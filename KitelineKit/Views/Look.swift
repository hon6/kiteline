import CoreText
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - 外观：主题色、字体、字号
//
// 各端同一套：iPhone App；Mac App（这个文件也编进 Mac 的 KitelineKit，Mac 的设置、侧栏、菜单栏直接用这里的 Look）；
// Apple Watch（手机按手表选项算好颜色、字体样式发过去，见 WatchLook）；网页版在 Resources/web/app.js 的 Look 里有同样的表。
// 改配色、加字体要几处一起改，id 不能变（存在各端的偏好里）

/// 一套主题色：强调色（图标、链接、进行中、选中）、主按钮（发送、开关、勾选）、我发的气泡和气泡上的字；浅色、深色各一份
public struct LookTheme: Identifiable, Hashable, Sendable {
    public let id: String
    /// 存中文、读时按界面语言翻译（见 Localized）
    @Localized public var name: String
    let accent: UInt32, accentDark: UInt32
    let action: UInt32, actionDark: UInt32
    let bubble: UInt32, bubbleDark: UInt32
    let bubbleText: UInt32, bubbleTextDark: UInt32

    public static let all: [LookTheme] = [
        // 默认：品牌橙 + 微信式的绿气泡（原来的样子）
        LookTheme(id: "classic", name: "经典", accent: 0xD97757, accentDark: 0xD97757, action: 0x07C160, actionDark: 0x07C160,
                  bubble: 0x95EC69, bubbleDark: 0x3EB575, bubbleText: 0x111111, bubbleTextDark: 0x08180E),
        LookTheme(id: "clay", name: "赤陶", accent: 0xD97757, accentDark: 0xE08B6E, action: 0xD97757, actionDark: 0xD97757,
                  bubble: 0xF7E0D6, bubbleDark: 0x8E4B36, bubbleText: 0x2B1911, bubbleTextDark: 0xFFF5F0),
        LookTheme(id: "ocean", name: "海蓝", accent: 0x007AFF, accentDark: 0x0A84FF, action: 0x007AFF, actionDark: 0x0A84FF,
                  bubble: 0xDCEBFF, bubbleDark: 0x1F4E8C, bubbleText: 0x0A2140, bubbleTextDark: 0xF2F7FF),
        LookTheme(id: "pine", name: "松绿", accent: 0x2E8B6A, accentDark: 0x3FB28A, action: 0x2E8B6A, actionDark: 0x2F9C76,
                  bubble: 0xD9F0E5, bubbleDark: 0x235E48, bubbleText: 0x0E2A1F, bubbleTextDark: 0xEFFAF5),
        LookTheme(id: "violet", name: "暮紫", accent: 0x6E56CF, accentDark: 0x9E8CFC, action: 0x6E56CF, actionDark: 0x7B64DD,
                  bubble: 0xE9E4FB, bubbleDark: 0x45388A, bubbleText: 0x1D1440, bubbleTextDark: 0xF5F2FF),
        // 只有黑白灰
        LookTheme(id: "graphite", name: "石墨", accent: 0x3A3A3C, accentDark: 0xD1D1D6, action: 0x1C1C1E, actionDark: 0x636366,
                  bubble: 0xE5E5EA, bubbleDark: 0x3A3A3C, bubbleText: 0x111111, bubbleTextDark: 0xF2F2F7),
        LookTheme(id: "rose", name: "樱粉", accent: 0xC8506E, accentDark: 0xE07A93, action: 0xC8506E, actionDark: 0xD2607C,
                  bubble: 0xFBE3EA, bubbleDark: 0x7A2E43, bubbleText: 0x3A0F1D, bubbleTextDark: 0xFFF2F5),
        LookTheme(id: "amber", name: "琥珀", accent: 0xB7791F, accentDark: 0xE3A645, action: 0xB7791F, actionDark: 0xC98A2C,
                  bubble: 0xFBEFD9, bubbleDark: 0x6E4A12, bubbleText: 0x3A2706, bubbleTextDark: 0xFFF7E8),
        LookTheme(id: "teal", name: "青碧", accent: 0x0F8B8D, accentDark: 0x34B5B7, action: 0x0F8B8D, actionDark: 0x1A9C9E,
                  bubble: 0xD5F1F1, bubbleDark: 0x145A5C, bubbleText: 0x06302F, bubbleTextDark: 0xEDFBFB),
        LookTheme(id: "indigo", name: "靛青", accent: 0x3F51B5, accentDark: 0x7C8CF0, action: 0x3F51B5, actionDark: 0x5466D0,
                  bubble: 0xE3E7FA, bubbleDark: 0x2E3A85, bubbleText: 0x141A45, bubbleTextDark: 0xF2F4FF),
        LookTheme(id: "wine", name: "酒红", accent: 0x9B2D4A, accentDark: 0xD4637F, action: 0x9B2D4A, actionDark: 0xB03A58,
                  bubble: 0xF5DDE4, bubbleDark: 0x5E1E30, bubbleText: 0x3A0A17, bubbleTextDark: 0xFFF0F4),
        LookTheme(id: "olive", name: "橄榄", accent: 0x6B7A2E, accentDark: 0xA3B556, action: 0x6B7A2E, actionDark: 0x7D8D38,
                  bubble: 0xEDF1D9, bubbleDark: 0x44501C, bubbleText: 0x23290B, bubbleTextDark: 0xF8FBEC),
        LookTheme(id: "mocha", name: "咖啡", accent: 0x8B6247, accentDark: 0xC2967A, action: 0x8B6247, actionDark: 0x9C7155,
                  bubble: 0xF2E6DC, bubbleDark: 0x5A3F2D, bubbleText: 0x2E1E14, bubbleTextDark: 0xFFF6EF),
        LookTheme(id: "navy", name: "墨蓝", accent: 0x1F3A5F, accentDark: 0x8AA6CF, action: 0x1F3A5F, actionDark: 0x3D5A85,
                  bubble: 0xDFE6F0, bubbleDark: 0x24364F, bubbleText: 0x0E1B2C, bubbleTextDark: 0xEEF3FA),
    ]

