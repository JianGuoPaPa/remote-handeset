#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_ROOT=${1:-"$SCRIPT_DIR/build"}
APP_PATH="$OUTPUT_ROOT/泰国安卓手机.app"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

/usr/bin/swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework WebKit \
  "$SCRIPT_DIR/RemoteAndroidApp.swift" \
  -o "$APP_PATH/Contents/MacOS/RemoteAndroid"

cp "$SCRIPT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"

if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

/usr/bin/codesign --force --sign - "$APP_PATH"
printf '%s\n' "$APP_PATH"
