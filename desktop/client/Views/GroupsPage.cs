using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

// 会话群的界面（同 iOS / Mac 版 Views/GroupViews.swift）：群头像、列表里的一行、全部群（进行中 + 历史群）、群聊页、
// 拉群 / 加成员的弹窗、改群名、对话里的群消息卡片

/// 群头像（同微信）：成员头像拼在一个圆角方块里，两个并排、三个上一下二、四个以上田字格
public static class GroupAvatar
{
    public static Control Make(IReadOnlyList<GroupMember> members, double size, bool dim = false)
    {
        var shown = members.Take(4).ToList();
        var gap = Math.Max(1.5, size * 0.04);
        var cell = (size - gap * 3) / 2;
        Control Face(GroupMember m) => SessionFace.Make(m.Key, cell, 0.23) ?? new Border
        {
            Width = cell, Height = cell, CornerRadius = new CornerRadius(cell * 0.23),
            Child = new TextBlock
            {
                Text = Format.Initials(m.Name), FontSize = cell * 0.42, FontWeight = FontWeight.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            }.Res(TextBlock.ForegroundProperty, "Accent"),
        }.Res(Border.BackgroundProperty, "IconTile");
        StackPanel Row(IEnumerable<GroupMember> list)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = gap, HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var m in list) row.Children.Add(Face(m));
            return row;
        }
        var rows = new StackPanel { Spacing = gap, VerticalAlignment = VerticalAlignment.Center };
        if (shown.Count >= 3)
        {
            rows.Children.Add(Row(shown.Take(shown.Count == 3 ? 1 : 2)));
            rows.Children.Add(Row(shown.Skip(shown.Count - 2)));
        }
        else rows.Children.Add(Row(shown));
        return new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.23), ClipToBounds = true, Child = rows, Opacity = dim ? 0.55 : 1,
        }.Res(Border.BackgroundProperty, "Fill06");
    }
}

/// 列表里的一行：群头像，群名（人数）+ 时间，下面是最后一条群消息；历史群标「历史」；暂停转发的标出来
public static class GroupRow
{
    /// 群那一行的标记、免打扰、解散（右键菜单、群聊页的「…」菜单里；同 iOS 版 GroupMenuItems）
    public static IEnumerable<Control> MenuItems(GroupInfo group)
    {
        var id = group.Id;
        yield return Ui.Item(group.Marked ? L("取消标记") : L("标记"), () => GroupState.Shared.Mark(id, !group.Marked));
        yield return Ui.Item(group.Muted ? L("取消免打扰") : L("免打扰（群消息不推送）"), () => GroupState.Shared.Mute(id, !group.Muted));
        yield return Ui.Divider();
        yield return Ui.Item(L("解散群"), () => GroupChatPage.Disband(id));
    }

    public static Control Content(GroupInfo group, bool compact)
    {
        var live = group.Live;
        string preview;
        if (group.Paused) preview = L("[已暂停转发]") + " " + L("轻点查看");
        else if (group.Last is { System: false } last)
        {
            var who = last.Mine ? L("我") : group.Member(last.From)?.Name ?? last.FromTitle;
            preview = $"{who}：{System.Text.RegularExpressions.Regex.Replace(last.Text, @"\s+", " ")}";
        }
        else preview = string.Join(L("、"), group.Members.Select(m => m.Name));
        var title = Ui.H(4,
            Ui.Sym("person.2.fill", compact ? 10 : 11, "Text2"),
            Ui.Text(group.Name, compact ? 13 : 14, FontWeight.SemiBold).Trim().Shrink(),
            Ui.Text($"({group.Members.Count})", compact ? 11.5 : 12.5, color: "Text2"),
            group.Marked ? Ui.Sym("star.fill", compact ? 10.5 : 11.5, "Accent") : null,
            new Spacer(4),
            Ui.Text(Format.ListTime(group.UpdatedAt), 10.5, color: "Text3"));
        var line = Ui.H(6,
            Ui.Text(preview, compact ? 11.5 : 12.5, color: group.Paused ? "Orange" : "Text2").Trim().Shrink(),
            new Spacer(0),
            group.Muted ? Ui.Sym("bell.slash", compact ? 10.5 : 11.5, "Text3") : null,
            live ? null : Ui.Box(Ui.Text(L("历史"), 10, color: "Text2"), new Thickness(5, 1), "Fill06", 4));
        return Ui.HTop(10, GroupAvatar.Make(group.Members, compact ? 32 : 44, !live).Margin(0, 1, 0, 0), Ui.VFill(3, title, line).Grow());
    }
}

/// 别的会话拖到一行上松开（同 iOS 版 groupDrop）：会话行 = 拉这两个建群；群行 = 加进这个群。拖着经过时画虚线框
public static class GroupDrop
{
    public static void Attach(Control target, Func<string?> self, Action<string> perform)
    {
        DragDrop.SetAllowDrop(target, true);
        (Thickness Width, IBrush? Brush)? saved = null;
        void Show(bool on)
        {
            if (target is not Border border) return;
            if (on && saved is null)
            {
                saved = (border.BorderThickness, border.BorderBrush);
                border.BorderThickness = new Thickness(1.5);
                border.BorderBrush = border.FindResource("Accent") as IBrush ?? Brushes.Orange;
            }
            else if (!on && saved is { } was)
            {
                saved = null;
                border.BorderThickness = was.Width;
                border.BorderBrush = was.Brush;
            }
        }
        (string Key, Guid? Source)? Payload(DragEventArgs e) => PaneDrag.Decode(e.Data.Get(PaneDrag.Format));
        target.AddHandler(DragDrop.DragOverEvent, (_, e) =>
        {
            var ok = GroupState.Shared.Supported && Payload(e) is { } p && p.Key != self();
            e.DragEffects = ok ? DragDropEffects.Link : DragDropEffects.None;
            Show(ok);
        });
        target.AddHandler(DragDrop.DragLeaveEvent, (_, _) => Show(false));
        target.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            Show(false);
            if (GroupState.Shared.Supported && Payload(e) is { } p && p.Key != self()) perform(p.Key);
        });
    }
}

