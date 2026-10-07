import Foundation

/// 用户自己加的规则，放在 ~/Library/Application Support/MacSweeper/自定义规则.json，不用改代码。
/// 自定义规则和内置规则一样受安全护栏保护：只能清理主目录里的东西，受保护目录本身不能删，
/// App 正在运行时会锁住。没写安全等级的默认“需确认”。
///
/// 文件格式（一个数组，每一项是一条规则）：
/// {
///   "name": "某某 App 的缓存",          必填
///   "detail": "说明文字",               可选
///   "safety": "review",                可选：safe（可放心清理）/ review（需确认）/ reportOnly（只报告）
///   "contents": "~/某个目录",           清理这个目录里的每一项（目录本身保留）
///   "paths": ["~/a", "~/b/*.log"],     或者：清理这些路径本身（可以用 *）
///   "files": {"in": "~/Downloads", "extensions": ["zip"]},   或者：清理目录里这些扩展名的文件
///   "quitApps": ["com.example.app"],   可选：这些 App 运行时不清理
///   "tool": "某某 App",                可选：放进“AI 工具与项目”里按工具分组
///   "iconApp": "com.example.app",      可选：分组图标从这个 App 读取
///   "enabled": true                    可选：写 false 暂时停用
/// }
public enum CustomRules {
    public static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSweeper/自定义规则.json")

    struct Entry: Decodable {
        let name: String
        let detail: String?
        let safety: String?
        let contents: String?
        let paths: [String]?
        let files: Files?
        let quitApps: [String]?
        let tool: String?
        let iconApp: String?
        let enabled: Bool?

        struct Files: Decodable {
            let `in`: String
            let extensions: [String]
        }
    }

    public struct LoadResult: Sendable {
        public var rules: [Rule] = []
        /// 有问题的地方，给用户看
        public var problems: [String] = []
    }

    /// 读取自定义规则文件；没有文件时返回空
    public static func load() -> LoadResult {
        guard let data = try? Data(contentsOf: file) else { return LoadResult() }
        return parse(data)
    }

    static func parse(_ data: Data) -> LoadResult {
        var result = LoadResult()
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            result.problems.append("自定义规则文件格式不对，整个文件没有生效：\(describe(error))")
            return result
        }
        for (i, e) in entries.enumerated() where e.enabled != false {
            let n = i + 1
            let targets = [e.contents != nil, e.paths != nil, e.files != nil].filter { $0 }.count
            guard targets == 1 else {
                result.problems.append("第 \(n) 条“\(e.name)”：contents、paths、files 要写其中一个，而且只写一个")
                continue
            }
            let safety: Safety
            switch e.safety ?? "review" {
            case "safe": safety = .safe
            case "review": safety = .review
            case "reportOnly": safety = .reportOnly
            default:
                result.problems.append("第 \(n) 条“\(e.name)”：safety 只能是 safe、review 或 reportOnly")
                continue
            }
            let all = (e.contents.map { [$0] } ?? []) + (e.paths ?? []) + (e.files.map { [$0.in] } ?? [])
            if let bad = all.first(where: { !$0.hasPrefix("~/") }) {
                result.problems.append("第 \(n) 条“\(e.name)”：路径要以 ~/ 开头（只能清理你的主目录里的东西）：\(bad)")
                continue
            }
            let target: Target
            if let c = e.contents { target = .contents(of: c) }
            else if let p = e.paths { target = .paths(p) }
            else { target = .files(in: e.files!.in, extensions: e.files!.extensions.map { $0.lowercased() }) }

            result.rules.append(Rule(
                id: "custom-\(n)", name: e.name, category: "自定义", safety: safety,
                detail: e.detail ?? "你自己添加的规则", target: target,
                quitApps: e.quitApps ?? [], tool: e.tool, iconBundleID: e.iconApp))
        }
        return result
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "缺少必填项 \(key.stringValue)"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            return "“\(c.codingPath.map(\.stringValue).joined(separator: "."))”的类型不对"
        case DecodingError.dataCorrupted: return "不是有效的 JSON（检查逗号、引号、括号）"
        default: return error.localizedDescription
        }
    }

    /// 文件不存在时，创建一份带示例的（示例默认停用），返回文件位置
    @discardableResult
    public static func createTemplateIfNeeded() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: file, atomically: true, encoding: .utf8)
        }
        return file
    }

    static let template = """
    [
      {
        "name": "示例：下载文件夹里的压缩包",
        "detail": "这是一条示例规则，把 enabled 改成 true 就会生效。字段说明见 GitHub 上的 README",
        "safety": "review",
        "files": { "in": "~/Downloads", "extensions": ["zip", "rar", "7z"] },
        "enabled": false
      },
      {
        "name": "示例：某个 App 的缓存",
        "safety": "safe",
        "contents": "~/Library/Application Support/某个App/Cache",
        "quitApps": ["com.example.app"],
        "enabled": false
      }
    ]

    """
}
