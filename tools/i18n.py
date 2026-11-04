#!/usr/bin/env python3
"""中英文翻译表：i18n/en.json（中文原文 → 英文）是唯一的来源，各端的英文文件都由它生成。

  python3 tools/i18n.py extract <目录>...   把 swiftc -emit-localized-strings 抽出的 .stringsdata（SwiftUI 写死的
                                           Text("…") 这类字）和代码里 L("…") / t("…") 的字并进表里，新的标成未翻译
  python3 tools/i18n.py todo [条数]          列出还没翻译的（带出处），JSON 输出，给翻译用
  python3 tools/i18n.py merge <文件.json>    把翻好的 {中文: 英文} 并回表里
  python3 tools/i18n.py build                生成 en.lproj/Localizable.strings（iPhone、Mac、手表）和电脑端用的 JSON

抽字要在 Mac 上编译时顺带做（swiftc 加 -emit-localized-strings -emit-localized-strings-path <目录>），见 tools/i18n-extract.sh。
表里的值是空字符串 = 还没翻译：生成时跳过，界面上照样显示中文。
只有一个 %lld、没有别的占位符的句子可以写单复数：{"one": "%lld session", "other": "%lld sessions"}，生成到 .stringsdict
（SwiftUI 的 Text 和 L() 都会按数字挑）；电脑端用 other。
"""

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(ROOT, "i18n", "en.json")
SOURCES = os.path.join(ROOT, "i18n", "sources.json")   # 键 → 出处（文件名），翻译时看上下文用
HAN = re.compile(r"[\u4e00-\u9fff]")
# Swift 里 L("…")、L("…", …)；Python 里 t("…")、t("…", …)。只认整段是字面量的
SWIFT_CALL = re.compile(r'(?<![\w.])L\(\s*"((?:[^"\\\n]|\\.)*)"')
PY_CALL = re.compile(r'(?<![\w.])t\(\s*"((?:[^"\\\n]|\\.)*)"')
# 这些文件里所有含中文的字面量都要进表：静态表里的名字存中文、读时才翻（@Localized），抽不到 L("…")
WHOLE_FILES = ("KitelineKit/Views/Look.swift",)
ANY_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*[\u4e00-\u9fff](?:[^"\\\n]|\\.)*)"')
OUTPUTS = [
    os.path.join(ROOT, "KitelineKit", "en.lproj", "Localizable.strings"),
    os.path.join(ROOT, "Resources", "en.lproj", "Localizable.strings"),
]
DESKTOP_JSON = os.path.join(ROOT, "desktop", "kiteline", "i18n_en.json")
CLIENT_JSON = os.path.join(ROOT, "desktop", "client", "Assets", "i18n_en.json")   # Windows / Linux 客户端（打进程序里）


def load(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1, sort_keys=True)
        handle.write("\n")


_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\", "0": "\0"}


def unescape_swift(text):
    """字面量里的转义（\\n、\\"、\\u00A0、Swift 的 \\u{A0}）还原成字符；不认识的（正则里的 \\d、\\s）连反斜杠原样留着；中文等非 ASCII 原样留着
    （以前经 unicode_escape + latin-1 绕一圈，字符串里同时有转义和中文时会解坏）"""
    if "\\" not in text:
        return text
    return re.sub(r"\\(u\{([0-9a-fA-F]+)\}|u([0-9a-fA-F]{4})|.)",
                  lambda m: chr(int(m.group(2) or m.group(3), 16)) if (m.group(2) or m.group(3)) else _ESCAPES.get(m.group(1), "\\" + m.group(1)), text)


def extract(dirs):
    table, sources = load(TABLE, {}), load(SOURCES, {})
    found = {}
    for folder in dirs:
        for path in glob.glob(os.path.join(folder, "**", "*.stringsdata"), recursive=True):
            data = load(path, {})
            for entries in data.get("tables", {}).values():
                for entry in entries:
                    found.setdefault(entry["key"], os.path.basename(data.get("source", "")))
    for pattern, globs in ((SWIFT_CALL, ("Sources/*.swift", "KitelineKit/**/*.swift")), (PY_CALL, ("desktop/kiteline/**/*.py",)),
                           (SWIFT_CALL, ("desktop/client/**/*.cs",))):
        for g in globs:
            for path in glob.glob(os.path.join(ROOT, g), recursive=True):
                if os.sep + "bin" + os.sep in path or os.sep + "obj" + os.sep in path or os.sep + "publish" + os.sep in path:
                    continue
                with open(path, encoding="utf-8") as handle:
                    for match in pattern.finditer(handle.read()):
                        found.setdefault(unescape_swift(match.group(1)), os.path.basename(path))
    for rel in WHOLE_FILES:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
            for line in handle:
                code = line.split("//")[0] if not line.lstrip().startswith("///") else ""
                for match in ANY_LITERAL.finditer(code):
                    if "\\(" not in match.group(1):
                        found.setdefault(unescape_swift(match.group(1)), os.path.basename(rel))
    for key, source in sweep_server().items():
        found.setdefault(key, source)
    added = 0
    for key, source in found.items():
        if not HAN.search(key):
            continue
        if key not in table:
            table[key] = ""
            added += 1
        sources[key] = source
    save(TABLE, table)
    save(SOURCES, sources)
    print("表里 %d 条，新增 %d 条，未翻译 %d 条" % (len(table), added, sum(1 for v in table.values() if not v)))


# 电脑端生成、发给手机的字（服务端不包 L：按看的那台设备的语言在出口换，见 Sources/ServerLang.swift），整个文件扫：
# Mac 的服务端文件、watcher、Windows / Linux 电脑端。日志那几行跳过；变量换成占位符（Swift 的 \(…)、Python 的 %s / %d / {…} 都记成 %@）
MAC_UI = {"SettingsWindow", "MainWindow", "NewTaskSheet", "HistoryView", "ProjectsView", "UsageReportView", "TodayView", "WatchPane",
          "VirtualScreen", "RemotePane", "Profile", "MenuBarPanel", "LookPane", "DesignSystem", "AppDelegate", "KitelineModel",
          "ChangelogWindow", "SelfTest", "ServerLang"}
LOG_LINE = re.compile(r"\b(Log\.write|NSLog|print|log|log\.write|logging\.\w+|NetLog\.\w+|fatalError|assert\w*|precondition)\s*\(")
PY_LITERAL = re.compile(r'(f?)("((?:[^"\\\n]|\\.)*)"|\'((?:[^\'\\\n]|\\.)*)\')')


def sweep_server():
    import importlib.util
    spec = importlib.util.spec_from_file_location("wrap", os.path.join(ROOT, "tools", "i18n-wrap.py"))
    wrap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wrap)
    found = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "Sources", "*.swift"))):
        name = os.path.basename(path)
        if name[:-6] in MAC_UI:
            continue
        with open(path, encoding="utf-8") as handle:
            src = handle.read()
        lines = src.split("\n")
        for start, end, line, _, _, parts in wrap.scan_literals(src):
            text = "".join(p[1] if p[0] == "text" else "%@" for p in parts)
            if HAN.search(text) and not LOG_LINE.search(lines[line - 1]):
                found.setdefault(unescape_swift("".join(p[1].replace("%", "%%") if p[0] == "text" else "%@" for p in parts)
                                                if any(p[0] == "interp" for p in parts) else text), name)
    pys = [os.path.join(ROOT, "watcher", "kiteline-watch.py")] + sorted(glob.glob(os.path.join(ROOT, "desktop", "kiteline", "**", "*.py"), recursive=True))
    for path in pys:
        name = os.path.basename(path)
        # 写在 Python 里的网页（电脑端控制台、说明页）：标签之间的中文
        with open(path, encoding="utf-8") as handle:
            for match in re.finditer(r">([^<>{}]*[\u4e00-\u9fff][^<>{}]*)<", handle.read()):
                text = match.group(1).strip()
                if "\n" not in text and '"' not in text:
                    found.setdefault(text, name)
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                code = line.split("#")[0] if '"' not in line.split("#")[0][-1:] else line
                if LOG_LINE.search(code) or line.lstrip().startswith(("#", '"""')):
                    continue
                for match in PY_LITERAL.finditer(code):
                    text = match.group(3) if match.group(3) is not None else match.group(4)
                    if not text or not HAN.search(text):
                        continue
                    if match.group(1):   # f 字符串：{…} 是变量
                        text = re.sub(r"\{[^{}]*\}", "%@", text.replace("%", "%%"))
                    else:
                        text = re.sub(r"%(?:\.\d+)?[sdrf]", "%@", text)
                        text = re.sub(r"\{\w*\}", "%@", text)
                    found.setdefault(unescape_swift(text), name)
    return found


