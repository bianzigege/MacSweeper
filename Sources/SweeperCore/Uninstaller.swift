import AppKit
import CoreServices
import Foundation

// MARK: - App 清单

/// 一个装在“应用程序”里的 App
public struct AppInfo: Sendable, Identifiable, Hashable {
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    /// 最后一次打开的时间（来自 Spotlight）；nil 表示从来没打开过
    public let lastUsed: Date?
    /// 为什么不能卸载；nil 表示可以卸载
    public let protection: Protection?
    /// App 文件归系统（root）所有，移到废纸篓要输入电脑密码
    public let needsPassword: Bool
    /// 用 Homebrew 装的（brew 的名字）
    public let homebrewCask: String?

    public var id: String { url.path }

    public enum Protection: String, Sendable {
        case system      // 苹果自带
        case itself      // MacSweeper 自己
        case userList    // 你加进了保护名单
    }

    /// 超过这么多天没打开，算“很久没用”
    public static let unusedDays = 90

    public var isUnused: Bool {
        guard let lastUsed else { return true }
        return Date().timeIntervalSince(lastUsed) > Double(Self.unusedDays) * 86_400
    }
}

public enum AppCatalog {
    /// 去这些地方找 App（包括下一层文件夹，比如 /Applications/Adobe Photoshop 2024/）
    static let roots = ["/Applications", "~/Applications"]

    public static func list() -> [AppInfo] {
        let fm = FileManager.default
        var urls: [URL] = []
        for root in roots {
            let base = Scanner.expand(root)
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where !name.hasPrefix(".") {
                let url = base.appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    urls.append(url)
                } else if name != "Utilities", isPlainFolder(url) {
                    for inner in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where inner.hasSuffix(".app") {
                        urls.append(url.appendingPathComponent(inner))
                    }
                }
            }
        }
        let protected = ProtectedApps.load()
        let casks = homebrewCasks()
        let apps = urls.map { info(for: $0, protected: protected, casks: casks) }
        // 名字重复时（比如 Claude 和它的旧版备份都叫 Claude）改用文件名，免得卸错
        let counts = Dictionary(apps.map { ($0.name, 1) }, uniquingKeysWith: +)
        return apps.map { a in
            guard counts[a.name, default: 0] > 1 else { return a }
            return AppInfo(url: a.url, name: a.url.deletingPathExtension().lastPathComponent, bundleID: a.bundleID,
                           version: a.version, lastUsed: a.lastUsed, protection: a.protection,
                           needsPassword: a.needsPassword, homebrewCask: a.homebrewCask)
        }
    }

    public static func info(for url: URL, protected: Set<String> = ProtectedApps.load(),
                            casks: Set<String> = homebrewCasks()) -> AppInfo {
        let plist = infoPlist(url)
        let id = plist["CFBundleIdentifier"] as? String
        // 用访达里显示的名字（会按系统语言显示，比如“剪映专业版”），和你在访达里看到的一致
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.isEmpty { name = (plist["CFBundleDisplayName"] as? String) ?? url.deletingPathExtension().lastPathComponent }
        let version = plist["CFBundleShortVersionString"] as? String

        var protection: AppInfo.Protection?
        if id?.lowercased().hasPrefix("com.apple.") == true || url.path.hasPrefix("/System/") {
            protection = .system
        } else if id != nil && id == Bundle.main.bundleIdentifier || url.lastPathComponent == "MacSweeper.app" {
            protection = .itself
        } else if protected.contains(id ?? url.path) {
            protection = .userList
        }

        var st = stat()
        let needsPassword = lstat(url.path, &st) == 0 && st.st_uid != getuid()
        let token = url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
        return AppInfo(url: url, name: name, bundleID: id, version: version, lastUsed: lastUsedDate(url),
                       protection: protection, needsPassword: needsPassword,
                       homebrewCask: casks.contains(token) ? token : nil)
    }

    /// “应用程序”里和它 ID 一样、但不是它本身的其他副本
    public static func otherCopies(of app: AppInfo) -> [URL] {
        guard let id = app.bundleID?.lowercased() else { return [] }
        let me = app.url.standardizedFileURL.path
        return list().filter { $0.bundleID?.lowercased() == id && $0.url.standardizedFileURL.path != me }.map(\.url)
    }

    /// 直接读 App 的 Info.plist。不用 Bundle(url:)：系统会缓存它，App 还没拷贝完时读到的“空”会一直被记着
    public static func infoPlist(_ app: URL) -> [String: Any] {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
            ?? (NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any])   // iOS App 外壳等
            ?? [:]
    }

    /// Spotlight 记录的“上次打开时间”
    static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Homebrew 装的 App 的名字（Caskroom 里的文件夹名）
    public static func homebrewCasks() -> Set<String> {
        var names = Set<String>()
        for dir in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            names.formUnion((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        }
        return names
    }

    private static func isPlainFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isPackage != true && v?.isSymbolicLink != true
    }
}