    public static func named(_ id: String) -> LookTheme { all.first { $0.id == id } ?? all[0] }

    /// 自定义：从一个颜色配出整套（和网页版 Look.custom 同一个算法）——
    /// 强调色就是它（深色下太暗的提亮）；主按钮要压得住白字（太浅的压暗）；浅色气泡是它淡淡的一层配深色字，深色气泡是压暗的它配浅色字
    public static func custom(_ hex: UInt32) -> LookTheme {
        let lum = luminance(hex)
        let accentDark = lum < 0.12 ? mix(hex, 0xFFFFFF, 0.45) : hex
        let action = lum > 0.45 ? mix(hex, 0x000000, 0.35) : hex
        let actionDark = luminance(action) < 0.05 ? mix(action, 0xFFFFFF, 0.3) : action
        return LookTheme(id: "custom", name: "自定义", accent: hex, accentDark: accentDark, action: action, actionDark: actionDark,
                         bubble: mix(hex, 0xFFFFFF, 0.84), bubbleDark: mix(hex, 0x000000, 0.55),
                         bubbleText: mix(hex, 0x000000, 0.8), bubbleTextDark: mix(hex, 0xFFFFFF, 0.92))
    }

    /// 两个颜色按比例混（t = 0 是 a，1 是 b）
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// 相对亮度（0 黑 … 1 白）
    static func luminance(_ hex: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}

/// 一种字体。中文字体苹果系统里不一定装着：用到时从苹果的字体服务下载整个家族（Mac 自带宋体），
/// 没下好之前、下不了时退回同风格的系统字体（衬线 / 圆角）
public struct LookFont: Identifiable, Hashable, Sendable {
    public let id: String
    /// 名字、说明、分组都存中文、读时按界面语言翻译（见 Localized）
    @Localized public var name: String
    /// 设置里名字下面的一行小字
    @Localized public var detail: String
    /// 分组：正文 / 书卷 / 手写与艺术
    @Localized public var group: String
    /// 系统字体用哪种样式：default / rounded / serif / monospaced（中文字体还没下好时、手表上用它）
    public let designName: String
    /// 中文字体的 PostScript 名（常规体；粗体由系统按字重挑同一家族里的）；nil = 中文用苹方
    public let cjk: String?
    /// 中文字体的家族名（下载时整个家族一起下，粗体才有）
    let family: String?

