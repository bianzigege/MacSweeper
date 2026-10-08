import Foundation
import SweeperCore

let usage = """
用法：
  sweep                     扫描并列出可清理的项目（只看，不删）
  sweep scan --detail       扫描，并列出每条规则里最大的几个项目
  sweep clean               清理所有“可放心清理”的项目（会先列出并询问确认）
  sweep clean <规则ID>...    只清理指定规则，例如：sweep clean user-caches npm-cache
  sweep clean --dry-run     只预览将要清理的内容，不做任何改动
  sweep undo                撤销上一次清理（或卸载）：把文件从废纸篓放回原处
  sweep dupes               找重复文件（只列出来，不删）
  sweep apps                列出已安装的 App，很久没用的排前面
  sweep uninstall <App名>   卸载 App：先列出相关文件，确认后移到废纸篓
  sweep uninstall <App名> --dry-run   只预览，不做任何改动

自定义规则：\(CustomRules.file.path)

清理是把文件移到废纸篓，确认没问题后再自己清空废纸篓。
操作日志：\(OperationLog.url.path)
"""

// MARK: - 终端排版

/// 终端显示宽度：中文等全角字符占 2 格
func displayWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { w, u in
        w + ((0x1100...0x115F).contains(u.value) || (0x2E80...0xFFEF).contains(u.value) ? 2 : 1)
    }
}

func pad(_ s: String, _ width: Int) -> String {
    s + String(repeating: " ", count: max(0, width - displayWidth(s)))
}

func lpad(_ s: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - displayWidth(s))) + s
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

let label: [Safety: String] = [.safe: "✅ 可放心清理", .review: "⚠️  需确认", .reportOnly: "ℹ️  只报告"]

func printTable(_ results: [ScanResult], detail: Bool) {
    for safety in [Safety.safe, .review, .reportOnly] {
        let group = results.filter { $0.rule.safety == safety && (!$0.items.isEmpty || !$0.unreadable.isEmpty) }
        guard !group.isEmpty else { continue }
        let total = group.reduce(Int64(0)) { $0 + $1.bytes }
        print("\n\(label[safety]!)  合计 \(formatBytes(total))")
        print(String(repeating: "─", count: 72))
        for r in group {
            print("  " + pad(r.rule.name, 24) + lpad(formatBytes(r.bytes), 10) + "   " + r.rule.id)
            print("      " + r.rule.detail)
            if let app = r.blocker {
                print("      🔒 \(app) 正在运行，请先退出它再清理这一项")
            }
            if !r.skippedRunning.isEmpty {
                print("      ⏭  已跳过正在运行的应用：\(r.skippedRunning.joined(separator: "、"))")
            }
            if !r.unreadable.isEmpty {
                print("      ⛔ 没有权限读取，需要在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”里授权终端")
            }
            if detail {
                for item in r.items.prefix(5) {
                    let shown = item.label ?? item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    let date = item.modified.map { " ·" + dateFormatter.string(from: $0) } ?? ""
                    print("        " + lpad(formatBytes(item.bytes), 10) + "  " + shown + date)
                }
            }
        }
    }
}

func scanWithProgress() -> [ScanResult] {
    FileHandle.standardError.write(Data("正在扫描，请稍候...\n".utf8))
    return Scanner.scan()
}

// MARK: - 命令

var args = Array(CommandLine.arguments.dropFirst())
var command = "scan"
if let first = args.first, !first.hasPrefix("-") {
    command = first
    args.removeFirst()
} else if args.contains("-h") || args.contains("--help") {
    command = "help"
}

