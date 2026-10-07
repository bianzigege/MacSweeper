import Foundation

/// 规则的安全等级
public enum Safety: String, Sendable {
    /// 可放心清理：删掉后程序会自动重新生成
    case safe
    /// 需确认：通常可删，但可能有用户想保留的东西
    case review
    /// 只报告：不自动删，提示用户去对应 App 里自己处理
    case reportOnly
}

/// 一条规则如何找到要清理的项目
public enum Target: Sendable {
    /// 清理目录里的每一个子项（目录本身保留）。
    /// 路径里可以有 `*` 通配一层目录；excludingPrefixes 对通配到的目录名和子项名都生效
    case contents(of: String, excludingPrefixes: [String] = [])
    /// 清理这些路径本身（路径里同样可以有 `*`）
    case paths([String])
    /// 清理目录第一层里指定扩展名的文件
    case files(in: String, extensions: [String])
    /// 在这些目录下找 Chromium 内核（Chrome、Edge、Electron 应用等）的配置目录，
    /// 只清理其中的网页缓存，不碰书签、密码、Cookie 和网站数据。excluding 里的目录跳过
    case chromiumCaches(roots: [String], excluding: [String] = [])
    /// 已卸载 App 留下的数据（Application Support、Containers、Preferences 等）
    case leftovers
    /// 主目录里超过 minBytes 的单个文件（跳过 ~/Library、.git、node_modules 和 App 数据包）
    case largeFiles(minBytes: Int64)
    /// 超过 inactiveDays 天没改过的项目里，能重新安装/生成的依赖（node_modules、.venv 等）
    case projectDependencies(inactiveDays: Int)
    /// 超过 inactiveDays 天没改过的整个项目文件夹
    case staleProjects(inactiveDays: Int)
    /// Codex 的旧对话记录，按月份
    case codexSessions(olderThanDays: Int)
    /// 已经卸载的 AI 工具留下的文件夹
    case uninstalledTools([ToolTrace])
}

/// 一个 AI 工具留在电脑上的痕迹：对应的 App 名字都没装时，这些路径才算残留
public struct ToolTrace: Sendable {
    public let name: String
    public let appNames: [String]
    public let paths: [String]

    public init(_ name: String, apps: [String], paths: [String]) {
        self.name = name
        self.appNames = apps
        self.paths = paths
    }
}

public struct Rule: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let category: String
    public let safety: Safety
    public let detail: String
    public let target: Target
    /// 清理前必须先退出的 App（Bundle ID）；写成 "process:名字" 表示命令行程序
    public let quitApps: [String]

    /// 逐项检查所属 App 是否在运行，在运行的跳过
    public let skipsRunningApps: Bool
    /// 最近这么多天内改过的不算（比如刚做的备份可能还要用来回滚）
    public let minAgeDays: Int?

    /// 没指定 quitApps 的浏览器类缓存，或者明确要求逐项检查的规则
    var checksOwnerPerItem: Bool {
        if case .chromiumCaches = target { return quitApps.isEmpty }
        return skipsRunningApps
    }

    public init(id: String, name: String, category: String, safety: Safety, detail: String,
                target: Target, quitApps: [String] = [], skipsRunningApps: Bool = false, minAgeDays: Int? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.safety = safety
        self.detail = detail
        self.target = target
        self.quitApps = quitApps
        self.skipsRunningApps = skipsRunningApps
        self.minAgeDays = minAgeDays
    }
}

/// 所有路径都以 ~ 开头，相对于用户主目录
public enum RuleBook {
    static let wechat = "~/Library/Containers/com.tencent.xinWeChat/Data/Documents"
    static let chrome = "~/Library/Application Support/Google/Chrome"

