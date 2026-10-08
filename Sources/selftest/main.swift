// 自检程序：检查清理工具里和安全相关的关键逻辑。
// 运行：./scripts/selftest.sh（不需要 Xcode）。每次改了 SweeperCore 都跑一遍。
// 所有测试文件都建在临时目录里，不碰你的真实文件，也不会往废纸篓里放东西。
import Foundation
@testable import SweeperCore

var passed = 0
var failed: [String] = []

func check(_ ok: Bool, _ what: String) {
    if ok { passed += 1 } else { failed.append(what) }
}

func group(_ title: String, _ body: () throws -> Void) {
    print("· \(title)")
    do { try body() } catch { failed.append("\(title)：出错 \(error)") }
}

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let sandbox = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macsweeper-selftest-\(UUID().uuidString)")
try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: sandbox) }   // 临时目录里的测试文件，用完删掉

/// 在临时目录里建文件（自动建上级文件夹），可以指定大小和修改时间
@discardableResult
func makeFile(_ rel: String, bytes: Int = 10, daysAgo: Double = 0) -> URL {
    let url = sandbox.appendingPathComponent(rel)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: Data(count: bytes))
    let date = Date().addingTimeInterval(-daysAgo * 86_400)
    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
}

func makeDir(_ rel: String) -> URL {
    let url = sandbox.appendingPathComponent(rel)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - 安全护栏

group("安全护栏：哪些路径允许清理") {
    let ok = { PathGuard.isAllowed(URL(fileURLWithPath: $0)) }
    check(!ok(home), "主目录本身不能删")
    check(!ok(home + "/Library"), "~/Library 本身不能删")
    check(!ok(home + "/Library/Caches"), "~/Library/Caches 本身不能删")
    check(!ok(home + "/Desktop"), "桌面本身不能删")
    check(!ok(home + "/Documents"), "文稿本身不能删")
    check(!ok(home + "/.Trash"), "废纸篓本身不能删")
    check(ok(home + "/Library/Caches/com.example.app"), "缓存里的子文件夹可以删")
    check(!ok("/Applications/Example.app"), "主目录以外不能删")
    check(!ok("/System/Library"), "系统目录不能删")
    check(!ok(home + "/Library/Caches/../../Desktop"), "带 .. 的路径不能删")
    check(!ok(home + "x/evil"), "名字以主目录开头的别的目录不能删")
}

// MARK: - 已卸载 App 的残留判断

group("残留判断：从文件夹名读出 App ID") {
    check(LeftoverFinder.bundleID(fromName: "com.foo.bar.plist", isGroup: false) == "com.foo.bar", "去掉 .plist")
    check(LeftoverFinder.bundleID(fromName: "com.foo.bar.savedState", isGroup: false) == "com.foo.bar", "去掉 .savedState")
    check(LeftoverFinder.bundleID(fromName: "Google", isGroup: false) == nil, "普通名字不当成 App ID")
    check(LeftoverFinder.bundleID(fromName: "com.foo", isGroup: false) == nil, "只有两段的不算")
    check(LeftoverFinder.bundleID(fromName: "UBF8T346G9.com.foo.shared", isGroup: true) == "com.foo.shared", "去掉团队编号")
    check(LeftoverFinder.bundleID(fromName: "group.com.foo.app", isGroup: true) == "com.foo.app", "去掉 group.")
}

group("残留判断：还装着的 App 不能当残留") {
    let installed: Set<String> = ["com.docker.docker", "com.bytedance.macos.feishu"]
    let names: Set<String> = ["lark", "docker"]
    check(LeftoverFinder.belongsToInstalled("com.docker.install", installed, names), "同一厂商还有 App（Docker）")
    check(LeftoverFinder.belongsToInstalled("com.electron.lark.font", installed, names), "名字对得上已安装的 App（Lark）")
    check(!LeftoverFinder.belongsToInstalled("com.baidu.netdisk", installed, names), "真正卸载了的才算残留")
    check(LeftoverFinder.isAppleOrSystem("com.apple.finder"), "苹果自己的不碰")
}

// MARK: - 查找

group("通配：*.backup-* 这类写法") {
    makeFile("codex/logs.sqlite.backup-2026")
    makeFile("codex/logs.sqlite")
    makeFile("codex/.hidden.backup-1")
    let found = PathPattern.expand(sandbox.path + "/codex/*.backup-*").map(\.lastPathComponent)
    check(found == ["logs.sqlite.backup-2026"], "只匹配备份文件，不匹配原文件和隐藏文件（实际：\(found)）")
}

group("浏览器缓存：只删缓存，不碰网站数据") {
    let profile = "chrome/Default"
    makeFile("\(profile)/Preferences")
    makeFile("\(profile)/Cache/data_0")
    makeFile("\(profile)/Service Worker/CacheStorage/abc")
    makeFile("\(profile)/Service Worker/Database/db")
    makeFile("\(profile)/Cookies")
    makeFile("\(profile)/IndexedDB/site/db")
    makeFile("chrome/Default/Partitions/inner/Preferences")
    makeFile("chrome/Default/Partitions/inner/Cache/x")
    let found = Set(ChromiumCacheFinder.find(roots: [sandbox.path + "/chrome"], excluding: [])
        .map { String($0.path.dropFirst(sandbox.path.count + 1)) })
    check(found.contains("\(profile)/Cache"), "找到 Cache")
    check(found.contains("\(profile)/Service Worker/CacheStorage"), "找到 Service Worker 缓存")
    check(found.contains("chrome/Default/Partitions/inner/Cache"), "找到嵌套的子浏览器缓存")
    check(!found.contains { $0.contains("Database") || $0.contains("Cookies") || $0.contains("IndexedDB") },
          "不碰 Cookie、数据库、网站数据")
}

group("旧版本：只保留最新版（按数字比较版本号）") {
    for v in ["2.1.9", "2.1.10", "2.1.288"] { makeFile("versions/\(v)/bin") }
    let old = VersionFinder.olderVersions(in: [sandbox.path + "/versions"]).map(\.url.lastPathComponent).sorted()
    check(old == ["2.1.10", "2.1.9"], "2.1.288 是最新的，要保留（实际列出：\(old)）")
}

group("失效的命令链接") {
    let bin = makeDir("bin")
    let target = makeFile("real-tool")
    try fm.createSymbolicLink(atPath: bin.path + "/good", withDestinationPath: target.path)
    try fm.createSymbolicLink(atPath: bin.path + "/broken", withDestinationPath: "/Applications/NotHere.app/x")
    let found = BrokenLinkFinder.find(in: [bin.path]).map(\.url.lastPathComponent)
    check(found == ["broken"], "只列出指向不存在文件的链接（实际：\(found)）")
}

group("装着命令行工具的文件夹不当残留") {
    makeFile("deskclaw/node/bin/claude")
    makeFile("plain/settings.json")
    check(ToolTraceFinder.containsCommandLineTools(sandbox.appendingPathComponent("deskclaw")), "有 bin 目录的要保护")
    check(!ToolTraceFinder.containsCommandLineTools(sandbox.appendingPathComponent("plain")), "普通文件夹不受影响")
}

group("项目：依赖目录和最后活跃时间") {
    makeFile("proj/package.json", daysAgo: 100)
    makeFile("proj/src/app.js", daysAgo: 90)
    makeFile("proj/node_modules/lib/index.js", daysAgo: 1)   // 依赖是新装的，但不算项目有改动
    makeFile("proj/target/out.txt", daysAgo: 95)             // 旁边没有 Cargo.toml，不算依赖
    makeFile("proj/rust/Cargo.toml", daysAgo: 95)
    makeFile("proj/rust/target/debug/app", daysAgo: 95)
    makeFile("proj/.git/HEAD", daysAgo: 0)                   // .git 不算改动
    let p = ProjectFinder.inspect(sandbox.appendingPathComponent("proj"))
    let deps = Set(p.dependencies.map { String($0.path.dropFirst(sandbox.path.count + 1)) })
    check(deps == ["proj/node_modules", "proj/rust/target"], "依赖目录判断正确（实际：\(deps)）")
    let days = Date().timeIntervalSince(p.lastActive) / 86_400
    check(days > 89 && days < 91, "最后活跃时间来自源代码，不受依赖和 .git 影响（实际：\(Int(days)) 天前）")
}

// MARK: - 大小计算

group("大小计算：记住结果后，上级文件夹的总数仍然正确") {
    makeFile("size/a/one", bytes: 100_000)
    makeFile("size/a/two", bytes: 200_000)
    makeFile("size/b/three", bytes: 300_000)
    let fresh = SizeCalculator().size(of: sandbox.appendingPathComponent("size"))
    let reused = SizeCalculator()
    let partA = reused.size(of: sandbox.appendingPathComponent("size/a"))
    let total = reused.size(of: sandbox.appendingPathComponent("size"))
    check(fresh >= 600_000, "总大小至少是文件大小之和（实际：\(fresh)）")
    check(total == fresh, "先算子文件夹再算上级，结果和直接算一样（\(total) vs \(fresh)）")
    check(partA < total, "子文件夹比上级小")
    let link = sandbox.appendingPathComponent("size/link")
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: sandbox.appendingPathComponent("size/b").path)
    check(SizeCalculator().size(of: sandbox.appendingPathComponent("size")) == fresh, "不跟随符号链接，不重复计算")
}

