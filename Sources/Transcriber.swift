import Foundation
import Speech

/// 把手机上「按住说话」录的语音转成文字。
///
/// Claude Code 只收文字和图片，所以语音要先转写。普通话优先用本机的 Fun-ASR-Nano 模型（LocalASR，准得多）；
/// 模型没下好、其他语言、或本机识别出错时，用 Mac 自带的语音识别：
/// 支持的语言优先在本机离线识别（录音不出这台 Mac），否则走 Apple 的在线识别。
/// 第一次用系统识别时会弹窗询问是否允许 Kiteline 使用语音识别。
enum Transcriber {
    static let deniedMessage = "Mac 未允许 Kiteline 使用语音识别（系统设置 → 隐私与安全性 → 语音识别）"

    /// 给手机设置页 / 配对窗口显示
    static var status: String {
        if ProcessInfo.processInfo.environment["CCPULSE_FAKE_TRANSCRIPT"] != nil { return "authorized" }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func requestIfNeeded(completion: ((Bool) -> Void)? = nil) {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else {
            completion?(current == .authorized)
            return
        }
        SFSpeechRecognizer.requestAuthorization { result in
            Log.write("语音识别授权：\(result == .authorized ? "已允许" : "未允许")")
            DispatchQueue.main.async { completion?(result == .authorized) }
        }
    }

    /// 识别任务进行中要持有识别器和任务，否则会被提前释放
    private static var running: [UUID: (SFSpeechRecognizer, SFSpeechRecognitionTask)] = [:]

    static func transcribe(file: URL, locale: String, completion: @escaping (Result<String, RemoteError>) -> Void) {
        // 自检用：不走系统识别，直接返回给定文字（自动化测试里没人能点授权弹窗）
        if let fake = ProcessInfo.processInfo.environment["CCPULSE_FAKE_TRANSCRIPT"] {
            DispatchQueue.main.async { completion(.success(fake)) }
            return
        }
        if locale == "zh-CN" {
            if LocalASR.state == .ready {
                LocalASR.transcribe(file: file) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let text) where !text.isEmpty:
                            completion(.success(text))
                        case .success:
                            system(file: file, locale: locale, completion: completion)
                        case .failure(let error):
                            Log.write("本机语音识别失败（\(error)），改用系统语音识别")
                            system(file: file, locale: locale, completion: completion)
                        }
                    }
                }
                return
            }
            // 模型还没下：这一条先用系统识别，同时在后台下载
            LocalASR.prepare()
        }
        system(file: file, locale: locale, completion: completion)
    }

    /// Mac 自带的语音识别
    private static func system(file: URL, locale: String, completion: @escaping (Result<String, RemoteError>) -> Void) {
        requestIfNeeded { authorized in
            guard authorized else { completion(.failure(RemoteError(deniedMessage))); return }
            recognize(file: file, locale: locale, onDevice: true, completion: completion)
        }
    }

    private static func recognize(file: URL, locale: String, onDevice: Bool,
                                  completion: @escaping (Result<String, RemoteError>) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            completion(.failure(RemoteError("不支持的识别语言：\(locale)")))
            return
        }
        guard recognizer.isAvailable else {
            completion(.failure(RemoteError("语音识别暂时不可用（在线识别需要网络）")))
            return
        }
        let useOnDevice = onDevice && recognizer.supportsOnDeviceRecognition
        let request = SFSpeechURLRecognitionRequest(url: file)
        // 要打开：说话中间一停顿，系统就把前面那段的定稿单独交出来（speechRecognitionMetadata 非空），
        // 最后那个 isFinal 结果只有停顿之后的一段。只看 isFinal，27 秒的话会只剩最后几个字
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = useOnDevice
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = true }

        let id = UUID()
        var finished = false
        /// 已经定稿的几段（每段是一次停顿前说的话）
        var segments: [String] = []
        let finish: (Result<String, RemoteError>) -> Void = { result in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                running.removeValue(forKey: id)?.1.cancel()
                completion(result)
            }
        }
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result = result, result.isFinal || result.speechRecognitionMetadata != nil {
                let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    if !text.isEmpty, text != segments.last { segments.append(text) }
                    if result.isFinal { finish(.success(joined(segments))) }
                }
            } else if let error = error as NSError? {
                // 1110 = 没检测到说话（前面已经有定稿的段落时，是结尾没声音，照样交出去）
                if error.code == 1110 {
                    DispatchQueue.main.async { finish(.success(joined(segments))) }
                } else if useOnDevice {
                    // 离线模型没下载好等情况：退回在线识别再试一次
                    DispatchQueue.main.async {
                        guard !finished else { return }
                        finished = true
                        running.removeValue(forKey: id)
                        Log.write("离线语音识别失败（\(error.localizedDescription)），改用在线识别")
                        recognize(file: file, locale: locale, onDevice: false, completion: completion)
                    }
                } else {
                    finish(.failure(RemoteError("语音识别失败：\(error.localizedDescription)")))
                }
            }
        }
        DispatchQueue.main.async { running[id] = (recognizer, task) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            finish(segments.isEmpty ? .failure(RemoteError("语音识别超时")) : .success(joined(segments)))
        }
    }

    /// 把几段接起来：上一段没以标点结尾就补个逗号（英文补空格）
    static func joined(_ segments: [String]) -> String {
        segments.reduce("") { text, next in
            guard let last = text.last else { return next }
            if last.isPunctuation { return text + next }
            return text + (last.isASCII ? " " : "，") + next
        }
    }
}

