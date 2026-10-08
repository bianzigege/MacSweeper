import Foundation

/// 盯着“应用程序”文件夹：有 App 被移走（通常是你拖进了废纸篓）时通知你，用来提醒顺手清理它留下的文件。
/// 只是“看”，不动任何东西。读“应用程序”不需要任何特殊权限（读废纸篓才需要“完全磁盘访问权限”）
public final class AppRemovalWatcher: @unchecked Sendable {
    public let directories: [URL]
    private let onRemoved: @Sendable (AppInfo) -> Void
    private let queue = DispatchQueue(label: "MacSweeper.AppRemovalWatcher")
    private var sources: [DispatchSourceFileSystemObject] = []
    /// 现在装着的 App（路径 → 信息）。App 被移走后就读不到它的信息了，所以要事先记下来
    private var snapshot: [String: AppInfo] = [:]
    /// 移走后等多久再判断（App 更新时会先删旧的再放新的）
    let settleSeconds: Double

    public init(directories: [URL] = [URL(fileURLWithPath: "/Applications"),
                                      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
                settleSeconds: Double = 3,
                onRemoved: @escaping @Sendable (AppInfo) -> Void) {
        self.directories = directories
        self.settleSeconds = settleSeconds
        self.onRemoved = onRemoved
        for url in currentApps() { snapshot[url.path] = AppCatalog.info(for: url) }
    }

    public func start() {
        guard sources.isEmpty else { return }
        for dir in directories {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
            src.setEventHandler { [weak self] in self?.check() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }

    public func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    deinit { stop() }

    private func currentApps() -> [URL] {
        directories.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".app") }.map { dir.appendingPathComponent($0) }
        }
    }

    private func check() {
        let now = Set(currentApps().map(\.path))
        for path in now where snapshot[path] == nil || snapshot[path]?.bundleID == nil {
            snapshot[path] = AppCatalog.info(for: URL(fileURLWithPath: path))
            // 新装的 App 可能还没拷贝完（读不到 ID），过一会儿再读一次
            if snapshot[path]?.bundleID == nil {
                queue.asyncAfter(deadline: .now() + settleSeconds + 2) { [weak self] in
                    guard let self, FileManager.default.fileExists(atPath: path) else { return }
                    self.snapshot[path] = AppCatalog.info(for: URL(fileURLWithPath: path))
                }
            }
        }
        for (path, app) in snapshot where !now.contains(path) {
            snapshot[path] = nil
            // MacSweeper 自己卸载的不用再提醒
            if Uninstaller.wasRemovedByUs(app.url) { continue }
            queue.asyncAfter(deadline: .now() + settleSeconds) { [weak self] in
                // 等一会儿还是没回来，才算真的移走了
                guard !FileManager.default.fileExists(atPath: path) else { return }
                self?.onRemoved(app)
            }
        }
    }
}

extension UninstallPlanner {
    /// 一个已经被移走的 App 留下了哪些文件。没有可清理的、受保护的、
    /// 还装着另一份同 ID 的（比如 App 更新、挪到了子文件夹）都返回 nil
    public static func leftovers(ofRemovedApp app: AppInfo,
                                 library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
                                 systemLibrary: URL = URL(fileURLWithPath: "/Library"),
                                 installedIDs: Set<String>? = nil,
                                 otherCopies: [URL]? = nil) -> UninstallPlan? {
        guard app.protection == nil, app.bundleID != nil else { return nil }
        let full = plan(for: app, library: library, systemLibrary: systemLibrary,
                        installedIDs: installedIDs, otherCopies: otherCopies)
        guard full.note == nil else { return nil }
        let items = full.items.filter { $0.kind != .bundle }
        guard items.contains(where: { $0.kind.removable }) else { return nil }
        return UninstallPlan(app: app, items: items)
    }
}
