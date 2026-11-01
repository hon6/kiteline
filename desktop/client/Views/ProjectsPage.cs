using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 项目总览里的一个项目（某台机器上的一个工作目录）
public sealed record ProjectItem(string SourceId, string SourceName, string Cwd, string Name, string? SessionId, bool Exists,
                                 double LastActive, int Sessions, int Today, string? Title, ProjectItem.GitInfo? Git)
{
    public sealed record GitInfo(string? Branch, string? Upstream, int Ahead, int Behind, int Changed, int Untracked,
                                 string? LastHash, string? LastSubject, double LastTs, bool Timeout)
    {
        public bool Dirty => Changed > 0 || Untracked > 0;
    }

    public string Id => $"{SourceId}\n{Cwd}";

    public static ProjectItem? Parse(JsonNode? n)
    {
        if (n.Str("sourceId") is not string sourceId || n.Str("cwd") is not string cwd) return null;
        GitInfo? git = null;
        if (n.Obj("git") is JsonNode g)
        {
            var last = g.Obj("last");
            git = new GitInfo(g.Str("branch"), g.Str("upstream"), g.Int("ahead") ?? 0, g.Int("behind") ?? 0, g.Int("changed") ?? 0, g.Int("untracked") ?? 0,
                              last.Str("hash"), last.Str("subject"), last.Num("ts") ?? 0, g.Truthy("timeout"));
        }
        return new ProjectItem(sourceId, Lang.Machine(n.Str("sourceName") ?? sourceId), cwd, n.Str("name") ?? Path.GetFileName(cwd.TrimEnd('/', '\\')), n.Str("sessionId"),
                               n.Bool("exists") ?? true, n.Num("lastActive") ?? 0, n.Int("sessions") ?? 0, n.Int("today") ?? 0, n.Str("title"), git);
    }
}

/// 主窗口右侧的「项目」（同 Mac 版 ProjectsView）：所有机器上的项目，在跑的会话、未提交的改动、没推送的提交、最近一次提交；点一下展开
public sealed class ProjectsPage : Panel
{
    static List<ProjectItem> projects = [];
    static List<string> errors = [];
    static bool loading = true;
    static Dictionary<string, double> cost7 = [];
    static readonly Dictionary<string, List<PastItem>> past = [];
    static string filter = "all";
    static string? expanded;

    readonly PageBar bar;
    readonly TextBlock summaryText = Ui.Text("", 12, color: "Text2").Trim();
    readonly Spinner spinner = new(14);
    readonly StackPanel list = new() { Margin = new Thickness(16, 8, 16, 16) };
    DispatcherTimer? timer;
    int seq;

