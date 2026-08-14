#!/bin/bash
#
# 各构建脚本共用的辅助函数。用法：source "$(dirname "$0")/common.sh"
#
# 遵循 Google Shell 风格指南：错误信息一律走 STDERR，函数名小写下划线分隔，
# 常量大写并 readonly，变量引用一律 "${var}"。

#######################################
# 打印错误信息到 STDERR，带时间戳。
# Globals:
#   None
# Arguments:
#   任意数量的文本片段
# Returns:
#   None
#######################################
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*" >&2
}

#######################################
# 打印错误信息后退出。
# Arguments:
#   $1 退出码
#   其余：错误文本
#######################################
die() {
  local code="$1"
  shift
  err "$@"
  exit "${code}"
}
