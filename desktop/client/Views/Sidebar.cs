using System.ComponentModel;
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

/// 左边栏（同 Mac 版 SidebarView）：顶上搜索框；入口格子（今日动态、待办、历史会话、今日用量、项目）；
/// 「会话 N　显示方式」和状态筛选；按分组排好的会话；底下一条玻璃底栏（来源、手机、二维码、设置）
public sealed class SidebarView : Panel
{
    readonly AppModel model = AppModel.Shared;
    readonly MainModel main = MainModel.Shared;
    readonly SidebarTilesModel tiles = new();
    readonly StackPanel content = new() { Spacing = 0 };
    readonly ScrollViewer scroll;
    readonly TextBox search;
    readonly Dictionary<string, SessionRowView> rows = new();
    readonly PeerOverlay peers = new();
    readonly TabGroupSidebar tabGroups = new();
    /// 「设备 · 项目」那一行展开着（选完自动收起，不存）
    bool scopeOpen;
    bool pending;

    public static readonly double Width0 = 300;

    public SidebarView()
    {
        // 底色由 MainWindow 里垫在下面的 SidebarGlass 画（玻璃 / 模糊壁纸 / 不透明）
        search = SearchField();
        scroll = new ScrollViewer
        {
            Content = content.Pad(16, 4, 16, 64),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        var top = new Border { Height = 52, Background = Brushes.Transparent };   // 标题栏那一带（新任务按钮在 MainWindow 里放），空白处拖窗口
        top.PointerPressed += WindowChrome.DragWindow;
        var column = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        var searchBox = search.Margin(10, 0, 10, 8);
        DockPanel.SetDock(searchBox, Dock.Top);
        column.Children.Add(top);
        column.Children.Add(searchBox);
        column.Children.Add(scroll);
        Children.Add(column);
        // 会话之间的消息：头像两侧滚动的虚线、纸鸢传信（盖在列表上，在底栏下面）
        peers.Viewport = scroll;
        peers.Rows = () => rows.Where(kv => kv.Value.IsVisible && kv.Value.Parent is not null && kv.Value.Avatar is not null).Select(kv => (kv.Key, kv.Value.Avatar!));
        var chip = new PeerChipHost(peers) { Margin = new Thickness(0, 0, 0, 72) };   // 在底栏上面
        scroll.ScrollChanged += (_, _) => { peers.InvalidateVisual(); chip.Update(); };
        Children.Add(peers);
        Children.Add(chip);
        var footer = new SidebarFooter(model) { VerticalAlignment = VerticalAlignment.Bottom };
        Children.Add(footer);

        model.PropertyChanged += Changed;
        main.PropertyChanged += Changed;
        tiles.Changed += Schedule;
        Look.Changed += Schedule;
        FavoriteState.Shared.PropertyChanged += (_, _) => Dispatcher.UIThread.Post(Schedule);   // 「收藏」格子的条数
        GroupState.Shared.PropertyChanged += (_, _) => Dispatcher.UIThread.Post(Schedule);      // 「群」页签
        TabGroupState.Shared.PropertyChanged += (_, _) => Dispatcher.UIThread.Post(Schedule);   // 「会话组」页签
        Rebuild();
        tiles.Start();
    }

    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.Toast) or nameof(AppModel.Banner)) return;
        Schedule();
    }

    /// 一连串变化合成一次重排
    void Schedule()
    {
        if (pending) return;
        pending = true;
        Dispatcher.UIThread.Post(() => { pending = false; Rebuild(); }, DispatcherPriority.Background);
    }

    TextBox SearchField()
    {
        var box = new TextBox
        {
            Watermark = L("搜索会话"),
            Height = 28, MinHeight = 28,
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(2, 4, 10, 4),
            FontSize = Look.Pt(13),
            VerticalContentAlignment = VerticalAlignment.Center,
            BorderThickness = new Thickness(0),
            Classes = { "search" },
        };
        box.Res(TextBox.BackgroundProperty, "Fill06");
        box.InnerLeftContent = Ui.Sym("magnifyingglass", 12, "Text2").Margin(10, 0, 2, 0);
        box.TextChanged += (_, _) => main.Query = box.Text ?? "";
        return box;
    }

    // MARK: 排

    static readonly (string Id, string Title)[] GroupOptions = [("none", "不分组"), ("source", "按来源"), ("project", "按项目"), ("agent", "按 Agent")];
    static readonly (string Id, string Title)[] SortOptions = [("started", "开始时间"), ("recent", "最近活动"), ("status", "状态优先"), ("name", "名称")];
    // 「标记」（主题色星星）放在「工作中」左边：多任务时找得到暂停、等着的会话（10-27）
    static readonly (string Id, string Title, string? Dot)[] StatusOptions =
        [("all", "全部", null), ("marked", "标记", "Accent"), ("busy", "工作中", "Accent"), ("waiting", "待确认", "Orange"), ("error", "出错", "Red")];

    string Status => StatusOptions.Any(o => o.Id == main.StatusFilter) ? main.StatusFilter : "all";
    SourceInfo? ActiveSource => main.SourceFilter.Length == 0 ? null : model.Sources.FirstOrDefault(s => s.Id == main.SourceFilter);
    /// 筛着的那个项目（运行中的会话里已经没有它就当没筛）
    string? ActiveProject => main.ProjectFilter.Length == 0 || model.Sessions.All(s => s.Folder != main.ProjectFilter) ? null : main.ProjectFilter;
    /// 选了某个项目时按项目、按来源分都只剩一组：不分组（项目选「全部」时才有「按项目」这些分组）
    string EffectiveGrouping => ActiveProject is null ? main.Grouping : "none";
    /// 分组、排序都是默认的
    bool IsDefaultView => EffectiveGrouping == "none" && main.Sorting == "started";
    bool IsFiltering => Status != "all" || ActiveSource is not null || ActiveProject is not null;

    void ClearFilters()
    {
        main.StatusFilter = "all";
        main.SourceFilter = "";
        main.ProjectFilter = "";
    }

    static bool Matches(SessionInfo s, string filter) => filter switch
    {
        "marked" => AppModel.Shared.IsMarked(s.Key),
        "busy" => s.IsBusy,
        "waiting" => s.IsWaiting,
        "error" => s.Error is not null,
        _ => true,
    };

    /// 当前页签（电脑不支持的回到会话）
    string CurrentTab => main.ListTab switch
    {
        "groups" when GroupState.Shared.Supported => "groups",
        "tabgroups" when TabGroupState.Shared.Supported => "tabgroups",
        _ => "sessions",
    };

    void Rebuild()
    {
        var searching = main.Query.Trim().Length > 0;
        var tab = searching ? "sessions" : CurrentTab;
        var filtered = main.Filtered(model.Sessions).ToList();
        var sorted = model.SortedSessions(main.Sorting, filtered);
        // 先按设备、项目，再按状态筛（搜索词上面已经筛过）
        var sourceId = ActiveSource?.Id;
        var project = ActiveProject;
        var baseList = sorted.Where(s => (sourceId is null || s.SourceId == sourceId) && (project is null || s.Folder == project)).ToList();
        var shown = baseList.Where(s => Matches(s, Status)).ToList();
        content.Children.Clear();
        if (TipVisible) content.Children.Add(TipCard().Margin(0, 12, 0, 0));
        if (!searching) content.Children.Add(Tiles().Margin(0, TipVisible ? 10 : 15, 0, 0));
        content.Children.Add(TabRow(tab, searching, shown.Count).Margin(0, 12, 0, 0));
        if (tab == "groups")
        {
            GroupsTab();
            return;
        }
        if (tab == "tabgroups")
        {
            foreach (var row in tabGroups.Build(main)) content.Children.Add(row);
            return;
        }
        // 会话群只在搜索时跟着会话列（对得上的群一起列）；平时群在「群」页签里
        Control? groupSection = null;
        if (searching)
        {
            var keys = shown.Select(s => s.Key).ToHashSet();
            var groupsShown = GroupSidebar.Shown(keys, Status == "marked", main.Query, out var pastGroups);
            groupSection = GroupSidebar.Section(main, groupsShown, pastGroups);
        }
        if (model.Sessions.Count == 0)
        {
            content.Children.Add(Ui.H(6, Ui.Sym("moon.stars", 11.5, "Text2"),
                Ui.Text(L("没有运行中的会话。在 VS Code 中打开 Claude Code，或在终端运行 claude。"), 11.5, color: "Text2", lines: 3).Wrap().Shrink()).Margin(4, 14, 0, 0));
            if (groupSection is not null) content.Children.Add(groupSection);
            return;
        }
        if (filtered.Count == 0 && searching && groupSection is null)
        {
            content.Children.Add(Empty.State("magnifyingglass", L("没有匹配的会话")).Margin(0, 60, 0, 0));
            return;
        }
        content.Children.Add(Controls(baseList, sorted));
        if (groupSection is not null) content.Children.Add(groupSection);
        var used = new HashSet<string>();
        foreach (var group in Groups(shown))
        {
            // 不分组时会话没有组头：上面有会话群一组时写个「会话」，免得看着像群里的
            if ((group.Name ?? (groupSection is not null ? L("会话") : null)) is string name) content.Children.Add(GroupHeader(group, name));
            foreach (var s in group.Items)
            {
                if (!rows.TryGetValue(s.Key, out var row)) rows[s.Key] = row = new SessionRowView(model, main);
                row.Update(s);
                used.Add(s.Key);
                content.Children.Add(row);
            }
        }
        foreach (var gone in rows.Keys.Where(k => !used.Contains(k)).ToList()) rows.Remove(gone);
        if (shown.Count == 0) content.Children.Add(EmptyFilter());
        Dispatcher.UIThread.Post(peers.Refresh, DispatcherPriority.Render);
    }

    /// 「会话 N | 群 N | 会话组 N」三个页签（同 Mac 版 SidebarTabs）：选中的字加粗、下面一条主题色短线；右边是这个页签自己的按钮。
    /// 搜索时不分页签，只写「会话 N」
    Control TabRow(string tab, bool searching, int count)
    {
        if (searching) return Ui.H(6, Ui.Text(L("会话"), 13, FontWeight.SemiBold), Ui.Text(count.ToString(), 12, color: "Text3").Digits());
        var tabs = new List<Control> { TabButton("sessions", L("会话"), count, tab) };
        if (GroupState.Shared.Supported) tabs.Add(TabButton("groups", L("群"), GroupState.Shared.Items.Count(g => g.Live), tab));
        if (TabGroupState.Shared.Supported)
            tabs.Add(TabButton("tabgroups", L("会话组"), TabGroupState.Shared.Items.Count, tab, TabGroupDigest.WaitingElsewhere()));
        Control? action = tab switch
        {
            "tabgroups" => SmallButton("plus", L("新建"), () => TabGroupPicker.Open(null, [])),
            "groups" when model.Sessions.Count > 1 => NewGroupButton(),
            _ => null,
        };
        return Ui.H(6, Ui.H(14, tabs.ToArray()), new Border().Grow(), action);
    }

    Control TabButton(string id, string title, int count, string current, bool alert = false)
    {
        var on = id == current;
        var label = Ui.H(4,
            Ui.Text(title, 13, on ? FontWeight.SemiBold : FontWeight.Medium, on ? "Text" : "Text2"),
            Ui.Text(count.ToString(), 12, color: "Text3").Digits(),
            alert ? Ui.Dot(6, "Orange").VAlign(VerticalAlignment.Top).Margin(-2, -2, 0, 0) : null);
        var underline = new Border { Height = 2, CornerRadius = new CornerRadius(1), Margin = new Thickness(0, 4, 0, 0) };
        underline.Res(Border.BackgroundProperty, on ? "Accent" : "Transparent");
        return new Tap(Ui.VFill(0, label, underline), () => main.ListTab = id, 6) { Padding = new Thickness(2, 3, 2, 0) }.Keys("Transparent", "Fill05");
    }

    /// 页签那一行右边的小按钮（同「建群」样子，小一点）
    static Control SmallButton(string symbol, string title, Action action)
    {
        var button = new Tap(Ui.H(4, Ui.Sym(symbol, 11, "Text2"), Ui.Text(title, 12, FontWeight.Medium, "Text2")), action, 15) { Height = 26, Padding = new Thickness(9, 0) };
        return button.Keys("Fill06", "Fill10");
    }

    /// 「群」页签：只列群（没有任何筛选）；历史群收成一行
    void GroupsTab()
    {
        var live = GroupState.Shared.Items.Where(g => g.Live).ToList();
        var past = GroupState.Shared.Items.Count - live.Count;
        if (live.Count == 0)
            content.Children.Add(Ui.Text(L("还没有会话群。点「建群」，或把一个会话拖到另一个会话上，让它们互相沟通。"), 11.5, color: "Text2", lines: 0).Wrap().Margin(4, 14, 4, 0));
        foreach (var group in live) content.Children.Add(new GroupRowView(group, main));
        if (past > 0)
            content.Children.Add(new Tap(Ui.H(6, Ui.Sym("clock.arrow.circlepath", 11, "Text2"), Ui.Text(L("历史群 %@ 个", past), 11.5, color: "Text2")).Pad(7, 4),
                () => main.Selection = MainModel.GroupsId, 6).Keys("Transparent", "Fill05").Tip(L("成员会话都已关闭的群。在群里发消息，会在原来的项目里恢复它们接着协作。")));
    }

    /// 第一次看到会话组、群这几页时的提示卡（关了记住，不再出）
    bool TipVisible => !Prefs.Bool("sidebarTipDone");

    Control TipCard()
    {
        void Dismiss()
        {
            Prefs.Set("sidebarTipDone", true);
            Schedule();
        }
        var stack = Ui.VFill(5,
            Ui.Text(L("会话列表有新的排法"), 12.5, FontWeight.SemiBold),
            Ui.Text(L("会话：所有运行中的会话，筛选和显示方式都在这里；设备、项目收成一行，点开再选。"), 11.5, color: "Text2", lines: 0).Wrap(),
            Ui.Text(L("群：把几个会话拉到一起互相沟通，建群在这里。"), 11.5, color: "Text2", lines: 0).Wrap(),
            Ui.Text(L("会话组：把同一阶段的相关会话放一组，切到哪组右边就多列显示哪组；组名和颜色可以改，还能一键把组里的会话拉成群，手机上也能看到。"), 11.5, color: "Text2", lines: 0).Wrap(),
            Ui.H(6,
                new GlassButton(L("知道了"), null, Dismiss, height: 26),
                new GlassButton(L("看看会话组"), null, () => { Dismiss(); main.ListTab = "tabgroups"; }, prominent: true, height: 26)).Margin(0, 0, 0, 0));
        return Ui.Box(stack, new Thickness(10, 9, 10, 10), "Fill06", 12);
    }

    Control Tiles()
    {
        var todos = TodoState.Shared;
        var sessions = model.Sessions;
        var running = sessions.Select(s => s.SourceId + "\n" + s.Cwd).Distinct().Count();
        var waiting = sessions.Where(s => s.IsWaiting).Select(s => s.SourceId + "\n" + s.Cwd).Distinct().Count();
        var t = tiles.Today;
        Control TodaySub()
        {
            if (t is null) return Ui.Text(L("今日各项目工作汇总"), 11, color: "Text2");
            if (t.Value.Sessions == 0) return Ui.Text(L("今日暂无动态"), 11, color: "Text2");
            var rest = string.Join(" · ", new[] { L("%@ 个会话", t.Value.Sessions) }.Concat(t.Value.Files > 0 ? [L("%@ 个文件", t.Value.Files)] : []));
            if (t.Value.TestFailed > 0)
                return Ui.H(0, Ui.Text(L("测试失败 %@ 次", t.Value.TestFailed), 11, color: "Red"), Ui.Text(" · " + rest, 11, color: "Text2").Shrink());
            return Ui.Text(rest, 11, color: "Text2");
        }
        var u = tiles.Usage;
        var favorites = FavoriteState.Shared.Items.Count;
        // 今日用量一张大卡片（各台电脑的额度环）；历史会话、今日动态一行；待办、项目、收藏一行小格
        // （同 Mac 版，10-27 起的格子，10-31 改：今日用量和今日动态对调位置和大小）
        return Ui.VFill(8,
            new SidebarLimitsTile(tiles.Limits, (u?.Tokens ?? 0) > 0 ? L("%@ token", UsageFormat.Compact(u!.Value.Tokens)) : "",
                u is null ? L("Claude Code 回复后显示 5 小时与本周额度")
                : L("%@ · %@ 输出 · %@ 次", UsageFormat.Money(u.Value.Cost), UsageFormat.Compact(u.Value.Output), (int)u.Value.Requests), main,
                tiles.LimitsBusy, tiles.RefreshLimits),
            new EqualRow(8,
                new SidebarTile(MainModel.HistoryId, "clock.arrow.circlepath", L("历史会话"), "", "", 0, Ui.Text(L("浏览 · 搜索 · 恢复"), 11, color: "Text2"), main),
                new SidebarTile(MainModel.TodayId, "sun.max.fill", L("今日动态"), (t?.Prompts ?? 0) > 0 ? t!.Value.Prompts.ToString() : "", L("轮"), 0, TodaySub(), main)),
            new EqualRow(8,
                new SidebarTile(MainModel.TodosId, "checklist", L("待办"), todos.Open > 0 ? todos.Open.ToString() : "", "", todos.Suggested, null, main, compact: true),
                new SidebarTile(MainModel.ProjectsId, "folder.fill", L("项目"), running > 0 ? running.ToString() : "", "", 0, null, main,
                    valueColor: waiting > 0 ? "Orange" : null, compact: true),
                new SidebarTile(MainModel.FavoritesId, "star.fill", L("收藏"), favorites > 0 ? favorites.ToString() : "", "", 0, null, main, compact: true)));
    }

    /// 「会话」页签下面（同 Mac 版 controls）：状态筛选胶囊（全部 · 标记 · 工作中 · 待确认 常驻，出错有的时候才出现；数字跟着设备、项目筛选走）；
    /// 再下面一行：设备、项目收成一行（只写着选的是哪个，点开才是两排胶囊，选完自动收起），右边「显示方式」
    Control Controls(List<SessionInfo> baseList, List<SessionInfo> sorted)
    {
        var stack = Ui.VFill(8);
        if (model.Sessions.Count > 1 || IsFiltering)
        {
            var chips = new List<Control>();
            foreach (var option in StatusOptions)
            {
                var n = baseList.Count(s => Matches(s, option.Id));
                if (option.Id != "error" || n > 0 || Status == option.Id)
                {
                    var id = option.Id;
                    chips.Add(new FilterChip(L(option.Title), n, option.Dot, Status == id, () => main.StatusFilter = Status == id && id != "all" ? "all" : id,
                                             id == "marked" ? "star.fill" : null));
                }
            }
            stack.Children.Add(new FilterBar(chips));
        }
        var project = ActiveProject;
        var sourceId = ActiveSource?.Id;
        // 项目下拉按列表里的先后，个数跟着设备筛选走；设备下拉的个数跟着项目筛选走
        var projects = sorted.Where(s => s.Folder.Length > 0 && (sourceId is null || s.SourceId == sourceId))
            .GroupBy(s => s.Folder).Select(g => (g.Key, g.Key, g.Count())).ToList();
        // 设备那排只列有会话的设备（筛着的那台没会话了也列着）；不止一台设备、不止一个项目时才有
        var busy = model.Sessions.Select(s => s.SourceId).ToHashSet();
        var inProject = sorted.Where(s => project is null || s.Folder == project).ToList();
        var sources = model.Sources.Where(src => busy.Contains(src.Id) || src.Id == sourceId)
            .Select(src => (src.Id, src.Name, inProject.Count(s => s.SourceId == src.Id))).ToList();
        var bySource = sources.Count > 1 || sourceId is not null;
        var byProject = projects.Count > 1 || project is not null;
        var showsView = model.Sessions.Count > 1 || !IsDefaultView;
        if (bySource || byProject || showsView)
            stack.Children.Add(Ui.H(6, bySource || byProject ? ScopeSummary(bySource, byProject) : null, new Border().Grow(), showsView ? ViewMenu() : null));
        if (scopeOpen && bySource)
            stack.Children.Add(ScopeBar.Build("desktopcomputer", L("全部设备"), sources, sourceId ?? "", id => { scopeOpen = false; main.SourceFilter = id; }));
        if (scopeOpen && byProject)
            stack.Children.Add(ScopeBar.Build("folder", L("全部项目"), projects, project ?? "", name => { scopeOpen = false; main.ProjectFilter = name; }));
        return stack.Margin(0, 10, 0, 2);
    }

    /// 收起时的一行：「🖥 全部设备 · 📁 项目 ⌄」，筛着的那项用主题色；点一下展开 / 收起两排胶囊
    Control ScopeSummary(bool bySource, bool byProject)
    {
        var parts = new List<Control>();
        if (bySource)
        {
            var on = ActiveSource is not null;
            parts.Add(Ui.Sym("desktopcomputer", 11, on ? "Accent" : "Text"));
            parts.Add(Ui.Text(ActiveSource?.Name ?? L("全部设备"), 12, FontWeight.Medium, on ? "Accent" : "Text").Shrink());
        }
        if (bySource && byProject) parts.Add(Ui.Text("·", 12, color: "Text3"));
        if (byProject)
        {
            var on = ActiveProject is not null;
            parts.Add(Ui.Sym("folder", 11, on ? "Accent" : "Text"));
            parts.Add(Ui.Text(ActiveProject ?? L("全部项目"), 12, FontWeight.Medium, on ? "Accent" : "Text").Shrink());
        }
        parts.Add(Ui.Sym(scopeOpen ? "chevron.up" : "chevron.down", 9, "Text3"));
        var button = new Tap(Ui.H(5, parts.ToArray()), () => { scopeOpen = !scopeOpen; Schedule(); }, 15) { Height = 30, Padding = new Thickness(11, 0) };
        button.Keys("Fill06", "Fill10");
        button.Tip(L("按设备、项目筛选"));
        return button;
    }

    /// 「建群」（「显示方式」左边，样子同它）：弹面板勾选要拉进来的会话（至少两个）
    static Control NewGroupButton()
    {
        var button = new Tap(Ui.H(5, Ui.Sym("person.2", 12, "Text2"), Ui.Text(L("建群"), 12, FontWeight.Medium, "Text2")), () => GroupPicker.Open([], null), 15)
        { Height = 30, Padding = new Thickness(11, 0) };
        button.Keys("Fill06", "Fill10");
        button.Tip(L("把几个会话拉进一个群，让它们互相沟通"));
        return button;
    }

    /// 「显示方式」：分组、排序放在一个菜单里；按钮上写着现在怎么分、怎么排，改过默认的用强调色。
    /// 项目选了某一个时没有分组（只剩排序）
    Control ViewMenu()
    {
        var parts = new List<string>();
        if (EffectiveGrouping != "none") parts.Add(L(GroupOptions.First(o => o.Id == main.Grouping).Title));
        if (main.Sorting != "started") parts.Add(L(SortOptions.FirstOrDefault(o => o.Id == main.Sorting).Title ?? ""));
        var summary = parts.Count == 0 ? L("显示方式") : string.Join(" · ", parts);
        var color = IsDefaultView ? "Text2" : "Accent";
        var button = new Tap(Ui.H(5, Ui.Sym("line.3.horizontal.decrease", 12, color), Ui.Text(summary, 12, FontWeight.Medium, color), Ui.Sym("chevron.down", 9, color)), null, 15)
        { Height = 30, Padding = new Thickness(11, 0) };
        button.Keys(IsDefaultView ? "Fill06" : "Tile", "Fill10");
        button.Tip(L("会话的分组与排序"));
        button.Click = () =>
        {
            var menu = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedRight };
            if (ActiveProject is null)
            {
                menu.Items.Add(new MenuItem { Header = L("分组"), IsEnabled = false });
                foreach (var (id, title) in GroupOptions) menu.Items.Add(Ui.Item(L(title), () => main.Grouping = id, check: main.Grouping == id ? "" : null));
                menu.Items.Add(new Separator());
            }
            menu.Items.Add(new MenuItem { Header = L("排序"), IsEnabled = false });
            foreach (var (id, title) in SortOptions) menu.Items.Add(Ui.Item(L(title), () => main.Sorting = id, check: main.Sorting == id ? "" : null));
            if (!IsDefaultView || IsFiltering)
            {
                menu.Items.Add(new Separator());
                menu.Items.Add(Ui.Item(L("恢复默认"), () => { main.Grouping = "none"; main.Sorting = "started"; ClearFilters(); }));
            }
            menu.ShowAt(button);
        };
        return button;
    }

    sealed record Group(string Key, string? Name, string? Sub, string? Agent, string? Source, List<SessionInfo> Items, bool Marked = false);

    /// 按来源 / 按项目 / 按 Agent 分组：组的先后跟着组里最靠前的会话走；按来源时照来源列表的顺序。
    /// 标记的会话不进各组，单独一组「标记」排在最上面（不分组时它们本来就排在最前）
    List<Group> Groups(List<SessionInfo> all)
    {
        var grouping = EffectiveGrouping;
        if (main.Query.Trim().Length > 0 || grouping == "none" || model.Sessions.Count <= 1) return [new Group("all", null, null, null, null, all)];
        var starred = all.Where(s => model.IsMarked(s.Key)).ToList();
        var items = all.Where(s => !model.IsMarked(s.Key)).ToList();
        var bySource = grouping == "source";
        var byAgent = grouping == "agent";
        var multi = model.Sessions.Select(s => s.SourceId).Distinct().Count() > 1;
        var order = new List<string>();
        var map = new Dictionary<string, Group>();
        foreach (var item in items)
        {
            var key = byAgent ? item.Agent : bySource ? item.SourceId : item.SourceId + "\n" + item.Cwd;
            if (!map.ContainsKey(key))
            {
                order.Add(key);
                map[key] = byAgent
                    ? new Group(key, Agents.Info(item.Agent).Name, null, item.Agent, null, [])
                    : new Group(key, bySource ? (item.SourceName.Length == 0 ? L("未知来源") : item.SourceName) : (item.Folder.Length == 0 ? L("（未知目录）") : item.Folder),
                                !bySource && multi ? item.SourceName : null, null, bySource || multi ? item.SourceId : null, []);
            }
            map[key].Items.Add(item);
        }
        var result = order.Select(k => map[k]).ToList();
        if (bySource)
        {
            var ids = model.Sources.Select(s => s.Id).ToList();
            result = result.OrderBy(g => ids.IndexOf(g.Key) is var i && i >= 0 ? i : ids.Count).ToList();
        }
        else if (main.Sorting == "name") result = result.OrderBy(g => g.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        if (starred.Count > 0) result.Insert(0, new Group("\u0001marked", L("标记"), null, null, null, starred, true));
        return result;
    }

    Control GroupHeader(Group group, string name)
    {
        var row = Ui.H(6,
            group.Marked ? Ui.Sym("star.fill", 11, "Accent") : null,
            group.Agent is null ? null : new AgentGlyph(group.Agent, 12, "Text2"),
            Ui.Text(name, 11, FontWeight.SemiBold, "Text2").Shrink(),
            group.Sub is null ? null : Ui.Text(group.Sub, 11, FontWeight.SemiBold, "Text3"),
            // 按来源分组：组头的 CPU / 内存点了打开设备详情
            group.Source is not string source ? null
                : new Tap(new MachineStatsRow(model, source), () => AgentDetails.OpenMachine(source, name), 4).Keys("Transparent", "Fill08").Tip(L("设备详情")).Margin(2, 0, 0, 0),
            new Spacer(4),
            Ui.Text(group.Items.Count.ToString(), 11, FontWeight.SemiBold, "Text3").Digits());
        return row.Margin(0, 14, 0, 4);
    }

    /// 筛得一个不剩：说清楚是哪一类没有，给个「显示全部」
    Control EmptyFilter()
    {
        var title = StatusOptions.FirstOrDefault(o => o.Id == Status && o.Id != "all").Title;
        var place = (ActiveSource is SourceInfo s ? L("%@上", s.Name) : "") + (ActiveProject is string p ? L("「%@」项目里", p) : "");
        var name = place + (title is null ? L("的会话") : L("%@的会话", L(title)));
        return Ui.Stack(Orientation.Vertical, 8, Align.Center, [
            Ui.Text(L("暂无%@", name), 12, color: "Text2"),
            new GlassButton(L("显示全部"), null, ClearFilters, height: 24),
        ]).HAlign(HorizontalAlignment.Center).Margin(0, 14, 0, 14);
    }
}

