#!/bin/bash
#
# 校验 Swift 代码是否符合本项目采用的风格规范（reers/swift-style-guide 的可测量条款）。
# build.sh 每次构建都会跑。风格靠人记会漂，靠脚本才不会。
#
# 只查能机械判定的四条，主观的（命名是否达意、抽象是否合理）留给代码审查：
#   1. 行长 ≤ 120
#   2. 不用分号作语句分隔符
#   3. 不用制表符
#   4. 单个函数 ≤ 100 行
#
# 多行字符串字面量（嵌入的 HTML/CSS/JS/SQL）不受这些规则约束——那不是 Swift 代码。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

readonly MAX_LINE=120
readonly MAX_FUNC=100

python3 - "${MAX_LINE}" "${MAX_FUNC}" <<'PY'
import pathlib, re, sys

max_line, max_func = int(sys.argv[1]), int(sys.argv[2])
problems = []


def swift_lines(path):
    """产出 (行号, 内容)，跳过多行字符串字面量内部。"""
    out, inside = [], False
    for i, line in enumerate(path.read_text().split("\n"), 1):
        fences = line.count('"""')
        if inside:
            if fences:
                inside = False
            continue
        if fences % 2 == 1:
            inside = True
            continue
        out.append((i, line))
    return out


def strip_literals(line):
    """把字符串字面量、正则字面量与行注释挖掉，只留可判定的代码。"""
    code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    code = re.sub(r'/(?:[^/\\\n]|\\.)+/', "//RE//", code)  # 裸斜杠正则
    return code.split("//")[0]


for path in sorted(pathlib.Path("Sources").rglob("*.swift")):
    rel = str(path)
    text = path.read_text()

    for number, line in swift_lines(path):
        if len(line) > max_line:
            problems.append(f"{rel}:{number} 行长 {len(line)} > {max_line}")
        if "\t" in line:
            problems.append(f"{rel}:{number} 含制表符")
        if ";" in strip_literals(line):
            problems.append(f"{rel}:{number} 用分号分隔语句：{line.strip()[:60]}")

    # 函数长度：从 func 声明找到同缩进的收尾花括号
    pattern = r'^([ ]*)(?:@\w+[ ]+)?(?:(?:public|private|internal|fileprivate|static|nonisolated|override|final)[ ]+)*func[ ]+(\w+)'
    for match in re.finditer(pattern, text, re.M):
        indent, name = match.group(1), match.group(2)
        rest = text[match.start():]
        close = re.search(r'^' + indent + r'\}', rest, re.M)
        if not close:
            continue
        length = rest[:close.end()].count("\n")
        if length > max_func:
            line_no = text[:match.start()].count("\n") + 1
            problems.append(f"{rel}:{line_no} 函数 {name}() 有 {length} 行 > {max_func}")

if problems:
    print(f"Swift 风格检查未通过（{len(problems)} 处）：", file=sys.stderr)
    for problem in problems:
        print(f"    {problem}", file=sys.stderr)
    print("", file=sys.stderr)
    print("规范见 docs/CONVENTIONS.md", file=sys.stderr)
    sys.exit(1)

print("Swift 风格检查通过")
PY
