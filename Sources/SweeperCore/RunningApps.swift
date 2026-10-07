import AppKit
import Foundation

/// 一个正在运行的程序
public struct RunningApp: Sendable {
    public let pid: pid_t
    public let bundleID: String?
    public let name: String
    public let bundleURL: URL?
    /// 用来和文件夹名比对的名字（小写）：显示名、App 文件名、可执行文件名
    let matchNames: [String]
    /// 是否是有界面的 App（后台服务不算）
    let hasUI: Bool

    public init(pid: pid_t, bundleID: String?, name: String, bundleURL: URL?, executableName: String?, hasUI: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundleURL = bundleURL
        self.matchNames = [name, bundleURL?.deletingPathExtension().lastPathComponent, executableName]
            .compactMap { $0?.lowercased() }.filter { $0.count >= 3 }
        self.hasUI = hasUI
    }
}

/// 某一刻正在运行的 App 和命令行程序。一次扫描只查一次系统，所有规则共用；
/// 清理那一刻再重新查一次。“规则要求退出的 App”和“文件夹属于哪个 App”都用这一份数据判断
public struct RunningSnapshot: Sendable {
    public let apps: [RunningApp]
    /// 所有进程的程序名（包括启动 MacSweeper 的上级进程，比如在 Codex 里运行命令行版时的 codex）
    public let processNames: Set<String>

    public init(apps: [RunningApp], processNames: Set<String>) {
        self.apps = apps
        self.processNames = processNames
    }

    public static func current() -> RunningSnapshot {
        let apps = NSWorkspace.shared.runningApplications.map { a in
            RunningApp(pid: a.processIdentifier, bundleID: a.bundleIdentifier,
                       name: a.localizedName ?? a.bundleIdentifier ?? L("相关 App"), bundleURL: a.bundleURL,
                       executableName: a.executableURL?.lastPathComponent,
                       hasUI: a.activationPolicy != .prohibited)
        }
        return RunningSnapshot(apps: apps, processNames: processNames())
    }

    /// 规则要求退出的 App（Bundle ID，或 "process:名字" 表示命令行程序）里，正在运行的那个的名字
    public func blocker(for quitApps: [String]) -> String? {
        if let name = runningCommandLine(in: quitApps) { return L("命令行 %@", name) }
        return apps(forBundleIDs: quitApps).first?.name
    }

    /// quitApps 里正在运行的命令行程序（"process:名字"）。这类不会帮你结束，只提示
    public func runningCommandLine(in quitApps: [String]) -> String? {
        quitApps.lazy.filter { $0.hasPrefix("process:") }
            .map { String($0.dropFirst("process:".count)) }
            .first { processNames.contains($0) }
    }

    /// 这些 Bundle ID 对应的、正在运行的 App
    public func apps(forBundleIDs ids: [String]) -> [RunningApp] {
        let wanted = Set(ids.filter { !$0.hasPrefix("process:") }.map { $0.lowercased() })
        return apps.filter { wanted.contains($0.bundleID?.lowercased() ?? "") }
    }

    /// 判断 ~/Library/<Application Support|Caches|Logs|Containers>/<文件夹>/ 属于哪个正在运行的 App。
    /// 按 Bundle ID（com.openai.codex）或名字（LarkInternational ↔ Lark）匹配，宁可多跳过，不在 App 运行时动它的文件
    public func owner(of url: URL) -> String? {
        let bases = ["/Library/Application Support/", "/Library/Caches/", "/Library/Logs/", "/Library/Containers/"]
        // 取路径里最靠前的那一段，比如 Containers/<微信>/Data/Library/Caches/… 要认成微信
        guard let r = bases.compactMap({ url.path.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
              let folder = url.path[r.upperBound...].split(separator: "/").first?.lowercased()
        else { return nil }
        for app in apps where app.hasUI && app.bundleID?.hasPrefix("com.apple.") != true {
            if let id = app.bundleID?.lowercased(),
               folder == id || folder.hasPrefix(id + ".") || id.hasPrefix(folder + ".") {
                return app.name
            }
            if app.matchNames.contains(where: { folder == $0 || folder.hasPrefix($0) || $0.hasPrefix(folder) }) {
                return app.name
            }
        }
        return nil
    }

    /// 用 ps 列出所有进程的程序名（只取文件名部分）
    static func processNames() -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            ($0.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        })
    }
}

/// 兼容旧的调用方式：每次现查一遍
public enum RunningApps {
    public static func blocker(for quitApps: [String]) -> String? {
        guard !quitApps.isEmpty else { return nil }
        return RunningSnapshot.current().blocker(for: quitApps)
    }

    public static func owner(of url: URL) -> String? {
        RunningSnapshot.current().owner(of: url)
    }
}
