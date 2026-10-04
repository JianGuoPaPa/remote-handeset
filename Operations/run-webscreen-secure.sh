#!/bin/zsh
set -euo pipefail

readonly service_dir="/Users/zhaogongzi/.remote-handset"

export WEBSCREEN_ORIGIN_SECRET="$(/usr/bin/tr -d '\r\n' < "${service_dir}/origin-secret")"
export WEBSCREEN_ALLOWED_ORIGIN="https://70.39.202.192"
export WEBSCREEN_DEVICE_ID="ZY22GHBP48,ZY22K2SXMK,ZY22F68DH8,31629594940010K,ZY22GDWXSZ,ZY22HN3ZS4,10AD6F2LSY0017B,iphone11-usb"
export WEBSCREEN_ADB_PATH="/opt/homebrew/bin/adb"
export WEBSCREEN_USB_RECOVERY_HELPER="/Users/zhaogongzi/.local/bin/remote-handset-usb-reenumerate"
export WEBSCREEN_ADB_RECOVERY_STATE_FILE="${service_dir}/adb-recovery-state.json"
export WEBSCREEN_IPHONE_USB_DRIVER_SOCKET_DIR="${service_dir}/iphone-console"
export WEBSCREEN_IPHONE_USB_UDID="00008030-001E10691152802E"
export WEBSCREEN_IPHONE_USB_VNC_PASSWORD_FILE="${service_dir}/iphone-console/vnc-password"
export GIN_MODE="release"
export WEBSCREEN_TURN_URLS='["turn:70.39.202.192:3478?transport=udp","turn:70.39.202.192:3478?transport=tcp"]'
export WEBSCREEN_TURN_SHARED_SECRET="$(/usr/bin/tr -d '\r\n' < "${service_dir}/turn-shared-secret")"
export WEBSCREEN_TURN_CREDENTIAL_TTL_SECONDS="3600"

exec /Users/zhaogongzi/.local/bin/webscreen-secure \
    -host 127.0.0.1 \
    -port 8079 \
    -pin DISABLED
