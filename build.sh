#!/bin/bash
# 构建 dist/2W.app。
# 用法: ./build.sh [debug|release] [--universal]
#   --universal 同时编 arm64 与 x86_64（需要完整 Xcode：通用二进制走 XCBuild，纯 CLT 没有）
set -euo pipefail
cd "$(dirname "$0")"
source scripts/common.sh

# Swift 模块名不能以数字开头，所以内部 target 仍叫 BiFeed，产物才叫 2W。
readonly PRODUCT='BiFeed'
readonly APP='dist/2W.app'
readonly XCODE_DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'

conf='release'
universal=0
for arg in "$@"; do
  case "${arg}" in
    debug|release) conf="${arg}" ;;
    --universal) universal=1 ;;
    *) die 1 "未知参数: ${arg}" ;;
  esac
done

# 规范靠脚本守，不靠人记：不通过就不出包
scripts/check-swift-style.sh
scripts/check-localization.sh

if [[ "${universal}" -eq 1 ]]; then
  # 通用二进制走 XCBuild，纯 Command Line Tools 没有它
  export DEVELOPER_DIR="${DEVELOPER_DIR:-${XCODE_DEVELOPER_DIR}}"
  swift build -c "${conf}" --arch arm64 --arch x86_64
  bin="$(swift build -c "${conf}" --arch arm64 --arch x86_64 --show-bin-path)/${PRODUCT}"
else
  swift build -c "${conf}"
  bin=".build/${conf}/${PRODUCT}"
fi

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${bin}" "${APP}/Contents/MacOS/2W"

[[ -f dist/2W.icns ]] || scripts/make-icns.sh dist
cp dist/2W.icns "${APP}/Contents/Resources/2W.icns"

# 本地化表进 Contents/Resources，运行时由 Bundle.main 查表
cp -R Localization/*.lproj "${APP}/Contents/Resources/"

cat > "${APP}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <!-- bundle id 保持 com.paul.bifeed：它是 UserDefaults 域与钥匙串条目的键，
       改了等于把现有安装的设置和凭据全部作废，而用户根本看不见这个字符串。 -->
  <key>CFBundleIdentifier</key><string>com.paul.bifeed</string>
  <key>CFBundleName</key><string>2W</string>
  <key>CFBundleDisplayName</key><string>2W</string>
  <!-- 开发区域即回落语言：系统语言不在下面的列表里时，用英语 -->
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>
    <string>en</string><string>zh-Hans</string><string>ja</string>
    <string>es</string><string>fr</string>
  </array>
  <key>CFBundleExecutable</key><string>2W</string>
  <key>CFBundleIconFile</key><string>2W</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.1</string>
  <key>CFBundleVersion</key><string>9</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.news</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Paul</string>
  <!-- RSS 世界仍有大量 http 源和 http 图片，放行明文请求是规格内需求 -->
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
</dict></plist>
EOF
printf 'APPL????' > "${APP}/Contents/PkgInfo"

codesign --force --sign - "${APP}"
if [[ "${universal}" -eq 1 ]]; then
  echo "built ${APP} (${conf}, universal)"
else
  echo "built ${APP} (${conf})"
fi
lipo -archs "${APP}/Contents/MacOS/2W" | sed 's/^/  架构: /'