    init(_ id: String, _ name: String, _ detail: String, group: String, design: String, cjk: String? = nil, family: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.group = group
        designName = design
        self.cjk = cjk
        self.family = family
    }

    public static var groups: [String] { [L("正文"), L("书卷"), L("手写与艺术")] }

    public static let all: [LookFont] = [
        LookFont("system", "系统", "苹方 + San Francisco", group: "正文", design: "default"),
        LookFont("rounded", "圆体", "圆体-简，笔画圆润", group: "正文", design: "rounded", cjk: "STYuanti-SC-Regular", family: "Yuanti SC"),
        LookFont("lanting", "兰亭黑", "兰亭黑-简，清瘦的黑体", group: "正文", design: "default", cjk: "FZLTXHK--GBK1-0", family: "Lantinghei SC"),
        LookFont("mono", "等宽", "SF Mono + 苹方", group: "正文", design: "monospaced"),
        LookFont("serif", "宋体", "宋体-简，适合长篇阅读", group: "书卷", design: "serif", cjk: "STSongti-SC-Regular", family: "Songti SC"),
        LookFont("kai", "楷体", "楷体-简，端正的手写感", group: "书卷", design: "serif", cjk: "STKaitiSC-Regular", family: "Kaiti SC"),
        LookFont("baoli", "报隶", "报隶-简，报刊标题的隶书", group: "书卷", design: "serif", cjk: "STBaoliSC-Regular", family: "Baoli SC"),
        LookFont("hannotate", "手札体", "手札体-简，钢笔字", group: "手写与艺术", design: "rounded", cjk: "HannotateSC-W5", family: "Hannotate SC"),
        LookFont("hanzipen", "翩翩体", "翩翩体-简，轻快的硬笔字", group: "手写与艺术", design: "rounded", cjk: "HanziPenSC-W3", family: "HanziPen SC"),
        LookFont("yuppy", "雅痞", "雅痞-简，圆润的手写", group: "手写与艺术", design: "rounded", cjk: "YuppySC-Regular", family: "Yuppy SC"),
        LookFont("wawati", "娃娃体", "娃娃体-简，童趣", group: "手写与艺术", design: "rounded", cjk: "DFWaWaSC-W5", family: "Wawati SC"),
        LookFont("xingkai", "行楷", "行楷-简，毛笔行书", group: "手写与艺术", design: "serif", cjk: "STXingkaiSC-Light", family: "Xingkai SC"),
        LookFont("libian", "隶变", "隶变-简，隶书", group: "手写与艺术", design: "serif", cjk: "STLibianSC-Regular", family: "Libian SC"),
        LookFont("weibei", "魏碑", "魏碑-简，碑刻楷书", group: "手写与艺术", design: "serif", cjk: "WeibeiSC-Bold", family: "Weibei SC"),
    ]

    public static func named(_ id: String) -> LookFont { all.first { $0.id == id } ?? all[0] }

    var design: Font.Design {
        switch designName {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: .default
        }
    }
}

/// 字号档位：和 iPhone「设置 → 显示与亮度 → 文字大小」的前七档一一对应（标准 = 第四档）；Mac、网页按同样的比例缩放
public struct LookSize: Identifiable, Hashable, Sendable {
    public let id: String
    /// 存中文、读时按界面语言翻译（见 Localized）
    @Localized public var name: String
    public let scale: CGFloat

    public static let all: [LookSize] = [
        LookSize(id: "xs", name: "特小", scale: 0.82),
        LookSize(id: "s", name: "小", scale: 0.88),
        LookSize(id: "m", name: "较小", scale: 0.94),
        LookSize(id: "l", name: "标准", scale: 1),
        LookSize(id: "xl", name: "较大", scale: 1.12),
        LookSize(id: "xxl", name: "大", scale: 1.24),
        LookSize(id: "xxxl", name: "特大", scale: 1.35),
    ]

    /// 「跟随系统」（只有 iPhone 有：跟着系统的文字大小走）
    public static let system = "system"

    public static func named(_ id: String) -> LookSize? { all.first { $0.id == id } }

    #if os(iOS)
    var contentSizeCategory: UIContentSizeCategory {
        switch id {
        case "xs": .extraSmall
        case "s": .small
        case "m": .medium
        case "xl": .extraLarge
        case "xxl": .extraExtraLarge
        case "xxxl": .extraExtraExtraLarge
        default: .large
        }
    }