/// 保护名单：加进来的 App 不能卸载。存在 ~/Library/Application Support/MacSweeper/protected-apps.json
public enum ProtectedApps {
    public static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSweeper/protected-apps.json")

    public static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    /// 用 Bundle ID 记；没有 ID 的用路径
    public static func set(_ app: AppInfo, protected: Bool) {
        var list = load()
        let key = app.bundleID ?? app.url.path
        if protected { list.insert(key) } else { list.remove(key) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list.sorted()).write(to: file, options: .atomic)
    }
}

// MARK: - 卸载计划：这个 App 有哪些相关文件

public struct UninstallItem: Sendable, Identifiable, Hashable {
    public enum Kind: Int, Sendable, Comparable {
        /// App 本体，一定会删
        case bundle
        /// 文件夹名和 App 的 ID 完全对得上的缓存、设置等，默认勾选
        case matched
        /// 开机自启项（你账户下的），默认勾选；删之前先停掉
        case launchAgent
        /// 可能有你数据的（应用数据、沙盒容器），默认不勾
        case userData
        /// 按名字猜的，不确定属于它，默认不勾
        case guessed
        /// 同一厂商其他 App 还在用的共享文件，不能删，只告诉你
        case shared
        /// 系统级的后台服务（需要管理员权限），只告诉你怎么处理
        case systemLevel

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        public var selectedByDefault: Bool { self == .bundle || self == .matched || self == .launchAgent }
        public var removable: Bool { self != .shared && self != .systemLevel }
    }

    public let url: URL
    public let kind: Kind
    public let bytes: Int64
    /// 这是什么（缓存、设置、应用数据……）
    public let what: String

    public var id: String { url.path }
}

public struct UninstallPlan: Sendable {
    public let app: AppInfo
    public let items: [UninstallItem]
    /// 需要特别告诉你的事，比如“还装着另一份同样的 App，所以只移走这一份”
    public var note: String?

    public init(app: AppInfo, items: [UninstallItem], note: String? = nil) {
        self.app = app
        self.items = items
        self.note = note
    }

    public var removableBytes: Int64 { items.filter { $0.kind.removable }.reduce(0) { $0 + $1.bytes } }
}

