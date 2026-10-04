#!/bin/bash
set -euo pipefail
if ! command -v adb >/dev/null 2>&1; then
  echo '请先安装 Android platform-tools，并让 adb 可在 PATH 中找到。' >&2
  exit 1
fi
adb devices -l
echo '这里只读取连接清单，没有启用无线 ADB、修改手机设置或重启服务。'
echo '请记录新两部手机的硬件 serial；首次 USB 授权需在手机上确认。'
