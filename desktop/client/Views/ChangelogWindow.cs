using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 更新记录里的一个版本（同 Mac 版 ChangelogRelease）：「## 1.0.8（2026-10-24）」，下面按「### 新功能 / 改进 / 问题修复 / 安全」分类列条目
public sealed class ChangelogRelease
{
    public required string Version { get; init; }
    /// 「2026-10-24」；没写日期的为空
    public required string Date { get; init; }
    /// 分类之前的说明段落
    public List<string> Notes { get; } = [];
    public List<(string Title, List<ChangelogItem> Items)> Sections { get; } = [];
}

public sealed class ChangelogItem
{
    /// 条目原文（续行已接上）：「**标题**：说明」或一整句
    public string Raw = "";
    public List<string> Details { get; } = [];

    /// 「**标题**：说明」拆成标题和说明；标题后紧跟的「（Windows、Linux）」算标题的一部分。没有加粗标题的整条都是说明
    public (string? Title, string Body) Parts
    {
        get
        {
            var close = Raw.StartsWith("**") ? Raw.IndexOf("**", 2, StringComparison.Ordinal) : -1;
            if (close < 0) return (null, Raw);
            var title = Raw[2..close];
            var rest = Raw[(close + 2)..];
            var tag = rest.TrimStart(' ');
            if (tag.Length > 0 && tag[0] is '（' or '(' && tag.IndexOf(tag[0] == '（' ? '）' : ')') is var end and > 0)
            {
                title += (tag[0] == '(' ? " " : "") + tag[..(end + 1)];
                rest = tag[(end + 1)..];
            }
            if (rest.Length > 0 && rest[0] is '：' or ':') rest = rest[1..];
            return (title, rest.Trim());
        }
    }
}

/// 解析 CHANGELOG.md（同 Mac 版 Changelog.parse）：只认这份文件自己的写法，「# 标题」和 <!-- 注释 --> 不显示
public static class Changelog
{
    enum Target { None, Note, Item, Detail }

    public static List<ChangelogRelease> Parse(string markdown)
    {
        var releases = new List<ChangelogRelease>();
        var target = Target.None;
        var inComment = false;
        foreach (var raw in markdown.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.Trim();
            if (inComment) { if (line.Contains("-->")) inComment = false; continue; }
            if (line.StartsWith("<!--")) { inComment = !line.Contains("-->"); continue; }
            if (line.Length == 0) { if (target == Target.Note) target = Target.None; continue; }
            if (line.StartsWith("## ")) { releases.Add(Header(line[3..])); target = Target.None; continue; }
            if (line.StartsWith("# ") || releases.Count == 0) continue;
            var r = releases[^1];
            if (line.StartsWith("### ")) { r.Sections.Add((line[4..].Trim(), [])); target = Target.None; continue; }
            var indented = raw.TakeWhile(c => c is ' ' or '\t').Count() >= 2;
            var hasItem = r.Sections.Count > 0 && r.Sections[^1].Items.Count > 0;
            if (line.StartsWith("- ") || line.StartsWith("* "))
            {
                var text = line[2..].Trim();
                if (indented && target is Target.Item or Target.Detail && hasItem)
                {
                    r.Sections[^1].Items[^1].Details.Add(text);
                    target = Target.Detail;
                }
                else
                {
                    if (r.Sections.Count == 0) r.Sections.Add(("", []));
                    r.Sections[^1].Items.Add(new ChangelogItem { Raw = text });
                    target = Target.Item;
                }
                continue;
            }
            // 续行：缩进的接到上一条（或它的子条目）后面；顶格的是说明段落
            if (indented && hasItem && target is Target.Item or Target.Detail)
            {
                var item = r.Sections[^1].Items[^1];
                if (target == Target.Detail && item.Details.Count > 0) item.Details[^1] = Join(item.Details[^1], line);
                else item.Raw = Join(item.Raw, line);
            }
            else if (target == Target.Note && r.Notes.Count > 0) r.Notes[^1] = Join(r.Notes[^1], line);
            else { r.Notes.Add(line); target = Target.Note; }
        }
        return releases;
    }

    /// 「1.0.8（2026-10-24）」→ 版本、日期；括号里日期后面的附注不显示
    static ChangelogRelease Header(string text)
    {
        var trimmed = text.Trim();
        var open = trimmed.IndexOfAny(['（', '(']);
        if (open < 0) return new ChangelogRelease { Version = trimmed, Date = "" };
        var inside = new string(trimmed[(open + 1)..].TakeWhile(c => c is not '）' and not ')').ToArray());
        var first = inside.Split('，', ',', '·').FirstOrDefault()?.Trim() ?? "";
        return new ChangelogRelease { Version = trimmed[..open].Trim(), Date = Regex.IsMatch(first, @"^\d{4}-\d{1,2}-\d{1,2}$") ? first : "" };
    }