/// 左边栏「会话群」一节：进行中的群（点开群聊页；把会话拖到群上 = 加进这个群），成员都关了的收成「历史群」一行
/// 左边栏会话列表里的「会话群」一组（同「标记」、按项目分的组，排在会话前面；同 Mac 版 TarsGroupSidebarSection）：进行中的群一行一个，
/// 点了同会话一样开成右边分屏的一个标签，拖到右边哪一块的哪一边就放到哪；把会话拖到群上 = 加进这个群。成员都关了的收成「历史群」一行。
/// 筛着设备、项目、状态或在搜索时（keys = 筛出来的会话）：只留有成员在里面的群（搜索也认群名）；筛「标记」时只留标记的群
public static class GroupSidebar
{
    public static List<GroupInfo> Shown(HashSet<string>? keys, bool markedOnly, string query, out int past)
    {
        var state = GroupState.Shared;
        past = 0;
        if (!state.Supported) return [];
        var q = query.Trim();
        var live = state.Items.Where(g => g.Live).ToList();
        if (keys is null && !markedOnly && q.Length == 0) { past = state.Items.Count - live.Count; return live; }
        return live.Where(g => markedOnly ? g.Marked
            : (q.Length > 0 && g.Name.Contains(q, StringComparison.OrdinalIgnoreCase)) || (keys is not null && g.Members.Any(m => keys.Contains(m.Key)))).ToList();
    }

    public static Control? Section(MainModel main, List<GroupInfo> live, int past)
    {
        if (live.Count == 0 && past == 0) return null;
        var stack = new StackPanel { Spacing = 2 };
        // 同别的组头（「标记」、按项目分的组）：图标、组名，右边个数
        stack.Children.Add(Ui.H(6, Ui.Sym("person.2.fill", 10.5, "Text2"), Ui.Text(L("会话群"), 11, FontWeight.SemiBold, "Text2").Shrink(), new Spacer(4),
            Ui.Text(live.Count.ToString(), 11, FontWeight.SemiBold, "Text3").Digits()).Margin(0, 14, 0, 4));
        foreach (var group in live) stack.Children.Add(new GroupRowView(group, main));
        if (past > 0)
            stack.Children.Add(new Tap(Ui.H(6, Ui.Sym("clock.arrow.circlepath", 11, "Text2"), Ui.Text(L("历史群 %@ 个", past), 11.5, color: "Text2")).Pad(7, 4),
                () => main.Selection = MainModel.GroupsId, 6).Keys("Transparent", "Fill05").Tip(L("成员会话都已关闭的群。在群里发消息，会在原来的项目里恢复它们接着协作。")));
        return stack;
    }
}

/// 左边栏的群那一行（同会话行）：选中 = 淡强调色底 + 细边；拖得进右边的分屏；右键「在右侧 / 下方分屏打开」和标记、免打扰、解散
public sealed class GroupRowView : Tap
{
    readonly string key;
    Point? dragFrom;

    public GroupRowView(GroupInfo group, MainModel main) : base(GroupRow.Content(group, true), null, 10)
    {
        key = MainModel.GroupPrefix + group.Id;
        Padding = new Thickness(7, 5);
        Click = () => main.Selection = key;
        if (main.Selection == key) { Keys("AccentFill14", "AccentFill14"); BorderThickness = new Thickness(1); this.Res(BorderBrushProperty, "AccentEdge32"); }
        else Keys("Transparent", "Fill05", "Fill08");
        var gid = group.Id;
        GroupDrop.Attach(this, () => null, dragged =>
        {
            if (GroupState.Shared.Group(gid)?.Member(dragged) is null) _ = GroupState.Shared.Add(gid, [dragged]);
        });
        var info = group;
        this.Menu(() => [
            Ui.Item(L("打开群聊"), () => main.Selection = key),
            .. ChatPanes.Shared.Keys.Contains(key) ? Array.Empty<Control>()
                : [Ui.Item(L("在右侧分屏打开"), () => SessionMenu.OpenSplit(key, false)), Ui.Item(L("在下方分屏打开"), () => SessionMenu.OpenSplit(key, true))],
            Ui.Divider(),
            .. GroupRow.MenuItems(info)]);
        PointerPressed += (_, e) => dragFrom = e.GetPosition(this);
        PointerMoved += StartDrag;
    }

    /// 同会话行：拖到右边哪一块的哪一边就放到哪
    async void StartDrag(object? sender, PointerEventArgs e)
    {
        if (dragFrom is not Point from || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        var p = e.GetPosition(this);
        if (Math.Abs(p.X - from.X) + Math.Abs(p.Y - from.Y) < 6) return;
        dragFrom = null;
        var data = new DataObject();
        data.Set(PaneDrag.Format, PaneDrag.Encode(key, null));
        await DragDrop.DoDragDrop(e, data, DragDropEffects.Move | DragDropEffects.Link);
    }
}

/// 「会话群」页：进行中的群在上，成员都关了的历史群在下
public sealed class GroupsPage : Panel
{
    readonly StackPanel list = new() { Spacing = 6, Margin = new Thickness(20, 8, 20, 24) };
    readonly ContentControl empty = new();

