#!/bin/bash
# 生成 dist/2W.icns。用法: scripts/make-icns.sh dist
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

# macOS 图标集需要的五档边长，每档再出一张 @2x
readonly SIZES=(16 32 128 256 512)

out_dir="${1:-dist}"
mkdir -p "${out_dir}"

png="$(mktemp -t 2w-icon).png"
iconset="$(mktemp -d -t 2w-iconset).iconset"
trap 'rm -rf "${png}" "${iconset}"' EXIT

swift scripts/make-icon.swift "${png}"
mkdir -p "${iconset}"
for size in "${SIZES[@]}"; do
  double=$((size * 2))
  sips -z "${size}" "${size}" "${png}" \
    --out "${iconset}/icon_${size}x${size}.png" >/dev/null
  sips -z "${double}" "${double}" "${png}" \
    --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null
done

if ! iconutil -c icns "${iconset}" -o "${out_dir}/2W.icns"; then
  die 1 "iconutil 打包失败"
fi
echo "wrote ${out_dir}/2W.icns"
