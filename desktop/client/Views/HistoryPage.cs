using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 历史会话里的一条（会话列表或搜索结果）
public sealed record PastItem(string Key, string SessionId, string SourceId, string SourceName, string Cwd, string? Title, string? FirstPrompt,
                              double LastActive, bool Live, IReadOnlyList<(string Id, double Ts, string Who, string Snippet)> Hits)
{
    public string Folder => Path.GetFileName(Cwd.TrimEnd('/', '\\'));
    /// 搜到它是因为项目名（project）或标题（title）里有搜索词（可能没有正文片段）
    public IReadOnlyList<string> Match { get; init; } = [];
    public string DisplayTitle => !string.IsNullOrEmpty(Title) ? Title : !string.IsNullOrEmpty(FirstPrompt) ? (FirstPrompt.Length > 40 ? FirstPrompt[..40] : FirstPrompt) : Folder.Length == 0 ? L("会话") : Folder;

    public static PastItem? Parse(JsonNode? n)
    {
        if (n.Str("key") is not string key || n.Str("sessionId") is not string sid) return null;
        var me = AppModel.Shared.Me?.Name ?? L("我");
        var hits = n.Arr("hits").Items().Select(h => (h.Str("id") ?? "", h.Num("ts") ?? 0, h.Str("t") == "user" ? me : "Claude", h.Str("snippet") ?? "")).ToList();
        return new PastItem(key, sid, n.Str("sourceId") ?? "", Lang.Machine(n.Str("sourceName") ?? ""), n.Str("cwd") ?? "", n.Str("title"), n.Str("firstPrompt"),
                            n.Num("lastActive") ?? 0, n.Truthy("live"), hits)
        { Match = n.Arr("match").Items().Select(m => m is JsonValue v && v.TryGetValue<string>(out var text) ? text : "").ToList() };
    }

    public PastSession Meta => new(Key, DisplayTitle, Cwd, SourceName, FirstPrompt, LastActive, Live, null);
}

/// 主窗口右侧的「历史会话」（同 Mac 版 HistoryView）：所有项目的对话（包括已结束的），可按设备、项目筛，按标题、项目名和对话内容搜
public sealed class HistoryPage : Panel
{
    static List<PastItem> sessions = [];
    static List<PastItem>? results;
    static string query = "";
    readonly PageBar bar;
    readonly StackPanel list = new();
    readonly Panel filters = new();
    readonly Spinner spinner = new(14) { IsVisible = false };
    DispatcherTimer? debounce;
    int seq;

    static string Grouping { get => Prefs.String("historyGrouping") ?? "none"; set => Prefs.Set("historyGrouping", value); }
    static string StatusFilter { get => Prefs.String("historyFilter") ?? "all"; set => Prefs.Set("historyFilter", value); }
    static string SourceFilter { get => Prefs.String("historySource") ?? ""; set => Prefs.Set("historySource", value); }
    /// 只看某个项目（项目名 = 目录最后一级，几台设备上同名的算一个；空 = 全部项目）
    static string ProjectFilter { get => Prefs.String("historyProject") ?? ""; set => Prefs.Set("historyProject", value); }

    public HistoryPage()
    {
        bar = new PageBar(L("历史会话"), L("%@ 个会话", sessions.Count), null, [PageBar.Button("arrow.clockwise", L("刷新"), () => { query = ""; Load(); })]);
        var box = new TextBox
        {
            Text = query, Watermark = L("搜索会话标题、项目名称和对话内容"), Classes = { "plain" },
            FontSize = Look.Pt(13), VerticalContentAlignment = VerticalAlignment.Center, Padding = new Thickness(0),
        };
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { debounce?.Stop(); query = box.Text ?? ""; Search(); } };
        // 打字停一下就搜，清空了马上回到列表
        box.TextChanged += (_, _) =>
        {
            debounce?.Stop();
            if (string.IsNullOrWhiteSpace(box.Text))
            {
                if (results is not null) { query = ""; results = null; ++seq; spinner.IsVisible = false; Build(); }
                return;
            }
            debounce = new DispatcherTimer(TimeSpan.FromMilliseconds(600), DispatcherPriority.Background, (_, _) => { debounce?.Stop(); query = box.Text ?? ""; Search(); });
            debounce.Start();
        };
        var search = new Border
        {
            Child = Ui.H(8, Ui.Sym("magnifyingglass", 13, "Text2"), box.Grow(), spinner), Padding = new Thickness(12, 9),
            CornerRadius = new CornerRadius(12), Margin = new Thickness(20, 14, 20, 8), BorderThickness = new Thickness(0.5),
        };
        search.Res(Border.BackgroundProperty, "Glass").Res(Border.BorderBrushProperty, "GlassEdge");
        var top = new StackPanel { Children = { search, filters } };
        var scroll = new ScrollViewer { Content = list.Pad(20, 0, 20, 20), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var dock = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        dock.Children.Add(top);
        dock.Children.Add(scroll);
        Children.Add(PageBar.Page(bar, dock));
        Build();
        AttachedToVisualTree += (_, _) => { if (results is null) Load(); };
    }

