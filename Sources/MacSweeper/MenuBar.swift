import AppKit
import SwiftUI
import SweeperCore
import UserNotifications

/// 菜单栏小工具的数据：剩余空间（每分钟刷新）、上次扫描能腾出多少、空间不足提醒
@MainActor
final class MenuBarModel: ObservableObject {
    @Published var freeBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    private var timer: Timer?

    static let showKey = "showMenuBar"
    static let lastSafeKey = "lastScanSafeBytes"
    static let lastScanDateKey = "lastScanDate"
    static let lastWarnKey = "lastLowSpaceWarning"
    /// 低于这个就算空间不足：10GB 或 10%
    static let lowBytes: Int64 = 10_000_000_000
    static let lowRatio = 0.10

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var isLow: Bool {
        totalBytes > 0 && (freeBytes < Self.lowBytes || Double(freeBytes) / Double(totalBytes) < Self.lowRatio)
    }

    /// 上次扫描“可放心清理”多少（扫描时由 SweepModel 记下来）
    var lastSafeBytes: Int64 { Int64(UserDefaults.standard.integer(forKey: Self.lastSafeKey)) }
    var lastScanDate: Date? { UserDefaults.standard.object(forKey: Self.lastScanDateKey) as? Date }

    func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        freeBytes = v?.volumeAvailableCapacityForImportantUsage ?? 0
        totalBytes = Int64(v?.volumeTotalCapacity ?? 0)
        if isLow { warnIfNeeded() }
    }

    /// 空间不足时提醒一次，一天最多一次
    private func warnIfNeeded() {
        let last = UserDefaults.standard.object(forKey: Self.lastWarnKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastWarnKey)
        let content = UNMutableNotificationContent()
        content.title = L("硬盘空间不多了")
        content.body = L("只剩 %@。打开 MacSweeper 扫描一下，看看能腾出多少。", formatBytes(freeBytes))
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "low-space", content: content, trigger: nil))
        }
    }

    /// 菜单栏上显示的短文字，比如“91 GB”
    var label: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useTB]
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: freeBytes)
    }
}

/// 菜单栏里的菜单内容
struct MenuBarMenu: View {
    @EnvironmentObject var menu: MenuBarModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuBarModel.showKey) private var show = true

    var body: some View {
        Text(L("剩余 %@ / 共 %@", formatBytes(menu.freeBytes), formatBytes(menu.totalBytes)))
        if menu.isLow { Text(L("空间不多了，建议清理")) }
        if menu.lastSafeBytes > 0, let date = menu.lastScanDate {
            Text(L("上次扫描（%@）：可放心清理 %@", date.formatted(.dateTime.month().day().hour().minute()),
                   formatBytes(menu.lastSafeBytes)))
        }
        Divider()
        Button(L("打开 MacSweeper")) { open() }
        Button(L("扫描一下")) {
            open()
            NotificationCenter.default.post(name: .scanRequested, object: nil)
        }
        Divider()
        Toggle(L("在菜单栏显示"), isOn: $show)
        Button(L("退出 MacSweeper")) { NSApp.terminate(nil) }
    }

    private func open() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let scanRequested = Notification.Name("MacSweeperScanRequested")
}