/// 会话那一行（同 Mac 版 SessionRow + SidebarRowHighlight）：选中 = 淡强调色底 + 细边，悬停 = 一层浅灰
public sealed class SessionRowView : Tap
{
    readonly AppModel model;
    readonly MainModel main;
    SessionInfo? shown;
    string? key;
    bool selected;

    public SessionRowView(AppModel model, MainModel main) : base(null, null, 10)
    {
        this.model = model;
        this.main = main;
        Padding = new Thickness(7, 5);
        Click = () => { if (key is not null) main.Selection = key; };
        this.Menu(() => key is null ? [] : SessionMenu.Items(model, main, key));
        DragDrop.SetAllowDrop(this, false);
        // 把另一个会话拖到这一行上松开：拉这两个会话建群
        GroupDrop.Attach(this, () => key, dragged => { if (key is not null) GroupPicker.Open([dragged, key], null); });
        PointerMoved += StartDrag;
        PointerPressed += (_, e) => dragFrom = e.GetPosition(this);
        PointerEntered += (_, _) => Hover(true);
        PointerExited += (_, _) => Hover(false);
    }

    Point? dragFrom;
    // 右上角：鼠标移到卡片上时，时间换成「×」（同 Mac 版），点了先确认再关闭会话；不能关的会话没有
    Control? closeMark, timeText;
    bool hovered;

