using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 会话的首字头像：淡强调色底 + 强调色首字；工作中右下角小纸鸢，等确认右下角橙色「!」（同 Mac 版 SessionAvatar）
public sealed class SessionAvatar : Panel
{
    /// face：这个会话在 Agent 详情里单独设了头像就用它（见 SessionFace），没设是标题首字
    public SessionAvatar(string title, string activity, double size = 34, Control? face = null)
    {
        Width = size;
        Height = size;
        ClipToBounds = false;
        var tile = face ?? new Border
        {
            CornerRadius = new CornerRadius(size * 0.28),
            Child = new TextBlock
            {
                Text = Format.Initials(title), FontSize = size * 0.4, FontWeight = FontWeight.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            }.Res(TextBlock.ForegroundProperty, "Accent"),
        }.Res(Border.BackgroundProperty, "IconTile");
        Children.Add(tile);
        if (activity == "busy")
        {
            var spinner = new KiteSpinner(size * 0.42 * 1.15) { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom };
            spinner.RenderTransform = new TranslateTransform(size * 0.12 + 2, size * 0.12 + 2);
            Children.Add(spinner);
        }
        else if (activity == "waiting")
        {
            var badge = new Border
            {
                Width = size * 0.36 + 3, Height = size * 0.36 + 3, CornerRadius = new CornerRadius(size),
                BorderThickness = new Thickness(1.5),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
                RenderTransform = new TranslateTransform(size * 0.12, size * 0.12),
                Child = new TextBlock { Text = "!", FontSize = size * 0.24, FontWeight = FontWeight.Bold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            }.Res(Border.BackgroundProperty, "Orange").Res(Border.BorderBrushProperty, "Sidebar");
            Children.Add(badge);
        }
    }
}

/// 编程 agent 的单色标志（同 Mac 版 AgentGlyph）：没有标志的写名字首字母，套个圆角框
public sealed class AgentGlyph : Viewbox
{
    public AgentGlyph(string? agent, double size = 14, string color = "Text2")
    {
        Width = size;
        Height = size;
        var info = Agents.Info(agent);
        if (info.Layers.Length == 0)
        {
            Child = new Border
            {
                Width = 24, Height = 24, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(2),
                Child = new TextBlock { Text = info.Name[..1].ToUpperInvariant(), FontSize = 15, FontWeight = FontWeight.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }.Res(TextBlock.ForegroundProperty, color),
            }.Res(Border.BorderBrushProperty, color);
            return;
        }
        var canvas = new Canvas { Width = 24, Height = 24 };
        foreach (var layer in info.Layers)
        {
            Geometry data;
            try { data = Geometry.Parse("F0 " + layer.D); }
            catch (Exception) { continue; }   // 插件给的路径写坏了：这一层不画，别让界面出错
            var path = new Avalonia.Controls.Shapes.Path { Data = data, Opacity = layer.Opacity };
            path.Res(Shape.FillProperty, color);
            canvas.Children.Add(path);
        }
        Child = canvas;
    }
}

/// 两色图标：强调色图形放在淡强调色圆角方块里（同 Mac 版 DuoIcon / TarsIcon）
public sealed class DuoIcon : Border
{
    public DuoIcon(string symbol, double size = 34, string tint = "Accent", string tile = "IconTile")
    {
        Width = size;
        Height = size;
        CornerRadius = new CornerRadius(size * 0.28);
        this.Res(BackgroundProperty, tile);
        Child = new Icon(symbol, size * 0.46) { FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center }.Res(TextBlock.ForegroundProperty, tint);
    }
}

/// 工作中的小纸鸢：随风晃（先用一个会转的小点代替，纸鸢形状移植后换成 KiteMark）
public sealed class KiteSpinner : Control
{
    readonly double size;
    double phase;
    DispatcherTimer? timer;

    public KiteSpinner(double size = 16)
    {
        this.size = size;
        Width = size;
        Height = size;
        IsHitTestVisible = false;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(50), DispatcherPriority.Render, (_, _) => { phase += 0.05; InvalidateVisual(); });
        timer.Start();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        timer?.Stop();
        timer = null;
    }

    public override void Render(DrawingContext context)
    {
        var brush = Palette.Get("Accent");
        KiteMark.Draw(context, new Rect(0, 0, size, size), brush, phase);
    }
}

/// 筛选胶囊：状态圆点 + 名字 + 个数；选中的填强调色，个数是 0 的淡一点（同 FilterChip）
public sealed class FilterChip : Tap
{
    /// symbol：用小图标代替圆点（「标记」的星星）
    public FilterChip(string title, int count, string? dot, bool selected, Action action, string? symbol = null) : base(null, action, 15)
    {
        Height = 30;
        Padding = new Thickness(10, 0);
        var text = selected ? "White" : "Text";
        var row = Ui.H(5,
            symbol is not null ? Ui.Sym(symbol, 10, selected ? "White" : dot ?? "Accent")
            : dot is null ? null : Ui.Dot(6, selected ? "White" : dot),
            Ui.Text(title, 12, FontWeight.SemiBold, text),
            Ui.Text(count.ToString(), 12, FontWeight.SemiBold, selected ? "White" : "Text2").Digits().Opacity(selected ? 0.8 : 1));
        Child = row;
        if (selected) Keys("Accent", "Accent"); else Keys("Fill06", "Fill10");
        Opacity = count == 0 && !selected ? 0.45 : 1;
    }
}

