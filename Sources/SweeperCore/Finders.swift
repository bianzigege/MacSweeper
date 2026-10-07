import AppKit
import Foundation

// MARK: - 通配路径

enum PathPattern {
    /// 展开路径里的通配符：含 `*` 的那一段按文件名匹配（如 `*` 或 `*.backup-*`）。
    /// 隐藏文件只在模式本身以 . 开头时才匹配；名字以 skipPrefixes 开头的跳过
    static func expand(_ pattern: String, skipPrefixes: [String] = []) -> [URL] {
        let full = (pattern as NSString).expandingTildeInPath
        var matches = ["/"]
        for part in full.split(separator: "/").map(String.init) {
            if part.contains("*") {
                matches = matches.flatMap { dir -> [String] in
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                    return names
                        .filter { part.hasPrefix(".") || !$0.hasPrefix(".") }
                        .filter { fnmatch(part, $0, 0) == 0 && !skipPrefixes.contains(where: $0.hasPrefix) }
                        .map { (dir as NSString).appendingPathComponent($0) }
                }
            } else {
                matches = matches.map { ($0 as NSString).appendingPathComponent(part) }
            }
        }
        return matches.map { URL(fileURLWithPath: $0) }
    }
}

// MARK: - Chromium 内核缓存

enum ChromiumCacheFinder {
    /// 这些子目录都是可重建的缓存；Cookie、Local Storage、IndexedDB、File System 等网站数据不碰
    static let cacheDirs = [
        "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache",
    ]

    /// 在 roots 下找 Chromium 配置目录（有 Preferences 文件的目录），返回其中的缓存目录
    static func find(roots: [String], excluding: [String]) -> [URL] {
        let excluded = Set(excluding.map { Scanner.expand($0).path })
        var found: [URL] = []
        for root in roots {
            walk(Scanner.expand(root), depth: 0, excluded: excluded, into: &found)
        }
        return found
    }

    private static func walk(_ dir: URL, depth: Int, excluded: Set<String>, into found: inout [URL]) {
        let fm = FileManager.default
        guard depth <= 5, !excluded.contains(dir.path) else { return }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        if names.contains("Preferences") {
            for sub in cacheDirs {
                let url = dir.appendingPathComponent(sub)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    found.append(url)
                }
            }
        }
        let skip = Set(cacheDirs.map { String($0.split(separator: "/")[0]) })
        for name in names where !name.hasPrefix(".") && !skip.contains(name) {
            let url = dir.appendingPathComponent(name)
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            if v?.isDirectory == true, v?.isSymbolicLink != true, v?.isPackage != true {
                walk(url, depth: depth + 1, excluded: excluded, into: &found)
            }
        }
    }
}

// MARK: - 大文件

enum LargeFileFinder {
    /// 这些目录不进去：删里面的文件会弄坏项目
    static let skipNames: Set<String> = ["node_modules"]
    /// 数据库文件通常是 App 的数据（聊天记录等），不列出
    static let skipExtensions: Set<String> = ["sqlite", "sqlite3", "db", "realm", "sqlite-wal", "db-wal"]

    static func find(minBytes: Int64) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library").path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                      .totalFileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(
            at: home, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true })
        else { return [] }

        var found: [URL] = []
        while let url = e.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // 隐藏文件和隐藏目录（.git、.codex 等）一般是程序数据，不碰
            let hidden = url.lastPathComponent.hasPrefix(".")
            if v.isDirectory == true {
                // App 数据包（如照片图库、.app）整体跳过；~/Library 由其他规则负责
                if hidden || url.path == library || skipNames.contains(url.lastPathComponent)
                    || v.isPackage == true {
                    e.skipDescendants()
                }
                continue
            }
            if hidden || v.isSymbolicLink == true { continue }
            if skipExtensions.contains(url.pathExtension.lowercased()) { continue }
            if Int64(v.totalFileAllocatedSize ?? 0) >= minBytes { found.append(url) }
        }
        return found
    }
}

