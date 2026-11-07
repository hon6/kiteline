"""消息翻译（给微信小程序用，POST /api/translate；同 Mac 的 HostTranslate）。

小程序连不上 Google 这类服务、也没有系统翻译，交给电脑联网翻好回去。
拆段同手机上的翻译（KitelineKit/Model/Translator.swift 的 TranslateDoc）：代码块、缩进代码、空行、表格分隔行原样留着；
行首的列表 / 标题 / 引用符号留着；行内代码、网址、数字 + 单位换成 {{n}} 占位符，翻完放回去。
服务按 Google → MyMemory 的顺序，前一个连不上 / 限流就换下一个；连不上的 10 分钟内先跳过。
"""
import json
import re
import threading
import time
import urllib.parse
import urllib.request

_down = {}            # 服务名 → 暂停到什么时候（time.time()）
_lock = threading.Lock()

_MASKS = [r"`[^`]+`", r"\]\([^)\s]+\)", r"https?://[^\s)>\]]+",
          r"\b\d+(?:\.\d+)?(?:px|pt|em|rem|vh|vw|ms|s|KB|MB|GB|TB|k|K|M|x)\b|\d+(?:\.\d+)?%"]
_PREFIX = re.compile(r"^\s*(?:>\s*)*(?:#{1,6}\s+|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)?")


def detect(text):
    """粗分：中文为主 → zh-Hans，其余按英语（技术内容大多是英文）"""
    plain = re.sub(r"```[\s\S]*?```", "", text)
    cjk = len(re.findall(r"[一-鿿]", plain))
    latin = len(re.findall(r"[A-Za-z]", plain))
    if cjk * 3 >= latin and cjk > 0:
        return "zh-Hans"
    return "en" if latin else "auto"


def _mask(text):
    tokens = []
    for pattern in _MASKS:
        def keep(m):
            tokens.append(m.group(0))
            return "{{%d}}" % (len(tokens) - 1)
        text = re.sub(pattern, keep, text)
    return text, tokens


class Doc:
    def __init__(self, text):
        self.lines = []   # ("keep", raw) / ("prose", prefix, lead, trail, piece, tokens) / ("cells", [行…])
        self.pieces = []
        fence = False
        for raw in text.split("\n"):
            t = raw.strip()
            if t.startswith("```") or t.startswith("~~~"):
                fence = not fence
                self.lines.append(("keep", raw))
                continue
            if fence or not t or (t.startswith("|") and set(t) <= set("|-: ")) or raw.startswith("    ") or raw.startswith("\t"):
                self.lines.append(("keep", raw))
                continue
            if t.startswith("|"):
                # 表格一行：每格单独翻（整行一起翻会把格子挪位、吞掉格子）
                self.lines.append(("cells", [self._cell(c, "") for c in raw.split("|")]))
                continue
            m = _PREFIX.match(raw)
            self.lines.append(self._cell(raw[m.end():], raw[:m.end()], raw))

    def _cell(self, body, prefix, raw=None):
        core = body.strip()
        masked, tokens = _mask(core)
        if not re.search(r"[^\W\d_]", re.sub(r"\{\{\d+\}\}", "", masked)):
            return ("keep", raw if raw is not None else prefix + body)
        lead = body[:len(body) - len(body.lstrip(" "))]
        trail = body[len(body.rstrip(" ")):]
        self.pieces.append(masked)
        return ("prose", prefix, lead, trail, len(self.pieces) - 1, tokens)

    def rebuild(self, translated):
        return "\n".join(self._render(line, translated) for line in self.lines)

    def _render(self, line, translated):
        if line[0] == "keep":
            return line[1]
        if line[0] == "cells":
            return "|".join(self._render(c, translated) for c in line[1])
        _, prefix, lead, trail, piece, tokens = line
        text = translated[piece] if piece < len(translated) else self.pieces[piece]
        text = re.sub(r"\*\s+\*", "**", text).strip()
        for i in range(len(tokens) - 1, -1, -1):
            pat = r"\{\s*\{\s*%d\s*\}\s*\}" % i
            if re.search(pat, text):
                text = re.sub(pat, lambda _m, tok=tokens[i]: tok, text, count=1)
            else:
                text += " " + tokens[i]
        return prefix + lead + text + trail