    public GroupsPage()
    {
        var bar = new PageBar(L("会话群"), null, null, [PageBar.Button("plus", L("拉群协作"), () => GroupPicker.Open([], null))]);
        var scroll = new ScrollViewer { Content = list, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Children.Add(PageBar.Page(bar, new Panel { Children = { scroll, empty } }));
        void Changed(object? s, PropertyChangedEventArgs e) => Dispatcher.UIThread.Post(Rebuild);
        AttachedToVisualTree += (_, _) => { GroupState.Shared.PropertyChanged += Changed; AppModel.Shared.PropertyChanged += Changed; Rebuild(); _ = GroupState.Shared.Load(); };
        DetachedFromVisualTree += (_, _) => { GroupState.Shared.PropertyChanged -= Changed; AppModel.Shared.PropertyChanged -= Changed; };
        Rebuild();
    }

    void Rebuild()
    {
        var items = GroupState.Shared.Items;
        list.Children.Clear();
        void Section(string title, IEnumerable<GroupInfo> groups, string? footer = null)
        {
            var rows = groups.ToList();
            if (rows.Count == 0) return;
            list.Children.Add(Ui.Text(title, 12, FontWeight.SemiBold, "Text2").Margin(4, 10, 0, 2));
            foreach (var group in rows)
            {
                var gid = group.Id;
                var row = new Tap(GroupRow.Content(group, false), () => MainModel.Shared.Selection = MainModel.GroupPrefix + gid, 12) { Padding = new Thickness(12, 9) }
                    .Keys("Fill045", "Fill08");
                var info = group;
                row.Menu(() => [Ui.Item(L("打开群聊"), () => MainModel.Shared.Selection = MainModel.GroupPrefix + gid), Ui.Divider(), .. GroupRow.MenuItems(info)]);
                list.Children.Add(row);
            }
            if (footer is not null) list.Children.Add(Ui.Text(footer, 11.5, color: "Text2", lines: 0).Wrap().Margin(4, 4, 0, 0));
        }
        Section(L("进行中"), items.Where(g => g.Live));
        Section(L("历史群"), items.Where(g => !g.Live), L("成员会话都已关闭的群。在群里发消息，会在原来的项目里恢复它们接着协作。"));
        empty.Content = items.Count == 0
            ? EmptyHint.Make("person.2", L("还没有会话群"), L("把一个会话拖到另一个会话上，或在会话的菜单里选「拉群协作」，让不同设备、不同项目里的会话互相沟通。")).VAlign(VerticalAlignment.Center)
            : null;
    }
}

/// 群聊页：顶上成员（头像、标题、在哪台电脑哪个项目、在跑没有，点开会话），中间往来的消息，下面在群里发话
/// 群聊页：同会话一样开成右边分屏里的一个标签（见 ChatPanesView）。群名、成员按钮、「更多」菜单在标签栏上（PaneHeader），
/// 这里只有往来消息、输入框和右边滑出的成员面板；把会话拖到这一块中间进群也由分屏接（PaneView）
public sealed class GroupChatPage : Panel
{
    readonly string id;
    /// 右边滑出的成员面板（同 QQ 群）：成员一行一个，顶上「添加成员」；点面板外面收起
    readonly StackPanel members = new() { Spacing = 2 };
    readonly Border drawer, dim;
    bool drawerOpen;
    bool loaded;
    /// 开着的群聊页（标签栏上的成员按钮找它开关成员面板）
    static readonly Dictionary<string, GroupChatPage> open = new();
    /// 成员面板开了 / 收了：标签栏上的成员按钮跟着变实心
    public static event Action? DrawerChanged;
    /// 自测用：打开群聊页时直接展开成员面板（步骤 groupmembers）
    public static bool StartWithMembers;
    readonly StackPanel messages = new() { Spacing = 12, Margin = new Thickness(18, 12, 18, 16) };
    readonly ScrollViewer scroll;
    readonly ContentControl notice = new();
    /// 输入栏：就是会话的输入栏（发图、粘贴截图、常用语都一样），发到群里；下面那排是「发给全部成员 ⌄」
    readonly Composer composer;
    int shownCount = -1;