def todo(limit):
    table, sources = load(TABLE, {}), load(SOURCES, {})
    pending = sorted((k for k, v in table.items() if not v), key=lambda k: (sources.get(k, ""), k))
    json.dump([{"zh": k, "file": sources.get(k, "")} for k in pending[:limit]], sys.stdout, ensure_ascii=False, indent=1)
    print()


PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|\.\d+f)")


def placeholders_ok(zh, en):
    """占位符要一一对上（个数、种类、顺序），不然 String(format:) 会崩或串位；单复数的每一种写法都要对上"""
    want = PLACEHOLDER.findall(zh)
    if isinstance(en, dict):
        return want == ["%lld"] and set(en) <= {"zero", "one", "two", "few", "many", "other"} and "other" in en \
            and all(PLACEHOLDER.findall(v) in ([], want) for v in en.values()) and PLACEHOLDER.findall(en["other"]) == want
    return isinstance(en, str) and PLACEHOLDER.findall(en) == want


def plain(value):
    """电脑端、.strings 用的单一写法：单复数取 other"""
    return value.get("other", "") if isinstance(value, dict) else value


def merge(path):
    table = load(TABLE, {})
    done = load(path, {})
    bad, unknown, merged = [], [], 0
    for zh, en in done.items():
        if not en:
            continue
        if zh not in table:   # 只更新表里已有的：新句子先 extract 进表（不然会悄悄丢掉）
            unknown.append(zh)
            continue
        if not placeholders_ok(zh, en):
            bad.append(zh)
            continue
        table[zh] = en
        merged += 1
    save(TABLE, table)
    print("并入 %d 条，占位符对不上跳过 %d 条%s" % (merged, len(bad), ("：" + " | ".join(bad[:5])) if bad else ""))
    if unknown:
        print("表里还没有、没并入的 %d 条（先 extract，或确认是代码里真用到的字）：%s" % (len(unknown), " | ".join(unknown[:5])))


