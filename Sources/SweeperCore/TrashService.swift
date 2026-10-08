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
        guard let moved = Self.moveToTrash(url, mayPromptForPassword: target == .app) else {
            fail(url, target == .app && Self.isOwnedByOtherUser(url)
                 ? L("需要电脑密码，你取消了或者没有权限。可以在访达里把它拖到废纸篓")
                 : L("没能移到废纸篓"))
            OperationLog.write("FAIL \(url.path)")
            return nil
        }
        report.trashedCount += 1
        report.trashedBytes += bytes
        report.moves.append(TrashMove(original: url.path, inTrash: moved.path, bytes: bytes))
        OperationLog.write("\(logTag) \(bytes) \(url.path)" + (note.isEmpty ? "" : "（\(note)）"))
        return moved
    }

    /// 结束：写入撤销历史，返回结果
    public func finish() -> CleanReport {
        if !report.moves.isEmpty {
            let batch = TrashBatch(kind: kind, title: title, moves: report.moves)
            Undo.save(batch)
            report.batchID = batch.id
        }
        return report
    }

    // MARK: 底层

    /// 普通文件直接移；需要权限时（mayPromptForPassword）交给系统处理，和在访达里拖到废纸篓一样，由 macOS 弹出密码框
    static func moveToTrash(_ url: URL, mayPromptForPassword: Bool) -> URL? {
        var inTrash: NSURL?
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: &inTrash)) != nil {
            return inTrash as URL?
        }
        guard mayPromptForPassword else { return nil }
        var result: URL?
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.recycle([url]) { moved, error in
            if error == nil { result = moved[url] }
            done.signal()
        }
        // 等你输入密码，最多 2 分钟
        _ = done.wait(timeout: .now() + 120)
        return result
    }

    static func isOwnedByOtherUser(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_uid != getuid()
    }
}
