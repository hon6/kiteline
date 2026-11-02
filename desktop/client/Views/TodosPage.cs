using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 主窗口右侧的「待办」（同 Mac 版 TarsTodosView → TodosView）：最上面是 agent 提醒你做、还没决定的事（现在处理 / 加入待办）；
/// 「我的待办」按出自哪条消息分组，组头就是来源，点一下跳回那条消息，做完点左边的圈打勾；
/// 「agent 的待办」是它自己会做的，只看是哪个会话在处理、到哪一步了
public sealed class TodosPage : Panel
{
    readonly StackPanel list = new() { Margin = new Thickness(16, 8, 16, 24) };
    readonly ContentControl empty = new();

    static bool ShowDone { get => Prefs.Bool("todosShowDone"); set => Prefs.Set("todosShowDone", value); }
    /// agent 的待办怎么分组、排序、只看哪台机器（同侧栏会话的「显示方式」）；分组没选过就跟侧栏一样
    /// 不认识的值（老版本、别处写坏的）都按默认处理
    static string Grouping
    {
        get { var g = Prefs.String("todosGrouping") ?? MainModel.Shared.Grouping; return GroupOptions.Any(o => o.Id == g) ? g : "none"; }
        set => Prefs.Set("todosGrouping", value);
    }
    static string Sorting
    {
        get { var s = Prefs.String("todosSorting") ?? ""; return SortOptions.Any(o => o.Id == s) ? s : "status"; }
        set => Prefs.Set("todosSorting", value);
    }
    static string SourceFilter { get => Prefs.String("todosSource") ?? ""; set => Prefs.Set("todosSource", value); }

