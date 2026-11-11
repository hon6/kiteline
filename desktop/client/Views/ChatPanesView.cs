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

/// 右边的分屏（同 Mac 版 ChatPanesView）：一块块会话，左右、上下随便分；每块顶上一排浏览器式的标签。
/// 最上面一排的标签栏铺进窗口标题栏那一带（Windows 上右上角让给系统的窗口按钮），空白处能拖动窗口
public sealed class ChatPanesView : Panel
{
    readonly ChatPanes panes = ChatPanes.Shared;
    /// 每个开着的会话（群）一份对话页（群聊页），切标签、换块时不重新加载
    readonly Dictionary<string, Control> chats = new();

    public ChatPanesView()
    {
        this.Res(BackgroundProperty, "ChatBackground");
        panes.Changed += Schedule;
        AppModel.Shared.PropertyChanged += (_, e) => { if (e.PropertyName is nameof(AppModel.Sessions) or nameof(AppModel.PastMeta) or nameof(AppModel.Marked)) Schedule(); };
        // 群：标签上的群名、成员数，标签栏上成员按钮的实心空心
        GroupState.Shared.PropertyChanged += GroupsChanged;
        GroupChatPage.DrawerChanged += Schedule;
        DetachedFromVisualTree += (_, _) =>
        {
            panes.Changed -= Schedule;
            GroupState.Shared.PropertyChanged -= GroupsChanged;
            GroupChatPage.DrawerChanged -= Schedule;
            foreach (var chat in chats.Values.OfType<ChatView>()) chat.Closed();
            chats.Clear();
        };
        Rebuild();
    }