    public ProjectsPage()
    {
        bar = new PageBar(L("项目"), "", null, [PageBar.Button("arrow.clockwise", L("刷新"), Load)]);
        var segmented = new LookSegmented([("all", L("全部")), ("active", L("有活动")), ("dirty", L("有改动"))], filter, id => { filter = id; Rebuild(); })
        {
            Width = Lang.Current == "en" ? 330 : 240,   // 英文「Has Activity」放不进 240
        };
        var header = Ui.H(10, segmented, summaryText.Shrink(), new Spacer(), spinner).Pad(20, 14, 20, 8);
        var scroll = new ScrollViewer { Content = list, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        var dock = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        dock.Children.Add(header);
        dock.Children.Add(scroll);
        Children.Add(PageBar.Page(bar, dock));
        Rebuild();
        void SessionsChanged(object? _, System.ComponentModel.PropertyChangedEventArgs e) { if (e.PropertyName == nameof(AppModel.Sessions)) Rebuild(); }
        AttachedToVisualTree += (_, _) =>
        {
            AppModel.Shared.PropertyChanged += SessionsChanged;
            Load();
            timer = new DispatcherTimer(TimeSpan.FromSeconds(120), DispatcherPriority.Background, (_, _) => Load());
            timer.Start();
        };
        DetachedFromVisualTree += (_, _) => { AppModel.Shared.PropertyChanged -= SessionsChanged; timer?.Stop(); };
    }

    async void Load()
    {
        var current = ++seq;
        loading = true;
        spinner.IsVisible = true;
        var api = AppModel.Shared.Api;
        var usage = api.Get("/api/usage", new Dictionary<string, string> { ["days"] = "7" });
        try
        {
            var reply = await api.Get("/api/projects", new Dictionary<string, string> { ["detail"] = "1" });
            if (current != seq) return;
            projects = reply.Arr("projects").Items().Select(ProjectItem.Parse).OfType<ProjectItem>().Where(p => p.Exists || Live(p).Count > 0).ToList();
            errors = reply.Strings("errors").ToList();
        }
        catch (Exception e) { if (current == seq) errors = [e.Message]; }
        loading = false;
        Rebuild();
        try
        {
            var reply = await usage;
            if (current != seq) return;
            cost7 = reply.Arr("projects").Items().ToDictionary(i => $"{i.Str("sourceId") ?? ""}\n{i.Str("cwd") ?? ""}", i => i.Num("cost") ?? 0);
            Rebuild();
        }
        catch { }
    }

    async void Toggle(ProjectItem project)
    {
        expanded = expanded == project.Id ? null : project.Id;
        Rebuild();
        if (expanded is null) return;
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/sessions", new Dictionary<string, string> { ["source"] = project.SourceId, ["cwd"] = project.Cwd });
            past[project.Id] = reply.Arr("sessions").Items().Select(PastItem.Parse).OfType<PastItem>().Where(p => !p.Live).ToList();
        }
        catch { past[project.Id] = []; }
        Rebuild();
    }

    /// 这个项目里正在跑的会话（实时的，跟着侧栏变）
    static List<SessionInfo> Live(ProjectItem project) =>
        AppModel.Shared.Sessions.Where(s => s.SourceId == project.SourceId && s.Cwd == project.Cwd).ToList();

    static int Rank(ProjectItem project)
    {
        var sessions = Live(project);
        if (sessions.Any(s => s.IsWaiting)) return 3;
        if (sessions.Any(s => s.IsBusy)) return 2;
        return sessions.Count == 0 ? 0 : 1;
    }

    static List<ProjectItem> Shown => projects.Where(p => filter switch
    {
        "active" => Live(p).Count > 0 || p.Today > 0,
        "dirty" => p.Git is { } g && (g.Dirty || g.Ahead > 0),
        _ => true,
    }).OrderByDescending(Rank).ThenByDescending(p => p.LastActive).ToList();

    static string Summary
    {
        get
        {
            var running = projects.Count(p => Live(p).Count > 0);
            var waiting = projects.Count(p => Live(p).Any(s => s.IsWaiting));
            var dirty = projects.Count(p => p.Git?.Dirty ?? false);
            var unpushed = projects.Count(p => (p.Git?.Ahead ?? 0) > 0);
            return string.Join(" · ", new[] { L("%lld 个项目", projects.Count), L("%lld 个运行中", running), waiting > 0 ? L("%lld 个待确认", waiting) : null,
                dirty > 0 ? L("%lld 个有未提交改动", dirty) : null, unpushed > 0 ? L("%lld 个未推送", unpushed) : null }.OfType<string>());
        }
    }

