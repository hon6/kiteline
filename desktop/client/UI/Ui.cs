using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace Kiteline.UI;

/// 写界面用的小工具：照 SwiftUI 的写法一层层套（Text、HStack、VStack、padding、background……），Mac 版的界面逐段照搬
public static class Ui
{
    /// 跟着资源走（深浅色切换、换主题色自动变）
    public static T Res<T>(this T c, AvaloniaProperty property, string key) where T : Control
    {
        c.Bind(property, c.GetResourceObservable(key));
        return c;
    }

    public static TextBlock Text(string? text, double size = 13, FontWeight weight = FontWeight.Normal, string color = "Text", int lines = 1)
    {
        var t = new TextBlock
        {
            Text = text ?? "",
            FontSize = Look.Pt(size),
            FontWeight = weight,
            // 单行默认不截短（排版取整差零点几就会出省略号）；可能放不下的地方用 Shrink() / Trim() 打开
            TextTrimming = lines > 1 ? TextTrimming.CharacterEllipsis : TextTrimming.None,
            TextWrapping = lines == 1 ? TextWrapping.NoWrap : TextWrapping.Wrap,
            // 单行不设 MaxLines：设了 1 会让中英混排的空格量出来和画出来不一样宽（Avalonia 11.3）
            MaxLines = lines > 1 ? lines : 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        return t.Res(TextBlock.ForegroundProperty, color);
    }

    public static TextBlock Mono(this TextBlock t) { t.FontFamily = Look.Mono; return t; }
    public static TextBlock Digits(this TextBlock t) { t.FontFeatures = new FontFeatureCollection { FontFeature.Parse("tnum") }; return t; }
    public static TextBlock Wrap(this TextBlock t) { t.TextWrapping = TextWrapping.Wrap; t.MaxLines = 0; t.TextTrimming = TextTrimming.None; return t; }

    public static Icon Sym(string symbol, double size = 13, string color = "Text") => new Icon(symbol, size).Res(TextBlock.ForegroundProperty, color);

    public static Flex H(double spacing, params Control?[] kids) => Stack(Orientation.Horizontal, spacing, Align.Center, kids);
    public static Flex V(double spacing, params Control?[] kids) => Stack(Orientation.Vertical, spacing, Align.Start, kids);
    public static Flex HTop(double spacing, params Control?[] kids) => Stack(Orientation.Horizontal, spacing, Align.Start, kids);
    public static Flex VFill(double spacing, params Control?[] kids) => Stack(Orientation.Vertical, spacing, Align.Stretch, kids);

    public static Flex Stack(Orientation orientation, double spacing, Align align, IEnumerable<Control?> kids)
    {
        var f = new Flex { Orientation = orientation, Spacing = spacing, Align = align };
        foreach (var k in kids) if (k is not null) f.Children.Add(k);
        return f;
    }

    public static T Grow<T>(this T c, double grow = 1) where T : Control { Flex.SetGrow(c, grow); return c; }
    public static T Shrink<T>(this T c) where T : Control
    {
        Flex.SetShrink(c, true);
        if (c is TextBlock t && t.TextWrapping == TextWrapping.NoWrap) t.TextTrimming = TextTrimming.CharacterEllipsis;
        return c;
    }

    /// 放不下时截短、末尾省略号
    public static TextBlock Trim(this TextBlock t) { t.TextTrimming = TextTrimming.CharacterEllipsis; return t; }
    public static T Self<T>(this T c, Align align) where T : Control { Flex.SetSelf(c, align); return c; }

    /// SwiftUI 的 .padding().background(颜色, in: 圆角矩形)
    public static Border Box(Control? child, Thickness padding, string? background = null, double radius = 0, string? border = null, double borderWidth = 1)
    {
        var b = new Border { Child = child, Padding = padding, CornerRadius = new CornerRadius(radius) };
        if (background is not null) b.Res(Border.BackgroundProperty, background);
        if (border is not null) { b.Res(Border.BorderBrushProperty, border); b.BorderThickness = new Thickness(borderWidth); }
        return b;
    }

    public static Border Pad(this Control c, double all) => new() { Child = c, Padding = new Thickness(all) };
    public static Border Pad(this Control c, double horizontal, double vertical) => new() { Child = c, Padding = new Thickness(horizontal, vertical) };
    public static Border Pad(this Control c, double left, double top, double right, double bottom) => new() { Child = c, Padding = new Thickness(left, top, right, bottom) };

    public static T Margin<T>(this T c, double left, double top, double right, double bottom) where T : Control { c.Margin = new Thickness(left, top, right, bottom); return c; }
    public static T Tip<T>(this T c, string? tip) where T : Control { if (!string.IsNullOrEmpty(tip)) ToolTip.SetTip(c, tip); return c; }
    public static T Width<T>(this T c, double w) where T : Control { c.Width = w; return c; }
    public static T MaxW<T>(this T c, double w) where T : Control { c.MaxWidth = w; return c; }
    public static T Height<T>(this T c, double h) where T : Control { c.Height = h; return c; }
    public static T Size<T>(this T c, double w, double h) where T : Control { c.Width = w; c.Height = h; return c; }
    public static T MinW<T>(this T c, double w) where T : Control { c.MinWidth = w; return c; }
    public static T HAlign<T>(this T c, HorizontalAlignment a) where T : Control { c.HorizontalAlignment = a; return c; }
    public static T VAlign<T>(this T c, VerticalAlignment a) where T : Control { c.VerticalAlignment = a; return c; }
    public static T Opacity<T>(this T c, double o) where T : Control { c.Opacity = o; return c; }
    public static T Hidden<T>(this T c, bool hidden) where T : Control { c.IsVisible = !hidden; return c; }

    /// 一圈圆角裁剪（图片、头像）
    public static Border Clip(this Control c, double radius) => new() { Child = c, CornerRadius = new CornerRadius(radius), ClipToBounds = true };

    /// 点一下（plain 按钮）：手形光标
    public static T OnTap<T>(this T c, Action action) where T : Control
    {
        c.Cursor = new Cursor(StandardCursorType.Hand);
        c.PointerReleased += (_, e) =>
        {
            if (e.InitialPressMouseButton == MouseButton.Left && c.IsPointerOver) { action(); e.Handled = true; }
        };
        return c;
    }

    /// 右键菜单
    public static T Menu<T>(this T c, Func<IEnumerable<Control>> items) where T : Control
    {
        var menu = new ContextMenu();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            foreach (var i in items()) menu.Items.Add(i);
        };
        c.ContextMenu = menu;
        return c;
    }

