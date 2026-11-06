import Foundation
import NaturalLanguage
import Observation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 消息翻译：每条消息下面的「翻译」角标点一下，把这条换成目标语言，再点「原文」换回来。
/// 第一次点先弹设置（从什么语言翻成什么语言、用哪个翻译服务），之后每次点直接翻；设置里随时改。
///
/// 翻译服务都不要 Key、不用注册：
/// - 系统翻译（iOS 18 / macOS 15 起，Apple 本机翻译）：在本机翻，消息不出设备；第一次用某种语言系统会提示下载语言包
/// - Google 翻译（免费网页接口）：质量好，大陆网络可能连不上
/// - MyMemory（公开免费接口，每天约 5000 字）
/// 「自动」按 系统翻译 → Google → MyMemory 的顺序，前一个不可用就换下一个。
///
/// 只翻文字：代码块原样保留，行内代码、链接换成占位符翻完再放回去，列表、标题、引用的前缀不动。
@MainActor @Observable
final class Translator {
    static let shared = Translator()

    // MARK: 设置

    enum Engine: String, CaseIterable, Identifiable {
        case auto, apple, google, mymemory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return L("自动")
            case .apple: return L("系统翻译")
            case .google: return L("Google 翻译")
            case .mymemory: return "MyMemory"
            }
        }
        var note: String {
            switch self {
            case .auto: return L("已下载语言包时使用系统翻译（在本机完成），否则依次改用 Google 翻译、MyMemory")
            case .apple: return L("在本机完成翻译，消息不离开设备，下载语言包后可离线使用")
            case .google: return L("翻译质量较好；部分网络环境下可能无法连接")
            case .mymemory: return L("公开免费接口，每天可翻译约 5000 字")
            }
        }
        /// 面板里名字旁边的小标签
        var tag: String? {
            switch self {
            case .auto: return nil
            case .apple: return L("本机")
            case .google, .mymemory: return L("联网")
            }
        }
        /// 这台设备上能不能用（系统翻译要 iOS 18 / macOS 15）
        static var appleAvailable: Bool {
            if #available(iOS 18, macOS 15, *) { return true }
            return false
        }
        static var choices: [Engine] { appleAvailable ? allCases : allCases.filter { $0 != .apple } }
    }

    /// 语言：code 用 BCP 47（zh-Hans 这种），各家接口用的写法在下面换
    struct Language: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
        static let auto = Language(code: "auto", name: L("自动检测"))
        static let all: [Language] = [
            .init(code: "zh-Hans", name: L("简体中文")), .init(code: "zh-Hant", name: L("繁体中文")),
            .init(code: "en", name: L("英语")), .init(code: "ja", name: L("日语")), .init(code: "ko", name: L("韩语")),
            .init(code: "fr", name: L("法语")), .init(code: "de", name: L("德语")), .init(code: "es", name: L("西班牙语")),
            .init(code: "pt", name: L("葡萄牙语")), .init(code: "it", name: L("意大利语")), .init(code: "ru", name: L("俄语")),
            .init(code: "ar", name: L("阿拉伯语")), .init(code: "vi", name: L("越南语")), .init(code: "th", name: L("泰语")),
            .init(code: "id", name: L("印尼语")), .init(code: "tr", name: L("土耳其语")), .init(code: "nl", name: L("荷兰语")),
            .init(code: "pl", name: L("波兰语")), .init(code: "uk", name: L("乌克兰语")), .init(code: "hi", name: L("印地语")),
        ]
        static func name(_ code: String) -> String {
            code == "auto" ? auto.name : (all.first { $0.code == code }?.name ?? code)
        }
    }

    private enum Key {
        static let source = "translate.source", target = "translate.target", engine = "translate.engine"
        static let configured = "translate.configured", badge = "translate.badge", auto = "translate.auto"
    }
    /// Mac 上换成 App 的偏好（测试实例是隔离的那份，见 KitelineKit.useTranslatorDefaults），iPhone 用标准的
    @ObservationIgnored private var defaults = UserDefaults.standard

    var source: String { didSet { defaults.set(source, forKey: Key.source); cache.removeAll() } }
    var target: String { didSet { defaults.set(target, forKey: Key.target); cache.removeAll() } }
    var engine: Engine { didSet { defaults.set(engine.rawValue, forKey: Key.engine); cache.removeAll() } }
    /// 设过一次（第一次点角标弹的设置点了「翻译」）：之后点角标直接翻
    var configured: Bool { didSet { defaults.set(configured, forKey: Key.configured) } }
    /// 每条消息下面显示「翻译」角标（默认开；关了长按 / 右键菜单里照样有「翻译」）
    var showBadge: Bool { didSet { defaults.set(showBadge, forKey: Key.badge) } }
    /// 自动翻译：助手的回复出现在屏幕上时自动翻（和目标语言相同的不翻；点过「原文」的、翻失败的不再自动翻）
    var auto: Bool { didSet { defaults.set(auto, forKey: Key.auto); if auto { configured = true } } }

    var summary: String {
        "\(Language.name(source)) → \(Language.name(target)) · \(engine.title)"
    }

    func use(_ store: UserDefaults) {
        defaults = store
        source = store.string(forKey: Key.source) ?? "auto"
        target = store.string(forKey: Key.target) ?? (Lang.shared.isEnglish ? "en" : "zh-Hans")
        engine = store.string(forKey: Key.engine).flatMap(Engine.init(rawValue:)) ?? .auto
        configured = store.bool(forKey: Key.configured)
        showBadge = store.object(forKey: Key.badge) as? Bool ?? true
        auto = store.bool(forKey: Key.auto)
        if engine == .apple && !Engine.appleAvailable { engine = .auto }
    }

    private init() {
        source = defaults.string(forKey: Key.source) ?? "auto"
        target = defaults.string(forKey: Key.target) ?? (Lang.shared.isEnglish ? "en" : "zh-Hans")
        engine = defaults.string(forKey: Key.engine).flatMap(Engine.init(rawValue:)) ?? .auto
        configured = defaults.bool(forKey: Key.configured)
        showBadge = defaults.object(forKey: Key.badge) as? Bool ?? true
        auto = defaults.bool(forKey: Key.auto)
        if engine == .apple && !Engine.appleAvailable { engine = .auto }
    }

    // MARK: 每条消息的状态

    enum State: Equatable {
        case working
        case done(String)
        case failed(String)
    }
    /// 消息 id → 状态。只有点过翻译的才有
    private(set) var states: [String: State] = [:]
    /// 翻译好了、但切回了原文的
    private(set) var showingOriginal: Set<String> = []
    /// 第一次点角标：弹设置，确认后翻这一条
    var askingFor: (id: String, text: String)?
    /// 原文 + 语言 + 服务 → 译文（同一句不重复翻；改了设置清空）
    private var cache: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    /// 气泡里该显示的文字：翻译好且没切回原文时是译文，否则 nil（照常显示原文）
    func shown(_ id: String) -> String? {
        guard case .done(let text) = states[id], !showingOriginal.contains(id) else { return nil }
        return text
    }
    func state(_ id: String) -> State? { states[id] }

    /// 自测用：每条翻译试过哪些服务、为什么换下一个
    @ObservationIgnored private var notes: [String: [String]] = [:]

    /// 自测用（KitelineKit.translateStates）
    var debugStates: String {
        let trail = notes.map { "\($0.key)[\($0.value.joined(separator: "; "))]" }.sorted().joined(separator: " ")
        return trail + " || " + statesText
    }

    private var statesText: String {
        states.map { id, state in
            switch state {
            case .working: return "\(id)=working"
            case .done(let text): return "\(id)=\(showingOriginal.contains(id) ? "original" : "done"):\(text.prefix(80))"
            case .failed(let message): return "\(id)=failed:\(message)"
            }
        }.sorted().joined(separator: " | ")
    }
    func isTranslated(_ id: String) -> Bool { shown(id) != nil }

    /// 角标 / 菜单「翻译」：没设过先问；翻好了的切回译文；没翻过就翻
    func tap(_ id: String, text: String) {
        if !configured { askingFor = (id, text); return }
        if case .done = states[id] {
            if showingOriginal.contains(id) { showingOriginal.remove(id) } else { showingOriginal.insert(id) }
            return
        }
        if states[id] == .working { return }
        translate(id, text: text)
    }

    /// 还原成原文
    func restore(_ id: String) {
        if case .done = states[id] { showingOriginal.insert(id) } else { cancel(id) }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
        failApple(id, CancellationError())
        states[id] = nil
    }

    /// 设置弹窗里点「翻译」：记下设过了，翻刚才那条
    func confirmAsk() {
        configured = true
        guard let ask = askingFor else { return }
        askingFor = nil
        states[ask.id] = nil; showingOriginal.remove(ask.id)
        translate(ask.id, text: ask.text)
    }

    /// 改了设置后重新翻这一条（翻好的那条旁边「设置」改完直接重翻）
    func retranslate(_ id: String, text: String) {
        cancel(id); showingOriginal.remove(id)
        translate(id, text: text)
    }

    /// 认过语言、和目标相同不用翻的（自动翻译不再反复认）
    @ObservationIgnored private var sameAsTarget: Set<String> = []
    /// 自动翻译同时最多跑 3 条（一屏十几条回复同时请求，联网服务会被限流）
    @ObservationIgnored private let autoGate = TranslateGate(3)

    /// 自动翻译：消息出现在屏幕上时调用。只翻和目标语言不同的；翻过、正在翻、点过「原文」、失败过的都不动
    func autoTranslate(_ id: String, text: String) {
        guard auto, configured, states[id] == nil, !showingOriginal.contains(id), !sameAsTarget.contains(id) else { return }
        let sample = TranslateDoc(text).pieces.joined(separator: "\n")
        guard !sample.isEmpty else { return }
        if source != "auto" ? Self.sameLanguage(source, target) : (Self.detect(sample).map { Self.sameLanguage($0, target) } ?? true) {
            sameAsTarget.insert(id); return
        }
        translate(id, text: text, gated: true)
    }

    func translate(_ id: String, text: String, gated: Bool = false) {
        let cacheKey = "\(engine.rawValue)|\(source)|\(target)|\(text)"
        if let hit = cache[cacheKey] { states[id] = .done(hit); showingOriginal.remove(id); return }
        states[id] = .working
        showingOriginal.remove(id)
        let doc = TranslateDoc(text)
        guard !doc.pieces.isEmpty else { states[id] = .done(text); return }
        let order: [Engine]
        switch engine {
        case .auto: order = (Engine.appleAvailable ? [.apple] : []) + [.google, .mymemory]
        default: order = [engine]
        }
        let source = source, target = target
        let gate = gated ? autoGate : nil
        tasks[id] = Task { [weak self] in
            await gate?.wait()
            defer { Task { await gate?.signal() } }
            var lastError = L("翻译失败")
            for engine in order {
                guard let self, !Task.isCancelled else { return }
                do {
                    let out: [String]
                    switch engine {
                    case .apple: out = try await self.runApple(id: id, pieces: doc.pieces, source: source, target: target,
                                                               sample: doc.pieces.joined(separator: "\n"), mayDownload: order.count == 1)
                    case .google: out = try await Self.google(doc.pieces, source: source, target: target)
                    case .mymemory: out = try await Self.myMemory(doc.pieces, source: source, target: target)
                    case .auto: continue
                    }
                    guard !Task.isCancelled else { return }
                    let result = doc.rebuild(out)
                    self.cache[cacheKey] = result
                    self.states[id] = .done(result)
                    self.notes[id, default: []].append("用 \(engine.rawValue)")
                    self.tasks[id] = nil
                    return
                } catch {
                    lastError = (error as? TranslateError)?.message ?? error.localizedDescription
                    self.notes[id, default: []].append("\(engine.rawValue):\(lastError)")
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.states[id] = .failed(lastError)
            self.tasks[id] = nil
        }
    }

    // MARK: 系统翻译（要挂在视图上：TranslationSession 只能从 .translationTask 拿到）

    struct AppleJob {
        let token: UUID
        let pieces: [String]
        let source: String, target: String
        var continuation: CheckedContinuation<[String], Error>?
        /// TranslationSession.Configuration（系统版本不够时这个类型不存在，只能放成 Any）
        var config: Any?
    }
    private(set) var appleJobs: [String: AppleJob] = [:]

    private func failApple(_ id: String, _ error: Error) {
        guard let continuation = appleJobs[id]?.continuation else { return }
        appleJobs[id] = nil
        continuation.resume(throwing: error)
    }

    /// mayDownload：用户明确选了「系统翻译」，语言包没下载时让系统弹下载提示；「自动」时没下载就直接换下一个服务，不打扰
    private func runApple(id: String, pieces: [String], source: String, target: String, sample: String, mayDownload: Bool) async throws -> [String] {
        guard #available(iOS 18, macOS 15, *) else { throw TranslateError(L("此系统不支持系统翻译")) }
        #if canImport(Translation)
        let languages = LanguageAvailability()
        let to = Locale.Language(identifier: target)
        // 原文「自动检测」：自己先按整条消息认出语言再明确告诉系统。交给系统逐段认（source 传 nil）时，
        // 表格的格子、「16px」这种短段认不出来，整批报「无法翻译」（11-05 实测）
        let sourceCode = source == "auto" ? Self.detect(sample) : source
        guard let sourceCode else { throw TranslateError(L("无法识别原文语言")) }
        if Self.sameLanguage(sourceCode, target) { return pieces }
        let from = Locale.Language(identifier: sourceCode)
        let status = await languages.status(from: from, to: to)
        if status == .unsupported { throw TranslateError(L("系统翻译不支持这组语言")) }
        if status == .supported && !mayDownload { throw TranslateError(L("系统翻译尚未下载这组语言")) }
        // 消息气泡不在屏幕上（滚走了、换了会话）时视图上的 .translationTask 不会跑：20 秒没开始就换下一个服务
        let token = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            var job = AppleJob(token: token, pieces: pieces, source: source, target: target, continuation: continuation)
            job.config = TranslationSession.Configuration(source: from, target: to)
            appleJobs[id] = job
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.appleJobs[id]?.token == token else { return }
                self.failApple(id, TranslateError(L("系统翻译没有响应")))
            }
        }
        #else
        throw TranslateError(L("此系统不支持系统翻译"))
        #endif
    }

    /// 整条消息的主要语言（BCP 47：zh-Hans / zh-Hant / en / ja……），认不出来是 nil
    nonisolated static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        switch language {
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        default: return language.rawValue
        }
    }

    /// 原文和目标是不是同一种语言（zh-Hans 和 zh-Hant 算不同）
    nonisolated static func sameLanguage(_ a: String, _ b: String) -> Bool {
        if a.hasPrefix("zh") || b.hasPrefix("zh") { return a == b }
        return a.split(separator: "-").first == b.split(separator: "-").first
    }

    #if canImport(Translation)
    @available(iOS 18, macOS 15, *)
    func appleConfig(_ id: String) -> TranslationSession.Configuration? {
        appleJobs[id]?.config as? TranslationSession.Configuration
    }

    @available(iOS 18, macOS 15, *)
    func performApple(_ id: String, session: TranslationSession) async {
        guard var job = appleJobs[id], let continuation = job.continuation else { return }
        // 先摘掉续体（超时不再算它），配置留着：配置变成 nil 时系统会取消正在跑的翻译，翻完再清
        job.continuation = nil
        appleJobs[id] = job
        defer { if appleJobs[id]?.token == job.token { appleJobs[id] = nil } }
        do {
            try await session.prepareTranslation()
            let requests = job.pieces.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            let responses = try await session.translations(from: requests)
            var out = job.pieces
            for response in responses {
                if let index = response.clientIdentifier.flatMap(Int.init), out.indices.contains(index) { out[index] = response.targetText }
            }
            continuation.resume(returning: out)
        } catch {
            continuation.resume(throwing: TranslateError(L("系统翻译不可用：%@", error.localizedDescription) + " (\(error))"))
        }
    }
    #endif

    // MARK: Google 翻译（translate.googleapis.com 的免费网页接口）

    nonisolated static func googleCode(_ code: String) -> String {
        switch code { case "zh-Hans": return "zh-CN"; case "zh-Hant": return "zh-TW"; default: return code }
    }

    nonisolated static func google(_ pieces: [String], source: String, target: String) async throws -> [String] {
        // 多段合成一次请求（一段一行），每次不超过约 3000 字；回来按行拆，行数对不上就逐段再翻
        var out: [String] = []
        var batch: [String] = []
        var size = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            let joined = try await googleOne(batch.joined(separator: "\n"), source: source, target: target)
            let lines = joined.components(separatedBy: "\n")
            if lines.count == batch.count {
                out += lines
            } else {
                for piece in batch { out.append(try await googleOne(piece, source: source, target: target)) }
            }
            batch = []; size = 0
        }
        for piece in pieces {
            if size + piece.count > 3000 { try await flush() }
            batch.append(piece.replacingOccurrences(of: "\n", with: " ")); size += piece.count + 1
        }
        try await flush()
        return out
    }

    private nonisolated static func googleOne(_ text: String, source: String, target: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&dt=t&sl=\(googleCode(source))&tl=\(googleCode(target))")!,
                                 timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = "q=\(formEscape(text))".data(using: .utf8)
        let data: Data
        do { data = try await URLSession.shared.data(for: request).0 } catch { throw TranslateError(L("连不上 Google 翻译")) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], let parts = json.first as? [Any] else {
            throw TranslateError(L("Google 翻译返回了无法识别的内容"))
        }
        return parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }

    // MARK: MyMemory（api.mymemory.translated.net，公开免费接口；每次最多 500 字节，按句子切）

    nonisolated static func myMemoryCode(_ code: String) -> String {
        switch code { case "auto": return "autodetect"; case "zh-Hans": return "zh-CN"; case "zh-Hant": return "zh-TW"; default: return code }
    }

    nonisolated static func myMemory(_ pieces: [String], source: String, target: String) async throws -> [String] {
        // 每块一个请求，最多同时 4 个（长消息逐个请求要十几秒）
        let jobs = pieces.enumerated().flatMap { index, piece in TranslateDoc.chunks(piece, maxBytes: 450).enumerated().map { (index, $0.offset, $0.element) } }
        var results: [Int: [Int: String]] = [:]
        try await withThrowingTaskGroup(of: (Int, Int, String).self) { group in
            var next = 0
            func add() {
                guard next < jobs.count else { return }
                let job = jobs[next]; next += 1
                group.addTask { (job.0, job.1, try await myMemoryOne(job.2, source: source, target: target)) }
            }
            for _ in 0..<4 { add() }
            while let (piece, part, text) = try await group.next() {
                results[piece, default: [:]][part] = text
                add()
            }
        }
        return pieces.indices.map { index in (results[index] ?? [:]).sorted { $0.key < $1.key }.map(\.value).joined(separator: " ") }
    }

    private nonisolated static func myMemoryOne(_ text: String, source: String, target: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.mymemory.translated.net/get")!, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = "q=\(formEscape(text))&langpair=\(myMemoryCode(source))|\(myMemoryCode(target))".data(using: .utf8)
        let data: Data
        do { data = try await URLSession.shared.data(for: request).0 } catch { throw TranslateError(L("连不上 MyMemory")) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranslateError(L("MyMemory 返回了无法识别的内容")) }
        if json["quotaFinished"] as? Bool == true { throw TranslateError(L("MyMemory 今日免费额度已用完")) }
        // 自动检测出来和目标语言相同（「16px」这种被认成英文）：原样保留
        if (json["responseDetails"] as? String)?.localizedCaseInsensitiveContains("DISTINCT LANGUAGES") == true { return text }
        guard let reply = json["responseData"] as? [String: Any], let text = reply["translatedText"] as? String,
              (json["responseStatus"] as? Int ?? Int(json["responseStatus"] as? String ?? "") ?? 200) == 200 else {
            throw TranslateError((json["responseDetails"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("MyMemory 翻译失败"))
        }
        return text
    }

    private nonisolated static func formEscape(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// 简单的计数闸门：同时最多 n 个
actor TranslateGate {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ count: Int) { free = count }
    func wait() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

struct TranslateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 把一条消息拆成「要翻的段」和「原样留着的」：代码块、空行、表格分隔行不翻；
/// 每行开头的列表 / 标题 / 引用符号留着，行内代码、链接、网址换成 {{n}} 占位符，翻完放回去
struct TranslateDoc {
    private enum Line {
        case keep(String)
        case prose(prefix: String, piece: Int, tokens: [String])
        /// 表格的一行：每格单独翻（整行一起翻会把格子挪位、吞掉格子）
        case cells([Line])
    }
    private var lines: [Line] = []
    private(set) var pieces: [String] = []

    init(_ text: String) {
        var inFence = false
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); lines.append(.keep(raw)); continue }
            if inFence || trimmed.isEmpty || Self.isTableRule(trimmed) || raw.hasPrefix("    ") || raw.hasPrefix("\t") {
                lines.append(.keep(raw)); continue
            }
            if trimmed.hasPrefix("|") {
                lines.append(.cells(raw.components(separatedBy: "|").map { cell($0, prefix: "") }))
                continue
            }
            let (prefix, body) = Self.splitPrefix(raw)
            lines.append(cell(body, prefix: prefix, raw: raw))
        }
    }

    /// 一段（一行或表格的一格）：前后空白留着，中间要翻的记成一段
    private mutating func cell(_ body: String, prefix: String, raw: String? = nil) -> Line {
        let core = body.trimmingCharacters(in: .whitespaces)
        let (masked, tokens) = Self.mask(core)
        // 只剩占位符和符号（整行就是一个路径、一段代码、一个数字）：不用翻
        if masked.replacingOccurrences(of: #"\{\{\d+\}\}"#, with: "", options: .regularExpression)
            .unicodeScalars.allSatisfy({ !CharacterSet.letters.contains($0) }) {
            return .keep(raw ?? prefix + body)
        }
        let lead = String(body.prefix { $0 == " " }), trail = String(body.reversed().prefix { $0 == " " })
        pieces.append(masked)
        return .prose(prefix: prefix + lead + "\u{1}" + trail, piece: pieces.count - 1, tokens: tokens)
    }

    func rebuild(_ translated: [String]) -> String {
        lines.map { render($0, translated) }.joined(separator: "\n")
    }

    private func render(_ line: Line, _ translated: [String]) -> String {
            switch line {
            case .keep(let raw): return raw
            case .cells(let cells): return cells.map { render($0, translated) }.joined(separator: "|")
            case .prose(let prefix, let piece, let tokens):
                var text = Self.tidy(translated.indices.contains(piece) ? translated[piece] : pieces[piece])
                for (index, token) in tokens.enumerated().reversed() {
                    // 有的服务会在括号里加空格：{{ 0 }}、{ {0} }
                    let pattern = #"\{\s*\{\s*"# + String(index) + #"\s*\}\s*\}"#
                    if let range = text.range(of: pattern, options: .regularExpression) {
                        text.replaceSubrange(range, with: token)
                    } else {
                        text += " " + token
                    }
                }
                // prefix 里 \u{1} 隔开前面的符号、缩进和后面的空白
                let parts = prefix.components(separatedBy: "\u{1}")
                return parts[0] + text + (parts.count > 1 ? parts[1] : "")
            }
    }

    /// 翻译服务常把 Markdown 符号拆开：「* * 粗体 * *」「** 粗体 **」→「**粗体**」
    static func tidy(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\*\s+\*"#, with: "**", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\*\*\s+([^*]+?)\s+\*\*"#, with: "**$1**", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isTableRule(_ line: String) -> Bool {
        line.hasPrefix("|") && line.allSatisfy { "|-: ".contains($0) }
    }

    /// 行首的缩进 + 列表 / 标题 / 引用 / 任务框符号
    private static func splitPrefix(_ line: String) -> (String, String) {
        let pattern = #"^\s*(?:>\s*)*(?:#{1,6}\s+|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)?"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return ("", line) }
        return (String(line[range]), String(line[range.upperBound...]))
    }

    /// 行内代码、Markdown 链接的地址部分、网址 → {{n}}
    private static func mask(_ text: String) -> (String, [String]) {
        var tokens: [String] = []
        var out = text
        // 最后一个：数字 + 单位（4px、200ms、1.5GB、80%）原样留着，系统翻译会把 px 翻成「像素」
        for pattern in [#"`[^`]+`"#, #"\]\([^)\s]+\)"#, #"https?://[^\s)>\]]+"#,
                        #"\b\d+(?:\.\d+)?(?:px|pt|em|rem|vh|vw|ms|s|KB|MB|GB|TB|k|K|M|x)\b|\d+(?:\.\d+)?%"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            var pieces: [String] = []
            var last = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                pieces.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
                let token = ns.substring(with: match.range)
                if token.hasPrefix("](") {
                    pieces.append("](" + "{{\(tokens.count)}}" + ")")
                    tokens.append(String(token.dropFirst(2).dropLast()))
                } else {
                    pieces.append("{{\(tokens.count)}}")
                    tokens.append(token)
                }
                last = match.range.location + match.range.length
            }
            pieces.append(ns.substring(from: last))
            out = pieces.joined()
        }
        return (out, tokens)
    }

    /// 按句子切成每块不超过 maxBytes（UTF-8）
    static func chunks(_ text: String, maxBytes: Int) -> [String] {
        guard text.utf8.count > maxBytes else { return [text] }
        var out: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            if current.utf8.count + sentence.utf8.count > maxBytes, !current.isEmpty { out.append(current); current = "" }
            if sentence.utf8.count > maxBytes {
                // 一句就超长：按字硬切
                var piece = ""
                for character in sentence {
                    if piece.utf8.count + String(character).utf8.count > maxBytes { out.append(piece); piece = "" }
                    piece.append(character)
                }
                current = piece
            } else {
                current += sentence
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
