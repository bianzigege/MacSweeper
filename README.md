<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="MacSweeper 图标">
</p>

<h1 align="center">MacSweeper</h1>

<p align="center">安全、透明、免费的 Mac 垃圾清理工具 · 原生 SwiftUI · 只移到废纸篓，从不直接删除</p>

<p align="center">中文 · <a href="README.en.md">English</a></p>

## 功能

- **清理缓存和日志**：应用缓存、沙盒应用缓存、日志、npm / Rust / Gradle / Xcode 等开发缓存
- **国内应用专项**：微信内置浏览器缓存（往往有几十 GB）、微信临时文件、飞书等
- **浏览器缓存**：Chrome、Edge 及各种 Electron 应用的 Service Worker 缓存，不碰书签、密码和登录状态
- **已卸载 App 的残留**：保守识别，宁可漏掉也不误删
- **大文件查找**：列出主目录里超过 500MB 的文件，逐个决定
- **AI 工具与项目**：按工具分组、显示各自的图标——Codex、Claude、ChatCut、WorkBuddy、通义千问、元宝、DeepSeek 等每个工具占了多少、哪些能清；长期没动的项目和它们的依赖（node_modules、.venv 等）；已卸载 AI 工具（Trae、Cursor、豆包等）的残留；失效的命令链接
- **图标不打包进项目**：各 AI 工具的图标在运行时从你电脑上已安装的 App 里读取，仓库里不存放任何其他公司的 logo
- **逐项勾选**：每一类都能展开，看清楚每个文件夹的大小和修改时间再决定
- **App 正在运行时自动跳过**它的文件；也可以一键“退出 App 并清理”，清理完自动重新打开
- **卸载 App**：列出很久没用的 App；选中后按 ⌘⌫（或右键、或把 App 拖进窗口/程序坞图标）打开确认清单，App 和它的缓存、设置、开机自启项一起移到废纸篓，可以撤销
- **撤销上次清理**：一键把上次移到废纸篓的文件放回原处（App 重开后也能撤销）
- **顶部总览**：能腾出多少、废纸篓里还有多少没清空；支持搜索和折叠分组
- **自定义规则**：不用改代码，在规则文件里加自己的清理项
- **中英文界面**：跟随系统语言

## 下载安装

到 [Releases](../../releases) 下载最新的 `MacSweeper-x.y.z.dmg`，打开后把 MacSweeper 拖进“应用程序”。支持 macOS 13 及以上，Apple 芯片和 Intel 芯片都可以。

> 目前没有苹果开发者签名，第一次打开会被 macOS 拦下。放行方法：
> 1. 先双击 MacSweeper，看到提示后点“完成”；
> 2. 打开“系统设置 → 隐私与安全性”，拉到最下面，点 MacSweeper 旁边的**“仍要打开”**，输入开机密码确认；
> 3. 之后就能正常双击使用了。（macOS 14 及更早的系统，也可以直接右键 MacSweeper → 打开。）

## 从源码编译

只需要 Xcode 命令行工具（`xcode-select --install`），不需要完整的 Xcode。

### 图形界面（推荐）

```bash
./scripts/build-app.sh
```

生成 `build/MacSweeper.app`，双击就能打开，也可以拖到“应用程序”文件夹。

图标由 `scripts/make-icon.swift` 用代码绘制（青蓝渐变 + 白色硬盘 + 闪光星星）。想改颜色或造型就改这个文件，再运行 `swift scripts/make-icon.swift` 重新生成。

界面流程：开始扫描 → 勾选要清理的类别 → 移到废纸篓 → 确认。

点类别右边的 `>` 可以展开明细，逐个勾选或取消具体项目（会显示最后修改时间），点放大镜能在访达里定位。类别前的勾选框是三态的：全选 / 部分选（−）/ 未选。

### 打包发给别人

```bash
./scripts/make-dmg.sh
```

生成 `build/MacSweeper-<版本>.dmg`，同时支持 Apple 芯片和 Intel 芯片的 Mac（macOS 13 及以上）。对方打开 DMG，把 MacSweeper 拖到“应用程序”即可。

**关于签名：** 目前用的是本机临时签名。别人第一次打开时 macOS 会拦下，需要去“系统设置 → 隐私与安全性”底部点“仍要打开”（见上面“下载安装”），之后就能正常双击。

