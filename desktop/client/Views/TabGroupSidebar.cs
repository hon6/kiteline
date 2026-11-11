using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 一组的会话情况（同 Mac 版 TabGroupDigest）：待确认、出错、有新消息、在工作、已结束
public sealed record TabGroupDigest(int Total, List<string> Waiting, List<string> Failed, List<string> Unread, List<string> Busy, int Ended)
{
    public static TabGroupDigest Of(IReadOnlyList<string> keys)
    {
        var model = AppModel.Shared;
        var found = keys.Select(k => (Key: k, Session: model.Session(k))).ToList();
        return new TabGroupDigest(
            keys.Count,
            found.Where(x => x.Session?.IsWaiting == true).Select(x => x.Key).ToList(),
            found.Where(x => x.Session?.Error is not null).Select(x => x.Key).ToList(),
            found.Where(x => x.Session is { } s && model.IsUnread(s)).Select(x => x.Key).ToList(),
            found.Where(x => x.Session?.IsBusy == true).Select(x => x.Key).ToList(),
            found.Count(x => x.Session is null));
    }

    /// 第二行只写最要紧的一件事（同 Mac 版 summary / summaryColor）
    public (string Text, string Color) Summary()
    {
        if (Waiting.Count > 0) return (L("待确认：%@", PaneTab.Title(Waiting[0])), "Orange");
        if (Failed.Count > 0) return (L("出错：%@", PaneTab.Title(Failed[0])), "Removed");
        if (Unread.Count > 0 && Busy.Count == 0) return (L("有新消息：%@", PaneTab.Title(Unread[0])), "Text2");
        if (Busy.Count > 0) return (Unread.Count == 0 ? L("%@ 个在工作", Busy.Count) : L("%@ 个在工作 · %@ 个有新消息", Busy.Count, Unread.Count), "Text2");
        if (Ended == Total) return (L("都已结束"), "Text2");
        return (L("空闲"), "Text2");
    }

    /// 角标用的第二行小字（有待确认的写待确认数，否则写新消息数）
    public string Note() => Waiting.Count > 0 ? L("%@ 个待确认", Waiting.Count) : Unread.Count > 0 ? L("%@ 个有新消息", Unread.Count) : "";

    /// 有没有非正显示的组在等确认（标签栏的色块上标个橙点）
    public static bool WaitingElsewhere()
    {
        var state = TabGroupState.Shared;
        return state.Items.Where(g => g.Id != state.Active).Any(g => Of(g.Keys).Waiting.Count > 0);
    }
}

/// 左边栏「会话组」页签（同 Mac 版 TabGroupRows）：一组一行，展开后列组里的会话。
/// 行和会话控件按组 id / 会话 key 缓存，重排时不重建（正在工作的状态点动画不断）
public sealed class TabGroupSidebar
{
    readonly Dictionary<string, TabGroupRowView> rows = new();

    public List<Control> Build(MainModel main)
    {
        var state = TabGroupState.Shared;
        var list = new List<Control> { LooseRow() };
        if (state.Items.Count == 0)
        {
            list.Add(EmptyHint());
            rows.Clear();
            return list;
        }
        var used = new HashSet<string>();
        foreach (var group in state.Items)
        {
            if (!rows.TryGetValue(group.Id, out var row)) rows[group.Id] = row = new TabGroupRowView(group.Id, main);
            row.Update(group);
            list.Add(row);
            used.Add(group.Id);
        }
        foreach (var gone in rows.Keys.Where(k => !used.Contains(k)).ToList()) rows.Remove(gone);
        return list;
    }

