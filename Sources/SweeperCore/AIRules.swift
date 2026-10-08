import Foundation

/// “AI 工具与项目”分类的规则，界面里按 tool 分组、显示对应 App 的图标
extension RuleBook {
    static let category = "AI 工具与项目"
    static let codexHome = "~/.codex"
    static let claudeSupport = "~/Library/Application Support/Claude"
    static let chatcutSupport = "~/Library/Application Support/ChatCut"

    enum App {
        static let codex = "com.openai.codex"          // ChatGPT.app，就是 Codex 桌面版
        static let claude = "com.anthropic.claudefordesktop"
        static let chatcut = "io.chatcut.desktop"
        static let workbuddy = "com.workbuddy.workbuddy"
        static let qianwen = "com.alibaba.tongyi"
        static let yuanbao = "com.tencent.yuanbao"
        static let deepseek = "ai.deepseek.dsh.desktop"
        static let scriberr = "Scriberr"              // 没有 Bundle ID，按 App 名字找
        static let translate = "com.immersivetranslate.Immersive-Translate"
        static let cockpit = "com.jlcodes.cockpit-tools"
    }

    private static func ai(_ id: String, _ name: String, tool: String, icon: String?, _ safety: Safety,
                           _ detail: String, _ target: Target, quit: [String] = [],
                           minAgeDays: Int? = nil, consequence: Consequence? = nil) -> Rule {
        Rule(id: id, name: name, category: category, safety: safety, detail: detail, target: target,
             quitApps: quit, minAgeDays: minAgeDays, tool: tool, iconBundleID: icon, consequence: consequence)
    }