    public GroupChatPage(string id)
    {
        this.id = id;
        this.Res(BackgroundProperty, "ChatBackground");
        scroll = new ScrollViewer { Content = messages, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        composer = new Composer(MainModel.GroupPrefix + id, new ComposeGroup(id));
        var deck = new Border { Child = composer, Padding = new Thickness(0, 8, 0, 0) };
        deck.Res(Border.BackgroundProperty, "ChatBackground");
        var dock = new DockPanel();
        DockPanel.SetDock(deck, Dock.Bottom);
        DockPanel.SetDock(notice, Dock.Bottom);
        dock.Children.Add(deck);
        dock.Children.Add(notice);
        dock.Children.Add(scroll);
        // 成员面板：盖在对话上，从右边滑进来；后面一层淡黑，点它收起
        dim = new Border { Background = new SolidColorBrush(Color.FromArgb(46, 0, 0, 0)), IsVisible = false, Opacity = 0 };
        dim.Transitions = [new Avalonia.Animation.DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(200) }];
        dim.PointerPressed += (_, e) => { ToggleDrawer(false); e.Handled = true; };
        var close = new Tap(Ui.Sym("xmark", 11, "Text2").HAlign(HorizontalAlignment.Center), () => ToggleDrawer(false), 6) { Width = 26, Height = 26 }.Keys("Transparent", "Fill08");
        var drawerHead = Ui.H(6, Ui.Text(L("群成员"), 14, FontWeight.SemiBold), memberCountInDrawer, new Spacer(6), close.Tip(L("收起"))).Pad(16, 14, 12, 8);
        var drawerDock = new DockPanel();
        DockPanel.SetDock(drawerHead, Dock.Top);
        drawerDock.Children.Add(drawerHead);
        drawerDock.Children.Add(new ScrollViewer { Content = members.Margin(6, 0, 6, 16), HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled });
        drawer = new Border
        {
            // 浮在群聊页右边的一张玻璃卡片（同 Mac 版：只占群聊这一块，四周留边、圆角）
            Child = drawerDock, Width = 300, HorizontalAlignment = HorizontalAlignment.Right, BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(16), Margin = new Thickness(0, 8, 8, 8), ClipToBounds = true,
            RenderTransform = Avalonia.Media.Transformation.TransformOperations.Parse("translateX(340px)"), IsVisible = false,
            // 不加 BoxShadow：带阴影的 Border 在这里连里面的内容都画不出来（只剩底色，离屏截图实测）；左边一道细线 + 后面的淡黑层分开
        };
        drawer.Transitions = [new Avalonia.Animation.TransformOperationsTransition { Property = RenderTransformProperty, Duration = TimeSpan.FromMilliseconds(220) }];
        // 这里没有窗口内模糊：用几乎不透明的玻璃色（同侧栏底栏），不然后面的消息透上来很乱
        drawer.Res(Border.BackgroundProperty, "GlassSolid").Res(Border.BorderBrushProperty, "GlassEdge");
        Children.Add(dock);
        Children.Add(dim);
        Children.Add(drawer);
        void Changed(object? s, PropertyChangedEventArgs e) => Dispatcher.UIThread.Post(Rebuild);
        // 分屏重排时会摘下来再挂上（同对话页）：消息只在第一次挂上时取
        AttachedToVisualTree += (_, _) =>
        {
            open[id] = this;
            GroupState.Shared.PropertyChanged += Changed;
            AppModel.Shared.PropertyChanged += Changed;
            Rebuild();
            if (loaded) return;
            loaded = true;
            _ = GroupState.Shared.LoadMessages(id);
            if (StartWithMembers) ToggleDrawer(true);
        };
        DetachedFromVisualTree += (_, _) =>
        {
            if (open.TryGetValue(id, out var page) && page == this) open.Remove(id);
            GroupState.Shared.PropertyChanged -= Changed;
            AppModel.Shared.PropertyChanged -= Changed;
        };
    }

    /// 标签栏上的成员按钮：开 / 收这个群的成员面板
    public static void ToggleMembers(string id)
    {
        if (open.TryGetValue(id, out var page)) page.ToggleDrawer(!page.drawerOpen);
    }

    public static bool MembersOpen(string id) => open.TryGetValue(id, out var page) && page.drawerOpen;

    /// 标签栏「更多」、右键标签里群的操作（同 iOS / Mac 版 GroupPaneMenu）：folded = 标签栏上的按钮折进来了，成员排最前面
    public static IEnumerable<Control> MenuItems(string id, bool folded)
    {
        if (GroupState.Shared.Group(id) is not GroupInfo group) yield break;
        if (folded) yield return Ui.Item(L("群成员"), () => ToggleMembers(id));
        yield return Ui.Item(L("添加成员"), () => GroupPicker.Open([], id));
        yield return Ui.Item(L("修改群名"), () => GroupRename.Open(id));
        yield return group.Paused ? Ui.Item(L("继续转发"), () => _ = GroupState.Shared.Pause(id, false)) : Ui.Item(L("暂停转发"), () => _ = GroupState.Shared.Pause(id, true));
        foreach (var item in GroupRow.MenuItems(group)) yield return item;
    }

    /// 会话拖到显示着群的那块中间（同原来拖进群聊页）：还不在群里、能回复的会话松开就进群，返回那个群；
    /// 已经在群里的、拖的是群、拖到四边的照常开标签、分屏
    public static GroupInfo? Joinable(string? key, string? paneKey)
    {
        if (key is null || MainModel.GroupIdOf(key) is not null || MainModel.GroupIdOf(paneKey) is not string id) return null;
        if (GroupState.Shared.Group(id) is not GroupInfo group || group.Member(key) is not null) return null;
        return AppModel.Shared.Session(key) is { CanReply: true } ? group : null;
    }

    /// 能进就进群，返回 true；不能进返回 false（交回去照常放）
    public static bool JoinDropped(string key, string? paneKey)
    {
        if (Joinable(key, paneKey) is not GroupInfo group) return false;
        Join(group.Id, key);
        return true;
    }

    static async void Join(string gid, string key)
    {
        if (await GroupState.Shared.Add(gid, [key])) AppModel.Shared.Flash(L("已加入群：%@", AppModel.Shared.Session(key)?.Title ?? key));
    }

    readonly TextBlock memberCountInDrawer = Ui.Text("", 13, color: "Text2");

    void ToggleDrawer(bool show)
    {
        drawerOpen = show;
        if (show) { drawer.IsVisible = true; dim.IsVisible = true; }
        drawer.RenderTransform = Avalonia.Media.Transformation.TransformOperations.Parse(show ? "translateX(0px)" : "translateX(340px)");
        dim.Opacity = show ? 1 : 0;
        if (!show) DispatcherTimer.RunOnce(() => { if (!drawerOpen) { drawer.IsVisible = false; dim.IsVisible = false; } }, TimeSpan.FromMilliseconds(240));
        DrawerChanged?.Invoke();
    }

    public static async void Disband(string id)
    {
        if (await Dialogs.Confirm(L("解散后群里的消息记录一并删除，成员会话不受影响。"), L("解散群"), destructive: true))
            await GroupState.Shared.Delete(id);   // 开着它的标签由分屏关掉（见 ChatPanesView）
    }

