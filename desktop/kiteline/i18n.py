"""电脑生成、发给手机的字按「看的那台设备」的语言出（同 Mac 版 Sources/ServerLang.swift）。

手机每个请求都带 X-Kiteline-Lang（zh / en）。服务端照旧用中文拼字，发出去之前在出口换成英文（中文的设备原样发）：
  - 出口：HTTP 回复（server.route）、实时事件（_broadcast）、锁屏推送（notify）
  - 只换界面文字那几个字段（error、detail、activityText……），会话标题、Claude 的回复这类内容不动
  - 一句话先整句查表；查不到再用表里带占位符的键反推（「已连接 虚拟机」← 「已连接 %@」），变量部分也查一遍
表是 i18n_en.json（中文 → 英文），和手机、Mac 用的同一张，由 tools/i18n.py build 从 i18n/en.json 生成
"""

import json
import os
import re
import threading

from . import config

FIELDS = {"error", "message", "detail", "hint", "status", "reason", "activityText", "blocking", "fix", "label", "summary",
          "note", "warning", "subtitle", "caption", "action", "body", "description", "client", "errors", "readOnlyReason",
          "https"}   # /api/desktop/status 的服务状态（「监听中 127.0.0.1:8766」），客户端设置页显示
# 只有内容（对话、文件、图片、差异……）、个头又大的接口：英文设备也原样回
CONTENT_ONLY = {"/api/history", "/api/media", "/api/file", "/api/files", "/api/git/diff", "/api/digest/media",
                "/api/task-output", "/api/search", "/api/changelog", "/api/agents", "/api/tts", "/api/peers", "/api/download",
                "/api/groups/messages", "/api/groups/media"}
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|\.\d+f|%)")
HAN = re.compile(r"[一-鿿]")

_lock = threading.Lock()
_table = None
_patterns = None
_plurals = {}


def _load():
    global _table, _patterns
    with _lock:
        if _table is not None:
            return
        try:
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "i18n_en.json"), encoding="utf-8") as handle:
                raw = json.load(handle)
        except (OSError, ValueError):
            raw = {}
        # 单复数写成 {"one", "other"}：整句查表用 other，Phrase 按数字挑
        _plurals.update({k: v for k, v in raw.items() if isinstance(v, dict)})
        _table = {k: (v.get("other", k) if isinstance(v, dict) else v) for k, v in raw.items()}
        patterns = []
        for key, english in _table.items():
            if "%" not in key or not PLACEHOLDER.search(key):
                continue
            regex, prefix, seen, pos = "^", "", False, 0
            for match in PLACEHOLDER.finditer(key):
                literal = key[pos:match.start()]
                regex += re.escape(literal)
                if not seen:
                    prefix += literal
                token = match.group(0)
                if token == "%%":
                    regex += "%"
                    if not seen:
                        prefix += "%"
                elif token in ("%lld", "%ld", "%d"):
                    regex += r"(-?\d+)"; seen = True
                elif token in ("%lf", "%f") or token.endswith("f"):
                    regex += r"(-?[\d.]+)"; seen = True
                else:
                    regex += "(.+?)"; seen = True
                pos = match.end()
            regex += re.escape(key[pos:]) + "$"
            fixed = PLACEHOLDER.sub("", key)
            # 固定的字里至少两个汉字才拿来反推：「%@ %@」「%@：%@」这种太泛，会把别的句子拆成乱码
            if seen and len(HAN.findall(fixed)) >= 2:
                patterns.append((re.compile(regex, re.S), prefix, english, len(fixed)))
        # 固定的字越多越具体，先配
        patterns.sort(key=lambda p: -p[3])
        patterns = [p[:3] for p in patterns]
        _patterns = patterns


def translate(text):
    """一句话换成英文（查不到就原样）"""
    if not isinstance(text, str) or not text or not HAN.search(text):
        return text
    _load()
    if text in _table:
        return _table[text]
    if len(text) > 400:   # 这么长的多半是内容（Claude 的回复），不拿几百个句式去配
        return text
    for regex, prefix, english in _patterns:
        if prefix and not text.startswith(prefix):
            continue
        match = regex.match(text)
        if not match:
            continue
        values = iter(translate(v) for v in match.groups())
        return PLACEHOLDER.sub(lambda m: "%" if m.group(0) == "%%" else next(values, ""), english)
    # 「机器名：原因」（各来源连不上时的 errors 都是这样拼的）：两半分开换
    name, colon, reason = text.partition("：")
    if colon and name and translate(reason) != reason:
        return (translate(name) if name == "本机" else name) + ": " + translate(reason)   # 机器名是用户起的，只换默认的「本机」
    return text


