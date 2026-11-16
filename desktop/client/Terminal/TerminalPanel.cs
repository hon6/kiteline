using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.VisualTree;
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
    /// 标签下面一行：在哪台设备上、agent 跑的命令和状态
    readonly Border place = new();
    /// 够宽时同 VS Code 分两列：左边终端、右边终端标题列表（rows）；窄的时候标签横排在上面（tabs）
    readonly StackPanel rows = new() { Spacing = 1, Margin = new Thickness(0, 4) };
    /// 终端列表（同 VS Code）：两个以上终端才显示；分隔条拖动改宽度（记住）、双击恢复默认；窄到放不下文字只剩图标
    readonly Border listColumn = new();
    readonly Border sash = new() { Width = 7, Background = Brushes.Transparent, Cursor = new Cursor(StandardCursorType.SizeWestEast), ZIndex = 1 };
    const double DefaultList = 176, MinList = 44;
    double listWidth = Prefs.Number("terminalListWidth") ?? DefaultList;
    double? listDragFrom;
    double listDragStart;
    readonly ScrollViewer tabStrip = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    readonly TextBlock headerTitle = Ui.Text("", 12, FontWeight.SemiBold);
    bool compact;
    readonly Dictionary<string, TermView> views = new();
    readonly Tap newButton;
    readonly Tap splitButton;
    /// 拖动排序：按下的那行、按下的位置、是不是已经拖起来了
    string? dragId;
    double dragY;
    bool dragging;
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
        // 拆分（同 VS Code 标题栏上的拆分按钮）：在正在看的终端旁边再开一个
        splitButton = HeaderButton("square.split.2x1", L("拆分终端"), () =>
        {
            if (TerminalStore.Shared.List(key)?.FirstOrDefault(t => t.Id == TerminalStore.Shared.Selected(key)) is TermInfo now) Split(now);
        });
        var right = Ui.H(2, newButton, splitButton, more, hide);
        DockPanel.SetDock(right, Dock.Right);
        header.Children.Add(right);
        tabStrip.Content = tabs;
        headerTitle.Margin = new Thickness(12, 0, 0, 0);
        headerTitle.VerticalAlignment = VerticalAlignment.Center;
        headerTitle.IsVisible = false;
        header.Children.Add(headerTitle);
        header.Children.Add(tabStrip);
        listColumn.Child = new ScrollViewer { Content = rows, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        listColumn.IsVisible = false;
        SetUpDragReorder();
        // 分隔条：中间一根细线，左右各留 3 好抓
        var line = new Border { Width = 1, HorizontalAlignment = HorizontalAlignment.Center };
        line.Res(Border.BackgroundProperty, "Fill12");
        sash.Child = line;
        sash.Margin = new Thickness(-3, 0, -3, 0);
        sash.IsVisible = false;
        sash.Tip(L("拖动调整终端列表宽度"));
        sash.PointerPressed += (_, e) =>
        {
            if (e.ClickCount >= 2) { SetListWidth(DefaultList); Prefs.Set("terminalListWidth", listWidth); e.Handled = true; return; }
            listDragFrom = e.GetPosition(TopLevel.GetTopLevel(this)).X; listDragStart = listColumn.Bounds.Width; e.Pointer.Capture(sash); e.Handled = true;
        };
        sash.PointerMoved += (_, e) =>
        {
            if (listDragFrom is not double from) return;
            SetListWidth(listDragStart - (e.GetPosition(TopLevel.GetTopLevel(this)).X - from));
        };
        sash.PointerReleased += (_, e) => { if (listDragFrom is null) return; listDragFrom = null; e.Pointer.Capture(null); Prefs.Set("terminalListWidth", listWidth); };
        var split = new DockPanel();
        DockPanel.SetDock(listColumn, Dock.Right);
        DockPanel.SetDock(sash, Dock.Right);
        split.Children.Add(listColumn);
        split.Children.Add(sash);
        split.Children.Add(body);
        var column = new DockPanel();
        DockPanel.SetDock(grip, Dock.Top);
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(place, Dock.Top);
        place.Margin = new Thickness(12, 0, 12, 5);
        column.Children.Add(grip);
        column.Children.Add(header);
        column.Children.Add(place);
        column.Children.Add(split);
        // 面板宽度变了：列表最多占一半
        this.GetObservable(BoundsProperty).Subscribe(new Avalonia.Reactive.AnonymousObserver<Rect>(_ => SetListWidth(listWidth)));
        Child = column;
        this.Res(BackgroundProperty, "InputBar");
        body.Height = height;
        Rebuild();
        _ = Start();
    }

    /// 列表宽度：夹在 MinList 和面板一半之间；窄到放不下文字（96）就只显示图标
    void SetListWidth(double value)
    {
        var max = Math.Max(MinList, Bounds.Width > 0 ? Bounds.Width * 0.5 : 600);
        listWidth = Math.Clamp(Math.Round(value), MinList, max);
        listColumn.Width = listWidth;
        var narrow = listWidth < 96;
        if (narrow == compact) return;
        compact = narrow;
        Rebuild();
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
        if (store.Selected(key) is string current && store.List(key)?.FirstOrDefault(t => t.Id == current) is TermInfo term)
        {
            flyout.Items.Add(Ui.Divider());
            foreach (var item in TermMenu(term)) flyout.Items.Add(item);
        }
        flyout.ShowAt(anchor);
    }

    /// 终端的右键菜单（同 VS Code）：重命名、改颜色、拆分、关闭
    List<Control> TermMenu(TermInfo term)
    {
        var store = TerminalStore.Shared;
        var items = new List<Control>
        {
            Ui.Item(L("重命名…"), async () =>
            {
                var name = await Kiteline.Views.Code.CodeWindow.Prompt(L("重命名终端"), L("留空则恢复默认名称"), term.CustomName, term.Name);
                if (name is not null) await store.Rename(key, term.Id, name);
            }),
            Ui.Submenu(L("更改颜色"), TermTabColors.All.Select(c => (Control)Ui.Item(c.Name, () => _ = store.SetColor(key, term.Id, c.Id), check: term.Color == c.Id ? "" : null))),
        };
        if (!term.Hosted && !term.IsRun) items.Add(Ui.Item(L("拆分终端"), () => Split(term)));
        if (!term.Hosted)
        {
            items.Add(Ui.Divider());
            items.Add(Ui.Item(L("关闭终端"), () => _ = store.Close(key, term.Id)));
        }
        return items;
    }

    void Split(TermInfo term)
    {
        if (term.Hosted || term.IsRun) return;
        var size = body.Bounds.Width > 1 ? new Size(body.Bounds.Width / 2, body.Bounds.Height) : new Size(Math.Max(300, Bounds.Width / 2), height);
        var (cols, rows) = TermView.Grid(size, FontSize());
        _ = TerminalStore.Shared.Split(key, term.Id, cols, rows);
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
        rows.Children.Clear();
        for (var i = 0; i < terms.Count; i++) rows.Children.Add(Row(terms[i], Title(terms, i), terms[i].Id == current));
        // 同 VS Code：标题栏只写「终端」；几个终端在右边一列切换（只有一个时不显示那列，名字写在标题栏）
        tabStrip.IsVisible = false;
        headerTitle.IsVisible = true;
        headerTitle.Text = terms.Count == 1
            ? (terms[0].Device.Length > 0 ? $"{terms[0].Device} · {terms[0].Name}" : terms[0].Name)
            : terms.Count == 0 ? L("所有终端") : $"{L("所有终端")} · {terms.Count}";
        listColumn.IsVisible = sash.IsVisible = terms.Count > 1;
        var shown = terms.FirstOrDefault(t => t.Id == current);
        place.Child = shown is null ? null : Place(shown);
        place.IsVisible = shown is not null;
        // 关掉的终端：画面也扔掉
        foreach (var gone in views.Keys.Where(id => !terms.Any(t => t.Id == id)).ToList()) views.Remove(gone);
        splitButton.IsVisible = shown is { Hosted: false, IsRun: false };
        if (current is not null && shown is not null)
        {
            if (!views.TryGetValue(current, out var view)) views[current] = view = new TermView(key, current, FontSize());
            // 拆分组（同 VS Code）：组里几个并排显示，正在看的那个加一圈淡色边；点哪个切到哪个
            var members = shown.Group is string group ? terms.Where(t => t.Group == group).ToList() : [shown];
            Control content = view;
            if (members.Count > 1)
            {
                var grid = new Grid();
                for (var i = 0; i < members.Count; i++)
                {
                    grid.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
                    var id = members[i].Id;
                    if (!views.TryGetValue(id, out var pane)) views[id] = pane = new TermView(key, id, FontSize());
                    (pane.Parent as Panel)?.Children.Remove(pane);
                    (pane.Parent as Border)?.SetValue(Border.ChildProperty, null);
                    var frame = new Border { Child = pane, BorderThickness = new Thickness(i > 0 ? 1 : 0, 0, 0, 0) };
                    frame.Res(Border.BorderBrushProperty, "Fill12");
                    if (id == current)
                    {
                        var ring = new Border { BorderThickness = new Thickness(1), IsHitTestVisible = false };
                        ring.Res(Border.BorderBrushProperty, "AccentEdge40");
                        frame.Child = new Panel { Children = { pane, ring } };
                    }
                    frame.AddHandler(PointerPressedEvent, (_, _) => { if (TerminalStore.Shared.Selected(key) != id) TerminalStore.Shared.Select(key, id); },
                                     Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
                    Grid.SetColumn(frame, i);
                    grid.Children.Add(frame);
                }
                content = grid;
            }
            else
            {
                (view.Parent as Panel)?.Children.Remove(view);
                (view.Parent as Border)?.SetValue(Border.ChildProperty, null);
            }
            if (body.Child != content)
            {
                body.Child = content;
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
            var label = store.Device(key) is string device ? L("在「%@」上新建终端", device) : L("新建终端");
            var open = new Tap(Ui.H(5, Ui.Sym("plus", 12, "Accent"), Ui.Text(label, 13, FontWeight.Medium, "Accent")).Pad(14, 7), () => _ = OpenNew(), 15)
                .Keys("AccentFill10", "AccentFill16");
            body.Child = Ui.V(10, Ui.Text(L("没有开着的终端"), 13, color: "Text2"), open).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center);
        }
    }

    /// 同一台设备上同一种 shell 开了几个：zsh、zsh 2、zsh 3（同 VS Code）
    static string Title(IReadOnlyList<TermInfo> terms, int index)
    {
        var term = terms[index];
        var same = terms.Take(index).Count(t => t.Name == term.Name && t.Device == term.Device);
        return same == 0 ? term.Name : $"{term.Name} {same + 1}";
    }

    /// 标签下面一行：这个终端在哪台设备上、agent 跑的是什么命令、跑完没有。设备名放最前面加粗，一眼分清是哪台
    Control Place(TermInfo term)
    {
        var home = TerminalStore.Shared.Device(key);
        var icon = home is null || home == term.Device ? "desktopcomputer" : "arrow.triangle.branch";
        var line = new DockPanel { LastChildFill = true };
        var left = Ui.H(6, Ui.Sym(icon, 11, "Text2"), Ui.Text(term.Device.Length > 0 ? term.Device : L("电脑"), 12, FontWeight.SemiBold));
        DockPanel.SetDock(left, Dock.Left);
        line.Children.Add(left);
        if (term.IsRun)
        {
            var state = term.Ended
                ? (term.ExitCode is int code && code != 0 ? Ui.Text(L("已结束，退出码 %lld", code), 11, color: "Accent") : Ui.Text(L("已完成"), 11, color: "Text2"))
                : Ui.Text(L("Agent 运行中"), 11, color: "Text2");
            DockPanel.SetDock(state, Dock.Right);
            line.Children.Add(state);
            var command = Ui.Text(term.Run, 11, color: "Text2");
            command.FontFamily = new FontFamily("Cascadia Mono, Consolas, DejaVu Sans Mono, monospace");
            command.TextTrimming = TextTrimming.CharacterEllipsis;
            command.Margin = new Thickness(8, 0);
            line.Children.Add(command);
        }
        else
        {
            var cwd = Ui.Text(term.Cwd, 11, color: "Text2");
            cwd.TextTrimming = TextTrimming.PrefixCharacterEllipsis;
            cwd.Margin = new Thickness(8, 0, 0, 0);
            line.Children.Add(cwd);
        }
        return line;
    }

    static string TabIcon(TermInfo term) =>
        !term.IsRun ? "terminal" : !term.Ended ? "play" : (term.ExitCode ?? 0) == 0 ? "checkmark.circle" : "exclamationmark.circle";

    /// 右边一列的一行（同 VS Code 的终端列表）：图标 + 设备名（加粗）+ 名字；正在看的那行淡色底加细边，关闭按钮在选中那行
    /// 拆分组在列表里的连线（同 VS Code）：组里第一个 ┌、中间 ├、最后 └
    string Connector(TermInfo term)
    {
        if (term.Group is not string group) return "";
        var members = (TerminalStore.Shared.List(key) ?? []).Where(t => t.Group == group).ToList();
        if (members.Count < 2) return "";
        return members[0].Id == term.Id ? "┌" : members[^1].Id == term.Id ? "└" : "├";
    }

    /// 拖动排序（同 VS Code）：在列表里按住一行上下拖，松开时放到手指下那一行的前面（拖到最后一行下半截 = 放到最后）
    void SetUpDragReorder()
    {
        rows.AddHandler(PointerPressedEvent, (_, e) =>
        {
            dragId = (e.Source as Control)?.FindAncestorOfType<Tap>(includeSelf: true)?.Tag as string;
            dragY = e.GetPosition(rows).Y;
            dragging = false;
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        rows.AddHandler(PointerMovedEvent, (_, e) =>
        {
            if (dragId is null) return;
            var y = e.GetPosition(rows).Y;
            if (!dragging && Math.Abs(y - dragY) < 6) return;
            dragging = true;
            foreach (var child in rows.Children) child.Opacity = child.Tag as string == dragId ? 0.5 : 1;
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        rows.AddHandler(PointerReleasedEvent, (_, e) =>
        {
            var id = dragId;
            dragId = null;
            if (!dragging || id is null) return;
            dragging = false;
            var y = e.GetPosition(rows).Y;
            string? before = null;
            foreach (var child in rows.Children)
            {
                if (child.Tag as string is not string other || other == id) continue;
                if (y < child.Bounds.Y + child.Bounds.Height / 2) { before = other; break; }
            }
            _ = TerminalStore.Shared.Move(key, id, before);
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
    }

    Control Row(TermInfo term, string title, bool selected)
    {
        var store = TerminalStore.Shared;
        var color = selected ? "Accent" : "Text";
        var label = term.Device.Length > 0 ? $"{term.Device} · {title}" : title;
        var line = new DockPanel { LastChildFill = true };
        // 删除（同 VS Code 悬停出现的垃圾桶）：常驻占位、只改透明度，悬停时不增删控件；「claude」主终端不给关
        var close = new Tap(Ui.Sym("trash", 10, color).HAlign(HorizontalAlignment.Center), () => _ = store.Close(key, term.Id), 6) { Width = 18, Height = 18 }
            .Keys("Transparent", "AccentFill20").Tip(L("关闭终端"));
        close.Opacity = 0;
        close.IsHitTestVisible = false;
        if (!compact)
        {
            DockPanel.SetDock(close, Dock.Right);
            line.Children.Add(close);
        }
        var icon = Ui.Sym(TabIcon(term), 11, color);
        if (TermTabColors.Brush(term.Color) is IBrush tint) icon.Foreground = tint;
        var left = Ui.H(6, icon);
        if (Connector(term) is { Length: > 0 } link && !compact)
            left.Children.Insert(0, Ui.Text(link, 12, color: "Text3"));
        if (!compact)
        {
            if (term.Device.Length > 0) left.Children.Add(Ui.Text(term.Device, 12, FontWeight.SemiBold, color));
            left.Children.Add(Ui.Text(title, 12, color: selected ? "Accent" : "Text2").Trim());
        }
        else left.HorizontalAlignment = HorizontalAlignment.Center;
        line.Children.Add(left);
        line.VerticalAlignment = VerticalAlignment.Center;
        var row = new Tap(line, () => store.Select(key, term.Id), 5) { Height = 24, Padding = compact ? new Thickness(0) : new Thickness(8, 0, 4, 0), Margin = new Thickness(4, 0) };
        if (!term.Hosted)
        {
            row.PointerEntered += (_, _) => { close.Opacity = 1; close.IsHitTestVisible = true; };
            row.PointerExited += (_, _) => { close.Opacity = 0; close.IsHitTestVisible = false; };
        }
        if (selected) { row.Keys("AccentFill14", "AccentFill20"); row.BorderThickness = new Thickness(1); row.Res(BorderBrushProperty, "AccentEdge40"); }
        else row.Keys("Transparent", "Fill08");
        row.Tip(label + "\n" + (term.Hosted ? L("Claude 主终端（后台运行），不能关闭") : term.IsRun ? term.Run : term.Cwd));
        row.ContextMenu = new ContextMenu { ItemsSource = TermMenu(term) };
        row.Tag = term.Id;   // 拖动排序时认是哪一行
        return row;
    }

    Control Tab(TermInfo term, string title, bool selected)
    {
        var store = TerminalStore.Shared;
        var color = selected ? "Accent" : "Text";
        var row = Ui.H(5, Ui.Sym(TabIcon(term), 11, color));
        if (term.Device.Length > 0)
        {
            row.Children.Add(Ui.Text(term.Device, 12, FontWeight.SemiBold, color));
            row.Children.Add(Ui.Text("·", 12, color: "Text2"));
        }
        row.Children.Add(Ui.Text(title, 12, color: color));
        if (selected && !term.Hosted)   // 后台运行会话的「claude」主终端不给关
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
        if (!term.Hosted) tab.ContextMenu = new ContextMenu { ItemsSource = new Control[] { Ui.Item(L("关闭终端"), () => _ = store.Close(key, term.Id)) } };
        return tab;
    }
}

/// 终端的颜色（同 VS Code 终端的「更改颜色」，取终端调色板里不刺眼的几种；同 iPhone / Mac 的 TermColor）
static class TermTabColors
{
    public sealed record Choice(string Id, string Name);
    public static readonly Choice[] All =
    [
        new("", L("默认")), new("red", L("红色")), new("green", L("绿色")), new("yellow", L("黄色")),
        new("blue", L("蓝色")), new("magenta", L("紫色")), new("cyan", L("青色")),
    ];

    public static IBrush? Brush(string id) => id switch
    {
        "red" => new SolidColorBrush(Color.Parse("#D9534F")),
        "green" => new SolidColorBrush(Color.Parse("#3FA66B")),
        "yellow" => new SolidColorBrush(Color.Parse("#C9A227")),
        "blue" => new SolidColorBrush(Color.Parse("#3B82C4")),
        "magenta" => new SolidColorBrush(Color.Parse("#A25CC4")),
        "cyan" => new SolidColorBrush(Color.Parse("#2A9DB0")),
        _ => null,
    };
}