    /// 续行接上：英文、数字之间补一个空格，中文直接接
    static string Join(string a, string b)
    {
        if (a.Length == 0 || b.Length == 0) return a + b;
        static bool Wordy(char c) => c < 128 && (char.IsLetterOrDigit(c) || ",.;:)".Contains(c));
        return a + (Wordy(a[^1]) && Wordy(b[0]) ? " " : "") + b;
    }

    /// 「2026-10-24」→「2026 年 10 月 24 日」
    public static string DisplayDate(string date)
    {
        var parts = date.Split('-').Select(p => int.TryParse(p, out var n) ? n : -1).ToArray();
        return parts.Length == 3 && parts.All(p => p >= 0) ? L("%@ 年 %@ 月 %@ 日", parts[0], parts[1], parts[2]) : date;
    }

    public static string Symbol(string title) => title switch
    {
        "新功能" or "New Features" => "sparkles",
        "改进" or "Improvements" => "arrow.up.circle",
        "问题修复" or "Bug Fixes" => "wrench.and.screwdriver",
        "安全" or "Security" => "lock.shield",
        "移除" or "Removed" => "minus.circle",
        _ => "circle.grid.2x2",
    };
}

/// 更新记录窗口（同 Mac 版 ChangelogWindow）：设置 → 关于 →「更新记录」打开，左边一条竖线串起各版本的时间轴（同手机、Mac 同一个页面）。
/// 内容取本机后台的 /api/changelog（Windows / Linux 版自己的更新记录，按界面语言取中文版 / 英文版）
public sealed class ChangelogWindow : Window
{
    static ChangelogWindow? shown;
    /// 自测截图用
    public static Window? Current => shown;

    readonly ContentControl body = new();

    public static void Open()
    {
        if (shown is null)
        {
            shown = new ChangelogWindow();
            shown.Closed += (_, _) => shown = null;
            WindowChrome.FitToScreen(shown);
            shown.Show();
        }
        shown.Activate();
    }

    ChangelogWindow()
    {
        Width = 700;
        Height = 780;
        MinWidth = 480;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Look.Family;
        Title = L("更新记录");
        this.Res(BackgroundProperty, "Window");
        Content = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        // 开着窗口时换了界面语言：标题和内容换成另一种语言的版本
        void Relabel() { Title = L("更新记录"); FontFamily = Look.Family; Load(); }
        Lang.Changed += Relabel;
        Closed += (_, _) => Lang.Changed -= Relabel;
        Load();
    }