    /// 自测用：卡片上的会话标题
    internal string? ShownTitle => shown?.Title;

    internal void Hover(bool on)
    {
        hovered = on;
        if (closeMark is null || timeText is null) return;
        closeMark.Opacity = on ? 1 : 0;
        closeMark.IsHitTestVisible = on;
        timeText.Opacity = on ? 0 : 1;
    }

    async void StartDrag(object? sender, PointerEventArgs e)
    {
        if (dragFrom is not Point from || key is null || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        var p = e.GetPosition(this);
        if (Math.Abs(p.X - from.X) + Math.Abs(p.Y - from.Y) < 6) return;
        dragFrom = null;
        var data = new DataObject();
        data.Set(PaneDrag.Format, PaneDrag.Encode(key, null));
        // 拖进分屏 = Move，拖进群（群聊页、群那一行、别的会话上）= Link：两样都要允许，
        // 不然 Windows 的拖放把目标给的 Link 和这里允许的取交集成了 None，松手不触发放下
        await DragDrop.DoDragDrop(e, data, DragDropEffects.Move | DragDropEffects.Link);
    }

    public void Update(SessionInfo s)
    {
        var isSelected = main.Selection == s.Key;
        var pinned = model.IsPinned(s.Key);
        var marked = model.IsMarked(s.Key);
        var muted = model.IsMuted(s.Key);
        if (s == shown && isSelected == selected && Child is not null && pinned == lastPinned && marked == lastMarked && muted == lastMuted && Look.Size == lastSize) return;
        shown = s;
        key = s.Key;
        selected = isSelected;
        lastPinned = pinned;
        lastMarked = marked;
        lastMuted = muted;
        lastSize = Look.Size;
        if (selected) { Keys("AccentFill14", "AccentFill14"); BorderThickness = new Thickness(1); this.Res(BorderBrushProperty, "AccentEdge32"); }
        else { Keys("Transparent", "Fill05", "Fill08"); BorderThickness = new Thickness(0); }
        var (line, lineColor) = SessionLine.Of(s);
        var title = Ui.H(4,
            new AgentGlyph(s.Agent, 12, "Text2").Tip(Agents.Info(s.Agent).Name),
            Ui.Text(s.Title, 13, FontWeight.SemiBold).Shrink(),
            marked ? new Tap(Ui.Sym("star.fill", 10, "Accent"), () => model.SetMarked(s.Key, false), 4).Keys("Transparent", "Fill08").Tip(L("已标记，点按取消标记")) : null,
            pinned ? Ui.Sym("pin.fill", 9, "Text3").Tip(L("已置顶")) : null,
            muted ? Ui.Sym("bell.slash", 10, "Text3").Tip(L("已静音：仅在需要确认时提醒")) : null,
            new Spacer(4),
            Corner(s, marked));
        var meta = Ui.H(4,
            Ui.Sym(s.SourceKind == "ssh" ? "server.rack" : "laptopcomputer", 10.5, "Text3"),
            Ui.Text($"{s.SourceName} · {s.Folder}", 10.5, color: "Text3").Shrink(),
            s.Usage?.Percent is int pct && pct >= 70 ? new Spacer(4) : null,
            s.Usage?.Percent is int p2 && p2 >= 70 ? Ui.Text(L("上下文 %@%", p2), 10.5, color: p2 >= 90 ? "Red" : "Orange") : null);
        Control lineView = Ui.Text(line, 11.5, color: lineColor, lines: 1).Tip(SessionLine.Detail(s));
        // 正在做的会话：这一轮做到第几步（主题色小标识，几个会话各到哪一步一眼看清）
        if (s.LiveStage is StageInfo stage) lineView = Ui.HTop(5, StageBadge.Make(stage, 10.5).Margin(0, 1, 0, 0), lineView.Shrink());
        // 设了目标的：目标到哪了（鼠标停上去看目标原文）
        if (s.ListGoal is GoalInfo goal) lineView = Ui.HTop(5, GoalBadge.Make(goal, 10.5).Margin(0, 1, 0, 0), lineView.Shrink());
        var text = Ui.VFill(2, title, lineView, meta);
        meta.ClipToBounds = true;
        Avatar = new SessionAvatar(s.Title, s.Activity, 34, SessionFace.Make(s.Key, 34, 0.28)).Margin(0, 1, 0, 0);
        Child = Ui.HTop(10, Avatar, text.Grow());
    }

    /// 时间；悬停时同一格换成「☆」（没标记的，点了标记）和「×」（能关的会话）：平时透明、点不到，占着位置，悬停时卡片不跳
    Control Corner(SessionInfo s, bool marked)
    {
        var time = Ui.Text(Format.Short(s.UpdatedAt), 10.5, color: "Text3");
        time.HorizontalAlignment = HorizontalAlignment.Right;
        time.VerticalAlignment = VerticalAlignment.Center;
        closeMark = timeText = null;
        var key = s.Key;
        var closable = s.CanReply && s.Can("close");
        if (!closable && marked) return time;
        Control? star = null;
        if (!marked)
        {
            var icon = Ui.Sym("star", 9.5, "Text2");
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            star = new Tap(icon, () => model.SetMarked(key, true), 9) { Width = 17, Height = 17 }.Keys("Fill08", "Fill15").Tip(L("标记：排在所有列表的最上面"));
        }
        Control? close = null;
        if (closable)
        {
            var x = Ui.Sym("xmark", 8.5, "Text2");
            x.FontWeight = FontWeight.Bold;
            x.HorizontalAlignment = HorizontalAlignment.Center;
            close = new Tap(x, () => SessionMenu.Close(model, key), 9) { Width = 17, Height = 17 }.Keys("Fill08", "Fill15").Tip(L("关闭会话…"));
        }
        var buttons = Ui.H(4, star, close);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        closeMark = buttons;
        timeText = time;
        Hover(hovered);
        return new Panel { Children = { time, buttons } };
    }

    /// 头像（会话之间的消息：纸鸢从这飞、风筝线接在这，见 PeerOverlay）
    public Control? Avatar { get; private set; }

    bool lastPinned, lastMarked, lastMuted;
    LookSize? lastSize;
}

/// 会话那行的小字（同 Mac 版 SessionItem.status）：只说状态——待确认什么工具、正在运行什么工具、可能停滞、出错、空闲；
/// 不放回复内容（截短的两行看了也看不全，11-10 用户），进度由前面的「2/4 开发中」标识说
public static class SessionLine
{
    /// 「Bash: S=/tmp/…」只取冒号前的工具名（太长就不要）
    static string? Tool(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var head = text.Split(':', 2)[0].Trim();
        return head.Length == 0 || head.Length > 24 ? null : head;
    }

