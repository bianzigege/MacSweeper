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
        .help(model.isCollapsed(key) ? "展开（\(count) 项）" : "收起")
    }
}
