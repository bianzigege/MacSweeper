import Foundation

/// 安全护栏：所有删除操作在执行前都要过这一关
public enum PathGuard {}

extension PathGuard {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    /// 这些目录本身绝不能被删
    static let protectedRoots: Set<String> = [
        "", "/Library", "/Library/Caches", "/Library/Logs", "/Library/Containers",
        "/Library/Application Support", "/Library/Developer", "/Desktop", "/Documents",
        "/Downloads", "/Pictures", "/Movies", "/Music", "/.Trash", "/Library/Group Containers",
        "/Library/Preferences", "/Library/Saved Application State", "/Library/HTTPStorages",
        "/Library/WebKit", "/.cache", "/.npm",
    ].reduce(into: []) { $0.insert(home + $1) }

    /// 只允许处理主目录内、且不是受保护目录本身的路径
    public static func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home + "/") else { return false }
        guard !path.split(separator: "/").contains("..") else { return false }
        return !protectedRoots.contains(path)
    }
}

public struct CleanReport: Sendable {
    public var trashedCount = 0
    public var trashedBytes: Int64 = 0
    public var failures: [(path: String, reason: String)] = []
    /// 每个文件从哪里移到了废纸篓的哪里，用来撤销
    public var moves: [TrashMove] = []
}

public enum Cleaner {
    /// 把项目移到废纸篓（不是永久删除，可以从废纸篓里还原）
    public static func moveToTrash(_ results: [ScanResult]) -> CleanReport {
        var report = CleanReport()
        for result in results where result.rule.safety != .reportOnly {
            // 清理那一刻再检查一次，App 正在运行就整条跳过
            if let app = RunningApps.blocker(for: result.rule.quitApps) {
                report.failures.append((result.rule.name, "\(app) 正在运行，请先退出"))
                continue
            }
            for item in result.items {
                if result.rule.checksOwnerPerItem, let app = RunningApps.owner(of: item.url) {
                    report.failures.append((item.url.path, "\(app) 正在运行，请先退出"))
                    continue
                }
                guard PathGuard.isAllowed(item.url) else {
                    report.failures.append((item.url.path, "不在允许范围内"))
                    continue
                }
                do {
                    var inTrash: NSURL?
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: &inTrash)
                    report.trashedCount += 1
                    report.trashedBytes += item.bytes
                    if let inTrash = inTrash as URL? {
                        report.moves.append(TrashMove(original: item.url.path, inTrash: inTrash.path, bytes: item.bytes))
                    }
                    OperationLog.write("TRASH \(item.bytes) \(item.url.path)")
                } catch {
                    report.failures.append((item.url.path, error.localizedDescription))
                    OperationLog.write("FAIL \(item.url.path) \(error.localizedDescription)")
                }
            }
        }
        // 记下这一批，方便“撤销上次清理”
        if !report.moves.isEmpty { Undo.save(TrashBatch(date: Date(), moves: report.moves)) }
        return report
    }
}

/// 操作日志：~/Library/Logs/MacSweeper/operations.log
public enum OperationLog {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacSweeper/operations.log")

    static func write(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

public func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
