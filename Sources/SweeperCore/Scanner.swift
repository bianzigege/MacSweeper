import Foundation

/// 一个可清理的具体项目（文件或文件夹）
public struct Item: Sendable {
    public let url: URL
    public let bytes: Int64
    /// 最后修改时间，帮助判断还有没有用（项目依赖用的是整个项目最后一次改动的时间）
    public let modified: Date?
    /// 显示用的名字，比如“tk-creator 的 node_modules”；没有就显示文件名
    public let label: String?

    public var displayName: String { label ?? url.lastPathComponent }
}

/// 查找阶段的结果：路径，加上可选的显示名和日期
struct Candidate {
    let url: URL
    var label: String? = nil
    var modified: Date? = nil
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

/// 一次扫描：几轮扫描共用同一个大小计算器（记住算过的文件夹）
public final class ScanSession: @unchecked Sendable {
    let sizes = SizeCalculator()
    /// 同时扫几条规则。实测 6 条最快：再多会互相抢硬盘，反而变慢
    static let concurrency = 6

    public init() {}

    /// 扫这些规则；每扫完一条调用一次 progress（已完成数、总数、规则名），在后台线程调用
    public func scan(_ rules: [Rule], progress: (@Sendable (Int, Int, String) -> Void)? = nil) -> [ScanResult] {
        var results = [ScanResult?](repeating: nil, count: rules.count)
        var done = 0
        let lock = NSLock()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = Self.concurrency
        for (i, rule) in rules.enumerated() {
            queue.addOperation { [sizes] in
                let r = Scanner.scan(rule: rule, sizes: sizes)
                lock.lock(); results[i] = r; done += 1; let n = done; lock.unlock()
                progress?(n, rules.count, rule.name)
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return Scanner.dedupe(results.compactMap { $0 })
    }

    /// 按规则在 RuleBook 里的顺序排好
    public static func ordered(_ results: [ScanResult], like rules: [Rule] = RuleBook.all) -> [ScanResult] {
        let index = Dictionary(uniqueKeysWithValues: rules.enumerated().map { ($1.id, $0) })
        return results.sorted { (index[$0.rule.id] ?? .max) < (index[$1.rule.id] ?? .max) }
    }
}

public enum Scanner {
    /// 扫描所有规则，结果按规则原顺序返回。
    /// 分两轮：先扫能清理的规则，再扫“只报告”的大类（如“微信数据（全部）”），
    /// 两轮共用一个大小计算器，第二轮遇到第一轮算过的文件夹直接用结果
    public static func scan(_ rules: [Rule] = RuleBook.all) -> [ScanResult] {
        let session = ScanSession()
        let first = session.scan(rules.filter { $0.safety != .reportOnly })
        let second = session.scan(rules.filter { $0.safety == .reportOnly })
        return ScanSession.ordered(first + second, like: rules)
    }

    /// 同一个文件可能被几条规则找到（比如大文件也是下载的安装包，浏览器缓存也在已卸载工具的文件夹里）。
    /// 规则：被别的可清理规则的文件夹整个包含的，从自己这条里去掉；完全相同的，只留在排前面的规则里。
    /// “只报告”的规则不参与，它们本来就只是看看。
    static func dedupe(_ results: [ScanResult]) -> [ScanResult] {
        var owner: [String: Int] = [:]   // 路径 → 第一个拥有它的规则序号
        for (i, r) in results.enumerated() where r.rule.safety != .reportOnly {
            for item in r.items where owner[item.url.path] == nil { owner[item.url.path] = i }
        }
        return results.enumerated().map { i, r in
            guard r.rule.safety != .reportOnly else { return r }
            let items = r.items.filter { item in
                if let first = owner[item.url.path], first != i { return false }
                var parent = item.url.deletingLastPathComponent()
                while parent.path.count > 1 {
                    if owner[parent.path] != nil { return false }
                    parent = parent.deletingLastPathComponent()
                }
                return true
            }
            return ScanResult(rule: r.rule, items: items, unreadable: r.unreadable,
                              blocker: r.blocker, skippedRunning: r.skippedRunning)
        }
    }

    public static func scan(rule: Rule) -> ScanResult {
        scan(rule: rule, sizes: SizeCalculator())
    }

    static func scan(rule: Rule, sizes: SizeCalculator) -> ScanResult {
        var unreadable: [String] = []
        var found = candidates(for: rule.target, unreadable: &unreadable)
        var skipped = Set<String>()
        if rule.checksOwnerPerItem {
            found = found.filter { c in
                guard let app = RunningApps.owner(of: c.url) else { return true }
                skipped.insert(app)
                return false
            }
        }
        let items = found.compactMap { c -> Item? in
            // 只报告的规则可以看主目录以外（比如“应用程序”里的旧版备份），反正不会去删
            guard rule.safety == .reportOnly || PathGuard.isAllowed(c.url) else { return nil }
            let size = sizes.size(of: c.url)
            // 失效链接本身几乎不占空间，但仍然要列出来
            if case .brokenLinks = rule.target {} else { guard size > 0 else { return nil } }
            let modified = c.modified
                ?? (try? c.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let days = rule.minAgeDays, let m = modified,
               m > Date().addingTimeInterval(-Double(days) * 86_400) { return nil }
            return Item(url: c.url, bytes: size, modified: modified, label: c.label)
        }
        .sorted { $0.bytes > $1.bytes }
        return ScanResult(rule: rule, items: items, unreadable: unreadable,
                          blocker: RunningApps.blocker(for: rule.quitApps),
                          skippedRunning: skipped.sorted())
    }

    static func candidates(for target: Target, unreadable: inout [String]) -> [Candidate] {
        switch target {
        case let .projectDependencies(inactiveDays):
            return ProjectFinder.dependencies(inactiveDays: inactiveDays)
        case let .staleProjects(inactiveDays):
            return ProjectFinder.staleProjects(inactiveDays: inactiveDays)
        case let .codexSessions(olderThanDays):
            return CodexFinder.oldSessionMonths(olderThanDays: olderThanDays)
        case let .uninstalledTools(traces):
            return ToolTraceFinder.find(traces)
        case let .olderVersions(dirs):
            return VersionFinder.olderVersions(in: dirs)
        case let .brokenLinks(dirs):
            return BrokenLinkFinder.find(in: dirs)
        default:
            return urls(for: target, unreadable: &unreadable).map { Candidate(url: $0) }
        }
    }

    static func urls(for target: Target, unreadable: inout [String]) -> [URL] {
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

        case .projectDependencies, .staleProjects, .codexSessions, .uninstalledTools, .olderVersions, .brokenLinks:
            return []   // 在 candidates 里处理
        }
    }

    /// 实际占用的磁盘空间（不跟随符号链接，和“显示简介”里的“磁盘上”一致）
    public static func allocatedSize(of url: URL) -> Int64 {
        SizeCalculator().size(of: url)
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
