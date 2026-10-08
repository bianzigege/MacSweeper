import Foundation
import SweeperCore

/// 新版本提醒：每天最多去 GitHub 查一次最新发布的版本号，比当前新就在界面上提示。
/// 只查版本号、不自动下载；没有网络就当没事
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Sendable {
        let version: String
        let url: URL
    }

    @Published var available: Release?
    @Published var dismissed = false

    static let releaseAPI = URL(string: "https://api.github.com/repos/bianzigege/MacSweeper/releases/latest")!
    static let lastCheckKey = "lastUpdateCheck"
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        Task { await check() }
    }

    func check() async {
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: Self.releaseAPI, timeoutInterval: 10)
        request.setValue("MacSweeper/\(Self.current)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Version.isNewer(latest, than: Self.current) {
            available = Release(version: latest, url: page)
        }
    }
}