    public static (string Text, string Color) Of(SessionInfo s)
    {
        if (s.Error is string) return (L("出错已停止"), "Red");
        if (s.IsWaiting) return (Tool(s.PendingTool) is string t ? L("待确认 · %@", t) : L("待确认"), "Orange");
        if (s.IsBusy)
        {
            if (s.UpdatedAt is double updated && (int)((Format.NowMs - updated) / 60000) is var minutes && minutes >= 20)
                return (L("可能停滞：%@ 分钟无进展", minutes), "Orange");
            return (Tool(s.ActivityText) is string a ? L("正在运行 %@", a) : L("正在工作…"), "Accent");
        }
        return (L("空闲"), "Text2");
    }

    /// 指着状态看的完整说明（原来那行小字：等确认的原因、正在做什么、出错原因、最后一句）
    public static string Detail(SessionInfo s)
    {
        string text;
        if (s.IsWaiting) text = s.Blocking ?? s.Reason ?? L("需要确认");
        else if (s.IsBusy) text = s.ActivityText is string a ? L("正在 %@", a) : s.Reason ?? L("正在工作…");
        else if (s.Error is string error) text = L("出错已停止：%@", error);
        else text = (s.Preview ?? s.Reason ?? "").Replace("\n", " ");
        return text.Replace("**", "").Replace("`", "");
    }
}

/// 入口格子：左上小方块图标（有新东西时右上角红色数字），右上角的数，下面名字和一行小字；选中时淡强调色底（同 Mac 版 SidebarTile）
public sealed class SidebarTile : Tap
{
    /// compact：一行三个的小格，只有图标、数字和名字，没有那行小字（sub 传 null）
    public SidebarTile(string id, string symbol, string title, string value, string unit, int badge, Control? sub, MainModel main,
                       string? valueColor = null, bool compact = false) : base(null, () => main.Selection = id, 12)
    {
        var selected = main.Selection == id;
        Padding = new Thickness(10);
        if (selected) { Keys("AccentFill16", "AccentFill16"); BorderThickness = new Thickness(1); this.Res(BorderBrushProperty, "AccentEdge40"); }
        else Keys("Fill05", "Fill08");
        var icon = new Panel { Children = { new DuoIcon(symbol, 28) } };
        if (badge > 0)
            icon.Children.Add(new Border
            {
                MinWidth = 16, Height = 16, CornerRadius = new CornerRadius(8), Padding = new Thickness(4, 0),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                RenderTransform = new TranslateTransform(6, -6),
                Child = Ui.Text(badge > 99 ? "99+" : badge.ToString(), 10, FontWeight.Bold, "White").Digits().HAlign(HorizontalAlignment.Center),
            }.Res(Border.BackgroundProperty, "Red"));
        var head = Ui.H(6, icon, new Spacer(6),
            value.Length == 0 ? null : Ui.H(2, Ui.Text(value, compact ? 15 : 18, FontWeight.Bold, valueColor ?? "Text").Digits(), unit.Length == 0 ? null : Ui.Text(unit, 11, color: "Text2")));
        if (sub is TextBlock t) t.Trim();
        Child = Ui.VFill(8, head, Ui.VFill(2, Ui.Text(title, 13, FontWeight.SemiBold).Trim(), compact ? null : sub));
    }
}

/// 一行几个一样宽、一样高的格子（侧栏「历史会话 · 今日用量」「待办 · 项目 · 收藏」两行）
public sealed class EqualRow : Panel
{
    readonly double spacing;

