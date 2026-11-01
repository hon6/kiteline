import Foundation
import Observation
import SwiftUI

/// 界面语言：跟随系统（系统首选语言是中文 → 简体中文，其余 → English）/ 简体中文 / English。设置里改了马上生效、不用重启。
///
/// 中文是原文：界面上的字照常写中文，英文在 en.lproj/Localizable.strings（由 i18n/en.json 生成，见 tools/i18n.py）。
/// - SwiftUI 里写死的字（Text("会话")、Button("取消")、Text("\(n) 个会话")……）：根上的 LookRoot 挂了
///   `.environment(\.locale, Lang.shared.locale)`，SwiftUI 按它查表，切换时整页跟着换，不用改代码
/// - 用 String 传进来、拼出来的字：写成 L("…")；带参数的写 L("%lld 个会话", n)，格式和 SwiftUI 抽出来的键一样
///   （整数 %lld、字符串 %@、小数 %lf）
/// - 别用 String(localized:)：它只认系统语言，不跟这里的设置走（实测）
/// - 发给电脑的请求带上语言（X-Kiteline-Lang），电脑生成的提醒、日报、出错原因按看的那台设备的语言出
@Observable
public final class Lang {
    public static let shared = Lang()

    public enum Choice: String, CaseIterable, Identifiable, Sendable {
        case system, zh, en
        public var id: String { rawValue }
    }

    static let key = "appLanguage"

    /// 存设置的地方：默认 UserDefaults.standard；Mac 的隔离测试实例在第一次用 Lang 之前换成自己那份
    /// （不然和正式版共用一份，用户在正式版里切了英文，测试实例也跟着英文）
    nonisolated(unsafe) public static var store: UserDefaults = .standard

    public var choice: Choice {
        didSet {
            guard choice != oldValue else { return }
            Self.store.set(choice.rawValue, forKey: Self.key)
            changed()
        }
    }

    /// 界面语言变了（设置里改了，或跟随系统时系统语言变了）。SwiftUI 自己会跟着换；AppKit / UIKit 建好就不变的字
    /// （Mac 的菜单栏、设置窗口顶上的标签页、窗口标题）听这个通知自己重设。在主线程发
    public static let didChange = Notification.Name("KitelineLanguageDidChange")

    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 系统首选语言是不是中文（跟随系统时用）。在系统设置里改了语言，App 回到前台时 refreshSystem() 重读
    private var systemChinese = Lang.systemPrefersChinese()

    /// 语言变了：Mac 上重建 AppKit 菜单、告诉电脑和手表……（主线程）
    @ObservationIgnored public var onChange: (() -> Void)?

    init() {
        choice = Choice(rawValue: Self.store.string(forKey: Self.key) ?? "") ?? .system
    }

    /// 跟随系统时英文系统也用英文（中文系统用中文）。翻译没覆盖全时可改回 false：英文系统也先显示中文，免得中英混杂
    static let followSystemEnglish = true

    public var isEnglish: Bool { choice == .en || (choice == .system && Self.followSystemEnglish && !systemChinese) }

    /// 告诉电脑的语言：zh / en
    public var code: String { isEnglish ? "en" : "zh" }

    /// 给 SwiftUI 的语言环境：查表用它的语言，日期、数字也按它的写法；地区沿用系统的
    public var locale: Locale {
        let region = Locale.current.region?.identifier
        return Locale(identifier: (isEnglish ? "en" : "zh-Hans") + (region.map { "_" + $0 } ?? ""))
    }

    public func refreshSystem() {
        let now = Lang.systemPrefersChinese()
        guard now != systemChinese else { return }
        systemChinese = now
        if choice == .system { changed() }
    }