    void Rebuild()
    {
        summaryText.Text = Summary;
        bar.Subtitle = Summary;
        spinner.IsVisible = loading;
        list.Children.Clear();
        var shown = Shown;
        for (var i = 0; i < shown.Count; i++)
        {
            var project = shown[i];
            var card = Card(project, Live(project), cost7.GetValueOrDefault(project.Id), expanded == project.Id, past.GetValueOrDefault(project.Id));
            var tap = new Tap(card.Pad(0, 10, 0, 10), () => Toggle(project), 0).Keys("Transparent", "Transparent");
            tap.Cursor = Avalonia.Input.Cursor.Default;
            list.Children.Add(tap);
            if (i < shown.Count - 1) list.Children.Add(Ui.Rule("Separator", 0.5).Margin(40, 0, 0, 0));
        }
        if (shown.Count == 0 && !loading)
            list.Children.Add(Ui.Text(projects.Count == 0 ? L("暂无使用过 Claude Code 的项目。") : L("没有符合条件的项目。"), 13, color: "Text2").Margin(0, 10, 0, 0));
        foreach (var error in errors)
            list.Children.Add(Ui.H(6, Ui.Sym("exclamationmark.triangle", 11.5, "Text2"), Ui.Text(error, 11.5, color: "Text2", lines: 2).Wrap().Shrink()).Margin(0, 10, 0, 0));
    }

    /// 一个项目（同 Mac 版 ProjectCard）
    static Control Card(ProjectItem project, List<SessionInfo> live, double cost, bool open, List<PastItem>? recent)
    {
        var state = live.Any(s => s.IsWaiting) ? "waiting" : live.Any(s => s.IsBusy) ? "busy" : live.Count == 0 ? "unknown" : "idle";
        var head = Ui.H(10, new SessionAvatar(project.Name, state, 30),
            Ui.VFill(1, Ui.Text(project.Name, 13, FontWeight.SemiBold).Trim(), Ui.Text($"{project.SourceName} · {Format.ShortPath(project.Cwd)}", 11, color: "Text2").Trim()).Shrink(),
            new Spacer { MinWidth = 6 }, Tag(live), Ui.Text(Format.Short(project.LastActive), 10.5, color: "Text3"),
            Ui.Sym(open ? "chevron.down" : "chevron.right", 10, "Text3"));
        var info = new StackPanel { Spacing = 3, Margin = new Thickness(40, 0, 0, 0) };
        if (project.Git is { } git)
        {
            info.Children.Add(GitLine(git));
            if (git.LastSubject is string subject)
                info.Children.Add(Ui.H(6, Ui.Text(git.LastHash ?? "", 11, color: "Text3").Mono(), Ui.Text(subject, 12, color: "Text2").Trim().Shrink(),
                    Ui.Text(Format.Short(git.LastTs), 10.5, color: "Text3")));
        }
        else if (project.Title is string title)
            info.Children.Add(Ui.Text(title, 12, color: "Text2").Trim());
        var foot = new[] { project.Today > 0 ? L("今天 %@ 个会话", project.Today) : null, project.Sessions > 0 ? L("共 %@ 个", project.Sessions) : null,
                           cost > 0 ? L("7 天 %@", UsagePage.Money(cost)) : null }.OfType<string>().ToList();
        if (foot.Count > 0) info.Children.Add(Ui.Text(string.Join(" · ", foot), 11, color: "Text3").Trim());
        var stack = new StackPanel { Spacing = 5, Children = { head, info } };
        if (open) stack.Children.Add(Detail(project, live, recent).Margin(40, 4, 0, 0));
        return stack;
    }

    static Control? Tag(List<SessionInfo> live)
    {
        var waiting = live.Count(s => s.IsWaiting);
        var busy = live.Count(s => s.IsBusy);
        (string Text, string Color, string Fill)? tag =
            waiting > 0 ? (waiting > 1 ? L("%lld 个待确认", waiting) : L("待确认"), "Orange", "OrangeFill13")
            : busy > 0 ? (busy > 1 ? L("%lld 个进行中", busy) : L("进行中"), "Accent", "IconTile")
            : live.Count > 0 ? (L("%lld 个会话运行中", live.Count), "Green", "GreenFill13") : null;
        if (tag is not { } t) return null;
        return new Border { Padding = new Thickness(6, 2), CornerRadius = new CornerRadius(9), Child = Ui.Text(t.Text, 10.5, FontWeight.Medium, t.Color) }
            .Res(Border.BackgroundProperty, t.Fill);
    }

