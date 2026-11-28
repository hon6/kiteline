using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using Kiteline.Views.Code;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 新版界面「项目」这一栏（同 Mac 版 SidebarProjects + ProjectSessions + TarsProjectSide）：
/// 上面项目列表（「活动中」和默认收起的「其他项目」两节）；点一个项目，列表只把它标成选中，下面叠着的两块换成它的——
/// 这个项目的会话（正在运行 + 最近的会话）和文件侧栏（顶部图标页签切文件 / Git / 分支与会话 / 提交历史）。
/// 块之间的分隔条能拖（比例按栏记），每块点小节标题能收起
public sealed class SideProjects : Grid
{
    readonly Block list, sessions, files;
    readonly StackPanel listBody = new();
    readonly StackPanel sessionBody = new();
    readonly ContentControl fileBody = new();
    /// 文件侧栏按项目各留一份（切回来不重读）
    static readonly Dictionary<string, CodeWindow> Sides = [];
    static readonly Dictionary<string, List<PastItem>?> Recent = [];

    public SideProjects()
    {
        list = new Block("projects", L("项目"), new ScrollViewer { Content = listBody.Margin(SideMetric.Edge, 0, SideMetric.Edge, 8), HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled },
            SmallIcon("plus", L("打开项目：新建任务时选择电脑和文件夹"), () => MainModel.Shared.NewTask()));
        sessions = new Block("sessions", L("会话"), new ScrollViewer { Content = sessionBody.Margin(SideMetric.Edge, 0, SideMetric.Edge, 8), HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled }, null);
        files = new Block("files", L("文件"), fileBody, null);
        foreach (var b in new[] { list, sessions, files }) b.Toggled += Arrange;
        ProjectList.Start();
        ProjectList.Changed += Schedule;
        Layout.SideChanged += Schedule;
        AppModel.Shared.PropertyChanged += SessionsChanged;
        ChatPanes.Shared.OpenKeysChanged += Schedule;
        DetachedFromVisualTree += (_, _) => { };
        Rebuild();
    }

