import AppKit
import SwiftUI
import SweeperCore

/// AI 工具里每条规则的安全等级小标签
struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        let (text, color): (String, Color) = switch safety {
        case .safe: ("可放心清理", .green)
        case .review: ("需确认", .orange)
        case .reportOnly: ("只报告", .blue)
        }
        Text(L(text))
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

/// 可以点击收起/展开的分组标题
struct CollapsibleHeader<Content: View>: View {
    @EnvironmentObject var model: SweepModel
    let key: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { model.toggleCollapsed(key) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(model.isCollapsed(key) ? 0 : 90))
                content
            }
            .font(.headline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.isCollapsed(key) ? L("展开（%ld 项）", count) : L("收起"))
    }
}

/// “删了会怎样”的三档标签
struct ConsequenceBadge: View {
    let consequence: Consequence

    var body: some View {
        let (text, color): (String, Color) = switch consequence {
        case .rebuilt: ("会自动重建", .green)
        case .redownload: ("要重新下载", .orange)
        case .lost: ("找不回来", .red)
        }
        Text(L(text))
            .font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    static func shortText(_ c: Consequence) -> String {
        switch c {
        case .rebuilt: return L("会自动重建")
        case .redownload: return L("要重新下载")
        case .lost: return L("找不回来")
        }
    }

    static func longText(_ c: Consequence) -> String {
        switch c {
        case .rebuilt: return L("会自动重建：这是缓存或日志，程序下次用到会重新生成，你不会察觉区别")
        case .redownload: return L("要重新下载或重新生成：以后需要时能再弄回来（重新下载、重新安装依赖、重新登录），但要花点时间")
        case .lost: return L("找不回来：这是你的数据或作品，移到废纸篓后还能撤销，清空废纸篓就没了。请逐项看清楚")
        }
    }
}

/// 猜一个文件属于哪个 App：看它在 ~/Library/Caches/<ID>、Containers/<ID>、Application Support/<名字> 里
enum AppOwner {
    struct Owner { let name: String; let bundleID: String? }
    private static var cache: [String: Owner?] = [:]

    static func guess(_ url: URL) -> Owner? {
        let bases = ["/Library/Application Support/", "/Library/Caches/", "/Library/Logs/", "/Library/Containers/",
                     "/Library/WebKit/", "/Library/HTTPStorages/", "/Library/Preferences/"]
        guard let r = bases.compactMap({ url.path.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
              var folder = url.path[r.upperBound...].split(separator: "/").first.map(String.init) else { return nil }
        if folder.hasSuffix(".plist") { folder = String(folder.dropLast(6)) }
        if let cached = cache[folder] { return cached }
        var owner: Owner?
        if folder.split(separator: ".").count >= 3,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folder) {
            owner = Owner(name: FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""), bundleID: folder)
        } else if ["/Applications", NSHomeDirectory() + "/Applications"]
                    .map({ URL(fileURLWithPath: $0).appendingPathComponent(folder + ".app") })
                    .contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            owner = Owner(name: folder, bundleID: nil)
        }
        cache[folder] = owner
        return owner
    }
}

/// 文件类型小标签（大文件用）
struct FileKindTag: View {
    let kind: FileDetail.Kind

    var body: some View {
        let (text, color): (String, Color) = switch kind {
        case .video: ("视频", .purple)
        case .image: ("图片", .green)
        case .audio: ("音频", .pink)
        case .installer: ("安装包/镜像", .orange)
        case .archive: ("压缩包", .orange)
        case .virtualMachine: ("虚拟机", .blue)
        case .document: ("文档", .teal)
        case .database: ("数据库", .gray)
        case .other: ("其他", .gray)
        }
        Text(L(text)).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// 快速查看：和在访达里选中按空格一样，弹出一个预览窗口
enum QuickLook {
    static func preview(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// 外观：跟随系统 / 浅色 / 深色。经典的黑白两套，不另造配色
enum Appearance: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }

    /// 套用到整个 App（包括菜单栏的菜单和弹窗）
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func applySaved() {
        (Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system).apply()
    }
}

/// 头部那个切换外观的小按钮
struct AppearanceMenu: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

    var body: some View {
        Menu {
            Picker(L("外观"), selection: $appearance) {
                ForEach(Appearance.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Image(systemName: "circle.lefthalf.filled")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L("外观：跟随系统 / 浅色 / 深色"))
        .onChange(of: appearance) { _ in Appearance.applySaved() }
    }
}