    var dynamicType: DynamicTypeSize {
        switch id {
        case "xs": .xSmall
        case "s": .small
        case "m": .medium
        case "xl": .xLarge
        case "xxl": .xxLarge
        case "xxxl": .xxxLarge
        default: .large
        }
    }
    #endif
}

/// 当前主题算好的颜色（换主题时算一次，同一个主题下每次拿到的是同一个 Color，比较相等也成立）
public struct LookPalette {
    public let accent: Color
    public let action: Color
    public let bubble: Color
    public let bubbleText: Color
    /// 图标、首字头像的底：淡淡的强调色
    public let tile: Color
    /// 我的气泡的浅色版（深色蒙层上「按住说话」的气泡用）
    let bubbleLight: Color

    init(_ theme: LookTheme) {
        accent = Theme.dynamic(light: theme.accent, dark: theme.accentDark)
        action = Theme.dynamic(light: theme.action, dark: theme.actionDark)
        bubble = Theme.dynamic(light: theme.bubble, dark: theme.bubbleDark)
        bubbleText = Theme.dynamic(light: theme.bubbleText, dark: theme.bubbleTextDark)
        tile = Theme.dynamic(light: theme.accent, dark: theme.accentDark, lightAlpha: 0.13, darkAlpha: 0.16)
        bubbleLight = Color(hex: theme.bubble)
    }
}

/// 这台设备上的外观设置（存在本机偏好里，各端各管各的）。界面读 Look.shared 的属性，改了自动重画
@Observable
public final class Look {
    public static let shared = Look()

    @ObservationIgnored private var defaults: UserDefaults = .standard
    /// 正在从偏好里读：这时改属性不存、不刷新导航栏（init 里 Look.shared 还没建好）
    @ObservationIgnored private var loading = false

    /// LookTheme 的 id，或 "custom"（自定义颜色，见 customColor）
    public var themeID: String { didSet { if themeID != oldValue { palette = LookPalette(theme); save() } } }
    /// 自定义的颜色（0xRRGGBB），themeID 是 custom 时用
    public var customColor: UInt32 = 0xD97757 { didSet { if customColor != oldValue { palette = LookPalette(theme); save() } } }
    public var fontID: String { didSet { if fontID != oldValue, !loading { save(); prepareFont() } } }
    /// LookSize 的 id，或 LookSize.system（跟随系统，只有 iPhone）
    public var sizeID: String { didSet { if sizeID != oldValue { save() } } }

    public private(set) var palette: LookPalette

    /// 中文字体：已经能用的（装着的、下载好的）、正在下载的进度（0…1）、下载失败的原因
    public private(set) var readyFonts: Set<String> = []
    public private(set) var downloads: [String: Double] = [:]
    public private(set) var failures: [String: String] = [:]

    #if os(iOS)
    /// 系统的文字大小（「跟随系统」时用）
    private var systemScale: CGFloat = 1
    #endif

    private init() {
        themeID = "classic"
        fontID = "system"
        sizeID = "system"
        palette = LookPalette(LookTheme.all[0])
        load()
        prepareFont()
        #if os(iOS)
        // UIApplication 只能在主线程问（手表的请求可能在后台线程先用到 Look）
        if Thread.isMainThread { systemScale = Look.currentSystemScale() } else {
            DispatchQueue.main.async { self.systemScale = Look.currentSystemScale() }
        }
        NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemScale = Look.currentSystemScale()
        }
        #endif
    }

    /// Mac：用 App 自己的那份偏好（测试实例单独一份），在界面出来之前调一次
    public func use(_ defaults: UserDefaults) {
        self.defaults = defaults
        load()
        prepareFont()
    }

    private func load() {
        loading = true
        defer { loading = false }
        let theme = defaults.string(forKey: "lookTheme") ?? "classic"
        customColor = defaults.string(forKey: "lookCustom").flatMap { UInt32($0, radix: 16) } ?? 0xD97757
        let font = defaults.string(forKey: "lookFont") ?? "system"
        var size = defaults.string(forKey: "lookSize") ?? LookSize.system
        #if !os(iOS)
        if LookSize.named(size) == nil { size = "l" }
        #endif
        if LookSize.named(size) == nil { size = LookSize.system }
        themeID = theme == "custom" || LookTheme.all.contains { $0.id == theme } ? theme : "classic"
        fontID = LookFont.all.contains { $0.id == font } ? font : "system"
        sizeID = size
        palette = LookPalette(self.theme)
    }