    void GroupsChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not (nameof(GroupState.Items) or nameof(GroupState.Supported))) return;
        Dispatcher.UIThread.Post(() =>
        {
            // 解散了的群（自己解散、别的设备上解散）：它的标签跟着关掉。群列表取到以后才比（刚启动时还没取到，别把上次开着的群关了）
            if (GroupState.Shared.Supported)
                foreach (var key in panes.Keys.Where(k => MainModel.GroupIdOf(k) is string id && GroupState.Shared.Group(id) is null).ToList()) panes.Close(key);
            Schedule();
        });
    }

    bool pending;
    void Schedule()
    {
        if (pending) return;
        pending = true;
        Dispatcher.UIThread.Post(() => { pending = false; Rebuild(); }, DispatcherPriority.Background);
    }

    void Rebuild()
    {
        var keys = panes.Keys.ToHashSet();
        foreach (var gone in chats.Keys.Where(k => !keys.Contains(k)).ToList())
        {
            (chats[gone] as ChatView)?.Closed();
            chats.Remove(gone);
        }
        // 对话页先从老的父级上摘下来，再挂到新排的树上
        foreach (var chat in chats.Values) if (chat.Parent is Panel p) p.Children.Remove(chat); else if (chat.Parent is Decorator d) d.Child = null; else if (chat.Parent is ContentControl c) c.Content = null;
        Children.Clear();
        Children.Add(Node(panes.Root, atTop: true, atRight: true));
        // 分屏时同一封信的两张信件用绳子连起来（盖在最上面，只有贴着绳子的地方接鼠标）
        if (panes.Count > 1) Children.Add(ropes);
    }

    readonly PeerRopeLayer ropes = new();

    public Control Chat(string key, Guid pane)
    {
        // 群同会话一样开成一个标签：内容是群聊页
        if (!chats.TryGetValue(key, out var chat)) chats[key] = chat = MainModel.GroupIdOf(key) is string id ? new GroupChatPage(id) : new ChatView(key);
        if (chat is ChatView view) view.Pane = pane;
        return chat;
    }

    Control Node(ChatPanes.Node node, bool atTop, bool atRight) => node switch
    {
        ChatPanes.PaneNode p => new PaneView(this, p.Pane, atTop, atRight),
        ChatPanes.SplitNode s => new SplitView(this, s, atTop, atRight),
        _ => new Panel(),
    };

    /// 一层分割：几项左右或上下排，中间是能拖的分隔条
    internal sealed class SplitView : Panel
    {
        readonly ChatPanes.SplitNode split;
        readonly List<Control> items = [];
        readonly List<PaneDivider> dividers = [];

        public SplitView(ChatPanesView owner, ChatPanes.SplitNode split, bool atTop, bool atRight)
        {
            this.split = split;
            var horizontal = split.Axis == Axis.Horizontal;
            for (var i = 0; i < split.Items.Count; i++)
            {
                if (i > 0)
                {
                    var divider = new PaneDivider(split, i - 1, this);
                    dividers.Add(divider);
                    Children.Add(divider);
                }
                // 左右分的只有最右边那项还贴着右边（Windows 的窗口按钮），上下分的只有第一项还贴着顶边
                var item = owner.Node(split.Items[i], atTop && (horizontal || i == 0), atRight && (!horizontal || i == split.Items.Count - 1));
                items.Add(item);
                Children.Add(item);
            }
        }

        public double Length => Math.Max(0, (split.Axis == Axis.Horizontal ? Bounds.Width : Bounds.Height) - (split.Items.Count - 1) * ChatPanes.DividerThickness);

        protected override Size MeasureOverride(Size available)
        {
            Arrange(available, measure: true);
            return available;
        }

        protected override Size ArrangeOverride(Size final)
        {
            Arrange(final, measure: false);
            return final;
        }

        void Arrange(Size size, bool measure)
        {
            var horizontal = split.Axis == Axis.Horizontal;
            var total = horizontal ? size.Width : size.Height;
            if (double.IsInfinity(total)) total = 800;
            var length = Math.Max(0, total - (split.Items.Count - 1) * ChatPanes.DividerThickness);
            double pos = 0;
            for (var i = 0; i < items.Count; i++)
            {
                if (i > 0)
                {
                    var d = dividers[i - 1];
                    var rect = horizontal ? new Rect(pos - 4, 0, ChatPanes.DividerThickness + 8, size.Height) : new Rect(0, pos - 4, size.Width, ChatPanes.DividerThickness + 8);
                    if (measure) d.Measure(rect.Size); else d.Arrange(rect);
                    pos += ChatPanes.DividerThickness;
                }
                var share = length * (i < split.Fractions.Count ? split.Fractions[i] : 1.0 / items.Count);
                var r = horizontal ? new Rect(pos, 0, share, size.Height) : new Rect(0, pos, size.Width, share);
                if (measure) items[i].Measure(r.Size); else items[i].Arrange(r);
                pos += share;
            }
        }
    }

    /// 块与块之间的分隔条：一道细线，按住拖调大小，双击恢复平分（同 Mac 版 PaneDivider）。
    /// 鼠标移到线上时指针处出现一个带箭头的小圆钮（提示能左右 / 上下拖），拖动时圆钮跟着指针走、高亮
    internal sealed class PaneDivider : Control
    {
        readonly ChatPanes.SplitNode split;
        readonly int index;
        readonly SplitView owner;
        List<double>? start;
        Point origin;
        bool hover;
        /// 指针在分隔条上的位置（圆钮沿着线跟着它走）
        Point pointer;

        public PaneDivider(ChatPanes.SplitNode split, int index, SplitView owner)
        {
            this.split = split;
            this.index = index;
            this.owner = owner;
            Cursor = new Cursor(split.Axis == Axis.Horizontal ? StandardCursorType.SizeWestEast : StandardCursorType.SizeNorthSouth);
            ToolTip.SetTip(this, L("拖动调整大小，双击恢复均分"));
            ZIndex = 1;
        }

        /// 自测截图：画成指针停在线上 along 处的样子
        public void DebugHover(double along) { hover = true; pointer = new Point(along, along); InvalidateVisual(); }

        protected override void OnPointerEntered(PointerEventArgs e) { hover = true; pointer = e.GetPosition(this); InvalidateVisual(); }
        protected override void OnPointerExited(PointerEventArgs e) { hover = false; InvalidateVisual(); }

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            if (e.ClickCount == 2) { ChatPanes.Shared.Equalize(split.SplitId); e.Handled = true; return; }
            start = ChatPanes.Shared.Fractions(split.SplitId);
            origin = e.GetPosition(owner);
            e.Pointer.Capture(this);
            e.Handled = true;
        }

        protected override void OnPointerMoved(PointerEventArgs e)
        {
            pointer = e.GetPosition(this);
            if (start is null) { if (hover) InvalidateVisual(); return; }
            InvalidateVisual();
            var p = e.GetPosition(owner);
            var delta = split.Axis == Axis.Horizontal ? p.X - origin.X : p.Y - origin.Y;
            ChatPanes.Shared.Drag(split.SplitId, index, start, delta / Math.Max(owner.Length, 1), owner.Length);
        }

        protected override void OnPointerReleased(PointerReleasedEventArgs e)
        {
            start = null;
            e.Pointer.Capture(null);
            InvalidateVisual();
        }

        public override void Render(DrawingContext context)
        {
            var dragging = start is not null;
            var brush = Palette.Get(hover || dragging ? "Fill15" : "Fill12");
            var horizontal = split.Axis == Axis.Horizontal;
            var rect = horizontal ? new Rect(4, 0, ChatPanes.DividerThickness, Bounds.Height) : new Rect(0, 4, Bounds.Width, ChatPanes.DividerThickness);
            context.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));
            context.FillRectangle(brush, rect);
            if (!hover && !dragging) return;
            // 圆钮：钉在线上、沿线跟着指针（离两头至少半个钮）
            const double r = 11;
            var center = horizontal
                ? new Point(rect.Center.X, Math.Clamp(pointer.Y, r + 2, Math.Max(r + 2, Bounds.Height - r - 2)))
                : new Point(Math.Clamp(pointer.X, r + 2, Math.Max(r + 2, Bounds.Width - r - 2)), rect.Center.Y);
            var accent = Palette.GetColor("Accent");
            var fill = dragging ? new SolidColorBrush(accent) : Palette.Get("GlassSolid");
            var edge = new Pen(dragging ? new SolidColorBrush(accent) : Palette.Get("Fill15"), 1);
            context.DrawEllipse(fill, edge, center, r, r);
            // 双向箭头：一道短线、两头各一个尖
            var ink = new Pen(dragging ? Brushes.White : Palette.Get("Text2"), 1.4, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
            Point P(double along, double across) => horizontal ? new Point(center.X + along, center.Y + across) : new Point(center.X + across, center.Y + along);
            context.DrawLine(ink, P(-5.5, 0), P(5.5, 0));
            context.DrawLine(ink, P(-5.5, 0), P(-2.5, -3));
            context.DrawLine(ink, P(-5.5, 0), P(-2.5, 3));
            context.DrawLine(ink, P(5.5, 0), P(2.5, -3));
            context.DrawLine(ink, P(5.5, 0), P(2.5, 3));
        }
    }

    /// 一块：顶上标签栏，下面是对话（还没选会话就列出能选的）；会话拖到上面时标出会落在哪
    sealed class PaneView : Panel
    {
        readonly ChatPanes.Pane pane;
        readonly Border overlay = new() { IsHitTestVisible = false, IsVisible = false, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1.5) };
        readonly TextBlock hint = Ui.Text("", 12, FontWeight.SemiBold, "Accent");
        readonly Control body;

        public PaneView(ChatPanesView owner, ChatPanes.Pane pane, bool atTop, bool atRight)
        {
            this.pane = pane;
            ClipToBounds = true;
            var header = new PaneHeader(pane, atTop, atRight);
            body = pane.Key is string key ? owner.Chat(key, pane.Id) : new PanePicker(pane.Id);
            var dock = new DockPanel();
            DockPanel.SetDock(header, Dock.Top);
            dock.Children.Add(header);
            dock.Children.Add(body);
            Children.Add(dock);
            overlay.Res(Border.BackgroundProperty, "AccentFill10").Res(Border.BorderBrushProperty, "AccentEdge40");
            overlay.Child = hint.HAlign(HorizontalAlignment.Center);
            Children.Add(overlay);
            DragDrop.SetAllowDrop(this, true);
            AddHandler(DragDrop.DragOverEvent, DragOver);
            AddHandler(DragDrop.DragLeaveEvent, (_, _) => overlay.IsVisible = false);
            AddHandler(DragDrop.DropEvent, Drop);
            // 在这一块里按下去（点消息、点输入框、拖滚动条……）：它就是当前块，接着弹的窗（文件、会话信息、确认……）对着它居中
            AddHandler(PointerPressedEvent, (_, _) => { ChatPanes.Shared.Focus(pane.Id); Dialog.Anchor = body; }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        }

        protected override Size ArrangeOverride(Size final)
        {
            ChatPanes.Shared.Sizes[pane.Id] = (final.Width, final.Height);
            return base.ArrangeOverride(final);
        }

        (string Key, Guid? Source)? Payload(DragEventArgs e) => PaneDrag.Decode(e.Data.Get(PaneDrag.Format));

        void DragOver(object? sender, DragEventArgs e)
        {
            if (Payload(e) is not { } p) { e.DragEffects = DragDropEffects.None; return; }
            var at = e.GetPosition(this);
            var zone = ChatPanes.Shared.Zone(at.X, at.Y, pane.Id, p.Source, p.Key);
            if (zone is null) { overlay.IsVisible = false; e.DragEffects = DragDropEffects.None; return; }
            // 从列表拖来的会话停在群聊这块中间：松开是进群（拖进群 = Link，见 Sidebar 的 StartDrag）
            var joining = zone == DropZone.Center && p.Source is null ? GroupChatPage.Joinable(p.Key, pane.Key) : null;
            e.DragEffects = joining is null ? DragDropEffects.Move : DragDropEffects.Link;
            var w = Bounds.Width; var h = Bounds.Height;
            var rect = zone switch
            {
                DropZone.Leading => new Rect(0, 0, w / 2, h),
                DropZone.Trailing => new Rect(w / 2, 0, w / 2, h),
                DropZone.Top => new Rect(0, 0, w, h / 2),
                DropZone.Bottom => new Rect(0, h / 2, w, h / 2),
                _ => new Rect(0, 0, w, h),
            };
            rect = rect.Deflate(6);
            overlay.Margin = new Thickness(rect.X, rect.Y, w - rect.Right, h - rect.Bottom);
            hint.Text = joining is not null ? L("松开加入群「%@」", joining.Name) : zone switch
            {
                DropZone.Leading => L("放到左侧"), DropZone.Trailing => L("放到右侧"), DropZone.Top => L("放到上方"),
                DropZone.Bottom => L("放到下方"), _ => L("放置于此"),
            };
            hint.VerticalAlignment = VerticalAlignment.Center;
            overlay.IsVisible = true;
        }

        void Drop(object? sender, DragEventArgs e)
        {
            overlay.IsVisible = false;
            if (Payload(e) is not { } p) return;
            var at = e.GetPosition(this);
            if (ChatPanes.Shared.Zone(at.X, at.Y, pane.Id, p.Source, p.Key) is DropZone zone)
            {
                if (zone == DropZone.Center && p.Source is null && GroupChatPage.JoinDropped(p.Key, pane.Key)) return;
                ChatPanes.Shared.Drop(p.Key, p.Source, pane.Id, zone);
                MainModel.Shared.Selection = ChatPanes.Shared.Focused;
            }
        }
    }
}