// MARK: - 去重

group("去重：同一个文件不在两条规则里重复计算") {
    func rule(_ id: String, _ safety: Safety) -> Rule {
        Rule(id: id, name: id, category: "测试", safety: safety, detail: "", target: .paths([]))
    }
    func item(_ path: String) -> Item { Item(url: URL(fileURLWithPath: path), bytes: 1, modified: nil, label: nil) }
    func result(_ r: Rule, _ paths: [String]) -> ScanResult {
        ScanResult(rule: r, items: paths.map(item), unreadable: [], blocker: nil, skippedRunning: [])
    }
    let out = Scanner.dedupe([
        result(rule("parent", .safe), ["/x/a"]),
        result(rule("child", .review), ["/x/a/b", "/x/c"]),
        result(rule("same", .review), ["/x/c"]),
        result(rule("report", .reportOnly), ["/x/a/b"]),
    ])
    check(out[1].items.map(\.url.path) == ["/x/c"], "被别的规则整个包含的去掉")
    check(out[2].items.isEmpty, "完全相同的只留在前面那条")
    check(out[3].items.count == 1, "“只报告”的规则不受影响")
}

// MARK: - 最短保留天数、运行检查

group("最短保留天数：太新的备份不列出") {
    makeFile("backups/old.backup-1", daysAgo: 30)
    makeFile("backups/new.backup-2", daysAgo: 1)
    let r = Rule(id: "t", name: "t", category: "测试", safety: .reportOnly, detail: "",
                 target: .paths([sandbox.path + "/backups/*.backup-*"]), minAgeDays: 7)
    let names = Scanner.scan(rule: r).items.map(\.url.lastPathComponent)
    check(names == ["old.backup-1"], "7 天内的不列出（实际：\(names)）")
}