class Phrase:
    """日报、早安简报这类许多小段拼起来的话，整句查表配不上，在源头按语言拼（同 Mac 版 ServerLang.swift 的 Phrase）：
    p = Phrase(english)；p("%lld 个会话", n)；分隔符 p.list / p.comma / p.semicolon / p.colon 也跟着语言"""

    def __init__(self, english):
        self.english = english
        self.list = ", " if english else "、"
        self.comma = ", " if english else "，"
        self.semicolon = "; " if english else "；"
        self.colon = ": " if english else "："

    def __call__(self, key, *args):
        fmt = key
        if self.english:
            _load()
            plural = _plurals.get(key)
            if plural:
                fmt = plural.get("one") if len(args) == 1 and args[0] == 1 and "one" in plural else plural.get("other", key)
            else:
                fmt = _table.get(key, key)
        values = iter(args)
        return PLACEHOLDER.sub(lambda m: "%" if m.group(0) == "%%" else str(next(values, "")), fmt)


def localize(value, extra=()):
    """JSON 里界面文字的字段换成英文；extra：这个接口另外要换的字段（就绪检查的 title）。
    同一条带了英文版（titleEn / bodyEn，日报这类在源头按语言拼好的）就直接用它"""
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if k.endswith("En") and k[:-2] in value:
                continue
            if isinstance(value.get(k + "En"), str) and value[k + "En"]:
                out[k] = value[k + "En"]
            elif isinstance(v, str) and (k in FIELDS or k in extra):
                out[k] = translate(v)
            elif isinstance(v, list) and (k in FIELDS or k in extra) and all(isinstance(x, str) for x in v):
                out[k] = [translate(x) for x in v]
            else:
                out[k] = localize(v, extra)
        return out
    if isinstance(value, list):
        return [localize(v, extra) for v in value]
    return value


def lang_of(request):
    return "en" if (request.headers.get("x-kiteline-lang") or "").lower() == "en" else "zh"


# MARK: 电脑端自己的界面（托盘菜单、/desktop 控制台）的语言

# 跟随系统时英文系统也用英文（中文系统用中文），同 iPhone / Mac 的 Lang.followSystemEnglish。
# 翻译没覆盖全时可改回 False：英文系统也先显示中文，免得中英混杂
FOLLOW_SYSTEM_ENGLISH = True
_ui_choice = "system"


def system_chinese():
    """系统界面语言是不是中文：Windows 看用户界面语言（LANGID 主语言 0x04 = 中文），Linux 看 LANGUAGE / LC_* / LANG"""
    if config.IS_WINDOWS:
        try:
            import ctypes
            return (ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF) == 0x04
        except Exception:   # noqa: BLE001
            return True
    for name in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
        value = os.environ.get(name)
        if value:
            return value.lower().startswith("zh")
    return True


def set_ui_choice(choice):
    global _ui_choice
    _ui_choice = choice if choice in ("system", "zh", "en") else "system"


def ui_choice():
    return _ui_choice


def ui_english():
    return _ui_choice == "en" or (_ui_choice == "system" and FOLLOW_SYSTEM_ENGLISH and not system_chinese())


def tr(text):
    """电脑端自己界面上的字：按电脑端的界面语言"""
    return translate(text) if ui_english() else text


# 每台设备的语言（锁屏推送按它发）：存起来，重启后第一条推送也对；内存里留一份，变了才写盘
_langs_lock = threading.Lock()
_langs = None


def _device_langs():
    global _langs
    if _langs is None:
        try:
            with open(config.path("device-langs.json"), encoding="utf-8") as handle:
                _langs = json.load(handle)
        except (OSError, ValueError):
            _langs = {}
    return _langs


def note_lang(device_id, lang):
    if not device_id:
        return
    with _langs_lock:
        langs = _device_langs()
        if langs.get(device_id) == lang:
            return
        langs[device_id] = lang
        try:
            with open(config.path("device-langs.json"), "w", encoding="utf-8") as handle:
                json.dump(langs, handle)
        except OSError:
            pass


def english_devices():
    with _langs_lock:
        return {k for k, v in _device_langs().items() if v == "en"}
