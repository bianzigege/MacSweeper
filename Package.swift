// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacSweeper",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SweeperCore", targets: ["SweeperCore"]),
        .executable(name: "sweep", targets: ["sweep"]),
        .executable(name: "MacSweeper", targets: ["MacSweeper"]),
    ],
    targets: [
        // 清理核心：规则、扫描、移到废纸篓、日志。命令行和以后的 SwiftUI 界面共用。
        .target(name: "SweeperCore"),
        // 命令行入口
        .executableTarget(name: "sweep", dependencies: ["SweeperCore"]),
        // SwiftUI 图形界面，用 scripts/build-app.sh 打包成 .app
        .executableTarget(name: "MacSweeper", dependencies: ["SweeperCore"]),
    ]
)
