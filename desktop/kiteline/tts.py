"""朗读（对应 Mac 版 TTS.swift）：电脑合成音频，手机只负责播放（手机自带的语音很机械）。

- 微软语音（Edge「大声朗读」的神经网络语音，晓晓、云希……）：最像真人；用 edge-tts，文字会发到微软的服务器合成，返回 mp3。
- Windows 自带中文语音（SAPI，离线）：比较机械，作为备用；用系统自带的 PowerShell 合成 wav，不另装东西。
- Linux 自带的 espeak 太机械（和 Mac 上不列的 Eloquence 一类），不列：连不上微软时手机改用 iPhone 自带语音。
合成过的按「文字 + 声音 + 语速」缓存在数据目录的 tts-cache/（只有本用户能进，里面是对话内容，不放公共的 /tmp）。
"""

import asyncio
import hashlib
import os
import subprocess
import tempfile
import threading
import time

from . import config, log

# 微软中文神经网络语音（和 Mac 版同一份，id 带 edge: 前缀）
EDGE_VOICES = [
    ("zh-CN-XiaoxiaoNeural", "晓晓（女声，温暖自然）"),
    ("zh-CN-YunxiNeural", "云希（男声，阳光）"),
    ("zh-CN-XiaoyiNeural", "晓伊（女声，活泼）"),
    ("zh-CN-YunjianNeural", "云健（男声，有激情）"),
    ("zh-CN-YunyangNeural", "云扬（男声，播音腔）"),
    ("zh-CN-YunxiaNeural", "云夏（男孩）"),
]
EDGE_TIMEOUT = 20
CACHE_DAYS = 7
CACHE_FILES = 400

_win_voices = None        # [名字]；None = 还没问过系统
_win_checked = 0.0
_lock = threading.Lock()


def edge_available():
    try:
        import edge_tts  # noqa: F401
        return True
    except ImportError:
        return False


def _powershell(script, timeout):
    """跑一段 PowerShell（Windows 自带 5.1）；不弹黑框"""
    return subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
                          capture_output=True, timeout=timeout, creationflags=0x08000000)


def _ps_quote(text):
    return "'" + str(text).replace("'", "''") + "'"


def windows_voices():
    """Windows 上装了的中文语音（SAPI）。问一次要一秒左右，结果记 10 分钟"""
    global _win_voices, _win_checked
    if not config.IS_WINDOWS:
        return []
    with _lock:
        if _win_voices is not None and time.time() - _win_checked < 600:
            return list(_win_voices)
    names = []
    try:
        out = _powershell("[Console]::OutputEncoding = [Text.Encoding]::UTF8; Add-Type -AssemblyName System.Speech; "
                          "(New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices() | "
                          "Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like 'zh-*' } | "
                          "ForEach-Object { $_.VoiceInfo.Name }", 20)
        names = [line.strip() for line in out.stdout.decode("utf-8", "replace").splitlines() if line.strip()]
    except (OSError, subprocess.SubprocessError) as error:
        log.write("读取 Windows 语音失败：%s" % error)
    with _lock:
        _win_voices, _win_checked = names, time.time()
    return list(names)


def voices():
    """和 Mac 版 /api/tts/voices 一样：最自然的在前（quality 越大越好）"""
    result = []
    if edge_available():
        result += [{"id": "edge:" + vid, "name": label, "label": "微软 " + label, "quality": 5} for vid, label in EDGE_VOICES]
    result += [{"id": "win:" + name, "name": name, "label": "%s（Windows 自带语音，较机械）" % name, "quality": 1}
               for name in windows_voices()]
    return result


def best_voice():
    found = voices()
    return found[0]["id"] if found else ""


def _cache_dir():
    path = config.path("tts-cache")
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def _prune(directory):
    """缓存只留最近一周、最多几百段"""
    try:
        entries = sorted((os.path.join(directory, n) for n in os.listdir(directory)), key=os.path.getmtime, reverse=True)
    except OSError:
        return
    cutoff = time.time() - CACHE_DAYS * 86400
    for index, path in enumerate(entries):
        try:
            if index >= CACHE_FILES or os.path.getmtime(path) < cutoff:
                os.remove(path)
        except OSError:
            pass