switch command {
case "scan":
    for problem in CustomRules.load().problems { print("⚠️  " + problem) }
    let results = scanWithProgress()
    printTable(results, detail: args.contains("--detail"))
    let cleanable = results.filter { $0.rule.safety == .safe }.reduce(Int64(0)) { $0 + $1.bytes }
    print("\n运行 sweep clean --dry-run 可预览清理“可放心清理”的 \(formatBytes(cleanable))")

case "clean":
    let dryRun = args.contains("--dry-run")
    let ids = args.filter { !$0.hasPrefix("-") }
    let known = Set(RuleBook.all.map(\.id))
    if let bad = ids.first(where: { !known.contains($0) }) {
        print("未知的规则 ID：\(bad)\n可用的 ID：\(RuleBook.all.map(\.id).joined(separator: ", "))")
        exit(1)
    }
    if let r = RuleBook.all.first(where: { ids.contains($0.id) && $0.safety == .reportOnly }) {
        print("“\(r.name)” 只报告不清理：\(r.detail)")
        exit(1)
    }

    let rules = ids.isEmpty
        ? RuleBook.all.filter { $0.safety == .safe }
        : RuleBook.all.filter { ids.contains($0.id) }
    FileHandle.standardError.write(Data("正在扫描，请稍候...\n".utf8))
    let plan = Scanner.scan(rules).filter { $0.bytes > 0 }
    guard !plan.isEmpty else { print("没有可清理的内容。"); exit(0) }

    printTable(plan, detail: true)
    let total = plan.reduce(Int64(0)) { $0 + $1.bytes }
    let count = plan.reduce(0) { $0 + $1.items.count }
    print("\n将把 \(count) 个项目（\(formatBytes(total))）移到废纸篓。")

    if dryRun { print("（预览模式，没有做任何改动）"); exit(0) }

    print("建议先退出相关 App。确认清理请输入 y 并回车：", terminator: " ")
    guard readLine()?.lowercased() == "y" else { print("已取消。"); exit(0) }

    let report = Cleaner.moveToTrash(plan)
    print("\n完成：已将 \(report.trashedCount) 个项目（\(formatBytes(report.trashedBytes))）移到废纸篓。")
    if !report.failures.isEmpty {
        print("有 \(report.failures.count) 个项目没能移动（通常是正在被使用或没有权限），例如：")
        for f in report.failures.prefix(5) { print("  \(f.path)：\(f.reason)") }
    }
    print("确认电脑一切正常后，再清空废纸篓才会真正释放空间。")

case "undo":
    guard let batch = Undo.lastBatch() else {
        print("没有可以撤销的清理（还没清理过，或者废纸篓已经清空了）。")
        exit(0)
    }
    let f = DateFormatter(); f.dateFormat = "M 月 d 日 HH:mm"
    print("上次清理：\(f.string(from: batch.date))，移走了 \(batch.moves.count) 个项目（\(formatBytes(batch.bytes))）。")
    print("确认放回原处请输入 y 并回车：", terminator: " ")
    guard readLine()?.lowercased() == "y" else { print("已取消。"); exit(0) }
    let r = Undo.restoreLast()!
    print("已放回 \(r.restoredCount) 个（\(formatBytes(r.restoredBytes))）。")
    if r.occupiedCount > 0 { print("\(r.occupiedCount) 个原位置已经有新文件（App 重新生成了），留在废纸篓里没有覆盖。") }
    if r.goneCount > 0 { print("\(r.goneCount) 个已经从废纸篓清空，找不回来了。") }
    for f in r.failures.prefix(5) { print("  没能放回 \(f.path)：\(f.reason)") }

case "dupes":
    let start = Date()
    let groups = DuplicateFinder.find { p in
        if p.total > 0 && p.done % 20 == 0 { FileHandle.standardError.write(Data("\r\(p.phase) \(p.done)/\(p.total)   ".utf8)) }
    }
    FileHandle.standardError.write(Data("\n".utf8))
    let saving = groups.reduce(Int64(0)) { $0 + $1.wastedBytes }
    let clones = groups.filter(\.allClones)
    print("找到 \(groups.count) 组重复文件，每组只留一份能腾出 \(formatBytes(saving))（用时 \(Int(Date().timeIntervalSince(start))) 秒）")
    if !clones.isEmpty { print("其中 \(clones.count) 组是克隆副本（共用硬盘空间），删了不省空间，已经不算在里面") }
    for g in groups.prefix(15) {
        print("\n" + lpad(formatBytes(g.size), 10) + " × \(g.files.count) 份" + (g.allClones ? "（克隆副本，删了不省空间）" : "，可腾出 \(formatBytes(g.wastedBytes))"))
        for f in g.files {
            let mark = f == g.suggestedKeep ? "  留 " : "     "
            print(mark + f.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
    }

case "apps":
    let apps = AppCatalog.list().sorted {
        ($0.isUnused ? 0 : 1, $0.lastUsed ?? .distantPast) < ($1.isUnused ? 0 : 1, $1.lastUsed ?? .distantPast)
    }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    for a in apps {
        let used = a.lastUsed.map { f.string(from: $0) } ?? "从没打开过"
        var tags: [String] = []
        if a.isUnused { tags.append("很久没用") }
        if let p = a.protection { tags.append(p == .system ? "系统自带" : p == .itself ? "MacSweeper 自己" : "已保护") }
        if a.needsPassword { tags.append("需要密码") }
        if let c = a.homebrewCask { tags.append("Homebrew: \(c)") }
        print(pad(a.name, max(28, displayWidth(a.name) + 2)) + pad(used, 14) + tags.joined(separator: "、"))
    }

case "uninstall":
    let dryRun = args.contains("--dry-run")
    let query = args.filter { !$0.hasPrefix("-") }.joined(separator: " ").lowercased()
    guard !query.isEmpty else { print("请写上要卸载的 App 名字，比如：sweep uninstall 钉钉"); exit(1) }
    let matches = AppCatalog.list().filter {
        $0.name.lowercased() == query || $0.url.deletingPathExtension().lastPathComponent.lowercased() == query
    }
    guard let app = matches.first else { print("没找到叫“\(query)”的 App。用 sweep apps 看看准确的名字。"); exit(1) }
    if let p = app.protection {
        print("“\(app.name)”受保护，不能卸载（\(p == .system ? "苹果自带" : p == .itself ? "MacSweeper 自己" : "在保护名单里")）。")
        exit(1)
    }
    FileHandle.standardError.write(Data("正在查找相关文件…\n".utf8))
    let plan = UninstallPlanner.plan(for: app)
    if let note = plan.note { print("\n⚠️  " + note) }
    let titles: [UninstallItem.Kind: String] = [
        .bundle: "一定会删 · App 本体", .matched: "默认勾选 · ID 完全对得上的", .launchAgent: "默认勾选 · 开机自启项",
        .userData: "默认不勾 · 可能有你的数据", .guessed: "默认不勾 · 按名字找到的，不确定是不是它的",
        .shared: "不会动 · 其他 App 还在用", .systemLevel: "不会动 · 系统级（需要管理员权限）",
    ]
    for kind in [UninstallItem.Kind.bundle, .matched, .launchAgent, .userData, .guessed, .shared, .systemLevel] {
        let items = plan.items.filter { $0.kind == kind }
        guard !items.isEmpty else { continue }
        print("\n" + titles[kind]!)
        for i in items {
            print("  " + lpad(formatBytes(i.bytes), 10) + "  " + i.what + "  " + i.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
    }
    if let cask = app.homebrewCask { print("\n这个 App 是用 Homebrew 装的，建议在终端运行：brew uninstall --cask \(cask)") }
    let chosen = plan.items.filter { $0.kind.selectedByDefault }
    print("\n将把 \(chosen.count) 项（\(formatBytes(chosen.reduce(0) { $0 + $1.bytes }))）移到废纸篓（只含默认勾选的；其余请用图形界面挑选）。")
    if app.needsPassword { print("这个 App 归系统所有，移到废纸篓时 macOS 会弹出密码框。") }
    if dryRun { print("（预览模式，没有做任何改动）"); exit(0) }
    print("确认卸载请输入 App 名字“\(app.name)”并回车：", terminator: " ")
    guard readLine()?.trimmingCharacters(in: .whitespaces) == app.name else { print("已取消。"); exit(0) }
    let report = Uninstaller.uninstall(plan, selected: Set(chosen.map(\.url)))
    print("已移到废纸篓 \(report.trashedCount) 项（\(formatBytes(report.trashedBytes))）。想反悔可以运行 sweep undo。")
    for f in report.failures { print("  没能移走 \(f.path)：\(f.reason)") }

case "help", "-h", "--help":
    print(usage)

default:
    print("未知命令：\(command)\n\n" + usage)
    exit(1)
}