    public TodosPage()
    {
        var bar = new PageBar(L("待办"), null, null, [PageBar.Button("plus", L("新建待办"), () => TodoEditor.Open(TodoEditor.Target.New()))]);
        var scroll = new ScrollViewer { Content = list, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Children.Add(PageBar.Page(bar, new Panel { Children = { scroll, empty } }));
        var state = TodoState.Shared;
        void Changed(object? s, PropertyChangedEventArgs e) => Rebuild();
        AttachedToVisualTree += (_, _) => { state.PropertyChanged += Changed; Rebuild(); _ = state.Refresh(); };
        DetachedFromVisualTree += (_, _) => state.PropertyChanged -= Changed;
        Rebuild();
    }

    void Rebuild()
    {
        var state = TodoState.Shared;
        list.Children.Clear();
        // 我的待办（只有你能做的、你自己记的）和 agent 的待办（它自己会做，你只看进度）分开两块
        var pending = state.Items.Where(i => !i.Done && !i.AgentTask).ToList();
        var agentAll = state.Items.Where(i => !i.Done && i.AgentTask).ToList();
        var agentTasks = SortAgentTasks(agentAll.Where(i => ActiveSource is not { } only || TodoState.Place(i).SourceId == only.Id)).ToList();
        var done = state.Items.Where(i => i.Done).OrderByDescending(i => i.DoneAt ?? 0).ToList();
        empty.Content = state.Items.Count == 0 && state.Suggestions.Count == 0
            ? EmptyHint.Make("checklist", L("暂无待办"), L("编程 agent 遇到只有你能做的事（如注册账号、申请密钥）时会提醒你，可以现在处理或加入待办；它自己以后要做的事会记在「agent 的待办」中。右键任意消息也可手动加入。")).VAlign(VerticalAlignment.Center)
            : null;
        if (state.Suggestions.Count > 0)
        {
            Control? dismissAll = state.Suggestions.Count > 1
                ? new Tap(Ui.H(5, Ui.Sym("xmark", 11, "Text"), Ui.Text(L("全部忽略"), 13, FontWeight.SemiBold)).Pad(14, 0), state.DismissAll, 16)
                    { Height = 32, BorderThickness = new Thickness(0.5) }.Keys("Fill10", "Fill15").Res(Border.BorderBrushProperty, "Fill12")
                : null;
            Section(Ui.H(8, SectionTitle(L("需要你处理")).Shrink(), new Spacer(), dismissAll),
                state.Suggestions.OrderByDescending(s => s.At).Select(SuggestionRow));
        }
        if (pending.Count > 0 && (agentAll.Count > 0 || state.Suggestions.Count > 0)) Section(SectionTitle(L("我的待办")), []);
        foreach (var group in Groups(pending))
            Section(GroupHeader(group.Source), group.Items.Select(i => Row(i, false)));
        if (agentAll.Count > 0)
        {
            var header = Ui.H(8, SectionTitle(L("agent 的待办 · 它会自己处理")).Shrink(), new Spacer(),
                agentAll.Count > 1 || !IsDefaultView ? ViewMenu(agentAll) : null);
            var groups = AgentGroups(agentTasks, agentAll);
            if (groups.Count == 1 && groups[0].Name is null)
                Section(header, agentTasks.Count > 0 ? agentTasks.Select(AgentRow) : [FilteredOut()]);
            else
            {
                Section(header, []);
                foreach (var group in groups) Section(AgentGroupHeader(group), group.Items.Select(AgentRow));
            }
        }
        if (done.Count > 0)
        {
            var toggle = new Tap(Ui.H(4, Ui.Text(L("已完成 %@", done.Count), 12, FontWeight.Medium, "Text2"),
                Ui.Sym(ShowDone ? "chevron.down" : "chevron.right", 10, "Text2")), () => { ShowDone = !ShowDone; Rebuild(); }, 4).Keys("Transparent", "Fill05");
            var clear = ShowDone ? new Tap(Ui.Text(L("清空"), 12, FontWeight.Medium, "Text2").Pad(4, 2), ConfirmClear, 4).Keys("Transparent", "Fill05") : null;
            Section(Ui.H(8, toggle, new Spacer(), clear), ShowDone ? done.Select(i => Row(i, true)) : []);
        }
    }

    // MARK: agent 的待办：分组、排序（同侧栏会话的「显示方式」）

    static readonly (string Id, string Title)[] GroupOptions = [("none", "不分组"), ("source", "按来源"), ("project", "按项目"), ("agent", "按 Agent")];
    static readonly (string Id, string Title)[] SortOptions = [("status", "状态优先"), ("recent", "最近更新"), ("started", "记录时间"), ("name", "名称")];

    /// 筛着的那台机器（机器已经不在了就当没筛）
    static SourceInfo? ActiveSource => SourceFilter.Length == 0 ? null : AppModel.Shared.Sources.FirstOrDefault(s => s.Id == SourceFilter);
    static bool IsDefaultView => Grouping == "none" && Sorting == "status" && ActiveSource is null;

    /// 状态优先：在做的在前，没人做了的（会话已结束）垫底；最近更新 / 记录时间：新的在上；名称：按标题。最后按 id 定死先后
    static IEnumerable<TodoItem> SortAgentTasks(IEnumerable<TodoItem> items) => Sorting switch
    {
        "recent" => items.OrderByDescending(i => i.UpdatedAt ?? i.CreatedAt).ThenBy(i => i.Id, StringComparer.Ordinal),
        "started" => items.OrderByDescending(i => i.CreatedAt).ThenBy(i => i.Id, StringComparer.Ordinal),
        "name" => items.OrderBy(i => i.Text, StringComparer.CurrentCultureIgnoreCase).ThenBy(i => i.Id, StringComparer.Ordinal),
        _ => items.OrderBy(i => Orphaned(i) ? 2 : i.Status == "doing" ? 0 : 1).ThenByDescending(i => i.UpdatedAt ?? i.CreatedAt).ThenBy(i => i.Id, StringComparer.Ordinal),
    };

    /// 按项目分组、待办来自不止一台机器时 Sub 写哪台；按 Agent 时 Agent 画它的标志，按来源 / 按项目画电脑 / 文件夹
    sealed record AgentGroup(string Key, string? Name, string? Sub, string? Agent, string? Symbol, List<TodoItem> Items);

    /// 组的先后跟着组里最靠前的那条走（同侧栏）；按来源时照来源列表的顺序，按名称排时组也按名称排
    static List<AgentGroup> AgentGroups(List<TodoItem> items, List<TodoItem> all)
    {
        if (Grouping == "none" || items.Count == 0) return [new AgentGroup("all", null, null, null, null, items)];
        var bySource = Grouping == "source";
        var byAgent = Grouping == "agent";
        var multi = all.Select(i => TodoState.Place(i).SourceId).Distinct().Count() > 1;
        var order = new List<string>();
        var map = new Dictionary<string, AgentGroup>();
        foreach (var item in items)
        {
            var place = TodoState.Place(item);
            var key = byAgent ? place.Agent ?? "" : bySource ? place.SourceId : place.SourceId + "\n" + place.Cwd;
            if (!map.ContainsKey(key))
            {
                order.Add(key);
                var machine = place.Machine ?? L("未知来源");
                var folder = System.IO.Path.GetFileName((place.Cwd ?? "").TrimEnd('/', '\\'));
                map[key] = byAgent
                    ? new AgentGroup(key, place.Agent is { } a ? Agents.Info(a).Name : L("未知 Agent"), null, place.Agent, place.Agent is null ? "questionmark.circle" : null, [])
                    : bySource
                        ? new AgentGroup(key, machine, null, null, "desktopcomputer", [])
                        : new AgentGroup(key, folder.Length == 0 ? L("（未知目录）") : folder, multi ? machine : null, null, "folder", []);
            }
            map[key].Items.Add(item);
        }
        var result = order.Select(k => map[k]).ToList();
        if (bySource)
        {
            var ids = AppModel.Shared.Sources.Select(s => s.Id).ToList();
            result = result.OrderBy(g => ids.IndexOf(g.Key) is var i && i >= 0 ? i : ids.Count).ToList();
        }
        else if (Sorting == "name") result = result.OrderBy(g => g.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        return result;
    }

    static Control AgentGroupHeader(AgentGroup group) => Ui.H(6,
        group.Agent is { } agent ? new AgentGlyph(agent, 12, "Text2") : group.Symbol is { } symbol ? Ui.Sym(symbol, 11, "Text2") : null,
        Ui.Text(group.Name ?? "", 12, FontWeight.SemiBold, "Text2").Trim().Shrink(),
        group.Sub is null ? null : Ui.Text(group.Sub, 11, FontWeight.SemiBold, "Text3"),
        new Spacer(4),
        Ui.Text(group.Items.Count.ToString(), 11, FontWeight.SemiBold, "Text3").Digits());

    /// 筛着的机器上一条都没有：说清楚，给个「显示全部」
    Control FilteredOut() => Ui.H(8,
        Ui.Text(L("%@上没有 agent 的待办", ActiveSource?.Name ?? ""), 12, color: "Text2").Trim().Shrink(), new Spacer(),
        new GlassButton(L("显示全部"), null, () => { SourceFilter = ""; Rebuild(); }, height: 24)).Pad(12, 9);

    /// 「显示方式」：分组、排序、机器放在一个菜单里（同侧栏）；按钮上写着现在怎么分、怎么排，改过默认的用强调色
    Control ViewMenu(List<TodoItem> all)
    {
        var parts = new List<string>();
        if (Grouping != "none") parts.Add(L(GroupOptions.FirstOrDefault(o => o.Id == Grouping).Title ?? ""));
        if (Sorting != "status") parts.Add(L(SortOptions.FirstOrDefault(o => o.Id == Sorting).Title ?? ""));
        if (ActiveSource is { } only) parts.Add(only.Name);
        var summary = parts.Count == 0 ? L("显示方式") : string.Join(" · ", parts);
        var color = IsDefaultView ? "Text2" : "Accent";
        var button = new Tap(Ui.H(5, Ui.Sym("line.3.horizontal.decrease", 12, color), Ui.Text(summary, 12, FontWeight.Medium, color), Ui.Sym("chevron.down", 9, color)), null, 15)
        { Height = 30, Padding = new Thickness(11, 0) };
        button.Keys(IsDefaultView ? "Fill06" : "Tile", "Fill10");
        button.Tip(L("agent 待办的分组、排序与机器筛选"));
        void Set(Action change) { change(); Rebuild(); }
        button.Click = () =>
        {
            var model = AppModel.Shared;
            var menu = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedRight };
            menu.Items.Add(new MenuItem { Header = L("分组"), IsEnabled = false });
            foreach (var (id, title) in GroupOptions) menu.Items.Add(Ui.Item(L(title), () => Set(() => Grouping = id), check: Grouping == id ? "" : null));
            menu.Items.Add(new Separator());
            menu.Items.Add(new MenuItem { Header = L("排序"), IsEnabled = false });
            foreach (var (id, title) in SortOptions) menu.Items.Add(Ui.Item(L(title), () => Set(() => Sorting = id), check: Sorting == id ? "" : null));
            if (model.Sources.Count > 1)
            {
                menu.Items.Add(new Separator());
                menu.Items.Add(new MenuItem { Header = L("机器"), IsEnabled = false });
                menu.Items.Add(Ui.Item(L("全部机器"), () => Set(() => SourceFilter = ""), check: ActiveSource is null ? "" : null));
                foreach (var source in model.Sources)
                {
                    var id = source.Id;
                    menu.Items.Add(Ui.Item($"{source.Name}（{all.Count(i => TodoState.Place(i).SourceId == id)}）", () => Set(() => SourceFilter = id),
                        check: ActiveSource?.Id == id ? "" : null));
                }
            }
            if (!IsDefaultView)
            {
                menu.Items.Add(new Separator());
                menu.Items.Add(Ui.Item(L("恢复默认"), () => Set(() => { Grouping = "none"; Sorting = "status"; SourceFilter = ""; })));
            }
            menu.ShowAt(button);
        };
        return button;
    }

    async void ConfirmClear()
    {
        if (await Dialogs.Confirm(L("删除所有已完成的待办？"), L("清空已完成"), destructive: true)) TodoState.Shared.ClearDone();
    }

    /// 一节：组头 + 一张卡片里的几行（同 Mac 的 inset List：行之间细线）
    void Section(Control header, IEnumerable<Control> rows)
    {
        var items = rows.ToList();
        list.Children.Add(header.Margin(4, list.Children.Count == 0 ? 6 : 18, 4, 6));
        if (items.Count == 0) return;
        var stack = new StackPanel();
        for (var i = 0; i < items.Count; i++)
        {
            stack.Children.Add(items[i]);
            if (i < items.Count - 1) stack.Children.Add(Ui.Rule("Separator", 0.5).Margin(46, 0, 0, 0));
        }
        list.Children.Add(Card.Make(stack, 0, 12));
    }

    static TextBlock SectionTitle(string text) => Ui.Text(text, 12, FontWeight.Medium, "Text2").Trim();

    sealed record Group(string Id, TodoSource? Source, List<TodoItem> Items, double Latest);

    /// 同一条消息里的放一组（组里按加进来的先后）；组按最近加的在上；自己记的单独一组
    static List<Group> Groups(IEnumerable<TodoItem> items)
    {
        var map = new Dictionary<string, Group>();
        var order = new List<string>();
        foreach (var item in items.OrderBy(i => i.CreatedAt))
        {
            var id = item.Source is { } s ? $"{s.Key}|{s.ItemId}" : "manual";
            if (!map.TryGetValue(id, out var group)) { order.Add(id); group = map[id] = new Group(id, item.Source, [], 0); }
            group.Items.Add(item);
            if (item.CreatedAt > group.Latest) map[id] = group with { Latest = item.CreatedAt };
        }
        return order.Select(id => map[id]).OrderByDescending(g => g.Latest).ToList();
    }

    static Control GroupHeader(TodoSource? source)
    {
        if (source is null) return SectionTitle(L("手动添加"));
        var time = source.Ts is double ts ? Format.ListTime(ts) : "";
        var row = Ui.H(6, Ui.Sym("bubble.left", 11, "Text2"), Ui.Text(source.Title, 12, FontWeight.Medium, "Text2").Trim().Shrink(),
            time.Length > 0 ? Ui.Text("· " + time, 12, FontWeight.Medium, "Text2") : null, new Spacer(4),
            Ui.Text(L("原消息"), 12, FontWeight.Medium, "Accent"), Ui.Sym("chevron.right", 10, "Accent"));
        return new Tap(row, () => TodoState.OpenSource(source.Key, source.ItemId), 4).Keys("Transparent", "Transparent").Tip(L("打开该会话并定位到原消息"));
    }

    static string SourceLine(TodoSource source) =>
        string.Join(" · ", new[] { source.Title, source.Ts is double ts ? Format.ListTime(ts) : "" }.Where(s => s.Length > 0));

    /// 一条待办：左边的圈打勾；右边内容（截图 + 文字）；点内容跳回原消息（自己记的就改字）
    static Control Row(TodoItem item, bool showSource)
    {
        var state = TodoState.Shared;
        var check = new Tap(Ui.Sym(item.Done ? "checkmark.circle.fill" : "circle", 21, item.Done ? "WechatGreen" : "Text2"),
            () => state.SetDone(item, !item.Done), 13) { Width = 26, Height = 26 }.Keys("Transparent", "Transparent");
        check.Tip(item.Done ? L("标为未完成") : L("标为已完成"));
        var content = new StackPanel { Spacing = 3, Margin = new Thickness(0, 2, 0, 0) };
        content.Children.Add(TodoContent.Make(item));
        if (!string.IsNullOrEmpty(item.Detail) && !item.Done)
        {
            var detail = Ui.Text(item.Detail, 12, color: "Text2", lines: 3).Wrap();
            detail.MaxLines = 3;
            detail.TextTrimming = Avalonia.Media.TextTrimming.CharacterEllipsis;
            content.Children.Add(detail);
        }
        if (showSource && item.Source is { } source)
            content.Children.Add(Ui.H(5, Ui.Sym("arrowshape.turn.up.backward", 10.5, "Text3"), Ui.Text(SourceLine(source), 11.5, color: "Text3").Trim().Shrink()));
        if (item.Source is { } from && !item.Done && !item.AgentTask)
        {
            // 回到会话：打开原会话、输入框里先写好「已处理好：…」，确认后发给 agent（点整行只是跳到原消息）
            var reply = new Tap(Ui.H(6, Ui.Sym("arrowshape.turn.up.backward", 12, "Accent"), Ui.Text(L("回到会话"), 12, FontWeight.Medium, "Accent")).Pad(11, 4),
                () => TodoState.ReplyDone(from.Key, item.Text), 12).Keys("AccentFill14", "AccentFill20");
            reply.HorizontalAlignment = HorizontalAlignment.Left;
            reply.Margin = new Thickness(0, 4, 0, 0);
            content.Children.Add(reply);
        }
        var body = new Tap(content, () => Tap(item), 6).Keys("Transparent", "Transparent");
        body.Cursor = Cursor.Default;
        var row = Ui.HTop(10, check, body.Grow()).Pad(12, 9);
        row.Background = Brushes.Transparent;
        row.Menu(() => Menu(item));
        return row;
    }

    static void Tap(TodoItem item)
    {
        if (item.Source is { } s) TodoState.OpenSource(s.Key, s.ItemId); else TodoEditor.Open(TodoEditor.Target.Edit(item));
    }

    /// agent 的待办没人在做了：在处理它（没人接手就是记下它）的会话已经结束。连着电脑、那台机器在线才判断（同 iPhone / Mac 版 todoOrphaned）
    static bool Orphaned(TodoItem item)
    {
        var model = AppModel.Shared;
        if (!model.Connected || !item.AgentTask || item.Done || (item.Handler?.Key ?? item.Source?.Key) is not string key) return false;
        var hash = key.IndexOf('#');
        if (hash < 0 || model.Sources.FirstOrDefault(s => s.Id == key[..hash])?.Online != true) return false;
        return model.Session(key) is null;
    }

    /// agent 的待办：状态、进度、哪个会话在处理；点一下打开那个会话（你不用勾，agent 做完自己标）。
    /// 那个会话已经结束的标出来：没人在做了，做完了右键标为已完成，没做完右键「创建会话」接着做
    static Control AgentRow(TodoItem item)
    {
        var orphaned = Orphaned(item);
        var doing = item.Status == "doing" && !orphaned;
        var icon = Ui.Sym(doing ? "arrow.triangle.2.circlepath" : "circle.dashed", 17, doing ? "Accent" : "Text2");
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        var iconBox = new Border { Width = 26, Height = 26, Child = icon };
        var content = new StackPanel { Spacing = 3, Margin = new Thickness(0, 2, 0, 0) };
        content.Children.Add(Ui.Text(item.Text, 14, lines: 0).Wrap());
        var note = !string.IsNullOrEmpty(item.Progress) ? item.Progress : item.Detail;
        if (!string.IsNullOrEmpty(note))
        {
            var text = Ui.Text(note, 12, color: "Text2", lines: 3).Wrap();
            text.MaxLines = string.IsNullOrEmpty(item.Progress) ? 2 : 3;
            text.TextTrimming = TextTrimming.CharacterEllipsis;
            content.Children.Add(text);
        }
        var where = item.Handler?.Title ?? item.Source?.Title;
        content.Children.Add(Ui.H(4, Ui.Text(orphaned ? L("会话已结束") : doing ? L("进行中") : L("待处理"), 11.5, color: orphaned ? "Orange" : doing ? "Accent" : "Text3"),
            where is null ? null : Ui.Text("· " + L("「%@」", where), 11.5, color: "Text3").Trim().Shrink(),
            Ui.Text("· " + Format.ListTime(item.UpdatedAt ?? item.CreatedAt), 11.5, color: "Text3")));
        var row = new Tap(Ui.HTop(10, iconBox, content.Grow()).Pad(12, 9), () =>
        {
            if ((item.Handler?.Key ?? item.Source?.Key) is string key) MainModel.Shared.Selection = key;
        }, 6).Keys("Transparent", "Fill05");
        row.Menu(() => Menu(item));
        return row;
    }

    static IEnumerable<Control> Menu(TodoItem item)
    {
        var state = TodoState.Shared;
        if (item.Handler is { } h && item.AgentTask) yield return Ui.Item(L("打开处理它的会话"), () => MainModel.Shared.Selection = h.Key);
        if (item.Source is { } s)
        {
            if (!item.AgentTask && !item.Done) yield return Ui.Item(L("回到会话"), () => TodoState.ReplyDone(s.Key, item.Text));
            yield return Ui.Item(L("跳转到原消息"), () => TodoState.OpenSource(s.Key, s.ItemId));
        }
        // agent 的待办也能替它勾掉（它忘了关、或者你知道已经做完了；agent 那边 todo list 也会看到已完成）
        yield return Ui.Item(item.Done ? L("标为未完成") : L("标为已完成"), () => state.SetDone(item, !item.Done));
        if (item.SuggestsSession) yield return Ui.Item(L("创建会话"), () => TodoState.CreateSession(item));
        yield return Ui.Item(L("修改"), () => TodoEditor.Open(TodoEditor.Target.Edit(item)));
        yield return Ui.Item(L("复制"), () => _ = MainWindow.Current?.Clipboard?.SetTextAsync(item.Text));
        yield return Ui.Divider();
        yield return Ui.Item(L("删除"), () => state.Delete([item.Id]));
    }

    /// agent 提醒你做的事：来源（点了跳过去）、要做的事和说明、「加入待办」「现在处理」
    static Control SuggestionRow(TodoSuggestion s)
    {
        var head = new Tap(Ui.H(6, Ui.Text(s.Title, 13, FontWeight.SemiBold).Trim().Shrink(), new Spacer(4),
            Ui.Text(Format.ListTime(s.Ts ?? s.At), 11.5, color: "Text3"), Ui.Sym("chevron.right", 10, "Text3")),
            () => TodoState.OpenSource(s.Key, s.ItemId), 4).Keys("Transparent", "Transparent");
        var asks = new StackPanel { Spacing = 4 };
        foreach (var ask in s.Asks.Take(4))
            asks.Children.Add(Ui.HTop(6, Ui.Text("·", 12, color: "Text2"), Ui.Text(ask, 12, color: "Text2", lines: 2).Wrap().Shrink()));
        if (s.Asks.Count > 4) asks.Children.Add(Ui.Text(L("另有 %@ 项", s.Asks.Count - 4), 12, color: "Text3"));
        if (!string.IsNullOrEmpty(s.Detail))
        {
            var detail = Ui.Text(s.Detail, 12, color: "Text3", lines: 4).Wrap();
            detail.MaxLines = 4;
            detail.TextTrimming = TextTrimming.CharacterEllipsis;
            asks.Children.Add(detail);
        }
        var add = new Tap(Ui.Text(L("加入待办"), 13, FontWeight.SemiBold, "White").Pad(14, 0), () =>
        {
            if (s.Asks.Count == 1) _ = TodoState.Shared.AddSuggestion(s);
            else AddTodosDialog.Open(new AddTodosRequest(s.Key, s.ItemId, s.Title, s.Ts, s.Asks));
        }, 15) { Height = 30 }.Keys("WechatGreen", "GreenHover", "GreenPressed");
        var now = new Tap(Ui.Text(L("现在处理"), 13, FontWeight.Medium, "Accent").Pad(4, 4), () => TodoState.Shared.HandleNow(s.Key, s.ItemId), 4).Keys("Transparent", "Fill05");
        return new StackPanel { Spacing = 8, Children = { head, asks, Ui.H(14, add, now) } }.Pad(12, 12);
    }
}

/// 一条待办的内容：一张截图时左边正方形缩略图、右边文字；两张以上九宫格在上、文字在下。点图看大图
public static class TodoContent
{
    public static Control Make(TodoItem item)
    {
        var text = Ui.Text(item.Text, 14, color: item.Done ? "Text2" : "Text", lines: 0).Wrap();
        if (item.Done) text.TextDecorations = Avalonia.Media.TextDecorations.Strikethrough;
        if (item.Images.Count == 0) return text;
        if (item.Images.Count == 1) return Ui.HTop(10, Thumb(item, 0, 72), text.Shrink());
        var grid = new Avalonia.Controls.Primitives.UniformGrid { Columns = 3, MaxWidth = 300, HorizontalAlignment = HorizontalAlignment.Left };
        for (var i = 0; i < item.Images.Count; i++) grid.Children.Add(Thumb(item, i, double.NaN).Margin(0, 0, 4, 4));
        return new StackPanel { Spacing = 8, Children = { grid, text } };
    }

