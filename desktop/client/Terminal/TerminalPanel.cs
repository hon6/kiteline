using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Terminal;

/// 输入框下面那排里的终端按钮：点开 / 收起会话里的终端面板；角标是开着几个终端（主题色，不用醒目的红）
public sealed class TerminalChip : Panel
{
    readonly SessionInfo session;
    readonly ChatStore chat;
    readonly Tap tap;
    readonly Icon icon;
    readonly Border badge;
    readonly TextBlock count;

    public TerminalChip(SessionInfo session, ChatStore chat)
    {
        this.session = session;
        this.chat = chat;
        icon = new Icon("terminal", 13);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        tap = new Tap(icon, () => chat.TerminalOpen = !chat.TerminalOpen, 14) { Height = 28, Width = 40 };
        count = new TextBlock { FontSize = 9.5, FontWeight = FontWeight.Bold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        badge = new Border
        {
            Child = count, MinWidth = 15, Height = 15, CornerRadius = new CornerRadius(7.5), Padding = new Thickness(3.5, 0),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -5, -5, 0), IsHitTestVisible = false,
        };
        badge.Res(Border.BackgroundProperty, "Accent");
        Children.Add(tap);
        Children.Add(badge);
        ClipToBounds = false;
        Update();
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        chat.PropertyChanged += Changed;
        TerminalStore.Shared.PropertyChanged += Changed;
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        chat.PropertyChanged -= Changed;
        TerminalStore.Shared.PropertyChanged -= Changed;
    }

    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ChatStore.TerminalOpen) or nameof(TerminalStore.Revision)) Update();
    }

    void Update()
    {
        var open = chat.TerminalOpen;
        var n = TerminalStore.Shared.Count(AppModel.Shared.Session(session.Key) ?? session);
        icon.Res(TextBlock.ForegroundProperty, open ? "Accent" : "Text");
        icon.Opacity = open ? 1 : 0.75;
        tap.Keys(open ? "AccentFill14" : "Field", open ? "AccentFill20" : "Fill12");
        tap.BorderThickness = new Thickness(open ? 1 : 0);
        tap.Res(Border.BorderBrushProperty, "AccentEdge40");
        badge.IsVisible = n > 0;
        count.Text = n.ToString();
        tap.Tip(n > 0 ? L("终端（%@ 个）", n) : L("打开终端"));
    }
}

/// 会话里的终端面板（同 iPhone / Mac 版 TerminalPanel）：在输入区的位置从底下升起来（收起后输入框回来），
/// 上面是标签（几个终端）、新建、更多、收起，下面是终端本身。终端开在会话所在的电脑上，收起面板、换会话都不会结束它，点标签上的 × 才关
public sealed class TerminalPanel : Border
{
    readonly string key;
    readonly ChatStore chat;
    readonly StackPanel tabs = new() { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(12, 0, 6, 0) };
    readonly Border body = new() { ClipToBounds = true };
    readonly Dictionary<string, TermView> views = new();
    readonly Tap newButton;
    double height;
    double dragStart;
    double? dragFrom;

