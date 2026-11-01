using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 「2/4 开发中」小标识（同 Mac 版 StageBadge）：会话列表。主题色字、淡主题色底、细边（同选中态，不用整块饱和色）
public static class StageBadge
{
    public static Border Make(StageInfo stage, double size = 11)
    {
        // 分了部分的：前面一排圆点和正在做的那部分的名字
        var box = Ui.Box(Ui.H(size * 0.3, Dots(stage, size)?.Margin(0, 0, size * 0.1, 0),
                                  stage.Part is string part ? Ui.Text(part, size, FontWeight.SemiBold, "Accent") : null,
                                  Ui.Text($"{stage.Step}/{stage.Total}", size, FontWeight.Bold, "Accent").Digits(),
                                  Ui.Text(L(stage.Label), size, FontWeight.Medium, "Accent")),
                         new Thickness(size * 0.5, size * 0.14), "AccentFill14", size, "AccentEdge40");
        box.HorizontalAlignment = HorizontalAlignment.Left;
        box.VerticalAlignment = VerticalAlignment.Center;
        ToolTip.SetTip(box, Tip(stage));
        return box;
    }

    /// 各部分完成情况的小圆点：做完的实心、正在做的空心圈、没开始的淡色；不到两部分没有
    public static Flex? Dots(StageInfo stage, double size)
    {
        var parts = stage.Parts;
        if (parts.Count < 2) return null;
        var row = Ui.H(size * 0.2);
        foreach (var p in parts)
        {
            var dot = new Border { Width = size * 0.45, Height = size * 0.45, CornerRadius = new CornerRadius(size) };
            if (p.Done) dot.Res(Border.BackgroundProperty, "Accent");
            else if (p.Name == stage.Part) { dot.BorderThickness = new Thickness(Math.Max(1, size * 0.12)); dot.Res(Border.BorderBrushProperty, "Accent"); }
            else dot.Res(Border.BackgroundProperty, "AccentEdge25");
            row.Children.Add(dot);
        }
        return row;
    }

    /// 鼠标停在小标识上的说明：各部分到哪了、agent 的说明
    static string Tip(StageInfo stage)
    {
        var steps = stage.Steps.Split('\n');
        var rows = stage.Parts.Select(p => p.Done ? $"{p.Name}：{L("已完成")}"
            : p.Step >= 1 && p.Step <= stage.Total ? $"{p.Name}：{p.Step}/{stage.Total} {(p.Name == stage.Part ? L(stage.Label) : p.Step <= steps.Length ? L(steps[p.Step - 1]) : "")}"
            : $"{p.Name}：{L("未开始")}");
        return string.Join("\n", new[] { L("任务进展") }.Concat(rows).Concat(stage.Note is string note ? [note] : []));
    }
}

/// 对话页输入框上方的任务进展条（同 Mac 版 StageStrip；11-01：步骤都放这里，对话里别处不再显示）。只在忙、等确认时有：
/// 平时收成一行——做到第几步、在做什么、这一步用了多久；点一下往上展开成清单：走过的步骤打勾划掉，正在做的主题色，没到的灰圈；
/// 分了几部分（几个端）的每部分一行，正在做的那部分下面列出它的步骤
public sealed class StageStrip : Panel
{
    const double Corner = 12;
    readonly Border card = new() { CornerRadius = new CornerRadius(Corner), BorderThickness = new Thickness(0.5), ClipToBounds = true };
    readonly DispatcherTimer timer;
    StageInfo? stage;
    bool expanded;
    /// 上次照什么建的：步骤、说明、展开没有都没变就只改每秒跳的字
    string? built;
    double available;
    /// 每秒要跳的几处字：这一步用时、一共用时、清单里每一步的用时
    TextBlock? spent, elapsed;
    readonly List<(int Index, TextBlock Text)> times = [];

