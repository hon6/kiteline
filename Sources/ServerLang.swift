import Foundation
import KitelineKit

/// 日报、早安简报这类由许多小段拼起来的话：整句查表配不上，在源头按语言拼。
/// `let p = Phrase(english: true)`；`p("%lld 个会话", n)`、`p.list`（「、」/「, 」）这些分隔符也跟着语言
struct Phrase {
    let english: Bool

    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        let format = english ? Lang.shared.english(key) : key
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: english ? "en" : "zh-Hans"), arguments: arguments)
    }

    var list: String { english ? ", " : "、" }
    var comma: String { english ? ", " : "，" }
    var semicolon: String { english ? "; " : "；" }
    var colon: String { english ? ": " : "：" }
}

/// 电脑生成、发给手机的字按「看的那台设备」的语言出：手机每个请求都带 X-Kiteline-Lang（zh / en），
/// 和这台电脑自己的界面语言无关（电脑是中文、手机是英文很常见）。
///
/// 服务端照旧用中文拼字，发出去之前在出口这里换成英文（中文的设备原样发）：
/// - 出口只有三处：HTTP 回复（MobileServer.route 的 respond）、实时事件（broadcast）、锁屏推送（pushLocalized）
/// - 只换界面文字那几个字段（error、detail、activityText……），会话标题、Claude 的回复这类内容不动
/// - 一句话先整句查表；查不到再用表里带占位符的键反推（「已连接 虚拟机」← 「已连接 %@」），变量部分也查一遍
/// 表就是界面用的那张（en.lproj/Localizable.strings，由 i18n/en.json 生成）：服务端的字由 tools/i18n.py 一并抽进去
enum ServerLang {
    static func of(_ request: HTTPRequest) -> String {
        request.headers["x-kiteline-lang"] == "en" ? "en" : "zh"
    }

    /// Mac 自己的界面上显示服务端生成的字（来源状态、服务状态、权限名……）：按这台 Mac 的界面语言换
    static func ui(_ text: String) -> String {
        Lang.shared.isEnglish ? translate(text) : text
    }

    // 查表、反推、换字段的本事在共用的 ServerText（KitelineKit/Shared/Lang.swift），iPhone 的演示模式也用它
    static var fields: Set<String> { ServerText.fields }
    static func machine(_ name: String, english: Bool = Lang.shared.isEnglish) -> String { ServerText.machine(name, english: english) }
    static func translate(_ text: String) -> String { ServerText.translate(text) }
    static func localize(_ object: Any, extra: Set<String> = []) -> Any { ServerText.localize(object, extra: extra) }
    static func localize(json data: Data, extra: Set<String> = []) -> Data { ServerText.localize(json: data, extra: extra) }

    /// 对话记录（/api/history 的回复、实时的 entries）是内容、整体不翻；只换其中电脑生成的事件提示（「接口出错：…」「上下文已压缩」）
    static func localizeEvents(json data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["items"] as? [[String: Any]], items.contains(where: { $0["t"] as? String == "event" }) else { return data }
        object["items"] = items.map { item -> [String: Any] in
            guard item["t"] as? String == "event", let text = item["text"] as? String else { return item }
            var copy = item
            copy["text"] = translate(text)
            return copy
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
    }
}
