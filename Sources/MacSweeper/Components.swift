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

    /// 只用品牌蓝，靠深浅和图标分轻重：
    /// 会自动重建 = 浅蓝底；要重新下载 = 蓝色描边；找不回来 = 实心蓝底白字，最醒目
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        HStack(spacing: 3) {
            Image(systemName: Self.icon(consequence))
            Text(Self.shortText(consequence))
        }
        .font(.caption2.weight(consequence == .lost ? .bold : .medium))
        .foregroundStyle(consequence == .lost ? Color.white : Brand.blue)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(consequence == .lost ? Brand.solid : consequence == .rebuilt ? Brand.blue.opacity(0.12) : .clear, in: shape)
        .overlay(shape.strokeBorder(Brand.blue.opacity(consequence == .redownload ? 0.7 : 0), lineWidth: 1))
    }

    static func icon(_ c: Consequence) -> String {
        switch c {
        case .rebuilt: return "arrow.triangle.2.circlepath"
        case .redownload: return "arrow.down.circle"
        case .lost: return "exclamationmark.triangle.fill"
        }
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

/// 开始扫描前的一句提醒：macOS 接下来可能会弹窗问权限，先说清楚为什么、不允许会怎样
struct PermissionHint: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "hand.raised")
            .font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 440)
    }
}

/// “反馈问题”：发邮件，或者在 GitHub 上提。都会自动带上版本号和系统版本，不带任何文件路径
@MainActor
enum Feedback {
    static let repo = "https://github.com/bianzigege/MacSweeper"
    /// 作者公开的反馈邮箱，没有 GitHub 账号的人用它
    static let email = "bianzigege2026@gmail.com"

    /// 反馈模板：遇到什么问题、怎么出现的、版本号。GitHub 上用加粗标题，邮件里用普通文字
    private static func template(markdown: Bool) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let system = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return [
            markdown ? L("**遇到了什么问题？**") : L("遇到了什么问题？"), "", "",
            markdown ? L("**怎么出现的？**（在哪个页面、点了什么）") : L("怎么出现的？（在哪个页面、点了什么）"), "", "",
            "---",
            L("MacSweeper %@ · macOS %@", UpdateChecker.current, system),
            L("请不要贴出带你名字的文件路径或截图。"),
        ].joined(separator: "\n")
    }

    /// 用“邮件”App 写一封给作者的信，主题和模板已经填好
    static func openMail() {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [URLQueryItem(name: "subject", value: L("MacSweeper 反馈")),
                        URLQueryItem(name: "body", value: template(markdown: false))]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// 打开 GitHub 的反馈页面（需要 GitHub 账号）
    static func openGitHub() {
        var c = URLComponents(string: repo + "/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: template(markdown: true))]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// 没设置“邮件”App 的人，复制地址去自己常用的邮箱发
    static func copyEmail() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email, forType: .string)
    }
}

/// “反馈问题”按钮：点开选发邮件、在 GitHub 上提，或者复制邮箱地址
struct FeedbackMenu: View {
    var body: some View {
        Menu(L("反馈问题")) {
            Button(L("发邮件给作者")) { Feedback.openMail() }
            Button(L("在 GitHub 上提（需要账号）")) { Feedback.openGitHub() }
            Divider()
            Button(L("复制邮箱地址：%@", Feedback.email)) { Feedback.copyEmail() }
        }
        .fixedSize()
        .help(L("会自动带上版本号和系统版本，不带任何文件路径"))
    }
}

/// 品牌色：只用蓝和白两种。和图标、海报、分享页是同一个蓝。
/// “删了会怎样”三个标签也只用这个蓝，靠深浅区分轻重（见 ConsequenceBadge）
enum Brand {
    /// 文字、按钮、勾选框用的蓝：深色模式下亮一点，看得清
    static let blue = Color(nsColor: NSColor(name: nil) { look in
        look.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.58, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.16, green: 0.42, blue: 0.96, alpha: 1)
    })
    /// 实心蓝底（上面放白字）用的蓝，深浅模式都一样，保证白字清楚
    static let solid = Color(red: 0.16, green: 0.42, blue: 0.96)
}

extension Notification.Name {
    /// 有东西移进或移出了废纸篓（卸载、重复文件、撤销），让顶部的剩余空间和撤销记录马上刷新
    static let trashChanged = Notification.Name("MacSweeperTrashChanged")
}

/// 做完以后的完成卡片，三个页面共用：移了多少、硬盘现在剩多少、清空废纸篓后大约多少；可以撤销、打开废纸篓
struct DoneCard: View {
    @EnvironmentObject var disk: SweepModel
    let title: String
    var failures: [(path: String, reason: String)] = []
    /// 还能撤销时才给按钮（废纸篓清空后就撤销不了了）
    var onUndo: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(Brand.blue)
            Text(disk.spaceLine).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let onUndo { Button(L("撤销"), action: onUndo) }
                Button(L("打开废纸篓")) {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                }
            }
            ForEach(Array(failures.prefix(5).enumerated()), id: \.offset) { _, f in
                Text("· " + f.reason + "：" + f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if failures.count > 5 {
                Text(L("还有 %ld 项没能移走", failures.count - 5)).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.blue.opacity(0.35)))
    }
}
