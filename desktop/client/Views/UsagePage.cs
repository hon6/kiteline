using System.Globalization;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 主窗口右侧的「用量」（同 Mac 版 UsageReportView）：各台机器按天 / 模型 / 项目的 token 与花费（类似 ccusage）
public sealed class UsagePage : Panel
{
    static int days = 7;
    static JsonNode? payload;
    /// 各台电脑的订阅额度（同 Mac 版用量页顶上那一节）
    static List<LimitDevice> limits = [];
    readonly PageBar bar;
    readonly StackPanel body = new() { Spacing = 18 };
    DispatcherTimer? timer;
    int seq;

    public UsagePage()
    {
        var segmented = new Segmented([("1", L("今天")), ("7", L("7 天")), ("30", L("30 天"))], days.ToString(), id => { days = int.Parse(id); bar!.Subtitle = Subtitle; Load(); }, 200);
        bar = new PageBar(L("用量"), Subtitle, segmented, [PageBar.Button("arrow.clockwise", L("刷新"), () => Load(fresh: true))]);
        var scroll = new ScrollViewer { Content = new Border { Child = body, MaxWidth = 900, Padding = new Thickness(28, 22) }, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Children.Add(PageBar.Page(bar, scroll));
        if (payload is not null) Show(); else body.Children.Add(Ui.Stack(Orientation.Vertical, 10, Align.Center, [new Spinner(20), Ui.Text(L("正在统计各机器的用量…"), 13, color: "Text2")]).HAlign(HorizontalAlignment.Center).Margin(0, 80, 0, 0));
        AttachedToVisualTree += (_, _) =>
        {
            Load();
            timer = new DispatcherTimer(TimeSpan.FromSeconds(120), DispatcherPriority.Background, (_, _) => Load());
            timer.Start();
        };
        DetachedFromVisualTree += (_, _) => timer?.Stop();
    }

    static string Subtitle => days == 1 ? L("今天") : L("最近 %@ 天", days);

    async void Load(bool fresh = false)
    {
        var current = ++seq;
        try
        {
            var query = new Dictionary<string, string> { ["days"] = days.ToString() };
            if (fresh) query["fresh"] = "1";
            var reply = AppModel.Shared.Api.Get("/api/usage", query);
            var quota = AppModel.Shared.Api.Get("/api/limits", fresh ? new Dictionary<string, string> { ["fresh"] = "1" } : null);
            var usage = await reply;
            // 旧版电脑端没有额度接口：不显示那一节
            List<LimitDevice>? devices = null;
            try { devices = LimitDevice.ParseAll(await quota); } catch (Exception) { }
            if (current != seq) return;
            payload = usage;
            if (devices is not null) limits = devices;
            Show();
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
    }

    public static string Money(double value) =>
        value >= 1000 ? $"${(value / 1000).ToString("0.0", CultureInfo.InvariantCulture)}k" : value >= 100 ? $"${value:0}" : $"${value.ToString("0.00", CultureInfo.InvariantCulture)}";

    sealed record Row(string Name, string Detail, double Cost, double Estimated, double Requests, double Output, double CacheRead);

    static List<Row> Rows(string field) => payload.Arr(field).Items().Select(item =>
    {
        string name, detail;
        switch (field)
        {
            case "models": name = item.Str("model") ?? "unknown"; detail = L("%@ 次请求", (int)(item.Num("requests") ?? 0)); break;
            case "projects":
                name = item.Str("name") is { Length: > 0 } n ? n : L("（未知目录）");
                detail = $"{Lang.Machine(item.Str("sourceName") ?? "")} · {item.Str("cwd") ?? ""}";
                break;
            default: name = item.Str("name") ?? ""; detail = L("%@ 次请求", (int)(item.Num("requests") ?? 0)); break;
        }
        return new Row(name, detail, item.Num("cost") ?? 0, item.Num("estimated") ?? 0, item.Num("requests") ?? 0, item.Num("output") ?? 0, item.Num("cacheRead") ?? 0);
    }).ToList();

    void Show()
    {
        body.Children.Clear();
        // 订阅额度（各台电脑的 5 小时 / 本周）：侧栏卡片上那几条，这里字大一号、一台电脑一栏并排放
        if (limits.Count > 0)
            body.Children.Add(Ui.VFill(8, Ui.Text(L("订阅额度"), 12, FontWeight.SemiBold, "Text2"),
                Card.Make(new AdaptiveGrid(330, 32, LimitsBoard.Blocks(limits, compact: false)))));
        var t = payload.Obj("totals");
        double N(string k) => t.Num(k) ?? 0;
        var cost = N("cost"); var estimated = N("estimated");
        var input = N("input") + N("cacheRead") + N("cacheWrite");
        var tiles = new List<Control>();
        void Tile(string symbol, string value, string label, string detail)
        {
            var card = Card.Make(Ui.VFill(6, new DuoIcon(symbol, 26).HAlign(HorizontalAlignment.Left),
                Ui.H(4, Ui.Text(value, 24, FontWeight.Bold).Digits(), Ui.Text(label, 11.5, color: "Text2")),
                Ui.Text(detail, 11, color: "Text3").Trim()), 12, 14);
            tiles.Add(card);
        }
        Tile("dollarsign.circle", Money(cost), L("花费"), estimated > 0 ? L("含估算 %@", Money(estimated)) : L("Claude Code 记录"));
        Tile("arrow.up.arrow.down.circle", ((int)N("requests")).ToString(), L("次请求"), L("%@ 个模型", Rows("models").Count));
        Tile("text.word.spacing", UsageFormat.Compact(N("output")), L("输出 token"), L("输入 %@", UsageFormat.Compact(input)));
        Tile("internaldrive", UsageFormat.Compact(N("cacheRead")), L("读缓存"), L("写缓存 %@", UsageFormat.Compact(N("cacheWrite"))));
        body.Children.Add(new AdaptiveGrid(170, 10, tiles));
        if (days > 1)
        {
            var dayRows = payload.Arr("days").Items().Select(d => (Day: d.Str("day") ?? "", Cost: d.Num("cost") ?? 0, Estimated: d.Num("estimated") ?? 0)).ToList();
            // 图例（同 Swift Charts 按类型着色时下面自带的那行）
            Control Legend(string label, double opacity)
            {
                var dot = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Opacity = opacity }.Res(Border.BackgroundProperty, "Accent");
                return Ui.H(4, dot, Ui.Text(label, 10.5, color: "Text2"));
            }
            var chart = new Panel { Height = 200, Children = { new CostChart(dayRows, days) { Margin = new Thickness(0, 0, 0, 18) }, Ui.H(12, Legend(L("记录"), 1), Legend(L("估算"), 0.4)).VAlign(VerticalAlignment.Bottom) } };
            body.Children.Add(Card.Make(Ui.VFill(8, Ui.Text(L("每天花费"), 12, FontWeight.SemiBold, "Text2"), chart)));
        }
        Table(L("按模型"), Rows("models"), cost);
        Table(L("按项目"), Rows("projects").Take(12).ToList(), cost);
        if (Rows("sources").Count > 1) Table(L("按机器"), Rows("sources"), cost);
        body.Children.Add(Ui.Text(L("花费数据取自 Claude Code 记录的 cost-state（会话结束或恢复时写入）；进行中的会话按同一机器、同一模型的平均费率估算（图中浅色部分）。"), 11, color: "Text3", lines: 0).Wrap());
        foreach (var e in payload.Strings("errors"))
            body.Children.Add(Ui.H(6, Ui.Sym("exclamationmark.triangle", 11.5, "Text2"), Ui.Text(e, 11.5, color: "Text2", lines: 2).Wrap().Shrink()));
    }

    void Table(string title, List<Row> rows, double totalCost)
    {
        if (rows.Count == 0) return;
        var total = Math.Max(totalCost, 0.0001);
        var list = new StackPanel();
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var detail = Ui.Text(L("%@ · 输出 %@ · 读缓存 %@", row.Detail, UsageFormat.Compact(row.Output), UsageFormat.Compact(row.CacheRead)), 11, color: "Text2").Trim();
            detail.TextTrimming = TextTrimming.PrefixCharacterEllipsis;
            var ratio = Math.Min(1, row.Cost / total);
            var meter = new Grid { Height = 4, ColumnDefinitions = new ColumnDefinitions($"{ratio.ToString(CultureInfo.InvariantCulture)}*,{(1 - ratio).ToString(CultureInfo.InvariantCulture)}*") };
            var track = new Border { CornerRadius = new CornerRadius(2) }.Res(Border.BackgroundProperty, "Fill08");
            Grid.SetColumnSpan(track, 2);
            var fill = new Border { CornerRadius = new CornerRadius(2) }.Res(Border.BackgroundProperty, "Accent");
            meter.Children.Add(track);
            meter.Children.Add(fill);
            var line = Ui.H(12, Ui.VFill(3, Ui.Text(row.Name, 13, FontWeight.SemiBold).Trim(), detail, meter).Grow(), Ui.Text(Money(row.Cost), 13, FontWeight.SemiBold).Digits());
            list.Children.Add(line.Pad(0, 8));
            if (i < rows.Count - 1) list.Children.Add(Ui.Rule("Separator", 0.5));
        }
        body.Children.Add(Ui.VFill(8, Ui.Text(title, 12, FontWeight.SemiBold, "Text2"), Card.Make(list, 12, 14)));
    }
}

