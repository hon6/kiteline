using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 「今日动态」（同 Mac 版 TodayView）：今天（昨天、近 7 天）每个项目做了什么，包括已经关掉的会话。
/// 顶上：标题和概况、今天 / 昨天 / 近 7 天、刷新、推送日报；下面 5 格统计，再往下每个会话一张卡片
public sealed class TodayPage : Panel
{
    public static string Range { get; set; } = "today";
    readonly PageBar bar;
    readonly StackPanel body = new() { Spacing = 18 };
    DispatcherTimer? timer;
    int token;

    public TodayPage()
    {
        var segmented = new Segmented([("today", L("今天")), ("yesterday", L("昨天")), ("week", L("近 7 天"))], Range, id => { Range = id; Load(); });
        bar = new PageBar(L("今日动态"), L("正在汇总"), segmented, [
            PageBar.Button("arrow.clockwise", L("重新汇总"), () => Load(fresh: true)),
            PageBar.Button("paperplane", L("立即将今日日报推送到手机"), Push),
        ]);
        var scroll = new ScrollViewer { Content = new Border { Child = body, MaxWidth = 900, Padding = new Thickness(28, 22) }, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Children.Add(PageBar.Page(bar, scroll));
        body.Children.Add(new Spinner(20).HAlign(HorizontalAlignment.Center).Margin(0, 80, 0, 0));
        AttachedToVisualTree += (_, _) =>
        {
            Load();
            // 开着时每分钟再汇总一次（来源刚连上那一下的「未连接」不会一直挂着）
            timer = new DispatcherTimer(TimeSpan.FromSeconds(60), DispatcherPriority.Background, (_, _) => Load());
            timer.Start();
        };
        DetachedFromVisualTree += (_, _) => timer?.Stop();
    }

    static (long Since, long? Until) Bounds()
    {
        var today = new DateTimeOffset(DateTime.Today).ToUnixTimeMilliseconds();
        return Range switch
        {
            "yesterday" => (today - 86_400_000, today),
            "week" => (today - 6 * 86_400_000, null),
            _ => (today, null),
        };
    }

    async void Load(bool fresh = false)
    {
        var current = ++token;
        var (since, until) = Bounds();
        var query = new Dictionary<string, string> { ["since"] = since.ToString() };
        if (until is long u) query["until"] = u.ToString();
        if (fresh) query["fresh"] = "1";
        try
        {
            var report = await AppModel.Shared.Api.Get("/api/digest", query);
            if (current != token) return;
            Show(report);
        }
        catch (Exception e) { if (current == token) AppModel.Shared.Flash(e.Message); }
    }

    async void Push()
    {
        AppModel.Shared.Flash(L("正在汇总…"));
        try
        {
            var reply = await AppModel.Shared.Api.Post("/api/digest/push");
            AppModel.Shared.Flash(reply.Str("message") ?? L("已推送"));
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
    }

    static string RangeLabel => Range switch { "yesterday" => L("昨天"), "week" => L("近 7 天"), _ => L("今天") };

    void Show(JsonNode? report)
    {
        body.Children.Clear();
        var totals = report.Obj("totals");
        var sessions = report.Arr("sessions").Items().ToList();
        var errors = report.Strings("errors");
        bar.Subtitle = sessions.Count == 0 ? L("没有动态") : L("%@ 个会话 · %@ 个项目", totals.Int("sessions") ?? 0, totals.Int("projects") ?? 0);
        body.Children.Add(new StatsGrid(totals));
        if (sessions.Count == 0)
            body.Children.Add(EmptyHint.Make("sun.haze", L("%@暂无动态", RangeLabel), errors.Count == 0
                ? L("Claude Code 产生对话后，此处将按会话汇总：对话轮数、改动文件、运行的测试及发送的截图。")
                : L("以下来源尚未连接，连接后将自动刷新。")));
        foreach (var s in sessions) body.Children.Add(DigestCard(s));
        foreach (var e in errors) body.Children.Add(Ui.H(6, Ui.Sym("exclamationmark.triangle", 11.5, "Text2"), Ui.Text(e, 11.5, color: "Text2", lines: 2).Wrap().Shrink()));
        if (report.Num("generatedAt") is double at)
            body.Children.Add(Ui.Text(L("生成于 %@，统计所有在线来源，包括已关闭的会话。", Format.Short(at)), 11, color: "Text3"));
    }

    /// 一个会话做了什么（同 Mac 版 DigestCard）：标题、机器 · 项目 · 时间段、状态、打开对话；几个小标签；最后一句结论；改了哪些文件；最近一次测试；截图
    static Control DigestCard(JsonNode s)
    {
        var title = s.Str("title") is { Length: > 0 } t ? t : Path.GetFileName((s.Str("cwd") ?? "").TrimEnd('/')) is { Length: > 0 } f ? f : L("会话");
        var key = s.Str("key");
        var activity = s.Str("activity");
        var folder = Path.GetFileName((s.Str("cwd") ?? "").TrimEnd('/'));
        var span = "";
        if (s.Num("firstAt") is double a && s.Num("lastAt") is double b) { var x = Format.Clock(a); var y = Format.Clock(b); span = x == y ? x : $"{x}–{y}"; }
        var (badge, badgeColor) = key is null ? (L("已结束"), "Text2") : activity switch
        {
            "waiting" => (L("等你确认"), "Orange"),
            "busy" => (L("进行中"), "Accent"),
            _ => (L("空闲"), "Green"),
        };
        var badgeView = new Border { Padding = new Thickness(7, 3), CornerRadius = new CornerRadius(10), Child = Ui.Text(badge, 10.5, FontWeight.Medium, badgeColor) };
        badgeView.Background = new SolidColorBrush(Palette.GetColor(badgeColor), 0.12);
        var head = Ui.HTop(10,
            new SessionAvatar(title, key is null ? "unknown" : activity ?? "idle", 34),
            Ui.VFill(2, Ui.Text(title, 14, FontWeight.SemiBold).Trim(),
                Ui.H(4, Ui.Sym(s.Str("sourceId") == "local" ? "laptopcomputer" : "server.rack", 11, "Text2"),
                    Ui.Text(string.Join(" · ", new[] { Lang.Machine(s.Str("sourceName") ?? ""), folder, span }.Where(p => p.Length > 0)), 11, color: "Text2").Shrink())).Grow(),
            badgeView.Self(Align.Center),
            key is null ? null : new GlassButton(L("打开对话"), null, () => MainModel.Shared.Selection = key, height: 24).Self(Align.Center));
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(head);
        // 小标签：一排放不下就整个标签换到下一行
        var chips = new WrapPanel();
        void Chip(string symbol, string text, string tint = "Text2")
        {
            var c = new Border { Padding = new Thickness(8, 3), CornerRadius = new CornerRadius(10), Margin = new Thickness(0, 0, 6, 6), Child = Ui.H(4, Ui.Sym(symbol, 11, tint), Ui.Text(text, 11, color: tint)) };
            c.Res(Border.BackgroundProperty, "Fill05");
            chips.Children.Add(c);
        }
        var tests = s.Obj("tests");
        Chip("bubble.left", L("%@ 轮", s.Int("prompts") ?? 0));
        if ((s.Int("fileCount") ?? 0) > 0) Chip("doc.text", L("%@ 个文件", s.Int("fileCount")));
        if ((tests.Int("runs") ?? 0) > 0)
        {
            var failed = tests.Int("failed") ?? 0;
            Chip(failed > 0 ? "xmark.seal" : "checkmark.seal", failed > 0 ? L("测试 %@ 次 · %@ 失败", tests.Int("runs"), failed) : L("测试 %@ 次", tests.Int("runs")), failed > 0 ? "Red" : "Green");
        }
        if ((s.Int("images") ?? 0) > 0) Chip("photo", L("%@ 张截图", s.Int("images")));
        if ((s.Int("outputTokens") ?? 0) > 0) Chip("text.word.spacing", UsageFormat.Compact(s.Int("outputTokens") ?? 0) + " token");
        stack.Children.Add(chips);
        if (s.Arr("conclusions").Items().LastOrDefault() is JsonNode note && note.Str("text") is string conclusion)
        {
            var text = new SelectableTextBlock { Text = Plain(conclusion), FontSize = Look.Pt(12.5), TextWrapping = TextWrapping.Wrap, MaxLines = 5, TextTrimming = TextTrimming.CharacterEllipsis };
            text.Res(TextBlock.ForegroundProperty, "Text");
            stack.Children.Add(Ui.Box(text, new Thickness(10), "Fill03", 10).HAlign(HorizontalAlignment.Stretch));
        }
        var files = s.Arr("files").Items().ToList();
        if (files.Count > 0) stack.Children.Add(Files(files, s.Int("fileCount") ?? files.Count));
        if (tests.Arr("last").Items().FirstOrDefault() is JsonNode run)
        {
            var ok = run.Bool("ok");
            stack.Children.Add(Ui.H(6,
                Ui.Sym(ok == false ? "xmark.circle.fill" : ok == true ? "checkmark.circle.fill" : "circle.dashed", 11.5, ok == false ? "Red" : ok == true ? "Green" : "Text2"),
                Ui.Text(L("最近一次测试：%@", run.Str("description") ?? run.Str("command") ?? ""), 11.5).Shrink(),
                run.Int("passed") is int p ? Ui.Text(L("%@ 通过", p), 11.5, color: "Green") : null,
                run.Int("failed") is int n && n > 0 ? Ui.Text(L("%@ 失败", n), 11.5, color: "Red") : null));
        }
        var shots = s.Arr("shots").Items().ToList();
        if (shots.Count > 0)
        {
            var strip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            foreach (var shot in shots)
            {
                var cell = new Border { Width = 132, Height = 88, CornerRadius = new CornerRadius(9), ClipToBounds = true };
                cell.Res(Border.BackgroundProperty, "Fill06");
                cell.Tip(shot.Str("caption"));
                var query = new Dictionary<string, string> { ["source"] = s.Str("sourceId") ?? "", ["sid"] = s.Str("sessionId") ?? "", ["ref"] = shot.Str("ref") ?? "", ["thumb"] = "300" };
                ImageCache.Load("/api/digest/media", query, bitmap => cell.Child = new Image { Source = bitmap, Stretch = Stretch.UniformToFill, Width = 132, Height = 88 });
                strip.Children.Add(cell);
            }
            stack.Children.Add(new ScrollViewer { Content = strip, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled });
        }
        return Card.Make(stack);
    }

    static Control Files(List<JsonNode> files, int total)
    {
        var stack = new StackPanel { Spacing = 3 };
        var all = false;
        void Build()
        {
            stack.Children.Clear();
            foreach (var file in all ? files : files.Take(5))
            {
                var edits = file.Int("edits") ?? 1;
                var path = Ui.Text(file.Str("path") ?? "", 11).Mono().Shrink();
                path.TextTrimming = TextTrimming.PrefixCharacterEllipsis;
                stack.Children.Add(Ui.H(6, Ui.Sym("pencil.line", 9, "Text3"), path, edits > 1 ? Ui.Text($"×{edits}", 10, color: "Text3") : null));
            }
            var shown = all ? files.Count : Math.Min(5, files.Count);
            if (total > shown || all)
                stack.Children.Add(new Tap(Ui.Text(all ? L("收起") : L("另有 %@ 个文件", total - shown), 11, color: "Accent"), () => { all = !all; Build(); }, 4).HAlign(HorizontalAlignment.Left));
        }
        Build();
        return stack;
    }

    /// 结论文本去掉最常见的 markdown 标记，卡片里只看纯文字
    static string Plain(string text)
    {
        var o = text.Replace("**", "").Replace("`", "");
        o = Regex.Replace(o, @"\[([^\]]+)\]\([^)]*\)", "$1");
        o = Regex.Replace(o, @"(?m)^#{1,6}\s*", "");
        return o.Trim();
    }
}

/// 5 格统计（同 Mac 版 StatsGrid）：够宽一排 5 个，窄了 3 + 2
public sealed class StatsGrid : Panel
{
    readonly List<Control> tiles = [];

    public StatsGrid(JsonNode? t)
    {
        var testRuns = t.Int("testRuns") ?? 0; var failed = t.Int("testFailed") ?? 0;
        tiles.Add(Tile("bubble.left.and.bubble.right", (t.Int("prompts") ?? 0).ToString(), L("轮对话"), L("%@ 个会话", t.Int("sessions") ?? 0)));
        tiles.Add(Tile("doc.badge.ellipsis", (t.Int("files") ?? 0).ToString(), L("个文件改动"), L("%@ 个项目", t.Int("projects") ?? 0)));
        tiles.Add(Tile(failed > 0 ? "xmark.seal" : "checkmark.seal", testRuns.ToString(), L("次测试"), testRuns == 0 ? L("未运行测试") : failed > 0 ? L("%@ 次失败", failed) : L("全部通过")));
        tiles.Add(Tile("photo.on.rectangle", (t.Int("images") ?? 0).ToString(), L("张截图"), L("Claude 发来的")));
        tiles.Add(Tile("text.word.spacing", UsageFormat.Compact(t.Int("outputTokens") ?? 0), L("输出 token"), L("%@ 次请求", t.Int("requests") ?? 0)));
        foreach (var tile in tiles) Children.Add(tile);
    }

    // 数字下面再写是什么：一排 5 格时每格只有一百来点宽，数字和说明并排会挤
    static Control Tile(string symbol, string value, string label, string detail) =>
        Card.Make(Ui.VFill(4, new DuoIcon(symbol, 26).Margin(0, 0, 0, 4).HAlign(HorizontalAlignment.Left), Ui.Text(value, 24, FontWeight.Bold).Digits().Trim(),
            Ui.Text(label, 12, color: "Text2").Trim(), Ui.Text(detail, 11, color: "Text3").Trim()), 12, 14);

    int Columns(double width) => width >= 560 ? 5 : 3;

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 800 : available.Width;
        var columns = Columns(width);
        var cell = (width - 10 * (columns - 1)) / columns;
        double rowH = 0, total = 0;
        for (var i = 0; i < tiles.Count; i++)
        {
            tiles[i].Measure(new Size(cell, double.PositiveInfinity));
            rowH = Math.Max(rowH, tiles[i].DesiredSize.Height);
            if ((i + 1) % columns == 0 || i == tiles.Count - 1) { total += rowH + (total > 0 ? 10 : 0); rowH = 0; }
        }
        return new Size(width, total);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var columns = Columns(final.Width);
        var cell = (final.Width - 10 * (columns - 1)) / columns;
        double y = 0;
        for (var start = 0; start < tiles.Count; start += columns)
        {
            var row = tiles.Skip(start).Take(columns).ToList();
            var h = row.Max(x => x.DesiredSize.Height);
            for (var k = 0; k < row.Count; k++) row[k].Arrange(new Rect(k * (cell + 10), y, cell, h));
            y += h + 10;
        }
        return final;
    }
}