    private func save() {
        guard !loading else { return }
        defaults.set(themeID, forKey: "lookTheme")
        defaults.set(String(format: "%06X", customColor), forKey: "lookCustom")
        defaults.set(fontID, forKey: "lookFont")
        defaults.set(sizeID, forKey: "lookSize")
        #if os(iOS)
        Look.styleSystemControls()
        #endif
    }

    public var theme: LookTheme { themeID == "custom" ? .custom(customColor) : LookTheme.named(themeID) }
    public var font: LookFont { LookFont.named(fontID) }
    public var size: LookSize? { LookSize.named(sizeID) }

    /// 现在用得上的中文字体（还没下好就是 nil，先用系统字体顶着）
    public var cjkFont: String? {
        guard let name = font.cjk, readyFonts.contains(name) else { return nil }
        return name
    }

    /// 写死字号的字放大缩小的倍数（标准 = 1）。iPhone「跟随系统」时按系统的文字大小算，最多放大到 1.6 倍（太大会挤坏一行一行的列表）
    public var textScale: CGFloat {
        if let size { return size.scale }
        #if os(iOS)
        return min(systemScale, 1.6)
        #else
        return 1
        #endif
    }

    /// 对话正文的倍数：「跟随系统」时不设上限（和以前一样跟着系统走，辅助功能的大字也能放大）
    var chatScale: CGFloat {
        if let size { return size.scale }
        #if os(iOS)
        return systemScale
        #else
        return 1
        #endif
    }

    #if os(iOS)
    /// 根视图上要盖掉系统文字大小的档位；nil = 跟随系统
    public var dynamicTypeOverride: DynamicTypeSize? { size?.dynamicType }