/// 每块顶上的标签栏（同 Mac 版 PaneHeader 的 macBody）：深一点的标签栏上一张圆角标签和下面的对话连成一片，
/// 右边是会话自己的按钮（文件、改动、测试、在 VS Code 中打开）、分屏按钮和「更多」；块窄了按钮依次折进「更多」
public sealed class PaneHeader : Panel
{
    public const double TabRow = 36;
    const double Foot = 7;
    const double MinTab = 96;
    const double MaxTab = 240;

    readonly ChatPanes.Pane pane;
    readonly bool atTop;
    readonly bool atRight;
    readonly double rise;

    public PaneHeader(ChatPanes.Pane pane, bool atTop, bool atRight)
    {
        this.pane = pane;
        this.atTop = atTop;
        this.atRight = atRight;
        // 组的名字、颜色变了：标签栏重排一次（色块和底线）
        AttachedToVisualTree += (_, _) => TabGroupState.Shared.PropertyChanged += OnGroupsChanged;
        DetachedFromVisualTree += (_, _) => TabGroupState.Shared.PropertyChanged -= OnGroupsChanged;
        // 最上面一排：标签栏往上长到窗口顶（标题栏那一带），标签贴着底边
        rise = atTop ? Math.Max(0, MainWindow.TitlebarHeight - TabRow) : 0;
        Height = TabRow + rise;
        ClipToBounds = true;
        Background = Brushes.Transparent;
    }

    double lastWidth = -1;