// MARK: - 已卸载 App 的残留

enum LeftoverFinder {
    /// 去这些地方找以 Bundle ID 命名的文件夹/文件
    static let places = [
        "~/Library/Application Support", "~/Library/Containers", "~/Library/Group Containers",
        "~/Library/Preferences", "~/Library/Saved Application State", "~/Library/HTTPStorages",
        "~/Library/WebKit",
    ]

    /// 最近这么多天内有改动的，说明还在被使用，不算残留
    static let recentDays: Double = 30

    static func find() -> [URL] {
        let (installed, appNames) = AppInventory.scan()
        let cutoff = Date().addingTimeInterval(-recentDays * 86_400)
        let fm = FileManager.default
        var found: [URL] = []

        for place in places {
            let base = Scanner.expand(place)
            guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            let isGroup = place.hasSuffix("Group Containers")
            for name in names {
                guard let id = bundleID(fromName: name, isGroup: isGroup) else { continue }
                if isAppleOrSystem(id) || belongsToInstalled(id, installed, appNames) { continue }
                let url = base.appendingPathComponent(name)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantFuture
                if modified < cutoff { found.append(url) }
            }
        }
        return found
    }

    /// 从文件名里取出 Bundle ID，取不出来就返回 nil（比如 "Google" 这种普通名字不处理，避免误删）
    static func bundleID(fromName name: String, isGroup: Bool) -> String? {
        var s = name
        for ext in [".plist", ".savedState", ".binarycookies"] where s.hasSuffix(ext) {
            s = String(s.dropLast(ext.count))
        }
        var parts = s.split(separator: ".").map(String.init)
        if isGroup {
            // 形如 "UBF8T346G9.com.foo.bar" 或 "group.com.foo.bar"
            if let first = parts.first, first.count == 10,
               first.allSatisfy({ $0.isUppercase || $0.isNumber }) { parts.removeFirst() }
            if parts.first == "group" { parts.removeFirst() }
        }
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }),
              parts[0].first?.isLetter == true, parts[0].count <= 6,
              s.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else { return nil }
        return parts.joined(separator: ".").lowercased()
    }

    static func isAppleOrSystem(_ id: String) -> Bool {
        ["com.apple.", "apple.", "systemgroup.", "com.microsoft.office", "com.microsoft.autoupdate"]
            .contains { id.hasPrefix($0) }
    }

    /// 保守判断，宁可漏掉一些残留，也不误删。满足任一条就算“还在用”：
    /// 1. 同一厂商（ID 前两段相同，如 com.docker）还有任何 App 或服务装着
    /// 2. ID 里某一段正好是某个已安装 App 的名字（如 com.electron.lark.xxx ↔ Lark.app）
    static func belongsToInstalled(_ id: String, _ installed: Set<String>, _ appNames: Set<String>) -> Bool {
        let parts = id.split(separator: ".").map(String.init)
        let vendor = parts.prefix(2).joined(separator: ".")
        if installed.contains(where: { $0 == vendor || $0.hasPrefix(vendor + ".") }) { return true }
        return parts.dropFirst().contains { $0.count >= 3 && appNames.contains($0) }
    }
}

/// 收集这台电脑上所有已安装 App（以及其中的辅助程序、扩展）和后台服务的 Bundle ID
enum AppInventory {
    /// 返回（所有 Bundle ID，所有 App 名字），都转成小写
    static func scan() -> (ids: Set<String>, names: Set<String>) {
        var apps = Set<String>()
        // 1. Spotlight 能找到的所有 App，不管装在哪里
        apps.formUnion(spotlightApps())
        // 2. 常见安装位置兜底（Spotlight 被关掉时）
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", "~/Applications"] {
            let base = Scanner.expand(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            for n in names where n.hasSuffix(".app") { apps.insert(base.appendingPathComponent(n).path) }
        }

        var ids = Set<String>()
        var names = Set<String>()
        for path in apps {
            let url = URL(fileURLWithPath: path)
            ids.formUnion(bundleIDs(inApp: url))
            names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
        }
        // 3. 正在运行的程序
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        // 4. 后台服务（LaunchAgents / LaunchDaemons）的名字，命令行工具常用
        for dir in ["~/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: Scanner.expand(dir).path)) ?? []
            for n in files where n.hasSuffix(".plist") { ids.insert(String(n.dropLast(6)).lowercased()) }
        }
        return (ids, names)
    }

