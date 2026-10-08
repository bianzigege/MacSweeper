import AppKit
import SweeperCore

/// “重复文件”页面的状态
@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var progress = DuplicateFinder.Progress(phase: "", done: 0, total: 0)
    /// 勾选要移走的文件（默认一个都不勾）
    @Published var selected: Set<URL> = []
    @Published var busyText: String?
    @Published var lastReport: CleanReport?
    @Published var notice: String?

    var totalSaving: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }
    var selectedFreed: Int64 { groups.reduce(0) { $0 + $1.freedBytes(removing: selected) } }

    func scan() {
        scanning = true
        notice = nil
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.find { p in Task { @MainActor in self.progress = p } }
            }.value
            groups = found
            selected = selected.filter { url in found.contains { $0.files.contains { $0.url == url } } }
            scanning = false
            scanned = true
        }
    }

    /// 勾选或取消一个文件。每组至少要留一份，不能全勾
    func toggle(_ file: DuplicateGroup.File, in group: DuplicateGroup) {
        if selected.contains(file.url) {
            selected.remove(file.url)
            return
        }
        let others = group.files.filter { $0.url != file.url }
        if others.allSatisfy({ selected.contains($0.url) }) {
            notice = L("每组至少要留一份，不能全部勾上")
            return
        }
        notice = nil
        selected.insert(file.url)
    }

    /// 每组只留建议保留的那一份（克隆副本那组跳过，删了也不省空间）
    func keepOnePerGroup() {
        notice = nil
        for g in groups where !g.allClones {
            for f in g.files where f.url != g.suggestedKeep.url { selected.insert(f.url) }
        }
    }

    func clearSelection() { selected.removeAll(); notice = nil }

    func clean() {
        let chosen = selected
        let targets = groups
        busyText = L("正在移到废纸篓…")
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                DuplicateCleaner.trash(targets, selected: chosen)
            }.value
            lastReport = report
            selected.removeAll()
            busyText = nil
            scan()
        }
    }

    func undo() {
        guard let id = lastReport?.batchID else { return }
        busyText = L("正在把上次清理的文件放回原处…")
        Task {
            let r = await Task.detached(priority: .userInitiated) { Undo.restore(id: id) }.value
            lastReport = nil
            busyText = nil
            if let r { notice = L("已放回 %ld 项（%@）", r.restoredCount, formatBytes(r.restoredBytes)) }
            scan()
        }
    }
}