    /// 最上面的「未分组的会话」一行：点了切回未分组（同 Mac 版 looseRow）
    static Control LooseRow()
    {
        var state = TabGroupState.Shared;
        var keys = state.LooseKeys();
        var selected = state.Active is null;
        var line = Ui.H(6,
            Ui.Sym("rectangle.on.rectangle", 12, "Text2"),
            Ui.Text(L("未分组的会话"), 13, FontWeight.Medium).Shrink(),
            Ui.Text(keys.Count.ToString(), 11, color: "Text3").Digits());
        Control text = line;
        if (keys.Count > 0)
        {
            var (summary, color) = TabGroupDigest.Of(keys).Summary();
            text = Ui.VFill(2, line, Ui.Text(summary, 11, color: color).Trim());
        }
        var row = new Tap(Ui.HTop(6, new Border { Width = 14 }, text.Grow()), () => state.Activate(null), 10) { Padding = new Thickness(7, 5) };
        if (selected) { row.Keys("AccentFill14", "AccentFill14"); row.BorderThickness = new Thickness(1); row.Res(Border.BorderBrushProperty, "AccentEdge32"); }
        else row.Keys("Transparent", "Fill05", "Fill08");
        row.Menu(() => state.Active is null && !ChatPanes.Shared.IsPristine
            ? [Ui.Item(L("用这些会话新建会话组"), () => state.Create(null, [], fromCurrent: true))]
            : []);
        return row.Margin(0, 0, 0, 4);
    }

    /// 还没有组：一句说明 + 新建（同 Mac 版 emptyHint；分屏里有标签时多一个「用当前标签页新建」）
    public static Control EmptyHint()
    {
        var stack = Ui.V(6,
            Ui.Text(L("把同一阶段的几个会话放成一组，切换时整组多列显示。"), 11.5, color: "Text2", lines: 0).Wrap(),
            Ui.H(12, Link(L("新建会话组…"), () => TabGroupPicker.Open(null, [])),
                ChatPanes.Shared.IsPristine ? null : Link(L("存下当前分屏"), () => TabGroupState.Shared.Create(null, [], fromCurrent: true))));
        return stack.Margin(4, 4, 4, 0);
    }

    static Control Link(string text, Action action) =>
        new Tap(Ui.Text(text, 11.5, FontWeight.Medium, "Accent"), action, 6) { Padding = new Thickness(4, 2) }.Keys("Transparent", "Fill05");

    /// 颜色菜单（组的右键、标签栏的菜单共用）
    public static IEnumerable<Control> ColorItems(string id)
    {
        var state = TabGroupState.Shared;
        foreach (var color in TabGroupColor.All)
        {
            var option = color;
            // 每项前面画这个颜色（同 Mac 版菜单里的色块），选中的描一圈
            var item = Ui.Item(option.Name, () => state.Update(id, state.Group(id)?.Name ?? "", option.Id));
            item.Icon = new TabGroupSwatch(option, state.ColorOf(id).Id == option.Id, () => { }) { Width = 18, Height = 18, IsHitTestVisible = false };
            yield return item;
        }
    }

    /// 删除要确认（会话不关，只是这一组没了）
    public static async void ConfirmDelete(string id)
    {
        var name = TabGroupState.Shared.Group(id)?.Name ?? "";
        if (await Dialogs.Confirm(L("删除「%@」？会话不会关，只是这一组没了。", name), L("删除"), destructive: true, title: L("删除会话组")))
            TabGroupState.Shared.Delete(id);
    }
}

/// 颜色块（同 Edge / Mac 版 TabGroupColor.swatch）：左半边浅色外观、右半边深色外观，选中的描一圈
public sealed class TabGroupSwatch : Control
{
    readonly TabGroupColor color;
    readonly bool selected;