    /// App 本身和里面的辅助程序、扩展、iOS App 外壳
    static func bundleIDs(inApp app: URL) -> Set<String> {
        var ids = Set<String>()
        if let id = Bundle(url: app)?.bundleIdentifier { ids.insert(id.lowercased()) }
        let fm = FileManager.default
        for sub in ["Contents/Library/LoginItems", "Contents/PlugIns", "Contents/XPCServices",
                    "Contents/Library/LaunchServices", "Contents/Helpers", "Contents/Frameworks",
                    "Contents/Extensions", "Wrapper"] {
            let dir = app.appendingPathComponent(sub)
            for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where [".app", ".appex", ".xpc", ".systemextension"].contains(where: n.hasSuffix) {
                if let id = Bundle(url: dir.appendingPathComponent(n))?.bundleIdentifier {
                    ids.insert(id.lowercased())
                }
            }
        }
        return ids
    }

    static func spotlightApps() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

// MARK: - 正在运行的 App

func isProcessRunning(_ name: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", name]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

public enum RunningApps {
    /// 判断 ~/Library/<Application Support|Caches|Logs|Containers>/<文件夹>/ 对应的 App 是否在运行。
    /// 按 Bundle ID（com.openai.codex）或名字（LarkInternational ↔ Lark）匹配，宁可多跳过，不在 App 运行时动它的文件
    public static func owner(of url: URL) -> String? {
        let bases = ["/Library/Application Support/", "/Library/Caches/", "/Library/Logs/", "/Library/Containers/"]
        // 取路径里最靠前的那一段，比如 Containers/<微信>/Data/Library/Caches/… 要认成微信
        guard let r = bases.compactMap({ url.path.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
              let folder = url.path[r.upperBound...].split(separator: "/").first?.lowercased()
        else { return nil }
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy != .prohibited && app.bundleIdentifier?.hasPrefix("com.apple.") != true {
            if let id = app.bundleIdentifier?.lowercased(), folder == id || folder.hasPrefix(id + ".") || id.hasPrefix(folder + ".") {
                return app.localizedName ?? folder
            }
            let names = [app.localizedName, app.bundleURL?.deletingPathExtension().lastPathComponent,
                         app.executableURL?.lastPathComponent]
                .compactMap { $0?.lowercased() }.filter { $0.count >= 3 }
            if names.contains(where: { folder == $0 || folder.hasPrefix($0) || $0.hasPrefix(folder) }) {
                return app.localizedName ?? folder
            }
        }
        return nil
    }

    /// 返回 bundleIDs 里正在运行的那个 App 的名字
    public static func blocker(for bundleIDs: [String]) -> String? {
        guard !bundleIDs.isEmpty else { return nil }
        // "process:codex" 这种是命令行程序，用 pgrep 查
        for entry in bundleIDs where entry.hasPrefix("process:") {
            let name = String(entry.dropFirst("process:".count))
            if isProcessRunning(name) { return "命令行 \(name)" }
        }
        let ids = Set(bundleIDs.filter { !$0.hasPrefix("process:") }.map { $0.lowercased() })
        return NSWorkspace.shared.runningApplications
            .first { ids.contains($0.bundleIdentifier?.lowercased() ?? "") }
            .map { $0.localizedName ?? $0.bundleIdentifier ?? "相关 App" }
    }
}