def _cached(path):
    try:
        with open(path, "rb") as handle:
            data = handle.read()
        return data or None
    except OSError:
        return None


def _store(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)


def _edge(text, voice, rate):
    """微软语音：合成 mp3；连不上、超时返回 None"""
    try:
        import edge_tts
    except ImportError:
        return None
    percent = round((rate - 1) * 100)

    async def run():
        audio = bytearray()
        async for chunk in edge_tts.Communicate(text, voice, rate="%+d%%" % percent).stream():
            if chunk.get("type") == "audio":
                audio += chunk["data"]
        return bytes(audio)

    try:
        data = asyncio.run(asyncio.wait_for(run(), EDGE_TIMEOUT))
        return data or None
    except Exception as error:  # noqa: BLE001  网络、微软那边的各种错误都当合成失败
        log.write("微软语音合成失败：%s" % (str(error)[:200] or type(error).__name__))
        return None


def _sapi(text, name, rate):
    """Windows 自带语音：16 kHz 单声道 wav（文字经 UTF-8 文件传，不拼进命令）"""
    work = tempfile.mkdtemp(prefix="kiteline-tts-")
    try:
        text_file, out = os.path.join(work, "text.txt"), os.path.join(work, "out.wav")
        with open(text_file, "w", encoding="utf-8") as handle:
            handle.write(text)
        level = max(-10, min(10, round((rate - 1) * 10)))
        script = ("Add-Type -AssemblyName System.Speech; "
                  "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
                  "$s.SelectVoice(%s); $s.Rate = %d; "
                  "$f = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, "
                  "[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono); "
                  "$s.SetOutputToWaveFile(%s, $f); $s.Speak([IO.File]::ReadAllText(%s, [Text.Encoding]::UTF8)); $s.Dispose()"
                  % (_ps_quote(name), level, _ps_quote(out), _ps_quote(text_file)))
        result = _powershell(script, 60)
        data = _cached(out)
        if not data:
            log.write("Windows 语音合成失败：%s" % result.stderr.decode("utf-8", "replace")[:200])
        return data
    except (OSError, subprocess.SubprocessError) as error:
        log.write("Windows 语音合成失败：%s" % error)
        return None
    finally:
        for name_ in os.listdir(work):
            try:
                os.remove(os.path.join(work, name_))
            except OSError:
                pass
        try:
            os.rmdir(work)
        except OSError:
            pass


def synthesize(text, voice_id, rate):
    """合成一段：返回 (音频, 类型)，没有可用的声音、都失败返回 None（手机会改用自带语音）。rate：1 = 正常（0.7 ~ 1.4）"""
    voice_id = voice_id or best_voice()
    if not voice_id:
        return None
    rate = min(1.4, max(0.7, float(rate or 1)))
    directory = _cache_dir()
    key = hashlib.sha256(("%s|%s|%s" % (voice_id, rate, text)).encode("utf-8")).hexdigest()[:32]
    if voice_id.startswith("edge:"):
        path = os.path.join(directory, key + ".mp3")
        data = _cached(path)
        if data is None:
            data = _edge(text, voice_id[5:], rate)
            if data:
                _store(path, data)
                _prune(directory)
        if data:
            return data, "audio/mpeg"
        # 微软那边连不上：Windows 退回自带语音，别让朗读断掉；没有自带语音就交给手机
        fallback = windows_voices()
        if not fallback:
            return None
        log.write("改用 Windows 自带语音")
        voice_id = "win:" + fallback[0]
        key = hashlib.sha256(("%s|%s|%s" % (voice_id, rate, text)).encode("utf-8")).hexdigest()[:32]
    if voice_id.startswith("win:"):
        name = voice_id[4:]
        if name not in windows_voices():
            return None
        path = os.path.join(directory, key + ".wav")
        data = _cached(path)
        if data is None:
            data = _sapi(text, name, rate)
            if data:
                _store(path, data)
                _prune(directory)
        return (data, "audio/wav") if data else None
    return None
