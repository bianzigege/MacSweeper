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
            Label(L("%@正在运行", app), systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.orange)
            if result.rule.safety == .safe {
                Button(L("退出%@并清理", app)) { quitThenClean = true; confirmQuit = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button(L("退出%@", app)) { quitThenClean = false; confirmQuit = true }
                    .controlSize(.small)
            }
        }
        .confirmationDialog(quitThenClean ? L("退出%@并清理“%@”？", app, L(result.rule.name)) : L("退出%@？", app),
                            isPresented: $confirmQuit, titleVisibility: .visible) {
            Button(quitThenClean ? L("退出并清理 %@", formatBytes(result.bytes)) : L("退出%@", app)) {
                model.quitApps(for: result, thenClean: quitThenClean)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(quitThenClean
                 ? L("会像按 ⌘Q 一样让%@正常退出，然后把这一项移到废纸篓，完成后自动重新打开%@。", app, app)
                 : L("会像按 ⌘Q 一样让%@正常退出。退出后这一项就能勾选了，挑好要删的再清理。", app))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if cleanable {
                    switch model.categoryCheck(result) {
                    case .allowed:
                        CheckBox(state: model.state(of: result)) { model.toggle(result) }
                    case .needsView:
                        // 需确认：先展开看一眼，才能整类勾选
                        Button { withAnimation(.easeOut(duration: 0.15)) { expanded = true }; model.markViewed(result.id) } label: {
                            Image(systemName: "square.dotted").font(.system(size: 15)).foregroundStyle(.orange)
                        }
                        .buttonStyle(.borderless)
                        .help(L("需确认的项目要先展开看一眼，再整类勾选"))
                    case .perItemOnly:
                        Image(systemName: "square.dashed").font(.system(size: 15)).foregroundStyle(.red)
                            .help(L("这类删了找不回来，只能展开后逐项勾选"))
                    }
                } else if result.rule.safety == .reportOnly {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary).frame(width: 15)
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(.orange).frame(width: 15)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L(result.rule.name)).font(.body.weight(.medium))
                        ConsequenceBadge(consequence: result.rule.consequence)
                        if result.rule.tool != nil {
                            SafetyBadge(safety: result.rule.safety)
                        } else {
                            Text(L(result.rule.category))
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(L(result.rule.detail)).font(.caption).foregroundStyle(.secondary)
                    if let app = result.blocker {
                        if !model.canQuitApps(for: result) {
                            Label(L("%@正在运行，退出后点“重新扫描”才能清理", app), systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            quitButtons(app)
                        }
                    }
                    if !result.skippedRunning.isEmpty {
                        Label(L("已跳过正在运行的：%@", result.skippedRunning.joined(separator: L("、"))),
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
                        Text(L("已选 %@", formatBytes(model.selectedBytes(in: result))))
                            .font(.caption).foregroundStyle(.tint).monospacedDigit()
                    }
                }
                if !result.items.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                        if expanded { model.markViewed(result.id) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(.borderless)
                    .help("查看明细")
                }
            }
            if expanded {
                explanationCard
                let shown = showAll ? result.items[...] : result.items.prefix(Self.previewCount)
                ForEach(shown, id: \.url) { item in itemRow(item) }
                if result.items.count > Self.previewCount {
                    Button(showAll ? L("收起") : L("显示全部 %ld 项", result.items.count)) { showAll.toggle() }
                        .buttonStyle(.link).font(.caption).padding(.leading, 26)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func fileDetailLine(_ d: FileDetail) -> String {
        var parts: [String] = []
        parts.append(d.downloadedFrom.map { L("从 %@ 下载的", $0) } ?? L("不是下载的，可能是你自己做的"))
        if let opened = d.lastOpened {
            let days = Int(Date().timeIntervalSince(opened) / 86_400)
            parts.append(days < 1 ? L("今天打开过") : L("最后打开：%ld 天前", days))
        } else {
            parts.append(L("没有打开记录"))
        }
        return parts.joined(separator: " · ")
    }

    /// 说明卡：这是什么、删了会怎样、我们怎么知道的
    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            explanationLine("info.circle", L("这是什么"), L(result.rule.detail))
            explanationLine("arrow.uturn.backward.circle", L("删了会怎样"), ConsequenceBadge.longText(result.rule.consequence))
            explanationLine("magnifyingglass.circle", L("我们怎么知道的"), result.rule.evidence)
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 26)
    }

    private func explanationLine(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 14)
            Text(title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func itemRow(_ item: Item) -> some View {
        HStack(spacing: 8) {
            if cleanable {
                CheckBox(state: model.selected.contains(item.url) ? .on : .off) { model.toggle(item.url) }
            }
            if let owner = AppOwner.guess(item.url) {
                AppIcon(bundleID: owner.bundleID ?? owner.name, name: owner.name, size: 18)
                    .help(L("属于 %@", owner.name))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.displayName).font(.callout).lineLimit(1)
                    if let d = item.detail { FileKindTag(kind: d.kind) }
                }
                if let d = item.detail {
                    // 大文件：从哪来、最后什么时候打开，帮人判断是不是自己做的、还用不用
                    Text(fileDetailLine(d)).font(.caption2).foregroundStyle(.secondary)
                }
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
            if item.detail != nil {
                Button { QuickLook.preview(item.url) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .help(L("预览（看看里面是什么）"))
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("在访达中显示")
        }
        .padding(.leading, 26)
    }
}