/// 手机发过的语音：录音文件 + 转写文字，按会话记下来，手机上的语音气泡靠它回放。
/// 发给 Claude 的只有文字；手机按「文字完全相同」把对话里那条消息认成语音。
final class VoiceStore {
    struct Entry: Codable {
        var id: String
        var key: String
        var text: String
        var duration: Double
        var ts: Double
        var file: String
        var mime: String
    }

    private(set) var entries: [Entry] = []
    private let lock = NSLock()

    static var directory: URL { AppConfig.directoryURL.appendingPathComponent("voice", isDirectory: true) }
    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    init() {
        if let data = try? Data(contentsOf: VoiceStore.indexURL),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
        prune()
    }

    /// 先把录音落盘（转写和回放都读文件）
    func saveAudio(_ data: Data, mime: String) throws -> URL {
        try FileManager.default.createDirectory(at: VoiceStore.directory, withIntermediateDirectories: true)
        let ext: String
        switch mime {
        case let m where m.contains("wav"): ext = "wav"
        case let m where m.contains("mp4"), let m where m.contains("m4a"), let m where m.contains("aac"): ext = "m4a"
        case let m where m.contains("webm"): ext = "webm"
        default: ext = "audio"
        }
        let url = VoiceStore.directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    func record(key: String, text: String, duration: Double, file: URL, mime: String) -> Entry {
        let entry = Entry(id: UUID().uuidString, key: key, text: text, duration: duration,
                          ts: Date().timeIntervalSince1970, file: file.lastPathComponent, mime: mime)
        lock.lock()
        entries.append(entry)
        lock.unlock()
        save()
        return entry
    }

    func list(key: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.key == key }
    }

    func entry(id: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.id == id }
    }

    func fileURL(_ entry: Entry) -> URL { VoiceStore.directory.appendingPathComponent(entry.file) }

    private func save() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: VoiceStore.indexURL, options: .atomic)
        }
    }

    /// 保留 30 天
    private func prune() {
        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
        let expired = entries.filter { $0.ts < cutoff }
        guard !expired.isEmpty else { return }
        for entry in expired { try? FileManager.default.removeItem(at: fileURL(entry)) }
        entries.removeAll { $0.ts < cutoff }
        save()
    }
}
