import Foundation

/// 请访达代办“移到废纸篓 / 放回原处”，用在 MacSweeper 自己做不到的两种情况：
/// - 归系统管理员所有的 App（比如从 App Store 装的）：访达会像你手动拖一样弹出密码框
/// - App 自己的数据文件夹（~/Library/Containers/<ID>）：新版 macOS 不让别的 App 动，但允许访达
/// 效果和你在访达里手动拖到废纸篓完全一样。第一次用时 macOS 会问“允许 MacSweeper 控制访达吗”
public enum FinderBridge {
    public enum Failure: Error, Equatable, Sendable {
        /// 你在密码框里点了取消
        case cancelled
        /// 没有允许 MacSweeper 控制访达
        case notAllowed
        /// 其他原因（访达给的原话）
        case other(String)

        public var message: String {
            switch self {
            case .cancelled:
                return L("你在密码框里点了取消，没有移走")
            case .notAllowed:
                return L("需要允许 MacSweeper 控制访达：系统设置 → 隐私与安全性 → 自动化，打开 MacSweeper 下面的“访达”，再试一次")
            case let .other(text):
                return text.isEmpty ? L("访达没能移走它") : L("访达没能移走它：%@", text)
            }
        }
    }

    /// 移到废纸篓，返回它在废纸篓里的位置（撤销时用）
    public static func trash(_ url: URL) -> Result<URL, Failure> {
        run("""
        on run argv
            with timeout of 600 seconds
                tell application "Finder"
                    set t to delete (POSIX file (item 1 of argv) as alias)
                    return POSIX path of (t as alias)
                end tell
            end timeout
        end run
        """, [url.path]).map { URL(fileURLWithPath: cleanPath($0)) }
    }

    /// 从废纸篓放回原来的文件夹，名字也改回原来的。需要密码时访达同样会弹框
    public static func putBack(_ inTrash: URL, to original: URL) -> Result<URL, Failure> {
        run("""
        on run argv
            with timeout of 600 seconds
                tell application "Finder"
                    set m to move (POSIX file (item 1 of argv) as alias) to (POSIX file (item 2 of argv) as alias)
                    if name of m is not (item 3 of argv) then set name of m to (item 3 of argv)
                    return POSIX path of (m as alias)
                end tell
            end timeout
        end run
        """, [inTrash.path, original.deletingLastPathComponent().path, original.lastPathComponent])
            .map { URL(fileURLWithPath: cleanPath($0)) }
    }

    /// App 和文件夹的路径，访达会在末尾多给一个 /
    static func cleanPath(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 1 && t.hasSuffix("/") ? String(t.dropLast()) : t
    }

    /// 从 osascript 的报错里认出是哪种失败
    static func failure(fromError text: String) -> Failure {
        if text.contains("-128") { return .cancelled }
        if text.contains("-1743") || text.contains("-1744") { return .notAllowed }
        // 原话类似 “execution error: Finder got an error: ... (-10006)”，去掉前缀，只留后半句
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "execution error: ") { t = String(t[r.upperBound...]) }
        return .other(t)
    }

    private static func run(_ script: String, _ args: [String]) -> Result<String, Failure> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(.other(error.localizedDescription)) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            return .failure(failure(fromError: String(decoding: e, as: UTF8.self)))
        }
        return .success(String(decoding: o, as: UTF8.self))
    }
}