    public TabGroupSwatch(TabGroupColor color, bool selected, Action pick)
    {
        this.color = color;
        this.selected = selected;
        Width = 24;
        Height = 24;
        Cursor = new Cursor(StandardCursorType.Hand);
        ToolTip.SetTip(this, color.Name);
        PointerPressed += (_, e) => { if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) pick(); };
    }

    public override void Render(DrawingContext context)
    {
        var center = new Point(Bounds.Width / 2, Bounds.Height / 2);
        var r = Math.Min(Bounds.Width, Bounds.Height) / 2 - 3;
        context.DrawEllipse(Palette.Brush(color.Light), null, center, r, r);
        var half = new StreamGeometry();
        using (var g = half.Open())
        {
            g.BeginFigure(new Point(center.X, center.Y - r), true);
            g.ArcTo(new Point(center.X, center.Y + r), new Size(r, r), 0, false, SweepDirection.Clockwise);
            g.EndFigure(true);
        }
        context.DrawGeometry(Palette.Brush(color.Dark), null, half);
        if (selected)
            context.DrawEllipse(null, new Pen(this.FindResource("Text") as IBrush ?? Brushes.Gray, 1.6), center, r + 3, r + 3);
    }
}

/// 一组那一行：展开箭头、颜色块、组名、会话数、角标（橙 = 待确认数，主题色 = 有新消息数）；第二行写最要紧的一件事。
/// 展开时组里的会话挂在下面（TabGroupMemberView）
public sealed class TabGroupRowView : StackPanel
{
    readonly string id;
    readonly MainModel main;
    readonly Tap head;
    readonly StackPanel members = new() { Spacing = 1 };
    readonly Dictionary<string, TabGroupMemberView> memberViews = new();

    public TabGroupRowView(string id, MainModel main)
    {
        this.id = id;
        this.main = main;
        head = new Tap(null, () => TabGroupState.Shared.Activate(id), 10) { Padding = new Thickness(7, 5) }.Keys("Transparent", "Fill05", "Fill08");
        // 左边栏的会话拖到这一组上：加进来（多一列）。只认会话（PaneDrag），和群无关
        DragDrop.SetAllowDrop(head, true);
        head.AddHandler(DragDrop.DragOverEvent, (_, e) => e.DragEffects = PaneDrag.Decode(e.Data.Get(PaneDrag.Format)) is null ? DragDropEffects.None : DragDropEffects.Link);
        head.AddHandler(DragDrop.DropEvent, (_, e) => { if (PaneDrag.Decode(e.Data.Get(PaneDrag.Format)) is { } p) TabGroupState.Shared.Add(id, [p.Key]); });
        Children.Add(head);
        Children.Add(members);
    }