    void OnGroupsChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        lastWidth = -1;
        InvalidateMeasure();
    }

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 800 : available.Width;
        if (Math.Abs(width - lastWidth) > 0.5) { lastWidth = width; Build(width); }
        return base.MeasureOverride(available);
    }

    IReadOnlyList<string?> Entries => [.. pane.Tabs.Select(t => (string?)t), .. pane.Key is null ? new string?[] { null } : []];

    void Build(double width)
    {
        Children.Clear();
        var panes = ChatPanes.Shared;
        var model = AppModel.Shared;
        var several = panes.Count > 1;
        var focused = panes.FocusId == pane.Id;
        // 底色：对话底色上压一层暗色；底边一道细线（正显示的标签盖住自己那一段）
        Children.Add(new Border().Res(Border.BackgroundProperty, "ChatBackground"));
        Children.Add(new Border().Res(Border.BackgroundProperty, "TabStrip"));
        // 有会话组正显示时底边那道线换成组的颜色（同 Mac 版）
        var line = new Border { Height = 0.5, VerticalAlignment = VerticalAlignment.Bottom };
        if (TabGroupState.Shared.Group(TabGroupState.Shared.Active) is not null) line.Background = TabGroupState.Shared.ColorOf(TabGroupState.Shared.Active).Brush;
        else line.Res(Border.BackgroundProperty, "Separator");
        Children.Add(line);
        var drag = new Border { Background = Brushes.Transparent };
        drag.PointerPressed += WindowDrag;
        Children.Add(drag);

        var caption = atTop && atRight ? MainWindow.CaptionWidth : 0;
        var entries = Entries;
        var count = Math.Max(1, entries.Count);
        // 群在块窄时还多留一个成员按钮
        // 会话组的色块 + 组名放在最左边（只在最左上角的那块的标签栏上）
        var chip = TabGroupState.Shared.Active is not null && ChatPanes.Shared.Panes.Count > 0 && ChatPanes.Shared.Panes[0].Id == pane.Id ? TabGroupChip.Make() : null;
        double Room(int level) => Math.Max(0, width - 12 - caption - ActionsWidth(level) - (chip is null ? 0 : 130) - (level < 2 && MainModel.GroupIdOf(pane.Key) is not null ? 48 : 0) - 30);
        var level = new[] { 2, 1 }.FirstOrDefault(l => Room(l) / count >= 120, 0);
        var room = Room(level);
        var cap = Math.Min(MaxTab, Math.Max(MinTab, room / count));

        var tabs = new TabsLayout(MinTab, MaxTab, pane.Key is not null) { VerticalAlignment = VerticalAlignment.Bottom };
        for (var i = 0; i < entries.Count; i++)
        {
            var key = entries[i];
            var divider = i > 0 && key != pane.Key && entries[i - 1] != pane.Key;
            tabs.Children.Add(new PaneTab(key, pane, focused, several, cap, divider));
        }
        if (pane.Key is not null)
            tabs.Children.Add(PaneButton("plus", L("新标签页：选择要在此打开的会话"), () => { panes.NewTab(pane.Id); MainModel.Shared.Selection = null; }).Margin(2, 0, 0, 5).VAlign(VerticalAlignment.Bottom));
        Control tabArea = tabs;
        if (entries.Count * MinTab > room)
        {
            var scroller = new ScrollViewer { Content = tabs, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
            tabArea = scroller;
            // 放不下要横着滚时，正显示的那个标签滚进来（不然块窄、左边又有会话组色块时，刚打开的群聊标签被挤到看不见的地方）
            var index = entries.ToList().IndexOf(pane.Key);
            if (index > 0)
            {
                void Reveal(object? sender, EventArgs e)
                {
                    if (tabs.Children.Count <= index || tabs.Children[index].Bounds.Width <= 0) return;
                    scroller.LayoutUpdated -= Reveal;
                    var tab = tabs.Children[index].Bounds;
                    var view = scroller.Viewport.Width;
                    if (tab.Right > scroller.Offset.X + view) scroller.Offset = new Vector(Math.Max(0, tab.Right - view), 0);
                }
                scroller.LayoutUpdated += Reveal;
            }
        }

        var actions = Actions(several, focused, level);
        var row = new DockPanel { Margin = new Thickness(6, rise, 6 + caption, 0), Height = TabRow, VerticalAlignment = VerticalAlignment.Bottom };
        DockPanel.SetDock(actions, Dock.Right);
        row.Children.Add(actions);
        if (chip is not null)
        {
            DockPanel.SetDock(chip, Dock.Left);
            chip.VerticalAlignment = VerticalAlignment.Bottom;
            row.Children.Add(chip);
        }
        row.Children.Add(tabArea);
        Children.Add(row);
    }

    static double ActionsWidth(int level) => new double[] { 26, 78, 190 }[Math.Clamp(level, 0, 2)];

    /// 右边的按钮：会话自己的（对正显示的那个标签）、左右 / 上下分屏、「更多」
    Control Actions(bool several, bool focused, int level)
    {
        var model = AppModel.Shared;
        var panes = ChatPanes.Shared;
        var color = focused || !several ? "Text2" : "Text3";
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (level == 2 && pane.Key is string key)
        {
            foreach (var b in MainModel.GroupIdOf(key) is string gid ? GroupButtons(gid, color) : SessionButtons(key, color)) row.Children.Add(b);
            row.Children.Add(new Border { Width = 8 });
        }
        else if (MainModel.GroupIdOf(pane.Key) is string narrowGroup)
        {
            // 块再窄：会话的按钮、分屏按钮都折进「更多」，群的成员按钮一直留着（看成员、拉人都从它进）
            foreach (var b in GroupButtons(narrowGroup, color, membersOnly: true)) row.Children.Add(b);
            row.Children.Add(new Border { Width = 4 });
        }
        if (level >= 1)
        {
            row.Children.Add(PaneButton("square.split.2x1", L("左右分屏：在右侧新开一块，选择要显示的会话"), () => Split(false), color));
            row.Children.Add(PaneButton("square.split.1x2", L("上下分屏：在下方新开一块，选择要显示的会话"), () => Split(true), color));
        }
        var more = PaneButton("ellipsis", L("更多"), () => { }, color, bold: true);
        more.Click = () =>
        {
            var menu = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedRight };
            if (MainModel.GroupIdOf(pane.Key) is string gid)
                foreach (var item in GroupChatPage.MenuItems(gid, level < 2)) menu.Items.Add(item);
            else if (pane.Key is string k)
            {
                if (level < 2) foreach (var item in FoldedItems(k)) menu.Items.Add(item);
                foreach (var item in SessionMenu.Items(model, MainModel.Shared, k)) menu.Items.Add(item);
                if (model.Session(k) is null && model.PastMeta.TryGetValue(k, out var past))
                {
                    menu.Items.Add(Ui.Item(L("在 VS Code 中恢复"), () => Resume(past)));
                    menu.Items.Add(Ui.Item(L("历史会话"), () => MainModel.Shared.Selection = MainModel.HistoryId));
                }
            }
            if (level < 1 || several)
            {
                if (menu.Items.Count > 0) menu.Items.Add(new Separator());
                menu.Items.Add(Ui.Item(L("左右分屏"), () => Split(false)));
                menu.Items.Add(Ui.Item(L("上下分屏"), () => Split(true)));
                if (several) menu.Items.Add(Ui.Item(L("关闭此分屏"), () => panes.Close(pane.Id)));
            }
            menu.ShowAt(more);
        };
        row.Children.Add(more);
        return row;
    }

    /// 块太窄、标签栏上的按钮折进「更多」：排在最前面
    IEnumerable<Control> FoldedItems(string key)
    {
        if (AppModel.Shared.Session(key) is not null)
        {
            yield return Ui.Item(L("文件"), () => ChatActions.Perform(key, SessionAction.Files));
            yield return Ui.Item(L("改动"), () => ChatActions.Perform(key, SessionAction.Changes));
            yield return Ui.Item(L("测试"), () => ChatActions.Perform(key, SessionAction.Tests));
            yield return new Separator();
        }
        else yield return Ui.Item(L("文件"), () => ChatActions.Perform(key, SessionAction.Files));
    }

    /// 标签栏上会话自己的按钮（同 Mac 版 PaneButtons）：正在跑的 = 文件、改动、测试、在 VS Code 中打开；已结束的 = 文件、在 VS Code 中恢复
    static IEnumerable<Control> SessionButtons(string key, string color)
    {
        var model = AppModel.Shared;
        if (model.Session(key) is not null)
        {
            // 标记：主题色实心星；点一下标记、再点取消
            var marked = model.IsMarked(key);
            yield return PaneButton(marked ? "star.fill" : "star", marked ? L("已标记，点按取消标记") : L("标记：排在所有列表的最上面"),
                () => model.SetMarked(key, !marked), marked ? "Accent" : color);
            yield return PaneButton("folder", L("文件：浏览此项目的文件（只读）"), () => ChatActions.Perform(key, SessionAction.Files), color);
            yield return PaneButton("plusminus.circle", L("改动：此项目的文件改动与最近提交"), () => ChatActions.Perform(key, SessionAction.Changes), color);
            yield return PaneButton("checkmark.seal", L("测试：Claude 运行过的测试及结果"), () => ChatActions.Perform(key, SessionAction.Tests), color);
            yield return PaneButton("arrow.up.forward.app", L("在 VS Code 中打开：切换到此会话所在的 VS Code 窗口"), () => SessionMenu.Jump(key), color);
        }
        else if (model.PastMeta.TryGetValue(key, out var past))
        {
            yield return PaneButton("folder", L("文件：浏览此项目的文件（只读）"), () => ChatActions.Perform(key, SessionAction.Files), color);
            yield return PaneButton("arrow.uturn.forward.circle", L("在 VS Code 中恢复此对话并继续（也可直接在下方输入框发送消息）"), () => Resume(past), color);
        }
    }

    /// 标签栏上群的按钮（同 iOS / Mac 版 GroupPaneButtons）：标记、成员（人形 + 人数，点开右边滑出成员面板，开着时实心）
    static IEnumerable<Control> GroupButtons(string id, string color, bool membersOnly = false)
    {
        if (GroupState.Shared.Group(id) is not GroupInfo group) yield break;
        if (!membersOnly)
            yield return PaneButton(group.Marked ? "star.fill" : "star", group.Marked ? L("已标记，点按取消标记") : L("标记：排在所有列表的最上面"),
                () => GroupState.Shared.Mark(id, !group.Marked), group.Marked ? "Accent" : color);
        var open = GroupChatPage.MembersOpen(id);
        var members = new Tap(Ui.H(3, Ui.Sym(open ? "person.2.fill" : "person.2", 13, color), Ui.Text(group.Members.Count.ToString(), 11.5, FontWeight.Medium, color).Digits()),
            () => GroupChatPage.ToggleMembers(id), 6) { Height = 24, MinWidth = 26, Padding = new Thickness(6, 0) }.Keys("Transparent", "Fill10", "Fill12");
        members.Tip(L("群成员"));
        yield return members;
    }

    static async void Resume(PastSession past)
    {
        try
        {
            // editor：按钮写明了「在 VS Code 中恢复」，远端项目也开 VS Code、不在后台运行（旧版电脑端不认这项，照旧）
            var reply = await AppModel.Shared.Api.Post("/api/resume", new Dictionary<string, object> { ["text"] = "", ["editor"] = true }, new Dictionary<string, string> { ["key"] = past.Key });
            AppModel.Shared.Flash(reply.Str("message") ?? L("已在 VS Code 中恢复"));
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
    }

    void Split(bool down)
    {
        var panes = ChatPanes.Shared;
        panes.Focus(pane.Id);
        if (!panes.SplitFocused(null, down)) AppModel.Shared.Flash(L("已达到分屏数量上限"));
        MainModel.Shared.Selection = null;
    }

    /// 标签栏上的小按钮（同 Mac 版 TarsPaneButton）：26×24，鼠标移上去一层浅底
    public static Tap PaneButton(string symbol, string help, Action action, string color = "Text2", bool bold = false)
    {
        var icon = Ui.Sym(symbol, 13, color);
        if (bold) icon.FontWeight = FontWeight.SemiBold;
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        var tap = new Tap(icon, action, 6) { Width = 26, Height = 24 }.Keys("Transparent", "Fill10", "Fill12");
        tap.Tip(help);
        return tap;
    }

    /// 标签栏空白处：按住拖窗口、双击最大化（标题栏那一带被标签栏占了）
    static void WindowDrag(object? sender, PointerPressedEventArgs e)
    {
        if (MainWindow.Current is not Window w || !e.GetCurrentPoint(w).Properties.IsLeftButtonPressed) return;
        if (e.ClickCount == 2) w.WindowState = w.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        else w.BeginMoveDrag(e);
    }
}