    /// 系统（或 iOS「设置 → Kiteline → 语言」）首选的是中文：简体、繁体都算
    static func systemPrefersChinese() -> Bool {
        (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("zh")
    }

    /// 设置里选项的名字：「简体中文」「English」各用自己的语言写（切过去也认得出），「跟随系统」跟着当前语言
    public static func title(_ choice: Choice) -> String {
        switch choice {
        case .system: L("跟随系统")
        case .zh: "简体中文"
        case .en: "English"
        }
    }

    @ObservationIgnored private lazy var english: Bundle? = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))

    /// 中文原文 → 当前语言。表里没有的照原样返回（新加的字还没翻译时显示中文，不会空白）；服务器下发了更正的用更正（见 setPatches）
    public func translate(_ key: String) -> String {
        if let patched = patch(key) { return patched }
        return isEnglish ? english(key) : key
    }

    /// 中文原文 → 英文，不管这台设备自己的界面语言（电脑给某台英文手机生成文字时用，见 Mac 的 ServerLang）
    public func english(_ key: String) -> String {
        guard let english else { return key }
        return english.localizedString(forKey: key, value: key, table: nil)
    }

    /// 整张英文表（中文 → 英文）：电脑反推带变量的句子用（「已连接 虚拟机」← 「已连接 %@」）
    @ObservationIgnored public private(set) lazy var englishTable: [String: String] = {
        guard let path = english?.path(forResource: "Localizable", ofType: "strings"),
              let table = NSDictionary(contentsOfFile: path) as? [String: String] else { return [:] }
        return table
    }()
}

// MARK: - 服务器下发的文案更正

extension Lang {
    /// 一条更正：整句，或按数挑单复数（英文，{"one": "%lld file", "other": "%lld files"}）
    public enum Patch: Equatable, Sendable {
        case text(String)
        case plural(one: String, other: String)

        func pick(_ count: Int?) -> String {
            switch self {
            case .text(let text): text
            case .plural(let one, let other): count == 1 ? one : other
            }
        }
    }

    /// 换上服务器下发的文案更正（iPhone 远程配置的 strings 一节，见 KitelineKit/Model/RemoteConfig.swift）：
    /// 语言（zh / en）→ 中文原文 → 改正后的字，错字、译得不好的不用发版本就能改。
    /// 占位符和原文对不上的条目直接丢掉：%@ 写成 %lld 这类会让 String(format:) 崩溃。
    /// 只管经 L() / translate 取的字；SwiftUI 里写死的 Text("…") 是系统自己按 Localizable.strings 查的（实测不经过 NSBundle 的公开方法），改不了
    public static func setPatches(_ table: [String: [String: Patch]]) {
        var valid: [String: [String: Patch]] = [:]
        for (language, entries) in table where language == "zh" || language == "en" {
            valid[language] = entries.filter { key, patch in
                guard let want = formatSpecifiers(key) else { return false }
                switch patch {
                case .text(let text): return formatSpecifiers(text) == want
                case .plural(let one, let other): return formatSpecifiers(one) == want && formatSpecifiers(other) == want
                }
            }
        }
        patchLock.lock()
        patches = valid
        patchLock.unlock()
    }

    /// 当前语言下这句有没有更正；count：带数量的句子按它挑单复数
    func patch(_ key: String, count: Int? = nil) -> String? {
        let language = isEnglish ? "en" : "zh"
        Self.patchLock.lock()
        defer { Self.patchLock.unlock() }
        return Self.patches[language]?[key]?.pick(count)
    }

    /// L() 在哪个线程都可能调（后台任务里拼提示），读写都加锁
    private static let patchLock = NSLock()
    nonisolated(unsafe) private static var patches: [String: [String: Patch]] = [:]

    /// 句子里的格式占位符，按参数顺序排好：「共 %lld 个，%@」→ ["lld", "@"]，「%2$@ 共 %1$lld 个」→ ["lld", "@"]。
    /// %% 不算；位置跳号、同一位置两种类型、宽度精度写 *（多吃一个参数）、落单的 % 都返回 nil（当作对不上）
    static func formatSpecifiers(_ text: String) -> [String]? {
        guard text.contains("%") else { return [] }
        let ns = text as NSString
        var sequential: [String] = [], positional: [Int: String] = [:], percents = 0
        for match in specifier.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func group(_ index: Int) -> String? {
                match.range(at: index).location == NSNotFound ? nil : ns.substring(with: match.range(at: index))
            }
            let conversion = group(5) ?? ""
            if conversion == "%" { percents += 2; continue }
            percents += 1
            if group(2) == "*" || group(3) == "*" { return nil }
            let type = (group(4) ?? "") + conversion
            if let position = group(1).flatMap({ Int($0) }) {
                guard positional[position] == nil || positional[position] == type else { return nil }
                positional[position] = type
            } else {
                sequential.append(type)
            }
        }
        guard percents == text.filter({ $0 == "%" }).count else { return nil }
        if positional.isEmpty { return sequential }
        guard sequential.isEmpty, Set(positional.keys) == Set(1...positional.count) else { return nil }
        return (1...positional.count).map { positional[$0]! }
    }

    private static let specifier = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?[-+ #0']*(\*|\d+)?(?:\.(\*|\d+))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp%])"#)
}

