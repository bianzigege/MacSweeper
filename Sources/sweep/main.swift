import Foundation
import SweeperCore

let usage = """
用法：
  sweep                     扫描并列出可清理的项目（只看，不删）
  sweep scan --detail       扫描，并列出每条规则里最大的几个项目
  sweep clean               清理所有“可放心清理”的项目（会先列出并询问确认）
  sweep clean <规则ID>...    只清理指定规则，例如：sweep clean user-caches npm-cache
  sweep clean --dry-run     只预览将要清理的内容，不做任何改动

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

let label: [Safety: String] = [.safe: "✅ 可放心清理", .review: "⚠️  需确认", .reportOnly: "ℹ️  只报告"]

func printTable(_ results: [ScanResult], detail: Bool) {
    for safety in [Safety.safe, .review, .reportOnly] {
        let group = results.filter { $0.rule.safety == safety && ($0.bytes > 0 || !$0.unreadable.isEmpty) }
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
                    let shown = item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    print("        " + lpad(formatBytes(item.bytes), 10) + "  " + shown)
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

case "help", "-h", "--help":
    print(usage)

default:
    print("未知命令：\(command)\n\n" + usage)
    exit(1)
}
