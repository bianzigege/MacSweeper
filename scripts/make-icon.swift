// 生成 App 图标：swift scripts/make-icon.swift
// 输出 Resources/AppIcon.icns（以及预览用的 Resources/AppIcon.png）
import AppKit
import SwiftUI

/// 四角闪光星
struct Sparkle: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: r.maxY), control: c)
        p.addQuadCurve(to: CGPoint(x: r.minX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: r.minY), control: c)
        return p
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            // 底板：824×824 圆角方形（苹果图标网格），带投影
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.33, green: 0.86, blue: 0.80),
                                              Color(red: 0.20, green: 0.42, blue: 0.96)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    // 顶部一层淡淡的高光
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .clear],
                                             startPoint: .top, endPoint: .center))
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 24, y: 14)

            // 硬盘
            ZStack {
                RoundedRectangle(cornerRadius: 64, style: .continuous)
                    .fill(.white)
                    .shadow(color: Color(red: 0.05, green: 0.15, blue: 0.45).opacity(0.35), radius: 22, y: 12)
                VStack(spacing: 0) {
                    Spacer()
                    Rectangle()
                        .fill(Color(red: 0.20, green: 0.42, blue: 0.96).opacity(0.18))
                        .frame(height: 6)
                    HStack {
                        Capsule()
                            .fill(Color(red: 0.20, green: 0.42, blue: 0.96).opacity(0.30))
                            .frame(width: 150, height: 22)
                        Spacer()
                        Circle()
                            .fill(Color(red: 0.25, green: 0.85, blue: 0.62))
                            .frame(width: 34, height: 34)
                    }
                    .padding(.horizontal, 52)
                    .frame(height: 104)
                }
            }
            .frame(width: 500, height: 300)
            .offset(y: 110)

            // 闪光星星
            Sparkle().fill(.white)
                .frame(width: 250, height: 250)
                .shadow(color: .white.opacity(0.6), radius: 18)
                .offset(x: 150, y: -190)
            Sparkle().fill(.white.opacity(0.92))
                .frame(width: 120, height: 120)
                .offset(x: -45, y: -255)
            Sparkle().fill(.white.opacity(0.85))
                .frame(width: 72, height: 72)
                .offset(x: 285, y: -20)
        }
        .frame(width: 1024, height: 1024)
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("渲染失败") }
    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    try! png.write(to: out.appendingPathComponent("AppIcon.png"))
}

// 生成各尺寸并打包成 .icns
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        run("/usr/bin/sips", ["-z", "\(size * scale)", "\(size * scale)",
                              out.appendingPathComponent("AppIcon.png").path,
                              "--out", iconset.appendingPathComponent(name).path])
    }
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path])
print("已生成：\(out.appendingPathComponent("AppIcon.icns").path)")
