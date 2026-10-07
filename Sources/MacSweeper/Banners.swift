import AppKit
import SwiftUI
import SweeperCore

/// 结果列表顶部的几块：总览、清理/撤销结果、重新打开 App、权限提醒
extension ContentView {
    func reportBanner(_ report: CleanReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("已将 \(report.trashedCount) 个项目（\(formatBytes(report.trashedBytes))）移到废纸篓",
                  systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            Text("确认电脑一切正常后，清空废纸篓才会真正释放空间。")
                .font(.callout).foregroundStyle(.secondary)
            if !report.failures.isEmpty {
                Text("有 \(report.failures.count) 个项目没能移动（通常是正在被使用），可以退出相关 App 后再试。")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }

    /// 顶部总览：能腾出多少、废纸篓还有多少、上次清理能不能撤销
    var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                summaryNumber("可放心清理", model.safeBytes, .green)
                summaryNumber("需确认", model.reviewBytes, .orange)
                summaryNumber("要先退出 App", model.lockedBytes, .secondary)
            }
            if let trash = model.trashBytes, trash > 0 {
                HStack {
                    Label("废纸篓里还有 \(formatBytes(trash))，清空后空间才会真正释放", systemImage: "trash")
                        .font(.callout)
                    Spacer()
                    Button("打开废纸篓") {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".Trash"))
                    }
                }
            } else if model.trashBytes == nil, model.undoBatch != nil {
                Label("清理的文件还在废纸篓里，确认电脑正常后记得清空，空间才会真正释放", systemImage: "trash")
                    .font(.callout)
            }
            if let batch = model.undoBatch {
                HStack {
                    Label("上次清理（\(batch.date.formatted(.dateTime.month().day().hour().minute()))）移走了 \(batch.moves.count) 个项目，共 \(formatBytes(batch.bytes))",
                          systemImage: "clock.arrow.circlepath")
                        .font(.callout)
                    Spacer()
                    Button("撤销上次清理") { confirmingUndo = true }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .listRowSeparator(.hidden)
        .padding(.vertical, 6)
    }

    func summaryNumber(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatBytes(bytes)).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func undoBanner(_ r: UndoReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("已把 \(r.restoredCount) 个项目（\(formatBytes(r.restoredBytes))）放回原处",
                  systemImage: "arrow.uturn.backward.circle.fill")
                .font(.headline).foregroundStyle(.green)
            if r.occupiedCount > 0 {
                Text("\(r.occupiedCount) 个原位置已经有新文件（App 重新生成了），留在废纸篓里没有覆盖。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if r.goneCount > 0 {
                Text("\(r.goneCount) 个已经从废纸篓清空，找不回来了。").font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }

    /// 只退出、还没重新打开的 App
    var reopenBanner: some View {
        HStack {
            Label("这些 App 是 MacSweeper 帮你退出的，清理完可以重新打开", systemImage: "arrow.uturn.backward.circle")
                .font(.callout)
            Spacer()
            ForEach(model.appsToReopen, id: \.self) { url in
                Button("重新打开 \(FileManager.default.displayName(atPath: url.path))") { model.reopen([url]) }
            }
        }
        .padding(.vertical, 6)
    }

    var permissionBanner: some View {
        HStack {
            Label("部分目录没有权限读取，授予“完全磁盘访问权限”后可以扫描得更完整",
                  systemImage: "lock.fill")
                .font(.callout)
            Spacer()
            Button("打开设置") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: 底部
}
