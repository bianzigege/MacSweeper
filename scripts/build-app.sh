#!/bin/zsh
# 把 SwiftUI 界面打包成可以双击打开的 build/MacSweeper.app（不需要 Xcode）
# 同时包含 Apple 芯片和 Intel 芯片两个版本。
#
# 默认用本机临时签名。有苹果开发者证书时，设置 SIGN_IDENTITY 即可正式签名：
#   SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.9.0"
APP="build/MacSweeper.app"

for arch in arm64 x86_64; do
    swift build -c release --product MacSweeper --triple "$arch-apple-macosx13.0"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/MacSweeper" \
    .build/arm64-apple-macosx/release/MacSweeper .build/x86_64-apple-macosx/release/MacSweeper
# 图标：没有的话先运行 swift scripts/make-icon.swift 生成
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 翻译：中文是原文，英文在 en.lproj 里；改了翻译先运行 python3 scripts/translations.py
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacSweeper</string>
    <key>CFBundleDisplayName</key><string>MacSweeper</string>
    <key>CFBundleExecutable</key><string>MacSweeper</string>
    <key>CFBundleIdentifier</key><string>local.macsweeper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>App</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>com.apple.application-bundle</string></array>
        </dict>
    </array>
    <key>NSDesktopFolderUsageDescription</key><string>扫描桌面上的大文件，看看哪些空间可以腾出来。</string>
    <key>NSDocumentsFolderUsageDescription</key><string>扫描文稿里的大文件，看看哪些空间可以腾出来。</string>
    <key>NSDownloadsFolderUsageDescription</key><string>扫描下载文件夹里的安装包和大文件。</string>
</dict>
</plist>
EOF

if [ -n "${SIGN_IDENTITY:-}" ]; then
    # 正式签名：开启 Hardened Runtime 和时间戳，公证要求这两项
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    # 本机临时签名：自己电脑上能直接用；发给别人时，对方第一次要右键 → 打开
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "已生成：$(pwd)/$APP"
