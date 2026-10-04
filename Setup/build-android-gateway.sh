#!/bin/bash
set -euo pipefail
base="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo '此构建入口面向 Apple 芯片 Mac。' >&2
  exit 1
fi
if ! command -v go >/dev/null 2>&1; then
  echo '请先安装 Go（原构建环境为 Go 1.26.5），再执行本脚本。' >&2
  exit 1
fi
mkdir -p "$base/out"
cd "$base/Gateway"
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o "$base/out/webscreen-secure" .
"$base/out/webscreen-secure" -h
echo "已构建：$base/out/webscreen-secure"
echo 'Android 构建不包含 iPhone USB 原生桥和 Apple 原生麦克风 Opus 解码。'
echo '尚未启动任何服务；新设备、白名单、秘密、独立隧道需要先配置。'