    public void Update(TabGroupItem group)
    {
        var state = TabGroupState.Shared;
        var selected = state.Active == id;
        var color = state.ColorOf(id);
        var expanded = state.IsExpanded(id);
        var digest = TabGroupDigest.Of(group.Keys);
        if (selected)
        {
            head.Keys("AccentFill14", "AccentFill14");
            head.BorderThickness = new Thickness(1);
            head.Res(Border.BorderBrushProperty, "AccentEdge32");
        }
        else
        {
            head.Keys("Transparent", "Fill05", "Fill08");
            head.BorderThickness = new Thickness(0);
        }

        var chevron = Ui.Sym("chevron.right", 9, "Text3");
        chevron.RenderTransform = new RotateTransform(expanded ? 90 : 0);
        var expander = new Tap(chevron, () => { state.ToggleExpanded(id); }, 4) { Width = 14, Height = 18 }.Keys("Transparent", "Fill08");
        expander.Tip(expanded ? L("收起") : L("展开组里的会话"));

        var badges = Ui.H(4,
            digest.Waiting.Count > 0 ? BadgeFor(digest.Waiting.Count.ToString(), "Orange", L("%@ 个会话等你确认", digest.Waiting.Count)) : null,
            digest.Unread.Count > 0 ? BadgeFor(digest.Unread.Count.ToString(), "Accent", L("%@ 个会话有新消息", digest.Unread.Count)) : null);
        var top = Ui.H(6,
            new Border { Width = 12, Height = 12, CornerRadius = new CornerRadius(3.5), Background = color.Brush, VerticalAlignment = VerticalAlignment.Center },
            Ui.Text(group.Name, 13, FontWeight.Medium).Shrink(),
            Ui.Text(group.Keys.Count.ToString(), 11, color: "Text3").Digits(),
            new Border().Grow(),
            badges);
        Control text = top;
        if (group.Keys.Count > 0)
        {
            var (line, lineColor) = digest.Summary();
            text = Ui.VFill(2, top, Ui.Text(line, 11, color: lineColor).Trim());
        }
        head.Child = Ui.HTop(6, expander, text.Grow());
        head.Menu(() => [
            Ui.Item(L("打开"), () => TabGroupState.Shared.Activate(id)),
            Ui.Item(L("添加会话…"), () => TabGroupPicker.Open(id, [])),
            Ui.Item(L("每个会话一列"), () => TabGroupState.Shared.Arrange(id)),
            Ui.Item(L("把组里的会话拉成群"), () => TabGroupState.Shared.MakeGroup(id)),
            Ui.Item(L("编辑名称和颜色…"), () => TabGroupEdit.Open(id)),
            Ui.Submenu(L("颜色"), TabGroupSidebar.ColorItems(id)),
            Ui.Divider(),
            Ui.Item(L("删除会话组…"), () => TabGroupSidebar.ConfirmDelete(id)),
        ]);
        members.Children.Clear();
        if (expanded)
        {
            var used = new HashSet<string>();
            foreach (var key in group.Keys)
            {
                if (!memberViews.TryGetValue(key, out var view)) memberViews[key] = view = new TabGroupMemberView(id, key);
                view.Update();
                members.Children.Add(view);
                used.Add(key);
            }
            foreach (var gone in memberViews.Keys.Where(k => !used.Contains(k)).ToList()) memberViews.Remove(gone);
        }
    }

    public static Control BadgeFor(string text, string color, string tip) =>
        Ui.Box(Ui.Text(text, 10, FontWeight.SemiBold, "White"), new Thickness(5, 0, 5, 0), color, 6).Tip(tip);
}

/// 展开的组里的一个会话：状态点（工作中一闪）、标题、待确认 / 新角标；点了切到这组并显示它；右键从组里拿掉
public sealed class TabGroupMemberView : Tap
{
    readonly string gid;
    readonly string key;
    /// 正在工作时才有（Steps.cs 的 PulseDot 自己有计时器，不工作的会话不留着）
    PulseDot? pulse;
    readonly Border dot = new() { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), Margin = new Thickness(1) };
    readonly TextBlock title = Ui.Text("", 12).Shrink();
    readonly StackPanel badges = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
    readonly Panel dotHost = new() { Width = 8, Height = 8, Margin = new Thickness(1) };

    public TabGroupMemberView(string gid, string key) : base(null, null, 10)
    {
        this.gid = gid;
        this.key = key;
        Click = () => TabGroupState.Shared.Activate(gid, key);
        Padding = new Thickness(30, 3, 4, 3);
        dotHost.Children.Add(dot);
        Child = Ui.H(7, dotHost, title, new Border().Grow(), badges);
        this.Menu(() => [Ui.Item(L("从会话组移除"), () => TabGroupState.Shared.Remove(gid, key))]);
    }

    public void Update()
    {
        var model = AppModel.Shared;
        var session = model.Session(key);
        var selected = TabGroupState.Shared.Active == gid && ChatPanes.Shared.Focused == key;
        if (selected) { Keys("AccentFill14", "AccentFill14"); BorderThickness = new Thickness(1); this.Res(Border.BorderBrushProperty, "AccentEdge32"); }
        else { Keys("Transparent", "Fill05", "Fill08"); BorderThickness = new Thickness(0); }

        var busy = session is { IsBusy: true, Error: null };
        if (busy && pulse is null)
        {
            pulse = new PulseDot("Accent", 6) { Margin = new Thickness(1) };
            dotHost.Children.Add(pulse);
        }
        else if (!busy && pulse is not null)
        {
            dotHost.Children.Remove(pulse);
            pulse = null;
        }
        dot.IsVisible = !busy;
        if (!busy) dot.Res(Border.BackgroundProperty, session is null ? "Text3" : PaneTab.StatusColorKey(session));
        title.Text = PaneTab.Title(key);
        title.Foreground = (session is null ? this.FindResource("Text3") : this.FindResource("Text")) as IBrush;
        ToolTip.SetTip(this, PaneTab.Title(key));

        badges.Children.Clear();
        if (session?.IsWaiting == true) badges.Children.Add(TabGroupRowView.BadgeFor(L("待确认"), "Orange", L("等你确认")));
        if (session is not null && model.IsUnread(session)) badges.Children.Add(TabGroupRowView.BadgeFor(L("新"), "Accent", L("有新消息")));
    }
}