    public EqualRow(double spacing, params Control[] children)
    {
        this.spacing = spacing;
        foreach (var child in children) Children.Add(child);
    }

    double Cell(double width) => Children.Count == 0 ? 0 : (width - spacing * (Children.Count - 1)) / Children.Count;

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 268 : available.Width;
        double h = 0;
        foreach (var child in Children) { child.Measure(new Size(Cell(width), double.PositiveInfinity)); h = Math.Max(h, child.DesiredSize.Height); }
        return new Size(width, h);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var w = Cell(final.Width);
        for (var i = 0; i < Children.Count; i++) Children[i].Arrange(new Rect(i * (w + spacing), 0, w, final.Height));
        return final;
    }
}

/// 入口格子的排法：两列；一格放不下的占一整行，落单的也撑满一行；同一行的格子一样高（同 Mac 版 TileGrid）
public sealed class TileGrid : Panel
{
    public double Spacing { get; set; } = 8;
    List<int[]> rows = [];

    List<int[]> Rows(double width)
    {
        var kids = Children.ToList();
        var cell = (width - Spacing) / 2;
        var wide = kids.Select(k => { k.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); return k.DesiredSize.Width > cell + 0.5; }).ToList();
        var result = new List<int[]>();
        for (var i = 0; i < kids.Count;)
        {
            if (!wide[i] && i + 1 < kids.Count && !wide[i + 1]) { result.Add([i, i + 1]); i += 2; }
            else { result.Add([i]); i += 1; }
        }
        return result;
    }

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 268 : available.Width;
        rows = Rows(width);
        double total = 0;
        foreach (var row in rows)
        {
            var w = row.Length == 2 ? (width - Spacing) / 2 : width;
            double h = 0;
            foreach (var i in row) { Children[i].Measure(new Size(w, double.PositiveInfinity)); h = Math.Max(h, Children[i].DesiredSize.Height); }
            total += h;
        }
        total += Spacing * Math.Max(0, rows.Count - 1);
        return new Size(width, total);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double y = 0;
        foreach (var row in rows)
        {
            var w = row.Length == 2 ? (final.Width - Spacing) / 2 : final.Width;
            var h = row.Max(i => Children[i].DesiredSize.Height);
            for (var k = 0; k < row.Length; k++) Children[row[k]].Arrange(new Rect(k * (w + Spacing), y, w, h));
            y += h + Spacing;
        }
        return final;
    }
}