/// 格子按最小宽度自适应几列（同 SwiftUI 的 GridItem(.adaptive(minimum:))），同一行一样高
public sealed class AdaptiveGrid : Panel
{
    readonly double min, spacing;

    public AdaptiveGrid(double min, double spacing, IEnumerable<Control> items)
    {
        this.min = min;
        this.spacing = spacing;
        foreach (var i in items) Children.Add(i);
    }

    int Columns(double width) => Math.Max(1, (int)((width + spacing) / (min + spacing)));

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 800 : available.Width;
        var columns = Columns(width);
        var cell = (width - spacing * (columns - 1)) / columns;
        double total = 0, row = 0;
        for (var i = 0; i < Children.Count; i++)
        {
            Children[i].Measure(new Size(cell, double.PositiveInfinity));
            row = Math.Max(row, Children[i].DesiredSize.Height);
            if ((i + 1) % columns == 0 || i == Children.Count - 1) { total += row + (total > 0 ? spacing : 0); row = 0; }
        }
        return new Size(width, total);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var columns = Columns(final.Width);
        var cell = (final.Width - spacing * (columns - 1)) / columns;
        double y = 0;
        for (var start = 0; start < Children.Count; start += columns)
        {
            var row = Children.Skip(start).Take(columns).ToList();
            var h = row.Max(c => c.DesiredSize.Height);
            for (var k = 0; k < row.Count; k++) row[k].Arrange(new Rect(k * (cell + spacing), y, cell, h));
            y += h + spacing;
        }
        return final;
    }
}