    public static let all: [Rule] = [
        // MARK: 系统
        Rule(id: "user-caches", name: "应用缓存", category: "系统", safety: .safe,
             detail: "~/Library/Caches，各个 App 的缓存，删除后会自动重建（跳过苹果系统自带的缓存）",
             target: .contents(of: "~/Library/Caches", excludingPrefixes: ["com.apple."]),
             skipsRunningApps: true),
        Rule(id: "sandbox-caches", name: "沙盒应用缓存", category: "系统", safety: .safe,
             detail: "从 App Store 安装的应用（飞书、腾讯会议等）各自的缓存目录",
             target: .contents(of: "~/Library/Containers/*/Data/Library/Caches",
                               excludingPrefixes: ["com.apple."]),
             skipsRunningApps: true),
        Rule(id: "user-logs", name: "应用日志", category: "系统", safety: .safe,
             detail: "~/Library/Logs，各个 App 的运行日志",
             target: .contents(of: "~/Library/Logs", excludingPrefixes: ["MacSweeper"]),
             skipsRunningApps: true),
        Rule(id: "installers", name: "下载的安装包", category: "系统", safety: .review,
             detail: "~/Downloads 里的 .dmg / .pkg 安装包，软件装好后一般就没用了",
             target: .files(in: "~/Downloads", extensions: ["dmg", "pkg", "mpkg"])),
        Rule(id: "leftovers", name: "已卸载 App 的残留", category: "系统", safety: .review,
             detail: "找不到对应 App 的设置和数据文件夹，最近 30 天内有改动的不算。也可能属于命令行工具，请展开确认",
             target: .leftovers),

        Rule(id: "large-files", name: "大文件", category: "文件", safety: .review,
             detail: "主目录里超过 500MB 的单个文件，比如旧视频、安装镜像、虚拟机、压缩包。请展开逐个确认",
             target: .largeFiles(minBytes: 500_000_000)),

        // MARK: 微信
        Rule(id: "wechat-browser", name: "微信内置浏览器缓存", category: "微信", safety: .safe,
             detail: "公众号文章、小程序网页的缓存，不影响聊天记录",
             target: .chromiumCaches(roots: ["\(wechat)/app_data/radium/web/profiles"]),
             quitApps: ["com.tencent.xinWeChat"]),
        Rule(id: "wechat-temp", name: "微信临时文件和日志", category: "微信", safety: .safe,
             detail: "微信的临时文件、运行日志和崩溃记录，不影响聊天记录",
             target: .paths(["\(wechat)/xwechat_files/*/temp", "\(wechat)/app_data/log",
                             "\(wechat)/app_data/crashinfo"]),
             quitApps: ["com.tencent.xinWeChat"]),
        Rule(id: "wechat-media-cache", name: "微信图片视频缓存", category: "微信", safety: .review,
             detail: "按月份存放的聊天图片、视频缓存。删除后，旧消息里的部分图片可能需要重新下载，或者已经过期看不了",
             target: .contents(of: "\(wechat)/xwechat_files/*/cache"),
             quitApps: ["com.tencent.xinWeChat"]),

        // MARK: 浏览器
        Rule(id: "chrome-cache", name: "Chrome 网页缓存", category: "浏览器", safety: .safe,
             detail: "网站的离线缓存和脚本缓存，不影响书签、密码和登录状态",
             target: .chromiumCaches(roots: [chrome]),
             quitApps: ["com.google.Chrome"]),
        Rule(id: "chromium-apps-cache", name: "其他浏览器和 Electron 应用缓存", category: "浏览器", safety: .review,
             detail: "Edge、夸克、豆包、飞书、VS Code 等的网页缓存。不影响登录状态，建议先退出这些应用",
             target: .chromiumCaches(roots: ["~/Library/Application Support"], excluding: [chrome])),

        // MARK: AI 工具与项目
        Rule(id: "ai-project-deps", name: "长期没动的项目依赖", category: "AI 工具与项目", safety: .review,
             detail: "超过 30 天没改过的项目里的 node_modules、.venv 等。以后要接着做，在项目里重新安装依赖（如 npm install）就能恢复",
             target: .projectDependencies(inactiveDays: 30)),
        Rule(id: "codex-old-sessions", name: "Codex 旧对话记录", category: "AI 工具与项目", safety: .review,
             detail: "两个月以前的 Codex 对话，按月份列出。删除后，这些对话在 Codex 里就找不到、也不能接着聊了",
             target: .codexSessions(olderThanDays: 60),
             quitApps: ["com.openai.codex", "process:codex"]),
        Rule(id: "codex-backups", name: "Codex 修复留下的备份", category: "AI 工具与项目", safety: .safe,
             detail: "Codex 升级或修复数据时留下的旧备份文件，平时用不到。最近 7 天内的备份不算，可能还要用来回滚",
             target: .paths(["~/.codex/*.backup-*", "~/.codex/*.bak", "~/.codex/backup-*"]),
             minAgeDays: 7),
        Rule(id: "codex-logs", name: "Codex 运行日志", category: "AI 工具与项目", safety: .review,
             detail: "Codex 的运行日志数据库，不含对话内容。删除后 Codex 会重新生成",
             target: .paths(["~/.codex/logs_*.sqlite", "~/.codex/logs_*.sqlite-wal", "~/.codex/logs_*.sqlite-shm"]),
             quitApps: ["com.openai.codex", "process:codex"]),
        Rule(id: "codex-images", name: "Codex 生成的图片", category: "AI 工具与项目", safety: .review,
             detail: "Codex 帮你生成的图片，按对话分文件夹。是你的作品，删除前先确认需要的已经另存",
             target: .contents(of: "~/.codex/generated_images")),
        Rule(id: "claude-vm", name: "Claude Cowork 虚拟机", category: "AI 工具与项目", safety: .review,
             detail: "Claude 桌面版 Cowork 功能用的虚拟机。不用 Cowork 可以删，以后再用会自动重新下载",
             target: .paths(["~/Library/Application Support/Claude/vm_bundles"]),
             quitApps: ["com.anthropic.claudefordesktop"]),
        Rule(id: "ai-tool-leftovers", name: "已卸载 AI 工具的残留", category: "AI 工具与项目", safety: .review,
             detail: "App 已经删掉的 AI 工具留下的设置和数据。有的里面可能有工作文件（workspace），请展开先看看",
             target: .uninstalledTools([
                 ToolTrace("Trae", apps: ["Trae", "Trae CN"],
                           paths: ["~/.trae", "~/.trae-cn", "~/Library/Application Support/Trae",
                                   "~/Library/Application Support/Trae CN"]),
                 ToolTrace("Cursor", apps: ["Cursor"],
                           paths: ["~/.cursor", "~/Library/Application Support/Cursor"]),
                 ToolTrace("Windsurf", apps: ["Windsurf"],
                           paths: ["~/.windsurf", "~/.codeium", "~/Library/Application Support/Windsurf"]),
                 ToolTrace("Qoder", apps: ["Qoder"],
                           paths: ["~/.qoder", "~/Library/Application Support/Qoder"]),
                 ToolTrace("CodeBuddy", apps: ["CodeBuddy", "CodeBuddy CN"],
                           paths: ["~/.codebuddy", "~/Library/Application Support/CodeBuddy"]),
                 ToolTrace("豆包", apps: ["Doubao", "豆包"],
                           paths: ["~/Library/Application Support/Doubao"]),
                 ToolTrace("Kimi", apps: ["Kimi"],
                           paths: ["~/Library/Application Support/Kimi"]),
                 ToolTrace("QClaw", apps: ["QClaw"],
                           paths: ["~/.qclaw", "~/Library/Application Support/QClaw"]),
                 ToolTrace("AutoClaw", apps: ["AutoClaw"],
                           paths: ["~/.openclaw-autoclaw", "~/Library/Application Support/autoclaw"]),
                 ToolTrace("Craft Agent", apps: ["Craft Agent", "Craft Agents"],
                           paths: ["~/.craft-agent", "~/Library/Application Support/@craft-agent"]),
             ])),
        Rule(id: "stale-projects", name: "长期没动的项目", category: "AI 工具与项目", safety: .reportOnly,
             detail: "超过 60 天没改过的项目文件夹，帮你梳理做完就没管的项目。确认不要了，点放大镜在访达里自己删除",
             target: .staleProjects(inactiveDays: 60)),
        Rule(id: "app-backups", name: "“应用程序”里的旧版备份", category: "AI 工具与项目", safety: .reportOnly,
             detail: "汉化补丁或升级时留下的 App 旧版副本。确认新版正常后，可以在“应用程序”里把它拖到废纸篓",
             target: .paths(["/Applications/*backup*.app", "/Applications/* copy.app", "/Applications/*副本*.app"])),

        // MARK: 开发
        Rule(id: "xcode-derived", name: "Xcode 编译缓存", category: "开发", safety: .safe,
             detail: "DerivedData，下次编译时会重新生成",
             target: .contents(of: "~/Library/Developer/Xcode/DerivedData")),
        Rule(id: "simulator-caches", name: "模拟器缓存", category: "开发", safety: .safe,
             detail: "CoreSimulator/Caches",
             target: .contents(of: "~/Library/Developer/CoreSimulator/Caches")),
        Rule(id: "xcode-device-support", name: "iOS 设备调试支持文件", category: "开发", safety: .review,
             detail: "连接旧 iPhone 调试时生成，再次连接会重新生成",
             target: .contents(of: "~/Library/Developer/Xcode/iOS DeviceSupport")),
        Rule(id: "npm-cache", name: "npm 缓存", category: "开发", safety: .safe,
             detail: "~/.npm/_cacache，下次安装依赖会重新下载",
             target: .paths(["~/.npm/_cacache"])),
        Rule(id: "cargo-cache", name: "Rust 依赖缓存", category: "开发", safety: .safe,
             detail: "~/.cargo/registry/cache",
             target: .paths(["~/.cargo/registry/cache"])),
        Rule(id: "gradle-cache", name: "Gradle 缓存", category: "开发", safety: .review,
             detail: "~/.gradle/caches，下次构建会重新下载",
             target: .paths(["~/.gradle/caches"])),
        Rule(id: "dot-cache", name: "~/.cache 通用缓存", category: "开发", safety: .review,
             detail: "命令行工具的缓存，可能包含下载好的 AI 模型等大文件，请先看清楚",
             target: .contents(of: "~/.cache")),

        // MARK: 只报告，不自动删
        Rule(id: "wechat", name: "微信数据（全部）", category: "大应用", safety: .reportOnly,
             detail: "包含上面几项微信缓存。聊天记录和文件请在 微信 → 设置 → 通用 → 存储空间 里清理",
             target: .paths(["~/Library/Containers/com.tencent.xinWeChat"])),
        Rule(id: "chrome", name: "Chrome 数据（全部）", category: "大应用", safety: .reportOnly,
             detail: "包含上面的 Chrome 缓存。其余是书签、密码、网站数据，请在 Chrome → 设置 → 隐私 里管理",
             target: .paths([chrome])),
        Rule(id: "docker", name: "Docker 数据", category: "大应用", safety: .reportOnly,
             detail: "请在终端运行 docker system prune，或在 Docker Desktop 里清理",
             target: .paths(["~/Library/Containers/com.docker.docker"])),
        Rule(id: "ios-backups", name: "iPhone 备份", category: "大应用", safety: .reportOnly,
             detail: "请在 访达 → 你的 iPhone → 管理备份 里删除旧备份",
             target: .paths(["~/Library/Application Support/MobileSync/Backup"])),
        Rule(id: "trash", name: "废纸篓", category: "大应用", safety: .reportOnly,
             detail: "清空后无法恢复，请在程序坞里右键废纸篓自己清空",
             target: .paths(["~/.Trash"])),
    ]
}
