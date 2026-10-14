import AppKit
import SwiftUI
import SweeperCore

/// 简单模式：一句话、一个数字、一个按钮。
/// 只清理“删了会自动重建”的缓存和日志，正在用的 App 自动跳过，其他一概不碰。
struct SimpleView: View {
    @EnvironmentObject var model: SweepModel
    @Binding var mode: ContentView.Mode
    @State private var confirming = false
    /// 正要“退出并清理”的那个 App（弹窗确认用）
    @State private var quitting: SweepModel.BlockedApp?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                switch model.phase {
                case .idle:
                    Text(L("硬盘剩余 %@", formatBytes(model.freeBytes))).font(.title2)
                    Text(L("点一下，看看有多少可以放心清理的缓存")).foregroundStyle(.secondary)
                    bigButton(L("开始检查")) { model.scan(scope: .simple) }
                    PermissionHint(text: L("只检查缓存和日志，不看你的桌面、文稿和下载。macOS 可能会问能不能访问其他 App 的数据，这是为了找微信、飞书这些 App 里的缓存。点“允许”就行；不允许也没关系，那部分会跳过。"))
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
            if let notice = model.notice, model.phase == .ready {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: 520).padding(.top, 12)
            }
            Spacer()
            footer
        }
        .confirmationDialog(L("退出%@，清理 %@ 的缓存？", quitting?.name ?? "", formatBytes(quitting?.bytes ?? 0)),
                            isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } }),
                            titleVisibility: .visible, presenting: quitting) { app in
            Button(L("退出并清理"), role: .destructive) { model.quitApps(for: app.results, thenClean: true) }
            Button("取消", role: .cancel) {}
        } message: { app in
            Text(L("%@ 会先退出，清理完自动重新打开。只清缓存，聊天记录、文件和登录状态都不受影响。如果有没发出去的消息、没保存的内容，请先处理好。", app.name))
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
            blockedApps
        } else if model.simpleBytes > 0 {
            Text(L("硬盘剩余 %@", formatBytes(model.freeBytes))).font(.title2)
            (Text(L("有 ")) + Text(formatBytes(model.simpleBytes)).bold().foregroundColor(.green) + Text(L(" 是缓存和日志")))
                .font(.title)
            Text(L("删了会自动重建，不影响聊天记录、文件、登录状态。正在使用的 App 会自动跳过。"))
                .foregroundStyle(.secondary)
            bigButton(L("安全清理")) { confirming = true }
            blockedApps
        } else {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.green)
            Text(L("很干净，没有可放心清理的缓存")).font(.title2)
            Text(L("硬盘剩余 %@", formatBytes(model.freeBytes))).foregroundStyle(.secondary)
            blockedApps
            Button(L("重新检查")) { model.scan() }
        }
    }

    /// 开着的 App 挡住的缓存，按 App 列出来，可以一键“退出并清理”。大多数人平时开着微信、飞书、Chrome，这部分往往最大
    @ViewBuilder private var blockedApps: some View {
        let apps = model.simpleBlockedApps
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("这些 App 开着，它们的缓存（共 %@）先没动：", formatBytes(model.simpleSkippedBytes)))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(apps.prefix(4)) { app in
                    HStack(spacing: 10) {
                        if let url = app.bundleURL {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "terminal").frame(width: 22, height: 22).foregroundStyle(.secondary)
                        }
                        Text(app.name).lineLimit(1)
                        Text(formatBytes(app.bytes)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        if app.canQuit {
                            Button(L("退出并清理")) { quitting = app }
                        } else {
                            Text(L("关掉它之后再检查")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .padding(12)
            .frame(maxWidth: 440)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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
            Button(L("反馈问题")) { Feedback.open() }
                .help(L("打开 GitHub 的反馈页面，会自动带上版本号，不带任何文件路径"))
            Button(L("详细模式")) { mode = .detailed }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
