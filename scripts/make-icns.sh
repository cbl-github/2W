#!/bin/bash
# 生成 dist/2W.icns。用法: scripts/make-icns.sh dist
set -euo pipefail
cd "$(dirname "$0")/.."
OUT_DIR=${1:-dist}
mkdir -p "$OUT_DIR"
PNG=$(mktemp -t 2w-icon).png
swift scripts/make-icon.swift "$PNG"

ICONSET=$(mktemp -d -t 2w-iconset).iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT_DIR/2W.icns"
rm -rf "$PNG" "$ICONSET"
echo "wrote $OUT_DIR/2W.icns"
