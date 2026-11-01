import Foundation
import KitelineKit

/// Apple Watch 上的选项：存在 config.mobile.watch，手机 App（设置 → Apple Watch）和这里的设置窗口改的是同一份；
/// /api/state 里带给手机，手机转给手表。字段和 iOS 那边的 WatchPrefs（KitelineKit/Shared/WatchProtocol.swift）一一对应
struct WatchConfig: Codable, Equatable {
    /// 双指互点（Double Tap，Series 9 / Ultra 2 起）= 允许 / 批准 / 确认
    var doubleTap = true
    /// 确认框上也显示「总是允许」
    var alwaysAllow = false
    /// 危险命令（rm -rf、git push --force……）不能双击直接允许，要在手表上再确认一次
    var guardDanger = true
    /// 会话列表显示哪些：all 全部 / active 只看等你确认、出错、正在工作的
    var scope = "all"
    /// 不显示静音了的会话
    var hideMuted = false
    /// 显示花费（金额）
    var showCost = true
    /// 手表 App 开着时，有新的确认就震一下
    var haptics = true
    /// 手表上的快捷回复；空 = 用快捷短语
    var replies: [String] = []
    /// 主题色：phone = 跟 iPhone 上选的，或者某套主题的 id（见 KitelineKit/Views/Look.swift）
    var theme = "phone"
    /// 字体：phone = 跟 iPhone，或者 system / rounded / serif / kai / mono
    var font = "phone"
    /// 字号：watch = 跟手表自己的文字大小，或者 xs … xxxl
    var textSize = "watch"

    init() {}

    static func validTheme(_ id: String) -> Bool { id == "phone" || LookTheme.all.contains { $0.id == id } }
    static func validFont(_ id: String) -> Bool { id == "phone" || LookFont.all.contains { $0.id == id } }
    static func validSize(_ id: String) -> Bool { id == "watch" || LookSize.named(id) != nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WatchConfig()
        func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil ?? fallback }
        doubleTap = flag(.doubleTap, d.doubleTap)
        alwaysAllow = flag(.alwaysAllow, d.alwaysAllow)
        guardDanger = flag(.guardDanger, d.guardDanger)
        scope = (try? c.decodeIfPresent(String.self, forKey: .scope)) ?? nil ?? d.scope
        if !["all", "active"].contains(scope) { scope = "all" }
        hideMuted = flag(.hideMuted, d.hideMuted)
        showCost = flag(.showCost, d.showCost)
        haptics = flag(.haptics, d.haptics)
        replies = (try? c.decodeIfPresent([String].self, forKey: .replies)) ?? nil ?? d.replies
        theme = (try? c.decodeIfPresent(String.self, forKey: .theme)).flatMap { $0 }.flatMap { Self.validTheme($0) ? $0 : nil } ?? d.theme
        font = (try? c.decodeIfPresent(String.self, forKey: .font)).flatMap { $0 }.flatMap { Self.validFont($0) ? $0 : nil } ?? d.font
        textSize = (try? c.decodeIfPresent(String.self, forKey: .textSize)).flatMap { $0 }.flatMap { Self.validSize($0) ? $0 : nil } ?? d.textSize
    }

    /// 给手机的（/api/state、/api/watch）
    var payload: [String: Any] {
        ["doubleTap": doubleTap, "alwaysAllow": alwaysAllow, "guardDanger": guardDanger, "scope": scope,
         "hideMuted": hideMuted, "showCost": showCost, "haptics": haptics, "replies": replies,
         "theme": theme, "font": font, "textSize": textSize]
    }

    /// 手机发来的改动：只改带了的字段
    mutating func merge(_ body: [String: Any]) {
        if let v = body["doubleTap"] as? Bool { doubleTap = v }
        if let v = body["alwaysAllow"] as? Bool { alwaysAllow = v }
        if let v = body["guardDanger"] as? Bool { guardDanger = v }
        if let v = body["scope"] as? String, ["all", "active"].contains(v) { scope = v }
        if let v = body["hideMuted"] as? Bool { hideMuted = v }
        if let v = body["showCost"] as? Bool { showCost = v }
        if let v = body["haptics"] as? Bool { haptics = v }
        if let v = body["theme"] as? String, Self.validTheme(v) { theme = v }
        if let v = body["font"] as? String, Self.validFont(v) { font = v }
        if let v = body["textSize"] as? String, Self.validSize(v) { textSize = v }
        if let v = body["replies"] as? [Any] {
            // 手表屏幕小：最多 8 条，每条最多 40 字
            replies = Array(MobileConfig.cleanQuickReplies(v.compactMap { $0 as? String }.map { String($0.prefix(40)) }).prefix(8))
        }
    }

    /// 手表快捷回复的建议（设置里「用推荐的」）
    static let suggestedReplies = ["继续", "按此方案执行", "暂停，等我回来", "说明你的计划", "运行测试"]
}

/// 一台手机报上来的手表状态（手机打开 Kiteline、手表配对状态变了时报一次）
struct WatchState: Codable, Equatable {
    /// 这台手机配了 Apple Watch
    var paired: Bool
    /// 手表上装了 Kiteline
    var installed: Bool
    /// 表盘上放了 Kiteline 的复杂功能
    var complication: Bool?
    /// 手机报这份状态的时间（毫秒）
    var updatedAt: Double
    /// 手表最近一次经这台手机来要数据、点按钮的时间（毫秒）
    var lastUsed: Double?

    var label: String {
        if !paired { return "未配对 Apple Watch" }
        if !installed { return "Apple Watch 尚未安装 Kiteline" }
        if let lastUsed, lastUsed > 0 { return "Apple Watch 已装 Kiteline · 最近使用 \(Format.short(lastUsed))" }
        return "Apple Watch 已装 Kiteline"
    }
}