    async void Load()
    {
        var current = ++seq;
        spinner.IsVisible = true;
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/sessions");
            if (current != seq) return;
            sessions = reply.Arr("sessions").Items().Select(PastItem.Parse).OfType<PastItem>().ToList();
            results = null;
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
        finally { if (current == seq) spinner.IsVisible = false; }
        Build();
        LoadProject();
    }

    /// 按项目筛着时这个项目的会话另外取全，并进列表（各电脑只列最近 120 个，老一些的项目不全）
    async void LoadProject()
    {
        var name = ProjectFilter;
        if (name.Length == 0) return;
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/sessions", new Dictionary<string, string> { ["project"] = name });
            if (name != ProjectFilter) return;
            var have = sessions.Select(s => s.Key).ToHashSet();
            var extra = reply.Arr("sessions").Items().Select(PastItem.Parse).OfType<PastItem>().Where(p => !have.Contains(p.Key)).ToList();
            if (extra.Count == 0) return;
            sessions = sessions.Concat(extra).OrderByDescending(p => p.LastActive).ToList();
            Build();
        }
        catch { /* 补不全就算了，列表照常 */ }
    }

    async void Search()
    {
        var q = query.Trim();
        if (q.Length == 0) { results = null; Build(); return; }
        var current = ++seq;
        spinner.IsVisible = true;
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/search", new Dictionary<string, string> { ["q"] = q });
            if (current != seq) return;
            results = reply.Arr("results").Items().Select(PastItem.Parse).OfType<PastItem>().ToList();
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
        finally { if (current == seq) spinner.IsVisible = false; }
        Build();
    }

    static readonly (string Id, string Title, string? Dot)[] StatusOptions = [("all", "全部", null), ("live", "进行中", "Accent"), ("ended", "已结束", "Text2")];
    static readonly (string Id, string Title)[] GroupOptions = [("none", "按日期"), ("source", "按来源"), ("project", "按项目")];

    static bool Matches(PastItem item, string filter) => filter switch { "live" => item.Live, "ended" => !item.Live, _ => true };

    static List<string> SourceNames => sessions.Select(s => s.SourceName).Where(n => n.Length > 0).Distinct().ToList();
    static string? ActiveSource => SourceFilter.Length == 0 || !SourceNames.Contains(SourceFilter) ? null : SourceFilter;
    static bool IsFiltering => StatusFilter != "all" || ActiveSource is not null || ProjectFilter.Length > 0;
    /// 选了某个项目时按项目、按来源分都只剩一组：不给分组，按日期排（项目选「全部」时才有「按项目」）
    static string EffectiveGrouping => ProjectFilter.Length == 0 ? Grouping : "none";

    /// 在筛着的设备、项目里
    static bool InScope(PastItem i)
    {
        var source = ActiveSource;
        return (source is null || i.SourceName == source) && (ProjectFilter.Length == 0 || i.Folder == ProjectFilter);
    }

    static List<PastItem> Filtered(IEnumerable<PastItem> items) => items.Where(i => InScope(i) && Matches(i, StatusFilter)).ToList();

    void ClearFilters()
    {
        StatusFilter = "all";
        SourceFilter = "";
        SetProject("");
    }

    void SetProject(string name)
    {
        if (name == ProjectFilter) return;
        ProjectFilter = name;
        Build();
        if (results is null) LoadProject();
    }

    /// 「虚拟机上「ccpulse」项目里已结束的会话」
    static string FilterName()
    {
        var status = StatusFilter == "all" ? "" : L(StatusOptions.FirstOrDefault(o => o.Id == StatusFilter).Title ?? "");
        var place = (ActiveSource is string source ? L("%@上", source) : "") + (ProjectFilter.Length == 0 ? "" : L("「%@」项目里", ProjectFilter));
        return place + L("%@的会话", status);
    }

    void Build()
    {
        bar.Subtitle = results is not null ? L("找到 %@ 个会话", Filtered(results).Count) : L("%@ 个会话", sessions.Count);
        filters.Children.Clear();
        if (sessions.Count > 0 || IsFiltering) filters.Children.Add(FilterRow());
        list.Children.Clear();
        if (results is not null) { SearchList(results); return; }
        var shown = Filtered(sessions);
        if (shown.Count == 0 && sessions.Count > 0)
        {
            list.Children.Add(Ui.Stack(Orientation.Vertical, 10, Align.Center, [
                Ui.Sym("line.3.horizontal.decrease", 28, "Text3"), Ui.Text(L("暂无%@", FilterName()), 15, FontWeight.SemiBold),
                new GlassButton(L("显示全部"), null, () => { ClearFilters(); Build(); }, height: 26),
            ]).HAlign(HorizontalAlignment.Center).Margin(0, 80, 0, 0));
            return;
        }
        foreach (var (title, items) in Sections(shown))
        {
            list.Children.Add(Ui.Text(title, 12, FontWeight.SemiBold, "Text2").Margin(8, 16, 0, 4));
            for (var i = 0; i < items.Count; i++)
            {
                if (i > 0) list.Children.Add(Ui.Rule("Separator", 0.5).Margin(48, 0, 8, 0));
                list.Children.Add(Row(items[i]));
            }
        }
    }

    /// 设备那排：个数跟着项目筛选走
    static List<(string Id, string Title, int Count)> SourceOptions(List<PastItem> all)
    {
        var inProject = all.Where(i => ProjectFilter.Length == 0 || i.Folder == ProjectFilter).ToList();
        return SourceNames.Select(n => (n, n, inProject.Count(i => i.SourceName == n))).ToList();
    }

    /// 项目那排：最近有动静的在前，个数跟着设备筛选走；筛着的项目这会儿一个都没有也列着
    static List<(string Id, string Title, int Count)> ProjectOptions(List<PastItem> all)
    {
        var source = ActiveSource;
        var list = all.Where(i => i.Folder.Length > 0 && (source is null || i.SourceName == source)).OrderByDescending(i => i.LastActive)
            .GroupBy(i => i.Folder).Select(g => (g.Key, g.Key, g.Count())).ToList();
        if (ProjectFilter.Length > 0 && list.All(o => o.Item1 != ProjectFilter)) list.Insert(0, (ProjectFilter, ProjectFilter, 0));
        return list;
    }

    Control FilterRow()
    {
        // 搜着的时候数字是搜到的里面的
        var all = results ?? sessions;
        var baseList = all.Where(InScope).ToList();
        var chips = new List<Control>();
        foreach (var option in StatusOptions)
        {
            var id = option.Id;
            chips.Add(new FilterChip(L(option.Title), baseList.Count(i => Matches(i, id)), option.Dot, StatusFilter == id, () =>
            {
                StatusFilter = StatusFilter == id && id != "all" ? "all" : id;
                Build();
            }));
        }
        var row = new DockPanel();
        // 项目选「全部」时才有「显示方式」（分组）；选了某个项目就按日期排
        if (ProjectFilter.Length == 0)
        {
            var menu = ViewMenu();
            DockPanel.SetDock(menu, Dock.Right);
            menu.Margin = new Thickness(8, 0, 0, 0);
            row.Children.Add(menu);
        }
        row.Children.Add(new FilterBar(chips));
        var stack = Ui.VFill(8, row);
        var projects = ProjectOptions(all);
        var bySource = SourceNames.Count > 1 || ActiveSource is not null;
        // 不止一台设备、不止一个项目时才有（筛着的时候也留着，好点回全部）
        if (bySource)
            stack.Children.Add(ScopeBar.Build("desktopcomputer", L("全部设备"), SourceOptions(all), ActiveSource ?? "", id => { SourceFilter = id; Build(); }));
        if (projects.Count > 1 || ProjectFilter.Length > 0)
            stack.Children.Add(ScopeBar.Build("folder", L("全部项目"), projects, ProjectFilter, SetProject));
        return stack.Margin(20, 0, 20, 6);
    }

    /// 「显示方式」：分组放在一个菜单里，按钮上写着现在怎么分
    Control ViewMenu()
    {
        var isDefault = Grouping == "none";
        var color = isDefault ? "Text2" : "Accent";
        var summary = isDefault ? L("显示方式") : L(GroupOptions.First(o => o.Id == Grouping).Title);
        var menu = new Tap(Ui.H(5, Ui.Sym("line.3.horizontal.decrease", 12, color), Ui.Text(summary, 12, FontWeight.Medium, color), Ui.Sym("chevron.down", 9, color)), null, 15)
        { Height = 30, Padding = new Thickness(11, 0) };
        menu.Keys(isDefault ? "Fill06" : "Tile", "Fill10");
        menu.Tip(L("历史会话的分组方式"));
        menu.Click = () =>
        {
            var flyout = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedRight };
            flyout.Items.Add(new MenuItem { Header = L("分组"), IsEnabled = false });
            foreach (var (id, title) in GroupOptions) flyout.Items.Add(Ui.Item(L(title), () => { Grouping = id; Build(); }, check: Grouping == id ? "" : null));
            if (!isDefault || IsFiltering)
            {
                flyout.Items.Add(new Separator());
                flyout.Items.Add(Ui.Item(L("恢复默认"), () => { Grouping = "none"; ClearFilters(); Build(); }));
            }
            flyout.ShowAt(menu);
        };
        return menu;
    }

    /// 不分组 = 按最后活动的那天；按来源 / 按项目 = 组的先后跟着组里最近的那个会话走，标题带个数
    static List<(string Title, List<PastItem> Items)> Sections(List<PastItem> items)
    {
        var sorted = items.OrderByDescending(i => i.LastActive).ToList();
        var grouping = EffectiveGrouping;
        if (grouping == "none")
            return sorted.GroupBy(i => Format.Date(i.LastActive).Date).OrderByDescending(g => g.Key).Select(g => (DayLabel(g.Key), g.ToList())).ToList();
        var bySource = grouping == "source";
        var multi = sorted.Select(i => i.SourceName).Distinct().Count() > 1;
        var order = new List<string>();
        var map = new Dictionary<string, List<PastItem>>();
        var names = new Dictionary<string, string>();
        foreach (var item in sorted)
        {
            var key = bySource ? item.SourceName : item.SourceName + "\n" + item.Cwd;
            if (!map.ContainsKey(key))
            {
                order.Add(key);
                map[key] = [];
                var project = item.Folder.Length == 0 ? L("（未知目录）") : item.Folder;
                names[key] = bySource ? (item.SourceName.Length == 0 ? L("未知来源") : item.SourceName) : multi && item.SourceName.Length > 0 ? $"{project} · {item.SourceName}" : project;
            }
            map[key].Add(item);
        }
        return order.Select(k => ($"{names[k]}（{map[k].Count}）", map[k])).ToList();
    }

    static string DayLabel(DateTime day)
    {
        var days = (DateTime.Today - day.Date).Days;
        if (days == 0) return L("今天");
        if (days == 1) return L("昨天");
        string[] week = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"];
        return day.Year == DateTime.Today.Year ? L("%@月%@日 %@", day.Month, day.Day, L(week[(int)day.DayOfWeek])) : L("%@年%@月%@日", day.Year, day.Month, day.Day);
    }

    public static void Open(PastItem item, string? hit = null)
    {
        AppModel.Shared.RememberPast(item.Meta);
        if (hit is not null) AppModel.Shared.JumpRequests[item.Key] = hit;
        MainModel.Shared.Selection = item.Key;
    }

    /// 一行（同 Mac 版 PastRow）：头像、标题、机器 · 项目 · 第一句、进行中、时间
    public static Control Row(PastItem item)
    {
        var sub = string.Join(" · ", new[] { item.SourceName, item.Folder, item.Title is not null ? item.FirstPrompt ?? "" : "" }.Where(s => s.Length > 0));
        Control? live = null;
        if (item.Live)
        {
            live = new Border { Padding = new Thickness(6, 2), CornerRadius = new CornerRadius(9), Child = Ui.Text(L("进行中"), 10.5, FontWeight.Medium, "Accent") };
            live.Res(Border.BackgroundProperty, "IconTile");
        }
        var row = Ui.H(10, new SessionAvatar(item.DisplayTitle, item.Live ? "busy" : "unknown", 30),
            Ui.VFill(1, Ui.Text(item.DisplayTitle, 13, FontWeight.SemiBold).Trim(), Ui.Text(sub, 11, color: "Text2").Trim()).Grow(),
            live, Ui.Text(Format.Short(item.LastActive), 10.5, color: "Text3"));
        return new Tap(row.Pad(8, 6), () => Open(item), 8).Keys("Transparent", "Fill05", "Fill08");
    }

    void SearchList(List<PastItem> all)
    {
        var found = Filtered(all);
        if (found.Count == 0 && !spinner.IsVisible)
        {
            if (all.Count == 0) list.Children.Add(Ui.Text(L("未找到「%@」", query), 13, color: "Text2").Margin(8, 16, 0, 0));
            else
                // 搜到了，只是不在筛着的设备、项目、状态里
                list.Children.Add(Ui.H(10, Ui.Text(L("%@中未找到「%@」，其他会话中有 %@ 个", FilterName(), query, all.Count), 13, color: "Text2").Shrink(),
                    new GlassButton(L("在全部会话中搜索"), null, () => { ClearFilters(); Build(); }, height: 24)).Margin(8, 16, 0, 0));
        }
        foreach (var item in found)
        {
            var section = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
            section.Children.Add(Row(item));
            // 因为项目名、标题搜到的（没有正文片段）：说一声是哪样对上的
            var note = item.Hits.Count > 0 ? null
                : item.Match.Contains("project") ? L("项目名称：%@", item.Folder) : item.Match.Contains("title") ? L("标题：%@", item.DisplayTitle) : null;
            if (note is not null) section.Children.Add(Highlighted(note, query).Margin(48, 2, 8, 4));
            foreach (var hit in item.Hits)
            {
                var snippet = Highlighted(hit.Snippet, query);
                var line = Ui.HTop(8, Ui.Text(hit.Who, 11, color: "Text3").Width(44), snippet.Grow(), Ui.Text(Format.Short(hit.Ts), 10.5, color: "Text3"));
                var id = hit.Id;
                section.Children.Add(new Tap(line.Pad(48, 4, 8, 4), () => Open(item, id), 6).Keys("Transparent", "Fill05"));
            }
            list.Children.Add(section);
        }
    }

    /// 搜到的那几个字标出来（淡强调色底、加粗）
    static TextBlock Highlighted(string text, string q)
    {
        var block = new TextBlock { FontSize = Look.Pt(12.5), TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis };
        block.Res(TextBlock.ForegroundProperty, "Text");
        block.Inlines = [];
        var at = q.Trim().Length > 0 ? text.IndexOf(q.Trim(), StringComparison.OrdinalIgnoreCase) : -1;
        if (at < 0) { block.Inlines.Add(new Run(text)); return block; }
        block.Inlines.Add(new Run(text[..at]));
        var mark = new Run(text.Substring(at, q.Trim().Length)) { FontWeight = FontWeight.SemiBold };
        mark.Bind(Run.BackgroundProperty, mark.GetResourceObservable("AccentFill20"));
        block.Inlines.Add(mark);
        block.Inlines.Add(new Run(text[(at + q.Trim().Length)..]));
        return block;
    }
}