    /// 正方形缩略图：图盖在底色块上填满再裁掉（宽图、长图都是正方形）
    static Control Thumb(TodoItem item, int index, double size)
    {
        var image = new Image { Stretch = Stretch.UniformToFill };
        var box = new Border { CornerRadius = new CornerRadius(6), ClipToBounds = true, Child = image, Opacity = item.Done ? 0.55 : 1 }.Res(Border.BackgroundProperty, "Fill06");
        if (!double.IsNaN(size)) { box.Width = size; box.Height = size; }
        else box.SizeChanged += (_, e) => { if (Math.Abs(box.Height - e.NewSize.Width) > 0.5) box.Height = e.NewSize.Width; };
        var query = TodoItem.MediaQuery(item.Images[index].Ref);
        query["thumb"] = "200";
        ImageCache.Load(TodoItem.MediaPath, query, b => image.Source = b);
        box.Cursor = new Cursor(StandardCursorType.Hand);
        box.PointerReleased += (_, e) => { if (e.InitialPressMouseButton == MouseButton.Left) { ImageViewer.Show("todos", item.Images, index, TodoItem.MediaPath); e.Handled = true; } };
        return box;
    }
}

/// 弹出的小窗（同 Mac 的面板）：面板底色（比里面的输入框、列表亮一档，同 Mac）、打开时宽度固定、高度随内容，Esc 关掉。
/// 顶上统一的标题栏（标题、最大化、关闭，见 TitleBar）；按住空白处能拖走，拖边角能改大小；在会话里弹的对着那一块会话正中打开（见 Place）
public static class Dialog
{
    /// titleBar：false = 内容自己画了标题栏和窗口按钮（代码窗口）
    public static Window Make(Control content, double width, string title = "Kiteline", bool titleBar = true)
    {
        var window = new Window
        {
            Title = title, Width = width, SizeToContent = SizeToContent.Height, CanResize = true, ShowInTaskbar = false,
            MinWidth = Math.Min(width, 360), MinHeight = 120,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = Look.Family,
        };
        // 浮动提示（「未能识别」之类）在弹窗里也显示
        window.Content = new Panel { Children = { titleBar ? WithTitleBar(window, content) : content, new ToastLayer(24) } };
        window.Res(Window.BackgroundProperty, "Sheet");
        Chromeless(window, titleBar);
        return window;
    }

