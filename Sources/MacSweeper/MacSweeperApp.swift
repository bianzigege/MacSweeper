import AppKit
import SwiftUI

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

/// 把 App 拖到程序坞里的 MacSweeper 图标上时，系统会把它“交给”MacSweeper 打开，这里转给界面去卸载
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// MacSweeper 还没打开时拖过来的 App：界面还没准备好，先记下来，界面出现后再处理
    static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "app" {
            Self.pending.append(url)
            NotificationCenter.default.post(name: .uninstallRequested, object: nil)
        }
    }
}

extension Notification.Name {
    static let uninstallRequested = Notification.Name("MacSweeperUninstallRequested")
}
