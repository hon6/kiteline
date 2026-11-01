import AVFoundation
import CryptoKit
import Foundation
import SherpaOnnxC

/// 本机离线语音识别：通义实验室的 Fun-ASR-Nano（2025-12，int8），跑在 sherpa-onnx 上。
///
/// 比系统语音识别准得多：拿用户真实录音对比，「中继」「待办」「九宫格」「豆包」「服务小记」这类词系统识别常错，它基本都对，
/// 标点也自然；录音不出这台 Mac。模型约 1 GB，第一次需要时从 hf-mirror.com（国内能直连）下载到数据目录。
/// 没下好、库加载不了（Intel Mac）、识别出错时，Transcriber 退回系统语音识别。
///
/// 库（libsherpa-onnx-c-api.dylib + libonnxruntime.dylib）放在 App 的 Contents/Frameworks，运行时 dlopen：
/// 只有 arm64，通用版里 Intel 那一半照样能编、能跑，只是用不上本机识别。
enum LocalASR {
    // MARK: 模型

    static let modelName = "sherpa-onnx-funasr-nano-int8-2025-12-30"
    /// 文件、字节数、SHA-256（取自 huggingface.co 官方仓库；merges.txt 不走 LFS，按官方 git SHA-1 核对过后算的）。
    /// 第一个下载源是第三方镜像：只按大小校验的话，镜像被篡改时能塞进同样大小的假模型，所以下完逐字节核对哈希
    private static let files: [(path: String, size: Int64, sha256: String)] = [
        ("encoder_adaptor.int8.onnx", 237_792_748, "f36dea2e30fbc33b5db1d7a7265cc976c5e5586c77b042d5adb1ad27c72db422"),
        ("llm.int8.onnx", 600_356_593, "dfbf9aa3be41bccc257587f151e15c63fbe1b549f2b517f5ccd5bdce3bf4322a"),
        ("embedding.int8.onnx", 155_584_380, "95e61cd0c9c3b9543339a4cf973c95c116815e745ccc1e0285cbd81f76d18644"),
        ("Qwen3-0.6B/tokenizer.json", 11_422_654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        ("Qwen3-0.6B/vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        ("Qwen3-0.6B/merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
    ]

    /// 全部核对过哈希后写的记号：内容就是这份清单。没有它（比如旧版只按大小下好的）就当没下完，重新核对一遍
    private static var manifest: String { files.map { "\($0.path) \($0.sha256)" }.joined(separator: "\n") }
    private static var verifiedMark: URL { directory.appendingPathComponent(".sha256-verified") }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static let mirrors = ["https://hf-mirror.com", "https://huggingface.co"]
    /// 产品里常说的词：识别时提示模型优先认成这些（太多会挤占模型的输入长度，控制在二十个以内）
    static let hotwords = ["Claude", "Claude Code", "Kiteline", "Mac", "iPhone", "VS Code", "DNS", "git",
                           "待办", "中继", "局域网", "截图", "会话", "提交", "推送", "九宫格"]

    /// 固定放在正式版的数据目录里（不跟 CCPULSE_CONFIG_DIR 走）：测试实例共用这一份，不会各自再下 1 GB
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TARS/asr/\(modelName)", isDirectory: true)
    }

    enum State: Equatable {
        case missing, downloading(Double), ready, unavailable(String)
    }

    private static let lock = NSLock()
    private static var _state: State?
    private static var activeDownload: URLSessionDownloadTask?
    private static var downloadedBytes: Int64 = 0

    static var state: State {
        lock.lock(); defer { lock.unlock() }
        if case .downloading = _state {
            let total = files.reduce(0) { $0 + $1.size }
            let current = activeDownload?.countOfBytesReceived ?? 0
            return .downloading(min(1, Double(downloadedBytes + current) / Double(total)))
        }
        if let _state { return _state }
        let s: State = !libraryAvailable ? .unavailable("这台 Mac 不支持本机识别（需要 Apple 芯片）")
            : (modelComplete ? .ready : .missing)
        _state = s
        return s
    }

    /// 给设置页、诊断信息显示
    static var statusText: String {
        switch state {
        case .ready: return "Fun-ASR-Nano（本机离线识别）"
        case .downloading(let p): return "正在下载语音识别模型 \(Int(p * 100))%，完成前使用系统语音识别"
        case .missing: return "系统语音识别（首次使用时自动下载更准确的本机模型，约 1 GB）"
        case .unavailable(let why): return "系统语音识别（\(why)）"
        }
    }

    private static var modelComplete: Bool {
        guard (try? String(contentsOf: verifiedMark, encoding: .utf8)) == manifest else { return false }
        return files.allSatisfy { file in
            let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.path).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    /// 没下就开始下（后台，进度看 state）；已在下、已就绪、不支持时什么都不做
    static func prepare() {
        lock.lock()
        let current = _state
        lock.unlock()
        if current == nil { _ = state }
        lock.lock()
        guard _state == .missing else { lock.unlock(); return }
        _state = .downloading(0)
        downloadedBytes = 0
        lock.unlock()
        Log.write("开始下载本机语音识别模型 \(modelName)（约 1 GB）")
        Task.detached(priority: .utility) {
            do {
                try await download()
                lock.lock(); _state = .ready; activeDownload = nil; lock.unlock()
                Log.write("本机语音识别模型已就绪")
            } catch {
                lock.lock(); _state = .missing; activeDownload = nil; lock.unlock()
                Log.write("本机语音识别模型下载失败：\(error.localizedDescription)（下次转写时重试）")
            }
        }
    }

    private static func download() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: verifiedMark)
        for file in files {
            let target = directory.appendingPathComponent(file.path)
            // 已经有了（大小对）：哈希也对才用，不对就删掉重下
            if ((try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value == file.size {
                if (try? sha256(of: target)) == file.sha256 {
                    lock.lock(); downloadedBytes += file.size; lock.unlock()
                    continue
                }
                Log.write("语音模型 \(file.path) 哈希不对，删掉重下")
                try? fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lastError: Error = RemoteError("下载失败")
            var done = false
            for mirror in mirrors where !done {
                let url = URL(string: "\(mirror)/csukuangfj/\(modelName)/resolve/main/\(file.path)")!
                do {
                    let temp = try await fetch(url)
                    let size = ((try? fm.attributesOfItem(atPath: temp.path))?[.size] as? NSNumber)?.int64Value
                    guard size == file.size else {
                        try? fm.removeItem(at: temp)
                        throw RemoteError("\(file.path) 大小不符（\(size ?? 0) / \(file.size)）")
                    }
                    guard (try? sha256(of: temp)) == file.sha256 else {
                        try? fm.removeItem(at: temp)
                        throw RemoteError("\(file.path) 内容和官方哈希不符（下载源可能被篡改）")
                    }
                    try? fm.removeItem(at: target)
                    try fm.moveItem(at: temp, to: target)
                    done = true
                } catch {
                    lastError = error
                    Log.write("语音模型 \(file.path) 从 \(mirror) 下载失败：\(error.localizedDescription)")
                }
            }
            guard done else { throw lastError }
            lock.lock(); downloadedBytes += file.size; lock.unlock()
        }
        try manifest.write(to: verifiedMark, atomically: true, encoding: .utf8)
    }

    /// 下载一个文件到临时位置（任务存起来，进度按已收字节算）
    private static func fetch(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: RemoteError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")); return
                }
                // 回调返回后系统就删掉 location，先挪走
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do { try FileManager.default.moveItem(at: location, to: keep); continuation.resume(returning: keep) }
                catch { continuation.resume(throwing: error) }
            }
            lock.lock(); activeDownload = task; lock.unlock()
            task.resume()
        }
    }

