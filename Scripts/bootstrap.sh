#!/usr/bin/env bash
# 本地开发：生成 Xcode 工程并打开。
# 工程文件不入库，改 project.yml 后重跑这个脚本即可。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "需要 XcodeGen：brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
echo "已生成 LotteryWallet.xcodeproj"

if [ "${1:-}" = "--open" ]; then
  open LotteryWallet.xcodeproj
fi