    void SessionsChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppModel.Sessions)) Schedule();
    }

    bool pending;

    void Schedule()
    {
        if (pending) return;
        pending = true;
        Dispatcher.UIThread.Post(() => { pending = false; Rebuild(); }, DispatcherPriority.Background);
    }

    ProjectItem? Selected => ProjectList.Get(Layout.OpenProject);
    string? arranged;

    void Rebuild()
    {
        BuildList();
        var project = Selected;
        if (project is not null)
        {
            sessions.Title = project.Name;
            sessions.Accessory = NewSessionButton(project);
            BuildSessions(project);
            BuildFiles(project);
        }
        var key = project?.Id ?? "";
        if (key != arranged) { arranged = key; Arrange(); }
    }

    // MARK: 排几块（同 Mac 的 PanelStack：默认一样高，分隔条能拖，每块至少 110；收起的块只剩 22 点标题条）

    void Arrange()
    {
        Children.Clear();
        RowDefinitions.Clear();
        var blocks = Selected is null ? new[] { list } : new[] { list, sessions, files };
        var weights = Weights(blocks.Length);
        for (var i = 0; i < blocks.Length; i++)
        {
            if (i > 0)
            {
                RowDefinitions.Add(new RowDefinition(GridLength.Auto));
                var splitter = new GridSplitter { Height = 5, ResizeDirection = GridResizeDirection.Rows, Background = Brushes.Transparent, Margin = new Thickness(0, -2, 0, -2) };
                var line = Ui.Rule("Separator", 0.5).VAlign(VerticalAlignment.Center);
                line.IsHitTestVisible = false;
                SetRow(splitter, RowDefinitions.Count - 1);
                SetRow(line, RowDefinitions.Count - 1);
                Children.Add(line);
                Children.Add(splitter);
                splitter.DragCompleted += (_, _) => SaveWeights(blocks);
                splitter.IsEnabled = !blocks[i - 1].Collapsed && !blocks[i].Collapsed;
            }
            var b = blocks[i];
            RowDefinitions.Add(b.Collapsed ? new RowDefinition(GridLength.Auto) : new RowDefinition(new GridLength(weights[i], GridUnitType.Star)) { MinHeight = 110 });
            b.Collapsible = blocks.Length > 1;
            if (b.Parent is Panel old) old.Children.Remove(b);
            SetRow(b, RowDefinitions.Count - 1);
            Children.Add(b);
        }
        // 全收起时最后一块贴栏底：补一行占满
        if (blocks.All(b => b.Collapsed)) RowDefinitions.Add(new RowDefinition(GridLength.Star));
    }

    static double[] Weights(int count)
    {
        var saved = Prefs.Node("panelWeights.projects" + count) as JsonArray;
        var w = saved?.Select(n => n?.GetValue<double>() ?? 1).ToArray();
        return w is { Length: > 0 } && w.Length == count && w.All(x => x > 0) ? w : Enumerable.Repeat(1.0, count).ToArray();
    }

    void SaveWeights(Block[] blocks)
    {
        var rows = RowDefinitions.Where((_, i) => i % 2 == 0).ToList();
        if (rows.Count != blocks.Length) return;
        var heights = rows.Select(r => Math.Max(1, r.ActualHeight)).ToArray();
        Prefs.Set("panelWeights.projects" + blocks.Length, new JsonArray(heights.Select(h => (JsonNode?)JsonValue.Create(h)).ToArray()));
    }

    // MARK: 项目列表

    void BuildList()
    {
        listBody.Children.Clear();
        var items = ProjectList.Items;
        list.Count = items.Count;
        if (items.Count == 0)
        {
            listBody.Children.Add(ProjectList.Loaded
                ? Ui.Text(L("暂无使用过 Claude Code 的项目。"), 11.5, color: "Text2", lines: 0).Wrap().Margin(SideMetric.Pad, 8, SideMetric.Pad, 0)
                : new SkeletonView(SkeletonKind.Rows, 5));
            return;
        }
        int Rank(ProjectItem p)
        {
            var live = ProjectList.Live(p);
            return live.Any(s => s.IsWaiting) ? 3 : live.Any(s => s.IsBusy) ? 2 : live.Count > 0 ? 1 : 0;
        }
        var active = items.Where(ProjectList.Active).OrderByDescending(Rank).ThenByDescending(p => p.LastActive).ToList();
        var rest = items.Where(p => !ProjectList.Active(p)).OrderByDescending(p => p.LastActive).ToList();
        listBody.Children.Add(Section(L("活动中"), active.Count, true, null));
        foreach (var p in active) listBody.Children.Add(Row(p));
        if (active.Count == 0) listBody.Children.Add(Ui.Text(L("今天还没有项目有动静"), 11, color: "Text3").Margin(SideMetric.Pad, 2, 0, 4));
        if (rest.Count > 0)
        {
            // 选中的项目在「其他项目」里：这一节自动展开，不然看不到选中了谁
            var open = Prefs.Bool("projects.rest.open") || rest.Any(p => p.Id == Layout.OpenProject);
            listBody.Children.Add(Section(L("其他项目"), rest.Count, open, () => { Prefs.Set("projects.rest.open", !open); BuildList(); }));
            if (open) foreach (var p in rest) listBody.Children.Add(Row(p));
        }
    }

    static Control Section(string title, int count, bool open, Action? toggle)
    {
        var row = Ui.H(4,
            toggle is null ? null : Ui.Sym(open ? "chevron.down" : "chevron.right", 8.5, "Text3"),
            Ui.Text(title, 11, FontWeight.SemiBold, "Text2"), Ui.Text(count.ToString(), 10.5, color: "Text3").Digits());
        var tap = new Tap(row, toggle, SideMetric.Radius) { Height = SideMetric.Header, Padding = new Thickness(toggle is null ? SideMetric.Pad : 0, 0, SideMetric.Pad, 0), Margin = new Thickness(0, 6, 0, 2) };
        return toggle is null ? tap.Keys("Transparent", "Transparent") : tap.Keys("Transparent", "Fill05");
    }

    /// 一行一个项目：状态点、名字、在跑几个；第二行设备 · 分支和改动（同 Mac 的项目行）
    Control Row(ProjectItem p)
    {
        var live = ProjectList.Live(p);
        var on = Layout.OpenProject == p.Id;
        var dot = live.Any(s => s.IsWaiting) ? "Orange" : live.Any(s => s.IsBusy) ? "Accent" : live.Count > 0 ? "Green" : "Text4";
        var git = p.Git is { } g
            ? $"⎇ {g.Branch ?? "—"}" + (g.Changed + g.Untracked > 0 ? " · " + L("%@ 个改动", g.Changed + g.Untracked) : "") + (g.Ahead > 0 ? $" ↑{g.Ahead}" : "")
            : null;
        var first = Ui.H(SideMetric.Gap, Ui.Dot(7, dot), Ui.Text(p.Name, 12, on ? FontWeight.SemiBold : FontWeight.Medium).Trim().Shrink(), new Spacer(4),
            live.Count > 0 ? Ui.Text(L("%@ 个会话", live.Count), 10.5, color: live.Any(s => s.IsWaiting) ? "Orange" : "Text3").Digits() : Ui.Text(Format.Short(p.LastActive), 10.5, color: "Text3"));
        var second = Ui.Text(string.Join(" · ", new[] { p.SourceName, git }.OfType<string>()), 10.5, color: "Text3").Trim().Margin(13, 0, 0, 0);
        var tap = new Tap(Ui.VFill(2, first, second), () => Pick(p), SideMetric.Radius) { Padding = new Thickness(SideMetric.Pad, 5), Margin = new Thickness(0, 0, 0, 2), BorderThickness = new Thickness(on ? 1 : 0) };
        if (on) { tap.Keys("AccentFill14", "AccentFill14"); tap.Res(Border.BorderBrushProperty, "AccentEdge32"); }
        else tap.Keys("Transparent", "Fill05", "Fill08");
        tap.Tip($"{p.Name} · {p.SourceName} · {p.Cwd}");
        tap.Menu(() =>
        [
            Ui.Item(L("在此新建任务"), () => MainModel.Shared.NewTask(p.SourceId, p.Cwd), p.Exists),
            Ui.Item(L("放到顶上那一排"), () => ProjectSpaces.Open(p.Id)),
            Ui.Item(L("切到这个项目的标签页"), () => ProjectSpaces.Switch(p.Id)),
        ]);
        return tap;
    }

    /// 点一个项目：列表里标成选中，下面换成它的会话和文件；分屏也切到这个项目的一套标签（同 Mac：切项目中间的会话也跟着换）
    static void Pick(ProjectItem p)
    {
        Layout.OpenProject = p.Id;
        ProjectSpaces.Switch(p.Id);
        _ = LoadRecent(p);
    }

    // MARK: 这个项目的会话

    static Control NewSessionButton(ProjectItem p)
    {
        var b = new Tap(Ui.H(4, Ui.Sym("square.and.pencil", 10.5, "Accent"), Ui.Text(L("新会话"), 11.5, FontWeight.SemiBold, "Accent")), () => MainModel.Shared.NewTask(p.SourceId, p.Cwd), SideMetric.Radius)
            { Height = 20, Padding = new Thickness(8, 0), BorderThickness = new Thickness(1) }.Keys("AccentFill10", "AccentFill14");
        b.Res(Border.BorderBrushProperty, "AccentEdge32");
        b.IsEnabled = p.Exists;
        return b.Tip(L("在此项目中新建会话"));
    }

    readonly Dictionary<string, SessionRowView> rows = [];

    void BuildSessions(ProjectItem p)
    {
        sessionBody.Children.Clear();
        var model = AppModel.Shared;
        var live = model.SortedSessions("recent", ProjectList.Live(p)).ToList();
        sessions.Count = live.Count;
        sessionBody.Children.Add(Section(L("未关闭的会话"), live.Count, true, null));
        if (live.Count == 0) sessionBody.Children.Add(Ui.Text(L("没有未关闭的会话"), 11, color: "Text3").Margin(SideMetric.Pad, 2, 0, 4));
        var used = new HashSet<string>();
        foreach (var s in live)
        {
            if (!rows.TryGetValue(s.Key, out var row)) rows[s.Key] = row = new SessionRowView(model, MainModel.Shared);
            row.Update(s);
            used.Add(s.Key);
            sessionBody.Children.Add(row);
        }
        foreach (var gone in rows.Keys.Where(k => !used.Contains(k)).ToList()) rows.Remove(gone);
        // 最近的会话（默认收起，键 recent.open 记的是展开）：只去掉正显示着的会话
        var open = Prefs.Bool("recent.open");
        Recent.TryGetValue(p.Id, out var recent);
        var shown = recent?.Where(r => !used.Contains(r.Key)).ToList();
        sessionBody.Children.Add(Section(L("最近的会话"), shown?.Count ?? 0, open, () => { Prefs.Set("recent.open", !open); BuildSessions(p); if (!open) _ = LoadRecent(p); }));
        if (!open) return;
        if (recent is null) { sessionBody.Children.Add(new SkeletonView(SkeletonKind.Rows, 3)); _ = LoadRecent(p); return; }
        if (shown!.Count == 0) sessionBody.Children.Add(Ui.Text(L("没有已结束的会话"), 11, color: "Text3").Margin(SideMetric.Pad, 2, 0, 4));
        foreach (var item in shown.Take(40)) sessionBody.Children.Add(PastRow(item));
    }

    /// 最近的一个会话：标题（最多两行，不加粗）、时间
    static Control PastRow(PastItem item)
    {
        var row = Ui.VFill(2, Ui.Text(item.DisplayTitle, 12, color: "Text", lines: 2).Wrap(), Ui.Text($"{Format.Short(item.LastActive)} · {item.SourceName}", 10.5, color: "Text3").Trim());
        row.Children[0].MaxHeight = 34;
        var tap = new Tap(row, () => { AppModel.Shared.RememberPast(item.Meta); MainModel.Shared.Pick(item.Key); }, SideMetric.Radius) { Padding = new Thickness(SideMetric.Pad, 5) }.Keys("Transparent", "Fill05", "Fill08");
        return tap.Tip(item.FirstPrompt);
    }

    static async Task LoadRecent(ProjectItem p)
    {
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/sessions", new Dictionary<string, string> { ["source"] = p.SourceId, ["cwd"] = p.Cwd });
            Recent[p.Id] = reply.Arr("sessions").Items().Select(PastItem.Parse).OfType<PastItem>().Where(x => !x.Live).OrderByDescending(x => x.LastActive).ToList();
        }
        catch { Recent[p.Id] = []; }
        Layout.NotifySide();
    }

    // MARK: 文件侧栏

    void BuildFiles(ProjectItem p)
    {
        var key = ProjectList.CodeKey(p);
        if (key is null)
        {
            fileBody.Content = Ui.Text(L("这个项目还没有会话，开一个会话后可在这里看文件和 Git。"), 11.5, color: "Text2", lines: 0).Wrap().Margin(SideMetric.Inset, 8, SideMetric.Inset, 0);
            return;
        }
        if (!Sides.TryGetValue(p.Id, out var side) || side.SessionKey != key)
        {
            side = CodeWindow.Side(key);
            Sides[p.Id] = side;
        }
        if (fileBody.Content != side.View)
        {
            if (side.View!.Parent is ContentControl old) old.Content = null;
            fileBody.Content = side.View;
        }
    }

    static Control SmallIcon(string symbol, string tip, Action action) =>
        new Tap(Ui.Sym(symbol, 11, "Text2").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center), action, SideMetric.Radius) { Width = SideMetric.Small, Height = 20 }
            .Keys("Transparent", "Fill08").Tip(tip);

    /// 一块：22 点的小节标题（箭头 + 标题 + 数 + 右边的小按钮），点标题收起 / 展开（只有一块时不能收）；收起状态按块记
    sealed class Block : DockPanel
    {
        readonly string id;
        readonly TextBlock title = Ui.Text("", 11, FontWeight.SemiBold, "Text2").Trim();
        readonly TextBlock count = Ui.Text("", 10.5, color: "Text3").Digits();
        readonly Icon arrow = Ui.Sym("chevron.down", 8.5, "Text3");
        readonly ContentControl accessory = new() { VerticalAlignment = VerticalAlignment.Center };
        readonly Control body;
        public event Action? Toggled;

        public Block(string id, string text, Control body, Control? accessory)
        {
            this.id = id;
            this.body = body;
            // 11-25 反馈：新版界面的文件列默认收起（点标题条展开；展开后记住）。只在第一次执行，之后以用户自己的选择为准
            if (id == "files" && !Prefs.Bool("filesCollapsedByDefault1125"))
            {
                Prefs.Set("panel.collapsed.files", true);
                Prefs.Set("filesCollapsedByDefault1125", true);
            }
            title.Text = text;
            this.accessory.Content = accessory;
            var head = new DockPanel { Height = SideMetric.Header, Background = Brushes.Transparent, Margin = new Thickness(SideMetric.Edge, 2, SideMetric.Edge, 2) };
            DockPanel.SetDock(this.accessory, Dock.Right);
            head.Children.Add(this.accessory);
            head.Children.Add(Ui.H(4, arrow, title.Shrink(), count));
            var tap = new Tap(head, () => { if (!Collapsible) return; Collapsed = !Collapsed; Toggled?.Invoke(); }, SideMetric.Radius).Keys("Transparent", "Fill05");
            SetDock(tap, Dock.Top);
            Children.Add(tap);
            Children.Add(body);
            Update();
        }

        public string Title { set => title.Text = value; }
        public int Count { set => count.Text = value > 0 ? value.ToString() : ""; }
        public Control? Accessory { set => accessory.Content = value; }

        bool collapsible;
        public bool Collapsible { get => collapsible; set { collapsible = value; Update(); } }

        public bool Collapsed
        {
            get => collapsible && Prefs.Bool("panel.collapsed." + id);
            set { Prefs.Set("panel.collapsed." + id, value); Update(); }
        }

        void Update()
        {
            arrow.IsVisible = collapsible;
            arrow.Symbol = Collapsed ? "chevron.right" : "chevron.down";
            body.IsVisible = !Collapsed;
        }
    }
}
