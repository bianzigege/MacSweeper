#!/usr/bin/env python3
"""把 2026-10-18 的横屏宣传录屏剪成精简版：不重录，只重排、删重复、推近、插 App 截图、加更正提示和中英字幕。

用法：python3 promo/polish.py            # 输出 promo/成片/MacSweeper-宣传-精简版.mp4 和同名 .srt
依赖：ffmpeg（带 libass）、Pillow
"""
import json
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SRC = Path.home() / "Documents/FocuSee/FocuSee Project 2026-10-18 17-41-22.mp4"
SRT_IN = ROOT / "promo/字幕/2026-10-18-宣传视频-中英.srt"
SHOTS = ROOT / "docs/宣传配图"
B = ROOT / "promo/build"
OUT = ROOT / "promo/成片"
FONT = "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc"
W, H, FPS = 1920, 1080, 30
INK = "0x0D1F4A"
PAGE = (5, 16, 37)   # 网页底色，从原片取的
# 原片 1814×1080 → 宽放大到 1920（1143 高）再裁掉上下各约 31 像素
BASE = f"scale={W}:-2,crop={W}:{H}:0:31,setsar=1"
# 左下角圆形头像在 1920 画面里的位置
BUB_X, BUB_Y, BUB_R = 238, 874, 201

# 保留哪些段（原片秒数）、怎么处理。顺序就是成片顺序。
SEGMENTS = [
    # 钩子：扫了一下，三样缓存，剩不到 80G —— 推近到 82GB 条形图
    {"src": (55.85, 71.7)},
    # 它们都不是聊天记录，越积越多
    {"src": (71.85, 87.7)},
    # 做了 MacSweeper → 从不直接删 → AI 能随时删但我不让 → 先进废纸篓
    {"src": (87.85, 132.0),
     "notes": [((104.0, 112.0), "注：系统自带「存储空间管理」，但不会清 App 里的这些缓存",
                "Note: macOS has Storage Management, but it won't clear these in-app caches")],
     "inserts": [((124.0, 132.0), "7-清理完成.png")]},
    # 两个模式 → 简单模式 → 详细模式 → 卸载 App → 空间地图 → AI 工具
    {"src": (144.85, 188.3),
     "inserts": [((145.0, 151.0), "海报-两种模式.png"), ((151.0, 158.0), "1-简单模式.png"),
                 ((158.0, 163.0), "3-详细模式.png"), ((163.0, 166.5), "4-卸载App.png"),
                 ((166.5, 171.0), "5-空间地图.png"), ((171.0, 188.3), "@AI工具总览")]},
    # 不联网、免费开源、两种芯片、深浅色、去网站下载 —— 推近 + 更正提示
    {"src": (188.6, 217.2),
     "notes": [((188.6, 197.0), "更正：除了每天查一次新版本（可以关掉），它不联网",
                "Correction: apart from a daily update check (can be turned off), it stays offline")]},
    # 联系方式 + 我是辫子
    {"src": (228.85, 253.5)},
]


def run(args):
    subprocess.run(args, check=True)


def esc(text: str) -> str:
    return text.replace("\\", "\\\\").replace(":", "\\:").replace("'", "’").replace(",", "\\,").replace("%", "\\%")


def make_assets():
    B.mkdir(parents=True, exist_ok=True)
    # 圆形遮罩：给头像用
    m = Image.new("L", (BUB_R * 2, BUB_R * 2), 0)
    ImageDraw.Draw(m).ellipse((0, 0, BUB_R * 2 - 1, BUB_R * 2 - 1), fill=255)
    m.save(B / "mask.png")
    # 截图：放在墨蓝底上，留边，圆角
    for f in SHOTS.glob("*.png"):
        im = Image.open(f).convert("RGBA")
        im.thumbnail((1500, 860))
        bg = Image.new("RGB", (W, H), (13, 31, 74))
        x, y = (W - im.width) // 2 + 120, (H - im.height) // 2   # 往右挪，给左下头像让位
        r = Image.new("L", im.size, 0)
        ImageDraw.Draw(r).rounded_rectangle((0, 0, im.width - 1, im.height - 1), 18, fill=255)
        bg.paste(im, (x, y), r)
        bg.save(B / f"card-{f.name}")
    # AI 工具总览：竖长图，缩到 1000 宽，后面做从上往下的平移
    ai = Image.open(ROOT / "build/AI工具总览.png").convert("RGB")
    ai = ai.resize((1000, int(ai.height * 1000 / ai.width)))
    ai.save(B / "ai-tall.png")