    /// 标题栏的高度（Windows 上系统的最大化、关闭按钮画在这一条里）
    public const double TitleHeight = 40;

    /// 弹窗统一的标题栏（11-02 反馈：软件内的弹窗要统一，有标题栏、全屏、关闭）：左边标题（跟着窗口标题变），
    /// 右边最大化（铺满屏幕，再点还原）、关闭。Windows 用系统画的按钮（Chromeless 给它留出这一条），Linux 用自己画的（按 GNOME 设置放左边或右边）。
    /// 按住拖动窗口，双击最大化 / 还原。挂在主窗口上的弹窗收不进任务栏，不要最小化
    public static Control TitleBar(Window window)
    {
        window.CanMinimize = false;
        var title = Ui.Text(window.Title, 13, FontWeight.SemiBold).Trim();
        title.IsHitTestVisible = false;   // 按在标题上也算按在标题栏上（拖动、双击）
        window.PropertyChanged += (_, e) => { if (e.Property == Window.TitleProperty) title.Text = window.Title; };
        var row = Ui.H(8, title.Shrink(), new Spacer());
        var left = 16.0;
        if (WindowChrome.Custom)
        {
            var buttons = new CaptionButtons(window, WindowChrome.Buttons.Where(b => b != "minimize"));
            if (WindowChrome.ButtonsLeft) { row.Children.Insert(0, buttons); left = 0; } else row.Children.Add(buttons);
        }
        var bar = new Border
        {
            Child = row, Height = TitleHeight, Background = Brushes.Transparent,
            Padding = new Thickness(left, 0, OperatingSystem.IsWindows() ? WindowChrome.CaptionWidth : 0, 0),
        };
        bar.PointerPressed += (sender, e) => { WindowChrome.DragWindow(sender, e); if (ReferenceEquals(e.Source, sender)) e.Handled = true; };
        return bar;
    }

