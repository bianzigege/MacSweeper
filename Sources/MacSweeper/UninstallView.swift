import AppKit
import SwiftUI
import SweeperCore

/// “卸载 App”页面：App 清单（很久没用的排前面），选中后 ⌘⌫ 打开确认清单
struct UninstallView: View {
    @EnvironmentObject var model: UninstallModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let busy = model.busyText {
                VStack(spacing: 12) { ProgressView(); Text(busy).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.loading && model.apps.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                appList
            }
            Divider()
            bottomBar
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
        .sheet(item: Binding(get: { model.plan.map(PlanBox.init) }, set: { if $0 == nil { model.cancelPlan() } })) { _ in
            UninstallSheet().environmentObject(model)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            let s = model.unusedSummary
            Label(L("很久没用的 App：%ld 个，共 %@", s.count, formatBytes(s.bytes)), systemImage: "moon.zzz")
                .font(.callout).foregroundStyle(.secondary)
                .help(L("超过 %ld 天没打开过，或者从没打开过", AppInfo.unusedDays))
            Spacer()
            Toggle(L("只看很久没用的"), isOn: $model.onlyUnused).toggleStyle(.checkbox)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("搜索 App"), text: $model.query).textFieldStyle(.plain).frame(width: 120)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var appList: some View {
        List(selection: $model.selection) {
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle.fill").font(.callout).foregroundStyle(.orange)
            }
            if let report = model.lastReport { resultBanner(report) }
            ForEach(model.visibleApps) { app in
                AppRow(app: app, size: model.sizes[app.id])
                    .tag(app.id)
                    .contextMenu {
                        Button(L("卸载…")) { model.requestUninstall(app) }.disabled(app.protection != nil)
                        Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                        Divider()
                        if app.protection == .userList {
                            Button(L("移出保护名单")) { model.setProtected(app, false) }
                        } else if app.protection == nil {
                            Button(L("加入保护名单（不能卸载）")) { model.setProtected(app, true) }
                        }
                    }
            }
        }
        .listStyle(.inset)
    }

