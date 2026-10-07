import AppKit
import SweeperCore

/// 界面状态：扫描、勾选、清理
@MainActor
final class SweepModel: ObservableObject {
    enum Phase { case idle, scanning, ready, cleaning }

    @Published var phase: Phase = .idle
    @Published var results: [ScanResult] = []
    /// 选中的具体项目
    @Published var selected: Set<URL> = []
    @Published var lastReport: CleanReport?
    @Published var freeBytes: Int64 = 0
    /// 忙碌时显示的文字
    @Published var busyText = ""
    /// 需要提醒的事，比如某个 App 没能退出
    @Published var notice: String?
    /// 被我们退出、还没重新打开的 App
    @Published var appsToReopen: [URL] = []
    /// 扫描进度：已完成、总数、刚扫完的规则名
    @Published var progress: (done: Int, total: Int, name: String) = (0, 0, "")
    /// “只报告”的大类还在后台统计
    @Published var reportsPending = false
    /// 每次扫描加一；旧的扫描结果晚到了就丢掉
    private var scanGeneration = 0
    /// 搜索框里的字
    @Published var query = ""
    /// 收起来的分组
    @Published var collapsed: Set<String> = []
    /// 废纸篓现在占多少（没有权限读取时为 nil）
    @Published var trashBytes: Int64?
    /// 上一次清理的记录，可以撤销
    @Published var undoBatch: TrashBatch? = Undo.lastBatch()
    @Published var lastUndo: UndoReport?
    /// 自定义规则文件里有问题的地方
    @Published var customProblems: [String] = []

    init() { refreshFreeSpace() }

    /// 普通规则（不属于某个 AI 工具），按安全等级分组
    func results(for safety: Safety) -> [ScanResult] {
        results.filter { $0.rule.safety == safety && $0.rule.tool == nil && matches($0) }
    }

    /// 搜索：规则名、说明、所属工具、具体项目的名字和路径，任何一个包含搜索词就显示
    func matches(_ r: ScanResult) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let fields = [r.rule.name, r.rule.detail, r.rule.tool ?? ""]
            + r.items.prefix(500).flatMap { [$0.displayName, $0.url.path] }
        return fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// 分组是否收起；搜索时全部展开
    func isCollapsed(_ key: String) -> Bool { query.isEmpty && collapsed.contains(key) }

    func toggleCollapsed(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    // MARK: 顶部总览

    /// 能直接清理的（不是只报告、App 没在运行）
    var safeBytes: Int64 { bytes { $0.rule.safety == .safe && isCleanable($0) } }
    var reviewBytes: Int64 { bytes { $0.rule.safety == .review && isCleanable($0) } }
    /// 要先退出 App 才能清理的
    var lockedBytes: Int64 { bytes { $0.rule.safety != .reportOnly && $0.blocker != nil } }

    private func bytes(_ include: (ScanResult) -> Bool) -> Int64 {
        results.filter(include).reduce(0) { $0 + $1.bytes }
    }

    func refreshTrash() {
        undoBatch = Undo.lastBatch()
        Task {
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            trashBytes = await Task.detached(priority: .utility) { () -> Int64? in
                // 没有“完全磁盘访问权限”时读不了废纸篓
                guard (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) != nil else { return nil }
                return Scanner.allocatedSize(of: trash)
            }.value
        }
    }

    /// 打开自定义规则文件（没有就先建一份带示例的）
    func openCustomRules() {
        let file = CustomRules.createTemplateIfNeeded()
        let editor = NSWorkspace.shared.urlForApplication(toOpen: file)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: .init()) { _, _ in }
    }

    func undoLast() {
        phase = .cleaning
        busyText = "正在把上次清理的文件放回原处…"
        notice = nil
        lastReport = nil
        Task {
            lastUndo = await Task.detached(priority: .userInitiated) { Undo.restoreLast() }.value
            scan(keepReport: true)
        }
    }

    struct ToolGroup: Identifiable {
        let tool: String
        let iconBundleID: String?
        let results: [ScanResult]
        var id: String { tool }
        /// 有“（全部）”那一条就用它的大小，否则把各条加起来
        var bytes: Int64 {
            results.first { $0.rule.safety == .reportOnly && $0.rule.name.hasSuffix("（全部）") }?.bytes
                ?? results.filter { $0.rule.safety != .reportOnly }.reduce(0) { $0 + $1.bytes }
        }
    }

    /// AI 工具的规则按工具分组：装着的工具按占用从大到小，后面跟项目、已卸载工具、命令行
    var toolGroups: [ToolGroup] {
        let order: [Safety] = [.safe, .review, .reportOnly]
        var groups: [String: [ScanResult]] = [:]
        for r in results where matches(r) { if let t = r.rule.tool { groups[t, default: []].append(r) } }
        let built = groups.map { tool, rs in
            ToolGroup(tool: tool, iconBundleID: rs.first?.rule.iconBundleID,
                      results: rs.sorted { order.firstIndex(of: $0.rule.safety)! < order.firstIndex(of: $1.rule.safety)! })
        }
        let tail = ["DeskClaw", "AI 做的项目", "已卸载的 AI 工具", "命令行"]
        return built.filter { !tail.contains($0.tool) }.sorted { $0.bytes > $1.bytes }
            + tail.compactMap { t in built.first { $0.tool == t } }
    }

    enum CheckState { case on, off, mixed }