/// 侧栏底栏（同 Mac 版 SidebarFooter）：来源 · 手机数 · 虚拟屏幕 · 二维码 · 设置，每项都是按钮
public sealed class SidebarFooter : Panel
{
    readonly AppModel model;
    readonly Border bar;

    public SidebarFooter(AppModel model)
    {
        this.model = model;
        Margin = new Thickness(10);
        // 阴影单独一层：和按钮放在同一个 Border 上时，离屏截图里按钮会画不出来
        Children.Add(new Border { CornerRadius = new CornerRadius(18), Background = Brushes.Transparent, BoxShadow = BoxShadows.Parse("0 4 16 0 #22000000") });
        bar = new Border { Padding = new Thickness(6, 5), CornerRadius = new CornerRadius(18), BorderThickness = new Thickness(0.5) };
        bar.Res(Border.BackgroundProperty, "GlassSolid").Res(Border.BorderBrushProperty, "GlassEdge");
        Children.Add(bar);
        model.PropertyChanged += (_, e) => { if (e.PropertyName is nameof(AppModel.Sources) or nameof(AppModel.Connected)) Build(); };
        VirtualScreenState.Shared.PropertyChanged += (_, _) => Build();
        Build();
        // 已连接的手机几台（同 Mac 版底栏的手机数）：本机后台的状态接口，十秒看一次
        var timer = new DispatcherTimer(TimeSpan.FromSeconds(10), DispatcherPriority.Background, (_, _) => RefreshPhones());
        AttachedToVisualTree += (_, _) => { RefreshPhones(); timer.Start(); };
        DetachedFromVisualTree += (_, _) => timer.Stop();
    }

