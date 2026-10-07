import AppKit
import SwiftUI
import SweeperCore

/// 三态勾选框：全选 / 部分选 / 未选
struct CheckBox: View {
    let state: SweepModel.CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill"
                  : state == .mixed ? "minus.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.borderless)
    }
}

/// 一条规则：勾选框 + 名称说明 + 大小，展开后可以逐项勾选
struct RuleRow: View {
    @EnvironmentObject var model: SweepModel
    let result: ScanResult
    @State private var expanded = false
    @State private var showAll = false

    private static let previewCount = 8
    private var cleanable: Bool { model.isCleanable(result) }
    @State private var confirmQuit = false
    @State private var quitThenClean = false

    /// App 正在运行时的按钮：可放心清理的一步到位；需确认的只退出，让你自己挑
    private func quitButtons(_ app: String) -> some View {
        HStack(spacing: 8) {
            Label("\(app)正在运行", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.orange)
            if result.rule.safety == .safe {
                Button("退出\(app)并清理") { quitThenClean = true; confirmQuit = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button("退出\(app)") { quitThenClean = false; confirmQuit = true }
                    .controlSize(.small)
            }
        }
        .confirmationDialog(quitThenClean ? "退出\(app)并清理“\(result.rule.name)”？" : "退出\(app)？",
                            isPresented: $confirmQuit, titleVisibility: .visible) {
            Button(quitThenClean ? "退出并清理 \(formatBytes(result.bytes))" : "退出\(app)") {
                model.quitApps(for: result, thenClean: quitThenClean)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(quitThenClean
                 ? "会像按 ⌘Q 一样让\(app)正常退出，然后把这一项移到废纸篓，完成后自动重新打开\(app)。"
                 : "会像按 ⌘Q 一样让\(app)正常退出。退出后这一项就能勾选了，挑好要删的再清理。")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if cleanable {
                    CheckBox(state: model.state(of: result)) { model.toggle(result) }
                } else if result.rule.safety == .reportOnly {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary).frame(width: 15)
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(.orange).frame(width: 15)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.rule.name).font(.body.weight(.medium))
                        if result.rule.tool != nil {
                            SafetyBadge(safety: result.rule.safety)
                        } else {
                            Text(result.rule.category)
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(result.rule.detail).font(.caption).foregroundStyle(.secondary)
                    if let app = result.blocker {
                        if !model.canQuitApps(for: result) {
                            Label("\(app)正在运行，退出后点“重新扫描”才能清理", systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            quitButtons(app)
                        }
                    }
                    if !result.skippedRunning.isEmpty {
                        Label("已跳过正在运行的：\(result.skippedRunning.joined(separator: "、"))",
                              systemImage: "forward.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !result.unreadable.isEmpty {
                        Text("没有权限读取").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatBytes(result.bytes)).monospacedDigit()
                    if cleanable && model.state(of: result) == .mixed {
                        Text("已选 \(formatBytes(model.selectedBytes(in: result)))")
                            .font(.caption).foregroundStyle(.tint).monospacedDigit()
                    }
                }
                if !result.items.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(.borderless)
                    .help("查看明细")
                }
            }
            if expanded {
                let shown = showAll ? result.items[...] : result.items.prefix(Self.previewCount)
                ForEach(shown, id: \.url) { item in itemRow(item) }
                if result.items.count > Self.previewCount {
                    Button(showAll ? "收起" : "显示全部 \(result.items.count) 项") { showAll.toggle() }
                        .buttonStyle(.link).font(.caption).padding(.leading, 26)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func itemRow(_ item: Item) -> some View {
        HStack(spacing: 8) {
            if cleanable {
                CheckBox(state: model.selected.contains(item.url) ? .on : .off) { model.toggle(item.url) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).font(.callout).lineLimit(1)
                // 有显示名的（如“tk-creator › node_modules”）给出完整路径，否则给所在文件夹
                Text((item.label == nil ? item.url.deletingLastPathComponent() : item.url).path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let date = item.modified {
                Text(date, format: .dateTime.year().month().day())
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("最后修改时间")
            }
            Text(formatBytes(item.bytes)).font(.callout).monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("在访达中显示")
        }
        .padding(.leading, 26)
    }
}
