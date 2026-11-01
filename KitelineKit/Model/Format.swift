import Foundation

/// 时间、时长的中文写法（和手机网页一致）。时间戳都是毫秒
enum Format {
    private static let calendar = Calendar.current

    private static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    private static func hm(_ d: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 「15:06」
    static func clock(_ ms: Double) -> String { hm(date(ms)) }

    /// 对话里隔了半小时以上的分隔：「今天 09:30」「昨天 23:10」「10月18日 14:02」
    static func separator(_ ms: Double) -> String {
        let d = date(ms)
        if calendar.isDateInToday(d) { return hm(d) }
        if calendar.isDateInYesterday(d) { return L("昨天 %@", "\(hm(d))") }
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: d)
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: Date())).day, days < 7 {
            let names = ["", L("星期日"), L("星期一"), L("星期二"), L("星期三"), L("星期四"), L("星期五"), L("星期六")]
            return "\(names[c.weekday ?? 0]) \(hm(d))"
        }
        if c.year == calendar.component(.year, from: Date()) { return L("%@月%@日 %@", "\(c.month ?? 0)", "\(c.day ?? 0)", "\(hm(d))") }
        return L("%@年%@月%@日 %@", "\(c.year ?? 0)", "\(c.month ?? 0)", "\(c.day ?? 0)", "\(hm(d))")
    }

    /// 每条消息下面的小字时间
    static func messageTime(_ ms: Double) -> String {
        let d = date(ms)
        if calendar.isDateInToday(d) { return hm(d) }
        if calendar.isDateInYesterday(d) { return L("昨天 %@", "\(hm(d))") }
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        if c.year == calendar.component(.year, from: Date()) { return L("%@月%@日 %@", "\(c.month ?? 0)", "\(c.day ?? 0)", "\(hm(d))") }
        return "\(c.year ?? 0)/\(c.month ?? 0)/\(c.day ?? 0) \(hm(d))"
    }

    /// 会话列表右上角：今天写时分，昨天写「昨天」，一周内写星期，更早写日期
    static func listTime(_ ms: Double?) -> String {
        guard let ms, ms > 0 else { return "" }
        let d = date(ms)
        if calendar.isDateInToday(d) { return hm(d) }
        if calendar.isDateInYesterday(d) { return L("昨天") }
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: d)
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: Date())).day, days < 7 {
            return ["", L("星期日"), L("星期一"), L("星期二"), L("星期三"), L("星期四"), L("星期五"), L("星期六")][c.weekday ?? 0]
        }
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// 用了多久：「45s」「3m 20s」「1h 5m」（和 Claude Code 里一样）
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        if m < 60 { return "\(m)m \(seconds % 60)s" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// 用量恢复时间：今天的只写时分，别的天带日期
    static func resetTime(_ ms: Double) -> String {
        let d = date(ms)
        if calendar.isDateInToday(d) { return hm(d) }
        let c = calendar.dateComponents([.month, .day], from: d)
        return L("%@月%@日 %@", "\(c.month ?? 0)", "\(c.day ?? 0)", "\(hm(d))")
    }

    /// 名字首字：英文取前两个字母，中文取第一个字
    static func initials(_ title: String) -> String {
        let text = title.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "?" }
        if first.isASCII, first.isLetter || first.isNumber {
            let letters = text.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            return String(letters.prefix(2)).uppercased()
        }
        return String(first)
    }
}

enum DayLabel {
    /// 「今天」「昨天」「10月18日」
    static func of(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(d) { return L("今天") }
        if calendar.isDateInYesterday(d) { return L("昨天") }
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return c.year == calendar.component(.year, from: Date()) ? L("%@月%@日", "\(c.month ?? 0)", "\(c.day ?? 0)") : L("%@年%@月%@日", "\(c.year ?? 0)", "\(c.month ?? 0)", "\(c.day ?? 0)")
    }

    /// 将来的时间：「今天 09:00」「明天 09:00」「10月22日 周三 09:00」
    static func future(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let calendar = Calendar.current
        let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: d)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDateInToday(d) { return L("今天 %@", "\(hm)") }
        if calendar.isDateInTomorrow(d) { return L("明天 %@", "\(hm)") }
        let week = ["", L("周日"), L("周一"), L("周二"), L("周三"), L("周四"), L("周五"), L("周六")][c.weekday ?? 0]
        return L("%@月%@日 %@ %@", "\(c.month ?? 0)", "\(c.day ?? 0)", "\(week)", "\(hm)")
    }
}
