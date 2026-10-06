import Foundation
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

    init() { refreshFreeSpace() }

    func results(for safety: Safety) -> [ScanResult] {
        results.filter { $0.rule.safety == safety }
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
        if !keepReport { lastReport = nil }
        Task {
            let found = await Task.detached(priority: .userInitiated) { Scanner.scan() }.value
            results = found.filter { $0.bytes > 0 || !$0.unreadable.isEmpty }
            // 默认只勾选“可放心清理”、而且相关 App 没在运行的
            selected = Set(results.filter { $0.rule.safety == .safe && isCleanable($0) }
                .flatMap { $0.items.map(\.url) })
            refreshFreeSpace()
            phase = .ready
        }
    }

    func clean() {
        let plan = selectedResults
        guard !plan.isEmpty else { return }
        phase = .cleaning
        Task {
            lastReport = await Task.detached(priority: .userInitiated) { Cleaner.moveToTrash(plan) }.value
            scan(keepReport: true)
        }
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