    object? Child { set => bar.Child = (Control?)value; }
    int phones;

    async void RefreshPhones()
    {
        try
        {
            var status = await model.Api.Get("/api/desktop/status");
            // 在托盘、控制台里换了界面语言，客户端跟着换
            Lang.Use(status.Str("uiLanguage"));
            VirtualScreenState.Shared.Apply(status.Obj("virtualScreen"));
            var count = status.Int("clients") ?? 0;
            if (count != phones) { phones = count; Build(); }
        }
        catch { }
    }

    void Build()
    {
        var online = model.Sources.Count(s => s.Online);
        Tap Button(Control label, string tip, Action action) => (Tap)new Tap(label, action, 10) { MinWidth = 32, MinHeight = 32, Padding = new Thickness(8, 0) }.Tip(tip);
        Child = Ui.H(2,
            Button(Ui.H(6, Ui.Dot(8, online > 0 && model.Connected ? "Green" : "Red"), Ui.Text(L("%@/%@ 来源", online, model.Sources.Count), 13, FontWeight.Medium, "Text2")),
                L("来源：点击管理"), () => SettingsWindow.Open("sources")),
            Button(Ui.H(5, Ui.Sym("iphone", 14, "Text2"), Ui.Text(phones.ToString(), 13, FontWeight.Medium, "Text2").Digits()),
                L("已连接的手机：点击打开手机访问"), () => SettingsWindow.Open("phone")),
            // 有新版本时：手机数和右边几个图标中间一个绿色向上箭头（没有更新时不占地方）
            new Spacer(4),
            new UpdateButton(24),
            new Spacer(4),
            // VS Code 在虚拟屏幕中运行：开着时图标用主题色（同 Mac 版）
            VirtualScreenState.Shared is { Supported: true } screen
                ? Button(Ui.Sym("display", 15, screen.On ? "Accent" : "Text2"), screen.Help, () => screen.Toggle()) : null,
            Button(Ui.Sym("qrcode", 16, "Text2"), L("手机访问"), () => SettingsWindow.Open("phone")),
            Button(Ui.Sym("gearshape", 16, "Text2"), L("设置"), () => SettingsWindow.Open("general")));
    }
}