/// 标签栏最左边的组色块 + 组名（同 Mac 版 TabGroupChip）：点开是切组菜单；有别的组在等确认，色块上角标个橙点
public static class TabGroupChip
{
    public static Control Make()
    {
        var state = TabGroupState.Shared;
        var active = state.Group(state.Active);
        var color = active is null ? null : state.ColorOf(active.Id);
        var label = Ui.H(5,
            color is null
                ? Ui.Sym("square.stack", 10.5, "Text2")
                : new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(3), Background = color.Brush },
            Ui.Text(active?.Name ?? L("未分组"), 12, FontWeight.SemiBold, "Text2").Shrink(),
            Ui.Sym("chevron.down", 8, "Text3"));
        if (color is not null && label.Children.OfType<TextBlock>().FirstOrDefault() is { } name) name.Foreground = color.Brush;
        var chip = new Tap(label, null, 7) { Height = 24, Padding = new Thickness(8, 0), MaxWidth = 150 };
        chip.Background = active is null ? Palette.Brush(Palette.IsDark ? 0xFFFFFFu : 0x000000u, 0.06) : Palette.Brush(color!.Hex, 0.15);
        chip.Tip(L("会话组：切换、改名和颜色"));
        chip.Click = () => Show(chip);
        return chip.Margin(0, 0, 4, 5);
    }

    static void Show(Control anchor)
    {
        var state = TabGroupState.Shared;
        var menu = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedLeft };
        menu.Items.Add(Ui.Item(state.Active is null ? L("未分组（当前）") : L("未分组"), () => state.Activate(null), check: state.Active is null ? "" : null));
        foreach (var group in state.Items)
        {
            var note = TabGroupDigest.Of(group.Keys).Note();
            var title = note.Length == 0 ? group.Name : $"{group.Name}　{note}";
            var id = group.Id;
            menu.Items.Add(Ui.Item(title, () => state.Activate(id), check: state.Active == id ? "" : null));
        }
        menu.Items.Add(new Separator());
        if (state.Group(state.Active) is { } current)
        {
            var id = current.Id;
            menu.Items.Add(Ui.Item(L("编辑「%@」的名称和颜色…", current.Name), () => TabGroupEdit.Open(id)));
            menu.Items.Add(Ui.Item(L("添加会话…"), () => TabGroupPicker.Open(id, [])));
            menu.Items.Add(Ui.Item(L("每个会话一列"), () => state.Arrange(id)));
            menu.Items.Add(Ui.Item(L("把组里的会话拉成群"), () => state.MakeGroup(id)));
        }
        else if (!ChatPanes.Shared.IsPristine)
            menu.Items.Add(Ui.Item(L("用这些标签页新建会话组"), () => state.Create(null, [], fromCurrent: true)));
        menu.Items.Add(Ui.Item(L("新建会话组…"), () => TabGroupPicker.Open(null, [])));
        menu.ShowAt(anchor);
    }
}