    // MARK: 库

    private typealias CreateRecognizer = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerConfig>?) -> OpaquePointer?
    private typealias DestroyRecognizer = @convention(c) (OpaquePointer?) -> Void
    private typealias CreateStream = @convention(c) (OpaquePointer?) -> OpaquePointer?
    private typealias DestroyStream = @convention(c) (OpaquePointer?) -> Void
    private typealias AcceptWaveform = @convention(c) (OpaquePointer?, Int32, UnsafePointer<Float>?, Int32) -> Void
    private typealias Decode = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
    private typealias GetResult = @convention(c) (OpaquePointer?) -> UnsafePointer<SherpaOnnxOfflineRecognizerResult>?
    private typealias DestroyResult = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerResult>?) -> Void

    private struct API {
        let createRecognizer: CreateRecognizer
        let destroyRecognizer: DestroyRecognizer
        let createStream: CreateStream
        let destroyStream: DestroyStream
        let acceptWaveform: AcceptWaveform
        let decode: Decode
        let getResult: GetResult
        let destroyResult: DestroyResult
    }

    private static let api: API? = {
        guard let dir = Bundle.main.privateFrameworksURL else { return nil }
        // 依赖的 libonnxruntime.dylib 靠它自己的 rpath（@loader_path）在同一个目录里找到
        guard let handle = dlopen(dir.appendingPathComponent("libsherpa-onnx-c-api.dylib").path, RTLD_NOW | RTLD_LOCAL) else {
            if let message = dlerror() { Log.write("本机语音识别库加载失败：\(String(cString: message))") }
            return nil
        }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let a = sym("SherpaOnnxCreateOfflineRecognizer", CreateRecognizer.self),
              let b = sym("SherpaOnnxDestroyOfflineRecognizer", DestroyRecognizer.self),
              let c = sym("SherpaOnnxCreateOfflineStream", CreateStream.self),
              let d = sym("SherpaOnnxDestroyOfflineStream", DestroyStream.self),
              let e = sym("SherpaOnnxAcceptWaveformOffline", AcceptWaveform.self),
              let f = sym("SherpaOnnxDecodeOfflineStream", Decode.self),
              let g = sym("SherpaOnnxGetOfflineStreamResult", GetResult.self),
              let h = sym("SherpaOnnxDestroyOfflineRecognizerResult", DestroyResult.self) else {
            Log.write("本机语音识别库缺少接口")
            return nil
        }
        return API(createRecognizer: a, destroyRecognizer: b, createStream: c, destroyStream: d,
                   acceptWaveform: e, decode: f, getResult: g, destroyResult: h)
    }()

    private static var libraryAvailable: Bool {
        #if arch(arm64)
        return api != nil
        #else
        return false
        #endif
    }

    // MARK: 识别

    /// 识别都在这个串行队列上跑（识别器不是线程安全的）
    private static let queue = DispatchQueue(label: "local-asr", qos: .userInitiated)
    private static var recognizer: OpaquePointer?
    /// 模型常驻约 1 GB 内存：闲置 30 分钟就释放，下次用时再加载（几秒）
    private static var unloadWork: DispatchWorkItem?

    /// 转写一段录音（wav / m4a 等系统能解码的格式）。失败时抛错，调用方退回系统识别
    static func transcribe(file: URL, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            do {
                let started = Date()
                let samples = try loadAudio(file)
                guard let api, let recognizer = try loadRecognizer(api) else { throw RemoteError("本机识别不可用") }
                var parts: [String] = []
                for chunk in split(samples) {
                    let stream = api.createStream(recognizer)
                    defer { api.destroyStream(stream) }
                    chunk.withUnsafeBufferPointer { api.acceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
                    api.decode(recognizer, stream)
                    if let result = api.getResult(stream) {
                        if let text = result.pointee.text { parts.append(String(cString: text)) }
                        api.destroyResult(result)
                    }
                }
                scheduleUnload()
                let text = joined(parts)
                Log.write(String(format: "本机识别 %.1f 秒录音，用时 %.1f 秒", Double(samples.count) / 16000, Date().timeIntervalSince(started)))
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func loadRecognizer(_ api: API) throws -> OpaquePointer? {
        if let recognizer { return recognizer }
        guard state == .ready else { return nil }
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            cStrings.append(p)
            return UnsafePointer(p)
        }
        let dir = directory.path
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.decoding_method = c("greedy_search")
        config.model_config.num_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2)))
        config.model_config.provider = c("cpu")
        config.model_config.funasr_nano.encoder_adaptor = c("\(dir)/encoder_adaptor.int8.onnx")
        config.model_config.funasr_nano.llm = c("\(dir)/llm.int8.onnx")
        config.model_config.funasr_nano.embedding = c("\(dir)/embedding.int8.onnx")
        config.model_config.funasr_nano.tokenizer = c("\(dir)/Qwen3-0.6B")
        config.model_config.funasr_nano.system_prompt = c("You are a helpful assistant.")
        config.model_config.funasr_nano.user_prompt = c("语音转写:")
        config.model_config.funasr_nano.max_new_tokens = 512
        config.model_config.funasr_nano.temperature = 1e-6
        config.model_config.funasr_nano.top_p = 0.8
        config.model_config.funasr_nano.seed = 42
        config.model_config.funasr_nano.language = c("中文")
        config.model_config.funasr_nano.itn = 1
        config.model_config.funasr_nano.hotwords = c(hotwords.joined(separator: ","))
        let started = Date()
        guard let created = withUnsafePointer(to: &config, { api.createRecognizer($0) }) else {
            throw RemoteError("本机语音识别模型加载失败")
        }
        Log.write(String(format: "本机语音识别模型已加载（%.1f 秒）", Date().timeIntervalSince(started)))
        recognizer = created
        return created
    }

    private static func scheduleUnload() {
        unloadWork?.cancel()
        let work = DispatchWorkItem { unload("闲置 30 分钟") }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + 30 * 60, execute: work)
        _ = pressure
    }

    /// 在 queue 上调：转写也在这条队列上，正在转写时不会释放
    private static func unload(_ reason: String) {
        unloadWork?.cancel()
        unloadWork = nil
        guard let recognizer, let api else { return }
        api.destroyRecognizer(recognizer)
        self.recognizer = nil
        Log.write("本机语音识别\(reason)，已释放模型")
    }

    /// 系统内存紧张时，闲着的模型立刻释放，不等 30 分钟：它连推理用的内存池常驻 1～2 GB，
    /// 和别的大程序（安卓模拟器之类）一起时整台 Mac 都在换页，界面跟着卡（10-26 反馈：卡顿，当时交换空间用了 5.9 GB）
    private static let pressure: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { unload("：系统内存紧张") }
        source.resume()
        return source
    }()

    /// 读成 16 kHz 单声道 Float32
    private static func loadAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw RemoteError("录音格式无法转换") }
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let data = output.floatChannelData else { throw RemoteError("录音为空") }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// 模型一次最多听二十秒左右：长录音在 8–15 秒之间找一段停顿切开（0.3 秒滑动平均能量最低处），分段识别再接起来
    static func split(_ samples: [Float], rate: Int = 16000, low: Double = 8, high: Double = 15) -> [ArraySlice<Float>] {
        let frame = rate / 100                     // 10 ms 一帧
        let window = 30                            // 0.3 秒
        var chunks: [ArraySlice<Float>] = []
        var start = 0
        while samples.count - start > Int(high * Double(rate)) {
            let from = start + Int(low * Double(rate)), to = start + Int(high * Double(rate))
            let count = (to - from) / frame
            var energy = [Float](repeating: 0, count: count)
            for i in 0..<count {
                var sum: Float = 0
                for s in samples[(from + i * frame)..<(from + (i + 1) * frame)] { sum += s * s }
                energy[i] = sum
            }
            var best = 0, bestValue = Float.greatestFiniteMagnitude, running: Float = 0
            for i in 0..<count {
                running += energy[i]
                if i >= window { running -= energy[i - window] }
                if i >= window - 1, running < bestValue { bestValue = running; best = i - window / 2 }
            }
            let cut = from + best * frame
            chunks.append(samples[start..<cut])
            start = cut
        }
        chunks.append(samples[start...])
        return chunks
    }

    /// 分段结果接起来：上一段没以标点结尾就补个逗号；去掉多余的空白和重复句号
    static func joined(_ parts: [String]) -> String {
        var text = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let last = text.last, !"，。？！、；：,.?!".contains(last) { text += "，" }
            text += part
        }
        while text.contains("。。") { text = text.replacingOccurrences(of: "。。", with: "。") }
        for (pattern, word) in fixes {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: word)
        }
        return text
    }

    /// 热词之外的兜底纠正（和电脑端 voice.FIXES 一致）：英文产品名常被听成发音相近的词，在这个场景里几乎不会是本意。
    /// 边界只看英文字母（中英文挨着写时 \b 不起作用）
    static let fixes: [(NSRegularExpression, String)] = [
        ("(?<!google )(?<!google)(?:cloud|clod|claud)\\s*code", "Claude Code"),   // Google Cloud Code 是真有的东西
        ("克劳德\\s*code", "Claude Code"),
        ("kite?\\s*line", "Kiteline"),
        ("vs\\s*code", "VS Code"),
    ].compactMap { pattern, word in
        (try? NSRegularExpression(pattern: "(?<![A-Za-z])" + pattern + "(?![A-Za-z])", options: .caseInsensitive)).map { ($0, word) }
    }
}
