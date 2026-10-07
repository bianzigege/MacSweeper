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

// MARK: - 结果

print("")
if failed.isEmpty {
    print("✅ 全部通过：\(passed) 项检查")
} else {
    print("❌ \(failed.count) 项没通过（通过 \(passed) 项）：")
    failed.forEach { print("   - \($0)") }
    exit(1)
}
