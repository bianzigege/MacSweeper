import AppKit
import SweeperCore

/// “卸载 App”页面的状态：App 清单、选中的 App、卸载计划、结果
@MainActor
final class UninstallModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    /// App 本体大小，后台慢慢算
    @Published var sizes: [String: Int64] = [:]
    @Published var loading = false
    @Published var selection: AppInfo.ID?
    @Published var query = ""
    @Published var onlyUnused = false

    /// 正在看的卸载计划（确认清单）
    @Published var plan: UninstallPlan?
    @Published var planning = false
    /// 确认清单里勾选的文件
    @Published var chosen: Set<URL> = []
    @Published var busyText: String?
    @Published var lastReport: CleanReport?
    @Published var lastUninstalled: String?
    @Published var notice: String?

    var selectedApp: AppInfo? { apps.first { $0.id == selection } }

    /// 很久没用的排前面，再按大小
    var visibleApps: [AppInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return apps
            .filter { !onlyUnused || $0.isUnused }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)
                || $0.url.lastPathComponent.localizedCaseInsensitiveContains(q) }
            .sorted {
                if $0.isUnused != $1.isUnused { return $0.isUnused }
                return (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0)
            }
    }

    var unusedSummary: (count: Int, bytes: Int64) {
        let unused = apps.filter { $0.isUnused && $0.protection == nil }
        return (unused.count, unused.reduce(0) { $0 + (sizes[$1.id] ?? 0) })
    }

    func load() {
        loading = true
        Task {
            let list = await Task.detached(priority: .userInitiated) { AppCatalog.list() }.value
            apps = list
            loading = false
            // 大小在后台一个个算，算好一个显示一个
            for app in list where sizes[app.id] == nil {
                let size = await Task.detached(priority: .utility) { Scanner.allocatedSize(of: app.url) }.value
                sizes[app.id] = size
            }
        }
    }

    // MARK: 卸载流程

    /// 打开确认清单（⌘⌫、右键菜单、拖拽都走这里）。只是列出来，不会删任何东西
    func requestUninstall(_ app: AppInfo) {
        notice = nil
        if let p = app.protection {
            notice = p == .system ? L("“%@”是苹果自带的 App，不能卸载", app.name)
                : p == .itself ? L("不能卸载 MacSweeper 自己")
                : L("“%@”在保护名单里。要卸载，先在右键菜单里把它移出保护名单", app.name)
            return
        }
        selection = app.id
        planning = true
        Task {
            let plan = await Task.detached(priority: .userInitiated) { UninstallPlanner.plan(for: app) }.value
            self.plan = plan
            chosen = Set(plan.items.filter { $0.kind.selectedByDefault }.map(\.url))
            planning = false
        }
    }

    /// 拖进来的 App
    func requestUninstall(url: URL) {
        let app = apps.first { $0.url.standardizedFileURL == url.standardizedFileURL } ?? AppCatalog.info(for: url)
        guard PathGuard.isAllowedApp(url) || app.protection != nil else {
            notice = L("只能卸载“应用程序”文件夹里的 App")
            return
        }
        requestUninstall(app)
    }

    /// 已经被移走（拖进废纸篓）的 App：列出它留下的文件
    func requestLeftovers(_ removed: AppInfo) {
        notice = nil
        planning = true
        Task {
            let plan = await Task.detached(priority: .userInitiated) { UninstallPlanner.leftovers(ofRemovedApp: removed) }.value
            planning = false
            guard let plan else {
                notice = L("%@ 没有留下需要清理的文件", removed.name)
                return
            }
            self.plan = plan
            chosen = Set(plan.items.filter { $0.kind.selectedByDefault }.map(\.url))
        }
    }

    func cancelPlan() { plan = nil }

    func toggle(_ item: UninstallItem) {
        guard item.kind != .bundle, item.kind.removable else { return }
        if chosen.contains(item.url) { chosen.remove(item.url) } else { chosen.insert(item.url) }
    }

    var chosenItems: [UninstallItem] {
        plan?.items.filter { $0.kind == .bundle || ($0.kind.removable && chosen.contains($0.url)) } ?? []
    }

    var chosenBytes: Int64 { chosenItems.reduce(0) { $0 + $1.bytes } }

    /// 勾选了的、可能有你数据的项目大小（超过 100MB 要多确认一次）
    var chosenUserDataBytes: Int64 {
        chosenItems.filter { $0.kind == .userData || $0.kind == .guessed }.reduce(0) { $0 + $1.bytes }
    }

    static let dataWarningBytes: Int64 = 100_000_000

    /// 这个 App 现在是不是在运行
    func runningApp(for plan: UninstallPlan) -> NSRunningApplication? {
        guard let id = plan.app.bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    /// 像 ⌘Q 一样让它退出，然后重新生成清单
    func quitThenReplan(_ plan: UninstallPlan) {
        guard let running = runningApp(for: plan) else { return }
        busyText = L("正在退出 %@…", plan.app.name)
        Task {
            running.terminate()
            let deadline = Date().addingTimeInterval(20)
            while !running.isTerminated && Date() < deadline { try? await Task.sleep(nanoseconds: 300_000_000) }
            busyText = nil
            if running.isTerminated { requestUninstall(plan.app) }
            else { notice = L("%@ 没有退出，可能在等你保存内容或确认。请切换过去处理一下", plan.app.name) }
        }
    }

    /// 真正执行：移到废纸篓
    func uninstall() {
        guard let plan else { return }
        let selected = chosen
        self.plan = nil
        busyText = L("正在卸载 %@…", plan.app.name)
        if plan.app.needsPassword { busyText = L("正在卸载 %@，请在弹出的窗口里输入电脑密码…", plan.app.name) }
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                Uninstaller.uninstall(plan, selected: selected)
            }.value
            lastReport = report
            lastUninstalled = plan.app.name
            busyText = nil
            selection = nil
            load()
        }
    }

    /// 撤销上次卸载（和“撤销上次清理”是同一份记录）
    /// 撤销刚才这次卸载（按记录编号，不会误撤别的清理）
    func undo() {
        guard let id = lastReport?.batchID else { return }
        busyText = L("正在把 %@ 放回原处…", lastUninstalled ?? "")
        Task {
            let r = await Task.detached(priority: .userInitiated) { Undo.restore(id: id) }.value
            busyText = nil
            lastReport = nil
            if let r {
                notice = r.failures.isEmpty
                    ? L("已放回 %ld 项（%@）", r.restoredCount, formatBytes(r.restoredBytes))
                    : L("已放回 %ld 项，%ld 项没能放回（可能需要电脑密码），请到废纸篓里手动拖回", r.restoredCount, r.failures.count)
            }
            load()
        }
    }

    func setProtected(_ app: AppInfo, _ protected: Bool) {
        ProtectedApps.set(app, protected: protected)
        load()
    }
}
