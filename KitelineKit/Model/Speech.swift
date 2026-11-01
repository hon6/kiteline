import Foundation
import Observation
#if os(iOS)
import AVFAudio
#endif

/// 朗读 Claude 的回复（和网页版一样）：默认用 Mac 上的自然语音合成（微软语音或 Mac 自带），手机播放；
/// 也可以选手机自带的语音。开着「朗读模式」时，正在看的会话里 Claude 的新回复自动读出来，
/// 别的会话需要你确认、有结论了也播报一句。
@MainActor
@Observable
final class Speaker: NSObject {
    static let shared = Speaker()

    /// 朗读模式：新回复自动读
    var autoRead: Bool = UserDefaults.standard.bool(forKey: "speakOn") {
        didSet { UserDefaults.standard.set(autoRead, forKey: "speakOn") }
    }
    /// mac = Mac 合成（推荐）；device = 手机自带
    var engine: String = UserDefaults.standard.string(forKey: "ttsEngine") ?? "mac" {
        didSet { UserDefaults.standard.set(engine, forKey: "ttsEngine") }
    }
    /// Mac 上的哪个声音；空 = Mac 自动挑最自然的
    var voiceId: String = UserDefaults.standard.string(forKey: "ttsVoice") ?? "" {
        didSet { UserDefaults.standard.set(voiceId, forKey: "ttsVoice") }
    }
    var rate: Double = UserDefaults.standard.object(forKey: "ttsRate") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(rate, forKey: "ttsRate") }
    }

    /// 正在读的消息 id（"sample" = 试听）
    private(set) var speaking: String?
    weak var api: MacAPI?
    private var queue: [(text: String, id: String)] = []
    private var run = 0
    /// 正在录音（按住说话、听写）：先不读，别和你说话撞在一起，读的声音也不会录进去
    private var listening = false
    private var resume: Task<Void, Never>?
    #if os(iOS)
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    #endif

    static var sample: String { L("首页卡片间距已调整为十六像素，测试全部通过。请查看截图，确认无误后我将提交。") }

    /// 点同一条：在读就停，没在读就读
    func toggle(_ text: String, id: String) {
        if speaking == id { stop(); return }
        speak(text, id: id)
    }

    func speak(_ text: String, id: String) {
        stop()
        queue = [(text, id)]
        next()
    }

    /// 排在后面读（自动朗读的新回复、别的会话的播报）
    func enqueue(_ text: String, id: String) {
        queue.append((text, id))
        if speaking == nil { next() }
    }

    func stop() {
        queue = []
        halt()
    }

    /// 开始录音：正在读的停下（你开口就是打断它，不再重读），排着的和录音时新来的（任务完成、需要确认的播报）先留着
    func pauseForMic() {
        listening = true
        resume?.cancel()
        resume = nil
        halt()
    }

    /// 录完了：稍等一下再接着读排着的（松手、马上又按住时不会读出半句）
    func resumeAfterMic() {
        guard listening else { return }
        resume?.cancel()
        resume = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            listening = false
            if speaking == nil { next() }
        }
    }

    /// 停下正在读的（排着的不动）
    private func halt() {
        run += 1
        speaking = nil
        #if os(iOS)
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
        #endif
    }

    private func next() {
        guard !queue.isEmpty, !listening else { speaking = nil; return }
        let (text, id) = queue.removeFirst()
        speaking = id
        run += 1
        let current = run
        Task {
            let plain = Self.plain(text)
            var ok = false
            if engine == "mac", let api {
                ok = await speakOnMac(plain, api: api, run: current)
            }
            if !ok, run == current { ok = await speakOnDevice(plain, run: current) }
            if run == current { next() }
        }
    }

    /// Mac 合成：按句子切段，一段一段取回来放（第一段短一点，声音早点出来）
    private func speakOnMac(_ text: String, api: MacAPI, run current: Int) async -> Bool {
        #if os(iOS)
        let pieces = Self.chunks(text, first: 80, rest: 400)
        var prefetch: Task<Data?, Never>?
        for (index, piece) in pieces.enumerated() {
            guard run == current else { return true }
            let data: Data?
            if let prefetch { data = await prefetch.value } else { data = try? await api.postData("/api/tts", body: ["text": piece, "voice": voiceId, "rate": rate]) }
            guard let data, run == current else { return index > 0 }
            // 放这一段的同时把下一段合成好
            if index + 1 < pieces.count {
                let following = pieces[index + 1]
                let voice = voiceId, rate = rate
                prefetch = Task { try? await api.postData("/api/tts", body: ["text": following, "voice": voice, "rate": rate]) }
            } else {
                prefetch = nil
            }
            guard await play(data, run: current) else { return index > 0 }
        }
        return true
        #else
        return false
        #endif
    }

    #if os(iOS)
    private func play(_ data: Data, run current: Int) async -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(data: data), player.play() else { return false }
        self.player = player
        while player.isPlaying, run == current { try? await Task.sleep(for: .milliseconds(200)) }
        return true
    }
    #endif

    private func speakOnDevice(_ text: String, run current: Int) async -> Bool {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        for piece in Self.chunks(text, first: 160, rest: 160) {
            guard run == current else { return true }
            let utterance = AVSpeechUtterance(string: piece)
            // 有中文用中文声音，没有（英文界面的播报、Claude 写的英文）用英文声音：中文声音读英文很别扭
            utterance.voice = AVSpeechSynthesisVoice(language: piece.range(of: "\\p{Han}", options: .regularExpression) != nil ? "zh-CN" : "en-US")
            utterance.rate = Float(min(0.62, max(0.4, 0.5 * rate)))
            synth.speak(utterance)
            try? await Task.sleep(for: .milliseconds(300))
            while synth.isSpeaking, run == current { try? await Task.sleep(for: .milliseconds(200)) }
        }
        return true
        #else
        return false
        #endif
    }

    /// markdown → 适合读的纯文本：代码块不读，链接只读文字，表格一行读成一句（和网页版一样）
    static func plain(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: "\n（代码略）\n", options: .regularExpression)
        var lines: [String] = []
        for raw in s.components(separatedBy: "\n") {
            var line = raw
            if line.range(of: "^\\s*\\|?\\s*:?-{3,}", options: .regularExpression) != nil { continue }
            if line.contains("|") { line = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "，") + "。" }
            line = line.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^\\s*([-*+]|\\d+[.)])\\s+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^\\s*>\\s?", with: "", options: .regularExpression)
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        s = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        s = s.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "（图片）", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "https?://\\S+", with: "（链接）", options: .regularExpression)
            .replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[*_~]{1,3}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "([^。！？：；，.!?:;,])\\n", with: "$1。", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "([：:；;，,])。", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "。{2,}", with: "。", options: .regularExpression)
        return String(s.trimmingCharacters(in: .whitespaces).prefix(3000))
    }

    /// 按句子切段：每段不超过 limit 个字
    static func chunks(_ text: String, first: Int, rest: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?；;".contains(ch) {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        var out: [String] = []
        var piece = ""
        for part in parts {
            let limit = out.isEmpty ? first : rest
            if !piece.isEmpty, piece.count + part.count > limit {
                out.append(piece)
                piece = ""
            }
            piece += part
        }
        if !piece.isEmpty { out.append(piece) }
        return out.isEmpty ? [text] : out
    }
}
