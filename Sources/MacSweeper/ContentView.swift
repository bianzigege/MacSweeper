import AppKit
import SwiftUI
import SweeperCore

struct ContentView: View {
    @EnvironmentObject var model: SweepModel
    @EnvironmentObject var uninstall: UninstallModel
    @State private var tab: Tab = .clean
    @State private var dropTargeted = false

    enum Tab { case clean, uninstall, duplicates }
    @State private var confirming = false
    @State var confirmingUndo = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == .uninstall {
                UninstallView()
            } else if tab == .duplicates {
                DuplicatesView()
            } else {
                switch model.phase {
                case .idle: emptyState
                case .scanning: scanningView
                case .cleaning: busy(model.busyText)
                case .ready: resultList
                }
                if model.phase == .ready {
                    Divider()
                    footer
                }
            }
        }
        // 把 App 拖进窗口：切到“卸载 App”，打开确认清单（不会直接删）
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension == "app" else { return }
                    DispatchQueue.main.async { openUninstall(url) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 3).padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uninstallRequested)) { _ in takePending() }
        .onAppear { takePending() }
        .confirmationDialog(
            L("将 %ld 个项目（%@）移到废纸篓？", model.selectedCount, formatBytes(model.selectedBytes)),
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) { model.clean() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("建议先退出相关 App。文件会进入废纸篓，确认电脑正常后再清空。")
        }
        .confirmationDialog(L("把上次清理的 %ld 个项目放回原处？", model.undoBatch?.moves.count ?? 0),
                            isPresented: $confirmingUndo, titleVisibility: .visible) {
            Button("放回原处") { model.undoLast() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会从废纸篓里把它们移回原来的位置。原位置已经有新文件的（比如 App 重新生成了缓存）不会覆盖。")
        }
    }

    /// 处理拖到程序坞图标上的 App
    private func takePending() {
        let urls = AppDelegate.pending
        AppDelegate.pending.removeAll()
        let trashed = AppDelegate.pendingLeftovers
        AppDelegate.pendingLeftovers.removeAll()
        if let url = urls.last {
            openUninstall(url)
        } else if let app = trashed.last {
            // 你拖进废纸篓的 App：打开它留下的文件的清单
            tab = .uninstall
            uninstall.load()
            uninstall.requestLeftovers(app)
        }
    }

    private func openUninstall(_ url: URL) {
        tab = .uninstall
        if uninstall.apps.isEmpty { uninstall.load() }
        uninstall.requestUninstall(url: url)
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Text("MacSweeper").font(.title2.bold())
                    Picker("", selection: $tab) {
                        Text(L("清理垃圾")).tag(Tab.clean)
                        Text(L("卸载 App")).tag(Tab.uninstall)
                        Text(L("重复文件")).tag(Tab.duplicates)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Text(L("磁盘剩余空间：%@", formatBytes(model.freeBytes)))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer()
            if tab == .clean && model.phase == .ready {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索，如 微信", text: $model.query)
                        .textFieldStyle(.plain)
                        .frame(width: 170)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                Button { model.openCustomRules() } label: { Label("自定义规则", systemImage: "slider.horizontal.3") }
                    .labelStyle(.iconOnly)
                    .help("自定义规则：打开规则文件，改完保存后点“重新扫描”生效")
                Button { model.scan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: 状态页

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 56)).foregroundStyle(.secondary)
            Text("扫描一下，看看哪些空间可以腾出来").font(.title3)
            Text("只扫描、不删除。清理前会列出清单让你确认，文件只会移到废纸篓。")
                .font(.callout).foregroundStyle(.secondary)
            Button { model.scan() } label: {
                Text("开始扫描").frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var scanningView: some View {
        VStack(spacing: 12) {
            if model.progress.total > 0 {
                ProgressView(value: Double(model.progress.done), total: Double(model.progress.total))
                    .frame(width: 320)
                Text(L("正在扫描（%ld/%ld）：%@", model.progress.done, model.progress.total, L(model.progress.name)))
                    .foregroundStyle(.secondary).monospacedDigit()
            } else {
                ProgressView()
                Text("正在准备扫描…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func busy(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 结果列表

    private var resultList: some View {
        List {
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).padding(.vertical, 6)
            }
            if model.query.isEmpty { summaryCard }
            if !model.customProblems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("自定义规则有问题，下面这些没有生效：", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    ForEach(model.customProblems, id: \.self) { Text("· " + $0).font(.callout) }
                    Button("打开自定义规则文件") { model.openCustomRules() }.padding(.top, 2)
                }
                .padding(.vertical, 6)
            }
            if let undo = model.lastUndo { undoBanner(undo) }
            if let report = model.lastReport { reportBanner(report) }
            if !model.appsToReopen.isEmpty { reopenBanner }
            if model.needsFullDiskAccess { permissionBanner }
            if !model.query.isEmpty && model.results.allSatisfy({ !model.matches($0) }) {
                Text(L("没有找到和“%@”有关的项目", model.query)).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            section(.safe, title: "可放心清理", icon: "checkmark.seal.fill", color: .green)
            section(.review, title: "需确认", icon: "exclamationmark.triangle.fill", color: .orange)
            if model.reportsPending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在统计各应用的总占用（微信、Chrome 等），上面的可以先清理")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            section(.reportOnly, title: "只报告，请在对应 App 里清理", icon: "info.circle.fill", color: .blue)
            if !model.toolGroups.isEmpty {
                Text("AI 工具与项目")
                    .font(.title3.bold())
                    .padding(.top, 14)
                    .listRowSeparator(.hidden)
                ForEach(model.toolGroups) { group in
                    Section {
                        if !model.isCollapsed("tool:" + group.tool) {
                            ForEach(group.results) { RuleRow(result: $0) }
                        }
                    } header: {
                        CollapsibleHeader(key: "tool:" + group.tool, count: group.results.count) {
                            AppIcon(bundleID: group.iconBundleID, name: L(group.tool), size: 22)
                            Text(L(group.tool))
                            Spacer()
                            Text(formatBytes(group.bytes))
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func section(_ safety: Safety, title: String, icon: String, color: Color) -> some View {
        let rows = model.results(for: safety)
        let key = safety.rawValue
        if !rows.isEmpty {
            Section {
                if !model.isCollapsed(key) { ForEach(rows) { RuleRow(result: $0) } }
            } header: {
                CollapsibleHeader(key: key, count: rows.count) {
                    Label(L(title), systemImage: icon).foregroundStyle(color)
                    Spacer()
                    Text(formatBytes(rows.reduce(0) { $0 + $1.bytes }))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("已选择 %@", formatBytes(model.selectedBytes))).font(.headline)
                Text(L("%ld 个项目", model.selectedCount)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { confirming = true } label: {
                Label("移到废纸篓", systemImage: "trash").frame(minWidth: 110)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedBytes == 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