public enum UninstallPlanner {
    /// 找出 App 的所有相关文件，并分好组
    /// - library：用户资料库（测试时换成临时目录）
    /// - systemLibrary：系统资料库 /Library（测试时换成临时目录）
    /// - installedIDs：其他已安装 App 的 ID，用来判断共享文件
    /// - otherCopies：还装着的、同一个 ID 的其他副本（不传就现查）
    public static func plan(for app: AppInfo,
                            library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
                            systemLibrary: URL = URL(fileURLWithPath: "/Library"),
                            installedIDs: Set<String>? = nil,
                            otherCopies: [URL]? = nil) -> UninstallPlan {
        let fm = FileManager.default
        let sizes = SizeCalculator()

        // 还装着另一份同 ID 的 App（比如 Claude 和它的旧版备份）：相关文件是另一份在用的，一个都不能动
        let copies = otherCopies ?? AppCatalog.otherCopies(of: app)
        if !copies.isEmpty {
            let bundle = UninstallItem(url: app.url, kind: .bundle, bytes: sizes.size(of: app.url), what: "App 本体")
            return UninstallPlan(app: app, items: app.url.path.contains("/.Trash/") ? [] : [bundle],
                                 note: L("还装着另一份同样的 App（%@），缓存和设置是它在用的，所以只移走这一份 App，相关文件都不动",
                                         copies.map(\.lastPathComponent).joined(separator: L("、"))))
        }
        var found: [URL: (UninstallItem.Kind, String)] = [:]
        func add(_ url: URL, _ kind: UninstallItem.Kind, _ what: String) {
            guard fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil else { return }
            // 同一个位置被几种方式找到时，取最保守的那种（编号大的）
            if let old = found[url], old.0 >= kind { return }
            found[url] = (kind, what)
        }
        func list(_ dir: URL) -> [String] { (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] }

        add(app.url, .bundle, "App 本体")

        let appFile = app.url.deletingPathExtension().lastPathComponent.lowercased()
        let names = Set([app.name.lowercased(), appFile]).filter { $0.count >= 3 }
        let otherIDs = (installedIDs ?? AppInventory.scan().ids).subtracting([app.bundleID?.lowercased() ?? ""])

        if let id = app.bundleID?.lowercased(), id.split(separator: ".").count >= 2 {
            /// 文件名是这个 ID，或者以 “ID.” 开头（比如 com.foo.app.ShipIt），而且不是别的已装 App 的 ID
            func isOurs(_ name: String, ext: String = "") -> Bool {
                var n = name.lowercased()
                if !ext.isEmpty, n.hasSuffix(ext) { n = String(n.dropLast(ext.count)) }
                guard n == id || n.hasPrefix(id + ".") else { return false }
                return !otherIDs.contains { $0 != id && (n == $0 || n.hasPrefix($0 + ".")) && $0.count > id.count }
            }
            let byID: [(String, String, String)] = [
                ("Caches", "", "缓存"), ("Preferences", ".plist", "设置"), ("Saved Application State", ".savedstate", "窗口状态"),
                ("HTTPStorages", "", "网络缓存"), ("HTTPStorages", ".binarycookies", "网络缓存"), ("WebKit", "", "网页缓存"),
                ("Logs", "", "日志"), ("Application Scripts", "", "脚本"), ("Cookies", ".binarycookies", "Cookie"),
            ]
            for (sub, ext, what) in byID {
                let dir = library.appendingPathComponent(sub)
                for n in list(dir) where isOurs(n, ext: ext) { add(dir.appendingPathComponent(n), .matched, what) }
            }
            for (sub, what) in [("Application Support", "应用数据"), ("Containers", "应用数据（沙盒）")] {
                let dir = library.appendingPathComponent(sub)
                for n in list(dir) where isOurs(n) { add(dir.appendingPathComponent(n), .userData, what) }
            }
            // 共享容器（Group Containers）：同一厂商还有别的 App 在用就不能删
            let vendor = id.split(separator: ".").prefix(2).joined(separator: ".")
            let vendorStillUsed = otherIDs.contains { $0.hasPrefix(vendor + ".") }
            let groups = library.appendingPathComponent("Group Containers")
            for n in list(groups) {
                // 去掉开头的团队编号（如 8T9NQJXDU3.）和 group.，剩下的是共享容器的 ID
                var gid = n.lowercased()
                if let dot = gid.firstIndex(of: "."), gid[..<dot].count == 10 { gid = String(gid[gid.index(after: dot)...]) }
                if gid.hasPrefix("group.") { gid = String(gid.dropFirst(6)) }
                // 明确属于别的已装 App 的（比如钉钉旁边的通义千问），不列出来
                if otherIDs.contains(where: { gid == $0 || gid.hasPrefix($0 + ".") }) && !gid.hasPrefix(id) { continue }
                guard gid.hasPrefix(id) || gid.hasPrefix(vendor + ".") else { continue }
                add(groups.appendingPathComponent(n), vendorStillUsed ? .shared : .userData,
                    vendorStillUsed ? "同一厂商其他 App 还在用的共享数据" : "共享数据")
            }
        }

        // 按 App 名字猜的：Application Support、Caches、Logs 里和 App 同名的文件夹
        for (sub, kind, what) in [("Application Support", UninstallItem.Kind.userData, "应用数据"),
                                  ("Caches", .guessed, "缓存（按名字找到的）"),
                                  ("Logs", .guessed, "日志（按名字找到的）")] {
            let dir = library.appendingPathComponent(sub)
            for n in list(dir) {
                let lower = n.lowercased()
                if names.contains(lower) {
                    add(dir.appendingPathComponent(n), kind == .userData ? .userData : .guessed, what)
                } else if names.contains(where: { looksRelated(lower, to: $0) }) {
                    add(dir.appendingPathComponent(n), .guessed, "名字相近，不确定是不是它的")
                }
            }
        }

        // 开机自启项：文件名对得上 ID，或者实际启动的程序在这个 App 里面
        for (dir, kind) in [(library.appendingPathComponent("LaunchAgents"), UninstallItem.Kind.launchAgent),
                            (systemLibrary.appendingPathComponent("LaunchAgents"), .systemLevel),
                            (systemLibrary.appendingPathComponent("LaunchDaemons"), .systemLevel)] {
            for n in list(dir) where n.hasSuffix(".plist") {
                let url = dir.appendingPathComponent(n)
                if launchItem(url, belongsTo: app) {
                    add(url, kind, kind == .launchAgent ? "开机自启项" : "系统级后台服务（需要管理员权限）")
                }
            }
        }
        // 系统级的只是告诉你、不会动，所以放宽到同一厂商（比如 Docker 的 com.docker.vmnetd）
        if let id = app.bundleID?.lowercased(), id.split(separator: ".").count >= 3 {
            let vendor = id.split(separator: ".").prefix(2).joined(separator: ".") + "."
            for (sub, what) in [("LaunchAgents", "系统级后台服务（需要管理员权限）"),
                                ("LaunchDaemons", "系统级后台服务（需要管理员权限）"),
                                ("PrivilegedHelperTools", "系统级辅助程序（需要管理员权限）")] {
                let dir = systemLibrary.appendingPathComponent(sub)
                for n in list(dir) where n.lowercased().hasPrefix(vendor) {
                    add(dir.appendingPathComponent(n), .systemLevel, what)
                }
            }
        }

        let items = found.map { url, v in
            UninstallItem(url: url, kind: v.0, bytes: sizes.size(of: url), what: v.1)
        }
        .sorted { ($0.kind, -$0.bytes) < ($1.kind, -$1.bytes) }
        return UninstallPlan(app: app, items: items)
    }

