// 生成 App 图标：swift scripts/make-icon.swift
// 输出 Resources/AppIcon.icns（以及预览用的 Resources/AppIcon.png）
// 造型：蓝底 + 白色废纸篓，篓身上镂空一个“撤销”箭头，意思是“只进废纸篓，可以撤销”；右上角两颗闪光
import AppKit
import SwiftUI

/// 品牌只用两个颜色：蓝和白。蓝色有一点点同色系的深浅变化，让底板有厚度
let brand = Color(red: 0.16, green: 0.42, blue: 0.96)        // 主蓝
let brandLight = Color(red: 0.29, green: 0.53, blue: 0.98)   // 底板上沿
let brandDeep = Color(red: 0.11, green: 0.33, blue: 0.86)    // 底板下沿、阴影

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

/// 废纸篓的篓身：上宽下窄，底部圆角大、顶部圆角小
struct BinBody: Shape {
    func path(in r: CGRect) -> Path {
        let inset = r.width * 0.085
        let tl = CGPoint(x: r.minX, y: r.minY), tr = CGPoint(x: r.maxX, y: r.minY)
        let br = CGPoint(x: r.maxX - inset, y: r.maxY), bl = CGPoint(x: r.minX + inset, y: r.maxY)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addArc(tangent1End: tr, tangent2End: br, radius: 18)
        p.addArc(tangent1End: br, tangent2End: bl, radius: 64)
        p.addArc(tangent1End: bl, tangent2End: tl, radius: 64)
        p.addArc(tangent1End: tl, tangent2End: tr, radius: 18)
        p.closeSubpath()
        return p
    }
}

/// 逆时针的“撤销”箭头：圆弧在左上方留一个缺口，箭头在顶上往左指
struct UndoArrow: View {
    let radius: CGFloat = 92
    let line: CGFloat = 38
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func pt(_ deg: Double, _ r: CGFloat) -> CGPoint {
                let t = deg * .pi / 180
                return CGPoint(x: c.x + r * CGFloat(cos(t)), y: c.y + r * CGFloat(sin(t)))
            }
            // 屏幕坐标里角度变小 = 逆时针。从左边 200° 一路转到顶上 -88°，接到箭头底部
            var arc = Path()
            arc.move(to: pt(200, radius))
            for d in stride(from: 200.0, through: -88.0, by: -2) { arc.addLine(to: pt(d, radius)) }
            ctx.stroke(arc, with: .color(brand), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            // 箭头：在 -95° 处，沿逆时针方向的切线
            let head = -95.0 * .pi / 180
            let h = CGPoint(x: c.x + radius * CGFloat(cos(head)), y: c.y + radius * CGFloat(sin(head)))
            let d = CGPoint(x: CGFloat(sin(head)), y: CGFloat(-cos(head)))
            let n = CGPoint(x: -d.y, y: d.x)
            let len: CGFloat = 64, half: CGFloat = 50
            var tri = Path()
            tri.move(to: CGPoint(x: h.x + d.x * len, y: h.y + d.y * len))
            tri.addLine(to: CGPoint(x: h.x + n.x * half, y: h.y + n.y * half))
            tri.addLine(to: CGPoint(x: h.x - n.x * half, y: h.y - n.y * half))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(brand))
        }
        .frame(width: 300, height: 300)
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            // 底板：824×824 圆角方形（苹果图标网格），带投影
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [brandLight, brand, brandDeep], startPoint: .top, endPoint: .bottom))
                .overlay(
                    // 顶部一层很淡的高光
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center))
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 24, y: 14)

            // 白色废纸篓：提手、盖子、篓身，篓身上镂空一个撤销箭头
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white, lineWidth: 30)
                    .frame(width: 150, height: 84)
                    .offset(y: -222)
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.white)
                    .frame(width: 452, height: 56)
                    .offset(y: -176)
                BinBody()
                    .fill(.white)
                    .frame(width: 384, height: 396)
                    .offset(y: 70)
                UndoArrow()
                    .offset(y: 66)
            }
            .compositingGroup()
            .shadow(color: brandDeep.opacity(0.55), radius: 22, y: 14)
            .offset(y: 8)

            // 闪光：打扫干净了
            Sparkle().fill(.white)
                .frame(width: 112, height: 112)
                .offset(x: 284, y: -286)
            Sparkle().fill(.white.opacity(0.9))
                .frame(width: 52, height: 52)
                .offset(x: 346, y: -186)
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