    void Rebuild()
    {
        if (GroupState.Shared.Group(id) is not GroupInfo group)
        {
            messages.Children.Clear();
            messages.Children.Add(Empty.State("person.2", L("群已解散")).Margin(0, 60, 0, 0));
            return;
        }
        memberCountInDrawer.Text = group.Members.Count.ToString();
        members.Children.Clear();
        var plus = new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(9), Child = Ui.Sym("plus", 15, "Accent").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center) }
            .Res(Border.BackgroundProperty, "IconTile");
        members.Children.Add(new Tap(Ui.H(10, plus, Ui.Text(L("添加成员"), 13)).Pad(10, 6), () => GroupPicker.Open([], id), 8).Keys("Transparent", "Fill05"));
        foreach (var m in group.Members) members.Children.Add(MemberRow(group, m));
        members.Children.Add(Ui.Text(L("把左边的会话拖到群聊里即可加入。"), 11.5, color: "Text2", lines: 0).Wrap().Margin(12, 10, 12, 0));
        if (group.Paused)
            notice.Content = Ui.H(10, Ui.Sym("pause", 13, "Orange"), Ui.Text(L("agent 之间往来较多，已暂停转发。"), 12).Shrink(), new Spacer(4),
                Form.Button(L("继续转发"), () => _ = GroupState.Shared.Pause(id, false))).Pad(16, 8).Res(Border.BackgroundProperty, "OrangeFill13");
        else if (!group.Live)
            notice.Content = Ui.H(8, Ui.Sym("clock.arrow.circlepath", 12, "Text2"),
                Ui.Text(L("成员会话都已关闭。发消息后会在原来的项目里恢复它们，接着协作。"), 12, color: "Text2", lines: 2).Wrap().Shrink()).Pad(16, 8).Res(Border.BackgroundProperty, "Fill03");
        else notice.Content = null;
        composer.Update(null);
        var list = GroupState.Shared.Messages(id);
        var atBottom = scroll.Offset.Y >= scroll.Extent.Height - scroll.Viewport.Height - 40;
        messages.Children.Clear();
        if (list.Count == 0 && group.Topic is { Length: > 0 } topic) messages.Children.Add(Ui.Text(topic, 12, color: "Text2", lines: 0).Wrap());
        foreach (var message in list) messages.Children.Add(MessageView(group, message));
        if (list.Count != shownCount || atBottom) Dispatcher.UIThread.Post(() => scroll.ScrollToEnd(), DispatcherPriority.Background);
        shownCount = list.Count;
    }

    /// 成员面板里的一行：头像、标题、在跑没有 · 哪台电脑哪个项目；点开那个会话，右键移出
    static Control MemberRow(GroupInfo group, GroupMember m)
    {
        var session = AppModel.Shared.Session(m.Key);
        var (status, dot) = session is null ? (L("已结束"), "Text3") : session.IsBusy ? (L("工作中"), "Accent") : session.IsWaiting ? (L("待确认"), "Orange") : (L("空闲"), "Green");
        var line = Ui.H(4, Ui.Dot(6, dot), Ui.Text(m.Place.Length > 0 ? $"{status} · {m.Place}" : status, 11, color: "Text2").Trim().Shrink());
        var row = new Tap(Ui.H(10, new SessionAvatar(m.Name, "idle", 34, SessionFace.Make(m.Key, 34, 0.23)), Ui.VFill(2, Ui.Text(m.Name, 13, FontWeight.Medium).Trim(), line).Shrink()).Pad(10, 6),
            () => MainModel.Shared.Selection = m.Key, 8).Keys("Transparent", "Fill05");
        var gid = group.Id;
        row.Menu(() => [Ui.Item(L("打开会话"), () => MainModel.Shared.Selection = m.Key), Ui.Divider(), Ui.Item(L("移出群"), async () =>
        {
            if (await Dialogs.Confirm(L("将「%@」移出群？之后它收不到群消息。", m.Name), L("移出"), destructive: true)) await GroupState.Shared.Remove(gid, m.Key);
        })]);
        return row;
    }

    static Control MessageView(GroupInfo group, GroupMessage message)
    {
        if (message.System)
            return Ui.Box(Ui.Text(message.EventText, 11.5, color: "Text2", lines: 0).Wrap(), new Thickness(10, 3), "Fill05", 10).HAlign(HorizontalAlignment.Center);
        var delivery = Delivery(group, message);
        var failed = message.States.ContainsValue("failed");
        if (message.Mine)
        {
            // 带的图在气泡上面、文件一个一张卡片（同会话里我发的）
            var key = MainModel.GroupPrefix + group.Id;
            var images = message.Images.Count > 0
                ? new MessageImages(key, message.Images.Select(m => new ChatImage(m.Ref, null, m.Name)).ToList(), path: GroupMedia.Path).HAlign(HorizontalAlignment.Right) : null;
            var files = message.Files.Count > 0
                ? new Bubble(true, true, FileOpen.GroupChips(group.Id, message.Files), string.Join("\n", message.Files.Select(f => f.Name))).MaxW(560) : null;
            var bubble = message.Text.Length > 0 ? new Bubble(true, true, new RichText(message.Text, ChatType.Size, color: Bubble.TextColor(true)), message.Text).MaxW(560) : null;
            return Ui.Stack(Orientation.Vertical, 4, Align.End, [Ui.Text(Format.ListTime(message.Ts), 10.5, color: "Text3"), images, files, bubble,
                delivery.Length > 0 ? Ui.Text(delivery, 10.5, color: failed ? "Red" : "Text2", lines: 0).Wrap() : null]).HAlign(HorizontalAlignment.Right);
        }
        var member = group.Member(message.From);
        var name = member?.Name ?? message.FromTitle;
        var header = Ui.H(5, Ui.Text(name, 12, FontWeight.SemiBold).Trim(), member?.Place is { Length: > 0 } place ? Ui.Text(place, 10.5, color: "Text3").Trim() : null,
            message.To is { Count: > 0 } to ? Ui.Text(L("→ %@", string.Join(L("、"), to.Select(k => group.Member(k)?.Name ?? k))), 10.5, color: "Text2").Trim() : null,
            Ui.Text(Format.ListTime(message.Ts), 10.5, color: "Text3"));
        var body = new Bubble(false, true, new MarkdownView(message.Text, false), message.Text, [(L("打开这个会话"), () => MainModel.Shared.Selection = message.From)]);
        var avatar = new SessionAvatar(name, "idle", 34, SessionFace.Make(message.From, 34, 0.23)).OnTap(() => MainModel.Shared.Selection = message.From);
        return Ui.HTop(8, avatar, Ui.VFill(4, header, body.MaxW(620).HAlign(HorizontalAlignment.Left),
            delivery.Length > 0 ? Ui.Text(delivery, 10.5, color: failed ? "Red" : "Text2", lines: 0).Wrap() : null).Shrink());
    }