extension Lang {
    /// 官网页面（privacy / terms / support）：一页里中英两份，英文界面跳到 #en 那份
    public static func site(_ path: String) -> URL {
        URL(string: "https://tars.betac.cn/\(path)" + (shared.isEnglish ? "#en" : ""))!
    }

    /// 更新记录的文件名：英文界面读 CHANGELOG.en.md（中文版是 CHANGELOG.md）
    public static func changelogName(english: Bool) -> String { english ? "CHANGELOG.en" : "CHANGELOG" }
}

/// 中文原文 → 当前界面语言（用 String 传、拼的字；SwiftUI 里写死的 Text("…") 不用包）
public func L(_ key: String) -> String {
    Lang.shared.translate(key)
}

/// 带一个数的：L("%lld 个文件", count: n)。英文按数挑单复数（表里写 {"one": "%lld file", "other": "%lld files"}）；
/// 只收 Int，免得把小数、文字塞进 %lld 印出乱码
public func L(_ format: String, count: Int) -> String {
    String(format: Lang.shared.patch(format, count: count) ?? Lang.shared.translate(format), locale: Lang.shared.locale, count)
}

/// 大数字底下的单位（「3」下面写「个文件」）：中文原样；英文按数挑单复数（1 file / 3 files），
/// 借带数字那句的翻译、去掉数字。`L("个文件", plural: "%lld 个文件", count: n)`
public func L(_ unit: String, plural format: String, count: Int) -> String {
    guard Lang.shared.isEnglish else { return unit }
    let text = L(format, count: count)
    guard let number = text.range(of: "\(count)") else { return L(unit) }
    return text.replacingCharacters(in: number, with: "").trimmingCharacters(in: .whitespaces)
}

/// 带参数：L("%lld 个会话", count)、L("已连接 %@", name)
public func L(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: Lang.shared.translate(format), locale: Lang.shared.locale, arguments: arguments)
}

/// 存中文原文、读的时候按当前语言翻译：给静态表里的名字用（主题、字体、字号……），表本身只建一次，切换语言照样跟着变。
/// `@Localized var name: String`，结构体的逐一成员初始化照常写 name: "经典"
@propertyWrapper
public struct Localized: Hashable, Sendable {
    public var raw: String
    public init(wrappedValue: String) { raw = wrappedValue }
    public var wrappedValue: String {
        get { L(raw) }
        set { raw = newValue }
    }
}

/// 电脑生成、发给手机的字换成英文（Mac 的服务端出口 ServerLang、iPhone 演示模式共用）：
/// 一句话先整句查表；查不到再用表里带占位符的键反推（「已连接 虚拟机」← 「已连接 %@」），变量部分也查一遍；
/// JSON 里只换界面文字那几个字段（error、detail、activityText……），会话标题、Claude 的回复这类内容不动
public enum ServerText {
    /// 界面文字的字段：值是电脑生成的话，换成英文
    public static let fields: Set<String> = ["error", "message", "detail", "hint", "status", "reason", "activityText", "blocking", "fix",
                                             "label", "summary", "note", "warning", "subtitle", "caption", "action", "body", "description", "client",
                                             "errors", "readOnlyReason"]

    /// 机器名：只换系统起的默认名「本机」，用户自己起的名字（哪怕是中文）不动
    public static func machine(_ name: String, english: Bool = Lang.shared.isEnglish) -> String {
        name == "本机" && english ? Lang.shared.english(name) : name
    }