    public StageStrip()
    {
        IsVisible = false;
        MaxWidth = 832;
        Margin = new Thickness(24, 0);
        // 同输入框：白底细边、浅阴影；阴影单独一层、不放子控件（带阴影的 Border 里有内容时，离屏截图把内容画到两倍的位置）
        card.Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");
        Children.Add(new Border { CornerRadius = new CornerRadius(Corner), Background = Brushes.Transparent, BoxShadow = BoxShadows.Parse("0 2 10 0 #0F000000") });
        Children.Add(card);
        timer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => Refresh());
    }

    /// 会话状态变了；available = 对话页多高（展开的清单最多占四成五，再多在里面滚）
    public void Update(StageInfo? next, double available)
    {
        stage = next;
        this.available = available;
        IsVisible = next is not null;
        if (next is null) { expanded = false; built = null; timer.Stop(); return; }
        var signature = $"{next.Token}|{next.Steps}|{next.PartsText}|{next.Marks}|{next.Auto}|{expanded}";
        if (signature != built) { built = signature; Render(); }
        else Refresh();
        if (VisualRoot is not null) timer.Start();
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e) { base.OnAttachedToVisualTree(e); if (stage is not null) timer.Start(); }
    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e) { base.OnDetachedFromVisualTree(e); timer.Stop(); }

    /// 点一下：展开 / 收起（自测的 stageopen 也走这里）
    public void Toggle()
    {
        expanded = !expanded;
        built = null;
        Update(stage, available);
    }

    void Render()
    {
        if (stage is not StageInfo s) return;
        times.Clear();
        spent = elapsed = null;
        var now = Format.NowMs;
        var seconds = s.Seconds(now);
        var header = Header(s, seconds);
        card.Child = expanded ? Ui.VFill(0, List(s, seconds, now), Ui.Rule("Separator", 0.5), header) : header;
    }

    /// 只改每秒要跳的字
    void Refresh()
    {
        if (stage is not StageInfo s) return;
        var now = Format.NowMs;
        var seconds = s.Seconds(now);
        if (spent is not null) spent.Text = Time(seconds, s.Step - 1);
        if (elapsed is not null && s.TurnAt is double start) elapsed.Text = L("用时 %@", Format.Duration((int)Math.Max(0, (now - start) / 1000)));
        foreach (var (index, text) in times) text.Text = Time(seconds, index);
    }

    static string Time(int?[] seconds, int index) => index >= 0 && index < seconds.Length && seconds[index] is int sec ? Format.Duration(sec) : "";

    /// 收起时的一行：（分部分的圆点、哪部分）2/5 这一步叫什么 · 在做什么 …… 这一步用了多久 ⌃
    Control Header(StageInfo s, int?[] seconds)
    {
        var title = Ui.H(5, StageBadge.Dots(s, 11),
            s.Part is string part ? Ui.Text(part, 12.5, FontWeight.SemiBold, "Accent") : null,
            Ui.Text($"{s.Step}/{s.Total}", 12.5, FontWeight.Bold, "Accent").Digits(),
            Ui.Text(s.Name(s.Step - 1), 12.5, FontWeight.SemiBold, "Accent").Trim());
        // 在做什么：展开后清单里当前那步下面有，这里不重复；窄的分屏块里放不下
        var note = !expanded && s.Note is string n && (Bounds.Width == 0 || Bounds.Width >= 300) ? Ui.Text(n, 12.5, color: "Text2").Shrink() : null;
        spent = Ui.Text(Time(seconds, s.Step - 1), 12, color: "Text2").Digits();
        var row = Ui.H(7, new StageRing { Width = 13, Height = 13, Fraction = Math.Max(0, (s.Step - 0.5) / Math.Max(1, s.Total)) },
            title.Shrink(), note, new Spacer(4), spent, Ui.Sym(expanded ? "chevron.down" : "chevron.up", 10, "Text2"));
        return new Tap(row.Pad(12, 0, 12, 0), Toggle, 0) { MinHeight = 34 }.Keys("Transparent", "Fill05").Tip(expanded ? L("收起") : L("展开全部步骤"));
    }

    /// 展开的清单：标题行（自动识别 / Agent 报告、一共用了多久）+ 步骤；太长在里面滚
    Control List(StageInfo s, int?[] seconds, double now)
    {
        var stack = new StackPanel { Margin = new Thickness(12, 10, 12, 8) };
        var source = Ui.Box(Ui.Text(s.Auto ? L("自动识别") : L("Agent 报告"), 10.5, color: "Text2"), new Thickness(6, 1), "Fill05", 8);
        elapsed = s.TurnAt is double start ? Ui.Text(L("用时 %@", Format.Duration((int)Math.Max(0, (now - start) / 1000))), 11.5, color: "Text2").Digits() : null;
        stack.Children.Add(Ui.H(6, Ui.Text(L("任务进展"), 12.5, FontWeight.SemiBold), source, new Spacer(4), elapsed).Margin(0, 0, 0, 6));
        if (s.Parts.Count == 0) AddSteps(stack, s, seconds, 0);
        else
            foreach (var p in s.Parts)
            {
                stack.Children.Add(PartRow(s, p));
                if (p.Name == s.Part) AddSteps(stack, s, seconds, 22);
            }
        return new ScrollViewer
        {
            Content = stack,
            MaxHeight = available > 0 ? Math.Max(120, Math.Min(380, available * 0.45)) : 300,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    /// 0 = 做完了，1 = 正在做，2 = 还没到
    static Icon Check(int state)
    {
        var icon = Ui.Sym(state == 0 ? "checkmark.circle.fill" : state == 1 ? "circle.dotted.circle" : "circle", 13, state == 0 ? "Text2" : state == 1 ? "Accent" : "Text3");
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 1.5, 8, 0);
        return icon;
    }

    static DockPanel Row(Icon icon, Control body, Control? trailing, double indent)
    {
        var row = new DockPanel { Margin = new Thickness(indent, 3.5, 0, 3.5) };
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        if (trailing is not null)
        {
            trailing.VerticalAlignment = VerticalAlignment.Top;
            trailing.Margin = new Thickness(8, 1, 0, 0);
            DockPanel.SetDock(trailing, Dock.Right);
            row.Children.Add(trailing);
        }
        row.Children.Add(body);
        return row;
    }

    void AddSteps(StackPanel stack, StageInfo s, int?[] seconds, double indent)
    {
        var current = s.Step - 1;
        for (var i = 0; i < s.Total; i++)
        {
            var state = i < current ? 0 : i == current ? 1 : 2;
            var name = Ui.Text(s.Name(i), 12.5, state == 1 ? FontWeight.SemiBold : FontWeight.Normal, state == 0 ? "Text2" : state == 1 ? "Accent" : "Text").Trim();
            name.VerticalAlignment = VerticalAlignment.Top;
            if (state == 0) name.TextDecorations = TextDecorations.Strikethrough;
            Control body = state == 1 && s.Note is string note ? Ui.V(2, name, Ui.Text(note, 11.5, color: "Text2", lines: 3)) : name;
            TextBlock? time = null;
            if (state != 2)
            {
                time = Ui.Text(Time(seconds, i), 11.5, color: "Text3").Digits();
                times.Add((i, time));
            }
            stack.Children.Add(Row(Check(state), body, time, indent));
        }
    }

    /// 一部分（一个端）：做完的划掉；右边写做到哪了
    static Control PartRow(StageInfo s, (string Name, int Step, bool Done) p)
    {
        var current = p.Name == s.Part;
        var steps = s.Steps.Split('\n');
        var status = p.Done ? L("已完成")
            : current ? $"{s.Step}/{s.Total}"
            : p.Step == 0 ? L("未开始") : $"{p.Step}/{s.Total} " + (p.Step <= steps.Length ? L(steps[p.Step - 1]) : "");
        var name = Ui.Text(p.Name, 12.5, current ? FontWeight.SemiBold : FontWeight.Medium, p.Done ? "Text2" : current ? "Accent" : "Text").Trim();
        name.VerticalAlignment = VerticalAlignment.Top;
        if (p.Done) name.TextDecorations = TextDecorations.Strikethrough;
        return Row(Check(p.Done ? 0 : current ? 1 : 2), name, Ui.Text(status, 11.5, color: "Text2").Digits(), 0);
    }
}