/// 一排标签（最后一个是「+」时 trailing = true，它按自己的宽度）：每个标签按标题要的宽度来（最宽 maxTab）；
/// 总宽放不下时同浏览器，短的照旧、长的平分剩下的（不窄于 minTab，标题截短）。不给宽度（横着滚）时每个最宽 160（同 Mac 版 TabsLayout）
public sealed class TabsLayout(double minTab, double maxTab, bool trailing) : Panel
{
    double[] Widths(double available)
    {
        var ideals = Children.Select(c => { c.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); return c.DesiredSize.Width; }).ToArray();
        var count = Children.Count - (trailing ? 1 : 0);
        if (count <= 0) return ideals;
        if (double.IsInfinity(available)) return ideals.Select((w, i) => i < count ? Math.Min(w, 160) : w).ToArray();
        var result = ideals.ToArray();
        var remaining = available - (trailing ? ideals[count] : 0);
        // 从要得少的开始分：每个拿「自己要的」和「剩下的平分」里小的那个
        var order = Enumerable.Range(0, count).OrderBy(i => ideals[i]).ToList();
        for (var rank = 0; rank < order.Count; rank++)
        {
            var index = order[rank];
            var share = remaining / (count - rank);
            result[index] = Math.Min(Math.Min(ideals[index], maxTab), Math.Max(minTab, share));
            remaining -= result[index];
        }
        return result;
    }

    double[] widths = [];

    protected override Size MeasureOverride(Size available)
    {
        widths = Widths(available.Width);
        var height = 0.0;
        for (var i = 0; i < Children.Count; i++)
        {
            Children[i].Measure(new Size(widths[i], available.Height));
            height = Math.Max(height, Children[i].DesiredSize.Height);
        }
        var total = widths.Sum();
        return new Size(double.IsInfinity(available.Width) ? total : Math.Min(available.Width, total), height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double x = 0;
        for (var i = 0; i < Children.Count && i < widths.Length; i++)
        {
            var h = Children[i].DesiredSize.Height;
            Children[i].Arrange(new Rect(x, final.Height - h, widths[i], h));
            x += widths[i];
        }
        return final;
    }
}

