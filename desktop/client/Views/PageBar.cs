using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.UI;

namespace Kiteline.Views;

/// 右边各页面（今日动态、用量、项目、历史、待办）顶上的一条（同 Mac 主窗口的工具栏）：
/// 左边标题 + 小字，中间可放分段切换，右边一组玻璃按钮；铺在标题栏那一带，空白处能拖窗口，Windows 上右边让给窗口按钮
public sealed class PageBar : Grid
{
    readonly TextBlock title;
    readonly TextBlock subtitle;

    public PageBar(string titleText, string? subtitleText = null, Control? center = null, IEnumerable<Control>? actions = null)
    {
        Height = MainWindow.TitlebarHeight;
        ColumnDefinitions = new ColumnDefinitions("*,Auto,*");
        Background = Brushes.Transparent;
        title = Ui.Text(titleText, 14, FontWeight.SemiBold).Trim();
        subtitle = Ui.Text(subtitleText ?? "", 11, color: "Text2").Trim();
        var left = Ui.VFill(0, title, subtitle).Margin(20, 0, 8, 0);
        left.VerticalAlignment = VerticalAlignment.Center;
        SetColumn(left, 0);
        Children.Add(left);
        if (center is not null)
        {
            center.VerticalAlignment = VerticalAlignment.Center;
            SetColumn(center, 1);
            Children.Add(center);
        }
        var list = actions?.ToList() ?? [];
        if (list.Count > 0)
        {
            var group = new Border
            {
                CornerRadius = new CornerRadius(18), Padding = new Thickness(4, 2), BorderThickness = new Thickness(0.5),
                Child = Ui.Stack(Avalonia.Layout.Orientation.Horizontal, 2, Align.Center, list),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 16 + MainWindow.CaptionWidth, 0),
            };
            group.Res(Border.BackgroundProperty, "Glass").Res(Border.BorderBrushProperty, "GlassEdge");
            SetColumn(group, 2);
            Children.Add(group);
        }
        PointerPressed += WindowChrome.DragWindow;
    }

    public string Subtitle { set => subtitle.Text = value; }
    public string Title { set => title.Text = value; }

    /// 工具栏上的图标按钮（玻璃组里的一个）
    public static Tap Button(string symbol, string tip, Action action)
    {
        var icon = Ui.Sym(symbol, 14, "Text");
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        var tap = new Tap(icon, action, 14) { Width = 34, Height = 30 }.Keys("Transparent", "Fill10", "Fill12");
        tap.Tip(tip);
        return tap;
    }

    /// 页面：顶上一条 + 下面的内容
    public static Control Page(PageBar bar, Control content)
    {
        var dock = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        dock.Children.Add(bar);
        dock.Children.Add(content);
        return dock;
    }
}

/// 分段切换（同 Mac 的 .segmented 选择器，macOS 26 的玻璃样式）：胶囊底，选中的那段一块浅色底、字加粗
public sealed class Segmented : Border
{
    readonly (string Id, string Title)[] options;
    readonly Action<string> changed;
    string selected;

    public Segmented((string Id, string Title)[] options, string selected, Action<string> changed, double width = 220)
    {
        this.options = options;
        this.selected = selected;
        this.changed = changed;
        Width = width;
        Height = 32;
        CornerRadius = new CornerRadius(16);
        Padding = new Thickness(2);
        this.Res(BackgroundProperty, "Fill08");
        Build();
    }

    void Build()
    {
        var grid = new Grid();
        for (var i = 0; i < options.Length; i++) grid.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
        for (var i = 0; i < options.Length; i++)
        {
            var (id, title) = options[i];
            var on = id == selected;
            var tap = new Tap(Ui.Text(title, 13, on ? FontWeight.SemiBold : FontWeight.Regular, on ? "Text" : "Text2").HAlign(HorizontalAlignment.Center), () =>
            {
                if (selected == id) return;
                selected = id;
                Build();
                changed(id);
            }, 14);
            if (on) tap.Keys("SegmentOn", "SegmentOn"); else tap.Keys("Transparent", "Fill06");
            Grid.SetColumn(tap, i);
            grid.Children.Add(tap);
        }
        Child = grid;
    }
}

