import AppKit
import SwiftUI
import SweeperCore

/// 简单模式：一句话、一个数字、一个按钮。
/// 只清理“删了会自动重建”的缓存和日志，正在用的 App 自动跳过，其他一概不碰。
struct SimpleView: View {
    @EnvironmentObject var model: SweepModel
    @Binding var mode: ContentView.Mode
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                switch model.phase {
                case .idle:
                    Text(L("硬盘剩余 %@", formatBytes(model.freeBytes))).font(.title2)
                    Text(L("点一下，看看有多少可以放心清理的缓存")).foregroundStyle(.secondary)
                    bigButton(L("开始检查")) { model.scan() }
                case .scanning:
                    ProgressView().controlSize(.large)
                    Text(L("正在检查…")).foregroundStyle(.secondary)
                case .cleaning:
                    ProgressView().controlSize(.large)
                    Text(model.busyText).foregroundStyle(.secondary)
                case .ready:
                    readyContent
                }
            }
            .frame(maxWidth: 520)
            .multilineTextAlignment(.center)
            Spacer()
            footer
        }
        .confirmationDialog(L("把 %@ 的缓存移到废纸篓？", formatBytes(model.simpleBytes)), isPresented: $confirming,
                            titleVisibility: .visible) {
            Button(L("安全清理"), role: .destructive) { model.cleanSimple() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(L("这些都是缓存和日志，程序下次用到会自动重建。文件先进废纸篓，可以撤销。"))
        }
    }

    @ViewBuilder private var readyContent: some View {
        if let report = model.lastReport, report.trashedCount > 0 {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text(L("已清理 %@", formatBytes(report.trashedBytes))).font(.title)
            Text(L("文件在废纸篓里，用几天没问题再清空。后悔了可以撤销。")).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let batch = model.undoHistory.first(where: { $0.id == report.batchID }) {
                    Button(L("撤销")) { model.undo(batch) }
                }
                Button(L("打开废纸篓")) {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                }
            }
            if model.simpleBytes > 0 {
                Text(L("还有 %@ 可以放心清理", formatBytes(model.simpleBytes))).font(.callout).foregroundStyle(.secondary)
                bigButton(L("再清理一次")) { confirming = true }
            }
        } else if model.simpleBytes > 0 {
            Text(L("硬盘剩余 %@", formatBytes(model.freeBytes))).font(.title2)
            (Text(L("有 ")) + Text(formatBytes(model.simpleBytes)).bold().foregroundColor(.green) + Text(L(" 是缓存和日志")))
                .font(.title)
            Text(L("删了会自动重建，不影响聊天记录、文件、登录状态。正在使用的 App 会自动跳过。"))
                .foregroundStyle(.secondary)
            bigButton(L("安全清理")) { confirming = true }
            if model.simpleSkippedBytes > 0 {
                Text(L("另有 %@ 属于正在运行的 App，等它们退出后再清", formatBytes(model.simpleSkippedBytes)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.green)
            Text(L("很干净，没有可放心清理的缓存")).font(.title2)
            Text(L("硬盘剩余 %@", formatBytes(model.freeBytes))).foregroundStyle(.secondary)
            if model.simpleSkippedBytes > 0 {
                Text(L("另有 %@ 属于正在运行的 App，等它们退出后再清", formatBytes(model.simpleSkippedBytes)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L("重新检查")) { model.scan() }
        }
    }

    private func bigButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.title3).frame(minWidth: 200).padding(.vertical, 6) }
            .controlSize(.large).buttonStyle(.borderedProminent)
    }

    private var footer: some View {
        HStack {
            Text(L("简单模式只清理缓存和日志。想看明细、卸载 App、找重复文件，用详细模式。"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L("详细模式")) { mode = .detailed }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