/// 编辑弹窗：组名 + 一排九个颜色（同 Mac 版 TabGroupRenameSheet）
public static class TabGroupEdit
{
    public static void Open(string id)
    {
        var state = TabGroupState.Shared;
        if (state.Group(id) is not { } group) return;
        Window? window = null;
        var box = new TextBox { Text = group.Name, FontSize = Look.Pt(13), Padding = new Thickness(10, 7) };
        var picked = state.ColorOf(id).Id;
        var swatches = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        void Draw()
        {
            swatches.Children.Clear();
            foreach (var color in TabGroupColor.All)
            {
                var option = color;
                swatches.Children.Add(new TabGroupSwatch(option, option.Id == picked, () => { picked = option.Id; Draw(); }));
            }
        }
        void Save()
        {
            state.Update(id, box.Text ?? "", picked);
            window?.Close();
        }
        box.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { Save(); e.Handled = true; } };
        var ok = PromptCard.CardButton(L("保存"), true, Save);
        var cancel = PromptCard.CardButton(L("取消"), false, () => window?.Close());
        var stack = new StackPanel
        {
            Spacing = 12,
            Children =
            {
                Ui.Text(L("名称"), 11.5, FontWeight.SemiBold, "Text2"),
                box,
                Ui.Text(L("颜色"), 11.5, FontWeight.SemiBold, "Text2"),
                swatches,
                new ButtonPair(cancel, ok),
            },
        };
        window = Dialog.Make(stack.Pad(20), 380, L("编辑会话组"));
        window.Opened += (_, _) => { box.Focus(); box.SelectAll(); };
        Draw();
        Dialog.Show(window);
    }
}

/// 选会话的弹窗（同 Mac 版 TabGroupPicker）：新建（可改名，勾的先后 = 从左到右的列）或往一组里添加会话（组里的会话灰着、不能再勾）
public static class TabGroupPicker
{
    public static void Open(string? groupId, IEnumerable<string> preselected)
    {
        var state = TabGroupState.Shared;
        var model = AppModel.Shared;
        var members = state.Keys(groupId).ToHashSet();
        var order = preselected.Distinct().Where(k => model.Session(k) is not null).ToList();
        Window? window = null;
        var nameBox = new TextBox
        {
            Text = groupId is null ? state.SuggestedName(order) : "",
            FontSize = Look.Pt(13),
            Padding = new Thickness(10, 7),
            IsVisible = groupId is null,
        };
        var search = new TextBox { Watermark = L("搜索会话"), FontSize = Look.Pt(13), Padding = new Thickness(10, 6) };
        // 新建时一排九个颜色（同 Mac 版 TabGroupPicker、Edge 新建标签组），默认给还没人用的
        var picked = state.NextColor();
        var swatches = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, IsVisible = groupId is null };
        void DrawSwatches()
        {
            swatches.Children.Clear();
            foreach (var color in TabGroupColor.All)
            {
                var option = color;
                swatches.Children.Add(new TabGroupSwatch(option, option.Id == picked, () => { picked = option.Id; DrawSwatches(); }));
            }
        }
        DrawSwatches();
        var list = new StackPanel { Spacing = 2 };
        var scroll = new ScrollViewer { Content = list, MaxHeight = 330, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        var confirm = PromptCard.CardButton("", true, () => Confirm());
        var cancel = PromptCard.CardButton(L("取消"), false, () => window?.Close());

        void Confirm()
        {
            if (groupId is null)
            {
                state.Create(nameBox.Text, order, color: picked);
            }
            else
            {
                var fresh = order.Where(k => !members.Contains(k)).ToList();
                if (fresh.Count == 0) return;
                state.Add(groupId, fresh);
            }
            window?.Close();
        }

        void Render()
        {
            list.Children.Clear();
            var q = (search.Text ?? "").Trim();
            foreach (var s in model.SortedSessions("recent"))
            {
                if (q.Length > 0 && !(s.Title.Contains(q, StringComparison.OrdinalIgnoreCase) || (s.Folder ?? "").Contains(q, StringComparison.OrdinalIgnoreCase))) continue;
                var key = s.Key;
                var member = members.Contains(key);
                var index = order.IndexOf(key);
                var box = new Border
                {
                    Width = 16,
                    Height = 16,
                    CornerRadius = new CornerRadius(4),
                    BorderThickness = new Thickness(1),
                    Child = index >= 0 ? Ui.Text((index + 1).ToString(), 10, FontWeight.SemiBold, "White").HAlign(HorizontalAlignment.Center) : null,
                };
                box.Res(Border.BorderBrushProperty, index >= 0 ? "Accent" : "Text3");
                box.Res(Border.BackgroundProperty, index >= 0 ? "Accent" : "Transparent");
                var line = Ui.H(8, box, Ui.VFill(1,
                    Ui.Text(s.Title, 12.5, FontWeight.Medium).Shrink(),
                    Ui.Text(member ? L("已在这个会话组里") : $"{s.Folder} · {s.SourceName}", 10.5, color: "Text3").Trim()).Grow());
                var row = new Tap(line, null, 8) { Padding = new Thickness(8, 6) }.Keys("Transparent", "Fill06");
                if (member)
                    row.Opacity = 0.45;
                else
                    row.Click = () =>
                    {
                        if (!order.Remove(key)) order.Add(key);
                        Render();
                    };
                list.Children.Add(row);
            }
            var fresh = order.Count(k => !members.Contains(k));
            var label = groupId is null
                ? (order.Count == 0 ? L("新建") : L("新建（%@ 个会话）", order.Count))
                : (fresh == 0 ? L("请选择要添加的会话") : L("添加 %@ 个会话", fresh));
            confirm.Child = Ui.Text(label, 13, FontWeight.SemiBold, "White").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center);
            confirm.IsEnabled = groupId is null || fresh > 0;
            confirm.Opacity = confirm.IsEnabled ? 1 : 0.45;
        }

