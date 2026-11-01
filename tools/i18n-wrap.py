#!/usr/bin/env python3
"""给 Swift 代码里「用 String 传、拼出来的界面文字」包上 L("…")，让它跟着界面语言翻译。

  python3 tools/i18n-wrap.py <stringsdata 目录> <文件.swift>... [--dry]

SwiftUI 写死的 Text("…")、Button("…") 这类字自己会按环境语言翻译，不用包：swiftc -emit-localized-strings 抽出的
.stringsdata 里有它们的位置（tools/i18n-extract.sh 加 KEEP=<目录> 留下），位置对上的跳过。剩下含中文的字面量里，
下面这些也不包（包了会改坏逻辑或没意义）：
  - 注释；日志、断言那几行（Log.write、print、NSLog、NetLog、PerfTrace、fatalError、assert……）
  - 比较、匹配用的：前面是 == / != / case / hasPrefix( / contains( / range(of: / replacingOccurrences(of: 这类
  - 字典的键（后面跟着冒号）；请求体那几行（post( / body: / payload / JSONSerialization）
  - verbatim:、已经在 L( 里的、多行字符串、原始字符串 #"…"#
带插值的 "已连接 \\(name)" 改成 L("已连接 %@", "\\(name)")（参数一律按文字传：%@）。
static let 里包了 L 的只算一次，切换语言后不会变：会列出来，要手动改成计算属性或者在显示的地方再包。
"""

import glob
import json
import os
import re
import sys

HAN = re.compile(r"[一-鿿]")
SKIP_LINE = re.compile(r"\b(Log\.write|NSLog|NetLog\.\w*|PerfTrace\.\w*|beginBackgroundTask|fatalError|assert|assertionFailure|precondition|preconditionFailure|debugPrint|print|os_log|logger\.)\s*\(")
SKIP_BEFORE = re.compile(
    r"(==|!=|\bcase|\bcase let|hasPrefix\(|hasSuffix\(|contains\(|starts\(with:|range\(of:|firstRange\(of:|replacingOccurrences\(of:"
    r"|with:|components\(separatedBy:|split\(separator:|forKey:|verbatim:|Image\(|systemImage:|named:|forResource:|"
    r"identifier:|Notification\.Name\(|Regex\(|pattern:|L\(|\bt\(|AppStorage\(|\?\?\s*\[)\s*$")
PAYLOAD_LINE = re.compile(r"(\bpost\(|\bbody:|payload|JSONSerialization|\.put\(|request\()")


def located(folder):
    """文件名 → {(行, 列)}：SwiftUI 自己会翻译的字面量的位置"""
    spots = {}
    for path in glob.glob(os.path.join(folder, "**", "*.stringsdata"), recursive=True):
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        name = os.path.basename(data.get("source", ""))
        for entries in data.get("tables", {}).values():
            for entry in entries:
                loc = entry.get("location") or {}
                spots.setdefault(name, set()).add((loc.get("startingLine"), loc.get("startingColumn")))
    return spots


