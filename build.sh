#!/bin/bash
# RestReminder 一键构建脚本：清理 → 编译 → 组装标准 .app bundle → ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

APP=RestReminder.app

# --- 标准 .app bundle 结构（每次从零重建，保证可复现） ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ 编译 main.swift ..."
swiftc -O \
  -framework AppKit \
  -framework UserNotifications \
  main.swift \
  -o "$APP/Contents/MacOS/RestReminder"

cp -f Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

# PkgInfo：bundle 类型标识
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶ ad-hoc 签名 ..."
codesign --force --sign - "$APP"

echo "▶ bundle 结构:"
find "$APP" -print | sed 's/^/   /'

echo "✅ 构建完成: $(pwd)/$APP"
echo "   运行: open $APP   (调试: open $APP --args --demo)"
