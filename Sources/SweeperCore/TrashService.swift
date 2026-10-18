import AppKit
import Foundation

/// 一次清理的结果
public struct CleanReport: Sendable {
    public var trashedCount = 0
    public var trashedBytes: Int64 = 0
    public var failures: [(path: String, reason: String)] = []
    /// 每个文件从哪里移到了废纸篓的哪里，用来撤销
    public var moves: [TrashMove] = []
    /// 这一批在撤销历史里的编号（什么都没移走时为 nil）
    public var batchID: UUID?

    public init() {}
}

/// 所有“移到废纸篓”都从这里走：清理垃圾、卸载 App、重复文件。
/// 安全护栏（只能动主目录里的东西 / “应用程序”里的 App）、操作日志、撤销记录只在这一处实现。
///
/// 用法：开一个会话，逐个 trash()，最后 finish() 拿结果并写入撤销历史。
public final class TrashSession {
    public enum Target {
        /// 主目录里的普通文件、文件夹
        case file
        /// “应用程序”里的 App 本体；归系统所有时会由 macOS 弹出密码框
        case app
    }

    public let kind: TrashBatch.Kind
    public let title: String
    public var report = CleanReport()
    private let logTag: String

    public init(kind: TrashBatch.Kind, title: String) {
        self.kind = kind
        self.title = title
        self.logTag = kind.rawValue.uppercased()
    }

    /// 记一条没能处理的
    public func fail(_ url: URL, _ reason: String) {
        report.failures.append((url.path, reason))
    }

    /// 把一个文件或文件夹移到废纸篓。
    /// - bytes：记到结果里的大小（重复文件里的克隆副本记 0，因为删了不省空间）
    /// - note：写进日志的备注，比如“保留了哪一份”
    /// 返回在废纸篓里的位置；不允许、或者没移成功时返回 nil（原因已记进 failures）
    @discardableResult
    public func trash(_ url: URL, bytes: Int64, target: Target = .file, note: String = "") -> URL? {
        // 安全护栏：这是唯一一处检查，三个功能共用
        let allowed = target == .app ? PathGuard.isAllowedApp(url) : PathGuard.isAllowed(url)
        guard allowed else {
            fail(url, L("不在允许范围内"))
            OperationLog.write("REFUSE \(url.path)")
            return nil
        }
        let outcome = Self.moveToTrash(url, viaFinderIfNeeded: Self.needsFinder(url, target: target))
        guard let moved = outcome.moved else {
            fail(url, outcome.reason)
            OperationLog.write("FAIL \(url.path)（\(outcome.reason)）")
            return nil
        }
        report.trashedCount += 1
        report.trashedBytes += bytes
        report.moves.append(TrashMove(original: url.path, inTrash: moved.path, bytes: bytes))
        let notes = [note, outcome.viaFinder ? L("经访达") : ""].filter { !$0.isEmpty }.joined(separator: L("，"))
        OperationLog.write("\(logTag) \(bytes) \(url.path)" + (notes.isEmpty ? "" : "（\(notes)）"))
        return moved
    }

    /// 结束：写入撤销历史，返回结果
    public func finish() -> CleanReport {
        if !report.moves.isEmpty {
            ProjectFinder.invalidate()
            let batch = TrashBatch(kind: kind, title: title, moves: report.moves)
            Undo.save(batch)
            report.batchID = batch.id
        }
        return report
    }

    // MARK: 底层

    struct Outcome {
        var moved: URL?
        var reason = ""
        var viaFinder = false
    }

    /// 能自己移的直接移。移不动时，App 本体和 App 的数据文件夹交给访达（viaFinderIfNeeded），
    /// 和你在访达里手动拖到废纸篓一样：要密码时访达会弹框
    static func moveToTrash(_ url: URL, viaFinderIfNeeded: Bool) -> Outcome {
        var inTrash: NSURL?
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: &inTrash)) != nil, let moved = inTrash as URL? {
            return Outcome(moved: moved)
        }
        guard viaFinderIfNeeded else { return Outcome(reason: L("没能移到废纸篓")) }
        switch FinderBridge.trash(url) {
        case let .success(moved): return Outcome(moved: moved, viaFinder: true)
        case let .failure(why): return Outcome(reason: why.message)
        }
    }

    /// 哪些东西 MacSweeper 自己可能移不动、要请访达帮忙：
    /// “应用程序”里的 App（从 App Store 装的归系统管理员所有，要密码）、
    /// App 的整个数据文件夹（~/Library/Containers/<ID>，新版 macOS 只让访达动）。
    /// 数据文件夹里面的缓存 MacSweeper 能自己清，不走访达
    static func needsFinder(_ url: URL, target: Target) -> Bool {
        if target == .app { return true }
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        return parent == PathGuard.home + "/Library/Containers" || parent == PathGuard.home + "/Library/Group Containers"
    }
}