/// 页面里「还没有……」的空状态：图标 + 标题 + 一段说明，居中、最宽 420（同 Mac 版 EmptyHint）
public static class EmptyHint
{
    public static Control Make(string symbol, string title, string detail)
    {
        var icon = Ui.Sym(symbol, 34, "Text3");
        icon.FontWeight = FontWeight.Light;
        var text = Ui.Text(detail, 12.5, color: "Text2", lines: 0).Wrap();
        text.TextAlignment = TextAlignment.Center;
        var stack = Ui.Stack(Avalonia.Layout.Orientation.Vertical, 10, Align.Center, [icon.Margin(0, 0, 0, 2), Ui.Text(title, 15, FontWeight.SemiBold), text]);
        stack.MaxWidth = 420;
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Margin = new Thickness(0, 36);
        return stack;
    }
}

/// 卡片（同 Mac 版 tarsCard）：玻璃之上的一层内容容器
public static class Card
{
    public static Border Make(Control content, double padding = 14, double radius = 16)
    {
        var b = new Border { Child = content, Padding = new Thickness(padding), CornerRadius = new CornerRadius(radius), HorizontalAlignment = HorizontalAlignment.Stretch };
        b.Res(Border.BackgroundProperty, "Fill045");
        return b;
    }
}

/// 页面里的分段选择（同 Mac 版 LookSegmented）：浅灰底槽、选中的一格浮起来（控件底色 + 一道细影），两格都没选中时中间一道细线
public sealed class LookSegmented : Border
{
    readonly (string Id, string Title)[] options;
    readonly Action<string> changed;
    string selected;

    public LookSegmented((string Id, string Title)[] options, string selected, Action<string> changed)
    {
        this.options = options;
        this.selected = selected;
        this.changed = changed;
        CornerRadius = new CornerRadius(7);
        Padding = new Thickness(2);
        this.Res(BackgroundProperty, "Fill06");
        Build();
    }

    public string Selected { get => selected; set { if (selected != value) { selected = value; Build(); } } }

    void Build()
    {
        var grid = new Grid();
        for (var i = 0; i < options.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
            if (i < options.Length - 1) grid.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Auto));
        }
        for (var i = 0; i < options.Length; i++)
        {
            var (id, title) = options[i];
            var on = id == selected;
            var label = Ui.Text(title, 13, on ? FontWeight.Medium : FontWeight.Normal).HAlign(HorizontalAlignment.Center);
            var cell = new Panel { MinHeight = Look.Pt(22) };
            if (on)
            {
                // 细影单独一层（同一元素上的阴影会吞掉离屏截图里后画的内容）
                var shadow = new Border { CornerRadius = new CornerRadius(5), Margin = new Thickness(0, 0.5, 0, -0.5) };
                shadow.Background = new SolidColorBrush(Colors.Black, 0.14);
                var face = new Border { CornerRadius = new CornerRadius(5) }.Res(BackgroundProperty, "ControlBackground");
                cell.Children.Add(shadow);
                cell.Children.Add(face);
            }
            cell.Children.Add(label.VAlign(VerticalAlignment.Center).Margin(8, 0, 8, 0));
            var tap = new Tap(cell, () =>
            {
                if (selected == id) return;
                selected = id;
                Build();
                changed(id);
            }, 5).Keys("Transparent", "Transparent");
            tap.Cursor = Avalonia.Input.Cursor.Default;
            Grid.SetColumn(tap, i * 2);
            grid.Children.Add(tap);
            if (i < options.Length - 1)
            {
                var line = new Border { Width = 1, Height = 12, VerticalAlignment = VerticalAlignment.Center };
                if (on || options[i + 1].Id == selected) line.Background = Brushes.Transparent; else line.Res(BackgroundProperty, "Fill12");
                Grid.SetColumn(line, i * 2 + 1);
                grid.Children.Add(line);
            }
        }
        Child = grid;
    }
}