    /// 「已送达 A、B」「A 已关闭，恢复时补上」「未送达 A：原因」……（同 iOS 版）
    static string Delivery(GroupInfo group, GroupMessage message)
    {
        string Name(string key) => group.Member(key)?.Name ?? L("会话");
        string Names(IEnumerable<string> keys) => string.Join(L("、"), keys.Select(Name));
        var by = message.States.GroupBy(p => p.Value).ToDictionary(g => g.Key, g => g.Select(p => p.Key).OrderBy(k => k).ToList());
        var parts = new List<string>();
        if (by.TryGetValue("sent", out var sent)) parts.Add(L("已送达 %@", Names(sent)));
        if (by.TryGetValue("filled", out var filled)) parts.Add(L("已填入 %@ 的输入框，未提交", Names(filled)));
        if (by.TryGetValue("pending", out var pending))
        {
            var resuming = pending.Where(k => message.Notes.ContainsKey(k)).ToList();
            // 在等你确认的会话：确认完才投（回车会替你点允许）
            var held = pending.Where(k => !message.Notes.ContainsKey(k) && AppModel.Shared.Session(k)?.IsWaiting == true).ToList();
            var waiting = pending.Where(k => !message.Notes.ContainsKey(k) && AppModel.Shared.Session(k)?.IsWaiting != true).ToList();
            if (waiting.Count > 0) parts.Add(L("正在送达 %@", Names(waiting)));
            if (held.Count > 0) parts.Add(L("%@ 确认后送达", Names(held)));
            if (resuming.Count > 0) parts.Add(L("正在恢复 %@", Names(resuming)));
        }
        if (by.TryGetValue("paused", out var paused)) parts.Add(L("暂停转发，未送达 %@", Names(paused)));
        if (by.TryGetValue("ended", out var ended))
            parts.Add(L("%@ 已关闭，恢复时补上", Names(ended)) + (ended.Select(k => message.Notes.GetValueOrDefault(k)).FirstOrDefault(n => n is not null) is string note ? L("（%@）", L(note)) : ""));
        if (by.TryGetValue("failed", out var failed))
            parts.Add(L("未送达 %@", Names(failed)) + (failed.Select(k => message.Notes.GetValueOrDefault(k)).FirstOrDefault(n => n is not null) is string why ? L("：%@", L(why)) : ""));
        return string.Join(" · ", parts);
    }
}