    /// git 一行：⎇ 分支 ↑领先 ↓落后 · N 个改动 · N 个新文件 / 已全部提交
    static TextBlock GitLine(ProjectItem.GitInfo git)
    {
        var block = new TextBlock { FontSize = Look.Pt(12), TextTrimming = TextTrimming.CharacterEllipsis };
        block.Inlines = [];
        void Add(string text, string color, bool bold = false)
        {
            var run = new Run(text) { FontWeight = bold ? FontWeight.Bold : FontWeight.Normal };
            run.Bind(Run.ForegroundProperty, block.GetResourceObservable(color));
            block.Inlines.Add(run);
        }
        if (git.Timeout)
        {
            Add(L("git 状态读取超时"), "Orange", true);
            Add(L(" · 可能是该文件夹在网络盘上或被占用"), "Text2");
            return block;
        }
        Add($"⎇ {git.Branch ?? L("(无分支)")}", "Text2");
        if (git.Ahead > 0) Add($" ↑{git.Ahead}", "Accent", true);
        if (git.Behind > 0) Add($" ↓{git.Behind}", "Red", true);
        if (git.Changed > 0) { Add(" · ", "Text2"); Add(L("%@ 个改动", git.Changed), "Orange", true); }
        if (git.Untracked > 0) Add(" · " + L("%@ 个新文件", git.Untracked), "Text2");
        if (!git.Dirty) { Add(" · ", "Text2"); Add(L("已全部提交"), "Green"); }
        return block;
    }

    static Control Detail(ProjectItem project, List<SessionInfo> live, List<PastItem>? recent)
    {
        var stack = new StackPanel { Spacing = 6 };
        var actions = Ui.H(8);
        if (project.Exists) actions.Children.Add(new GlassButton(L("在此新建任务"), "square.and.pencil", () => MainModel.Shared.NewTask(project.SourceId, project.Cwd), height: 24, size: 12));
        if (project.Git is { Upstream: string upstream } git)
        {
            var text = git.Ahead == 0 && git.Behind == 0 ? L("和 %@ 一致", upstream)
                : string.Join(L("，"), new[] { git.Ahead > 0 ? L("领先 %@ 个提交（未推送）", git.Ahead) : null, git.Behind > 0 ? L("落后 %@ 个", git.Behind) : null }.OfType<string>());
            actions.Children.Add(Ui.Text(text, 11.5, color: "Text2"));
        }
        if (actions.Children.Count > 0) stack.Children.Add(actions);
        if (live.Count > 0)
        {
            stack.Children.Add(Ui.Text(L("正在运行"), 11, FontWeight.SemiBold, "Text2").Margin(0, 2, 0, 0));
            foreach (var session in live)
            {
                var color = session.IsWaiting ? "Orange" : session.IsBusy ? "Accent" : session.Activity == "idle" ? "Green" : "Text2";
                var section = session.IsWaiting ? L("待处理") : session.IsBusy ? L("进行中") : session.Activity == "idle" ? L("空闲") : L("其他");
                var row = Ui.H(8, Ui.Dot(6, color), Ui.Text(session.Title, 12.5).Trim().Shrink(), new Spacer { MinWidth = 4 }, Ui.Text(section, 10.5, color: "Text3"));
                var key = session.Key;
                stack.Children.Add(new Tap(row, () => MainModel.Shared.Selection = key, 4).Keys("Transparent", "Fill05"));
            }
        }
        stack.Children.Add(Ui.Text(L("最近的会话"), 11, FontWeight.SemiBold, "Text2").Margin(0, 2, 0, 0));
        if (recent is null) stack.Children.Add(new Spinner(14).HAlign(HorizontalAlignment.Left));
        else if (recent.Count == 0) stack.Children.Add(Ui.Text(L("没有已结束的会话"), 12, color: "Text3"));
        else foreach (var item in recent.Take(8)) stack.Children.Add(HistoryPage.Row(item));
        return stack;
    }
}
