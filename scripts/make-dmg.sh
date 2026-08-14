#!/bin/bash
# 打包 dist/2W.dmg（拖进 Applications 的经典布局）。
# 用法: scripts/make-dmg.sh          先跑 ./build.sh --universal 再执行本脚本
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

readonly APP='dist/2W.app'
readonly DMG='dist/2W.dmg'

[[ -d "${APP}" ]] || die 1 "先构建：./build.sh --universal"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${APP}/Contents/Info.plist")"

# 暂存目录里只放 app 和 /Applications 快捷方式：挂载后拖过去就装好
stage="$(mktemp -d -t 2w-dmg)"
trap 'rm -rf "${stage}"' EXIT
cp -R "${APP}" "${stage}/"
ln -s /Applications "${stage}/Applications"

rm -f "${DMG}"
# UDZO = 压缩只读镜像；srcfolder 直接用暂存目录，不需要先造可写镜像再转换
if ! hdiutil create -volname "2W ${version}" -srcfolder "${stage}" \
    -ov -format UDZO -quiet "${DMG}"; then
  die 1 "hdiutil 打包失败"
fi

codesign --force --sign - "${DMG}"
echo "wrote ${DMG} ($(du -h "${DMG}" | cut -f1))"