/// 一排「只看某一个」的胶囊（设备、项目，同 Mac 版 ScopeBar）：最前面「全部设备」，后面每项带个数，直接点选，
/// 再点一下选中的就回到全部；选中的淡强调色底加细边（和上面状态筛选的实心胶囊区分开）；放不下时横着划
public static class ScopeBar
{
    public static FilterBar Build(string symbol, string allTitle, IEnumerable<(string Id, string Title, int Count)> options, string selection, Action<string> select)
    {
        var chips = new List<Control> { new ScopeChip(allTitle, null, symbol, selection.Length == 0, () => select("")) };
        foreach (var option in options)
        {
            var id = option.Id;
            chips.Add(new ScopeChip(option.Title, option.Count, null, selection == id, () => select(selection == id ? "" : id)));
        }
        return new FilterBar(chips);
    }
}

/// ScopeBar 里的一个胶囊：小图标（「全部」那个才有）+ 名字 + 个数
public sealed class ScopeChip : Tap
{
    public ScopeChip(string title, int? count, string? symbol, bool selected, Action action) : base(null, action, 15)
    {
        Height = 30;
        Padding = new Thickness(10, 0);
        var color = selected ? "Accent" : "Text";
        if (title.Length > 24) title = title[..23] + "…";   // 名字太长的截短（一个胶囊别占满一排）
        Child = Ui.H(5,
            symbol is null ? null : Ui.Sym(symbol, 11, color),
            Ui.Text(title, 12, FontWeight.SemiBold, color),
            count is int n ? Ui.Text(n.ToString(), 12, FontWeight.SemiBold, selected ? "Accent" : "Text2").Digits().Opacity(selected ? 0.75 : 1) : null);
        if (selected) { Keys("AccentFill14", "AccentFill20"); BorderThickness = new Thickness(1); this.Res(BorderBrushProperty, "AccentEdge32"); }
        else Keys("Fill06", "Fill10");
    }
}

/// 一排筛选胶囊：放不下时横着划
public sealed class FilterBar : ScrollViewer
{
    // 继承的控件要指明用 ScrollViewer 的模板，不然套不上、只是裁掉放不下的部分，根本划不动
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    public FilterBar(IEnumerable<Control> chips)
    {
        HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Hidden;
        VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled;
        Content = Ui.Stack(Orientation.Horizontal, 6, Align.Center, chips).Pad(0, 1);
        // 放不下时用普通鼠标的上下滚轮也能横着滚（滚动条藏着，大多数鼠标没有横向滚轮）；先截住，免得被外层列表吃掉
        AddHandler(PointerWheelChangedEvent, (_, e) =>
        {
            var room = Extent.Width - Viewport.Width;
            if (room <= 0 || e.Delta.X != 0 || e.Delta.Y == 0) return;
            Offset = new Avalonia.Vector(Math.Clamp(Offset.X - e.Delta.Y * 40, 0, room), 0);
            e.Handled = true;
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
    }

}

/// 读取失败：图标 + 原因 + 「重试」
public static class Empty
{
    public static Control State(string symbol, string title, string? detail = null, Control? action = null) =>
        Ui.Stack(Orientation.Vertical, 8, Align.Center, [
            Ui.Sym(symbol, 30, "Text3"),
            Ui.Text(title, 15, FontWeight.SemiBold, "Text"),
            detail is null ? null : Ui.Text(detail, 12, color: "Text2", lines: 3).Wrap().HAlign(HorizontalAlignment.Center),
            action,
        ]).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center);
}

/// 玻璃按钮（同 Mac 版 tarsButton）：prominent = 主操作，填主按钮色
public sealed class GlassButton : Tap
{
    public GlassButton(string title, string? symbol, Action action, bool prominent = false, double height = 28, double size = 13) : base(null, action, height / 2)
    {
        Height = height;
        Padding = new Thickness(height < 26 ? 9 : 12, 0);
        var color = prominent ? "White" : "Text";
        Child = Ui.H(height < 26 ? 4 : 6, symbol is null ? null : Ui.Sym(symbol, size - 1, color), Ui.Text(title, size, FontWeight.Medium, color));
        if (prominent) Keys("Action", "Action"); else Keys("Glass", "Fill12");
        if (!prominent) { BorderThickness = new Thickness(0.5); this.Res(BorderBrushProperty, "GlassEdge"); }
    }
}

/// 右上角的拷贝小钮（同 Mac 版 CopyCorner、VS Code 的代码块）：鼠标指着这一块才出现；点了图标换成对勾一会儿（不另外弹「已复制」）。
/// 代码块、命令、工具的输入输出、思考原文用
public static class CopyCorner
{
    /// 自测截图：画成指着的样子（在打开会话之前设）
    public static bool CaptureShown;

    public static Control Wrap(Control content, string text, double inset = 6)
    {
        var copied = false;
        var button = new Tap(null, null, 6) { Width = 26, Height = 24, IsVisible = CaptureShown, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(inset) };
        button.Keys("GlassSolid", "Fill12").Tip(L("复制"));
        button.Res(Border.BorderBrushProperty, "Fill10");
        button.BorderThickness = new Thickness(1);
        void Face()
        {
            var icon = Ui.Sym(copied ? "checkmark" : "doc.on.doc", 11, copied ? "Added" : "Text2");
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            icon.VerticalAlignment = VerticalAlignment.Center;
            button.Child = icon;
        }
        Face();
        var panel = new Panel { Children = { content, button }, HorizontalAlignment = content.HorizontalAlignment };
        button.Click = () =>
        {
            _ = MainWindow.Current?.Clipboard?.SetTextAsync(text);
            copied = true;
            Face();
            DispatcherTimer.RunOnce(() => { copied = false; Face(); button.IsVisible = panel.IsPointerOver; }, TimeSpan.FromSeconds(1.5));
        };
        panel.PointerEntered += (_, _) => button.IsVisible = true;
        panel.PointerExited += (_, _) => button.IsVisible = copied || CaptureShown;
        return panel;
    }
}
