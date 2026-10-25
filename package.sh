#!/bin/bash
# RestReminder 一键打包脚本
# 用法：bash package.sh [版本号]   （默认 1.0）
# 产物：RestReminder.app（重新构建）+ RestReminder-<版本>.dmg（可分发安装包）
set -e
cd "$(dirname "$0")"

VERSION="${1:-1.0}"
APP="RestReminder.app"
DMG="RestReminder-$VERSION.dmg"

# 1. 构建 App（复用 build.sh）
bash build.sh

# 2. 制作 DMG（拖拽安装布局：App + Applications 软链接）
STAGING=$(mktemp -d /tmp/rr-dmg.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "RestReminder" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

# 3. 校验
hdiutil verify "$DMG" >/dev/null && echo "✅ DMG 校验通过"
ls -lh "$APP" "$DMG"
echo "📦 安装包已生成：$(pwd)/$DMG"