        var stack = new StackPanel { Spacing = 10 };
        if (groupId is null)
        {
            stack.Children.Add(Ui.Text(L("名称"), 11.5, FontWeight.SemiBold, "Text2"));
            stack.Children.Add(nameBox);
            stack.Children.Add(Ui.Text(L("颜色"), 11.5, FontWeight.SemiBold, "Text2"));
            stack.Children.Add(swatches);
        }
        stack.Children.Add(Ui.Text(L("选择会话，勾的先后就是从左到右的列。"), 11.5, color: "Text2", lines: 0).Wrap());
        stack.Children.Add(search);
        stack.Children.Add(scroll);
        // 主按钮整行宽、固定在弹窗最底部；列表在上面滚（取消在它上面）
        cancel.HorizontalAlignment = HorizontalAlignment.Stretch;
        confirm.HorizontalAlignment = HorizontalAlignment.Stretch;
        stack.Children.Add(Ui.VFill(8, cancel, confirm));
        search.TextChanged += (_, _) => Render();
        window = Dialog.Make(stack.Pad(20), 440, groupId is null ? L("新建会话组") : L("添加会话"));
        window.Opened += (_, _) => (groupId is null ? nameBox : search).Focus();
        Render();
        Dialog.Show(window);
    }
}

/// 会话右键的「添加到会话组 ▸」（同 Mac 版 TarsTabGroupMenu）：已经在的那组打勾，再点就拿掉
public static class TabGroupMenus
{
    public static IEnumerable<Control> For(string key)
    {
        var state = TabGroupState.Shared;
        foreach (var group in state.Items)
        {
            var id = group.Id;
            var member = group.Keys.Contains(key);
            yield return Ui.Item(group.Name, () =>
            {
                if (member) state.Remove(id, key);
                else state.Add(id, [key]);
            }, check: member ? "" : null);
        }
        if (state.Items.Count > 0) yield return Ui.Divider();
        yield return Ui.Item(L("新建会话组…"), () => TabGroupPicker.Open(null, [key]));
    }
}
