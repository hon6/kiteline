using static Kiteline.Lang;

namespace Kiteline.Model;

/// 时间、时长的写法（同 iOS 版 Model/Format.swift）。时间戳都是毫秒
public static class Format
{
    public static DateTime Date(double ms) => DateTimeOffset.FromUnixTimeMilliseconds((long)ms).LocalDateTime;

    static string Hm(DateTime d) => $"{d.Hour:00}:{d.Minute:00}";

    static int DaysAgo(DateTime d) => (DateTime.Today - d.Date).Days;

    static readonly string[] Weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"];
    static readonly string[] ShortWeekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

    /// 「15:06」
    public static string Clock(double ms) => Hm(Date(ms));

    /// 对话里隔了一阵的分隔：「09:30」「昨天 23:10」「星期三 14:02」「10月18日 14:02」
    public static string Separator(double ms)
    {
        var d = Date(ms);
        var days = DaysAgo(d);
        if (days == 0) return Hm(d);
        if (days == 1) return L("昨天 %@", Hm(d));
        if (days > 0 && days < 7) return $"{L(Weekdays[(int)d.DayOfWeek])} {Hm(d)}";
        if (d.Year == DateTime.Today.Year) return L("%@月%@日 %@", d.Month, d.Day, Hm(d));
        return L("%@年%@月%@日 %@", d.Year, d.Month, d.Day, Hm(d));
    }

    /// 每条消息下面的小字时间
    public static string MessageTime(double ms)
    {
        var d = Date(ms);
        var days = DaysAgo(d);
        if (days == 0) return Hm(d);
        if (days == 1) return L("昨天 %@", Hm(d));
        if (d.Year == DateTime.Today.Year) return L("%@月%@日 %@", d.Month, d.Day, Hm(d));
        return $"{d.Year}/{d.Month}/{d.Day} {Hm(d)}";
    }

    /// 会话列表右上角：今天写时分，昨天写「昨天」，一周内写星期，更早写日期
    public static string ListTime(double? ms)
    {
        if (ms is not double v || v <= 0) return "";
        var d = Date(v);
        var days = DaysAgo(d);
        if (days == 0) return Hm(d);
        if (days == 1) return L("昨天");
        if (days > 0 && days < 7) return L(Weekdays[(int)d.DayOfWeek]);
        return $"{d.Month}/{d.Day}";
    }

    /// Mac 侧栏会话行右上角（Format.short）：同 ListTime
    public static string Short(double? ms) => ListTime(ms);

    /// 用了多久：「45s」「3m 20s」「1h 5m」
    public static string Duration(int seconds)
    {
        if (seconds < 60) return $"{seconds}s";
        var m = seconds / 60;
        if (m < 60) return $"{m}m {seconds % 60}s";
        return $"{m / 60}h {m % 60}m";
    }

    /// 用量恢复时间：今天的只写时分，别的天带日期
    public static string ResetTime(double ms)
    {
        var d = Date(ms);
        return DaysAgo(d) == 0 ? Hm(d) : L("%@月%@日 %@", d.Month, d.Day, Hm(d));
    }

    /// 名字首字：英文取前两个字母，中文取第一个字
    public static string Initials(string title)
    {
        var text = title.Trim();
        if (text.Length == 0) return "?";
        var first = text[0];
        if (first < 128 && char.IsLetterOrDigit(first))
            return new string(text.Where(c => c < 128 && char.IsLetterOrDigit(c)).Take(2).ToArray()).ToUpperInvariant();
        return char.IsSurrogate(first) && text.Length > 1 ? text[..2] : first.ToString();
    }

    /// 「今天」「昨天」「10月18日」
    public static string Day(double ms)
    {
        var d = Date(ms);
        var days = DaysAgo(d);
        if (days == 0) return L("今天");
        if (days == 1) return L("昨天");
        return d.Year == DateTime.Today.Year ? L("%@月%@日", d.Month, d.Day) : L("%@年%@月%@日", d.Year, d.Month, d.Day);
    }

    /// 将来的时间：「今天 09:00」「明天 09:00」「10月22日 周三 09:00」
    public static string Future(double ms)
    {
        var d = Date(ms);
        var days = (d.Date - DateTime.Today).Days;
        if (days == 0) return L("今天 %@", Hm(d));
        if (days == 1) return L("明天 %@", Hm(d));
        return L("%@月%@日 %@ %@", d.Month, d.Day, L(ShortWeekdays[(int)d.DayOfWeek]), Hm(d));
    }

    /// 路径里的用户目录缩成 ~（/Users/x、/home/x、C:\Users\x）
    public static string ShortPath(string path) =>
        System.Text.RegularExpressions.Regex.Replace(path, @"^(/(Users|home)/[^/]+|[A-Za-z]:\\Users\\[^\\]+)", "~");

    public static double NowMs => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}
