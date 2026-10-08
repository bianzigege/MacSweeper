import AppKit
import SwiftUI
import SweeperCore

/// “重复文件”页面：一组一组列出内容完全一样的文件，默认一个都不勾，每组至少留一份
struct DuplicatesView: View {
    @EnvironmentObject var model: DuplicatesModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            if let busy = model.busyText {
                VStack(spacing: 12) { ProgressView(); Text(busy).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.scanning {
                VStack(spacing: 12) {
                    if model.progress.total > 0 {
                        ProgressView(value: Double(model.progress.done), total: Double(model.progress.total)).frame(width: 320)
                    } else {
                        ProgressView()
                    }
                    Text(L(model.progress.phase.isEmpty ? "正在列出文件…" : model.progress.phase)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.scanned {
                intro
            } else {
                toolbar
                Divider()
                list
                Divider()
                footer
            }
        }
        .confirmationDialog(L("将 %ld 个重复文件移到废纸篓？", model.selected.count), isPresented: $confirming,
                            titleVisibility: .visible) {
            Button(L("移到废纸篓"), role: .destructive) { model.clean() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("每组都会留下至少一份。移走前会再核对一遍内容，后来改过的不会删。可以撤销。"))
        }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc").font(.system(size: 52)).foregroundStyle(.secondary)
            Text(L("找出内容完全一样的文件")).font(.title3)
            Text(L("查找桌面、文稿、下载、影片等文件夹里 1MB 以上的文件，逐字节比对内容。项目文件夹、App 的缓存和媒体库不会碰。"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button { model.scan() } label: { Text(L("开始查找")).frame(minWidth: 120) }
                .controlSize(.large).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(L("%ld 组重复文件，每组只留一份能腾出 %@", model.groups.count, formatBytes(model.totalSaving)),
                  systemImage: "doc.on.doc").font(.callout)
            Spacer()
            Button(L("每组只留一份（推荐）")) { model.keepOnePerGroup() }
                .help(L("每组保留建议的那一份（优先保留不在“下载”里、名字不像副本的），其余勾上"))
            Button(L("全部取消")) { model.clearSelection() }.disabled(model.selected.isEmpty)
            Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }.help(L("重新查找"))
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var list: some View {
        List {
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle.fill").font(.callout).foregroundStyle(.orange)
            }
            if let r = model.lastReport, r.trashedCount > 0 {
                HStack {
                    Label(L("已将 %ld 个重复文件移到废纸篓，腾出 %@", r.trashedCount, formatBytes(r.trashedBytes)),
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button(L("撤销")) { model.undo() }
                }
                ForEach(Array(r.failures.prefix(5).enumerated()), id: \.offset) { _, f in
                    Text("· " + f.reason + "：" + f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if model.groups.isEmpty {
                Text(L("没有找到重复文件")).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.files) { file in row(file, group) }
                } header: {
                    HStack {
                        Text(L("%@ × %ld 份", formatBytes(group.size), group.files.count)).font(.headline)
                        if group.allClones {
                            Tag(L("克隆副本，删了不省空间"), .secondary)
                                .help(L("这些文件在硬盘上共用同一份空间（比如在访达里按 ⌘D 复制出来的），删掉也腾不出空间"))
                        }
                        Spacer()
                        if !group.allClones {
                            Text(L("可腾出 %@", formatBytes(group.wastedBytes))).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ file: DuplicateGroup.File, _ group: DuplicateGroup) -> some View {
        HStack(spacing: 8) {
            CheckBox(state: model.selected.contains(file.url) ? .on : .off) { model.toggle(file, in: group) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    if file.url == group.suggestedKeep.url { Tag(L("建议保留"), .green) }
                }
                Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(file.modified, format: .dateTime.year().month().day())
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().help(L("最后修改时间"))
            Button { NSWorkspace.shared.open(file.url) } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless).help(L("打开看看"))
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help(L("在访达中显示"))
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("已选择 %@", formatBytes(model.selectedFreed))).font(.headline)
                Text(L("%ld 个文件", model.selected.count)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { confirming = true } label: { Label(L("移到废纸篓"), systemImage: "trash").frame(minWidth: 110) }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(model.selected.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