/// 每天花费的柱状图：记录的是强调色，估算的叠在上面、浅一点（同 Mac 版用 Charts 画的那张）
public sealed class CostChart : Control
{
    readonly List<(string Day, double Cost, double Estimated)> days;
    readonly int range;

    public CostChart(List<(string Day, double Cost, double Estimated)> days, int range)
    {
        this.days = days;
        this.range = range;
    }

    public override void Render(DrawingContext context)
    {
        if (days.Count == 0) return;
        var w = Bounds.Width; var h = Bounds.Height;
        const double left = 4, bottom = 20, axis = 46;
        var plotW = w - left - axis; var plotH = h - bottom - 6;
        var max = Math.Max(days.Max(d => d.Cost), 0.01);
        // 刻度：取个整数步长，约 4 条横线
        var raw = max / 4;
        var magnitude = Math.Pow(10, Math.Floor(Math.Log10(raw)));
        var step = new[] { 1, 2, 2.5, 5, 10 }.Select(m => m * magnitude).First(s => s >= raw);
        var top = Math.Ceiling(max / step) * step;
        var grid = new Pen(Palette.Get("Fill10"), 1);
        var labelBrush = Palette.Get("Text2");
        var typeface = new Typeface(Look.Family);
        for (var v = 0.0; v <= top + 1e-9; v += step)
        {
            var y = 6 + plotH - v / top * plotH;
            context.DrawLine(grid, new Point(left, y), new Point(left + plotW, y));
            var text = new FormattedText(UsagePage.Money(v), CultureInfo.CurrentCulture, FlowDirection.LeftToRight, typeface, 10, labelBrush);
            context.DrawText(text, new Point(left + plotW + 6, y - text.Height / 2));
        }
        var slot = plotW / days.Count;
        var barW = Math.Max(2, slot * 0.62);
        var accent = Palette.GetColor("Accent");
        var solid = new SolidColorBrush(accent);
        var light = new SolidColorBrush(accent, 0.4);
        var every = range > 10 ? 5 : 1;
        for (var i = 0; i < days.Count; i++)
        {
            var (day, cost, estimated) = days[i];
            var x = left + i * slot + (slot - barW) / 2;
            var recorded = Math.Max(0, cost - estimated);
            var hRec = recorded / top * plotH;
            var hEst = Math.Max(0, estimated) / top * plotH;
            var baseY = 6 + plotH;
            if (hRec > 0) context.DrawRectangle(solid, null, new Rect(x, baseY - hRec, barW, hRec), 2, 2);
            if (hEst > 0) context.DrawRectangle(light, null, new Rect(x, baseY - hRec - hEst, barW, hEst), 2, 2);
            if (i % every == 0 && DateTime.TryParse(day, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            {
                var label = new FormattedText($"{date.Month}/{date.Day}", CultureInfo.CurrentCulture, FlowDirection.LeftToRight, typeface, 10, labelBrush);
                context.DrawText(label, new Point(left + i * slot + slot / 2 - label.Width / 2, baseY + 4));
            }
        }
    }
}