/// 收起那行最前面的小圈：转到这一步的一半（做到第几步一眼看出来）
public sealed class StageRing : Control
{
    double fraction;

    public double Fraction
    {
        get => fraction;
        set { if (Math.Abs(value - fraction) > 0.001) { fraction = value; InvalidateVisual(); } }
    }

    public override void Render(DrawingContext context)
    {
        var size = Math.Min(Bounds.Width, Bounds.Height);
        var radius = size / 2 - 1;
        var center = new Point(Bounds.Width / 2, Bounds.Height / 2);
        context.DrawEllipse(null, new Pen(Palette.Get("AccentEdge25"), 2), center, radius, radius);
        if (fraction <= 0) return;
        var sweep = Math.Min(0.9999, fraction) * 2 * Math.PI;
        var start = new Point(center.X, center.Y - radius);
        var end = new Point(center.X + radius * Math.Sin(sweep), center.Y - radius * Math.Cos(sweep));
        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            g.BeginFigure(start, false);
            g.ArcTo(end, new Size(radius, radius), 0, sweep > Math.PI, SweepDirection.Clockwise);
            g.EndFigure(false);
        }
        context.DrawGeometry(null, new Pen(Palette.Get("Accent"), 2, lineCap: PenLineCap.Round), geometry);
    }
}