group("运行检查：真实系统") {
    check(RunningApps.blocker(for: ["process:launchd"]) != nil, "能发现正在运行的命令行程序（包括上级进程）")
    check(RunningApps.blocker(for: ["com.example.not-installed"]) == nil, "没运行的不挡")
    check(RunningApps.blocker(for: []) == nil, "没要求退出的不挡")
}

group("运行检查：文件夹属于哪个 App（用假数据，不受电脑上开了什么影响）") {
    func app(_ id: String?, _ name: String, exe: String? = nil, ui: Bool = true) -> RunningApp {
        RunningApp(pid: 1, bundleID: id, name: name, bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                   executableName: exe, hasUI: ui)
    }
    let snap = RunningSnapshot(apps: [
        app("com.tencent.xinWeChat", "微信", exe: "WeChat"),
        app("com.electron.lark", "Lark"),
        app("com.apple.finder", "Finder"),
        app("com.example.helper", "Helper", ui: false),
    ], processNames: ["codex", "zsh"])
    let lib = home + "/Library"
    let owner = { snap.owner(of: URL(fileURLWithPath: lib + $0)) }
    check(owner("/Containers/com.tencent.xinWeChat/Data/Library/Caches/profiles") == "微信",
          "沙盒里的缓存认成微信（路径里有两段 Library 也不认错）")
    check(owner("/Application Support/LarkInternational/Cache") == "Lark", "按名字认出 LarkInternational 属于 Lark")
    check(owner("/Caches/com.tencent.xinWeChat.helper") == "微信", "辅助程序的文件夹也算")
    check(owner("/Caches/Finder") == nil, "苹果自己的 App 不参与")
    check(owner("/Caches/Helper") == nil, "后台服务不参与")
    check(owner("/Caches/com.google.Chrome") == nil, "没在运行的不挡")
    check(snap.blocker(for: ["process:codex"]) == "命令行 codex", "命令行程序能发现")
    check(snap.blocker(for: ["COM.TENCENT.XINWECHAT"]) == "微信", "Bundle ID 不分大小写")
    check(snap.apps(forBundleIDs: ["process:codex", "com.electron.lark"]).map(\.name) == ["Lark"],
          "能帮你退出的只算有界面的 App，不算命令行程序")
}

// MARK: - 撤销