    /// 内容上面加统一的标题栏
    public static Control WithTitleBar(Window window, Control content)
    {
        var bar = TitleBar(window);
        var dock = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        dock.Children.Add(bar);
        dock.Children.Add(content);
        return dock;
    }

    /// 在会话里弹的窗对着它居中：最近一次在哪一块会话里按下（主窗口别处按下就清掉，弹窗对着整个窗口居中）
    public static Control? Anchor
    {
        get => anchor is not null && anchor.TryGetTarget(out var c) ? c : null;
        set => anchor = value is null ? null : new WeakReference<Control>(value);
    }
    static WeakReference<Control>? anchor;

    /// 打开的位置：在会话里弹的对着那一块会话正中（水平、垂直都居中），别的对着所在窗口正中；不超出屏幕。
    /// 打开前按估的大小摆一次，打开后按实际大小再摆一次
    public static void Place(Window window, Window? owner)
    {
        if (owner is null) return;
        Control target = Anchor is { } a && TopLevel.GetTopLevel(a) == owner && a.IsEffectivelyVisible && a.Bounds.Width > 0 ? a : owner;
        var topLeft = target.PointToScreen(new Point(0, 0));
        var bottomRight = target.PointToScreen(new Point(target.Bounds.Width, target.Bounds.Height));
        var center = new PixelPoint((topLeft.X + bottomRight.X) / 2, (topLeft.Y + bottomRight.Y) / 2);
        var scale = owner.DesktopScaling;
        var size = EstimatedSize(window);
        int w = (int)(size.Width * scale), h = (int)(size.Height * scale);
        int x = center.X - w / 2, y = center.Y - h / 2;
        if (owner.Screens.ScreenFromPoint(center)?.WorkingArea is { } area)
        {
            x = Math.Clamp(x, area.X, Math.Max(area.X, area.Right - w));
            y = Math.Clamp(y, area.Y, Math.Max(area.Y, area.Bottom - h));
        }
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Position = new PixelPoint(x, y);
    }

    /// 打开后的实际大小（含标题栏）；没打开的按宽度量一下内容有多高
    static Size EstimatedSize(Window window)
    {
        if (window.IsVisible) return window.FrameSize ?? window.ClientSize;
        var width = double.IsNaN(window.Width) ? 560 : window.Width;
        var height = window.Height;
        if (double.IsNaN(height) || window.SizeToContent.HasFlag(SizeToContent.Height))
        {
            if (window.Content is Control content)
            {
                content.Measure(new Size(width, double.PositiveInfinity));
                height = content.DesiredSize.Height;
            }
            if (double.IsNaN(height) || height <= 0) height = 400;
        }
        return new Size(width, height);
    }

    /// 打开：先摆好位置，打开后按实际大小再摆一次
    public static void ShowPlaced(Window window, Window? owner, bool modal = false)
    {
        Place(window, owner);
        window.Opened += (_, _) => Place(window, owner);
        if (owner is null) window.Show();
        else if (modal) window.ShowDialog(owner);
        else window.Show(owner);
    }