def render_segment(i, seg):
    s0, s1 = seg["src"]
    dur = s1 - s0
    out = B / f"seg{i:02d}.mp4"
    inputs = ["-ss", f"{s0:.2f}", "-t", f"{dur:.2f}", "-i", str(SRC), "-i", str(B / "mask.png")]
    fc, n = [f"[0:v]{BASE},fps={FPS},split=2[v0][bsrc]"], 0

    def step(filt, extra_in=""):
        nonlocal n
        fc.append(f"[v{n}]{extra_in}{filt}[v{n + 1}]")
        n += 1

    if "zoom" in seg:
        # 只推近头像右边、窗口标题栏下面这块（x≥440、y≥100），锚点在这块的左上角：
        # 接缝落在网页的深色留白里看不出来，原画面里的头像不在这块里，不会出现两个头像
        z0, z1 = seg["zoom"][:2]
        frames = int(dur * FPS)
        rx, ry = 440, 100
        fc.append(f"[v{n}]split=2[full{n}][r{n}]")
        fc.append(f"[r{n}]crop={W - rx}:{H - ry}:{rx}:{ry},zoompan=z='{z0}+({z1}-{z0})*on/{frames}':x=0:y=0:d=1:s={W - rx}x{H - ry}:fps={FPS}[rz{n}]")
        fc.append(f"[full{n}][rz{n}]overlay={rx}:{ry}[v{n + 1}]")
        n += 1
    k = len([x for x in inputs if x == "-i"])
    for (a, b), name in seg.get("inserts", []):
        t0, t1 = a - s0, b - s0
        if name == "@AI工具总览":
            inputs += ["-loop", "1", "-t", f"{dur:.2f}", "-i", str(B / "ai-tall.png")]
            pan = f"40-(h-{H - 80})*min(max((t-{t0:.2f})/{t1 - t0:.2f}\\,0)\\,1)"
            fc.append(f"color=c={INK}:s={W}x{H}:r={FPS}:d={dur:.2f}[bg{k}]")
            fc.append(f"[bg{k}][{k}:v]overlay=x=(W-w)/2+120:y='{pan}':eval=frame[card{k}]")
        else:
            inputs += ["-loop", "1", "-t", f"{dur:.2f}", "-i", str(B / f"card-{name}")]
            fc.append(f"[{k}:v]fps={FPS},format=yuv420p[card{k}]")
        step(f"overlay=enable='between(t,{t0:.2f},{t1:.2f})'", extra_in=f"[card{k}]")
        k += 1
    for (a, b), zh, en in seg.get("notes", []):
        en_ = f"between(t,{a - s0:.2f},{b - s0:.2f})"
        step(f"drawbox=x=0:y=40:w=iw:h=118:color=0x0D1F4A@0.86:t=fill:enable='{en_}',"
             f"drawtext=fontfile='{FONT}':text='{esc(zh)}':fontsize=40:fontcolor=white:x=(w-text_w)/2:y=58:enable='{en_}',"
             f"drawtext=fontfile='{FONT}':text='{esc(en)}':fontsize=26:fontcolor=0xC9D8F5:x=(w-text_w)/2:y=112:enable='{en_}'")
    # 头像永远在最上层：从未推近的原画面里抠圆
    fc.append(f"[bsrc]crop={BUB_R * 2}:{BUB_R * 2}:{BUB_X - BUB_R}:{BUB_Y - BUB_R},format=rgba[bc]")
    fc.append(f"[1:v]format=gray,scale={BUB_R * 2}:{BUB_R * 2}[m]")
    fc.append("[bc][m]alphamerge[bub]")
    fc.append(f"[v{n}][bub]overlay={BUB_X - BUB_R}:{BUB_Y - BUB_R}:shortest=1,format=yuv420p[vout]")
    fc.append(f"[0:a]afade=t=in:d=0.08,afade=t=out:st={dur - 0.1:.2f}:d=0.1,aresample=48000[aout]")
    run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(fc), "-map", "[vout]", "-map", "[aout]",
         "-t", f"{dur:.2f}", "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-r", str(FPS), "-c:a", "aac", "-b:a", "192k", str(out)])
    return out, dur


