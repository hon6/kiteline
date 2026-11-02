#!/usr/bin/env python3
"""世界模式网页里的界面文字（t('…')、墙上的标语）汇总进 KitelineKit/Model/WorldStrings.swift 的 keys（Mac、iPhone 宿主按它翻好交给网页），
并列出 i18n/en.json 里还没有英文的。网页加了文字跑一遍：python3 tools/world-strings.py"""
import glob, json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
keys = set()
for f in glob.glob(os.path.join(ROOT, "Resources/world/js/*.js")):
    if f.endswith("demo.js"):
        continue
    for m in re.finditer(r"\bt\('((?:[^'\\]|\\.)*)'", open(f, encoding="utf-8").read()):
        keys.add(m.group(1).replace("\\n", "\n"))
# 数据流大屏：卡片名、工具通道、阶段标题这些是表里的字面量、按变量查 t()，整份收进来（只收带汉字的）
for name in ("flow.js", "flowdash.js", "flowdata.js"):
    src = open(os.path.join(ROOT, "Resources/world/js", name), encoding="utf-8").read()
    src = re.sub(r"^\s*//.*$", "", src, flags=re.M)
    keys.update(m.group(1) for m in re.finditer(r"'((?:[^'\\\n])*[\u4e00-\u9fff](?:[^'\\\n])*)'", src))
walls = open(os.path.join(ROOT, "Resources/world/js/walls.js"), encoding="utf-8").read()
for arr in ("BANNERS", "POSTERS"):
    block = walls[walls.index("const " + arr):walls.index("];", walls.index("const " + arr))]
    keys.update(m.group(1).replace("\\n", "\n") for m in re.finditer(r"'((?:[^'\\]|\\.)*)'", block))
keys |= {"自动", "低", "中", "高", "超高", "最高"}   # 思考等级（hud.js 用变量查）
keys = sorted(k for k in keys if re.search(r"[\u4e00-\u9fff]", k) or "\n" in k)

def lit(k):
    return '"' + k.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'

path = os.path.join(ROOT, "KitelineKit/Model/WorldStrings.swift")
src = open(path, encoding="utf-8").read()
start = src.index("    public static let keys = [")
end = src.index("\n    ]\n", start) + len("\n    ]\n")
lines, line = [], "       "
for k in keys:
    item = " " + lit(k) + ","
    if len(line) + len(item) > 140:
        lines.append(line)
        line = "       "
    line += item
lines.append(line)
src = src[:start] + "    public static let keys = [\n" + "\n".join(lines) + "\n    ]\n" + src[end:]
open(path, "w", encoding="utf-8").write(src)
en = json.load(open(os.path.join(ROOT, "i18n/en.json"), encoding="utf-8"))
missing = [k for k in keys if k not in en]
print("%d 条文字，缺英文 %d 条%s" % (len(keys), len(missing), ("：" + "、".join(missing)) if missing else ""))