    async void Load()
    {
        body.Content = new Spinner(18).HAlign(HorizontalAlignment.Center).Margin(0, 80, 0, 0);
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/changelog");
            var releases = Changelog.Parse(reply.Str("text") ?? "");
            body.Content = releases.Count == 0
                ? Ui.Text(L(reply.Str("error") is { Length: > 0 } error ? error : "此版本未包含更新记录"), 14, color: "Text2").HAlign(HorizontalAlignment.Center).Margin(0, 80, 0, 0)
                : Timeline(releases, reply.Str("version") ?? "");
        }
        catch (Exception e)
        {
            body.Content = Ui.Text(e.Message, 13, color: "Text2", lines: 0).Wrap().HAlign(HorizontalAlignment.Center).Margin(40, 80, 40, 0);
        }
    }

    /// 当前版本的节点用强调色并标「当前版本」（找不到就标最新一版）
    static Control Timeline(List<ChangelogRelease> releases, string current)
    {
        var marked = releases.Any(r => r.Version == current) ? current : releases[0].Version;
        var stack = new StackPanel { MaxWidth = 760, Margin = new Thickness(40, 32, 40, 40), HorizontalAlignment = HorizontalAlignment.Stretch };
        for (var i = 0; i < releases.Count; i++)
            stack.Children.Add(new ReleaseRow(releases[i], releases[i].Version == marked, i == 0, i == releases.Count - 1));
        return stack;
    }

    /// 一个版本：左边时间轴（竖线 + 节点，节点对齐版本号那一行的中心），右边版本号、日期、各分类的条目
    sealed class ReleaseRow : Panel
    {
        const double RailWidth = 22, RailGap = 14, Clearance = 5, ReleaseSpacing = 52;
        readonly bool isCurrent, isFirst, isLast;
        readonly TextBlock version;
        readonly Control content;

        public ReleaseRow(ChangelogRelease release, bool isCurrent, bool isFirst, bool isLast)
        {
            this.isCurrent = isCurrent;
            this.isFirst = isFirst;
            this.isLast = isLast;
            version = Ui.Text(release.Version, 21, FontWeight.SemiBold);
            var header = new StackPanel { Spacing = 5 };
            var title = Ui.H(10, version, isCurrent
                ? new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 3), Child = Ui.Text(L("当前版本"), 11, FontWeight.SemiBold, "Accent") }
                    .Res(Border.BackgroundProperty, "IconTile") : null);
            header.Children.Add(title);
            if (release.Date.Length > 0) header.Children.Add(Ui.Text(Changelog.DisplayDate(release.Date), 12.5, color: "Text2"));
            var column = new StackPanel { Spacing = 0 };
            column.Children.Add(header);
            if (release.Notes.Count > 0 || release.Sections.Count > 0)
            {
                var sections = new StackPanel { Spacing = 28, Margin = new Thickness(0, 20, 0, 0) };
                foreach (var note in release.Notes) sections.Children.Add(Rich(note, 14, FontWeight.Normal, "Text"));
                foreach (var (name, items) in release.Sections)
                {
                    var group = new StackPanel { Spacing = 16 };
                    if (name.Length > 0) group.Children.Add(Ui.H(6, Ui.Sym(Changelog.Symbol(name), 12, "Text2"), Ui.Text(name, 12.5, FontWeight.SemiBold, "Text2")));
                    foreach (var item in items) group.Children.Add(Item(item));
                    sections.Children.Add(group);
                }
                column.Children.Add(sections);
            }
            content = column;
            content.Margin = new Thickness(RailWidth + RailGap, 0, 0, isLast ? 8 : ReleaseSpacing);
            Children.Add(new Rail(this) { Width = RailWidth, HorizontalAlignment = HorizontalAlignment.Left });
            Children.Add(content);
        }

        /// 一条：有加粗标题的，标题一行、说明在下面（次要色）；没有标题的整句用正文色。子条目缩进、字小一号
        static Control Item(ChangelogItem item)
        {
            var (title, text) = item.Parts;
            var column = new StackPanel { Spacing = 6 };
            if (title is not null) column.Children.Add(Rich(title, 14, FontWeight.SemiBold, "Text"));
            if (text.Length > 0) column.Children.Add(Rich(text, 14, FontWeight.Normal, title is null ? "Text" : "Text2"));
            if (item.Details.Count > 0)
            {
                var details = new StackPanel { Spacing = 8, Margin = new Thickness(0, 4, 0, 0) };
                foreach (var detail in item.Details)
                {
                    var row = new DockPanel();
                    var dash = Ui.Text("–", 12.5, color: "Text3");
                    dash.Margin = new Thickness(0, 0, 8, 0);
                    dash.VerticalAlignment = VerticalAlignment.Top;   // 对齐第一行，不跟着多行的说明居中
                    DockPanel.SetDock(dash, Dock.Left);
                    row.Children.Add(dash);
                    row.Children.Add(Rich(detail, 12.5, FontWeight.Normal, "Text2"));
                    details.Children.Add(row);
                }
                column.Children.Add(details);
            }
            var dock = new DockPanel();
            var bullet = Ui.Text("•", 14, color: "Text3");
            bullet.Margin = new Thickness(0, 0, 10, 0);
            bullet.VerticalAlignment = VerticalAlignment.Top;
            DockPanel.SetDock(bullet, Dock.Left);
            dock.Children.Add(bullet);
            dock.Children.Add(column);
            return dock;
        }

        /// 行内的 **加粗**、`代码`、[链接](…)；能用鼠标选字复制（同 Mac 版 .textSelection）
        static Control Rich(string text, double size, FontWeight weight, string color) =>
            new RichText(Markdown.Inline(text), size, weight, color) { OpenLink = url => OpenUrl(url) };

        static void OpenUrl(string url)
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (Exception) { }
        }

        /// 左边的时间轴：竖线在节点上下各断开一点，节点对齐版本号那一行的中心（字号、字体怎么换都对得上）
        sealed class Rail(ReleaseRow row) : Control
        {
            public override void Render(DrawingContext context)
            {
                var y = row.version.TranslatePoint(new Point(0, row.version.Bounds.Height / 2), this)?.Y ?? 14;
                var radius = row.isCurrent ? 11 : 5;
                var x = RailWidth / 2;
                var pen = new Pen(Palette.Get("Fill15"), 1.5);
                if (!row.isFirst && y - radius - Clearance > 0) context.DrawLine(pen, new Point(x, 0), new Point(x, y - radius - Clearance));
                if (!row.isLast) context.DrawLine(pen, new Point(x, y + radius + Clearance), new Point(x, Bounds.Height));
                if (row.isCurrent)
                {
                    context.DrawEllipse(Palette.Get("AccentFill16"), null, new Point(x, y), 11, 11);
                    context.DrawEllipse(Palette.Get("Accent"), null, new Point(x, y), 5, 5);
                }
                else context.DrawEllipse(null, new Pen(Palette.Get("Text3"), 1.5), new Point(x, y), 4.25, 4.25);
            }
        }

        protected override Size ArrangeOverride(Size finalSize)
        {
            var size = base.ArrangeOverride(finalSize);
            Dispatcher.UIThread.Post(() => Children[0].InvalidateVisual(), DispatcherPriority.Render);
            return size;
        }
    }
}