def escape_strings(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def stringsdict(plurals):
    from xml.sax.saxutils import escape
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
           '<!-- 由 tools/i18n.py build 从 i18n/en.json 生成，别手改 -->', '<plist version="1.0">', "<dict>"]
    for key, forms in plurals.items():
        out += ["<key>%s</key>" % escape(key), "<dict>", "<key>NSStringLocalizedFormatKey</key><string>%#@n@</string>",
                "<key>n</key>", "<dict>", "<key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>",
                "<key>NSStringFormatValueTypeKey</key><string>lld</string>"]
        out += ["<key>%s</key><string>%s</string>" % (form, escape(text)) for form, text in forms.items()]
        out += ["</dict>", "</dict>"]
    out += ["</dict>", "</plist>", ""]
    return "\n".join(out)


def build():
    table = load(TABLE, {})
    done = {k: v for k, v in sorted(table.items()) if v and placeholders_ok(k, v)}
    body = "/* 由 tools/i18n.py build 从 i18n/en.json 生成，别手改 */\n" + "".join(
        '"%s" = "%s";\n' % (escape_strings(k), escape_strings(plain(v))) for k, v in done.items())
    plurals = {k: v for k, v in done.items() if isinstance(v, dict)}
    for path in OUTPUTS:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        with open(path[:-len(".strings")] + ".stringsdict", "w", encoding="utf-8") as handle:
            handle.write(stringsdict(plurals))
    save(DESKTOP_JSON, done)   # 电脑端：单复数原样留着（kiteline/i18n.py 的 Phrase 按数字挑，整句查表用 other）
    save(CLIENT_JSON, done)    # 客户端（desktop/client/Lang.cs）同上
    print("已生成 %d 条英文：%s" % (len(done), "、".join(os.path.relpath(p, ROOT) for p in OUTPUTS + [DESKTOP_JSON, CLIENT_JSON])))


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "extract":
        extract(sys.argv[2:])
    elif command == "todo":
        todo(int(sys.argv[2]) if len(sys.argv) > 2 else 100000)
    elif command == "merge":
        merge(sys.argv[2])
    elif command == "build":
        build()
    else:
        print(__doc__)
        sys.exit(1)
