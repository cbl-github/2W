#!/bin/bash
# 把本地 main 的代码同步到公开仓库，作为一个新提交推上去。
# 用法: scripts/publish.sh "提交说明"
#
# 为什么要有这个脚本：公开仓库不含 docs/（设计文档、竞品调研、交接文档只留本地），
# 而本地 main 的历史里有它们。所以公开史单独走 `public` 分支——它只装代码，
# 每次发布在上面追加一个提交，历史连续，也不会把 docs/ 带出去。
set -euo pipefail
cd "$(dirname "$0")/.."

MESSAGE=${1:?用法: scripts/publish.sh "提交说明"}
SOURCE=$(git rev-parse --abbrev-ref HEAD)
[ "$SOURCE" = "main" ] || { echo "请在 main 上执行（当前 $SOURCE）" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "工作区不干净，先提交" >&2; exit 1; }

git fetch -q origin main
git checkout -q -B public origin/main

# 用 main 的代码整体覆盖：先清空索引再从 main 取，这样 main 上删掉的文件也会同步删掉。
# docs/ 已在 .gitignore 里，checkout 不会带它进来。
git rm -rq --cached . >/dev/null
git checkout main -- .
git rm -rq --cached docs >/dev/null 2>&1 || true
git add -A

if git diff --cached --quiet; then
  echo "公开仓库已经是最新，无需提交"
else
  git commit -q -m "$MESSAGE"
  git push -q origin public:main
  echo "已推送: $MESSAGE"
fi

git checkout -q "$SOURCE"