/// 一个标签（同 Mac 版 PaneTab）：状态点、会话标题、×。正显示的那个是对话的底色、和下面连成一片（几块时当前块的顶上一道强调色）；
/// 别的标签平铺在标签栏上，鼠标指上去浅浅一层底、出现 ×。点一下切过去；拖到别的块（或这块的边上）挪过去；右键：关闭、关闭其他、关闭右侧、分出去
public sealed class PaneTab : Control
{
    const double Foot = 7;
    readonly string? key;
    readonly ChatPanes.Pane pane;
    readonly bool focused, several, divider, active, closable, showClose;
    readonly Flex row;
    readonly Tap? close;
    bool hover;
    Point? pressAt;

    public PaneTab(string? key, ChatPanes.Pane pane, bool focused, bool several, double cap, bool divider)
    {
        this.key = key;
        this.pane = pane;
        this.focused = focused;
        this.several = several;
        this.divider = divider;
        var model = AppModel.Shared;
        var session = key is null ? null : model.Session(key);
        active = key == pane.Key;
        var lit = active && (focused || !several);
        closable = key is not null || pane.Tabs.Count > 0 || several;
        showClose = closable && (active || cap >= 150);
        Height = PaneHeader.TabRow - 5;
        VerticalAlignment = VerticalAlignment.Bottom;
        var group = MainModel.GroupIdOf(key) is string gid ? GroupState.Shared.Group(gid) : null;
        var title = key is null ? L("选择会话") : Title(key);
        var text = Ui.Text(title, 13, lit ? FontWeight.SemiBold : FontWeight.Medium, lit ? "Text" : "Text2").Shrink();
        // 会话是状态点；群是双人图标（成员有在工作的就是强调色）
        Control dot = MainModel.GroupIdOf(key) is null ? (Control)Ui.Dot(7, session is null ? "Text4" : StatusColorKey(session))
            : Ui.Sym("person.2.fill", 10, group?.Members.Any(m => model.Session(m.Key)?.IsBusy == true) == true ? "Accent" : "Text2");
        if (showClose)
        {
            var x = Ui.Sym("xmark", 9, "Text2");
            x.FontWeight = FontWeight.Bold;
            x.HorizontalAlignment = HorizontalAlignment.Center;
            close = new Tap(x, () => ChatPanes.Shared.CloseTab(pane.Id, key), 9) { Width = 18, Height = 18 }.Keys("Fill08", "Fill15");
            close.Tip(L("关闭标签页"));
            close.Opacity = active ? 1 : 0;
        }
        row = Ui.H(7, dot, text, close);
        row.Margin = new Thickness(12 + Foot, 0, (showClose ? 6 : 12) + Foot, 0);
        VisualChildren.Add(row);
        LogicalChildren.Add(row);
        Cursor = new Cursor(StandardCursorType.Arrow);
        ToolTip.SetTip(this, group is not null ? Help(group) : Help(session, title));
        this.Menu(Menu);
    }

