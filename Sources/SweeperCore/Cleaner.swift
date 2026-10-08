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

public enum Cleaner {
    /// 把项目移到废纸篓（不是永久删除，可以从废纸篓里还原）
    public static func moveToTrash(_ results: [ScanResult]) -> CleanReport {
        let session = TrashSession(kind: .clean, title: L("清理垃圾"))
        // 清理那一刻重新查一次哪些 App 在运行
        let running = RunningSnapshot.current()
        for result in results where result.rule.safety != .reportOnly {
            // 清理那一刻再检查一次，App 正在运行就整条跳过
            if let app = running.blocker(for: result.rule.quitApps) {
                session.report.failures.append((result.rule.name, L("%@ 正在运行，请先退出", app)))
                continue
            }
            for item in result.items {
                if result.rule.checksOwnerPerItem, let app = running.owner(of: item.url) {
                    session.fail(item.url, L("%@ 正在运行，请先退出", app))
                    continue
                }
                session.trash(item.url, bytes: item.bytes)
            }
        }
        return session.finish()
    }
}

/// 操作日志：~/Library/Logs/MacSweeper/operations.log
public enum OperationLog {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacSweeper/operations.log")

    public static func write(_ line: String) {
        // 自检程序在临时目录里做的测试不记进你的日志
        if line.contains("/macsweeper-selftest-") { return }
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
