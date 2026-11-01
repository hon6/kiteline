import AVFoundation
import CryptoKit
import Foundation

/// 朗读：Mac 合成音频，手机只负责播放（手机浏览器自带的语音很机械）。
/// - 微软语音（Edge「大声朗读」的神经网络语音，晓晓、云希……）：最像真人；用 edge-tts 调，文字会发到微软的服务器合成。
///   edge-tts 装在配置目录的 tts-venv 里（python3 -m venv + pip install edge-tts），没装就不列。
/// - Mac 自带语音：离线；macOS 27 上 App 里只拿得到压缩版婷婷，比较机械，作为备用。
/// 合成过的按「文字 + 声音 + 语速」缓存在临时目录。
final class TTS {
    static let shared = TTS()

    struct Voice {
        var id: String
        var name: String
        var label: String
        var quality: Int
    }

    private let synth = AVSpeechSynthesizer()
    private var pending: [(text: String, voice: String, rate: Double, done: (Data?) -> Void)] = []
    private var busy = false
    private let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("tars-tts", isDirectory: true)

    /// 中文语音，最自然的在前：Siri 自然语音 > 高级 > 增强 > 普通；Eloquence 那批（Eddy、Flo…）太机械，不列
    /// 微软中文神经网络语音（edge-tts 的声音名）
    static let edgeVoices: [(id: String, label: String)] = [
        ("zh-CN-XiaoxiaoNeural", "晓晓（女声，温暖自然）"),
        ("zh-CN-YunxiNeural", "云希（男声，阳光）"),
        ("zh-CN-XiaoyiNeural", "晓伊（女声，活泼）"),
        ("zh-CN-YunjianNeural", "云健（男声，有激情）"),
        ("zh-CN-YunyangNeural", "云扬（男声，播音腔）"),
        ("zh-CN-YunxiaNeural", "云夏（男孩）"),
    ]

    static var edgeTool: URL { AppConfig.directoryURL.appendingPathComponent("tts-venv/bin/edge-tts") }
    static var edgeAvailable: Bool { FileManager.default.isExecutableFile(atPath: edgeTool.path) }

    static func voices() -> [Voice] {
        let edge = edgeAvailable ? edgeVoices.map { Voice(id: "edge:\($0.id)", name: $0.label, label: "微软 \($0.label)", quality: 5) } : []
        return edge + appleVoices()
    }

    private static func appleVoices() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh-CN") && !$0.identifier.contains("eloquence") && !$0.identifier.contains("super-compact") }
            .map { voice -> Voice in
                let siri = voice.identifier.contains("siri")
                let premium = voice.identifier.contains("premium") || voice.quality == .premium
                let rank = siri ? 4 : (premium ? 3 : (voice.quality == .enhanced ? 2 : 1))
                let kind = siri ? "Siri 自然语音" : (premium ? "高级语音" : (rank == 2 ? "增强语音" : "普通语音，较机械"))
                return Voice(id: voice.identifier, name: voice.name, label: "\(voice.name)（\(kind)）", quality: rank)
            }
            .sorted { $0.quality != $1.quality ? $0.quality > $1.quality : $0.name < $1.name }
    }

    static var bestVoiceId: String? { voices().first?.id }

    /// rate：1 = 正常语速（0.7 ~ 1.4）。完成时给出音频和类型（微软是 mp3，Mac 自带是 m4a）
    func synthesize(text: String, voice: String?, rate: Double, completion: @escaping (Data?, String) -> Void) {
        let voiceId = (voice?.isEmpty == false ? voice : nil) ?? Self.bestVoiceId ?? ""
        let clamped = min(1.4, max(0.7, rate))
        let key = SHA256.hash(data: Data("\(voiceId)|\(clamped)|\(text)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        if voiceId.hasPrefix("edge:") {
            let cached = cacheDir.appendingPathComponent("\(key).mp3")
            if let data = try? Data(contentsOf: cached), !data.isEmpty { completion(data, "audio/mpeg"); return }
            edge(text: text, voice: String(voiceId.dropFirst(5)), rate: clamped, to: cached) { [weak self] data in
                if let data = data { completion(data, "audio/mpeg"); return }
                // 微软那边连不上：退回 Mac 自带语音，别让朗读断掉
                Log.write("微软语音合成失败，改用 Mac 自带语音")
                // 没有可用的 Mac 语音时别传空：空 = 自动挑，又会挑回微软语音，转圈不返回
                guard let fallback = Self.appleVoices().first?.id ?? AVSpeechSynthesisVoice(language: "zh-CN")?.identifier else {
                    completion(nil, "audio/mpeg"); return
                }
                self?.synthesize(text: text, voice: fallback, rate: rate, completion: completion)
            }
            return
        }
        let cached = cacheDir.appendingPathComponent("\(key).m4a")
        if let data = try? Data(contentsOf: cached), !data.isEmpty { completion(data, "audio/mp4"); return }
        DispatchQueue.main.async {
            self.pending.append((text, voiceId, clamped, { data in
                if let data = data { try? data.write(to: cached, options: .atomic) }
                completion(data, "audio/mp4")
            }))
            self.pump()
        }
    }

    private func pump() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let job = pending.removeFirst()
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("work-\(UUID().uuidString).m4a")
        let utterance = AVSpeechUtterance(string: job.text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: job.voice) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * job.rate)
        var file: AVAudioFile?
        var finished = false
        let finish: (Bool) -> Void = { [weak self] ok in
            guard !finished else { return }
            finished = true
            file = nil   // 释放时把 AAC 文件写完整
            let data = ok ? try? Data(contentsOf: url) : nil
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                job.done(data?.isEmpty == false ? data : nil)
                self?.busy = false
                self?.pump()
            }
        }
        synth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { let ok = file != nil; DispatchQueue.main.async { finish(ok) }; return }
            if file == nil {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: pcm.format.sampleRate,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
                file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: pcm.format.commonFormat,
                                        interleaved: pcm.format.isInterleaved)
            }
            try? file?.write(from: pcm)
        }
        // 兜底：合成卡住时 30 秒放弃，别让后面的都排着
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish(false) }
    }

    /// 微软语音：edge-tts 子进程合成 mp3（20 秒超时）
    private func edge(text: String, voice: String, rate: Double, to output: URL, completion: @escaping (Data?) -> Void) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let work = cacheDir.appendingPathComponent("edge-\(UUID().uuidString).mp3")
        let percent = Int(((rate - 1) * 100).rounded())
        let process = Process()
        process.executableURL = Self.edgeTool
        process.arguments = ["--voice", voice, "--rate", (percent >= 0 ? "+" : "") + "\(percent)%", "--text", text, "--write-media", work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var done = false
        let finish: (Data?) -> Void = { data in
            DispatchQueue.main.async {
                guard !done else { return }
                done = true
                if let data = data { try? data.write(to: output, options: .atomic) }
                try? FileManager.default.removeItem(at: work)
                completion(data)
            }
        }
        process.terminationHandler = { proc in
            let data = proc.terminationStatus == 0 ? try? Data(contentsOf: work) : nil
            finish(data?.isEmpty == false ? data : nil)
        }
        do { try process.run() } catch { finish(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if process.isRunning { process.terminate() }
            finish(nil)
        }
    }

    /// 缓存超过 200 个文件就清掉旧的
    func trimCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 200 else { return }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        sorted.prefix(files.count - 150).forEach { try? fm.removeItem(at: $0) }
    }
}
