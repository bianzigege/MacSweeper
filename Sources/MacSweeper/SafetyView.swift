import AppKit
import SwiftUI
import SweeperCore

/// “安全说明”页：五句话说清楚这个工具怎么保证安全，以及怎么自己验证
struct SafetyView: View {
    @Environment(\.dismiss) private var dismiss

    private let promises: [(String, String, String)] = [
        ("trash", "只移到废纸篓，从不直接删除", "所有清理、卸载、重复文件处理，都是把文件移到废纸篓。想反悔就撤销，或者在废纸篓里拖回来。清空废纸篓这一步永远由你自己做"),
        ("list.bullet.rectangle", "动手前一定先列清单", "每一项都写明这是什么、删了会怎样（会自动重建 / 要重新下载 / 找不回来）、我们怎么知道的。找不回来的只能逐项勾"),
        ("arrow.uturn.backward.circle", "每一次操作都能撤销", "每次清理是一条记录，清理垃圾页面顶部列出来，可以单独撤销。原位置已经有新文件的不会覆盖"),
        ("house", "只碰你自己的主目录", "桌面、文稿、下载等文件夹本身不会被动；系统文件、别的用户的东西碰不到。卸载 App 只限“应用程序”文件夹"),
        ("doc.text", "所有操作都有日志", "每一次移动、撤销、拒绝都记在日志里，随时可以查"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.shield").font(.title).foregroundStyle(.green)
                Text(L("MacSweeper 怎么保证安全")).font(.title2.weight(.semibold))
                Spacer()
                Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ForEach(promises, id: \.1) { icon, title, body in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L(title)).font(.headline)
                        Text(L(body)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Text(L("不放心的话，可以自己验证：")).font(.headline)
            HStack(spacing: 10) {
                Button(L("查看操作日志")) { NSWorkspace.shared.activateFileViewerSelecting([OperationLog.url]) }
                Button(L("查看源代码（开源）")) { NSWorkspace.shared.open(URL(string: "https://github.com/bianzigege/MacSweeper")!) }
                Button(L("打开废纸篓")) { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) }
            }
            Text(L("还可以用“导出清单”把要清理的东西存成文件，发给懂的人或者问 AI。"))
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 560)
    }
}