    private static func currentSystemScale() -> CGFloat {
        UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory)).pointSize / 17
    }
    #endif

    // MARK: 字

    /// 指定字号的字（size 已经是最终的点数）：换成选的字体；指定了 design（代码这类等宽字）的只用系统字体
    public func font(size: CGFloat, weight: Font.Weight?, design: Font.Design?) -> Font {
        if design == nil, let name = cjkFont {
            let font = Font.custom(name, fixedSize: size)
            return weight.map { font.weight($0) } ?? font
        }
        return .system(size: size, weight: weight, design: design ?? font.design)
    }

    #if os(iOS)
    /// iPhone 的文字档位：系统字体照样跟着文字大小走；中文字体按系统同档的字号、同样跟着缩放
    func font(_ style: Font.TextStyle, design: Font.Design?) -> Font {
        if design == nil, let name = cjkFont {
            let font = Font.custom(name, size: Look.baseSize(style), relativeTo: style)
            return style == .headline ? font.weight(.semibold) : font
        }
        return .system(style, design: design ?? font.design)
    }

    /// 标准文字大小下各档的字号（iOS 的默认值）
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }
    #endif

    // MARK: 中文字体下载

    /// 选中的字体要是中文字体：确认能用，没装就下载（下好以后整个界面自动换过来）。
    /// 没选中的中文字体：装着的、以前下载过的直接启用（不联网），设置里就不会再显示「首次使用需下载」
    public func prepareFont() {
        for option in LookFont.all {
            guard let name = option.cjk, !readyFonts.contains(name), downloads[name] == nil else { continue }
            if Look.installed(name) {
                readyFonts.insert(name)
            } else if option.id == fontID || Look.downloaded(name) {
                activate(option)
            }
        }
    }

    /// 某个中文字体现在是什么状态（设置里显示用）
    public func fontState(_ option: LookFont) -> String? {
        guard let name = option.cjk else { return nil }
        if readyFonts.contains(name) { return nil }
        if let progress = downloads[name] { return progress > 0 ? L("下载中 %@%%", "\(Int(progress * 100))") : L("准备下载…") }
        if let failure = failures[name] { return failure }
        return L("首次使用需下载")
    }

    private func activate(_ option: LookFont) {
        guard let name = option.cjk, !readyFonts.contains(name), downloads[name] == nil else { return }
        if Look.installed(name) {
            readyFonts.insert(name)
            return
        }
        failures[name] = nil
        downloads[name] = 0
        // 整个家族一起下（常规、粗体……），粗体字才不是硬描出来的
        let descriptor = option.family.map { CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: $0] as CFDictionary) }
            ?? CTFontDescriptorCreateWithNameAndSize(name as CFString, 0)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { [weak self] state, progress in
            let info = progress as NSDictionary
            switch state {
            case .downloading:
                let percent = (info[kCTFontDescriptorMatchingPercentage] as? Double) ?? 0
                DispatchQueue.main.async { self?.downloads[name] = max(0.01, percent / 100) }
            case .didFinish:
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.downloads[name] = nil
                    if Look.installed(name) {
                        self.readyFonts.insert(name)
                        #if os(iOS)
                        Look.styleSystemControls()
                        #endif
                    } else if self.failures[name] == nil {
                        self.failures[name] = L("下载失败，轻点重试")
                    }
                }
            case .didFailWithError:
                let error = info[kCTFontDescriptorMatchingError] as? NSError
                DispatchQueue.main.async {
                    self?.failures[name] = error.map { L("下载失败（%@）", "\($0.localizedDescription)") } ?? L("下载失败，轻点重试")
                }
            default:
                break
            }
            return true
        }
    }

    /// 重新下载（上次失败了）
    public func retry(_ option: LookFont) {
        guard let name = option.cjk else { return }
        failures[name] = nil
        activate(option)
    }

    /// 以前下载过（苹果的字体服务下好放在系统里了，只是这次启动还没启用）
    private static func downloaded(_ name: String) -> Bool {
        let query = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name, kCTFontDownloadableAttribute: true] as CFDictionary)
        let mandatory = Set([kCTFontDownloadableAttribute as String]) as CFSet
        guard let match = (CTFontDescriptorCreateMatchingFontDescriptors(query, mandatory) as? [CTFontDescriptor])?.first else { return false }
        return (CTFontDescriptorCopyAttribute(match, kCTFontDownloadedAttribute) as? Bool) ?? false
    }

    private static func installed(_ name: String) -> Bool {
        #if canImport(UIKit)
        UIFont(name: name, size: 12) != nil
        #else
        NSFont(name: name, size: 12) != nil
        #endif
    }

    #if os(iOS)
    /// 导航栏标题、分段控件、搜索框、导航栏上的文字按钮是 UIKit 画的，不吃 SwiftUI 的字体：
    /// 换字体、字号时把它们的字也换掉（以后新建的走 appearance，已经显示着的逐个改）
    static func styleSystemControls() {
        let look = Look.shared
        // 设置里选了字号就按那一档放大，「跟随系统」按系统的文字大小
        let traits = look.size.map { UITraitCollection(preferredContentSizeCategory: $0.contentSizeCategory) }
        func uiFont(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle) -> UIFont {
            let metrics = UIFontMetrics(forTextStyle: style)
            func scaled(_ font: UIFont) -> UIFont { metrics.scaledFont(for: font, compatibleWith: traits) }
            if let name = look.cjkFont, let font = UIFont(name: name, size: size) {
                guard weight.rawValue >= UIFont.Weight.semibold.rawValue else { return scaled(font) }
                let bold = font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: size) } ?? font
                return scaled(bold)
            }
            var font = UIFont.systemFont(ofSize: size, weight: weight)
            let design: UIFontDescriptor.SystemDesign? = switch look.font.designName {
            case "rounded": .rounded
            case "serif": .serif
            case "monospaced": .monospaced
            default: nil
            }
            if let design, let descriptor = font.fontDescriptor.withDesign(design) { font = UIFont(descriptor: descriptor, size: size) }
            return scaled(font)
        }
        let standard = uiFont(17, .semibold, .headline), large = uiFont(34, .bold, .largeTitle)
        let segment = uiFont(13, .regular, .footnote), segmentOn = uiFont(13, .semibold, .footnote)
        let field = uiFont(17, .regular, .body), barButton = uiFont(17, .regular, .body)
        let proxy = UINavigationBar.appearance()
        proxy.titleTextAttributes = [.font: standard]
        proxy.largeTitleTextAttributes = [.font: large]
        UISegmentedControl.appearance().setTitleTextAttributes([.font: segment], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: segmentOn], for: .selected)
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).font = field
        for state: UIControl.State in [.normal, .highlighted, .disabled, .selected] {
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: barButton], for: state)
        }
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                for bar in window.descendants(of: UINavigationBar.self) {
                    bar.titleTextAttributes = (bar.titleTextAttributes ?? [:]).merging([.font: standard]) { $1 }
                    bar.largeTitleTextAttributes = (bar.largeTitleTextAttributes ?? [:]).merging([.font: large]) { $1 }
                    func restyled(_ appearance: UINavigationBarAppearance) -> UINavigationBarAppearance {
                        let copy = appearance.copy()
                        copy.titleTextAttributes[.font] = standard
                        copy.largeTitleTextAttributes[.font] = large
                        return copy
                    }
                    bar.standardAppearance = restyled(bar.standardAppearance)
                    if let edge = bar.scrollEdgeAppearance { bar.scrollEdgeAppearance = restyled(edge) }
                    if let compact = bar.compactAppearance { bar.compactAppearance = restyled(compact) }
                }
                for control in window.descendants(of: UISegmentedControl.self) {
                    control.setTitleTextAttributes([.font: segment], for: .normal)
                    control.setTitleTextAttributes([.font: segmentOn], for: .selected)
                }
                for search in window.descendants(of: UISearchTextField.self) { search.font = field }
            }
        }
    }
    #endif
}