    /// 标签上写的：会话标题（已结束的用历史里的）；群写群名
    public static string Title(string key)
    {
        var model = AppModel.Shared;
        if (MainModel.GroupIdOf(key) is string id) return GroupState.Shared.Group(id)?.Name ?? L("群已解散");
        return model.Session(key)?.Title ?? (model.PastMeta.TryGetValue(key, out var p) ? p.Title : L("会话已结束"));
    }

    /// 群：群名 · 几个成员 · 成员都有谁
    static string Help(GroupInfo group) =>
        string.Join(" · ", new[] { group.Name, L("%@ 个成员", group.Members.Count), string.Join(L("、"), group.Members.Select(m => m.Name)) }.Where(x => x.Length > 0));

    public static string StatusColorKey(SessionInfo s) =>
        s.Error is not null ? "Removed" : s.Activity switch { "waiting" => "Orange", "busy" => "Accent", "idle" => "Added", _ => "Text3" };

    string Help(SessionInfo? s, string title)
    {
        if (key is null) return L("选择要在此打开的会话，或从左侧拖入");
        if (s is null) return string.Join(" · ", new[] { title, L("已结束") });
        var status = s.Error is not null ? L("出错已停止") : s.Activity switch { "waiting" => L("待确认"), "busy" => L("正在工作"), "idle" => L("空闲"), _ => "" };
        return string.Join(" · ", new[] { title, status, s.ReadOnly ? L("只读") : "", s.SourceName, s.Folder }.Where(x => x.Length > 0));
    }

    IEnumerable<Control> Menu()
    {
        var panes = ChatPanes.Shared;
        if (key is string k)
        {
            yield return Ui.Item(L("关闭标签页"), () => panes.CloseTab(pane.Id, k));
            if (pane.Tabs.Count > 1)
            {
                yield return Ui.Item(L("关闭其他标签页"), () => panes.CloseOtherTabs(pane.Id, k));
                if (pane.Tabs[^1] != k) yield return Ui.Item(L("关闭右侧标签页"), () => panes.CloseOtherTabs(pane.Id, k, rightOnly: true));
                yield return new Separator();
                yield return Ui.Item(L("移到右侧分屏"), () => panes.Drop(k, pane.Id, pane.Id, DropZone.Trailing));
                yield return Ui.Item(L("移到下方分屏"), () => panes.Drop(k, pane.Id, pane.Id, DropZone.Bottom));
            }
            if (MainModel.GroupIdOf(k) is string gid)
            {
                yield return new Separator();
                foreach (var item in GroupChatPage.MenuItems(gid, false)) yield return item;
            }
            else if (AppModel.Shared.Session(k) is not null)
            {
                yield return new Separator();
                foreach (var item in SessionMenu.Items(AppModel.Shared, MainModel.Shared, k)) yield return item;
            }
        }
        else if (closable) yield return Ui.Item(L("关闭标签页"), () => panes.CloseTab(pane.Id, null));
    }

    // 留白（row.Margin）由排版系统自己算进去：DesiredSize 已经含着它
    protected override Size MeasureOverride(Size available)
    {
        row.Measure(new Size(available.Width, Height));
        return new Size(double.IsInfinity(available.Width) ? row.DesiredSize.Width : Math.Min(row.DesiredSize.Width, available.Width), Height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        row.Arrange(new Rect(final));
        return final;
    }

    protected override void OnPointerEntered(PointerEventArgs e) { hover = true; if (close is not null && !active) close.Opacity = 1; InvalidateVisual(); }
    protected override void OnPointerExited(PointerEventArgs e) { hover = false; if (close is not null && !active) close.Opacity = 0; InvalidateVisual(); }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        pressAt = e.GetPosition(this);
        e.Handled = true;
    }

