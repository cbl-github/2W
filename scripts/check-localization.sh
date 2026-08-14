#!/bin/bash
# 校验本地化表与代码是否同步。build.sh 每次构建都会跑，漏译无法发布。
#
# 它回答三个问题：
#   1. 代码里用了、但某个语言的表里没有的 key（漏译）
#   2. 表里有、代码里已经不再使用的 key（残留）
#   3. 带占位符的 key，各语言的占位符数量是否一致（%@ 数量对不上会崩）
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

BASE=zh-Hans           # 源语言，key 的权威清单以它为准
LANGS="zh-Hans en ja es fr"
DIR=Localization
FAIL=0

used=$(mktemp); trap 'rm -f "$used" "$defined" "$tmp"' EXIT
defined=$(mktemp); tmp=$(mktemp)

# 代码里所有 L(...) 的第一个参数。必须跨行匹配：折行后 key 常在 L( 的下一行，
# 按行 grep 会漏掉它们——漏掉的后果是那个 key 被误报成「已不再使用」，
# 照着删就把五个语言表里的文案删了。
python3 - "$used" <<'EXTRACT'
import pathlib, re, sys
pattern = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
keys = set()
for path in pathlib.Path("Sources").rglob("*.swift"):
    keys.update(pattern.findall(path.read_text()))
pathlib.Path(sys.argv[1]).write_text("\n".join(sorted(keys)) + "\n")
EXTRACT

if [[ ! -s "${used}" ]]; then
  die 1 "没有从代码里提取到任何 key，检查脚本的提取规则是不是过时了"
fi

# 提取规则的自测：折行后的 L( 换行写法必须能被认出来。
# 这条规则退化过一次——按行 grep 漏掉换行的 key，把它误报成「已不再使用」。
if ! python3 - <<'SELFTEST'
import re, sys
pattern = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
samples = {
    'Text(L("a.b"))': "a.b",
    'L(\n    "c.d",\n    x)': "c.d",
    '.help(L(  "e.f", y))': "e.f",
}
for source, expected in samples.items():
    found = pattern.findall(source.replace("\\n", "\n"))
    if expected not in found:
        print(f"提取规则自测失败：{source!r} 应提取出 {expected!r}", file=sys.stderr)
        sys.exit(1)
SELFTEST
then
  die 1 "提取规则自测未通过，先修 check-localization.sh 自己"
fi

keys_of() {  # 提取一个 .strings 里的 key，忽略注释与空行
  grep -oE '^\s*"[^"]+"\s*=' "$1" 2>/dev/null | sed -E 's/^\s*"//; s/"\s*=$//' | sort -u
}

for lang in $LANGS; do
  file="$DIR/$lang.lproj/Localizable.strings"
  if [[ ! -f "${file}" ]]; then
    err "缺少 ${file}"; FAIL=1; continue
  fi
  # 真正解析一遍。格式错了（少个分号、引号没转义）运行时是静默失败——
  # 界面上所有文字变成 key，而下面的正则扫描看不出来。
  if ! plutil -lint "${file}" >/dev/null 2>&1; then
    err "[${lang}] 文件格式非法，plutil 无法解析："
    plutil -lint "${file}" >&2 || true
    FAIL=1; continue
  fi
  keys_of "$file" > "$defined"

  missing=$(comm -23 "$used" "$defined")
  if [ -n "$missing" ]; then
    echo "[$lang] 漏译 $(echo "$missing" | wc -l | tr -d ' ') 条：" >&2
    echo "$missing" | sed 's/^/    /' >&2
    FAIL=1
  fi

  # 残留只在源语言上报：其它语言的多余 key 由源语言这一轮统一暴露
  if [[ "${lang}" == "${BASE}" ]]; then
    orphan=$(comm -13 "$used" "$defined")
    if [ -n "$orphan" ]; then
      echo "[$lang] 表里有 $(echo "$orphan" | wc -l | tr -d ' ') 条代码已不再使用：" >&2
      echo "$orphan" | sed 's/^/    /' >&2
      FAIL=1
    fi
  fi
done

# 占位符数量一致性：某个语言少写一个 %@，String(format:) 运行时才炸
python3 - "$DIR" $LANGS <<'PY' || FAIL=1
import re, sys, pathlib
directory, langs = sys.argv[1], sys.argv[2:]
tables = {}
for lang in langs:
    path = pathlib.Path(directory) / f"{lang}.lproj" / "Localizable.strings"
    if not path.exists():
        continue
    entries = {}
    for m in re.finditer(r'^\s*"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', path.read_text(), re.M):
        entries[m.group(1)] = m.group(2)
    tables[lang] = entries

spec = re.compile(r'%(?:\d+\$)?[@a-z]')
base = tables.get("zh-Hans", {})
bad = 0
for key, text in base.items():
    want = len(spec.findall(text))
    for lang, entries in tables.items():
        if lang == "zh-Hans" or key not in entries:
            continue
        got = len(spec.findall(entries[key]))
        if got != want:
            print(f"[{lang}] 占位符数量不符 {key}：源 {want} 个，此语言 {got} 个", file=sys.stderr)
            bad = 1
sys.exit(bad)
PY

if [[ "${FAIL}" != 0 ]]; then
  echo "" >&2
  echo "本地化检查未通过。新增文案的流程见 Localization/README.md" >&2
  exit 1
fi

echo "本地化检查通过（$(wc -l < "$used" | tr -d ' ') 个 key × $(echo $LANGS | wc -w | tr -d ' ') 种语言）"