    public TerminalPanel(string key, ChatStore chat)
    {
        this.key = key;
        this.chat = chat;
        height = Prefs.Number("terminalHeight") ?? 320;
        var grip = new Border { Height = 14, Background = Brushes.Transparent, Cursor = new Cursor(StandardCursorType.SizeNorthSouth) };
        var handle = new Border { Width = 36, Height = 4, CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        handle.Res(Border.BackgroundProperty, "Fill15");
        grip.Child = handle;
        grip.PointerPressed += (_, e) => { dragFrom = e.GetPosition(TopLevel.GetTopLevel(this)).Y; dragStart = height; e.Pointer.Capture(grip); e.Handled = true; };
        grip.PointerMoved += (_, e) =>
        {
            if (dragFrom is not double from) return;
            SetHeight(dragStart - (e.GetPosition(TopLevel.GetTopLevel(this)).Y - from));
        };
        grip.PointerReleased += (_, e) => { if (dragFrom is null) return; dragFrom = null; e.Pointer.Capture(null); Prefs.Set("terminalHeight", height); };
        grip.Tip(L("拖动调整终端高度"));

        newButton = HeaderButton("plus", L("新建终端"), () => _ = OpenNew());
        var more = HeaderButton("ellipsis", L("更多"), null);
        more.Click = () => MoreMenu(more);
        var hide = HeaderButton("chevron.down", L("收起终端"), () => chat.TerminalOpen = false);
        var header = new DockPanel { Height = 32, Margin = new Thickness(0, 0, 8, 6) };
        var right = Ui.H(2, newButton, more, hide);
        DockPanel.SetDock(right, Dock.Right);
        header.Children.Add(right);
        header.Children.Add(new ScrollViewer { Content = tabs, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        var column = new DockPanel();
        DockPanel.SetDock(grip, Dock.Top);
        DockPanel.SetDock(header, Dock.Top);
        column.Children.Add(grip);
        column.Children.Add(header);
        column.Children.Add(body);
        Child = column;
        this.Res(BackgroundProperty, "InputBar");
        body.Height = height;
        Rebuild();
        _ = Start();
    }

    static Tap HeaderButton(string symbol, string tip, Action? action)
    {
        var icon = Ui.Sym(symbol, 13, "Text2");
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        return new Tap(icon, action, 8) { Width = 30, Height = 30 }.Keys("Transparent", "Fill08").Tip(tip);
    }

    /// 打开面板：拉这个会话开着的终端，一个都没有就新开一个
    async Task Start()
    {
        await TerminalStore.Shared.Refresh(key);
        if (TerminalStore.Shared.List(key) is { Count: 0 }) await OpenNew();
    }

    /// 新开一个终端，一开始就按面板的大小：先按 80 列开再缩小的话，zsh 会在第一行留下一个「%」
    async Task OpenNew()
    {
        var size = body.Bounds.Width > 1 ? body.Bounds.Size : new Size(Math.Max(400, Bounds.Width), height);
        var (cols, rows) = TermView.Grid(size, FontSize());
        await TerminalStore.Shared.Open(key, cols, rows);
    }

    static double FontSize() => Prefs.Number("terminalFontSize") ?? 13;

    void SetHeight(double value)
    {
        var top = Math.Max(160, (Parent is Visual v && TopLevel.GetTopLevel(this) is { } window ? window.Bounds.Height * 0.7 : 600));
        height = Math.Clamp(value, 120, top);
        body.Height = height;
    }

    void MoreMenu(Control anchor)
    {
        var store = TerminalStore.Shared;
        var flyout = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedRight };
        flyout.Items.Add(Ui.Item(L("放大字号"), () => SetFont(FontSize() + 1)));
        flyout.Items.Add(Ui.Item(L("缩小字号"), () => SetFont(FontSize() - 1)));
        if (store.Selected(key) is string current)
        {
            flyout.Items.Add(Ui.Divider());
            flyout.Items.Add(Ui.Item(L("关闭当前终端"), () => _ = store.Close(key, current)));
        }
        flyout.ShowAt(anchor);
    }

    void SetFont(double size)
    {
        size = Math.Clamp(size, 9, 22);
        Prefs.Set("terminalFontSize", size);
        foreach (var view in views.Values) view.FontSize = size;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        TerminalStore.Shared.PropertyChanged += StoreChanged;
        Rebuild();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        TerminalStore.Shared.PropertyChanged -= StoreChanged;
    }

    void StoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TerminalStore.Revision)) Rebuild();
    }

    /// 标签、正在看的那个终端
    void Rebuild()
    {
        var store = TerminalStore.Shared;
        var terms = store.List(key) ?? [];
        var current = store.Selected(key);
        newButton.IsEnabled = !store.IsOpening(key);
        tabs.Children.Clear();
        for (var i = 0; i < terms.Count; i++) tabs.Children.Add(Tab(terms[i], Title(terms, i), terms[i].Id == current));
        // 关掉的终端：画面也扔掉
        foreach (var gone in views.Keys.Where(id => !terms.Any(t => t.Id == id)).ToList()) views.Remove(gone);
        if (current is not null && terms.Any(t => t.Id == current))
        {
            if (!views.TryGetValue(current, out var view)) views[current] = view = new TermView(key, current, FontSize());
            if (body.Child != view)
            {
                body.Child = view;
                // 等它进了窗口、排好版再拿焦点（刚放进去就拿，输入法客户端挂不上）
                Avalonia.Threading.Dispatcher.UIThread.Post(view.FocusInput, Avalonia.Threading.DispatcherPriority.Loaded);
            }
        }
        else if (store.IsOpening(key) || store.List(key) is null)
        {
            body.Child = new TextBlock { Text = "…", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }.Res(TextBlock.ForegroundProperty, "Text2");
        }
        else
        {
            var open = new Tap(Ui.H(5, Ui.Sym("plus", 12, "Accent"), Ui.Text(L("新建终端"), 13, FontWeight.Medium, "Accent")).Pad(14, 7), () => _ = OpenNew(), 15)
                .Keys("AccentFill10", "AccentFill16");
            body.Child = Ui.V(10, Ui.Text(L("没有开着的终端"), 13, color: "Text2"), open).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center);
        }
    }

    /// 同一种 shell 开了几个：zsh、zsh 2、zsh 3（同 VS Code）
    static string Title(IReadOnlyList<TermInfo> terms, int index)
    {
        var name = terms[index].Name;
        var same = terms.Take(index).Count(t => t.Name == name);
        return same == 0 ? name : $"{name} {same + 1}";
    }

    Control Tab(TermInfo term, string title, bool selected)
    {
        var store = TerminalStore.Shared;
        var color = selected ? "Accent" : "Text";
        var row = Ui.H(5, Ui.Sym("terminal", 11, color), Ui.Text(title, 12, color: color));
        if (selected)
        {
            var close = new Tap(Ui.Sym("xmark", 9, "Accent").HAlign(HorizontalAlignment.Center), () => _ = store.Close(key, term.Id), 8) { Width = 18, Height = 18 }
                .Keys("Transparent", "AccentFill20").Tip(L("关闭终端"));
            row.Children.Add(close);
        }
        var tab = new Tap(row, () => store.Select(key, term.Id), 13) { Height = 26, Padding = new Thickness(9, 0, selected ? 4 : 9, 0) };
        if (selected) { tab.Keys("AccentFill14", "AccentFill20"); tab.BorderThickness = new Thickness(1); tab.Res(BorderBrushProperty, "AccentEdge40"); }
        else tab.Keys("Field", "Fill12");
        row.VerticalAlignment = VerticalAlignment.Center;
        row.Opacity = selected ? 1 : 0.75;
        tab.ContextMenu = new ContextMenu { ItemsSource = new Control[] { Ui.Item(L("关闭终端"), () => _ = store.Close(key, term.Id)) } };
        return tab;
    }
}