    protected override async void OnPointerMoved(PointerEventArgs e)
    {
        if (pressAt is not Point from || key is null || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        var p = e.GetPosition(this);
        if (Math.Abs(p.X - from.X) + Math.Abs(p.Y - from.Y) < 6) return;
        pressAt = null;
        var data = new DataObject();
        data.Set(PaneDrag.Format, PaneDrag.Encode(key, pane.Id));
        await DragDrop.DoDragDrop(e, data, DragDropEffects.Move | DragDropEffects.Link);   // Link：拖进群（见 Sidebar 的 StartDrag）
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (pressAt is null) return;
        pressAt = null;
        if (e.InitialPressMouseButton != MouseButton.Left) return;
        if (key is string k) ChatPanes.Shared.Activate(pane.Id, k); else ChatPanes.Shared.Focus(pane.Id);
        MainModel.Shared.Selection = key;
    }

    public override void Render(DrawingContext context)
    {
        var rect = new Rect(Bounds.Size);
        if (active)
        {
            var shape = Shape(rect, open: false);
            context.DrawGeometry(Palette.Get("ChatBackground"), null, shape);
            context.DrawGeometry(null, new Pen(Palette.Get("Separator"), 0.5), Shape(rect, open: true));
            // 当前块顶上一道强调色，跟着标签的圆角走：用几何求交（裁剪绘制在离屏截图里会吞掉后面画的字）
            if (focused && several)
                context.DrawGeometry(Palette.Get("Accent"), null, new CombinedGeometry(GeometryCombineMode.Intersect, shape, new RectangleGeometry(new Rect(0, 0, rect.Width, 2))));
        }
        else if (hover)
            context.DrawRectangle(Palette.Get("Fill06"), null, new Rect(Foot, 2, rect.Width - Foot * 2, rect.Height - 6), 7, 7);
        if (divider && !hover)
            context.FillRectangle(Palette.Get("Separator"), new Rect(-0.5, (rect.Height - 15) / 2 - 1, 1, 15));
    }

    /// 浏览器式的标签：上面两个圆角，下面两只「脚」往外弯、和标签栏底边接上（同 Mac 版 PaneTabShape）
    static Geometry Shape(Rect rect, bool open, double radius = 8)
    {
        var left = rect.X + Foot; var right = rect.Right - Foot; var top = rect.Y; var bottom = rect.Bottom;
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            ctx.BeginFigure(new Point(rect.X, bottom), !open);
            ctx.QuadraticBezierTo(new Point(left, bottom), new Point(left, bottom - Foot));
            ctx.LineTo(new Point(left, top + radius));
            ctx.QuadraticBezierTo(new Point(left, top), new Point(left + radius, top));
            ctx.LineTo(new Point(right - radius, top));
            ctx.QuadraticBezierTo(new Point(right, top), new Point(right, top + radius));
            ctx.LineTo(new Point(right, bottom - Foot));
            ctx.QuadraticBezierTo(new Point(right, bottom), new Point(rect.Right, bottom));
            ctx.EndFigure(!open);
        }
        return g;
    }
}

/// 还没选会话的一块：列出没打开的会话让你选（同 Mac 版 PanePicker）
public sealed class PanePicker : ScrollViewer
{
    // 继承的控件要指明用 ScrollViewer 的模板，不然会话多了只是被裁掉、划不动
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    public PanePicker(Guid paneId)
    {
        var model = AppModel.Shared;
        var open = ChatPanes.Shared.Keys.ToHashSet();
        var others = model.SortedSessions(MainModel.Shared.Sorting).Where(s => !open.Contains(s.Key)).ToList();
        var list = Ui.VFill(6,
            Ui.Text(L("选择要在此显示的会话"), 14, FontWeight.SemiBold),
            Ui.Text(others.Count == 0 ? L("其他会话均已打开。也可从左侧列表拖入会话。") : L("也可从左侧列表拖入会话，拖至哪一侧即从该侧拆分。"), 12, color: "Text2", lines: 2).Wrap().Margin(0, 0, 0, 8));
        foreach (var s in others)
        {
            var key = s.Key;
            var status = s.Error is not null ? L("出错已停止") : s.Activity switch { "waiting" => L("待确认"), "busy" => L("正在工作"), "idle" => L("空闲"), _ => "" };
            var detail = status + (s.ReadOnly ? " · " + L("只读") : "") + string.Concat(new[] { s.SourceName, s.Folder }.Where(x => x.Length > 0).Select(x => " · " + x));
            var initial = new Border
            {
                Width = 32, Height = 32, CornerRadius = new CornerRadius(8),
                Child = Ui.Text(s.Title.Length > 0 ? s.Title[..1] : "?", 14, FontWeight.SemiBold, "Accent").HAlign(HorizontalAlignment.Center),
            }.Res(Border.BackgroundProperty, "IconTile");
            var row = Ui.H(10, initial,
                Ui.VFill(2, Ui.Text(s.Title, 13, FontWeight.Medium), Ui.H(5, Ui.Dot(6, PaneTab.StatusColorKey(s)), Ui.Text(detail, 11.5, color: "Text2").Shrink())).Grow(),
                Ui.Sym("plus.circle", 14, "Accent"));
            var tap = new Tap(row, () => { ChatPanes.Shared.SetKey(paneId, key); MainModel.Shared.Selection = key; }, 10) { Padding = new Thickness(12, 9) }.Keys("BotBubble", "Fill10");
            list.Children.Add(tap);
        }
        // 群同会话一样能开在这里（进行中的在前，历史群也能开：在里面发话会恢复成员）
        var groups = GroupState.Shared.Supported ? GroupState.Shared.Items.Where(g => !open.Contains(MainModel.GroupPrefix + g.Id)).OrderBy(g => g.Live ? 0 : 1).ToList() : [];
        if (groups.Count > 0) list.Children.Add(Ui.Text(L("会话群"), 12.5, FontWeight.SemiBold, "Text2").Margin(0, others.Count > 0 ? 10 : 0, 0, 2));
        foreach (var g in groups)
        {
            var key = MainModel.GroupPrefix + g.Id;
            var row = Ui.H(10, GroupAvatar.Make(g.Members, 32, !g.Live),
                Ui.VFill(2, Ui.Text(g.Name, 13, FontWeight.Medium), Ui.Text(L("%@ 个成员", g.Members.Count) + (g.Live ? "" : " · " + L("历史群")), 11.5, color: "Text2")).Grow(),
                Ui.Sym("plus.circle", 14, "Accent"));
            list.Children.Add(new Tap(row, () => { ChatPanes.Shared.SetKey(paneId, key); MainModel.Shared.Selection = key; }, 10) { Padding = new Thickness(12, 9) }.Keys("BotBubble", "Fill10"));
        }
        var box = list.Pad(16);
        box.MaxWidth = 520;
        box.HorizontalAlignment = HorizontalAlignment.Center;
        Content = box;
        this.Res(BackgroundProperty, "ChatBackground");
    }
}
