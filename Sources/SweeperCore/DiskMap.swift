import Foundation

/// 空间地图里的一块：一个文件夹、一个大文件，或者“其他小文件”的合计
public final class DiskNode: Identifiable, @unchecked Sendable {
    public enum Kind: Sendable { case folder, file, others }

    public let url: URL
    public let name: String
    public let kind: Kind
    public let size: Int64
    /// 子项，从大到小（只有文件夹有）
    public let children: [DiskNode]
    /// “其他小文件”合计了多少个
    public let mergedCount: Int

    public var id: String { kind == .others ? url.path + "/…others" : url.path }

    init(url: URL, name: String, kind: Kind, size: Int64, children: [DiskNode] = [], mergedCount: Int = 0) {
        self.url = url
        self.name = name
        self.kind = kind
        self.size = size
        self.children = children
        self.mergedCount = mergedCount
    }
}

public enum DiskMap {
    public struct Progress: Sendable {
        public var files: Int
        public var bytes: Int64
        public init(files: Int, bytes: Int64) { self.files = files; self.bytes = bytes }
    }

    /// 走一遍整个文件夹，算出每一层的大小。
    /// - minNodeBytes：比这小的文件/文件夹不单独显示，合进“其他小文件”（不然几十万个小块画不出来）
    /// - maxChildren：每层最多单独显示多少块，其余合进“其他小文件”
    /// 前两层的文件夹分给多个 CPU 核同时算（主目录和资料库下面通常有几十个大文件夹）
    public static func build(root: URL = FileManager.default.homeDirectoryForCurrentUser,
                             minNodeBytes: Int64 = 5_000_000, maxChildren: Int = 60,
                             progress: (@Sendable (Progress) -> Void)? = nil) -> DiskNode {
        let ctx = Context(minNodeBytes: minNodeBytes, maxChildren: maxChildren, progress: progress)
        let node = ctx.build(root, parallelLevels: 2)
        ctx.report()
        return node
    }

    /// 一次构建共用的东西：硬链接去重、进度
    final class Context: @unchecked Sendable {
        let minNodeBytes: Int64, maxChildren: Int
        let progress: (@Sendable (Progress) -> Void)?
        private let lock = NSLock()
        private var linked = Set<String>()
        private var files = 0, bytes: Int64 = 0, lastReport = 0

        init(minNodeBytes: Int64, maxChildren: Int, progress: (@Sendable (Progress) -> Void)?) {
            self.minNodeBytes = minNodeBytes
            self.maxChildren = maxChildren
            self.progress = progress
        }

        /// 文件实际占的空间；硬链接（同一个文件的几个名字）只有第一次算
        func count(_ st: stat) -> Int64 {
            let size = Int64(st.st_blocks) * 512
            lock.lock(); defer { lock.unlock() }
            if st.st_nlink > 1 && !linked.insert("\(st.st_dev):\(st.st_ino)").inserted { return 0 }
            files += 1
            bytes += size
            if files - lastReport >= 5000 { lastReport = files; progress?(Progress(files: files, bytes: bytes)) }
            return size
        }

        func report() {
            lock.lock(); let p = Progress(files: files, bytes: bytes); lock.unlock()
            progress?(p)
        }

        /// 把子项整理成一个文件夹节点：从大到小，太多的合进“其他小文件”
        func folder(_ url: URL, size: Int64, children: [DiskNode]) -> DiskNode {
            var kids = children.filter { $0.size >= minNodeBytes }.sorted { $0.size > $1.size }
            var merged = 0
            if kids.count > maxChildren {
                merged = kids.count - maxChildren
                kids = Array(kids[..<maxChildren])
            }
            let rest = size - kids.reduce(0) { $0 + $1.size }
            if rest > 0 { kids.append(DiskNode(url: url, name: "其他小文件", kind: .others, size: rest, mergedCount: merged)) }
            // 文件夹名用访达里显示的（资料库、文稿、桌面……），和你在访达里看到的一致
            return DiskNode(url: url, name: FileManager.default.displayName(atPath: url.path), kind: .folder, size: size, children: kids)
        }