    static let aiTools: [Rule] = [
        // MARK: Codex
        ai("codex-backups", "修复留下的备份", tool: "Codex", icon: App.codex, .safe,
           "Codex 升级或修复数据时留下的旧备份文件，平时用不到。最近 7 天内的备份不算，可能还要用来回滚",
           .paths(["\(codexHome)/*.backup-*", "\(codexHome)/*.bak", "\(codexHome)/backup-*"]), minAgeDays: 7),
        ai("codex-cache", "插件目录缓存", tool: "Codex", icon: App.codex, .safe,
           "插件市场、应用目录的缓存，Codex 下次打开会重新下载",
           .contents(of: "\(codexHome)/cache"), quit: [App.codex, "process:codex"]),
        ai("codex-old-sessions", "旧对话记录", tool: "Codex", icon: App.codex, .review,
           "两个月以前的对话，按月份列出。删除后，这些对话在 Codex 里就找不到、也不能接着聊了",
           .codexSessions(olderThanDays: 60), quit: [App.codex, "process:codex"], consequence: .lost),
        ai("codex-logs", "运行日志", tool: "Codex", icon: App.codex, .review,
           "运行日志数据库，不含对话内容。删除后 Codex 会重新生成",
           .paths(["\(codexHome)/logs_*.sqlite", "\(codexHome)/logs_*.sqlite-wal", "\(codexHome)/logs_*.sqlite-shm"]),
           quit: [App.codex, "process:codex"]),
        ai("codex-images", "生成的图片", tool: "Codex", icon: App.codex, .review,
           "Codex 帮你生成的图片，按对话分文件夹。是你的作品，删除前先确认需要的已经另存",
           .contents(of: "\(codexHome)/generated_images"), consequence: .lost),
        ai("codex-all", "Codex 数据（全部）", tool: "Codex", icon: App.codex, .reportOnly,
           "包含上面几项。其余是对话索引数据库、插件和设置",
           .paths([codexHome, "~/Library/Application Support/Codex", "~/Library/Caches/com.openai.codex",
                   "~/Library/Caches/Codex"])),

        // MARK: Claude
        ai("claude-code-old", "Claude Code 旧版本", tool: "Claude", icon: App.claude, .safe,
           "Claude 桌面版自动更新后留下的旧版 Claude Code，只保留最新版；正在被使用的版本不会动",
           .olderVersions(["\(claudeSupport)/claude-code", "\(claudeSupport)/claude-code-vm"])),
        ai("claude-vm", "Cowork 虚拟机", tool: "Claude", icon: App.claude, .review,
           "Claude 桌面版 Cowork 功能用的虚拟机。不用 Cowork 可以删，以后再用会自动重新下载",
           .paths(["\(claudeSupport)/vm_bundles"]), quit: [App.claude]),
        ai("app-backups", "“应用程序”里的旧版备份", tool: "Claude", icon: App.claude, .reportOnly,
           "汉化补丁或升级时留下的 App 旧版副本。确认新版正常后，可以在“应用程序”里把它拖到废纸篓",
           .paths(["/Applications/*backup*.app", "/Applications/* copy.app", "/Applications/*副本*.app"])),
        ai("claude-all", "Claude 数据（全部）", tool: "Claude", icon: App.claude, .reportOnly,
           "包含上面几项。其余是网页缓存（Claude 运行时会跳过）、对话记录和设置",
           .paths([claudeSupport, "~/.claude", "~/Library/Caches/com.anthropic.claudefordesktop",
                   "~/Library/Caches/com.anthropic.claudefordesktop.ShipIt"])),

        // MARK: ChatCut
        ai("chatcut-cache", "字体和组件缓存", tool: "ChatCut", icon: App.chatcut, .safe,
           "字体缓存、AI 助手组件的下载缓存和安装日志，会自动重新生成",
           .paths(["\(chatcutSupport)/font_cache", "\(chatcutSupport)/acp-agents/npm/_cacache",
                   "\(chatcutSupport)/acp-agents/npm/_logs"]), quit: [App.chatcut, "process:ChatCut"]),
        ai("chatcut-agent-workspaces", "AI 助手工作文件夹", tool: "ChatCut", icon: App.chatcut, .review,
           "AI 剪辑助手处理每个项目时用的工作文件夹，可能有中间素材。对应项目做完了可以删",
           .contents(of: "\(chatcutSupport)/acp-workspaces/*"), quit: [App.chatcut, "process:ChatCut"], consequence: .lost),
        ai("chatcut-backups", "项目自动备份", tool: "ChatCut", icon: App.chatcut, .review,
           "剪辑项目的自动备份，按项目分文件夹。项目本身不受影响",
           .contents(of: "\(chatcutSupport)/project-backups"), quit: [App.chatcut, "process:ChatCut"], consequence: .lost),
        ai("chatcut-all", "ChatCut 数据（全部）", tool: "ChatCut", icon: App.chatcut, .reportOnly,
           "包含上面几项。projects 里是你的剪辑项目，请在 ChatCut 里管理",
           .paths([chatcutSupport, "~/Library/Caches/chatcut-desktop-updater", "~/Library/Caches/io.chatcut.desktop"])),

        // MARK: WorkBuddy
        ai("workbuddy-logs", "运行日志和追踪记录", tool: "WorkBuddy", icon: App.workbuddy, .safe,
           "WorkBuddy 的运行日志和调试追踪记录",
           .paths(["~/.workbuddy/logs/*", "~/.workbuddy/traces/*"]),
           quit: [App.workbuddy]),
        ai("workbuddy-all", "WorkBuddy 数据（全部）", tool: "WorkBuddy", icon: App.workbuddy, .reportOnly,
           "包含程序组件、插件和 ~/WorkBuddy 里的工作区（工作区里的项目在“AI 做的项目”里看）",
           .paths(["~/.workbuddy", "~/WorkBuddy"])),

        // MARK: 其他在用的 AI 工具（数据不多，只报告；它们的缓存已经在“沙盒应用缓存”等规则里）
        ai("qianwen-all", "通义千问数据（全部）", tool: "通义千问", icon: App.qianwen, .reportOnly,
           "缓存已包含在“沙盒应用缓存”里，其余是登录和设置",
           .paths(["~/Library/Containers/\(App.qianwen)"])),
        ai("yuanbao-all", "元宝数据（全部）", tool: "元宝", icon: App.yuanbao, .reportOnly,
           "缓存已包含在“沙盒应用缓存”里，其余是登录和设置",
           .paths(["~/Library/Containers/\(App.yuanbao)", "~/Library/WebKit/\(App.yuanbao)"])),
        ai("deepseek-all", "DeepSeek 数据（全部）", tool: "DeepSeek", icon: App.deepseek, .reportOnly,
           "数据很少，不需要清理",
           .paths(["~/Library/Application Support/DSH Desktop", "~/Library/Caches/\(App.deepseek)"])),
        ai("scriberr-all", "Scriberr 数据（全部）", tool: "Scriberr", icon: App.scriberr, .reportOnly,
           "语音转文字的记录和模型，请在 Scriberr 里管理",
           .paths(["~/Library/Application Support/Scriberr"])),
        ai("translate-all", "沉浸式翻译数据（全部）", tool: "沉浸式翻译", icon: App.translate, .reportOnly,
           "数据很少，不需要清理",
           .paths(["~/Library/Application Support/\(App.translate)", "~/Library/Caches/\(App.translate)"])),
        ai("cockpit-all", "Cockpit Tools 数据（全部）", tool: "Cockpit Tools", icon: App.cockpit, .reportOnly,
           "数据很少，不需要清理",
           .paths(["~/Library/Application Support/\(App.cockpit)", "~/Library/Caches/\(App.cockpit)"])),
        ai("deskclaw-all", "DeskClaw 命令行工具（全部）", tool: "DeskClaw", icon: nil, .reportOnly,
           "你在终端里用的 claude、codex、openclaw 等命令都装在这里，不要删除",
           .paths(["~/.deskclaw", "~/.openclaw"])),

        // MARK: AI 做的项目
        ai("ai-project-deps", "长期没动的项目依赖", tool: "AI 做的项目", icon: nil, .review,
           "超过 30 天没改过的项目里的 node_modules、.venv 等。以后要接着做，在项目里重新安装依赖（如 npm install）就能恢复",
           .projectDependencies(inactiveDays: 30)),
        ai("stale-projects", "长期没动的项目", tool: "AI 做的项目", icon: nil, .reportOnly,
           "超过 60 天没改过的项目文件夹，帮你梳理做完就没管的项目。确认不要了，点放大镜在访达里自己删除",
           .staleProjects(inactiveDays: 60)),

        // MARK: 已卸载的 AI 工具
        ai("ai-tool-leftovers", "已卸载 AI 工具的残留", tool: "已卸载的 AI 工具", icon: nil, .review,
           "App 已经删掉的 AI 工具留下的设置和数据。有的里面可能有工作文件（workspace），请展开先看看",
           .uninstalledTools([
               ToolTrace("Trae", apps: ["Trae", "Trae CN"],
                         paths: ["~/.trae", "~/.trae-cn", "~/Library/Application Support/Trae",
                                 "~/Library/Application Support/Trae CN"]),
               ToolTrace("Cursor", apps: ["Cursor"], paths: ["~/.cursor", "~/Library/Application Support/Cursor"]),
               ToolTrace("Windsurf", apps: ["Windsurf"],
                         paths: ["~/.windsurf", "~/.codeium", "~/Library/Application Support/Windsurf"]),
               ToolTrace("Qoder", apps: ["Qoder"], paths: ["~/.qoder", "~/Library/Application Support/Qoder"]),
               ToolTrace("CodeBuddy", apps: ["CodeBuddy", "CodeBuddy CN"],
                         paths: ["~/.codebuddy", "~/Library/Application Support/CodeBuddy"]),
               ToolTrace("豆包", apps: ["Doubao", "豆包"], paths: ["~/Library/Application Support/Doubao"]),
               ToolTrace("Kimi", apps: ["Kimi"], paths: ["~/Library/Application Support/Kimi"]),
               ToolTrace("QClaw", apps: ["QClaw"], paths: ["~/.qclaw", "~/Library/Application Support/QClaw"]),
               ToolTrace("AutoClaw", apps: ["AutoClaw"],
                         paths: ["~/.openclaw-autoclaw", "~/Library/Application Support/autoclaw"]),
               ToolTrace("Craft Agent", apps: ["Craft Agent", "Craft Agents"],
                         paths: ["~/.craft-agent", "~/Library/Application Support/@craft-agent"]),
               ToolTrace("Ollama", apps: ["Ollama"], paths: ["~/.ollama", "~/Library/Application Support/Ollama"]),
               ToolTrace("CodexBar", apps: ["CodexBar"], paths: ["~/Library/Application Support/CodexBar"]),
           ]), consequence: .lost),
        ai("broken-links", "失效的命令链接", tool: "命令行", icon: nil, .safe,
           "指向已删除 App 的命令（如 trae、codexbar），留着只会在终端里报错",
           .brokenLinks(["~/.local/bin", "~/bin", "~/.npm-global/bin"])),
        ai("broken-links-system", "失效的命令链接（系统目录）", tool: "命令行", icon: nil, .reportOnly,
           "在系统目录里，需要管理员权限。可以在终端运行 sudo rm 加上下面的路径来删除",
           .brokenLinks(["/usr/local/bin", "/opt/homebrew/bin"])),
    ]
}
