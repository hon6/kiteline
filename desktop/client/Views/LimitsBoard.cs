using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 订阅额度（/api/limits）的一个窗口：5 小时、本周，或别的（Codex 免费版 30 天一个窗口、网关的花费上限）
public sealed record LimitWindow(string Kind, double Percent, double? ResetsAt, int? Minutes, bool Reset)
{
    public static LimitWindow Parse(JsonNode n)
    {
        var window = new LimitWindow(n.Str("kind") ?? "", n.Num("percent") ?? 0, n.Num("resetsAt"), n.Int("minutes"), n.Bool("reset") ?? false);
        // 电脑暂时连不上时给的是记住的旧读数：过了重置时间的额度已经回来了
        return window.ResetsAt is double at && at <= DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
            ? window with { Percent = 0, ResetsAt = null, Reset = true } : window;
    }

    public string Label => Kind switch
    {
        "five_hour" => L("5 小时"),
        "seven_day" => L("本周"),
        "spend_limit" => L("额度"),
        _ => (Minutes ?? 0) switch
        {
            >= 1440 => L("%@ 天", Minutes!.Value / 1440),
            > 0 => L("%@ 小时", Math.Max(1, Minutes!.Value / 60)),
            _ => L("额度"),
        },
    };

    /// 「5 小时 · 22:10 重置」
    public string Caption => ResetText.Length == 0 ? Label : $"{Label} · {ResetText}";

    /// 「22:10 重置」「明天 03:00 重置」「11月7日 重置」；不知道什么时候重置时为空
    public string ResetText
    {
        get
        {
            if (Reset) return L("已重置");
            if (ResetsAt is not double at) return "";
            var date = Format.Date(at);
            var time = Format.Clock(at);
            if (date.Date == DateTime.Today) return L("%@ 重置", time);
            if (date.Date == DateTime.Today.AddDays(1)) return L("%@ 重置", L("明天 %@", time));
            return L("%@ 重置", L("%@月%@日", date.Month, date.Day));
        }
    }

    /// 平时主题色，用到八成起红色（同 Mac 版）
    public string Tint => Percent >= 80 ? "Red" : "Accent";
}

/// pending：还没有读数，这台电脑上开着的会话都是额度插件装上之前启动的，新开一个会话回复后才有
public sealed record LimitAgent(string Agent, double At, string? Plan, List<LimitWindow> Windows, bool Pending)
{
    public static LimitAgent Parse(JsonNode n) =>
        new(n.Str("agent") ?? "claude-code", n.Num("at") ?? 0, n.Str("plan"), n.Arr("windows").Items().Select(LimitWindow.Parse).ToList(),
            n.Bool("pending") ?? false);

    /// 两格：第一格 5 小时、第二格每周；没有这两种窗口的按顺序补上
    public LimitWindow?[] Slots
    {
        get
        {
            var rest = Windows.Where(w => w.Kind != "five_hour" && w.Kind != "seven_day").GetEnumerator();
            LimitWindow? Next() => rest.MoveNext() ? rest.Current : null;
            var first = Windows.FirstOrDefault(w => w.Kind == "five_hour") ?? Next();
            var second = Windows.FirstOrDefault(w => w.Kind == "seven_day") ?? Next();
            return [first, second];
        }
    }
}

public sealed record LimitDevice(string SourceId, string Name, bool Local, List<LimitAgent> Agents)
{
    public static List<LimitDevice> ParseAll(JsonNode? reply) =>
        reply.Arr("devices").Items().Select(n => new LimitDevice(n.Str("sourceId") ?? "", n.Str("name") ?? "", n.Bool("local") ?? false,
                                                                  n.Arr("agents").Items().Select(LimitAgent.Parse).ToList())).ToList();
}

/// 一条额度：上面一行「5 小时 · 22:10 重置」和已用百分比，下面一根横条（同 Mac 版 LimitBar，10-31：不要环形）
public sealed class LimitBar : Panel
{
    public LimitBar(LimitWindow window, bool compact)
    {
        // 放不下时整行等比缩小（同 Mac 版 minimumScaleFactor），别截成「13:02 …」
        var caption = new Viewbox
        {
            Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Left,
            Child = Ui.Text(window.Caption, compact ? 10.5 : 11.5, color: "Text2"),
        };
        var head = Ui.H(4,
            caption.Shrink(),
            new Spacer(4),
            Ui.Text($"{Math.Round(window.Percent):0}%", compact ? 12 : 13, FontWeight.SemiBold, window.Percent >= 80 ? window.Tint : "Text").Digits());
        Children.Add(Ui.VFill(4, head, new LimitTrack(window.Percent / 100, compact ? 5 : 6, window.Tint)));
        ToolTip.SetTip(this, $"{window.Caption} {Math.Round(window.Percent):0}%");
    }
}

/// 横条本身：灰色底条 + 主题色（八成起红色）已用部分，两头圆
sealed class LimitTrack : Control
{
    readonly double ratio;
    readonly string tint;