def parse_srt(p):
    cues = []
    for block in p.read_text().strip().split("\n\n"):
        lines = block.strip().split("\n")
        a, b = lines[1].split(" --> ")
        t = lambda s: int(s[:2]) * 3600 + int(s[3:5]) * 60 + int(s[6:8]) + int(s[9:12]) / 1000
        cues.append((t(a), t(b), lines[2], lines[3] if len(lines) > 3 else ""))
    return cues


def ts(t, ass=False):
    if ass:
        return f"{int(t // 3600)}:{int(t // 60 % 60):02d}:{t % 60:05.2f}"
    ms = int(round(t * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"


def remap_subs(offsets):
    cues, out = parse_srt(SRT_IN), []
    for (s0, s1), base in offsets:
        for a, b, zh, en in cues:
            mid = (a + b) / 2
            if s0 <= mid < s1:
                out.append((max(a, s0) - s0 + base, min(b, s1) - s0 + base, zh, en))
    return out


def write_subs(cues, name):
    srt = "\n".join(f"{i}\n{ts(a)} --> {ts(b)}\n{zh}\n{en}\n" for i, (a, b, zh, en) in enumerate(cues, 1))
    (OUT / f"{name}.srt").write_text(srt)
    head = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {W}
PlayResY: {H}

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,PingFang SC,48,&H00FFFFFF,&H00FFFFFF,&H5A25100A,&H5A25100A,1,0,0,0,100,100,0,0,3,9,0,2,460,120,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    ev = [f"Dialogue: 0,{ts(a, True)},{ts(b, True)},Default,,0,0,0,,{zh}\\N{{\\fs32\\b0\\c&HE6EEF6&}}{en}" for a, b, zh, en in cues]
    (B / f"{name}.ass").write_text(head + "\n".join(ev) + "\n")
    return B / f"{name}.ass"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    make_assets()
    segs, offsets, t = [], [], 0.0
    for i, seg in enumerate(SEGMENTS):
        path, dur = render_segment(i, seg)
        segs.append(path)
        offsets.append((seg["src"], t))
        t += dur
        print(f"段 {i}: {seg['src'][0]:.1f}–{seg['src'][1]:.1f}s → 成片 {offsets[-1][1]:.1f}s 起，{dur:.1f}s")
    (B / "list.txt").write_text("".join(f"file '{p}'\n" for p in segs))
    joined = B / "joined.mp4"
    run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(B / "list.txt"), "-c", "copy", str(joined)])
    name = "MacSweeper-宣传-精简版"
    ass = write_subs(remap_subs(offsets), name)
    fontsdir = str(Path(FONT).parent)
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(joined),
         "-vf", f"subtitles='{ass}':fontsdir='{fontsdir}'",
         "-af", "loudnorm=I=-16:TP=-1.5:LRA=11",
         "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
         str(OUT / f"{name}.mp4")])
    # 不烧字幕的版本，给想在平台上挂外挂字幕的
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(joined), "-af", "loudnorm=I=-16:TP=-1.5:LRA=11",
         "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(OUT / f"{name}-无字幕.mp4")])
    print(f"成片 {t:.1f} 秒 → {OUT / name}.mp4")


if __name__ == "__main__":
    main()
