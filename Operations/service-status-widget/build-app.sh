#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
output_root="${1:-${script_dir}/build}"
app_dir="${output_root}/ServiceStatus.app"
contents_dir="${app_dir}/Contents"

mkdir -p "${contents_dir}/MacOS"

xcrun swiftc \
    -O \
    -whole-module-optimization \
    -framework AppKit \
    -framework CoreGraphics \
    "${script_dir}/ServiceStatusWidget.swift" \
    -o "${contents_dir}/MacOS/ServiceStatusWidget"

install -m 644 "${script_dir}/Info.plist" "${contents_dir}/Info.plist"
codesign --force --deep --sign - "${app_dir}"

printf '%s\n' "${app_dir}"
