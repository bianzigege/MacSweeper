#!/bin/zsh
# 运行自检程序：检查安全护栏、残留判断、去重、大小计算等关键逻辑。
# 测试文件都建在临时目录里，不会碰你的真实文件。每次改了 SweeperCore 都跑一遍。
set -euo pipefail
cd "$(dirname "$0")/.."
swift run -q selftest
