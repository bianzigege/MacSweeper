import CryptoKit
import Foundation

/// 一组内容完全一样的文件
public struct DuplicateGroup: Sendable, Identifiable {
    public struct File: Sendable, Hashable, Identifiable {
        public let url: URL
        public let modified: Date
        /// APFS 内容标识：一样的说明是“克隆副本”，共用同一份硬盘空间
        let contentID: Int64?
        public var id: String { url.path }
    }

    public let size: Int64
    public let files: [File]
    public var id: String { files.map(\.url.path).joined(separator: "|") }

    /// 建议保留哪一份：优先保留整理过的（不在“下载”里、名字不像副本），再选最早的那份
    public var suggestedKeep: File {
        files.min { a, b in
            let ka = DuplicateGroup.keepScore(a), kb = DuplicateGroup.keepScore(b)
            return ka != kb ? ka < kb : a.modified < b.modified
        }!
    }

    /// 分数越小越该留：在“下载”里 +2，名字像副本（“(1)”、“ 2”、“副本”、“copy”）+1
    static func keepScore(_ f: File) -> Int {
        let path = f.url.path
        let name = f.url.deletingPathExtension().lastPathComponent.lowercased()
        var score = 0
        if path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Downloads/") { score += 2 }
        if name.range(of: #"(\(\d+\)|[ _-]\d+|副本|copy|拷贝)$"#, options: .regularExpression) != nil { score += 1 }
        return score
    }

    /// 是不是全都是克隆副本（删了不省空间）
    public var allClones: Bool {
        guard let first = files.first?.contentID else { return false }
        return files.allSatisfy { $0.contentID == first }
    }

    /// 移走这些文件实际能腾出多少：和留下的某份是克隆（共用空间）的，删了不省；
    /// 要删的几份彼此是克隆的，只算一次
    public func freedBytes(removing urls: Set<URL>) -> Int64 {
        let keptStorage = Set(files.filter { !urls.contains($0.url) }.map { $0.contentID.map(String.init) ?? $0.url.path })
        let removedStorage = Set(files.filter { urls.contains($0.url) }.map { $0.contentID.map(String.init) ?? $0.url.path })
        return size * Int64(removedStorage.subtracting(keptStorage).count)
    }

    /// 只留一份能省多少：克隆副本之间共用空间，按“不同的内容块”算
    public var wastedBytes: Int64 {
        let distinctStorage = Set(files.map { $0.contentID.map(String.init) ?? $0.url.path }).count
        return size * Int64(max(0, distinctStorage - 1))
    }
}

public enum DuplicateFinder {
    /// 去这些地方找（主目录下，跳过 ~/Library 等程序数据）
    public static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let skip: Set<String> = ["Library", "Applications", "Public"]
        return ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !skip.contains($0) }
            .map { home.appendingPathComponent($0) }
    }

    /// 这些文件夹不进去：程序依赖、版本库、App 自己管理的缓存和媒体库（删了会让 App 出问题）
    static let skipDirs: Set<String> = [
        "node_modules", ".git", ".venv", "venv", "__pycache__", ".build", "DerivedData", "Pods",
        "Cache", "Caches", "cache", "User Data", "JianyingPro", "CapCut", "Media.localized",
    ]

    public struct Progress: Sendable {
        public var phase: String
        public var done: Int
        public var total: Int

        public init(phase: String, done: Int, total: Int) {
            self.phase = phase
            self.done = done
            self.total = total
        }
    }

    /// 找重复文件：先按大小分组，再比开头结尾，最后完整比对内容
    /// - minBytes：小于这个大小的不管（太小的重复省不了多少空间）
    public static func find(roots: [URL] = defaultRoots(), minBytes: Int64 = 1_000_000,
                            progress: (@Sendable (Progress) -> Void)? = nil) -> [DuplicateGroup] {
        // 1. 走一遍，按大小分组
        progress?(Progress(phase: "正在列出文件…", done: 0, total: 0))
        var bySize: [Int64: [URL]] = [:]
        var seenInodes = Set<String>()   // 硬链接（同一个文件的两个名字）只算一次
        // 项目文件夹整个跳过：项目里每份字体、图片都是这个项目要用的，删了项目就坏了
        let projects = Set(ProjectFinder.all().map(\.url.path))
        for root in roots {
            FTS.walk(root.path) { entry, path, level in
                let name = (path as NSString).lastPathComponent
                switch Int32(entry.pointee.fts_info) {
                case FTS_D:
                    if level > 0 && (name.hasPrefix(".") || skipDirs.contains(name) || isPackage(path)) { return .skip }
                    if projects.contains(path) { return .skip }
                case FTS_F:
                    let st = entry.pointee.fts_statp.pointee
                    let size = Int64(st.st_size)
                    guard size >= minBytes, !name.hasPrefix(".") else { break }
                    guard seenInodes.insert("\(st.st_dev):\(st.st_ino)").inserted else { break }
                    bySize[size, default: []].append(URL(fileURLWithPath: path))
                default:
                    break
                }
                return .next
            }
        }
        let candidates = bySize.filter { $0.value.count > 1 }

        // 2. 比开头和结尾各 64KB，大多数“只是大小一样”的在这里就分开了
        var groups: [[URL]] = []
        for (size, urls) in candidates {
            let byEdges = Dictionary(grouping: urls) { edgeDigest($0, size: size) ?? UUID().uuidString }
            groups += byEdges.values.filter { $0.count > 1 }
        }

        // 3. 完整比对内容（读整个文件算指纹）
        let total = groups.count
        var result: [DuplicateGroup] = []
        for (i, urls) in groups.enumerated() {
            progress?(Progress(phase: "正在逐个比对内容…", done: i, total: total))
            let byContent = Dictionary(grouping: urls) { fullDigest($0) ?? UUID().uuidString }
            for same in byContent.values where same.count > 1 {
                let files = same.map { url -> DuplicateGroup.File in
                    let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileContentIdentifierKey])
                    return .init(url: url, modified: v?.contentModificationDate ?? .distantPast,
                                 contentID: v?.fileContentIdentifier)
                }
                let size = (try? same[0].resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                result.append(DuplicateGroup(size: size, files: files.sorted { $0.modified < $1.modified }))
            }
        }
        progress?(Progress(phase: "完成", done: total, total: total))
        return result.sorted { $0.wastedBytes > $1.wastedBytes }
    }


    static func isPackage(_ path: String) -> Bool {
        ["app", "photoslibrary", "fcpbundle", "logicx", "imovielibrary", "bundle", "framework", "xcarchive"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    /// 开头和结尾各 64KB 的指纹
    static func edgeDigest(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 64 * 1024
        var hasher = SHA256()
        if let head = try? h.read(upToCount: chunk) { hasher.update(data: head) }
        if size > Int64(chunk * 2) {
            try? h.seek(toOffset: UInt64(size - Int64(chunk)))
            if let tail = try? h.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 整个文件的指纹（每次读 1MB，不会一次占很多内存）
    static func fullDigest(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            guard let data = try? h.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DuplicateCleaner {
    /// 把选中的重复副本移到废纸篓。每组至少留一份：清理前再核对一遍，
    /// 确认留下的那份还在、大小没变、内容和要删的一样，否则这一组整组跳过
    public static func trash(_ groups: [DuplicateGroup], selected: Set<URL>) -> CleanReport {
        var report = CleanReport()
        for group in groups {
            let remove = group.files.filter { selected.contains($0.url) }
            let keep = group.files.filter { !selected.contains($0.url) }
            guard !remove.isEmpty else { continue }
            guard let kept = keep.first(where: { FileManager.default.fileExists(atPath: $0.url.path) }) else {
                report.failures.append((group.files[0].url.path, L("这一组没有留下任何一份，为了安全整组跳过")))
                continue
            }
            let keptDigest = DuplicateFinder.fullDigest(kept.url)
            for file in remove {
                guard PathGuard.isAllowed(file.url) else {
                    report.failures.append((file.url.path, L("不在允许范围内")))
                    continue
                }
                // 内容有变化（比如你后来改过）就不删
                guard keptDigest != nil, DuplicateFinder.fullDigest(file.url) == keptDigest else {
                    report.failures.append((file.url.path, L("和留下的那份内容已经不一样了，没有删")))
                    continue
                }
                var inTrash: NSURL?
                do {
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: &inTrash)
                    let freed = group.allClones ? 0 : group.size
                    report.trashedCount += 1
                    report.trashedBytes += freed
                    if let t = inTrash as URL? {
                        report.moves.append(TrashMove(original: file.url.path, inTrash: t.path, bytes: freed))
                    }
                    OperationLog.write("DUPLICATE \(group.size) \(file.url.path)（保留 \(kept.url.path)）")
                } catch {
                    report.failures.append((file.url.path, error.localizedDescription))
                }
            }
        }
        if !report.moves.isEmpty { Undo.save(TrashBatch(date: Date(), moves: report.moves)) }
        return report
    }
}