/// 拉群 / 加成员的弹窗：在跑的会话按电脑分开列（勾选），只拖 / 点了一个会话时可以直接加进已有的群；建群时可以写要协作的事
public static class GroupPicker
{
    public static void Open(IEnumerable<string> preselected, string? groupId)
    {
        var model = AppModel.Shared;
        var existing = groupId is null ? [] : GroupState.Shared.Group(groupId)?.Members.Select(m => m.Key).ToHashSet() ?? [];
        var seed = preselected.ToList();
        var picked = seed.ToHashSet();
        Window? window = null;
        var stack = new StackPanel { Spacing = 12 };
        stack.Children.Add(Ui.Text(groupId is null ? L("拉群协作") : L("添加成员"), 15, FontWeight.SemiBold));
        var confirm = PromptCard.CardButton("", true, () => { });
        void UpdateButton()
        {
            var fresh = picked.Count(k => !existing.Contains(k));
            var ready = groupId is null ? picked.Count >= 2 : fresh > 0;
            var title = groupId is not null ? (fresh == 0 ? L("请选择要添加的会话") : L("添加 %@ 个会话", fresh))
                : picked.Count >= 2 ? L("建群（%@ 个会话）", picked.Count) : L("至少选择两个会话");
            confirm.Child = Ui.Text(title, 13, FontWeight.SemiBold, "White").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center);
            confirm.IsEnabled = ready;
            confirm.Opacity = ready ? 1 : 0.45;
        }
        if (groupId is null)
        {
            stack.Children.Add(Ui.Text(L("把几个会话拉进一个群，它们可以在不同设备、不同项目里互相发消息协作；你在群里能看到全部往来，也能直接发话。"), 12, color: "Text2", lines: 0).Wrap());
            if (seed.Count == 1 && GroupState.Shared.Items.Where(g => g.Live && g.Member(seed[0]) is null).ToList() is { Count: > 0 } joinable)
            {
                stack.Children.Add(Ui.Text(L("加入已有的群"), 11.5, FontWeight.SemiBold, "Text2"));
                foreach (var group in joinable)
                {
                    var gid = group.Id;
                    stack.Children.Add(new Tap(GroupRow.Content(group, true).Pad(10, 6), async () =>
                    {
                        if (await GroupState.Shared.Add(gid, seed)) { window?.Close(); MainModel.Shared.Selection = MainModel.GroupPrefix + gid; }
                    }, 10).Keys("Fill045", "Fill08"));
                }
                stack.Children.Add(Ui.Text(L("或者新建一个群："), 11.5, FontWeight.SemiBold, "Text2").Margin(0, 4, 0, 0));
            }
        }
        var sessions = model.Sessions;
        // 设备、项目两排胶囊（同会话列表）：不止一台设备 / 不止一个项目时才有，只列筛剩的会话；筛掉的已勾选的照样算在里面
        string sourceFilter = "", projectFilter = "";
        var filterHost = new StackPanel { Spacing = 8 };
        var listHost = new StackPanel { Spacing = 12 };
        stack.Children.Add(filterHost);
        stack.Children.Add(listHost);
        void Rebuild()
        {
            var source = sourceFilter.Length > 0 && sessions.Any(s => s.SourceId == sourceFilter) ? sourceFilter : null;
            var project = projectFilter.Length > 0 && sessions.Any(s => s.Folder == projectFilter) ? projectFilter : null;
            var allMachines = sessions.Select(s => (s.SourceId, s.SourceName)).Distinct().ToList();
            var projects = sessions.Where(s => s.Folder.Length > 0 && (source is null || s.SourceId == source)).Select(s => s.Folder).Distinct().ToList();
            filterHost.Children.Clear();
            if (allMachines.Count > 1)
                filterHost.Children.Add(ScopeBar.Build("desktopcomputer", L("全部设备"),
                    allMachines.Select(m => (m.SourceId, m.SourceName.Length == 0 ? L("未知设备") : Lang.Machine(m.SourceName),
                                             sessions.Count(s => s.SourceId == m.SourceId && (project is null || s.Folder == project)))),
                    source ?? "", id => { sourceFilter = id; Rebuild(); }));
            if (projects.Count > 1 || project is not null)
                filterHost.Children.Add(ScopeBar.Build("folder", L("全部项目"),
                    projects.Select(name => (name, name, sessions.Count(s => s.Folder == name && (source is null || s.SourceId == source)))),
                    project ?? "", name => { projectFilter = name; Rebuild(); }));
            filterHost.IsVisible = filterHost.Children.Count > 0;
            listHost.Children.Clear();
            var shown = sessions.Where(s => (source is null || s.SourceId == source) && (project is null || s.Folder == project)).ToList();
            if (shown.Count == 0) listHost.Children.Add(Ui.Text(sessions.Count == 0 ? L("没有运行中的会话") : L("没有符合筛选条件的会话"), 12, color: "Text2"));
            var machines = shown.Select(s => (s.SourceId, s.SourceName)).Distinct().ToList();
            foreach (var (sourceId, sourceName) in machines)
            {
                if (allMachines.Count > 1)
                    listHost.Children.Add(Ui.H(5, Ui.Sym("desktopcomputer", 11, "Text2"), Ui.Text(sourceName.Length == 0 ? L("未知设备") : Lang.Machine(sourceName), 11.5, FontWeight.SemiBold, "Text2")));
                var card = new StackPanel { Spacing = 0 };
                foreach (var s in shown.Where(x => x.SourceId == sourceId))
                {
                    var key = s.Key;
                    var member = existing.Contains(key);
                    var enabled = !member && s.CanReply;
                    var check = Ui.Sym(member || picked.Contains(key) ? "checkmark.circle.fill" : "circle", 16, member || picked.Contains(key) ? "Action" : "Text3");
                    var note = member ? L("已在群里") : !s.CanReply ? L("只读，收不到群消息") : string.Join(" · ", new[] { s.Folder, s.IsBusy ? L("工作中") : null }.Where(x => !string.IsNullOrEmpty(x)));
                    var row = new Tap(Ui.H(10, check, new SessionAvatar(s.Title, "idle", 30, SessionFace.Make(key, 30, 0.23)),
                        Ui.VFill(1, Ui.H(4, new AgentGlyph(s.Agent, 11, "Text2"), Ui.Text(s.Title, 13).Trim().Shrink()), Ui.Text(note, 11, color: "Text2").Trim()).Shrink()).Pad(10, 7), null, 8)
                        .Keys("Transparent", enabled ? "Fill05" : "Transparent");
                    row.Opacity = enabled || member ? 1 : 0.5;
                    row.Click = () =>
                    {
                        if (!enabled) return;
                        if (!picked.Remove(key)) picked.Add(key);
                        var on = picked.Contains(key);
                        check.Symbol = on ? "checkmark.circle.fill" : "circle";
                        check.Res(TextBlock.ForegroundProperty, on ? "Action" : "Text3");
                        UpdateButton();
                    };
                    card.Children.Add(row);
                }
                listHost.Children.Add(new Border { Child = card, CornerRadius = new CornerRadius(12), Padding = new Thickness(2) }.Res(Border.BackgroundProperty, "Fill045"));
            }
        }
        Rebuild();
        TextBox? topic = null;
        if (groupId is null)
        {
            topic = new TextBox
            {
                AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64, MaxHeight = 180, FontSize = Look.Pt(13), Padding = new Thickness(10, 8),
                Watermark = L("例如：右边用完虚拟机后告诉左边，左边再开始搬迁"), Classes = { "plain" },
            };
            topic.Res(TextBox.BackgroundProperty, "Fill06");
            var field = topic;
            stack.Children.Add(Ui.VFill(6, Ui.Text(L("要它们协作什么（可选）"), 11.5, FontWeight.SemiBold, "Text2"), field,
                new DictateButton(said => field.Text = DictateButton.Append(said, field.Text ?? "")).HAlign(HorizontalAlignment.Left),
                Ui.Text(L("填写后作为第一条群消息发给所有成员；不填就等你在群里发话。群名会由 agent 按协作的事自动起。"), 11, color: "Text2", lines: 0).Wrap()));
        }
        var busy = false;
        confirm.Click = async () =>
        {
            if (busy || !confirm.IsEnabled) return;
            busy = true;
            if (groupId is not null)
            {
                if (await GroupState.Shared.Add(groupId, picked.Where(k => !existing.Contains(k)).ToList())) { window?.Close(); MainModel.Shared.Selection = MainModel.GroupPrefix + groupId; }
            }
            else if (await GroupState.Shared.Create(picked, (topic?.Text ?? "").Trim()) is string id)
            {
                window?.Close();
                MainModel.Shared.Selection = MainModel.GroupPrefix + id;
            }
            busy = false;
        };
        UpdateButton();
        var cancel = PromptCard.CardButton(L("取消"), false, () => window?.Close());
        var scroll = new ScrollViewer { Content = stack, MaxHeight = 560, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        window = Dialog.Make(new StackPanel { Spacing = 16, Children = { scroll, new ButtonPair(cancel, confirm) } }.Pad(20), 520, groupId is null ? L("拉群协作") : L("添加成员"));
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) { window.Close(); e.Handled = true; } };
        Dialog.Show(window);
    }
}