    /// 能被清理的规则：不是“只报告”，相关 App 也没在运行
    func isCleanable(_ r: ScanResult) -> Bool { r.rule.safety != .reportOnly && r.blocker == nil }

    var selectedResults: [ScanResult] {
        results.filter(isCleanable).map { $0.keeping(selected) }.filter { !$0.items.isEmpty }
    }

    func state(of r: ScanResult) -> CheckState {
        let n = r.items.filter { selected.contains($0.url) }.count
        return n == 0 ? .off : (n == r.items.count ? .on : .mixed)
    }

    func selectedBytes(in r: ScanResult) -> Int64 {
        r.items.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.bytes }
    }

    var selectedBytes: Int64 { selectedResults.reduce(0) { $0 + $1.bytes } }
    var selectedCount: Int { selectedResults.reduce(0) { $0 + $1.items.count } }
    var needsFullDiskAccess: Bool { results.contains { !$0.unreadable.isEmpty } }

    func scan(keepReport: Bool = false) {
        phase = .scanning
        progress = (0, 0, "")
        reportsPending = true
        if !keepReport { lastReport = nil; notice = nil; lastUndo = nil }
        scanGeneration += 1
        let generation = scanGeneration
        let custom = CustomRules.load()
        customProblems = custom.problems
        let all = RuleBook.builtIn + custom.rules
        Task {
            let session = ScanSession()
            // 第一轮：能清理的规则，扫完马上显示
            let first = await Task.detached(priority: .userInitiated) {
                session.scan(all.filter { $0.safety != .reportOnly }) { done, total, name in
                    Task { @MainActor in
                        if generation == self.scanGeneration { self.progress = (done, total, name) }
                    }
                }
            }.value
            guard generation == scanGeneration else { return }
            show(first)
            refreshTrash()
            // 默认只勾选“可放心清理”、而且相关 App 没在运行的
            selected = Set(results.filter { $0.rule.safety == .safe && isCleanable($0) }
                .flatMap { $0.items.map(\.url) })
            refreshFreeSpace()
            phase = .ready

            // 第二轮：“只报告”的大类（如微信数据全部），在后台算完再补上
            let second = await Task.detached(priority: .utility) {
                session.scan(all.filter { $0.safety == .reportOnly })
            }.value
            guard generation == scanGeneration else { return }
            show(first + second)
            reportsPending = false
            refreshTrash()
        }
    }

    private func show(_ found: [ScanResult]) {
        results = ScanSession.ordered(found, like: RuleBook.builtIn + CustomRules.load().rules).filter { !$0.items.isEmpty || !$0.unreadable.isEmpty }
    }

    func clean() {
        let plan = selectedResults
        guard !plan.isEmpty else { return }
        phase = .cleaning
        busyText = "正在移到废纸篓…"
        notice = nil
        Task {
            lastReport = await Task.detached(priority: .userInitiated) { Cleaner.moveToTrash(plan) }.value
            scan(keepReport: true)
        }
    }

    // MARK: 退出 App 再清理

    /// 挡住这条规则的、正在运行的 App（只算有窗口的 App；命令行程序不在这里，不帮你结束）
    func quittableApps(for r: ScanResult) -> [NSRunningApplication] {
        guard let blocker = r.blocker, !blocker.hasPrefix("命令行") else { return [] }
        let ids = Set(r.rule.quitApps.filter { !$0.hasPrefix("process:") }.map { $0.lowercased() })
        return NSWorkspace.shared.runningApplications
            .filter { ids.contains($0.bundleIdentifier?.lowercased() ?? "") }
    }

    /// 像按 ⌘Q 一样让 App 自己退出；thenClean 为 true 时接着把这一条全部清理，并重新打开 App
    func quitApps(for r: ScanResult, thenClean: Bool) {
        let apps = quittableApps(for: r)
        guard !apps.isEmpty else { return }
        let names = apps.compactMap(\.localizedName).joined(separator: "、")
        let urls = apps.compactMap(\.bundleURL)
        phase = .cleaning
        busyText = "正在退出 \(names)…"
        notice = nil
        Task {
            apps.forEach { $0.terminate() }
            guard await waitUntilExited(apps, seconds: 20) else {
                notice = "\(names) 没有退出，可能在等你保存内容或确认。请切换过去处理一下，再点“重新扫描”。"
                scan(keepReport: true)
                return
            }
            if thenClean {
                busyText = "正在清理 \(r.rule.name)…"
                let rule = r.rule
                // App 退出后重新扫一遍这一条，拿到最新的文件列表再清理
                lastReport = await Task.detached(priority: .userInitiated) {
                    Cleaner.moveToTrash([Scanner.scan(rule: rule)])
                }.value
                reopen(urls)
            } else {
                appsToReopen = Array(Set(appsToReopen + urls))
            }
            scan(keepReport: true)
        }
    }

    func reopen(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
        }
        appsToReopen.removeAll { urls.contains($0) }
    }

    private func waitUntilExited(_ apps: [NSRunningApplication], seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return apps.allSatisfy(\.isTerminated)
    }

    /// 点类别的勾选框：全选时变全不选，否则变全选
    func toggle(_ r: ScanResult) {
        let urls = r.items.map(\.url)
        if state(of: r) == .on { selected.subtract(urls) } else { selected.formUnion(urls) }
    }

    func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    private func refreshFreeSpace() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeBytes = v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