    /// 不要系统标题栏（同 Mac 的面板：没有标题、最小化 / 最大化；弹窗内容里自己有标题），按住空白处拖动。
    /// Windows：系统照样给圆角和阴影；客户区铺满整个窗口后系统的拖边没了，四周往里 5 点自己接（同主窗口）。
    /// Linux：同主窗口自己画圆角、阴影和一圈细边（GNOME 的标题栏会把「新任务」再写一遍）
    /// titleBar：内容顶上有统一的标题栏（TitleBar）——Windows 上让系统在那一条里画最大化、关闭按钮（同代码窗口）
    public static void Chromeless(Window window, bool titleBar = false)
    {
        if (OperatingSystem.IsWindows())
        {
            window.ExtendClientAreaToDecorationsHint = true;
            window.ExtendClientAreaChromeHints = titleBar ? Avalonia.Platform.ExtendClientAreaChromeHints.PreferSystemChrome
                                                           : Avalonia.Platform.ExtendClientAreaChromeHints.NoChrome;
            window.ExtendClientAreaTitleBarHeightHint = titleBar ? TitleHeight : -1;
            ResizeGrips(window, 5);
        }
        else if (WindowChrome.Custom) LinuxFrame(window);
        else return;
        window.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(window).Properties.IsLeftButtonPressed && e.Source is not TextBox) window.BeginMoveDrag(e);
        };
    }

    const double FrameRadius = 12;

    /// Linux 弹窗的外框：四周留出阴影，内容放进圆角的面板里。有的弹窗先调这里、后设内容，内容一换就重新套上
    static void LinuxFrame(Window window)
    {
        window.SystemDecorations = SystemDecorations.None;
        window.TransparencyLevelHint = [WindowTransparencyLevel.Transparent];
        window.Background = Brushes.Transparent;
        if (!double.IsNaN(window.Width)) window.Width += WindowChrome.ShadowMargin * 2;
        window.MinWidth += WindowChrome.ShadowMargin * 2;
        window.MinHeight += WindowChrome.ShadowMargin * 2;
        ResizeGrips(window, WindowChrome.ShadowMargin + 4);
        Border? shadow = null, frame = null, edge = null;
        // 正常大小时四周留阴影、圆角；最大化时铺满、直角（能最大化的弹窗，比如代码窗口）
        void Fit()
        {
            if (shadow is null || frame is null || edge is null) return;
            var normal = window.WindowState == WindowState.Normal;
            var margin = normal ? new Thickness(WindowChrome.ShadowMargin) : default;
            var radius = new CornerRadius(normal ? FrameRadius : 0);
            foreach (var b in new[] { shadow, frame, edge }) { b.Margin = margin; b.CornerRadius = radius; }
            edge.IsVisible = normal;
            frame.Clip = new RectangleGeometry(new Rect(frame.Bounds.Size), radius.TopLeft, radius.TopLeft);
        }
        var wrapping = false;
        void Wrap()
        {
            if (wrapping || window.Content is not Control inner || inner.Tag as string == "kl-frame") return;
            wrapping = true;
            window.Content = null;
            // 阴影单独一层（同主窗口：同一元素上的阴影会吞掉后画的内容），要有实底才画得出来
            shadow = new Border
            {
                IsHitTestVisible = false,
                BoxShadow = new BoxShadows(new BoxShadow { OffsetY = 6, Blur = 26, Color = Palette.Color(0, 0.45) },
                                           [new BoxShadow { Blur = 2, Spread = 0.5, Color = Palette.Color(0, 0.18) }]),
            }.Res(Border.BackgroundProperty, "Sheet");
            frame = new Border { Child = inner }.Res(Border.BackgroundProperty, "Sheet");
            frame.SizeChanged += (_, _) => Fit();
            edge = new Border { BorderThickness = new Thickness(1), IsHitTestVisible = false }.Res(Border.BorderBrushProperty, "WindowEdge");
            Fit();
            window.Content = new Panel { Tag = "kl-frame", Children = { shadow, frame, edge } };
            wrapping = false;
        }
        window.PropertyChanged += (_, e) =>
        {
            if (e.Property == ContentControl.ContentProperty) Wrap();
            else if (e.Property == Window.WindowStateProperty) Fit();
        };
        Wrap();
    }

    /// 弹窗没有系统的拖边：离窗口边 grip 点以内（Linux 是阴影那一圈再往里 4 点）按下就拖边改大小，鼠标指上去换成拖边的样子（同主窗口）
    static void ResizeGrips(Window window, double grip)
    {
        WindowEdge? At(Point p)
        {
            if (!window.CanResize || window.WindowState != WindowState.Normal) return null;
            var corner = grip + 10;
            double w = window.Bounds.Width, h = window.Bounds.Height;
            bool left = p.X < grip, right = p.X > w - grip, top = p.Y < grip, bottom = p.Y > h - grip;
            bool nearLeft = p.X < corner, nearRight = p.X > w - corner, nearTop = p.Y < corner, nearBottom = p.Y > h - corner;
            if ((top && nearLeft) || (left && nearTop)) return WindowEdge.NorthWest;
            if ((top && nearRight) || (right && nearTop)) return WindowEdge.NorthEast;
            if ((bottom && nearLeft) || (left && nearBottom)) return WindowEdge.SouthWest;
            if ((bottom && nearRight) || (right && nearBottom)) return WindowEdge.SouthEast;
            if (top) return WindowEdge.North;
            if (bottom) return WindowEdge.South;
            if (left) return WindowEdge.West;
            if (right) return WindowEdge.East;
            return null;
        }
        WindowEdge? hover = null;
        window.AddHandler(InputElement.PointerPressedEvent, (_, e) =>
        {
            if (!e.GetCurrentPoint(window).Properties.IsLeftButtonPressed || At(e.GetPosition(window)) is not WindowEdge edge) return;
            window.BeginResizeDrag(edge, e);
            e.Handled = true;
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        window.AddHandler(InputElement.PointerMovedEvent, (_, e) =>
        {
            var at = At(e.GetPosition(window));
            if (at == hover) return;
            hover = at;
            window.Cursor = at switch
            {
                WindowEdge.North or WindowEdge.South => new Cursor(StandardCursorType.SizeNorthSouth),
                WindowEdge.West or WindowEdge.East => new Cursor(StandardCursorType.SizeWestEast),
                WindowEdge.NorthWest => new Cursor(StandardCursorType.TopLeftCorner),
                WindowEdge.NorthEast => new Cursor(StandardCursorType.TopRightCorner),
                WindowEdge.SouthWest => new Cursor(StandardCursorType.BottomLeftCorner),
                WindowEdge.SouthEast => new Cursor(StandardCursorType.BottomRightCorner),
                _ => Cursor.Default,
            };
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
    }

    /// 最近打开的一个（自测截图用）
    public static Window? Last { get; private set; }

    public static void Show(Window window, bool modal = false)
    {
        Last = window;
        window.Closed += (_, _) => { if (Last == window) Last = null; };
        ShowPlaced(window, Owner(), modal);
    }

    /// 弹窗挂在哪个窗口上：当前在前台的 Kiteline 窗口（从设置窗口里点的，就盖在设置窗口上，不会被它挡住），没有就主窗口
    public static Window? Owner()
    {
        var windows = (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Windows;
        return windows?.FirstOrDefault(w => w.IsActive && w.IsVisible) ?? MainWindow.Current;
    }
}

/// 记一条待办、修改一条、从某条消息加一条（同 Mac 版 TodoEditor 的 macBody）：多行文字、附截图（Ctrl+V 粘贴、拖进来、选文件，最多 9 张）
public sealed class TodoEditor
{
    public sealed record Target(TodoItem? Editing, AddTodosRequest? Request)
    {
        public static Target New() => new(null, null);
        public static Target Edit(TodoItem item) => new(item, null);
        public static Target FromMessage(AddTodosRequest request) => new(null, request);
    }

    const int MaxShots = 9;
    readonly Target target;
    readonly Window window;
    readonly TextBox input;
    readonly List<TodoShot> shots;
    readonly WrapPanel shotGrid = new();
    readonly Border shotArea;
    readonly TextBlock shotCount = Ui.Text("", 11.5, color: "Text3").Digits();
    readonly Tap confirm;
    readonly string initialText;
    readonly List<string> initialShots;
    bool busy;

    public static void Open(Target target) => new TodoEditor(target);

    TodoEditor(Target target)
    {
        this.target = target;
        initialText = target.Editing?.Text ?? target.Request?.Candidates.FirstOrDefault() ?? "";
        shots = target.Editing?.Images.Select(TodoShot.FromSaved).ToList() ?? [];
        initialShots = shots.Select(s => s.Id).ToList();
        var title = target.Editing is not null ? L("修改待办") : target.Request is not null ? L("加入待办") : L("新建待办");
        var confirmTitle = target.Editing is null ? L("加入") : L("保存");

        var header = new StackPanel { Spacing = 5, Margin = new Thickness(0, 0, 0, 14) };
        header.Children.Add(Ui.Text(title, 16, FontWeight.SemiBold));
        if (SourceText is string source) header.Children.Add(Ui.H(5, Ui.Sym("text.bubble", 11, "Text2"), Ui.Text(source, 12, color: "Text2").Trim().Shrink()));

        input = new TextBox
        {
            Text = initialText, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 96, MaxHeight = 240, FontSize = Look.Pt(14),
            Watermark = L("需要做的事"), Padding = new Thickness(10, 8), Background = Brushes.Transparent, BorderThickness = new Thickness(0),
        };
        input.Classes.Add("plain");
        input.AddHandler(InputElement.KeyDownEvent, OnKey, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        input.PasteImages(MaxShots, Add);
        var field = new Border
        {
            CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(0.5),
            Child = new StackPanel
            {
                Children =
                {
                    input,
                    Ui.H(8, new DictateButton(said => { input.Text = DictateButton.Append(said, input.Text); input.Focus(); input.CaretIndex = input.Text?.Length ?? 0; }),
                        new Spacer(), Ui.Text(L("Ctrl+V 粘贴截图 · Ctrl+Enter %@", confirmTitle), 11.5, color: "Text3")).Pad(8, 0, 8, 8),
                },
            },
        }.Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");

        var pickLink = new Tap(Ui.Text(L("选择文件…"), 12, color: "Accent").Pad(2, 2), Pick, 4).Keys("Transparent", "Fill05");
        var shotsHead = Ui.H(6, Ui.Text(L("截图"), 13, FontWeight.Medium), shotCount, new Spacer(), pickLink).Margin(0, 18, 0, 8);
        shotArea = new Border { CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), Child = shotGrid, MinHeight = 76 }
            .Res(Border.BackgroundProperty, "Fill03").Res(Border.BorderBrushProperty, "Separator");
        DragDrop.SetAllowDrop(shotArea, true);

        var top = new StackPanel { Children = { header, field, shotsHead, shotArea } }.Pad(20, 18, 20, 20);
        confirm = new Tap(Ui.Text(confirmTitle, 13, FontWeight.SemiBold, "White").HAlign(HorizontalAlignment.Center).Pad(18, 0), Save, 7) { Height = 30, MinWidth = 72 }
            .Keys("WechatGreen", "GreenHover", "GreenPressed");
        var cancel = new Tap(Ui.Text(L("取消"), 13).HAlign(HorizontalAlignment.Center).Pad(18, 0), Cancel, 7) { Height = 30, MinWidth = 72, BorderThickness = new Thickness(0.5) }
            .Keys("Fill10", "Fill15").Res(Border.BorderBrushProperty, "Fill12");
        var note = target.Request is not null && SourceText is not null ? Ui.Text(L("加入后点击即可跳转到原消息"), 11.5, color: "Text2") : null;
        var footer = Ui.H(10, note, new Spacer(), cancel, confirm).Pad(20, 14);
        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        var rule = Ui.Rule("Separator", 0.5);
        DockPanel.SetDock(rule, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(rule);
        root.Children.Add(top);

        window = Dialog.Make(root, 560, title);
        DragDrop.SetAllowDrop(window, true);
        window.AddHandler(DragDrop.DragOverEvent, (_, e) => { e.DragEffects = DragDropEffects.Copy; Highlight(true); });
        window.AddHandler(DragDrop.DragLeaveEvent, (_, _) => Highlight(false));
        window.AddHandler(DragDrop.DropEvent, (_, e) => { Highlight(false); OnDrop(e); });
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) Cancel(); };
        window.Opened += (_, _) => { input.Focus(); input.CaretIndex = input.Text?.Length ?? 0; };
        input.TextChanged += (_, _) => UpdateConfirm();
        DrawShots();
        UpdateConfirm();
        Dialog.Show(window);
    }

    string? SourceText
    {
        get
        {
            if (target.Editing?.Source is { } s) return L("出自「%@」", s.Title) + (s.Ts is double ts ? " · " + Format.ListTime(ts) : "");
            if (target.Request is { Title: { Length: > 0 } title } r) return L("出自「%@」", title) + (r.Ts is double t ? " · " + Format.ListTime(t) : "");
            return null;
        }
    }

    bool Dirty => (input.Text ?? "").Trim() != initialText.Trim() || !shots.Select(s => s.Id).SequenceEqual(initialShots);
    bool CanSave => !busy && (input.Text ?? "").Trim().Length > 0;

    void UpdateConfirm()
    {
        confirm.Opacity = CanSave ? 1 : 0.45;
        confirm.IsHitTestVisible = CanSave;
    }

    void Highlight(bool on) => shotArea.Res(Border.BorderBrushProperty, on ? "Accent" : "Separator");

    void OnKey(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && e.KeyModifiers.HasFlag(KeyModifiers.Control)) { e.Handled = true; if (CanSave) Save(); }
    }

    void OnDrop(DragEventArgs e)
    {
        if (e.Data.GetFiles() is not { } files) return;
        Add(files.OfType<IStorageFile>().Select(f => f.TryGetLocalPath()).Where(p => p is not null && IsImage(p)).Select(p => File.ReadAllBytes(p!)).ToList());
    }

    static bool IsImage(string? path) => path is not null && new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic" }.Contains(System.IO.Path.GetExtension(path).ToLowerInvariant());

    async void Pick()
    {
        if (shots.Count >= MaxShots) return;
        var files = await window.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = true, Title = L("添加截图"), FileTypeFilter = [FilePickerFileTypes.ImageAll] });
        Add(files.Select(f => f.TryGetLocalPath()).Where(p => p is not null).Select(p => File.ReadAllBytes(p!)).ToList());
    }

    /// 粘贴、拖进来、选文件加的图：同发消息，长边缩到 2048、转 JPEG
    void Add(IReadOnlyList<byte[]> list)
    {
        foreach (var data in list)
        {
            if (shots.Count >= MaxShots) break;
            if (ImagePrep.Prepare(data) is { } prepared) shots.Add(TodoShot.FromNew(prepared.Jpeg, prepared.Preview));
        }
        DrawShots();
    }

    /// 截图区：没图时一块虚线框（点一下选文件）；有图时一格格缩略图（指上去右上角 ✕），最后一格「+」接着加
    void DrawShots()
    {
        shotCount.Text = $"{shots.Count}/{MaxShots}";
        shotGrid.Children.Clear();
        if (shots.Count == 0)
        {
            var hint = new StackPanel
            {
                Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 18),
                Children =
                {
                    Ui.Sym("photo.on.rectangle.angled", 20, "Text2").HAlign(HorizontalAlignment.Center),
                    Ui.Text(L("将截图拖到此处，或在文字框中按 Ctrl+V 粘贴"), 12, color: "Text2").HAlign(HorizontalAlignment.Center),
                    Ui.Text(L("最多 %@ 张", MaxShots), 11.5, color: "Text3").HAlign(HorizontalAlignment.Center),
                },
            };
            var tap = new Tap(hint, Pick, 10).Keys("Transparent", "Fill03").Tip(L("点击选择图片文件"));
            shotGrid.Children.Add(tap);
            tap.Width = 518;
            return;
        }
        foreach (var shot in shots.ToList())
        {
            var image = new Image { Stretch = Stretch.UniformToFill };
            if (shot.Preview is byte[] preview) { using var stream = new MemoryStream(preview); image.Source = new Bitmap(stream); }
            else if (shot.Saved is { } saved)
            {
                var query = TodoItem.MediaQuery(saved.Ref);
                query["thumb"] = "200";
                ImageCache.Load(TodoItem.MediaPath, query, b => image.Source = b);
            }
            var tile = new Border { Width = 76, Height = 76, CornerRadius = new CornerRadius(8), ClipToBounds = true, Child = image }.Res(Border.BackgroundProperty, "Fill06");
            ToolTip.SetTip(image, L("点击放大查看"));
            image.OnTap(() => ImageViewer.ShowShots(shots, Math.Max(0, shots.IndexOf(shot))));
            var remove = new Tap(Ui.Sym("xmark", 9, "White").HAlign(HorizontalAlignment.Center), () => { shots.Remove(shot); DrawShots(); }, 9)
            {
                Width = 18, Height = 18, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 4, 4, 0),
                Background = new SolidColorBrush(Colors.Black, 0.6), IsVisible = false,
            }.Tip(L("移除截图"));
            remove.Keys("Transparent", "Transparent");
            remove.Background = new SolidColorBrush(Colors.Black, 0.6);
            var cell = new Panel { Children = { tile, remove }, Margin = new Thickness(10, 10, 0, 0) };
            cell.PointerEntered += (_, _) => remove.IsVisible = true;
            cell.PointerExited += (_, _) => remove.IsVisible = false;
            cell.Menu(() => [Ui.Item(L("移除截图"), () => { shots.Remove(shot); DrawShots(); })]);
            shotGrid.Children.Add(cell);
        }
        if (shots.Count < MaxShots)
        {
            var dash = new Rectangle { Width = 76, Height = 76, RadiusX = 8, RadiusY = 8, StrokeThickness = 1, StrokeDashArray = [4, 3] }.Res(Shape.StrokeProperty, "Separator");
            var plus = new Tap(new Panel { Children = { dash, Ui.Sym("plus", 18, "Text2").HAlign(HorizontalAlignment.Center) } }, Pick, 8) { Margin = new Thickness(10, 10, 0, 10) }
                .Keys("Transparent", "Fill05").Tip(L("添加图片文件"));
            shotGrid.Children.Add(plus);
        }
        else shotGrid.Margin = new Thickness(0, 0, 0, 10);
    }

    async void Cancel()
    {
        if (Dirty && !await Dialogs.Confirm(target.Editing is null ? L("放弃这条待办？") : L("放弃所做的修改？"), target.Editing is null ? L("放弃") : L("放弃修改"), destructive: true))
            return;
        window.Close();
    }

    async void Save()
    {
        if (!CanSave) return;
        busy = true;
        UpdateConfirm();
        var state = TodoState.Shared;
        var text = input.Text ?? "";
        bool ok;
        if (target.Editing is { } editing) ok = await state.Edit(editing, text, shots);
        else if (target.Request is { } r) ok = await state.Add([text], r.Key, r.ItemId, r.Title, r.Ts, shots);
        else ok = await state.Add([text], shots: shots);
        busy = false;
        UpdateConfirm();
        if (ok) window.Close();
    }
}