    private func resultBanner(_ r: CleanReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if r.trashedCount > 0 {
                Label(L("已卸载 %@：%ld 项（%@）移到了废纸篓", model.lastUninstalled ?? "", r.trashedCount, formatBytes(r.trashedBytes)),
                      systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                HStack {
                    Text(L("后悔了可以撤销；确认没问题后清空废纸篓，空间才会真正释放。"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("撤销这次卸载")) { model.undo() }
                }
            }
            ForEach(Array(r.failures.prefix(5).enumerated()), id: \.offset) { _, f in
                Text("· " + f.reason + "：" + f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack {
            if let app = model.selectedApp {
                Text(app.name).font(.headline)
                if let size = model.sizes[app.id] { Text(formatBytes(size)).foregroundStyle(.secondary) }
            } else {
                Text(L("选中一个 App，按 ⌘⌫ 卸载；也可以把 App 拖进这个窗口"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if let app = model.selectedApp { model.requestUninstall(app) }
            } label: {
                Label(L("卸载…"), systemImage: "trash").frame(minWidth: 90)
            }
            // ⌘⌫：和在访达里“移到废纸篓”是同一个快捷键。只打开确认清单，不会直接删除
            .keyboardShortcut(.delete, modifiers: .command)
            .controlSize(.large)
            .disabled(model.selectedApp == nil || model.selectedApp?.protection != nil || model.busyText != nil)
            .help(L("打开确认清单（⌘⌫）。不会直接删除"))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// sheet(item:) 需要一个 Identifiable 的东西
struct PlanBox: Identifiable {
    let plan: UninstallPlan
    var id: String { plan.app.id }
}

/// App 清单里的一行
struct AppRow: View {
    let app: AppInfo
    let size: Int64?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.body.weight(.medium))
                    if let v = app.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                    tags
                }
                Text(lastUsedText).font(.caption).foregroundStyle(app.isUnused ? .orange : .secondary)
            }
            Spacer()
            Text(size.map(formatBytes) ?? "…").monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .opacity(app.protection == nil ? 1 : 0.55)
    }

    private var lastUsedText: String {
        guard let date = app.lastUsed else { return L("从没打开过") }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        return days < 1 ? L("今天用过") : L("%ld 天前用过", days)
    }

    @ViewBuilder private var tags: some View {
        if app.isUnused && app.protection == nil { Tag(L("很久没用"), .orange) }
        switch app.protection {
        case .system: Tag(L("系统自带"), .secondary)
        case .itself: Tag(L("MacSweeper 自己"), .secondary)
        case .userList: Tag(L("已保护"), .blue)
        case nil: EmptyView()
        }
        if app.needsPassword && app.protection == nil { Tag(L("需要密码"), .secondary) }
        if app.homebrewCask != nil { Tag("Homebrew", .purple) }
    }
}

struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }

    var body: some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// 确认清单：分组列出要移走的文件。默认按钮是“取消”，按回车不会删
struct UninstallSheet: View {
    @EnvironmentObject var model: UninstallModel
    @State private var confirmData = false

    private static let groups: [(UninstallItem.Kind, String, Color)] = [
        (.bundle, "一定会删 · App 本体", .green),
        (.matched, "默认勾选 · ID 完全对得上的缓存和设置", .green),
        (.launchAgent, "默认勾选 · 开机自启项（会先停掉）", .green),
        (.userData, "需要你确认 · 可能有你的数据", .orange),
        (.guessed, "需要你确认 · 按名字找到的，不确定是不是它的", .orange),
        (.shared, "不会动 · 同一厂商其他 App 还在用", .secondary),
        (.systemLevel, "不会动 · 系统级（需要管理员权限，见下方说明）", .secondary),
    ]

    var body: some View {
        if let plan = model.plan {
            VStack(alignment: .leading, spacing: 0) {
                header(plan)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let running = model.runningApp(for: plan) {
                            HStack {
                                Label(L("%@ 正在运行，要先退出才能卸载", plan.app.name), systemImage: "lock.fill")
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button(L("退出%@", running.localizedName ?? plan.app.name)) { model.quitThenReplan(plan) }
                            }
                        }
                        if let cask = plan.app.homebrewCask {
                            Label(L("这个 App 是用 Homebrew 装的，建议在终端运行 brew uninstall --cask %@，不然 Homebrew 会以为它还装着", cask),
                                  systemImage: "terminal").font(.callout).foregroundStyle(.purple)
                        }
                        ForEach(Self.groups, id: \.0) { kind, title, color in
                            let items = plan.items.filter { $0.kind == kind }
                            if !items.isEmpty {
                                Text(L(title)).font(.callout.weight(.semibold)).foregroundStyle(color).padding(.top, 4)
                                ForEach(items) { itemRow($0) }
                                if kind == .systemLevel {
                                    Text(L("这些需要管理员权限，MacSweeper 不会动。卸载后如果不需要了，可以在终端运行 sudo rm 加上路径删除；不确定的话留着也没关系。"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(18)
                }
                Divider()
                footer(plan)
            }
            .frame(width: 620, height: 520)
            .confirmationDialog(L("你勾选了可能有你数据的项目（%@）", formatBytes(model.chosenUserDataBytes)),
                                isPresented: $confirmData, titleVisibility: .visible) {
                Button(L("我知道，一起移到废纸篓"), role: .destructive) { model.uninstall() }
                Button(L("取消"), role: .cancel) {}
            } message: {
                Text(L("里面可能有聊天记录、下载的文件、项目等。移到废纸篓后还能撤销，清空废纸篓后就找不回来了。"))
            }
        }
    }

    private func header(_ plan: UninstallPlan) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.url.path)).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("卸载 %@", plan.app.name)).font(.title3.weight(.semibold))
                Text(L("所有东西都只是移到废纸篓，可以撤销。勾选你要一起移走的文件。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private func itemRow(_ item: UninstallItem) -> some View {
        HStack(spacing: 10) {
            Group {
                if item.kind == .bundle {
                    Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
                } else if !item.kind.removable {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                } else {
                    CheckBox(state: model.chosen.contains(item.url) ? .on : .off) { model.toggle(item) }
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(L(item.what)).font(.callout)
                Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(formatBytes(item.bytes)).font(.callout).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help(L("在访达中显示"))
        }
    }

    private func footer(_ plan: UninstallPlan) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("将移走 %ld 项，共 %@", model.chosenItems.count, formatBytes(model.chosenBytes))).font(.headline)
                if plan.app.needsPassword {
                    Text(L("这个 App 归系统所有，macOS 会弹出窗口要你输入电脑密码")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // 默认按钮是“取消”：按回车或 Esc 都只会取消
            Button(L("取消")) { model.cancelPlan() }
                .keyboardShortcut(.defaultAction)
            // 看不见的按钮：让 Esc 也是取消
            Button("") { model.cancelPlan() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button(L("移到废纸篓"), role: .destructive) {
                if model.chosenUserDataBytes >= UninstallModel.dataWarningBytes { confirmData = true } else { model.uninstall() }
            }
            .disabled(model.runningApp(for: plan) != nil)
        }
        .padding(18)
    }
}