/// 机器的 CPU、内存（组头上机器名右边，同 Mac 版 MachineStatsRow）：两个小圆环 + 数，占用高了变橙、变红
public sealed class MachineStatsRow : Panel
{
    readonly AppModel model;
    readonly string sourceId;

    public MachineStatsRow(AppModel model, string sourceId)
    {
        this.model = model;
        this.sourceId = sourceId;
        model.MachineStatsChanged += Build;
        DetachedFromVisualTree += (_, _) => model.MachineStatsChanged -= Build;
        Build();
    }

    void Build()
    {
        Children.Clear();
        if (model.LiveStats(sourceId) is not MachineStats stats) return;
        var row = Ui.H(6,
            stats.Cpu is double cpu ? Ui.H(3, new Ring(cpu, 9), Ui.Text("CPU " + MachineFormat.Percent(cpu), 10.5, color: "Text3").Digits()) : null,
            stats.MemRatio is double mem && stats.MemUsed is double used && stats.MemTotal is double total
                ? Ui.H(3, new Ring(mem, 9), Ui.Text(L("内存 %@/%@", MachineFormat.Gigabytes(used).Replace(" GB", ""), MachineFormat.Gigabytes(total)), 10.5, color: "Text3").Digits()) : null);
        row.Tip(stats.Summary);
        Children.Add(row);
    }
}

/// 小圆环（占用多少）：70% 以上橙、90% 以上红，其余灰
public sealed class Ring : Control
{
    readonly double ratio;
    readonly double size;

    public Ring(double ratio, double size)
    {
        this.ratio = Math.Clamp(ratio, 0, 1);
        this.size = size;
        Width = size;
        Height = size;
        VerticalAlignment = VerticalAlignment.Center;
    }

    public override void Render(DrawingContext context)
    {
        var rect = new Rect(0.75, 0.75, size - 1.5, size - 1.5);
        context.DrawEllipse(null, new Pen(Palette.Get("Fill15"), 1.5), rect);
        var color = ratio >= 0.9 ? Palette.Get("Red") : ratio >= 0.7 ? Palette.Get("Orange") : Palette.Get("Text2");
        if (ratio <= 0) return;
        var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
        {
            var c = rect.Center; var r = rect.Width / 2;
            var start = -Math.PI / 2; var end = start + Math.PI * 2 * Math.Min(ratio, 0.999);
            ctx.BeginFigure(new Point(c.X + r * Math.Cos(start), c.Y + r * Math.Sin(start)), false);
            ctx.ArcTo(new Point(c.X + r * Math.Cos(end), c.Y + r * Math.Sin(end)), new Size(r, r), 0, ratio > 0.5, SweepDirection.Clockwise);
            ctx.EndFigure(false);
        }
        context.DrawGeometry(null, new Pen(color, 1.5, lineCap: PenLineCap.Round), geometry);
    }
}

/// 侧栏入口格子要的数：今日动态的轮数、会话数、文件数、测试失败；今日用量的花费、输出、次数（每 5 分钟、连上时重新拉）；
/// 各台电脑的订阅额度（每次回复都在变，一分钟拉一次）
public sealed class SidebarTilesModel
{
    public (int Prompts, int Sessions, int Files, int TestFailed)? Today { get; private set; }
    public (double Cost, double Output, double Requests, double Tokens)? Usage { get; private set; }
    public List<LimitDevice> Limits { get; private set; } = [];
    /// 卡片上的刷新按钮转圈
    public bool LimitsBusy { get; private set; }
    public event Action? Changed;
    DispatcherTimer? timer;
    DispatcherTimer? limitsTimer;

    public void Start()
    {
        timer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(5) };
        timer.Tick += (_, _) => Load();
        timer.Start();
        limitsTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        limitsTimer.Tick += (_, _) => LoadLimits();
        limitsTimer.Start();
        AppModel.Shared.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppModel.Connected) && AppModel.Shared.Connected) Load(); };
        Load();
    }

    public async void Load()
    {
        var api = AppModel.Shared.Api;
        try
        {
            var digest = await api.Get("/api/digest", new Dictionary<string, string> { ["range"] = "today" });
            var t = digest.Obj("totals");
            Today = (t.Int("prompts") ?? 0, t.Int("sessions") ?? 0, t.Int("files") ?? 0, t.Int("testFailed") ?? 0);
        }
        catch (Exception) { }
        await FetchUsage();
        await FetchLimits();
        Changed?.Invoke();
    }

    async void LoadLimits()
    {
        await FetchLimits();
        Changed?.Invoke();
    }

    /// 卡片上的刷新按钮（11-03）：额度、今天的 token 数都跳过缓存当场问各台电脑
    public async void RefreshLimits()
    {
        if (LimitsBusy) return;
        LimitsBusy = true;
        Changed?.Invoke();
        await Task.WhenAll(FetchUsage(fresh: true), FetchLimits(fresh: true));
        LimitsBusy = false;
        Changed?.Invoke();
        AppModel.Shared.Flash(LimitsBoard.RefreshedNote(Limits));
    }

    async Task FetchUsage(bool fresh = false)
    {
        try
        {
            var query = new Dictionary<string, string> { ["days"] = "1" };
            if (fresh) query["fresh"] = "1";
            var t = (await AppModel.Shared.Api.Get("/api/usage", query)).Obj("totals");
            Usage = (t.Num("cost") ?? 0, t.Num("output") ?? 0, t.Num("requests") ?? 0,
                     new[] { "input", "output", "cacheRead", "cacheWrite" }.Sum(k => t.Num(k) ?? 0));
        }
        catch (Exception) { }
    }

    /// 旧版电脑端没有这个接口：当没有读数，卡片退回一行花费
    async Task FetchLimits(bool fresh = false)
    {
        try { Limits = LimitDevice.ParseAll(await AppModel.Shared.Api.Get("/api/limits", fresh ? new Dictionary<string, string> { ["fresh"] = "1" } : null)); }
        catch (Exception) { }
    }
}

public static class UsageFormat
{
    /// 「$9.39」
    public static string Money(double cost) => UsagePage.Money(cost);

    /// 「14k」「1.2M」
    public static string Compact(double n) =>
        n >= 1_000_000_000 ? $"{n / 1_000_000_000:0.0}B" : n >= 1_000_000 ? $"{n / 1_000_000:0.0}M" : n >= 1000 ? $"{Math.Round(n / 1000):0}k" : ((int)n).ToString();
}