/// 「加入待办」（同 Mac 版 AddTodosSheet）：列出认出来的几件事，默认全选，可以去掉几条、改改字，再一起加进来；只有一件就用记一条的面板
public static class AddTodosDialog
{
    public static void Open(AddTodosRequest request)
    {
        if (request.Candidates.Count <= 1) { TodoEditor.Open(TodoEditor.Target.FromMessage(request)); return; }
        // 最近点进去改的是哪一条：听写的字接在它后面；没点过就新加一条
        var focused = -1;
        TextBox Make(string c)
        {
            var box = new TextBox
            {
                Text = c, AcceptsReturn = false, TextWrapping = TextWrapping.Wrap, FontSize = Look.Pt(14), Background = Brushes.Transparent,
                BorderThickness = new Thickness(0), Padding = new Thickness(0, 2, 0, 0), Watermark = L("待办内容"),
            };
            box.Classes.Add("plain");
            return box;
        }
        var texts = request.Candidates.Select(Make).ToList();
        var picked = Enumerable.Range(0, texts.Count).ToHashSet();
        for (var i = 0; i < texts.Count; i++) { var index = i; texts[i].GotFocus += (_, _) => focused = index; }
        Window? window = null;
        Tap? addButton = null;
        var rows = new StackPanel();
        void Draw()
        {
            rows.Children.Clear();
            for (var i = 0; i < texts.Count; i++)
            {
                var index = i;
                var on = picked.Contains(i);
                var check = new Tap(Ui.Sym(on ? "checkmark.circle.fill" : "circle", 20, on ? "WechatGreen" : "Text2"), () =>
                {
                    if (!picked.Remove(index)) picked.Add(index);
                    Draw();
                }, 12) { Width = 24, Height = 24 }.Keys("Transparent", "Transparent");
                check.Tip(on ? L("不加入这一项") : L("加入这一项"));
                texts[i].Foreground = Palette.Get(on ? "Text" : "Text2");
                if (texts[i].Parent is Panel old) old.Children.Remove(texts[i]);
                var row = Ui.HTop(10, check, texts[i].Grow()).Pad(12, 10);
                rows.Children.Add(row);
                if (i < texts.Count - 1) rows.Children.Add(Ui.Rule("Separator", 0.5).Margin(46, 0, 0, 0));
            }
            if (addButton is not null)
            {
                ((TextBlock)((Border)addButton.Child!).Child!).Text = picked.Count == 0 ? L("请至少选择一项") : L("加入 %@ 项", picked.Count);
                addButton.Opacity = picked.Count == 0 ? 0.4 : 1;
                addButton.IsHitTestVisible = picked.Count > 0;
            }
        }
        var label = Ui.Text("", 14, FontWeight.SemiBold, "White").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center);
        addButton = new Tap(new Border { Child = label }, async () =>
        {
            var chosen = Enumerable.Range(0, texts.Count).Where(picked.Contains).Select(i => texts[i].Text ?? "").ToList();
            if (await TodoState.Shared.Add(chosen, request.Key, request.ItemId, request.Title, request.Ts)) window?.Close();
        }, 12) { Height = 46 }.Keys("WechatGreen", "GreenHover", "GreenPressed");
        var stack = new StackPanel { Spacing = 12 };
        if (request.Title is { Length: > 0 } title)
            stack.Children.Add(Ui.Text(L("出自「%@」，加入后点击即可跳转到原消息", title), 12, color: "Text2", lines: 2).Wrap());
        stack.Children.Add(Card.Make(rows, 0, 12).Res(Border.BackgroundProperty, "Surface"));
        var dictate = new DictateButton(said =>
        {
            if (focused >= 0 && focused < texts.Count) { texts[focused].Text = DictateButton.Append(said, texts[focused].Text); picked.Add(focused); }
            else
            {
                var box = Make(said);
                var index = texts.Count;
                box.GotFocus += (_, _) => focused = index;
                texts.Add(box);
                picked.Add(index);
            }
            Draw();
        });
        stack.Children.Add(Ui.H(10, dictate, Ui.Text(L("如需为某项附加截图，请在加入后点击该项进行编辑。"), 11.5, color: "Text2", lines: 2).Wrap().Shrink()));
        stack.Children.Add(addButton);
        Draw();
        window = Dialog.Make(stack.Pad(20), 480, L("加入待办"));
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) window.Close(); };
        Dialog.Show(window);
    }
}