#if os(iOS)
private extension UIView {
    func descendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in ((view as? T).map { [$0] } ?? []) + view.descendants(of: type) }
    }
}
#endif

extension Font {
    /// 写死字号的界面字（size = 标准字号下的点数）：跟着设置里的字号缩放、换成选的字体；
    /// 指定了 design（等宽这类）的只缩放、不换字体。框死大小的小方块（头像首字、角标）里的字用 appFixed：只换字体不缩放
    /// （Mac App 那边在 Sources/DesignSystem.swift 里有一份同样的 Font.app）
    static func app(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        Look.shared.font(size: size * Look.shared.textScale, weight: weight, design: design)
    }

    /// 只换字体、不缩放：字号已经算好了的（ChatType 那些已经乘过倍数），或者框死大小的方块里的字（头像首字、角标、编号）
    static func appFixed(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        Look.shared.font(size: size, weight: weight, design: design)
    }
}

/// 根视图上挂一次：界面语言、强调色、默认字（没写字体的字、系统控件的标签用它）、（iPhone）文字大小。
/// 不在环境里挂 fontDesign：它会连明确写的等宽字（代码、命令、路径；Menlo、.monospaced 都会）一起换成普通字（ccpulse-cf 实测）。
/// 圆体、宋体这些靠 Font.ui / Font.app / 这里的默认字生效；列表分组标题这类系统自己定字体的地方保持系统字
public struct LookRoot: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        let look = Look.shared
        content
            // SwiftUI 按环境里的语言查 en.lproj：写死的 Text("会话") 这类字跟着设置里的语言换，不用重启（见 Lang）
            .environment(\.locale, Lang.shared.locale)
            .tint(look.palette.accent)
            #if os(iOS)
            .transformEnvironment(\.dynamicTypeSize) { size in
                if let override = look.dynamicTypeOverride { size = override }
            }
            .font(Font.ui(.body))
            .onAppear { Look.styleSystemControls() }
            #else
            .font(.app(size: 13))
            #endif
    }
}

extension View {
    public func lookRoot() -> some View { modifier(LookRoot()) }
}

// MARK: - 分段选择

