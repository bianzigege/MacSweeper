import AppKit
import SwiftUI
import SweeperCore

/// “空间地图”页面的状态
@MainActor
final class DiskMapModel: ObservableObject {
    @Published var root: DiskNode?
    /// 当前看到哪一层（第一个是主目录）
    @Published var path: [DiskNode] = []
    @Published var building = false
    @Published var progress = DiskMap.Progress(files: 0, bytes: 0)
    @Published var hovered: DiskNode?

    var current: DiskNode? { path.last }

    func build() {
        building = true
        Task {
            let tree = await Task.detached(priority: .userInitiated) {
                DiskMap.build { p in Task { @MainActor in self.progress = p } }
            }.value
            root = tree
            path = [tree]
            building = false
        }
    }

    func open(_ node: DiskNode) {
        guard node.kind == .folder, !node.children.isEmpty else { return }
        path.append(node)
        hovered = nil
    }

    func goBack(to index: Int) {
        path = Array(path.prefix(index + 1))
        hovered = nil
    }
}

/// “空间地图”页面：色块越大，占的空间越多。只看，不删
struct DiskMapView: View {
    @EnvironmentObject var model: DiskMapModel

    var body: some View {
        VStack(spacing: 0) {
            if model.building {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("已扫描 %ld 个文件，%@", model.progress.files, formatBytes(model.progress.bytes)))
                        .foregroundStyle(.secondary).monospacedDigit()
                    Text(L("整个主目录大约要半分钟")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let current = model.current {
                breadcrumb(current)
                Divider()
                HStack(spacing: 0) {
                    GeometryReader { geo in treemap(current, size: geo.size) }
                        .padding(10)
                    Divider()
                    sideList(current).frame(width: 250)
                }
                Divider()
                infoBar
            } else {
                intro
            }
        }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.square").font(.system(size: 52)).foregroundStyle(.secondary)
            Text(L("看看空间都被谁占了")).font(.title3)
            Text(L("扫描整个主目录，用色块显示每个文件夹、文件占多大。点色块可以一层层往里看。只看，不删。"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Button { model.build() } label: { Text(L("开始扫描")).frame(minWidth: 120) }
                .controlSize(.large).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func breadcrumb(_ current: DiskNode) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(model.path.enumerated()), id: \.offset) { i, node in
                if i > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                Button(i == 0 ? L("主目录") : node.name) { model.goBack(to: i) }
                    .buttonStyle(.link)
                    .disabled(i == model.path.count - 1)
            }
            Text(formatBytes(current.size)).foregroundStyle(.secondary).padding(.leading, 6)
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([current.url]) } label: { Image(systemName: "magnifyingglass") }
                .help(L("在访达中显示"))
            Button { model.build() } label: { Image(systemName: "arrow.clockwise") }.help(L("重新扫描"))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func treemap(_ node: DiskNode, size: CGSize) -> some View {
        let kids = node.children
        let rects = Treemap.layout(kids.map(\.size), width: Double(size.width), height: Double(size.height))
        return ZStack(alignment: .topLeading) {
            ForEach(rects, id: \.index) { r in
                block(kids[r.index], index: r.index, width: r.width, height: r.height)
                    .offset(x: r.x, y: r.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func block(_ node: DiskNode, index: Int, width: Double, height: Double) -> some View {
        let hovered = model.hovered?.id == node.id
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Self.color(node, index: index).opacity(hovered ? 1 : 0.82))
            if width > 64 && height > 30 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.kind == .others ? L("其他小文件") : node.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(formatBytes(node.size)).font(.caption2).monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(5)
            }
        }
        .frame(width: max(0, width - 2), height: max(0, height - 2))
        .contentShape(Rectangle())
        .onHover { inside in if inside { model.hovered = node } else if model.hovered?.id == node.id { model.hovered = nil } }
        .onTapGesture { model.open(node) }
        .contextMenu {
            if node.kind == .folder && !node.children.isEmpty { Button(L("看看里面")) { model.open(node) } }
            if node.kind != .others {
                Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            }
        }
        .help(node.kind == .folder ? L("点一下看看里面") : node.name)
    }

    private func sideList(_ node: DiskNode) -> some View {
        List(Array(node.children.enumerated()), id: \.element.id) { i, child in
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Self.color(child, index: i)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(child.kind == .others ? L("其他小文件") : child.name).lineLimit(1).truncationMode(.middle)
                    Text(formatBytes(child.size) + String(format: " · %.1f%%", node.size > 0 ? Double(child.size) / Double(node.size) * 100 : 0))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if child.kind == .folder && !child.children.isEmpty {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.open(child) }
            .onHover { if $0 { model.hovered = child } }
            .contextMenu {
                if child.kind != .others {
                    Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
                }
            }
        }
        .listStyle(.inset)
    }

    private var infoBar: some View {
        HStack {
            if let h = model.hovered {
                Text(h.kind == .others ? L("其他小文件") : h.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(formatBytes(h.size)).monospacedDigit()
            } else {
                Text(L("只看，不删。要清理请用“清理垃圾”“重复文件”，或者在访达里自己处理。"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// 颜色：文件按类型，文件夹按顺序轮流用几种蓝绿紫
    static func color(_ node: DiskNode, index: Int) -> Color {
        switch node.kind {
        case .others: return Color(white: 0.6)
        case .folder:
            let palette: [Color] = [Color(red: 0.20, green: 0.45, blue: 0.85), Color(red: 0.13, green: 0.60, blue: 0.62),
                                    Color(red: 0.42, green: 0.36, blue: 0.80), Color(red: 0.18, green: 0.55, blue: 0.40),
                                    Color(red: 0.30, green: 0.40, blue: 0.60)]
            return palette[index % palette.count]
        case .file:
            switch node.url.pathExtension.lowercased() {
            case "mp4", "mov", "m4v", "mkv", "avi", "webm": return Color(red: 0.62, green: 0.30, blue: 0.70)   // 视频
            case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "psd": return Color(red: 0.35, green: 0.65, blue: 0.30)   // 图片
            case "mp3", "wav", "m4a", "aac", "flac", "aiff": return Color(red: 0.85, green: 0.40, blue: 0.55)   // 音频
            case "zip", "rar", "7z", "tar", "gz", "dmg", "pkg", "iso": return Color(red: 0.85, green: 0.55, blue: 0.20)   // 压缩包、安装包
            case "sqlite", "db", "sqlite3", "realm": return Color(red: 0.50, green: 0.45, blue: 0.40)   // 数据库
            default: return Color(red: 0.45, green: 0.50, blue: 0.55)
            }
        }
    }
}