def _post(url, form, timeout):
    data = urllib.parse.urlencode(form).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                                                          "User-Agent": "Mozilla/5.0 Kiteline"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _gcode(code):
    return {"zh-Hans": "zh-CN", "zh-Hant": "zh-TW"}.get(code, code)


def google(pieces, source, target):
    out = []
    batch, size = [], 0

    def flush():
        nonlocal batch, size
        if not batch:
            return
        joined = _google_one("\n".join(batch), source, target)
        lines = joined.split("\n")
        out.extend(lines if len(lines) == len(batch) else [_google_one(p, source, target) for p in batch])
        batch, size = [], 0
    for p in pieces:
        if size + len(p) > 3000:
            flush()
        batch.append(p.replace("\n", " "))
        size += len(p) + 1
    flush()
    return out


def _google_one(text, source, target):
    url = "https://translate.googleapis.com/translate_a/single?client=gtx&dt=t&sl=%s&tl=%s" % (_gcode(source), _gcode(target))
    try:
        reply = _post(url, {"q": text}, 10)
    except Exception:
        raise TranslateError("连不上 Google 翻译", pause=600)
    try:
        return "".join(part[0] for part in reply[0] if part and isinstance(part[0], str))
    except Exception:
        raise TranslateError("Google 翻译返回了无法识别的内容", pause=600)


def _chunks(text, max_bytes=450):
    out, buf = [], ""
    for part in re.split(r"(?<=[。！？.!?;；])\s*", text):
        if buf and len((buf + " " + part).encode()) > max_bytes:
            out.append(buf)
            buf = ""
        while len(part.encode()) > max_bytes:
            cut = max_bytes // 3
            out.append(part[:cut])
            part = part[cut:]
        buf = (buf + " " + part).strip() if buf else part
    if buf:
        out.append(buf)
    return out or [text]


def mymemory(pieces, source, target):
    code = lambda c: {"auto": "autodetect", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW"}.get(c, c)
    out = []
    for p in pieces:
        parts = []
        for chunk in _chunks(p):
            try:
                reply = _post("https://api.mymemory.translated.net/get", {"q": chunk, "langpair": "%s|%s" % (code(source), code(target))}, 12)
            except Exception:
                raise TranslateError("连不上 MyMemory", pause=600)
            if reply.get("quotaFinished"):
                raise TranslateError("MyMemory 今日免费额度已用完", pause=3600)
            if "DISTINCT LANGUAGES" in str(reply.get("responseDetails") or "").upper():
                parts.append(chunk)
                continue
            data = reply.get("responseData") or {}
            if str(reply.get("responseStatus", 200)) != "200" or not data.get("translatedText"):
                raise TranslateError(str(reply.get("responseDetails") or "MyMemory 翻译失败"))
            parts.append(data["translatedText"])
        out.append(" ".join(parts))
    return out


class TranslateError(Exception):
    def __init__(self, message, pause=None):
        super().__init__(message)
        self.pause = pause


def run(text, target=None, source=None, local=False):
    """返回 {text, from, to, engine}；都失败抛 TranslateError。
    11-07 起手机 App、电脑客户端也先交给电脑翻；source 给了就不再自己认。
    local = 只许在电脑本机翻（用户选了「系统翻译」）：Windows / Linux 没有本机翻译，直接说明"""
    if local:
        raise TranslateError("这台电脑不能在本机翻译")
    source = source if source and source != "auto" else detect(text)
    to = target or ("en" if source.startswith("zh") else "zh-Hans")
    if source != "auto" and (source == to or (not source.startswith("zh") and source.split("-")[0] == to.split("-")[0])):
        return {"text": text, "from": source, "to": to, "engine": "none"}
    doc = Doc(text)
    if not doc.pieces:
        return {"text": text, "from": source, "to": to, "engine": "none"}
    now = time.time()
    order = [("google", google), ("mymemory", mymemory)]
    with _lock:
        live = [x for x in order if _down.get(x[0], 0) < now]
    last = "翻译失败"
    for name, fn in (live or order):
        try:
            out = fn(doc.pieces, source, to)
            return {"text": doc.rebuild(out), "from": source, "to": to, "engine": name}
        except TranslateError as e:
            last = str(e)
            if e.pause:
                with _lock:
                    _down[name] = time.time() + e.pause
    raise TranslateError(last)