    /// 一句话换成英文（查不到就原样）
    public static func translate(_ text: String) -> String {
        guard !text.isEmpty, text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return text }
        let whole = Lang.shared.english(text)
        if whole != text { return whole }
        guard text.count <= 400 else { return text }   // 这么长的多半是内容（Claude 的回复），不拿几百个句式去配
        for pattern in patterns where pattern.prefix.isEmpty || text.hasPrefix(pattern.prefix) {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.regex.firstMatch(in: text, range: range) else { continue }
            var output = pattern.english
            var values: [String] = []
            for index in 1..<match.numberOfRanges {
                guard let r = Range(match.range(at: index), in: text) else { continue }
                values.append(translate(String(text[r])))
            }
            // 英文模板里的占位符依次换成抠出来的值（%% 是百分号）
            var result = "", i = output.startIndex, next = 0
            while i < output.endIndex {
                if output[i] == "%", let spec = output[i...].firstMatch(of: placeholder) {
                    if output[spec.range] == "%%" { result += "%" } else { result += next < values.count ? values[next] : ""; next += 1 }
                    i = spec.range.upperBound
                } else {
                    result.append(output[i]); i = output.index(after: i)
                }
            }
            output = result
            return output
        }
        // 「机器名：原因」（各来源连不上时的 errors 都是这样拼的）：两半分开换
        if let colon = text.firstIndex(of: "："), colon != text.startIndex {
            let name = String(text[..<colon]), reason = String(text[text.index(after: colon)...])
            let english = translate(reason)
            if english != reason { return machine(name, english: true) + ": " + english }
        }
        return text
    }

    /// JSON 里界面文字的字段换成英文；extra：这个接口另外要换的字段（就绪检查的 title）
    public static func localize(_ object: Any, extra: Set<String> = []) -> Any {
        if let dict = object as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict {
                if key.hasSuffix("En"), dict[String(key.dropLast(2))] != nil { continue }   // 英文版给下面用，不单独发
                if let english = dict[key + "En"] as? String, !english.isEmpty {
                    out[key] = english
                    continue
                }
                if let text = value as? String, key == "name" || key == "sourceName" {
                    out[key] = machine(text, english: true)   // 会话标题这类名字是内容；只有默认的「本机」换
                } else if let text = value as? String, fields.contains(key) || extra.contains(key) {
                    out[key] = translate(text)
                } else if let list = value as? [String], fields.contains(key) || extra.contains(key) {
                    out[key] = list.map(translate)
                } else {
                    out[key] = localize(value, extra: extra)
                }
            }
            return out
        }
        if let array = object as? [Any] { return array.map { localize($0, extra: extra) } }
        return object
    }

    public static func localize(json data: Data, extra: Set<String> = []) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: localize(object, extra: extra), options: [.sortedKeys]) else { return data }
        return out
    }

    // MARK: 带变量的句子

    private struct Pattern {
        var regex: NSRegularExpression
        /// 第一个占位符前面的字：先比它，省得每句都跑一遍几百个正则
        var prefix: String
        var english: String
        /// 除占位符外的字数：越多越具体
        var fixed: Int
    }

    private static let placeholder = try! Regex(#"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|\.\d+f|%)"#)

    /// 表里带占位符的键 → 正则
    private static let patterns: [Pattern] = {
        Lang.shared.englishTable.compactMap { key, english -> Pattern? in
            guard key.contains("%"), key.firstMatch(of: placeholder) != nil else { return nil }
            var regex = "^", prefix = "", sawPlaceholder = false, i = key.startIndex
            while i < key.endIndex {
                if key[i] == "%", let spec = key[i...].firstMatch(of: placeholder), spec.range.lowerBound == i {
                    switch String(key[spec.range]) {
                    case "%%": regex += "%"; if !sawPlaceholder { prefix += "%" }
                    case "%lld", "%ld", "%d": regex += "(-?\\d+)"; sawPlaceholder = true
                    case "%lf", "%f": regex += "(-?[\\d.]+)"; sawPlaceholder = true
                    default: regex += "(.+?)"; sawPlaceholder = true
                    }
                    i = spec.range.upperBound
                } else {
                    regex += NSRegularExpression.escapedPattern(for: String(key[i]))
                    if !sawPlaceholder { prefix.append(key[i]) }
                    i = key.index(after: i)
                }
            }
            // 固定的字里至少两个汉字才拿来反推：「%@ %@」「%@：%@」这种太泛，会把别的句子拆成乱码
            let fixed = key.replacing(placeholder, with: "")
            guard sawPlaceholder, fixed.unicodeScalars.filter({ (0x4E00...0x9FFF).contains($0.value) }).count >= 2,
                  let compiled = try? NSRegularExpression(pattern: regex + "$", options: [.dotMatchesLineSeparators]) else { return nil }
            return Pattern(regex: compiled, prefix: prefix, english: english, fixed: fixed.count)
        }
        // 固定的字越多越具体，先配
        .sorted { $0.fixed > $1.fixed }
    }()
}