/// 对话里：Claude 这条回复里有要你做的事（同 Mac 版 AskPrompt）：气泡下面一张小卡片「有 N 项事项需要你处理 · 忽略 / 加入」；
/// 加过了变成一行「已加入待办 · N 项」（点开待办），说过不用的只留一个小小的「加入待办」
public static class AskPrompt
{
    public static Control Make(string key, ChatItem item, IReadOnlyList<string> asks)
    {
        var host = new ContentControl();
        var state = TodoState.Shared;
        void Draw() => host.Content = Content(key, item, asks);
        void Changed(object? s, PropertyChangedEventArgs e) => Draw();
        host.AttachedToVisualTree += (_, _) => { state.PropertyChanged += Changed; Draw(); };
        host.DetachedFromVisualTree += (_, _) => state.PropertyChanged -= Changed;
        Draw();
        return host;
    }

    static Control Content(string key, ChatItem item, IReadOnlyList<string> asks)
    {
        var state = TodoState.Shared;
        var added = state.Added(key, item.Id);
        if (added > 0)
            return new Tap(Ui.H(5, Ui.Sym("checkmark.circle.fill", 12, "Text2"), Ui.Text(L("已加入待办 · %@ 项", added), 12, color: "Text2")),
                () => MainModel.Shared.Selection = MainModel.TodosId, 4).Keys("Transparent", "Transparent").HAlign(HorizontalAlignment.Left).Margin(2, 0, 0, 0);
        if (state.IsHandled(key, item.Id))
            return new Tap(Ui.H(5, Ui.Sym("plus.circle", 12, "Text3"), Ui.Text(L("加入待办"), 12, color: "Text3")),
                () => TodoActions.Add(key, item, asks), 4).Keys("Transparent", "Transparent").HAlign(HorizontalAlignment.Left).Margin(2, 0, 0, 0);
        var ignore = new Tap(Ui.Text(L("忽略"), 13, color: "Text2").Pad(4, 3), () => state.Dismiss(key, item.Id), 4).Keys("Transparent", "Fill05");
        var add = new Tap(Ui.Text(L("加入"), 13, FontWeight.SemiBold, "White").Pad(14, 0), () => TodoActions.Add(key, item, asks), 15) { Height = 30 }
            .Keys("WechatGreen", "GreenHover", "GreenPressed");
        var row = Ui.H(10, Ui.Sym("checklist", 13, "Accent"),
            Ui.VFill(1, Ui.Text(L("有 %@ 项事项需要你处理", asks.Count), 13, FontWeight.SemiBold).Trim(), Ui.Text(L("加入待办，完成后勾选"), 11.5, color: "Text2").Trim()).Shrink(),
            new Spacer(6), ignore, add);
        var card = new Tap(row.Pad(ChatType.PadH, ChatType.PadV + ChatType.Px(2)), () => TodoActions.Add(key, item, asks), ChatType.Radius)
        {
            MaxWidth = ChatType.Px(360), HorizontalAlignment = HorizontalAlignment.Left, BorderThickness = new Thickness(1),
        }.Keys("BotBubble", "BotBubble");
        card.Res(Border.BorderBrushProperty, "AccentEdge25");
        card.Cursor = Cursor.Default;
        return card;
    }
}

/// 从消息加入待办（右键「加入待办」、对话里的提示卡）：认出了要你做的事就列那几件，没认出来就把这条消息（摘头几句）当一条，可以改
public static class TodoActions
{
    public static void Add(string key, ChatItem item, IReadOnlyList<string>? asks = null)
    {
        asks ??= item.Asks ?? [];
        var title = AppModel.Shared.Session(key)?.Title ?? AppModel.Shared.PastMeta.GetValueOrDefault(key)?.Title;
        var whole = Quote.Make(item.Text ?? "").Replace("\n", " ");
        if (whole.Length > 200) whole = whole[..200];
        AddTodosDialog.Open(new AddTodosRequest(key, item.Id, title, item.Ts, asks.Count == 0 ? [whole] : asks));
    }
}