    /// 文件夹名是不是“App 名 + 后缀”，比如 Docker Desktop、DingTalkMac、zoom.us。
    /// 后缀必须是分隔符开头，或者常见的后缀词；不然 Code（VS Code）会把 Codex 也算进来
    static func looksRelated(_ folder: String, to name: String) -> Bool {
        guard folder.hasPrefix(name), folder != name else { return false }
        let rest = folder.dropFirst(name.count)
        if let first = rest.first, " -_.".contains(first) { return rest.count <= 16 }
        return ["mac", "app", "desktop", "helper", "pro", "beta", "cn", "intl"].contains(String(rest))
    }

    /// 开机自启项是不是这个 App 的：Label 对得上 ID，或者启动的程序路径在 App 里面
    static func launchItem(_ plist: URL, belongsTo app: AppInfo) -> Bool {
        let file = plist.deletingPathExtension().lastPathComponent.lowercased()
        if let id = app.bundleID?.lowercased(), file == id || file.hasPrefix(id + ".") { return true }
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        if let id = app.bundleID?.lowercased(), let label = (dict["Label"] as? String)?.lowercased(),
           label == id || label.hasPrefix(id + ".") { return true }
        let programs = [dict["Program"] as? String].compactMap { $0 } + ((dict["ProgramArguments"] as? [String])?.prefix(1) ?? [])
        return programs.contains { $0.hasPrefix(app.url.path + "/") }
    }
}

// MARK: - 执行卸载