/// 分段选择（内容 / 改动记录、现在开始 / 每天……）。iPhone 用系统的分段控件（字由 styleSystemControls 换）；
/// Mac 上系统的分段控件不吃设置里的字体（实测 .font 加在哪都没用），照它的样子自己画一个：浅灰底槽、选中的一格浮起来。
/// 工具栏里的分段控件是窗口外框的一部分（和窗口标题一样是系统字），不用换
public struct LookSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    public init(selection: Binding<Value>, options: [(Value, String)]) {
        _selection = selection
        self.options = options.map { (value: $0.0, label: $0.1) }
    }

    public var body: some View {
        #if os(iOS)
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { Text(L(options[$0].label)).tag(options[$0].value) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        #else
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let on = options[index].value == selection
                Button { selection = options[index].value } label: {
                    Text(L(options[index].label))
                        .font(.app(size: 13, weight: on ? .medium : nil))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 22 * Look.shared.textScale)
                        .padding(.horizontal, 8)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.14), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                if index < options.count - 1 {
                    // 两格都没选中时中间一道细线（和系统的一样）
                    Rectangle().fill(Color.primary.opacity(on || options[index + 1].value == selection ? 0 : 0.12))
                        .frame(width: 1, height: 12)
                }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .animation(.snappy(duration: 0.18), value: selection)
        #endif
    }
}

// MARK: - 设置里共用的几块（iPhone 的「外观」页和 Mac 的「设置 → 通用」都用）

/// 主题色圆点：外圈是强调色、里面是气泡色，选中的带勾；最后一个是「自定义」（彩色外圈，里面是自己挑的颜色，颜色在下面的「自定义颜色」里挑）
public struct LookThemePicker: View {
    @Binding var selection: String
    var diameter: CGFloat
    var columns: Int
    @State private var look = Look.shared

    public init(selection: Binding<String>, diameter: CGFloat = 38, columns: Int = 5) {
        _selection = selection
        self.diameter = diameter
        self.columns = columns
    }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 14) {
            ForEach(LookTheme.all) { theme in
                swatch(theme, ring: nil)
            }
            swatch(.custom(look.customColor), ring: AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
        }
    }

    private func swatch(_ theme: LookTheme, ring: AngularGradient?) -> some View {
        let palette = LookPalette(theme)
        let on = theme.id == selection
        return Button {
            selection = theme.id
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if let ring { Circle().fill(ring) } else { Circle().fill(palette.accent) }
                    Circle().fill(palette.bubble).padding(diameter * 0.2)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: diameter * 0.26, weight: .bold)).foregroundStyle(palette.bubbleText)
                    }
                }
                .frame(width: diameter, height: diameter)
                .overlay(Circle().hairlineBorder(Color.primary.opacity(0.1)))
                .padding(3)
                .overlay(Circle().strokeBorder(on ? palette.accent : .clear, lineWidth: 2))
                Text(theme.name).font(.app(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension Look {
    /// 「自定义颜色」的取色器用：颜色 ↔ 0xRRGGBB（广色域的颜色截到 sRGB）
    public var customColorBinding: Binding<Color> {
        Binding(get: { Color(hex: self.customColor) }, set: { color in
            self.customColor = Look.hex(color)
            self.themeID = "custom"
        })
    }

    static func hex(_ color: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        #if canImport(UIKit)
        var a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        if let c = NSColor(color).usingColorSpace(.sRGB) { r = c.redComponent; g = c.greenComponent; b = c.blueComponent }
        #endif
        func byte(_ x: CGFloat) -> UInt32 { UInt32((min(max(x, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}

/// 预览：一来一回两个气泡、一个强调色的图标和按钮，按当前主题、字体、字号画
public struct LookPreview: View {
    public init() {}

    public var body: some View {
        let look = Look.shared
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.app(size: 13, weight: .semibold)).foregroundStyle(look.palette.accent)
                    .frame(width: 26, height: 26).background(look.palette.tile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Claude").font(.app(size: 13, weight: .semibold))
                Spacer()
                Text("刚刚").font(.app(size: 11)).foregroundStyle(.secondary)
            }
            Text("登录页已修改完成，测试全部通过。是否需要提交？")
                .font(.appFixed(size: ChatType.size))
                .lineSpacing(ChatType.lineSpacing)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Spacer(minLength: 40)
                Text("好的，请提交")
                    .font(.appFixed(size: ChatType.size))
                    .foregroundStyle(look.palette.bubbleText)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(look.palette.bubble, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                Text("允许").font(.app(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(look.palette.action, in: Capsule())
                Text("查看改动").font(.app(size: 13)).foregroundStyle(look.palette.accent)
                Spacer()
            }
        }
        .padding(14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("预览")
    }
}
