import AppKit
import SwiftUI
import SweeperCore

struct ContentView: View {
    @EnvironmentObject var model: SweepModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.phase {
            case .idle: emptyState
            case .scanning: busy("正在扫描，大约需要半分钟…")
            case .cleaning: busy("正在移到废纸篓…")
            case .ready: resultList
            }
            if model.phase == .ready {
                Divider()
                footer
            }
        }
        .confirmationDialog(
            "将 \(model.selectedCount) 个项目（\(formatBytes(model.selectedBytes))）移到废纸篓？",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) { model.clean() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("建议先退出相关 App。文件会进入废纸篓，确认电脑正常后再清空。")
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacSweeper").font(.title2.bold())
                Text("磁盘剩余空间：\(formatBytes(model.freeBytes))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .ready {
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
            if let report = model.lastReport { reportBanner(report) }
            if model.needsFullDiskAccess { permissionBanner }
            section(.safe, title: "可放心清理", icon: "checkmark.seal.fill", color: .green)
            section(.review, title: "需确认", icon: "exclamationmark.triangle.fill", color: .orange)
            section(.reportOnly, title: "只报告，请在对应 App 里清理", icon: "info.circle.fill", color: .blue)
            if !model.toolGroups.isEmpty {
                Text("AI 工具与项目")
                    .font(.title3.bold())
                    .padding(.top, 14)
                    .listRowSeparator(.hidden)
                ForEach(model.toolGroups) { group in
                    Section {
                        ForEach(group.results) { RuleRow(result: $0) }
                    } header: {
                        HStack(spacing: 8) {
                            AppIcon(bundleID: group.iconBundleID, name: group.tool, size: 22)
                            Text(group.tool)
                            Spacer()
                            Text(formatBytes(group.bytes))
                        }
                        .font(.headline)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func section(_ safety: Safety, title: String, icon: String, color: Color) -> some View {
        let rows = model.results(for: safety)
        if !rows.isEmpty {
            Section {
                ForEach(rows) { RuleRow(result: $0) }
            } header: {
                HStack {
                    Label(title, systemImage: icon).foregroundStyle(color)
                    Spacer()
                    Text(formatBytes(rows.reduce(0) { $0 + $1.bytes }))
                }
                .font(.headline)
            }
        }
    }

    private func reportBanner(_ report: CleanReport) -> some View {
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

    private var permissionBanner: some View {
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

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选择 \(formatBytes(model.selectedBytes))").font(.headline)
                Text("\(model.selectedCount) 个项目").font(.caption).foregroundStyle(.secondary)
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
                        Label("\(app)正在运行，退出后点“重新扫描”才能清理", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
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

/// AI 工具里每条规则的安全等级小标签
struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        let (text, color): (String, Color) = switch safety {
        case .safe: ("可放心清理", .green)
        case .review: ("需确认", .orange)
        case .reportOnly: ("只报告", .blue)
        }
        Text(text)
            .font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// 读取电脑上已安装 App 的图标；没装的显示首字母。
/// 图标在运行时从 App 本身读取，项目里不存放任何其他公司的 logo
struct AppIcon: View {
    let bundleID: String?
    let name: String
    let size: CGFloat

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = Self.icon(for: bundleID) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(.quaternary)
                .frame(width: size * 0.86, height: size * 0.86)
                .overlay(Text(String(name.prefix(1))).font(.system(size: size * 0.45, weight: .semibold))
                            .foregroundStyle(.secondary))
                .frame(width: size, height: size)
        }
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let id = bundleID else { return nil }
        if let cached = cache[id] { return cached }
        // 有点号的按 Bundle ID 找，否则按 App 名字在“应用程序”里找
        let url = id.contains(".")
            ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            : ["/Applications", NSHomeDirectory() + "/Applications"]
                .map { URL(fileURLWithPath: $0).appendingPathComponent(id + ".app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = image
        return image
    }
}