public enum Uninstaller {
    private static let recentLock = NSLock()
    nonisolated(unsafe) private static var recent: [String: Date] = [:]

    /// 这个 App 是不是 MacSweeper 刚刚自己卸载的（5 分钟内，按原来的位置记）
    public static func wasRemovedByUs(_ url: URL) -> Bool {
        recentLock.lock(); defer { recentLock.unlock() }
        return recent[url.standardizedFileURL.path].map { Date().timeIntervalSince($0) < 300 } ?? false
    }

    /// 卸载：只移到废纸篓。执行前再检查一遍（受保护、正在运行），开机自启项先停掉
    public static func uninstall(_ plan: UninstallPlan, selected: Set<URL>) -> CleanReport {
        var report = CleanReport()
        let app = AppCatalog.info(for: plan.app.url)
        if app.protection != nil {
            report.failures.append((app.url.path, L("这个 App 受保护，不能卸载")))
            return report
        }
        if let id = app.bundleID, !RunningSnapshot.current().apps(forBundleIDs: [id]).isEmpty {
            report.failures.append((app.url.path, L("%@ 正在运行，请先退出", app.name)))
            return report
        }
        // App 本体一定在里面；其余只处理勾选了的、允许删除的
        let chosen = plan.items.filter { $0.kind == .bundle || ($0.kind.removable && selected.contains($0.url)) }
        // 先停掉开机自启项，免得 App 删了后台程序还在跑
        for item in chosen where item.kind == .launchAgent { stopLaunchAgent(item.url) }

        // 先删相关文件，最后删 App 本体：App 本体失败（比如要密码你取消了）时，其余已经在废纸篓，可以撤销
        for item in chosen.sorted(by: { $0.kind > $1.kind }) {
            let allowed = item.kind == .bundle ? PathGuard.isAllowedApp(item.url) : PathGuard.isAllowed(item.url)
            guard allowed else {
                report.failures.append((item.url.path, L("不在允许范围内")))
                continue
            }
            if let moved = trash(item.url) {
                if item.kind == .bundle {
                    recentLock.lock(); recent[item.url.standardizedFileURL.path] = Date(); recentLock.unlock()
                }
                report.trashedCount += 1
                report.trashedBytes += item.bytes
                report.moves.append(TrashMove(original: item.url.path, inTrash: moved.path, bytes: item.bytes))
                OperationLog.write("UNINSTALL \(item.bytes) \(item.url.path)")
            } else {
                report.failures.append((item.url.path, item.kind == .bundle && app.needsPassword
                    ? L("需要电脑密码，你取消了或者没有权限。可以在访达里把它拖到废纸篓")
                    : L("没能移到废纸篓")))
            }
        }
        if !report.moves.isEmpty { Undo.save(TrashBatch(date: Date(), moves: report.moves)) }
        return report
    }

    /// 移到废纸篓，返回在废纸篓里的位置。普通文件直接移；归系统所有的 App 交给系统处理，系统会弹出密码框
    static func trash(_ url: URL) -> URL? {
        var inTrash: NSURL?
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: &inTrash)) != nil {
            return inTrash as URL?
        }
        // 需要权限：用 NSWorkspace，和在访达里拖到废纸篓一样，由 macOS 弹出它自己的密码框
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

    static func stopLaunchAgent(_ plist: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())", plist.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

extension PathGuard {
    /// 能卸载的 App：只限“应用程序”文件夹（和下一层）、你自己的 ~/Applications，必须是 .app，不能是苹果自带的
    public static func isAllowedApp(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasSuffix(".app"), !path.split(separator: "/").contains("..") else { return false }
        let roots = ["/Applications/", home + "/Applications/"]
        guard let root = roots.first(where: { path.hasPrefix($0) }) else { return false }
        let depth = path.dropFirst(root.count).split(separator: "/").count
        guard depth == 1 || depth == 2 else { return false }
        let id = (AppCatalog.infoPlist(url)["CFBundleIdentifier"] as? String)?.lowercased() ?? ""
        return !id.hasPrefix("com.apple.")
    }
}