def scan_literals(src):
    """找出顶层的普通字符串字面量：返回 [(起, 止, 行号, 列号字符, 列号字节, 片段列表)]。
    片段：("text", 原样转义后的文字) 或 ("interp", 插值表达式源码)。跳过注释、多行和原始字符串"""
    out = []
    i, n, line, line_start = 0, len(src), 1, 0

    def advance_newlines(a, b):
        nonlocal line, line_start
        for k in range(a, b):
            if src[k] == "\n":
                line += 1
                line_start = k + 1

    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            i = j
            continue
        if src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1; j += 2
                elif src.startswith("*/", j):
                    depth -= 1; j += 2
                else:
                    j += 1
            advance_newlines(i, j)
            i = j
            continue
        if src.startswith('"""', i) or (c == "#" and re.match(r'#+"', src[i:])):
            # 多行 / 原始字符串：整段跳过
            if src.startswith('"""', i):
                j = src.find('"""', i + 3)
                j = n if j < 0 else j + 3
            else:
                hashes = re.match(r"#+", src[i:]).group(0)
                j = src.find('"' + hashes, i + len(hashes) + 1)
                j = n if j < 0 else j + 1 + len(hashes)
            advance_newlines(i, j)
            i = j
            continue
        if c == '"':
            start = i
            col_chars = i - line_start + 1
            col_bytes = len(src[line_start:i].encode("utf-8")) + 1
            parts, buf, j = [], [], i + 1
            ok = True
            while j < n:
                ch = src[j]
                if ch == "\\" and j + 1 < n and src[j + 1] == "(":
                    if buf:
                        parts.append(("text", "".join(buf))); buf = []
                    depth, k = 1, j + 2
                    while k < n and depth:
                        if src[k] == "(":
                            depth += 1
                        elif src[k] == ")":
                            depth -= 1
                        elif src[k] == '"':
                            # 插值里的字符串：跳到它结尾
                            k += 1
                            while k < n and src[k] != '"':
                                k += 2 if src[k] == "\\" else 1
                        k += 1
                    parts.append(("interp", src[j + 2:k - 1]))
                    j = k
                    continue
                if ch == "\\":
                    buf.append(src[j:j + 2]); j += 2
                    continue
                if ch == "\n":
                    ok = False
                    break
                if ch == '"':
                    break
                buf.append(ch); j += 1
            if buf:
                parts.append(("text", "".join(buf)))
            end = j + 1
            if ok:
                out.append((start, end, line, col_chars, col_bytes, parts))
            i = end
            continue
        if c == "\n":
            line += 1
            line_start = i + 1
        i += 1
    return out


def wrap(parts):
    texts = [p[1] for p in parts if p[0] == "text"]
    interps = [p[1] for p in parts if p[0] == "interp"]
    if not interps:
        return 'L("%s")' % "".join(texts)
    fmt = "".join(p[1].replace("%", "%%") if p[0] == "text" else "%@" for p in parts)
    return 'L("%s", %s)' % (fmt, ", ".join('"\\(%s)"' % e for e in interps))


def process(path, spots, dry):
    with open(path, encoding="utf-8") as handle:
        src = handle.read()
    name = os.path.basename(path)
    mine = spots.get(name, set())
    lines = src.split("\n")
    edits, statics = [], set()
    for start, end, line, col_c, col_b, parts in scan_literals(src):
        text = "".join(p[1] for p in parts if p[0] == "text")
        if not HAN.search(text):
            continue
        if (line, col_c) in mine or (line, col_b) in mine:
            continue
        current = lines[line - 1]
        line_start = src.rfind("\n", 0, start) + 1
        before = src[line_start:start]
        after = src[end:src.find("\n", end) if src.find("\n", end) >= 0 else len(src)]
        if SKIP_LINE.search(current) or PAYLOAD_LINE.search(current) or "#Preview" in current:
            continue
        if SKIP_BEFORE.search(before.rstrip()):
            continue
        if re.match(r"\s*:", after) and not before.rstrip().endswith("?"):
            continue   # 字典的键（"键": 值）；三元运算 cond ? "甲" : "乙" 的「甲」后面也是冒号，前面有 ? 的不算
        edits.append((start, end, wrap(parts)))
        # static let（含跨行的数组）：往上找最近的声明行
        for back in range(line - 1, max(line - 14, 0) - 1, -1):
            text_line = lines[back]
            if re.search(r"\b(func|var|init)\b", text_line) and back != line - 1:
                break
            if re.search(r"\bstatic\s+let\b", text_line):
                statics.add(back + 1)
                break
    if not edits:
        return 0, []
    out = src
    for start, end, repl in sorted(edits, reverse=True):
        out = out[:start] + repl + out[end:]
    if not dry:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(out)
    return len(edits), sorted(statics)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--dry"]
    dry = "--dry" in sys.argv
    spots = located(args[0])
    total = 0
    for path in args[1:]:
        count, statics = process(path, spots, dry)
        total += count
        if count:
            print("%-40s 包了 %3d 处%s" % (os.path.relpath(path), count, ("；static let 在第 %s 行，要手动处理" % statics) if statics else ""))
    print("合计 %d 处%s" % (total, "（只看不改）" if dry else ""))
