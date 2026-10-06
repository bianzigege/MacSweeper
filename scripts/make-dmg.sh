#!/bin/zsh
# 生成用来分发的安装包 build/MacSweeper-<版本>.dmg
# 打开后把 MacSweeper 拖进“应用程序”即可安装。
#
# 有苹果开发者账号时，可以签名并公证，别人打开就不会有安全提示：
#   1. 先保存一次公证凭据（只需一次）：
#      xcrun notarytool store-credentials macsweeper --apple-id 你的AppleID --team-id TEAMID
#   2. 然后：
#      SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" NOTARY_PROFILE=macsweeper ./scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/MacSweeper.app/Contents/Info.plist)
DMG="build/MacSweeper-$VERSION.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/MacSweeper.app "$STAGE/"
ln -s /Applications "$STAGE/应用程序"

hdiutil create -volname "MacSweeper $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "正在提交苹果公证，通常需要几分钟…"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "已生成：$(pwd)/$DMG（$(du -h "$DMG" | cut -f1)）"
