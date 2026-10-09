// 生成宣传海报（不含任何电脑上的真实数据）：swift scripts/make-posters.swift 输出目录
// 1. 封面：图标 + 一句话
// 2. 三条原则
// 3. 两种模式
import AppKit
import SwiftUI

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : root.appendingPathComponent("docs/宣传配图").path)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let iconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.png"))!

let teal = Color(red: 0.33, green: 0.86, blue: 0.80)
let blue = Color(red: 0.20, green: 0.42, blue: 0.96)
let ink = Color(red: 0.09, green: 0.14, blue: 0.22)

struct Pill: View {
    let icon: String, text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold))
            Text(text).font(.system(size: 24, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(.white.opacity(0.18), in: Capsule())
    }
}

/// 1. 封面
struct Cover: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [teal, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 28) {
                Image(nsImage: iconImage).resizable().frame(width: 260, height: 260)
                Text("MacSweeper").font(.system(size: 72, weight: .bold)).foregroundStyle(.white)
                Text("只进废纸篓，从不直接删除的 Mac 清理工具")
                    .font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                HStack(spacing: 14) {
                    Pill(icon: "trash", text: "只移到废纸篓")
                    Pill(icon: "arrow.uturn.backward", text: "一键撤销")
                    Pill(icon: "list.bullet.rectangle", text: "先看清单再动手")
                    Pill(icon: "lock.open", text: "免费开源")
                }
            }
        }
        .frame(width: 1600, height: 900)
    }
}

/// 2. 三条原则
struct Principles: View {
    let items: [(String, String, String)] = [
        ("trash", "只移到废纸篓，从不直接删除", "清空废纸篓这一步永远由你自己做。后悔了，一键撤销，文件回到原处。"),
        ("doc.text.magnifyingglass", "动手之前一定先列清单", "每一项都写明：这是什么、删了会怎样、我们怎么知道的。找不回来的只能一个一个勾。"),
        ("hand.tap", "新手只看一个数字、点一个按钮", "简单模式只碰删了会自动重建的缓存和日志，正在用的 App 自动跳过。"),
    ]
    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.97, blue: 0.985)
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 16) {
                    Image(nsImage: iconImage).resizable().frame(width: 64, height: 64)
                    Text("MacSweeper 的三条原则").font(.system(size: 44, weight: .bold)).foregroundStyle(ink)
                }
                ForEach(items, id: \.1) { icon, title, body in
                    HStack(alignment: .top, spacing: 24) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [teal, blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                        }
                        .frame(width: 80, height: 80)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title).font(.system(size: 34, weight: .semibold)).foregroundStyle(ink)
                            Text(body).font(.system(size: 24)).foregroundStyle(ink.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(28)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22))
                }
            }
            .padding(70)
        }
        .frame(width: 1600, height: 900)
    }
}

/// 3. 两种模式
struct Modes: View {
    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.97, blue: 0.985)
            HStack(spacing: 40) {
                card("简单模式", "给新手", teal, [
                    "打开就是它", "一个数字：有多少缓存可以放心清理", "一个按钮：安全清理",
                    "只碰删了会自动重建的", "正在用的 App 自动跳过", "聊天记录、文件、登录状态一概不碰",
                ])
                card("详细模式", "给想看明细的人", blue, [
                    "每一项：这是什么 / 删了会怎样 / 我们怎么知道的", "卸载 App，连同缓存、设置、开机自启项",
                    "重复文件，逐字节比对内容", "空间地图，色块看硬盘被谁占了", "导出清单，发给懂的人或问 AI", "每一步都能撤销",
                ])
            }
            .padding(70)
        }
        .frame(width: 1600, height: 760)
    }

    func card(_ title: String, _ sub: String, _ color: Color, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 46, weight: .bold)).foregroundStyle(color)
            Text(sub).font(.system(size: 26)).foregroundStyle(ink.opacity(0.6))
            Divider().padding(.vertical, 6)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(color)
                    Text(line).font(.system(size: 25)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
    }
}

@MainActor func render<V: View>(_ v: V, _ name: String) {
    let r = ImageRenderer(content: v)
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("渲染失败：\(name)") }
    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    try! png.write(to: out.appendingPathComponent(name))
    print("已生成：\(out.appendingPathComponent(name).path)")
}
MainActor.assumeIsolated {
    render(Cover(), "海报-封面.png")
    render(Principles(), "海报-三条原则.png")
    render(Modes(), "海报-两种模式.png")
}
