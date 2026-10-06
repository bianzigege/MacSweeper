import AppKit
import SwiftUI

@main
struct MacSweeperApp: App {
    @StateObject private var model = SweepModel()

    init() {
        // 直接用 swift run 启动时也能正常显示窗口和程序坞图标
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MacSweeper") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}
