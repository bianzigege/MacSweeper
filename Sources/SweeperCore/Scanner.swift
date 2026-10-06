import Foundation

/// 一个可清理的具体项目（文件或文件夹）
public struct Item: Sendable {
    public let url: URL
    public let bytes: Int64
    /// 最后修改时间，帮助判断还有没有用
    public let modified: Date?
}

public struct ScanResult: Sendable, Identifiable {
    public let rule: Rule
    public let items: [Item]
    /// 因权限不足等原因读不到的路径
    public let unreadable: [String]
    /// 正在运行、需要先退出的 App 名字
    public let blocker: String?
    /// 因所属 App 正在运行而跳过的应用名字
    public let skippedRunning: [String]

    public var id: String { rule.id }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    /// 只保留选中的项目，用于逐项清理
    public func keeping(_ urls: Set<URL>) -> ScanResult {
        ScanResult(rule: rule, items: items.filter { urls.contains($0.url) }, unreadable: unreadable,
                   blocker: blocker, skippedRunning: skippedRunning)
    }
}

public enum Scanner {
    /// 并行扫描所有规则，结果按规则原顺序返回
    public static func scan(_ rules: [Rule] = RuleBook.all) -> [ScanResult] {
        var results = [ScanResult?](repeating: nil, count: rules.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: rules.count) { i in
            let r = scan(rule: rules[i])
            lock.lock(); results[i] = r; lock.unlock()
        }
        return dedupeLargeFiles(results.compactMap { $0 })
    }

    /// 大文件可能已经在别的规则里（比如下载文件夹的安装包），从大文件里去掉，避免重复计算
    static func dedupeLargeFiles(_ results: [ScanResult]) -> [ScanResult] {
        let isLarge: (ScanResult) -> Bool = { if case .largeFiles = $0.rule.target { return true }; return false }
        let others = results.filter { !isLarge($0) }.flatMap { $0.items.map(\.url.path) }
        let covered = Set(others)
        return results.map { r in
            guard isLarge(r) else { return r }
            let items = r.items.filter { item in
                !covered.contains(item.url.path) && !others.contains { item.url.path.hasPrefix($0 + "/") }
            }
            return ScanResult(rule: r.rule, items: items, unreadable: r.unreadable,
                              blocker: r.blocker, skippedRunning: r.skippedRunning)
        }
    }

    public static func scan(rule: Rule) -> ScanResult {
        var unreadable: [String] = []
        var urls = candidates(for: rule.target, unreadable: &unreadable)
        var skipped = Set<String>()
        if rule.checksOwnerPerItem {
            urls = urls.filter { url in
                guard let app = RunningApps.owner(of: url) else { return true }
                skipped.insert(app)
                return false
            }
        }
        let items = urls.compactMap { url -> Item? in
            guard PathGuard.isAllowed(url) else { return nil }
            let size = allocatedSize(of: url)
            guard size > 0 else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return Item(url: url, bytes: size, modified: modified)
        }
        .sorted { $0.bytes > $1.bytes }
        return ScanResult(rule: rule, items: items, unreadable: unreadable,
                          blocker: RunningApps.blocker(for: rule.quitApps),
                          skippedRunning: skipped.sorted())
    }

    static func candidates(for target: Target, unreadable: inout [String]) -> [URL] {
        let fm = FileManager.default
        /// 列出目录内容；目录存在但读不了时记下来
        func list(_ dir: URL) -> [URL] {
            guard fm.fileExists(atPath: dir.path) else { return [] }
            do {
                return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            } catch {
                unreadable.append(dir.path)
                return []
            }
        }

        switch target {
        case let .paths(patterns):
            return patterns.flatMap { PathPattern.expand($0) }.filter { url in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
                if isDir.boolValue, (try? fm.contentsOfDirectory(atPath: url.path)) == nil {
                    unreadable.append(url.path)
                    return false
                }
                return true
            }

        case let .contents(pattern, excluded):
            return PathPattern.expand(pattern, skipPrefixes: excluded).flatMap(list)
                .filter { url in !excluded.contains { url.lastPathComponent.hasPrefix($0) } }

        case let .files(dir, exts):
            return list(expand(dir)).filter { exts.contains($0.pathExtension.lowercased()) }

        case let .chromiumCaches(roots, excluding):
            return ChromiumCacheFinder.find(roots: roots, excluding: excluding)

        case .leftovers:
            return LeftoverFinder.find()

        case let .largeFiles(minBytes):
            return LargeFileFinder.find(minBytes: minBytes)
        }
    }

    /// 实际占用的磁盘空间（不跟随符号链接，和“显示简介”里的“磁盘上”一致）
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? 0) }

        var total: Int64 = 0
        let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true })
        while let child = e?.nextObject() as? URL {
            if let cv = try? child.resourceValues(forKeys: keys), cv.isSymbolicLink != true {
                total += Int64(cv.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
