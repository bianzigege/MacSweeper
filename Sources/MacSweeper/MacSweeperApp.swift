import AppKit
import SwiftUI
import SweeperCore
import UserNotifications

@main
struct MacSweeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = SweepModel()
    @StateObject private var uninstall = UninstallModel()

    init() {
        // 直接用 swift run 启动时也能正常显示窗口和程序坞图标
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MacSweeper") {
            ContentView()
                .environmentObject(model)
                .environmentObject(uninstall)
                .frame(minWidth: 680, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

/// 处理从外面来的卸载请求：拖到程序坞图标、访达右键菜单、拖进废纸篓的提醒
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 界面还没准备好时来的请求，先记下来，界面出现后再处理
    static var pending: [URL] = []
    /// 被移走了的 App：要清理的是它留下的文件
    static var pendingLeftovers: [AppInfo] = []
    static private(set) var shared: AppDelegate?

    private let services = ServiceProvider()
    private var watcher: AppRemovalWatcher?

    static let watchTrashKey = "watchTrash"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // 访达右键菜单“用 MacSweeper 卸载”
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self
        UserDefaults.standard.register(defaults: [Self.watchTrashKey: true])
        updateTrashWatching()
    }

    /// 关掉窗口后继续在后台运行，才能在你把 App 拖进废纸篓时提醒
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.request(urls.filter { $0.pathExtension == "app" })
    }

    static func request(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.append(contentsOf: urls)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .uninstallRequested, object: nil)
    }

    // MARK: 拖进废纸篓的提醒

    func updateTrashWatching() {
        watcher?.stop()
        watcher = nil
        guard UserDefaults.standard.bool(forKey: Self.watchTrashKey) else { return }
        watcher = AppRemovalWatcher { app in
            // 找它留下的文件；有可清理的才提醒
            guard let plan = UninstallPlanner.leftovers(ofRemovedApp: app) else {
                OperationLog.write("WATCH \(app.url.lastPathComponent) 被移走了，没有需要清理的残留")
                return
            }
            OperationLog.write("WATCH \(app.url.lastPathComponent) 被移走了，留下 \(plan.items.count) 个相关文件，已提醒")
            let bytes = plan.items.filter { $0.kind.selectedByDefault }.reduce(0) { $0 + $1.bytes }
            DispatchQueue.main.async { AppDelegate.shared?.notifyLeftovers(app, count: plan.items.count, bytes: bytes) }
        }
        watcher?.start()
        OperationLog.write("WATCH 开始盯着“应用程序”文件夹")
    }

    private func notifyLeftovers(_ app: AppInfo, count: Int, bytes: Int64) {
        let name = app.name
        Self.pendingLeftovers.append(app)
        if NSApp.isActive {
            NotificationCenter.default.post(name: .uninstallRequested, object: nil)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = L("你把 %@ 移到了废纸篓", name)
        content.body = L("它还留下 %ld 个相关文件（%@ 可以放心清理）。点这里看看要不要一起清理。", count, formatBytes(bytes))
        content.userInfo = ["path": app.url.path]
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                center.add(UNNotificationRequest(identifier: app.url.path, content: content, trigger: nil))
            } else {
                // 没开通知权限：在程序坞里跳一下图标，你切回 MacSweeper 时再弹出清单
                DispatchQueue.main.async { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !Self.pendingLeftovers.isEmpty { NotificationCenter.default.post(name: .uninstallRequested, object: nil) }
    }

    // 点了通知
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .uninstallRequested, object: nil)
        }
        done()
    }

    // MacSweeper 在前台时也显示通知
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }
}

/// 访达右键菜单 →“服务”→“用 MacSweeper 卸载”。系统在 Info.plist 的 NSServices 里找到它，调用下面这个方法。
/// 可以在“系统设置 → 键盘 → 键盘快捷键 → 服务”里给它设一个快捷键
final class ServiceProvider: NSObject {
    @objc func uninstallApp(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        DispatchQueue.main.async { AppDelegate.request(urls.filter { $0.pathExtension == "app" }) }
    }
}

extension Notification.Name {
    static let uninstallRequested = Notification.Name("MacSweeperUninstallRequested")
}