        /// parallelLevels > 0：列出这一层，子文件夹并行地各自去算；否则用一次 fts 走完
        func build(_ dir: URL, parallelLevels: Int) -> DiskNode {
            guard parallelLevels > 0 else { return walk(dir) }
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            var subdirs: [URL] = []
            var files: [DiskNode] = []
            var size: Int64 = 0
            for url in entries {
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    subdirs.append(url)
                case S_IFLNK:
                    break
                default:
                    let bytes = count(st)
                    size += bytes
                    files.append(DiskNode(url: url, name: url.lastPathComponent, kind: .file, size: bytes))
                }
            }
            var results = [DiskNode?](repeating: nil, count: subdirs.count)
            let resultLock = NSLock()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 6
            for (i, sub) in subdirs.enumerated() {
                queue.addOperation {
                    let node = self.build(sub, parallelLevels: parallelLevels - 1)
                    resultLock.lock(); results[i] = node; resultLock.unlock()
                }
            }
            queue.waitUntilAllOperationsAreFinished()
            let dirs = results.compactMap { $0 }
            size += dirs.reduce(0) { $0 + $1.size }
            return folder(dir, size: size, children: files + dirs)
        }

        /// 用 fts 走完一个文件夹，一边走一边建树
        func walk(_ root: URL) -> DiskNode {
            final class Frame {
                let url: URL
                var size: Int64 = 0
                var children: [DiskNode] = []
                init(_ url: URL) { self.url = url }
            }
            var stack: [Frame] = []
            var result: DiskNode?
            FTS.walk(root.path, xdev: true) { entry, path, _ in
                switch Int32(entry.pointee.fts_info) {
                case FTS_D:
                    stack.append(Frame(URL(fileURLWithPath: path)))
                case FTS_DP:
                    guard let frame = stack.popLast() else { break }
                    let node = folder(frame.url, size: frame.size, children: frame.children)
                    if let parent = stack.last {
                        parent.size += node.size
                        parent.children.append(node)
                    } else {
                        result = node
                    }
                case FTS_F, FTS_DEFAULT:
                    guard let parent = stack.last else { break }
                    let bytes = count(entry.pointee.fts_statp.pointee)
                    parent.size += bytes
                    if bytes >= minNodeBytes {
                        let url = URL(fileURLWithPath: path)
                        parent.children.append(DiskNode(url: url, name: url.lastPathComponent, kind: .file, size: bytes))
                    }
                default:
                    break   // 读不了的文件夹（没有权限）、符号链接：跳过
                }
                return .next
            }
            return result ?? DiskNode(url: root, name: root.lastPathComponent, kind: .folder, size: 0)
        }
    }
}

// MARK: - 排列色块（squarified treemap：让每块尽量接近正方形，好看也好点）

public struct TreemapRect: Sendable {
    public let index: Int
    public let x: Double, y: Double, width: Double, height: Double
}

public enum Treemap {
    /// 把一组大小（从大到小）排进 width × height 的矩形里，面积和大小成正比
    public static func layout(_ sizes: [Int64], width: Double, height: Double) -> [TreemapRect] {
        let total = Double(sizes.reduce(0, +))
        guard total > 0, width > 0, height > 0 else { return [] }
        let scale = width * height / total
        var items = sizes.enumerated().map { (index: $0.offset, area: Double($0.element) * scale) }.filter { $0.area > 0 }
        var rects: [TreemapRect] = []
        var x = 0.0, y = 0.0, w = width, h = height

        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +)
            guard let mx = row.max(), let mn = row.min(), s > 0, mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }

        while !items.isEmpty {
            let side = min(w, h)
            var row: [(index: Int, area: Double)] = [items.removeFirst()]
            while let next = items.first,
                  worst(row.map(\.area) + [next.area], side) <= worst(row.map(\.area), side) {
                row.append(items.removeFirst())
            }
            let rowArea = row.reduce(0) { $0 + $1.area }
            if w >= h {
                // 竖着排一列
                let colWidth = rowArea / h
                var cy = y
                for item in row {
                    let ih = item.area / colWidth
                    rects.append(TreemapRect(index: item.index, x: x, y: cy, width: colWidth, height: ih))
                    cy += ih
                }
                x += colWidth; w -= colWidth
            } else {
                // 横着排一行
                let rowHeight = rowArea / w
                var cx = x
                for item in row {
                    let iw = item.area / rowHeight
                    rects.append(TreemapRect(index: item.index, x: cx, y: y, width: iw, height: rowHeight))
                    cx += iw
                }
                y += rowHeight; h -= rowHeight
            }
        }
        return rects
    }
}