/// 改群名
public static class GroupRename
{
    public static void Open(string id)
    {
        Window? window = null;
        var box = new TextBox { Text = GroupState.Shared.Group(id)?.Name ?? "", FontSize = Look.Pt(13), Padding = new Thickness(10, 7) };
        async void Save()
        {
            var name = (box.Text ?? "").Trim();
            if (name.Length == 0) return;
            if (await GroupState.Shared.Rename(id, name)) window?.Close();
        }
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Save(); e.Handled = true; } };
        var ok = PromptCard.CardButton(L("保存"), true, Save);
        var cancel = PromptCard.CardButton(L("取消"), false, () => window?.Close());
        var stack = new StackPanel
        {
            Spacing = 12,
            Children = { box, Ui.Text(L("改过之后，agent 不会再自动起名。"), 11.5, color: "Text2"), new ButtonPair(cancel, ok) },   // 「修改群名」在标题栏里
        };
        window = Dialog.Make(stack.Pad(20), 400, L("修改群名"));
        window.Opened += (_, _) => { box.Focus(); box.SelectAll(); };
        Dialog.Show(window);
    }
}

/// 对话里的群消息（同 iOS 版 GroupSayMessage / GroupInboundMessage）
public static class GroupCards
{
    static GroupInfo? Find(string key, string? id, string? name)
    {
        if (id is { Length: > 0 } && GroupState.Shared.Group(id) is GroupInfo byId) return byId;
        var mine = GroupState.Shared.Containing(key).ToList();
        return mine.FirstOrDefault(g => g.Name == name) ?? mine.FirstOrDefault();
    }

    static Control Head(string label, string name, GroupInfo? group) =>
        new Tap(Ui.H(5, Ui.Sym("person.2.fill", 10.5, "Text2"), Ui.Text(label, 11.5, color: "Text2"), Ui.Text(name, 11.5, FontWeight.SemiBold).Trim(),
            group is null ? null : Ui.Sym("chevron.right", 9, "Text3")).Pad(2, 1), () => { if (group is not null) MainModel.Shared.Selection = MainModel.GroupPrefix + group.Id; }, 4)
            .Keys("Transparent", "Fill05").HAlign(HorizontalAlignment.Left);

    /// agent 发到群里的（group say）：一张「发到群」卡片
    public static Control Say(string key, ChatItem item, bool first)
    {
        var group = Find(key, item.Group, null);
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(Head(L("发到群"), group?.Name ?? L("会话群"), group));
        if (item.To is { Count: > 0 } to && group is not null)
            stack.Children.Add(Ui.Text(L("只发给 %@", string.Join(L("、"), to.Select(k => group.Member(k)?.Name ?? k))), 11, color: "Text2"));
        stack.Children.Add(new MarkdownView(item.Text ?? "", false));
        return new Bubble(false, first, stack, item.Text);
    }

    /// Kiteline 送进这个会话的群消息（对话记录里是一条用户消息）：居中一张「来自群」卡片；群说明、回复方法是写给 agent 看的，只标一句
    public static Control Inbound(string key, ChatItem item, GroupText.Inbound inbound)
    {
        var group = Find(key, null, inbound.Name);
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(Ui.H(6, Head(L("来自群"), inbound.Name, group), new Spacer(6), item.Ts is double ts ? Ui.Text(Format.ListTime(ts), 10.5, color: "Text3") : null));
        if (inbound.Brief) stack.Children.Add(Ui.Text(L("已附上群说明：成员、所在设备与项目、发群消息的方法"), 11, color: "Text2", lines: 0).Wrap());
        foreach (var part in inbound.Parts)
            stack.Children.Add(Ui.VFill(3, Ui.Text(part.Who, 11.5, FontWeight.SemiBold, "Text2").Trim(), new MarkdownView(part.Text, false)));
        var card = new Border { Child = stack, Padding = new Thickness(14, 11), CornerRadius = new CornerRadius(14), MaxWidth = 560, BorderThickness = new Thickness(1) }
            .Res(Border.BackgroundProperty, "Fill045").Res(Border.BorderBrushProperty, "Fill08");
        card.Menu(() => [Ui.Item(L("复制"), () => SessionMenu.Copy(item.Text ?? ""))]);
        return card.HAlign(HorizontalAlignment.Center).Margin(12, 4, 12, 4);
    }
}