    public static MenuItem Item(string title, Action action, bool enabled = true, string? check = null)
    {
        var item = new MenuItem { Header = title, IsEnabled = enabled };
        item.Click += (_, _) => action();
        if (check is not null) item.Icon = new Icon("checkmark", 11).Res(TextBlock.ForegroundProperty, "Text");
        return item;
    }

    public static MenuItem Submenu(string title, IEnumerable<Control> items)
    {
        var item = new MenuItem { Header = title };
        foreach (var i in items) item.Items.Add(i);
        return item;
    }

    public static Separator Divider() => new();

    public static Control Rule(string color = "Separator", double thickness = 1) =>
        new Border { Height = thickness, HorizontalAlignment = HorizontalAlignment.Stretch }.Res(Border.BackgroundProperty, color);

    public static Control VRule(string color = "Separator", double thickness = 1) =>
        new Border { Width = thickness, VerticalAlignment = VerticalAlignment.Stretch }.Res(Border.BackgroundProperty, color);

    /// 一个圆点
    public static Border Dot(double size, string color) =>
        new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), VerticalAlignment = VerticalAlignment.Center }.Res(Border.BackgroundProperty, color);

    public static Border Dot(double size, IBrush brush) =>
        new() { Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = brush, VerticalAlignment = VerticalAlignment.Center };
}

/// plain 按钮：鼠标移上去有浅底、按下更深，点了执行（同 Mac 版 FooterButton、SidebarRowHighlight 这一类）
public class Tap : Border
{
    public string Normal { get; set; } = "Transparent";
    public string HoverKey { get; set; } = "Fill08";
    public string PressedKey { get; set; } = "Fill12";
    public Action? Click { get; set; }
    bool hover, pressed;

    public Tap(Control? child, Action? click = null, double radius = 8)
    {
        Child = child;
        Click = click;
        CornerRadius = new CornerRadius(radius);
        Cursor = new Cursor(StandardCursorType.Hand);
        Background = Brushes.Transparent;
        Update();
    }

    public Tap Keys(string normal, string hover, string? pressed = null)
    {
        Normal = normal;
        HoverKey = hover;
        PressedKey = pressed ?? hover;
        Update();
        return this;
    }

    protected override void OnPointerEntered(PointerEventArgs e) { base.OnPointerEntered(e); hover = true; Update(); }
    protected override void OnPointerExited(PointerEventArgs e) { base.OnPointerExited(e); hover = false; pressed = false; Update(); }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) { pressed = true; Update(); e.Handled = true; }
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        var was = pressed;
        pressed = false;
        Update();
        if (was && e.InitialPressMouseButton == MouseButton.Left && IsPointerOver) { Click?.Invoke(); e.Handled = true; }
    }

    IDisposable? binding;
    string? boundKey;

    public void Update()
    {
        var key = pressed ? PressedKey : hover ? HoverKey : Normal;
        if (key == boundKey) return;
        boundKey = key;
        binding?.Dispose();
        binding = null;
        if (key == "Transparent") { Background = Brushes.Transparent; return; }
        binding = this.Bind(BackgroundProperty, this.GetResourceObservable(key));
    }
}
