#!/bin/zsh
# 总检查：改完代码跑这一个就够。任何一步失败都会停下并报错。
#   1. 编译全部（核心、命令行、图形界面、自检）
#   2. 自检（安全护栏、残留判断、撤销、卸载、重复文件……）
#   3. 翻译检查（漏翻、占位符对不上）并重新生成翻译文件
#   4. 打包 .app（确认图标、翻译、Info.plist 都齐）
#
# 全部通过会打印 “✅ 全部检查通过”。发版前再运行 ./scripts/make-dmg.sh。
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }

step "1/4 编译"
swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build" | grep -vE "^\[" || true
swift build -c release >/dev/null

step "2/4 自检"
./scripts/selftest.sh

step "3/4 翻译"
python3 scripts/translations.py

step "4/4 打包"
./scripts/build-app.sh | tail -1

printf '\n✅ 全部检查通过\n'