group("撤销：从废纸篓放回原处") {
    // 用临时目录里的“假废纸篓”，不碰你真正的废纸篓
    let a = makeFile(".Trash/cache-a", bytes: 50)
    let b = makeFile(".Trash/cache-b")
    makeFile("restore/occupied")                       // 原位置已经有同名文件
    let moves = [
        TrashMove(original: sandbox.path + "/restore/deep/cache-a", inTrash: a.path, bytes: 50),
        TrashMove(original: sandbox.path + "/restore/occupied", inTrash: b.path, bytes: 10),
        TrashMove(original: sandbox.path + "/restore/gone", inTrash: sandbox.path + "/.Trash/emptied", bytes: 10),
        TrashMove(original: sandbox.path + "/restore/x", inTrash: sandbox.path + "/not-trash/x", bytes: 10),
    ]
    let r = Undo.restore(moves, allowed: { _ in true })
    check(fm.fileExists(atPath: sandbox.path + "/restore/deep/cache-a"), "放回原处，缺的上级文件夹会补上")
    check(!fm.fileExists(atPath: a.path), "废纸篓里的那份移走了")
    check(r.restoredCount == 1 && r.restoredBytes == 50, "统计还原了 1 个")
    check(r.occupiedCount == 1 && fm.fileExists(atPath: b.path), "原位置有东西就不覆盖，留在废纸篓")
    check(r.goneCount == 1, "废纸篓已清空的算“找不到”")
    check(r.failures.count == 1, "来源不在废纸篓里的不处理")
    let blocked = Undo.restore([TrashMove(original: "/System/x", inTrash: b.path, bytes: 1)])
    check(blocked.failures.count == 1 && fm.fileExists(atPath: b.path), "不往主目录以外放")
}

// MARK: - 移到废纸篓（统一入口）和撤销历史

group("移到废纸篓：统一入口的安全护栏") {
    // 临时目录不在主目录里，必须被拒绝；什么都不会动
    let outside = makeFile("outside.bin", bytes: 100)
    let session = TrashSession(kind: .clean, title: "测试")
    check(session.trash(outside, bytes: 100) == nil && fm.fileExists(atPath: outside.path), "主目录以外的文件拒绝移动")
    check(session.trash(URL(fileURLWithPath: home + "/Desktop"), bytes: 1) == nil, "桌面这种受保护的文件夹本身拒绝移动")
    check(session.trash(URL(fileURLWithPath: home + "/Library/Caches/x.app"), bytes: 1, target: .app) == nil,
          "App 只允许在“应用程序”里（文件不存在也先被护栏挡住）")
    let r = session.finish()
    check(r.trashedCount == 0 && r.failures.count == 3 && r.batchID == nil, "没移走任何东西时不写撤销记录")
}