    public LimitTrack(double ratio, double height, string tint)
    {
        this.ratio = Math.Clamp(ratio, 0, 1);
        this.tint = tint;
        Height = height;
    }

    public override void Render(DrawingContext context)
    {
        var h = Bounds.Height;
        var radius = h / 2;
        context.DrawRectangle(Palette.Get("Fill08"), null, new Rect(0, 0, Bounds.Width, h), radius, radius);
        if (ratio <= 0) return;
        context.DrawRectangle(Palette.Get(tint), null, new Rect(0, 0, Math.Max(h, Bounds.Width * ratio), h), radius, radius);
    }
}

/// 额度面板：每台电脑每家 agent 一块——上面一行左边电脑名、右边 agent，下面「5 小时」「本周」两条各占一半并排（同 Mac 版，10-31）。
/// 侧栏大卡片、用量页共用
public static class LimitsBoard
{
    /// 每台电脑每家 agent 一块（用量页把它们并排放）
    public static List<Control> Blocks(List<LimitDevice> devices, bool compact) =>
        devices.SelectMany(d => d.Agents.Select(a => Block(d, a, compact))).ToList();

    /// compact：侧栏那样的窄处，字小一号
    public static Control Make(List<LimitDevice> devices, bool compact = true)
    {
        var stack = Ui.VFill(10);
        foreach (var block in Blocks(devices, compact))
        {
            if (stack.Children.Count > 0) stack.Children.Add(new Border { Height = 1, Opacity = 0.6 }.Res(Border.BackgroundProperty, "Separator"));
            stack.Children.Add(block);
        }
        return stack;
    }

    static Control Block(LimitDevice device, LimitAgent agent, bool compact)
    {
        var plan = string.IsNullOrEmpty(agent.Plan) ? "" : " · " + char.ToUpperInvariant(agent.Plan[0]) + agent.Plan[1..];
        var head = Ui.H(5,
            Ui.Sym(device.Local ? "laptopcomputer" : "server.rack", 11, "Text2"),
            Ui.Text(device.Name, compact ? 12 : 13, FontWeight.Medium, "Text2").Trim().Shrink(),
            new Spacer(6),
            // 读数是多久前的（旧了说明那台电脑一阵子没回复，额度可能已经变了）
            agent.At > 0 ? Ui.Text(Relative(agent.At), 11, color: "Text3") : null,
            new AgentGlyph(agent.Agent, compact ? 13 : 14, "Text"),
            Ui.Text(Kiteline.Model.Agents.Info(agent.Agent).Name + plan, compact ? 12.5 : 13.5, FontWeight.SemiBold).Trim());
        if (agent.Pending)
            return Ui.VFill(8, head, Ui.Text(L("已开着的会话不记额度，新开一个会话回复后显示"), compact ? 10.5 : 11.5, color: "Text2").Wrap());
        var bars = new EqualRow(compact ? 10 : 14, agent.Slots.Select(w => w is null ? (Control)new Border() : new LimitBar(w, compact)).ToArray());
        return Ui.VFill(8, head, bars);
    }

    static string Relative(double? ms)
    {
        if (ms is not double t || t <= 0) return "";
        var span = DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeMilliseconds((long)t);
        if (span.TotalSeconds < 60) return L("刚刚");
        if (span.TotalMinutes < 60) return L("%@ 分钟前", (int)span.TotalMinutes);
        if (span.TotalHours < 24) return L("%@ 小时前", (int)span.TotalHours);
        return Format.Short(t);
    }
}

/// 侧栏「今日用量」大卡片（同 Mac 版 SidebarLimitsTile，10-31）：右上角今天的 token 总数，下面各台电脑的额度条，花费这些明细点进去看；
/// 还没有额度读数时退回一行今天的花费
public sealed class SidebarLimitsTile : Tap
{
    /// tokens：右上角今天各台电脑一共用了多少 token（空 = 不显示）
    public SidebarLimitsTile(List<LimitDevice> devices, string tokens, string fallback, MainModel main) : base(null, () => main.Selection = MainModel.UsageId, 12)
    {
        var selected = main.Selection == MainModel.UsageId;
        Padding = new Thickness(10);
        if (selected) { Keys("AccentFill16", "AccentFill16"); BorderThickness = new Thickness(1); this.Res(BorderBrushProperty, "AccentEdge40"); }
        else Keys("Fill05", "Fill08");
        var head = Ui.H(6, new DuoIcon("chart.bar.fill", 28), Ui.Text(L("今日用量"), 13, FontWeight.SemiBold).Trim(), new Spacer(6),
                        tokens.Length == 0 ? null : Ui.Text(tokens, 13, FontWeight.SemiBold).Digits(),
                        Ui.Sym("chevron.right", 11, "Text3"));
        Child = Ui.VFill(10, head, devices.Count == 0 ? Ui.Text(fallback, 11, color: "Text2").Trim() : LimitsBoard.Make(devices));
    }
}
