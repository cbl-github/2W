#!/bin/bash
# 把本地 main 的代码同步到公开仓库，作为一个新提交推上去。
# 用法: scripts/publish.sh "提交说明"
#
# 为什么要有这个脚本：公开仓库不含 docs/（设计文档、竞品调研、交接文档只留本地），
# 而本地 main 的历史里有它们。所以公开史单独走 `public` 分支——它只装代码，
# 每次发布在上面追加一个提交，历史连续，也不会把 docs/ 带出去。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

readonly STAMP='.git/last-publish'

message="${1:?用法: scripts/publish.sh "提交说明"}"
source_branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "${source_branch}" == 'main' ]] || die 1 "请在 main 上执行（当前 ${source_branch}）"
[[ -z "$(git status --porcelain)" ]] || die 1 '工作区不干净，先提交'

git fetch -q origin main
remote="$(git rev-parse origin/main)"

# 远端 tip 不是上次发布留下的那个提交 = 有人直接在 GitHub 上改过（网页编辑、别的机器）。
# 这时候照常覆盖会把那些改动抹掉——2026-08-14 就这么弄丢过一版 Paul 手写的 README。
if [[ -f "${STAMP}" ]] && [[ "$(cat "${STAMP}")" != "${remote}" ]]; then
  err '远端有本地没有的改动，已停止发布。'
  err "上次发布: $(cat "${STAMP}")"
  err "远端现在: ${remote}"
  err '先看看远端改了什么，把它取回本地 main 再发布：'
  git --no-pager log --oneline "$(cat "${STAMP}")..${remote}" >&2
  die 1 "  git show ${remote}:README.md > README.md   # 举例：取回远端的 README"
fi

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
  git commit -q -m "${message}"
  git push -q origin public:main
  git rev-parse HEAD > "${STAMP}" # 下次发布用它判断远端有没有被别人动过
  echo "已推送: ${message}"
fi

git checkout -q "${source_branch}"
