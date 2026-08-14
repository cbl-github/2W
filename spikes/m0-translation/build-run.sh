#!/bin/bash
# 构建最小 .app 并运行 spike。产物在 /tmp/bifeed-m0/，结果在 /tmp/bifeed-m0-result.txt
set -euo pipefail
cd "$(dirname "$0")"
OUT=/tmp/bifeed-m0
APP="$OUT/Spike.app"
rm -rf "$OUT" /tmp/bifeed-m0-result.txt
mkdir -p "$APP/Contents/MacOS"

swiftc -parse-as-library -O -target x86_64-apple-macosx15.0 Spike.swift -o "$APP/Contents/MacOS/Spike"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.paul.bifeed.m0spike</string>
  <key>CFBundleName</key><string>BiFeed M0 Spike</string>
  <key>CFBundleExecutable</key><string>Spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF

codesign --force --sign - "$APP"
open "$APP"
echo "launched; polling result…"
