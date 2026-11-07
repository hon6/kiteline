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
        case auto, computer, apple, google, mymemory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return L("自动")
            case .computer: return L("电脑翻译")
            case .apple: return L("系统翻译")
            case .google: return L("Google 翻译")
            case .mymemory: return "MyMemory"
            }
        }
        var note: String {
            switch self {
            case .auto: return L("先交给连着的电脑翻译，再依次尝试本机系统翻译、Google 翻译、MyMemory")
            case .computer: return L("交给连着的电脑翻译：Mac 使用系统翻译在电脑上完成，其他电脑联网翻译")
            case .apple: return L("在本机完成翻译，消息不离开设备，下载语言包后可离线使用")
            case .google: return L("翻译质量较好；部分网络环境下无法连接，连不上时自动改用其他服务")
            case .mymemory: return L("公开免费接口，每天可翻译约 5000 字")
            }
        }
        /// 面板里名字旁边的小标签
        var tag: String? {
            switch self {
            case .auto: return nil
            case .computer: return L("电脑")
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
        // 选了联网服务时，连不上 / 被限流 / 额度用完就换别的（11-07 手机选了 Google，大陆网络连不上，条条失败）：
        // 先换本机系统翻译（只在语言包已下载时，不弹下载），再换另一个联网服务。只选「系统翻译」的不换（消息不出设备）
        // 11-07 起先交给连着的电脑翻（消息本来就是电脑发来的；Mac 用系统翻译在电脑上完成，手机上的系统翻译 iOS 18 真机报 internalError、
        // Google 大陆连不上）。只选「系统翻译」的也可以交给电脑，但只许电脑在本机翻（local），不许它联网
        let apple: [Engine] = Engine.appleAvailable ? [.apple] : []
        let host: [Engine] = hostTranslate != nil ? [.computer] : []
        var order: [Engine]
        switch engine {
        case .auto, .computer: order = host + apple + [.google, .mymemory]
        case .apple: order = apple + host
        case .google: order = [.google] + host + apple + [.mymemory]
        case .mymemory: order = [.mymemory] + host + apple + [.google]
        }
        // 最近连不上的联网服务先跳过（每条都白等 10 秒超时）；全被跳过时照常都试
        let now = Date()
        let live = order.filter { (Self.downUntil[$0] ?? .distantPast) < now }
        if !live.isEmpty { order = live }
        let chosen = engine
        let source = source, target = target
        let gate = gated ? autoGate : nil
        tasks[id] = Task { [weak self] in
            await gate?.wait()
            defer { Task { await gate?.signal() } }
            var lastError = L("翻译失败")
            for engine in order {
                guard let self, !Task.isCancelled else { return }
                do {
                    if engine == .computer, let host = self.hostTranslate {
                        let result = try await host(text, source, target, chosen == .apple)
                        guard !Task.isCancelled else { return }
                        self.cache[cacheKey] = result
                        self.states[id] = .done(result)
                        self.notes[id, default: []].append("用 computer")
                        self.tasks[id] = nil
                        return
                    }
                    let out: [String]
                    switch engine {
                    // 自动翻译从不弹系统的下载语言包窗口（11-07 用户报电脑上时不时弹「下载语言以翻译」）：只有手动点「翻译」才弹
                    case .apple: out = try await self.runApple(id: id, pieces: doc.pieces, source: source, target: target,
                                                               sample: doc.pieces.joined(separator: "\n"), mayDownload: chosen == .apple && !gated)
                    case .google: out = try await Self.google(doc.pieces, source: source, target: target)
                    case .mymemory: out = try await Self.myMemory(doc.pieces, source: source, target: target)
                    case .auto, .computer: continue
                    }
                    guard !Task.isCancelled else { return }
                    let result = doc.rebuild(out)
                    self.cache[cacheKey] = result
                    self.states[id] = .done(result)
                    self.notes[id, default: []].append("用 \(engine.rawValue)")
                    self.tasks[id] = nil
                    return
                } catch let error as TranslateError where gated && error.skip {
                    // 自动翻译被打断（气泡滚出屏幕、换了会话）或语言包没下载：不算失败、不标红，
                    // 回到没翻过的样子，下次出现在屏幕上再自动翻（11-07 用户报手机上翻译经常显示失败）
                    guard !Task.isCancelled else { return }
                    self.notes[id, default: []].append("\(engine.rawValue):\(error.message)，稍后再自动翻")
                    self.states[id] = nil
                    self.tasks[id] = nil
                    return
                } catch {
                    lastError = (error as? TranslateError)?.message ?? error.localizedDescription
                    if let pause = (error as? TranslateError)?.pause { Self.downUntil[engine] = Date().addingTimeInterval(pause) }
                    self.notes[id, default: []].append("\(engine.rawValue):\(lastError)")
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.states[id] = .failed(lastError)
            self.tasks[id] = nil
        }
    }

    /// 交给连着的电脑翻（POST /api/translate，电脑有 translate 功能时 AppModel 填上）：(原文, 原文语言, 目标语言, 只许本机翻) → 译文
    @ObservationIgnored var hostTranslate: ((String, String, String, Bool) async throws -> String)?

    /// 联网服务连不上 / 被限流 / 额度用完后暂停到什么时候（期间先用别的服务）
    private static var downUntil: [Engine: Date] = [:]

    // MARK: 系统翻译（整个 App 一个常驻会话）
    //
    // TranslationSession 只能从视图的 .translationTask 拿到。原来每个消息气泡各挂一个，iOS 18 上条条报
    // TranslationError.internalError（11-07 用户 iPhone 语言包已下载仍「重试」），气泡滚出屏幕还会中断。
    // 现在根视图挂一个看不见的 TranslateAppleHost，要翻的消息排队交给它：同一组语言连着翻，换语言时换配置。

    struct AppleJob {
        let id: String
        let token: UUID
        let pieces: [String]
        let from: String, to: String
        let continuation: CheckedContinuation<[String], Error>
        /// 语言包已下载：不再调 prepareTranslation（只在要下载时才需要）
        let installed: Bool
    }
    @ObservationIgnored private var appleQueue: [AppleJob] = []
    @ObservationIgnored private var appleBusy = false
    /// 常驻宿主当前的配置（TranslationSession.Configuration；系统版本不够时这个类型不存在，只能放成 Any）和它的语言
    private(set) var appleConfig: Any?
    @ObservationIgnored private var appleLangs: (from: String, to: String)?
    /// 挂着的宿主（多个窗口各有一个），只有第一个真正干活
    private(set) var appleHosts: [UUID] = []
    @ObservationIgnored private var kickToken = UUID()

    func hostAppeared(_ host: UUID) { if !appleHosts.contains(host) { appleHosts.append(host) }; kickApple() }
    func hostGone(_ host: UUID) { appleHosts.removeAll { $0 == host }; if !appleHosts.isEmpty { kickApple() } }

    private func failApple(_ id: String, _ error: Error) {
        let gone = appleQueue.filter { $0.id == id }
        appleQueue.removeAll { $0.id == id }
        gone.forEach { $0.continuation.resume(throwing: error) }
    }

    /// 让宿主开始翻排在最前面的：语言和当前配置一样就让配置失效（系统会重跑 .translationTask），否则换新配置
    private func kickApple() {
        guard #available(iOS 18, macOS 15, *) else { return }
        #if canImport(Translation)
        guard !appleBusy, let next = appleQueue.first, !appleHosts.isEmpty else { return }
        if var config = appleConfig as? TranslationSession.Configuration, appleLangs?.from == next.from, appleLangs?.to == next.to {
            config.invalidate()
            appleConfig = config
        } else {
            appleConfig = TranslationSession.Configuration(source: next.from.isEmpty ? nil : Locale.Language(identifier: next.from),
                                                           target: Locale.Language(identifier: next.to))
            appleLangs = (next.from, next.to)
        }
        // 15 秒还没开始（宿主不在窗口里、系统没响应）：排着的都放弃，交给下一个服务 / 下次再自动翻
        let token = UUID()
        kickToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.kickToken == token, !self.appleBusy else { return }
            let stuck = self.appleQueue
            self.appleQueue = []
            stuck.forEach { $0.continuation.resume(throwing: TranslateError(L("系统翻译没有响应"), skip: true)) }
        }
        #endif
    }

    #if DEBUG && os(iOS)
    /// 调试：在真机上试几种语言写法 / 是否先 prepare，看哪种系统翻译能翻（DebugRemote 的 trprobe）
    func probeApple() async {
        guard #available(iOS 18, *) else { return }
        #if canImport(Translation)
        let supported = await LanguageAvailability().supportedLanguages
        DebugRemote.note("probe 支持：" + supported.map { $0.maximalIdentifier }.joined(separator: ","))
        let cases: [(String, String, Bool)] = [("en", "zh-Hans", true), ("en", "zh-Hans", false), ("en-US", "zh-Hans-CN", true),
                                               ("en", "zh", true), ("", "zh-Hans", true)]
        for c in cases {
            let st = await LanguageAvailability().status(from: Locale.Language(identifier: c.0.isEmpty ? "en" : c.0), to: Locale.Language(identifier: c.1))
            do {
                let out = try await withCheckedThrowingContinuation { (k: CheckedContinuation<[String], Error>) in
                    appleQueue.append(AppleJob(id: "probe", token: UUID(), pieces: ["Hello, how are you today?"], from: c.0, to: c.1, continuation: k, installed: c.2))
                    kickApple()
                }
                DebugRemote.note("probe \(c) status=\(st)：成功 \(out)")
            } catch {
                DebugRemote.note("probe \(c) status=\(st)：失败 \((error as? TranslateError)?.message ?? "\(error)")")
            }
        }
        #endif
    }
    #endif

    /// mayDownload：用户明确选了「系统翻译」，语言包没下载时让系统弹下载提示；「自动」时没下载就直接换下一个服务，不打扰
    private func runApple(id: String, pieces: [String], source: String, target: String, sample: String, mayDownload: Bool) async throws -> [String] {
        guard #available(iOS 18, macOS 15, *) else { throw TranslateError(L("此系统不支持系统翻译")) }
        #if canImport(Translation)
        guard !appleHosts.isEmpty else { throw TranslateError(L("系统翻译没有响应"), skip: true) }
        let languages = LanguageAvailability()
        let to = Locale.Language(identifier: target)
        // 原文「自动检测」：自己先按整条消息认出语言再明确告诉系统。交给系统逐段认（source 传 nil）时，
        // 表格的格子、「16px」这种短段认不出来，整批报「无法翻译」（11-05 实测）
        let sourceCode = source == "auto" ? Self.detect(sample) : source
        guard let sourceCode else { throw TranslateError(L("无法识别原文语言")) }
        if Self.sameLanguage(sourceCode, target) { return pieces }
        let status = await languages.status(from: Locale.Language(identifier: sourceCode), to: to)
        if status == .unsupported { throw TranslateError(L("系统翻译不支持这组语言")) }
        // 用户明确选了系统翻译时，没下载语言包的自动翻译先跳过（不标失败），手动点一次「翻译」弹系统下载窗口
        if status == .supported && !mayDownload { throw TranslateError(L("系统翻译尚未下载这组语言"), skip: engine == .apple) }
        return try await withCheckedThrowingContinuation { continuation in
            appleQueue.append(AppleJob(id: id, token: UUID(), pieces: pieces, from: sourceCode, to: target,
                                       continuation: continuation, installed: status == .installed))
            kickApple()
        }
        #else
        throw TranslateError(L("此系统不支持系统翻译"))
        #endif
    }

    /// 整条消息的主要语言（BCP 47：zh-Hans / zh-Hant / en / ja……），认不出来是 nil
    /// 技术内容（命令、文件名、缩写多的英文）常被认成法语、德语等（11-07 电脑上因此弹了「下载法语」）：
    /// 给英语、中文较高的先验；认出来是别的拉丁字母语言但把握不大、英语也有一定可能时按英语算
    nonisolated static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageHints = [.english: 0.5, .simplifiedChinese: 0.25, .traditionalChinese: 0.05, .japanese: 0.05, .korean: 0.03,
                                    .french: 0.02, .german: 0.02, .spanish: 0.02, .russian: 0.02, .portuguese: 0.01, .italian: 0.01]
        recognizer.processString(text)
        guard var language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let latin: Set<NLLanguage> = [.french, .german, .spanish, .portuguese, .italian, .dutch, .catalan, .romanian, .swedish,
                                      .danish, .norwegian, .finnish, .polish, .czech, .slovak, .hungarian, .croatian, .indonesian,
                                      .malay, .turkish, .vietnamese]
        if latin.contains(language) {
            let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
            if (hypotheses[language] ?? 0) < 0.9, (hypotheses[.english] ?? 0) > 0.05 { language = .english }
        }
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
    /// 宿主拿到会话：把排着的、语言和这个会话一样的都翻完；还有别的语言的就换配置再来
    @available(iOS 18, macOS 15, *)
    func performApple(session: TranslationSession) async {
        guard !appleBusy, let langs = appleLangs else { return }
        appleBusy = true
        defer {
            appleBusy = false
            if !Task.isCancelled { kickApple() }
        }
        while let index = appleQueue.firstIndex(where: { $0.from == langs.from && $0.to == langs.to }) {
            let job = appleQueue.remove(at: index)
            if Task.isCancelled {
                job.continuation.resume(throwing: TranslateError(L("系统翻译被打断"), skip: true)); continue
            }
            do {
                job.continuation.resume(returning: try await translateApple(job, session: session))
            } catch {
                if error is CancellationError || Task.isCancelled {
                    job.continuation.resume(throwing: TranslateError(L("系统翻译被打断"), skip: true))
                } else if "\(error)".contains("internalError") {
                    // 11-07 用户 iPhone（iOS 18.7，语言包已下载）上任何写法都瞬间报 internalError：系统翻译在这台设备上用不了。
                    // 一小时内「自动」直接跳过系统翻译
                    job.continuation.resume(throwing: TranslateError(L("系统翻译在这台设备上无法使用，可在翻译设置中改用其他翻译服务"), pause: 3600))
                } else {
                    job.continuation.resume(throwing: TranslateError(L("系统翻译不可用：%@", error.localizedDescription) + " (\(error))"))
                }
            }
        }
    }

    @available(iOS 18, macOS 15, *)
    private func translateApple(_ job: AppleJob, session: TranslationSession) async throws -> [String] {
        if !job.installed { try await session.prepareTranslation() }
        let requests = job.pieces.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        var out = job.pieces
        do {
            for response in try await session.translations(from: requests) {
                if let index = response.clientIdentifier.flatMap(Int.init), out.indices.contains(index) { out[index] = response.targetText }
            }
        } catch let error where !(error is CancellationError) && !Task.isCancelled {
            // 整批报错：逐段翻，个别段翻不了留原文，全部翻不了才算失败
            notes[job.id, default: []].append("apple 整批失败：\(error)，改逐段")
            var failed = 0
            var firstError: Error = error
            for (index, piece) in job.pieces.enumerated() {
                do { out[index] = try await session.translate(piece).targetText } catch {
                    if error is CancellationError || Task.isCancelled { throw error }
                    if failed == 0 { firstError = error }
                    failed += 1
                    notes[job.id, default: []].append("段\(index) 失败：\(error) 「\(piece.prefix(60))」")
                }
            }
            if failed == job.pieces.count { throw firstError }
        }
        return out
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
        do { data = try await URLSession.shared.data(for: request).0 } catch { throw TranslateError(L("连不上 Google 翻译"), pause: 600) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], let parts = json.first as? [Any] else {
            throw TranslateError(L("Google 翻译返回了无法识别的内容"), pause: 600)
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
        do { data = try await URLSession.shared.data(for: request).0 } catch { throw TranslateError(L("连不上 MyMemory"), pause: 600) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranslateError(L("MyMemory 返回了无法识别的内容")) }
        if json["quotaFinished"] as? Bool == true { throw TranslateError(L("MyMemory 今日免费额度已用完"), pause: 3600) }
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

/// 电脑端给手机（微信小程序）翻译用：POST /api/translate（Sources/MobileServer.swift）。
/// 拆段、占位同手机上的翻译（TranslateDoc：代码块、行内代码、网址不翻）；服务按 Google → MyMemory 的顺序，
/// 前一个连不上 / 限流就换下一个。target 不给时：中文翻成英文，其余翻成简体中文。
/// 11-07 起手机 App、电脑客户端也先交给电脑翻：macOS 26 起先用系统翻译在电脑本机翻（TranslationSession(installedSource:) 不用界面，
/// 实测 0.1 秒），语言包没下载才联网；local = 只许本机翻（用户选了「系统翻译」：消息不出设备）
public enum HostTranslate {
    /// 这台电脑能不能只在本机翻（hello / state 的 features 里报 translateLocal）
    public static var localAvailable: Bool {
        #if canImport(Translation)
        if #available(iOS 26, macOS 26, *) { return true }
        #endif
        return false
    }

    public struct Result: Sendable {
        public let text: String
        public let source: String
        public let target: String
        public let engine: String
    }

    public static func run(_ text: String, target: String?, source given: String? = nil, local: Bool = false) async throws -> Result {
        let source = given.flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 } ?? Translator.detect(text) ?? "auto"
        let to = target.flatMap { $0.isEmpty ? nil : $0 } ?? (source.hasPrefix("zh") ? "en" : "zh-Hans")
        if source != "auto", Translator.sameLanguage(source, to) { return Result(text: text, source: source, target: to, engine: "none") }
        let doc = TranslateDoc(text)
        guard !doc.pieces.isEmpty else { return Result(text: text, source: source, target: to, engine: "none") }
        var lastError = "翻译失败"
        #if canImport(Translation)
        if #available(iOS 26, macOS 26, *), source != "auto" {
            let from = Locale.Language(identifier: source), into = Locale.Language(identifier: to)
            if await LanguageAvailability().status(from: from, to: into) == .installed {
                do {
                    let session = TranslationSession(installedSource: from, target: into)
                    let requests = doc.pieces.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                    var out = doc.pieces
                    for response in try await session.translations(from: requests) {
                        if let index = response.clientIdentifier.flatMap(Int.init), out.indices.contains(index) { out[index] = response.targetText }
                    }
                    return Result(text: doc.rebuild(out), source: source, target: to, engine: "apple")
                } catch {
                    lastError = L("电脑上的系统翻译失败：%@", error.localizedDescription)
                }
            } else {
                lastError = L("电脑上的系统翻译尚未下载「%@ → %@」语言包", Translator.Language.name(source), Translator.Language.name(to))
            }
        }
        #endif
        if local { throw NSError(domain: "HostTranslate", code: 2, userInfo: [NSLocalizedDescriptionKey: localAvailable ? lastError : L("这台电脑不能在本机翻译")]) }
        for (name, run) in [("google", Translator.google), ("mymemory", Translator.myMemory)] as [(String, ([String], String, String) async throws -> [String])] {
            do {
                let out = try await run(doc.pieces, source, to)
                return Result(text: doc.rebuild(out), source: source, target: to, engine: name)
            } catch {
                lastError = (error as? TranslateError)?.message ?? error.localizedDescription
            }
        }
        throw NSError(domain: "HostTranslate", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError])
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
    /// 自动翻译遇到时不算失败（被打断 / 语言包没下载），回到没翻过的样子，下次出现再翻
    var skip = false
    /// 联网服务暂时不可用：这么多秒内先用别的服务
    var pause: TimeInterval?
    init(_ message: String, skip: Bool = false, pause: TimeInterval? = nil) { self.message = message; self.skip = skip; self.pause = pause }
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