想去掉这个提示，需要加入 [Apple Developer Program](https://developer.apple.com/programs/)（每年 99 美元），然后：

```bash
# 只需一次：保存公证凭据（密码用 appleid.apple.com 生成的 App 专用密码）
xcrun notarytool store-credentials macsweeper --apple-id 你的AppleID --team-id 你的TEAMID

# 之后每次发布
SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" NOTARY_PROFILE=macsweeper ./scripts/make-dmg.sh
```

脚本会自动正式签名、提交苹果公证并把公证结果附到 DMG 上。

### 自定义规则

点界面右上角的规则按钮（或者直接编辑 `~/Library/Application Support/MacSweeper/自定义规则.json`），第一次会生成一份带示例的文件。每条规则的写法：

```json
{
  "name": "某某 App 的缓存",
  "detail": "说明文字（可选）",
  "safety": "review",
  "contents": "~/Library/Application Support/某某/Cache",
  "quitApps": ["com.example.app"]
}
```

- `safety`：`safe`（可放心清理）/ `review`（需确认，默认）/ `reportOnly`（只报告）
- 目标三选一：`contents`（清理目录里的每一项）、`paths`（清理这些路径，可以用 `*`）、`files`（如 `{"in": "~/Downloads", "extensions": ["zip"]}`）
- 可选：`quitApps`（这些 App 运行时不清理）、`tool` 和 `iconApp`（放进“AI 工具与项目”分组并显示图标）、`enabled: false`（暂时停用）
- 路径必须以 `~/` 开头；自定义规则同样受所有安全护栏保护。改完保存，点“重新扫描”生效

### 翻译

英文翻译在 `scripts/translations.py` 里。改了界面文字或规则后运行 `python3 scripts/translations.py`：检查每句都有翻译、占位符对得上，并生成 `Resources/en.lproj/Localizable.strings`。自检程序会检查每条内置规则都有翻译。

### 卸载 App

切到顶部的“卸载 App”。很久没用的（超过 90 天没打开或从没打开过）排在前面。选中一个 App 按 **⌘⌫**，或者右键 →“卸载…”，或者把 App 拖进窗口、拖到程序坞里的 MacSweeper 图标上。命令行：`sweep apps`、`sweep uninstall <App名> --dry-run`。

快捷键只打开**确认清单**，不会直接删除。清单分组：

| 分组 | 默认 |
|---|---|
| App 本体 | 一定会删 |
| ID 完全对得上的缓存、设置；你账户下的开机自启项（会先停掉） | 勾选 |
| 可能有你数据的（应用数据、沙盒）；按名字找到、不确定是不是它的 | 不勾 |
| 同一厂商其他 App 还在用的共享数据；系统级后台服务 | 不会动，只告诉你 |

安全措施：苹果自带的 App、MacSweeper 自己、你加进保护名单的 App（右键菜单）不能卸载；正在运行的要先退出；确认窗口的默认按钮是“取消”，回车和 Esc 都只会取消；勾选了超过 100MB 可能有你数据的项目会再确认一次；归系统所有的 App 由 macOS 弹出它自己的密码框；全部只移到废纸篓，可以“撤销这次卸载”。用 Homebrew 装的 App 会提示你改用 `brew uninstall`。

### 撤销

界面顶部有“撤销上次清理”；命令行是 `sweep undo`。原位置已经有新文件的（比如 App 重新生成了缓存）不会覆盖。

### 自检

```bash
./scripts/selftest.sh
```

检查安全护栏、残留判断、浏览器缓存识别、去重、大小计算、运行检查、撤销、自定义规则、卸载 App 等 93 项关键逻辑。测试文件都建在临时目录里，不碰真实文件；不需要 Xcode。改了 `SweeperCore` 之后先跑一遍。

### 命令行

```bash
swift build -c release
```

编译出来的程序在 `.build/release/sweep`。

```bash
.build/release/sweep                   # 扫描，只看不删
.build/release/sweep scan --detail     # 扫描，并列出每条规则里最大的项目
.build/release/sweep clean --dry-run   # 预览要清理的内容
.build/release/sweep clean             # 清理“可放心清理”的项目（会要求输入 y 确认）
.build/release/sweep clean installers  # 只清理某一条规则
```

## 安全设计

- **只移到废纸篓**，不会永久删除，误删了可以从废纸篓还原
- 清理前一定会列出清单并要求确认，也可以用 `--dry-run` 只预览
- 只处理用户主目录里的文件；桌面、文稿、下载等目录本身受保护
- 微信、Chrome、Docker、iPhone 备份、废纸篓的整体数据只报告大小，只清理其中确定是缓存的部分
- 相关 App 正在运行时（微信、Chrome 等）不允许清理它的缓存，清理那一刻还会再检查一次
- “退出并清理”像按 ⌘Q 一样让 App 正常退出；20 秒内没退出（比如在等你保存）就停下来提醒，不会强制关闭。“需确认”的项只帮你退出 App，要删哪些仍由你勾选；命令行程序不会被结束
- 浏览器类缓存只删 Cache、Service Worker 缓存等可重建的目录，不碰书签、密码、Cookie 和网站数据
- 大文件查找跳过 `~/Library`、隐藏目录（.git、.codex 等）、node_modules、数据库文件和 App 数据包（如照片图库），默认不勾选
- AI 项目只清理能重新安装的依赖，不碰 dist、build 等可能是成果的目录；整个项目文件夹只列出来，由你自己决定删不删
- 已卸载 AI 工具的文件夹里如果装着命令行工具（有 bin 目录），一律不动——比如 `~/.deskclaw` 里装着 `claude`、`codex` 命令
- Codex 正在运行（桌面版或命令行）时，不清理它的对话和日志；最近 7 天内的备份不算
- 判断"已卸载 App 的残留"很保守：同一厂商还有 App 装着、名字对得上已安装的 App、最近 30 天有改动，都不算残留
- 每一次操作都会记录在 `~/Library/Logs/MacSweeper/operations.log`

## 代码结构

| 文件 | 作用 |
|---|---|
| `Sources/SweeperCore/Rules.swift` | 清理规则库：扫哪些地方、安全等级。想新增清理项目就改这里 |
| `Sources/SweeperCore/Scanner.swift` | 并行扫描、计算占用空间 |
| `Sources/SweeperCore/Cleaner.swift` | 路径安全检查、移到废纸篓、操作日志 |
| `Sources/sweep/main.swift` | 命令行界面 |
| `Sources/MacSweeper/` | SwiftUI 图形界面：`SweepModel` 管状态，`ContentView` 管布局，`Banners`、`RuleRow`、`Components` 是各部分 |
| `Sources/SweeperCore/Finders.swift` | 浏览器缓存、已卸载 App 残留、大文件的查找逻辑 |
| `Sources/SweeperCore/AIRules.swift` | AI 工具的清理规则，按工具分组 |
| `Sources/SweeperCore/AIFinders.swift` | AI 项目和依赖、Codex 旧对话、已卸载 AI 工具的查找逻辑 |
| `scripts/build-app.sh` | 把图形界面打包成 .app |
| `scripts/make-icon.swift` | 生成 App 图标 |
| `Sources/SweeperCore/SizeCalculator.swift` | 计算占用空间：用底层 fts 遍历，并记住算过的文件夹 |
| `Sources/SweeperCore/Undo.swift` | 撤销上次清理 |
| `Sources/SweeperCore/Uninstaller.swift` | 卸载 App：App 清单、找相关文件并分组、执行卸载 |
| `Sources/MacSweeper/UninstallModel.swift`、`UninstallView.swift` | 卸载 App 的界面 |
| `Sources/SweeperCore/CustomRules.swift` | 读取和检查自定义规则 |
| `Sources/selftest/main.swift` | 自检程序 |
| `scripts/selftest.sh` | 运行自检 |
| `scripts/translations.py` | 英文翻译表，检查并生成翻译文件 |
| `Sources/SweeperCore/RunningApps.swift` | 判断哪些 App、命令行程序正在运行，文件夹属于哪个 App |
| `Sources/SweeperCore/Localization.swift` | 翻译函数 `L()` |
| `scripts/make-dmg.sh` | 生成分发用的 DMG 安装包，可选签名和公证 |

## 权限

废纸篓、部分 App 容器等目录受 macOS 隐私保护。要扫描它们，需要在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”里授权 MacSweeper（用命令行时授权“终端”）。

## 开源协议

[MIT](LICENSE)
