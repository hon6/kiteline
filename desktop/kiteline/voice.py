"""按住说话的转写（对应 Mac 版 LocalASR.swift）：本机离线的 Fun-ASR-Nano（通义实验室，2025-12，int8），sherpa-onnx 运行。

模型约 1 GB，第一次需要时从 hf-mirror.com（国内能直连）下载到数据目录的 asr/ 下。
模型一次最多听二十秒左右：长录音在 8–15 秒之间找一段停顿切开，分段识别再接起来。闲置 30 分钟释放内存。
"""

import hashlib
import os
import re
import threading
import time
import urllib.request
import wave

from . import config, log

MODEL = "sherpa-onnx-funasr-nano-int8-2025-12-30"
# 文件、字节数、SHA-256（huggingface.co 官方仓库的值）：第一个下载源 hf-mirror.com 是第三方镜像，下完逐个核对，对不上就删掉重下
FILES = [
    ("encoder_adaptor.int8.onnx", 237_792_748, "f36dea2e30fbc33b5db1d7a7265cc976c5e5586c77b042d5adb1ad27c72db422"),
    ("llm.int8.onnx", 600_356_593, "dfbf9aa3be41bccc257587f151e15c63fbe1b549f2b517f5ccd5bdce3bf4322a"),
    ("embedding.int8.onnx", 155_584_380, "95e61cd0c9c3b9543339a4cf973c95c116815e745ccc1e0285cbd81f76d18644"),
    ("Qwen3-0.6B/tokenizer.json", 11_422_654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
    ("Qwen3-0.6B/vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ("Qwen3-0.6B/merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
]
MIRRORS = ("https://hf-mirror.com", "https://huggingface.co")
HOTWORDS = ["Claude", "Claude Code", "Kiteline", "Mac", "Windows", "Linux", "VS Code", "DNS", "git",
            "待办", "中继", "局域网", "截图", "会话", "提交", "推送", "九宫格"]

_lock = threading.Lock()
_state = None             # missing / downloading / ready / unavailable
_downloaded = 0
_current = None           # 正在下的文件：[已收字节]
_recognizer = None
_last_used = 0.0
_work = threading.Lock()


def directory():
    override = os.environ.get("KITELINE_ASR_DIR")
    return override or os.path.join(config.config_dir(), "asr", MODEL)


def _complete():
    for name, size, _ in FILES:
        try:
            if os.path.getsize(os.path.join(directory(), name)) != size:
                return False
        except OSError:
            return False
    return True


def _sha256(file_path):
    h = hashlib.sha256()
    with open(file_path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _library():
    try:
        import sherpa_onnx  # noqa: F401
        import numpy  # noqa: F401
        return True
    except ImportError:
        return False


def unavailable_reason():
    return "这个版本没有语音识别组件（sherpa-onnx）" if not _library() else ""


def state():
    """(状态, 下载进度 0–1)"""
    global _state
    with _lock:
        if _state is None:
            _state = "unavailable" if not _library() else ("ready" if _complete() else "missing")
        if _state == "downloading":
            total = sum(size for _, size, _ in FILES)
            return "downloading", min(1.0, (_downloaded + (_current[0] if _current else 0)) / total)
        return _state, 1.0 if _state == "ready" else 0.0


def prepare():
    """没下就开始下（后台）"""
    global _state, _downloaded
    current, _ = state()
    if current != "missing":
        return
    with _lock:
        _state, _downloaded = "downloading", 0
    log.write("开始下载语音识别模型 %s（约 1 GB）" % MODEL)
    threading.Thread(target=_download_all, daemon=True).start()


def _download_all():
    global _state, _downloaded, _current
    try:
        for name, size, digest in FILES:
            target = os.path.join(directory(), name)
            if os.path.exists(target) and os.path.getsize(target) == size and _sha256(target) == digest:
                with _lock:
                    _downloaded += size
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            error = None
            for mirror in MIRRORS:
                url = "%s/csukuangfj/%s/resolve/main/%s" % (mirror, MODEL, name)
                temp = target + ".part"
                try:
                    _current = [0]
                    request = urllib.request.Request(url, headers={"User-Agent": config.USER_AGENT})
                    with urllib.request.urlopen(request, timeout=60) as response, open(temp, "wb") as handle:
                        while True:
                            chunk = response.read(1 << 20)
                            if not chunk:
                                break
                            handle.write(chunk)
                            _current[0] += len(chunk)
                    if os.path.getsize(temp) != size:
                        raise IOError("%s 大小不符（%d / %d）" % (name, os.path.getsize(temp), size))
                    if _sha256(temp) != digest:
                        os.remove(temp)
                        raise IOError("%s 校验失败（SHA-256 与官方不符），已删除" % name)
                    os.replace(temp, target)
                    error = None
                    break
                except OSError as exc:
                    error = exc
                    log.write("语音模型 %s 从 %s 下载失败：%s" % (name, mirror, exc))
                finally:
                    _current = None
            if error:
                raise error
            with _lock:
                _downloaded += size
        with _lock:
            _state = "ready"
        log.write("语音识别模型已就绪")
    except Exception as exc:  # noqa: BLE001
        with _lock:
            _state = "missing"
        log.write("语音识别模型下载失败：%s（下次转写时重试）" % exc)


def _load():
    global _recognizer
    if _recognizer is not None:
        return _recognizer
    import sherpa_onnx
    base = directory()
    started = time.time()
    _recognizer = sherpa_onnx.OfflineRecognizer.from_funasr_nano(
        encoder_adaptor=os.path.join(base, "encoder_adaptor.int8.onnx"), llm=os.path.join(base, "llm.int8.onnx"),
        embedding=os.path.join(base, "embedding.int8.onnx"), tokenizer=os.path.join(base, "Qwen3-0.6B"),
        num_threads=max(2, min(8, (os.cpu_count() or 4) // 2)), language="中文", itn=True, hotwords=",".join(HOTWORDS))
    log.write("语音识别模型已加载（%.1f 秒）" % (time.time() - started))
    threading.Thread(target=_unload_later, daemon=True).start()
    return _recognizer


def _unload_later():
    global _recognizer
    while True:
        time.sleep(60)
        with _work:
            if _recognizer is not None and time.time() - _last_used > 1800:
                _recognizer = None
                log.write("语音识别闲置 30 分钟，已释放模型")
                return


def _read_wav(path):
    import numpy as np
    with wave.open(path, "rb") as handle:
        rate, channels, width = handle.getframerate(), handle.getnchannels(), handle.getsampwidth()
        frames = handle.readframes(handle.getnframes())
    if width != 2:
        raise ValueError("只支持 16 位 PCM 录音")
    samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return samples, rate


def split(samples, rate, low=8.0, high=15.0):
    """超过 high 秒的：在 [low, high] 秒里找 0.3 秒滑动平均能量最低处切开"""
    import numpy as np
    frame, window = rate // 100, 30
    chunks, start = [], 0
    while len(samples) - start > int(high * rate):
        a, b = start + int(low * rate), start + int(high * rate)
        count = (b - a) // frame
        energy = (samples[a:a + count * frame].reshape(count, frame) ** 2).sum(axis=1)
        smooth = np.convolve(energy, np.ones(window), mode="valid")
        cut = a + (int(smooth.argmin()) + window // 2) * frame
        chunks.append(samples[start:cut])
        start = cut
    chunks.append(samples[start:])
    return chunks


def joined(parts):
    text = ""
    for raw in parts:
        part = raw.strip()
        if not part:
            continue
        if text and text[-1] not in "，。？！、；：,.?!":
            text += "，"
        text += part
    while "。。" in text:
        text = text.replace("。。", "。")
    for pattern, word in FIXES:
        text = pattern.sub(word, text)
    return text


# 热词之外的兜底纠正（和 Mac 版 LocalASR.fixes 一致）：英文产品名常被听成发音相近的词，在这个场景里几乎不会是本意
# 边界只看英文字母（中英文挨着写时 \b 不起作用：汉字也算单词字符）
FIXES = [(re.compile(r"(?<![A-Za-z])" + p + r"(?![A-Za-z])", re.IGNORECASE), w) for p, w in (
    (r"(?<!google )(?<!google)(?:cloud|clod|claud)\s*code", "Claude Code"),   # Google Cloud Code 是真有的东西
    (r"克劳德\s*code", "Claude Code"),
    (r"kite?\s*line", "Kiteline"),
    (r"vs\s*code", "VS Code"),
)]


def transcribe(path, locale="zh-CN"):
    global _last_used
    current, progress = state()
    if current == "unavailable":
        raise RuntimeError("这个版本没有语音识别组件")
    if current != "ready":
        prepare()
        raise RuntimeError("语音识别模型下载中（%d%%），完成后即可使用" % int(state()[1] * 100))
    samples, rate = _read_wav(path)
    with _work:
        recognizer = _load()
        started = time.time()
        parts = []
        for chunk in split(samples, rate):
            stream = recognizer.create_stream()
            stream.accept_waveform(rate, chunk)
            recognizer.decode_stream(stream)
            parts.append(stream.result.text)
        _last_used = time.time()
    log.write("本机识别 %.1f 秒录音，用时 %.1f 秒" % (len(samples) / rate, time.time() - started))
    return joined(parts)
