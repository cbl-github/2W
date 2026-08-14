#!/bin/bash
# 打包 dist/2W.dmg（拖进 Applications 的经典布局）。
# 用法: scripts/make-dmg.sh          先跑 ./build.sh --universal 再执行本脚本
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/2W.app
DMG=dist/2W.dmg
[ -d "$APP" ] || { echo "先构建：./build.sh --universal" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# 暂存目录里只放 app 和 /Applications 快捷方式：挂载后拖过去就装好
STAGE=$(mktemp -d -t 2w-dmg)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# UDZO = 压缩只读镜像；srcfolder 直接用暂存目录，不需要先造可写镜像再转换
hdiutil create -volname "2W $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"

codesign --force --sign - "$DMG"
echo "wrote $DMG ($(du -h "$DMG" | cut -f1))"