group("移到废纸篓 → 撤销：真实走一遍（主目录里的小文件）") {
    // 唯一会碰真实废纸篓的测试：在 ~/Library/Caches 建一个 1 字节的文件，移进废纸篓再放回来，最后删掉
    let dir = URL(fileURLWithPath: home + "/Library/Caches/macsweeper-selftest-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent("tiny")
    fm.createFile(atPath: file.path, contents: Data([1]))
    let rule = Rule(id: "selftest", name: "自检", category: "测试", safety: .review, detail: "", target: .paths([file.path]))
    let report = Cleaner.moveToTrash([Scanner.scan(rule: rule)])
    check(report.trashedCount == 1 && !fm.fileExists(atPath: file.path), "清理垃圾的路径能把文件移进废纸篓")
    check(report.batchID != nil && Undo.history().contains { $0.id == report.batchID }, "写进了撤销历史")
    let undo = report.batchID.flatMap { Undo.restore(id: $0) }
    check(undo?.restoredCount == 1 && fm.fileExists(atPath: file.path), "按编号撤销，文件回到原处")
    check(!Undo.history().contains { $0.id == report.batchID }, "撤销后记录从历史里去掉")
}

group("撤销历史：多条记录各自撤销，旧版记录能迁移") {
    // 用假废纸篓文件造几条记录（不碰真实废纸篓）
    let t = makeDir("HistTrash/.Trash")
    func batch(_ title: String, _ name: String) -> TrashBatch {
        makeFile("HistTrash/.Trash/\(name)")
        return TrashBatch(kind: .uninstall, title: title,
                          moves: [TrashMove(original: sandbox.path + "/restore2/\(name)", inTrash: t.appendingPathComponent(name).path, bytes: 1)])
    }
    let first = batch("卸载 A", "a"), second = batch("清理 B", "b")
    Undo.save(first); Undo.save(second)
    let ids = Undo.history().map(\.id)
    check(ids.firstIndex(of: second.id)! < ids.firstIndex(of: first.id)!, "最近的在前，两条都在")
    // 撤销较早的那条，不影响较晚的
    let r = Undo.restore(first.moves, allowed: { _ in true })
    check(r.restoredCount == 1 && fm.fileExists(atPath: sandbox.path + "/restore2/a"), "能单独撤销较早的一条")
    // 清掉测试记录
    for id in [first.id, second.id] { _ = Undo.restore(id: id) }
    check(!Undo.history().contains { [first.id, second.id].contains($0.id) }, "测试记录已清掉")
    // 旧版 last-clean.json 没有 id/kind/title，读出来要能补上
    let legacy = Data(#"{"date":"2026-10-07T00:00:00Z","moves":[]}"#.utf8)
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    let old = try d.decode(TrashBatch.self, from: legacy)
    check(old.kind == .clean && old.title == "清理垃圾", "旧版记录按“清理垃圾”读入")
}

// MARK: - 自定义规则

group("自定义规则：读取和检查") {
    let json = """
    [
      {"name": "好的", "contents": "~/Library/Caches/foo", "safety": "safe", "quitApps": ["com.x"]},
      {"name": "默认需确认", "paths": ["~/a/*.log"]},
      {"name": "按扩展名", "files": {"in": "~/Downloads", "extensions": ["ZIP"]}},
      {"name": "停用的", "paths": ["~/x"], "enabled": false},
      {"name": "两个目标", "paths": ["~/x"], "contents": "~/y"},
      {"name": "主目录外", "paths": ["/System/Library"]},
      {"name": "等级写错", "paths": ["~/x"], "safety": "danger"}
    ]
    """
    let r = CustomRules.parse(Data(json.utf8))
    check(r.rules.map(\.name) == ["好的", "默认需确认", "按扩展名"], "合格的规则读进来，停用的跳过（实际：\(r.rules.map(\.name))）")
    check(r.rules.first?.safety == .safe && r.rules.first?.quitApps == ["com.x"], "安全等级和要退出的 App 读对了")
    check(r.rules.dropFirst().first?.safety == .review, "没写等级的默认“需确认”")
    if case let .files(_, exts) = r.rules.last?.target { check(exts == ["zip"], "扩展名统一小写") } else { check(false, "按扩展名的规则类型不对") }
    check(r.problems.count == 3, "三条有问题的都报出来了（实际：\(r.problems)）")
    check(r.problems.contains { $0.contains("主目录外") && $0.contains("~/") }, "主目录以外的路径会被拒绝")
    let broken = CustomRules.parse(Data("[{\"name\": \"少逗号\" \"paths\": []}]".utf8))
    check(broken.rules.isEmpty && broken.problems.first?.contains("不是有效的 JSON") == true, "格式错误时给出看得懂的提示")
    let template = CustomRules.parse(Data(CustomRules.template.utf8))
    check(template.problems.isEmpty && template.rules.isEmpty, "示例文件本身格式正确，而且默认停用")
}

// MARK: - 卸载 App

group("卸载：相关文件的分组") {
    // 一个假的 App：Demo.app，ID 是 com.test.demo
    let appURL = makeDir("Apps/Demo.app/Contents")
        .deletingLastPathComponent()
    try (["CFBundleIdentifier": "com.test.demo", "CFBundleName": "Demo"] as NSDictionary)
        .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    let lib = "Lib/"
    makeFile(lib + "Caches/com.test.demo/a")                       // ID 对得上 → 默认勾选
    makeFile(lib + "Caches/com.test.demo.ShipIt/a")                // ID. 开头 → 默认勾选
    makeFile(lib + "Caches/com.test.demoother/a")                  // 只是开头像，不算
    makeFile(lib + "Caches/com.test.demo.helper/a")                // 属于另一个已装的 App，不算
    makeFile(lib + "Preferences/com.test.demo.plist")
    makeFile(lib + "Application Support/com.test.demo/db")         // 可能有数据 → 默认不勾
    makeFile(lib + "Application Support/Demo/db")                  // 和 App 同名 → 默认不勾
    makeFile(lib + "Application Support/DemoMac/db")               // 名字相近 → 不确定
    makeFile(lib + "Application Support/Democracy/db")             // 名字只是碰巧开头一样，不算
    makeFile(lib + "Group Containers/ABCDE12345.com.test.shared/x")   // 同厂商还有别的 App → 共享，不能删
    makeFile(lib + "Group Containers/ABCDE12345.com.test.other.g/x")  // 明确属于别的 App → 不列
    try (["Label": "com.test.demo.agent"] as NSDictionary)
        .write(to: makeDir(lib + "LaunchAgents").appendingPathComponent("com.test.demo.agent.plist"))
    try (["Label": "netdisk", "ProgramArguments": [appURL.path + "/Contents/MacOS/helper"]] as NSDictionary)
        .write(to: sandbox.appendingPathComponent(lib + "LaunchAgents/netdisk.plist"))   // 名字看不出来，但启动的是它
    try (["Label": "other", "ProgramArguments": ["/usr/bin/true"]] as NSDictionary)
        .write(to: sandbox.appendingPathComponent(lib + "LaunchAgents/other.plist"))
    makeFile("SysLib/LaunchDaemons/com.test.daemon.plist")         // 系统级 → 只告诉你

    let app = AppInfo(url: appURL, name: "Demo", bundleID: "com.test.demo", version: nil, lastUsed: nil,
                      protection: nil, needsPassword: false, homebrewCask: nil)
    let plan = UninstallPlanner.plan(for: app, library: sandbox.appendingPathComponent("Lib"),
                                     systemLibrary: sandbox.appendingPathComponent("SysLib"),
                                     installedIDs: ["com.test.other", "com.test.demo.helper"])
    let kinds = Dictionary(plan.items.map { (String($0.url.path.dropFirst(sandbox.path.count + 1)), $0.kind) },
                           uniquingKeysWith: { a, _ in a })
    let expect: [String: UninstallItem.Kind] = [
        "Apps/Demo.app": .bundle,
        "Lib/Caches/com.test.demo": .matched, "Lib/Caches/com.test.demo.ShipIt": .matched,
        "Lib/Preferences/com.test.demo.plist": .matched,
        "Lib/Application Support/com.test.demo": .userData, "Lib/Application Support/Demo": .userData,
        "Lib/Application Support/DemoMac": .guessed,
        "Lib/Group Containers/ABCDE12345.com.test.shared": .shared,
        "Lib/LaunchAgents/com.test.demo.agent.plist": .launchAgent, "Lib/LaunchAgents/netdisk.plist": .launchAgent,
        "SysLib/LaunchDaemons/com.test.daemon.plist": .systemLevel,
    ]
    for (path, kind) in expect { check(kinds[path] == kind, "\(path) 应该是 \(kind)（实际：\(String(describing: kinds[path]))）") }
    for path in ["Lib/Caches/com.test.demoother", "Lib/Caches/com.test.demo.helper", "Lib/Application Support/Democracy",
                 "Lib/Group Containers/ABCDE12345.com.test.other.g", "Lib/LaunchAgents/other.plist"] {
        check(kinds[path] == nil, "\(path) 不属于它，不该列出来")
    }
    check(plan.items.filter { $0.kind.selectedByDefault }.allSatisfy { [.bundle, .matched, .launchAgent].contains($0.kind) },
          "默认勾选的只有 App 本体、ID 对得上的、开机自启项")
    check(!UninstallItem.Kind.shared.removable && !UninstallItem.Kind.systemLevel.removable, "共享的和系统级的不能删")
}

group("卸载：还装着另一份同 ID 的 App 时，相关文件一个都不动") {
    let appURL = sandbox.appendingPathComponent("Apps/Demo.app")
    let app = AppInfo(url: appURL, name: "Demo", bundleID: "com.test.demo", version: nil, lastUsed: nil,
                      protection: nil, needsPassword: false, homebrewCask: nil)
    let plan = UninstallPlanner.plan(for: app, library: sandbox.appendingPathComponent("Lib"),
                                     systemLibrary: sandbox.appendingPathComponent("SysLib"),
                                     installedIDs: [], otherCopies: [URL(fileURLWithPath: "/Applications/Demo 2.app")])
    check(plan.items.map(\.kind) == [.bundle], "只移走这一份 App 本体（实际：\(plan.items.map(\.kind))）")
    check(plan.note?.contains("Demo 2.app") == true, "告诉你原因")
}

group("拖进废纸篓：发现从“应用程序”里移走的 App") {
    let apps = makeDir("WatchApps")
    func makeApp(_ name: String, _ id: String) throws {
        let c = apps.appendingPathComponent("\(name).app/Contents")
        try fm.createDirectory(at: c, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": id, "CFBundleName": name] as NSDictionary).write(to: c.appendingPathComponent("Info.plist"))
    }
    try makeApp("Keep", "com.test.keep")
    try makeApp("Gone", "com.test.gone")
    try makeApp("Update", "com.test.update")
    final class Box: @unchecked Sendable { var names: [String] = []; let lock = NSLock() }
    let box = Box()
    let seen = DispatchSemaphore(value: 0)
    let watcher = AppRemovalWatcher(directories: [apps], settleSeconds: 0.5) { app in
        box.lock.lock(); box.names.append(app.name); box.lock.unlock(); seen.signal()
    }
    watcher.start()
    let out = makeDir("OutTrash")
    try fm.moveItem(at: apps.appendingPathComponent("Gone.app"), to: out.appendingPathComponent("Gone.app"))   // 拖进“废纸篓”
    // 模拟 App 更新：先挪走，马上又放回来
    try fm.moveItem(at: apps.appendingPathComponent("Update.app"), to: out.appendingPathComponent("Update.app"))
    try fm.moveItem(at: out.appendingPathComponent("Update.app"), to: apps.appendingPathComponent("Update.app"))
    let ok = seen.wait(timeout: .now() + 5) == .success
    Thread.sleep(forTimeInterval: 1.5)
    watcher.stop()
    check(ok && box.names == ["Gone"], "只提醒真的被移走的 App，更新时不误报（实际：\(box.names)）")
}

group("拖进废纸篓：找移走的 App 留下的文件") {
    // 前面那个假 App 的文件还在 Lib 里；App 本体已经不在原位置了
    let removed = AppInfo(url: sandbox.appendingPathComponent("Apps/RemovedDemo.app"), name: "Demo", bundleID: "com.test.demo",
                          version: nil, lastUsed: nil, protection: nil, needsPassword: false, homebrewCask: nil)
    let lib = sandbox.appendingPathComponent("Lib"), sys = sandbox.appendingPathComponent("SysLib")
    let plan = UninstallPlanner.leftovers(ofRemovedApp: removed, library: lib, systemLibrary: sys,
                                          installedIDs: ["com.test.other"], otherCopies: [])
    check(plan != nil && plan!.items.allSatisfy { $0.kind != .bundle }, "列出留下的文件，不含 App 本体")
    check(plan?.items.contains { $0.url.lastPathComponent == "com.test.demo.plist" && $0.kind == .matched } == true,
          "找到了它的设置文件")
    let withCopy = UninstallPlanner.leftovers(ofRemovedApp: removed, library: lib, systemLibrary: sys,
                                              installedIDs: [], otherCopies: [URL(fileURLWithPath: "/Applications/Demo.app")])
    check(withCopy == nil, "还装着另一份同样的 App 时（比如更新、挪了位置），不提醒")
}

group("卸载：哪些 App 不能卸载") {
    check(AppCatalog.info(for: URL(fileURLWithPath: "/System/Applications/Calculator.app")).protection == .system, "系统自带的受保护")
    if fm.fileExists(atPath: "/Applications/Safari.app") {
        check(AppCatalog.info(for: URL(fileURLWithPath: "/Applications/Safari.app")).protection == .system, "装在“应用程序”里的苹果 App 也受保护")
    }
    // 受保护的 App，就算直接调用卸载也会被拒绝，什么都不动
    let calc = AppCatalog.info(for: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
    let report = Uninstaller.uninstall(UninstallPlan(app: calc, items: [
        UninstallItem(url: calc.url, kind: .bundle, bytes: 0, what: "")]), selected: [calc.url])
    check(report.trashedCount == 0 && !report.failures.isEmpty && fm.fileExists(atPath: calc.url.path), "卸载受保护的 App 会被拒绝")
    let ok = { PathGuard.isAllowedApp(URL(fileURLWithPath: $0)) }
    check(ok("/Applications/Foo.app") && ok("/Applications/Adobe/Foo.app") && ok(home + "/Applications/Foo.app"), "“应用程序”里的 App 可以卸载")
    check(!ok("/Applications/a/b/Foo.app") && !ok("/System/Applications/Foo.app") && !ok("/Applications/Foo")
          && !ok("/Applications/../Foo.app"), "别的位置、太深的、不是 .app 的都不行")
    check(!UninstallPlanner.looksRelated("codex", to: "code") && !UninstallPlanner.looksRelated("democracy", to: "demo"),
          "名字只是碰巧开头一样的不算（Code 和 Codex）")
    check(UninstallPlanner.looksRelated("docker desktop", to: "docker") && UninstallPlanner.looksRelated("dingtalkmac", to: "dingtalk"),
          "App 名 + 常见后缀的算")
}

// MARK: - 重复文件

group("重复文件：只认内容完全一样的") {
    let d = makeDir("Dupes")
    func write(_ rel: String, _ data: Data) { let u = d.appendingPathComponent(rel)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: u.path, contents: data) }
    var x = Data(count: 300_000); x[150_000] = 1
    var y = x; y[150_000] = 2                      // 大小一样、开头结尾也一样，只有中间不同
    write("one.bin", x)
    write("sub/one (1).bin", x)                    // 真正的重复，名字像副本
    write("other.bin", y)                          // 不算重复
    write("node_modules/lib.bin", x)               // 程序依赖里的，不管
    try fm.linkItem(at: d.appendingPathComponent("one.bin"), to: d.appendingPathComponent("hardlink.bin"))   // 硬链接，同一个文件
    let clone = Process(); clone.executableURL = URL(fileURLWithPath: "/bin/cp")
    clone.arguments = ["-c", d.appendingPathComponent("one.bin").path, d.appendingPathComponent("clone.bin").path]
    try clone.run(); clone.waitUntilExit()       // APFS 克隆，共用硬盘空间

    let groups = DuplicateFinder.find(roots: [d], minBytes: 1000)
    check(groups.count == 1, "只有一组重复（实际 \(groups.count) 组）")
    let names = Set(groups.first?.files.map(\.url.lastPathComponent) ?? [])
    check(names.contains("one (1).bin") && names.contains("clone.bin"), "内容一样的认出来了（实际：\(names.sorted())）")
    check(!names.contains("other.bin"), "大小、开头结尾都一样但中间不同的，不算重复")
    check(!names.contains("lib.bin"), "程序依赖里的不管")
    check(names.contains("hardlink.bin") != names.contains("one.bin"), "硬链接是同一个文件的两个名字，只算一次")
    if let g = groups.first {
        check(g.wastedBytes == 300_000, "克隆副本不算可腾出的空间：只算真正多占的那一份（实际 \(g.wastedBytes)）")
        check(g.suggestedKeep.url.lastPathComponent != "one (1).bin", "建议保留的不是名字像副本的那份")
        // 整组都勾上：必须拒绝，什么都不动
        let r = DuplicateCleaner.trash([g], selected: Set(g.files.map(\.url)))
        check(r.trashedCount == 0 && g.files.allSatisfy { fm.fileExists(atPath: $0.url.path) }, "整组都勾上时拒绝删除，每组至少留一份")
    }
}

// MARK: - 空间地图

group("空间地图：大小和层级") {
    makeFile("Map/big.bin", bytes: 3_000_000)
    makeFile("Map/folder/a.bin", bytes: 2_000_000)
    makeFile("Map/folder/b.bin", bytes: 1_000_000)
    for i in 0..<5 { makeFile("Map/folder/small\(i).txt", bytes: 10_000) }
    try fm.linkItem(at: sandbox.appendingPathComponent("Map/big.bin"), to: sandbox.appendingPathComponent("Map/folder/big-link.bin"))
    let tree = DiskMap.build(root: sandbox.appendingPathComponent("Map"), minNodeBytes: 500_000)
    let real = SizeCalculator().size(of: sandbox.appendingPathComponent("Map"))
    check(tree.size == real, "总大小和逐个算的一致（\(tree.size) vs \(real)）")
    check(tree.size < 7_000_000, "硬链接只算一次（实际 \(tree.size)）")
    check(tree.children.map(\.size) == tree.children.map(\.size).sorted(by: >), "子项从大到小排")
    let folder = tree.children.first { $0.name == "folder" }
    check(folder?.children.contains { $0.kind == .others } == true, "小文件合进“其他小文件”")
    check(folder.map { $0.children.reduce(0) { $0 + $1.size } == $0.size } == true, "每层子项加起来等于这一层的大小")
}

group("空间地图：色块排列") {
    let sizes: [Int64] = [500, 250, 120, 80, 30, 15, 5]
    let rects = Treemap.layout(sizes, width: 400, height: 300)
    check(rects.count == sizes.count, "每个都有一块")
    let total = Double(sizes.reduce(0, +))
    let proportional = rects.allSatisfy { r in
        abs(r.width * r.height - Double(sizes[r.index]) / total * 120_000) < 1
    }
    check(proportional, "面积和大小成正比")
    check(rects.allSatisfy { $0.x >= -0.01 && $0.y >= -0.01 && $0.x + $0.width <= 400.01 && $0.y + $0.height <= 300.01 },
          "都在画布里面")
    var overlap = false
    for i in rects.indices { for j in rects.indices where i < j {
        let a = rects[i], b = rects[j]
        if a.x + 0.01 < b.x + b.width && b.x + 0.01 < a.x + a.width && a.y + 0.01 < b.y + b.height && b.y + 0.01 < a.y + a.height { overlap = true }
    } }
    check(!overlap, "色块互不重叠")
}

// MARK: - 版本号

group("版本号比较（新版本提醒用）") {
    check(Version.isNewer("0.13.0", than: "0.12.0") && Version.isNewer("1.0.0", than: "0.99.9") && Version.isNewer("0.12.1", than: "0.12"),
          "新的算新")
    check(!Version.isNewer("0.12.0", than: "0.12.0") && !Version.isNewer("0.9.0", than: "0.12.0"), "一样或更旧的不算新（0.9 不比 0.12 新）")
}

// MARK: - 翻译

group("英文翻译：每条内置规则的名称、说明、分类、工具名都有翻译") {
    let path = fm.currentDirectoryPath + "/Resources/en.lproj/Localizable.strings"
    guard let table = NSDictionary(contentsOfFile: path) as? [String: String] else {
        check(false, "读不到翻译文件 \(path)（先运行 python3 scripts/translations.py）")
        return
    }
    let hasChinese = { (s: String) in s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
    var missing: [String] = []
    for r in RuleBook.builtIn {
        for text in [r.name, r.detail, r.category, r.tool ?? ""] where hasChinese(text) && table[text] == nil {
            missing.append(text)
        }
    }
    check(missing.isEmpty, "缺少翻译（加到 scripts/translations.py 里）：\(missing)")
}

// MARK: - 结果

print("")
if failed.isEmpty {
    print("✅ 全部通过：\(passed) 项检查")
} else {
    print("❌ \(failed.count) 项没通过（通过 \(passed) 项）：")
    failed.forEach { print("   - \($0)") }
    exit(1)
}
