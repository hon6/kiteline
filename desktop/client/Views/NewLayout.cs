using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 新版界面的尺寸（同 Mac 的 SideMetric：栏边 → 框 8、框 → 内容 8，字从离栏边 16 处起；小节标题 22，输入框 / 带字按钮 28，图标按钮 22；圆角 6）
public static class SideMetric
{
    public const double Edge = 8, Pad = 8, Inset = 16, Gap = 6, Header = 22, Control = 28, Small = 22, Radius = 6;
    public const double Rail = 50, Bar = 24;
}

/// 窗口右上角切换经典 / 新版界面的按钮（同 Mac 版 LayoutSwitch）：浮在标题栏那一带、窗口按钮左边；
/// 对话分屏、页面顶上那一排给它让出位置（MainWindow.CornerReserve）
public sealed class LayoutSwitch : Tap
{
    public LayoutSwitch() : base(null, null, SideMetric.Radius)
    {
        var on = Layout.New;
        Child = Ui.H(SideMetric.Gap, Ui.Sym(on ? "macwindow" : "sidebar.left", 12, "Text2"), Ui.Text(on ? L("经典界面") : L("新版界面"), 12, FontWeight.SemiBold, "Text2"));
        Padding = new Thickness(11, 0);
        Height = 26;
        BorderThickness = new Thickness(1);
        Keys("Fill06", "Fill10", "Fill14");
        this.Res(BorderBrushProperty, "Fill15");
        Click = () => Layout.Set(!Layout.New);
        this.Tip(on ? L("切回经典界面") : L("试试新版界面：左边图标栏、项目栏里看文件和 Git，会话和文件以标签页打开，可左右、上下分屏"));
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Top;
    }

    /// 让出来的宽度（按钮宽度 + 两边空隙，中英文不同）。按钮还没挂到窗口上时量不准（Windows 上量出 250 多），按语言给定值
    public double Reserve => Lang.Current == "en" ? 140 : 108;
}

/// 新版界面最左一条图标栏（同 Mac 版 SidebarRail，50 宽）：上面四项决定旁边那一栏列什么（会话 / 项目 / 待办 / 收藏），
/// 中间两项弹今日动态、用量（新版里是能拖动、改大小的弹窗，不占标签页区域），最底下是更新箭头、虚拟屏幕、手机访问、设置
public sealed class SidebarRail : Panel
{
    readonly StackPanel top = new() { Spacing = 2 };
    readonly StackPanel bottom = new() { Spacing = 2, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 8) };

    public SidebarRail()
    {
        Width = SideMetric.Rail;
        this.Res(BackgroundProperty, "Fill05");
        var band = new Border { Height = MainWindow.TitlebarHeight, Background = Brushes.Transparent };
        band.PointerPressed += WindowChrome.DragWindow;
        var dock = new DockPanel();
        DockPanel.SetDock(band, Dock.Top);
        dock.Children.Add(band);
        DockPanel.SetDock(bottom, Dock.Bottom);
        dock.Children.Add(bottom);
        dock.Children.Add(top);
        Children.Add(dock);
        Children.Add(Ui.VRule("Separator", 0.5).HAlign(HorizontalAlignment.Right));
        Layout.SideChanged += Schedule;
        AppModel.Shared.PropertyChanged += (_, e) => { if (e.PropertyName is nameof(AppModel.Sessions) or nameof(AppModel.Sources)) Schedule(); };
        TodoState.Shared.PropertyChanged += (_, _) => Dispatcher.UIThread.Post(Schedule);
        FavoriteState.Shared.PropertyChanged += (_, _) => Dispatcher.UIThread.Post(Schedule);
        VirtualScreenState.Shared.PropertyChanged += (_, _) => Schedule();
        PagePopup.Changed += Schedule;
        Build();
    }

    bool pending;
    string? built;

    void Schedule()
    {
        if (pending) return;
        pending = true;
        Dispatcher.UIThread.Post(() => { pending = false; Build(); }, DispatcherPriority.Background);
    }

    void Build()
    {
        var sessions = AppModel.Shared.Sessions;
        var waiting = sessions.Count(s => s.IsWaiting);
        var todos = TodoState.Shared.Open;
        var screen = VirtualScreenState.Shared;
        var key = string.Join("|", Layout.SideTab, waiting, sessions.Count, todos, TodoState.Shared.Suggested, screen.Supported, screen.On,
            PagePopup.IsOpen(MainModel.TodayId), PagePopup.IsOpen(MainModel.UsageId), Lang.Current);
        if (key == built) return;
        built = key;
        top.Children.Clear();
        bottom.Children.Clear();
        top.Children.Add(Item("sessions", "bubble.left.and.bubble.right", L("会话"), waiting, waiting > 0 ? "Orange" : null));
        top.Children.Add(Item("projects", "folder", L("项目"), 0, null));
        top.Children.Add(Item("todos", "checklist", L("待办"), TodoState.Shared.Suggested > 0 ? TodoState.Shared.Suggested : todos, TodoState.Shared.Suggested > 0 ? "Red" : null));
        top.Children.Add(Item("favorites", "star", L("收藏"), 0, null));
        top.Children.Add(Ui.Rule("Separator", 0.5).Margin(12, 6, 12, 6));
        top.Children.Add(Button("sun.max", L("今日动态"), PagePopup.IsOpen(MainModel.TodayId), () => PagePopup.Toggle(MainModel.TodayId)));
        top.Children.Add(Button("chart.bar", L("用量"), PagePopup.IsOpen(MainModel.UsageId), () => PagePopup.Toggle(MainModel.UsageId)));
        var update = new UpdateButton(24) { HorizontalAlignment = HorizontalAlignment.Center };
        bottom.Children.Add(update);
        if (screen.Supported) bottom.Children.Add(Button("display", screen.Help, screen.On, () => screen.Toggle()));
        bottom.Children.Add(Button("qrcode", L("手机访问"), false, () => SettingsWindow.Open("phone")));
        bottom.Children.Add(Button("gearshape", L("设置"), false, () => SettingsWindow.Open("general")));
    }

    /// 上面四项：选中的左边一道主题色、图标用正文色（同 VS Code 的活动栏）；数字角标
    static Control Item(string id, string symbol, string tip, int badge, string? badgeColor)
    {
        var on = Layout.SideTab == id;
        var cell = new Panel { Width = SideMetric.Rail, Height = 44 };
        cell.Children.Add(Ui.Sym(symbol, 19, on ? "Text" : "Text3").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center));
        if (on) cell.Children.Add(new Border { Width = 2.5, Height = 22, CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Left }.Res(Border.BackgroundProperty, "Accent"));
        if (badge > 0)
            cell.Children.Add(new Border
            {
                MinWidth = 15, Height = 15, CornerRadius = new CornerRadius(7.5), Padding = new Thickness(4, 0),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 7, 0),
                Child = Ui.Text(badge > 99 ? "99+" : badge.ToString(), 9.5, FontWeight.Bold, "White").Digits().HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center),
            }.Res(Border.BackgroundProperty, badgeColor ?? "Accent"));
        return new Tap(cell, () => Layout.SideTab = id, 0).Keys("Transparent", "Fill06").Tip(tip);
    }

    static Control Button(string symbol, string tip, bool lit, Action action)
    {
        var cell = new Panel { Width = SideMetric.Rail, Height = 40 };
        cell.Children.Add(Ui.Sym(symbol, 17, lit ? "Accent" : "Text3").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center));
        return new Tap(cell, action, 0).Keys("Transparent", "Fill06").Tip(tip);
    }
}

/// 今日动态、用量在新版界面里是弹窗（同 Mac：不要占标签页区域）；图标栏上亮不亮看弹窗开没开
public static class PagePopup
{
    static readonly Dictionary<string, Window> Open = [];
    public static event Action? Changed;

    public static bool IsOpen(string id) => Open.ContainsKey(id);

    public static void Toggle(string id)
    {
        if (Open.TryGetValue(id, out var w)) { w.Close(); return; }
        Show(id);
    }

    public static void Show(string id)
    {
        if (Open.TryGetValue(id, out var existing)) { existing.Activate(); return; }
        Control page = id == MainModel.UsageId ? Pages.Usage() : Pages.Today();
        var w = Sheets.Show(id == MainModel.UsageId ? L("用量") : L("今日动态"), page, 980, 720, scroll: false);
        Open[id] = w;
        w.Closed += (_, _) => { Open.Remove(id); Changed?.Invoke(); };
        Changed?.Invoke();
    }
}

/// 新版界面左边：图标栏 + 一栏内容（同 Mac 版 RailSidebar）。这一栏顶上标题栏那一带只写栏名（新任务 / 世界 / 数据流在上面项目那一排右边，
/// 同 Mac 新版放在窗口工具栏；栏名右边的空处留给顶上飞的纸鸢）
public sealed class RailSidebar : Grid
{
    readonly ContentControl column = new();
    readonly TextBlock title = Ui.Text("", 13, FontWeight.SemiBold).Trim();
    /// 每栏一份（切走再切回不重建，同 Mac：只有正显示的那栏存在，这里留着省得重读）
    readonly Dictionary<string, Control> cache = [];

    public RailSidebar()
    {
        ColumnDefinitions = new ColumnDefinitions($"{SideMetric.Rail},*");
        var rail = new SidebarRail();
        SetColumn(rail, 0);
        Children.Add(rail);
        var band = new DockPanel { Height = MainWindow.TitlebarHeight, Background = Brushes.Transparent };
        band.PointerPressed += WindowChrome.DragWindow;
        band.Children.Add(title.VAlign(VerticalAlignment.Center).Margin(SideMetric.Inset, 0, 8, 0));
        var dock = new DockPanel();
        DockPanel.SetDock(band, Dock.Top);
        dock.Children.Add(band);
        dock.Children.Add(column);
        var side = new Border { Child = dock }.Res(Border.BackgroundProperty, "Sidebar");
        SetColumn(side, 1);
        Children.Add(side);
        Layout.SideChanged += Show;
        DetachedFromVisualTree += (_, _) => Layout.SideChanged -= Show;
        Show();
    }

    string? shown;

    void Show()
    {
        var tab = Layout.SideTab;
        title.Text = tab switch { "projects" => L("项目"), "todos" => L("待办"), "favorites" => L("收藏"), _ => L("会话") };
        if (tab == shown) return;
        shown = tab;
        if (!cache.TryGetValue(tab, out var view))
        {
            PageBar.InColumn = true;
            try
            {
                view = tab switch
                {
                    "projects" => new SideProjects(),
                    "todos" => Pages.Todos(),
                    "favorites" => Pages.Favorites(),
                    _ => new SidebarView(embedded: true),
                };
            }
            finally { PageBar.InColumn = false; }
            cache[tab] = view;
        }
        column.Content = view;
    }
}

/// 新版界面底部状态栏（同 Mac 版 StatusBar，24 高）：来源数、手机数、Kiteline 自己的 CPU 和内存、会话数（工作中 / 待确认）；
/// 右边今天的 token 和各台电脑的额度（一行紧凑的「电脑 窗口 xx%」，八成起红色）加刷新
public sealed class StatusBar : Border
{
    readonly SidebarTilesModel tiles = new();
    readonly ContentControl left = new(), right = new();
    readonly DispatcherTimer timer;
    int phones;
    (TimeSpan Cpu, DateTime At)? lastCpu;
    double? cpu;
    double memory;

    public StatusBar()
    {
        Height = SideMetric.Bar;
        BorderThickness = new Thickness(0, 0.5, 0, 0);
        this.Res(BackgroundProperty, "Fill05").Res(BorderBrushProperty, "Separator");
        var dock = new DockPanel { Margin = new Thickness(8, 0, 8, 0) };
        DockPanel.SetDock(right, Dock.Right);
        dock.Children.Add(right);
        dock.Children.Add(left);
        Child = dock;
        tiles.Changed += () => Dispatcher.UIThread.Post(BuildRight);
        AppModel.Shared.PropertyChanged += (_, e) => { if (e.PropertyName is nameof(AppModel.Sessions) or nameof(AppModel.Sources) or nameof(AppModel.Connected)) Dispatcher.UIThread.Post(BuildLeft); };
        timer = new DispatcherTimer(TimeSpan.FromSeconds(3), DispatcherPriority.Background, (_, _) => Sample());
        var phoneTimer = new DispatcherTimer(TimeSpan.FromSeconds(10), DispatcherPriority.Background, (_, _) => RefreshPhones());
        AttachedToVisualTree += (_, _) => { timer.Start(); phoneTimer.Start(); RefreshPhones(); Sample(); };
        DetachedFromVisualTree += (_, _) => { timer.Stop(); phoneTimer.Stop(); };
        tiles.Start();
        BuildLeft();
        BuildRight();
    }

    /// Kiteline 自己（这个客户端进程）的 CPU（按单个核心计）和内存，3 秒采一次，只重画左边
    void Sample()
    {
        try
        {
            using var me = Process.GetCurrentProcess();
            var now = DateTime.UtcNow;
            var used = me.TotalProcessorTime;
            if (lastCpu is { } last && (now - last.At).TotalSeconds > 0.5)
                cpu = (used - last.Cpu).TotalSeconds / (now - last.At).TotalSeconds * 100;
            lastCpu = (used, now);
            memory = me.WorkingSet64 / 1048576.0;
        }
        catch { }
        BuildLeft();
    }

    async void RefreshPhones()
    {
        try
        {
            var status = await AppModel.Shared.Api.Get("/api/desktop/status");
            Lang.Use(status.Str("uiLanguage"));
            VirtualScreenState.Shared.Apply(status.Obj("virtualScreen"));
            var count = status.Int("clients") ?? 0;
            if (count != phones) { phones = count; BuildLeft(); }
        }
        catch { }
    }

    static Tap Item(Control content, string tip, Action? action) =>
        (Tap)new Tap(content, action, 4) { Height = 20, Padding = new Thickness(6, 0), VerticalAlignment = VerticalAlignment.Center }.Keys("Transparent", "Fill08").Tip(tip);

    void BuildLeft()
    {
        var model = AppModel.Shared;
        var online = model.Sources.Count(s => s.Online);
        var sessions = model.Sessions;
        var busy = sessions.Count(s => s.IsBusy);
        var waiting = sessions.Count(s => s.IsWaiting);
        var row = Ui.H(2,
            Item(Ui.H(5, Ui.Dot(7, online > 0 && model.Connected ? "Green" : "Red"), Ui.Text(L("%@/%@ 来源", online, model.Sources.Count), 11, color: "Text2").Digits()),
                L("来源：点击管理"), () => SettingsWindow.Open("sources")),
            Item(Ui.H(4, Ui.Sym("iphone", 11, "Text2"), Ui.Text(phones.ToString(), 11, color: "Text2").Digits()), L("已连接的手机：点击打开手机访问"), () => SettingsWindow.Open("phone")),
            Item(Ui.H(4, Ui.Sym("cpu", 11, "Text2"), Ui.Text(cpu is double c ? $"{c:0}%" : "—", 11, color: (cpu ?? 0) >= 50 ? "Orange" : "Text2").Digits(),
                    Ui.Text(L("内存 %@ MB", memory.ToString("0")), 11, color: "Text2").Digits()),
                L("Kiteline 本身占用的 CPU（按单个核心计）和内存"), null),
            Item(Ui.H(6, Ui.Sym("bubble.left.and.bubble.right", 11, "Text2"), Ui.Text(L("%@ 个会话", sessions.Count), 11, color: "Text2").Digits(),
                    busy > 0 ? Ui.H(3, Ui.Dot(6, "Accent"), Ui.Text(busy.ToString(), 11, color: "Accent").Digits()) : null,
                    waiting > 0 ? Ui.H(3, Ui.Dot(6, "Orange"), Ui.Text(waiting.ToString(), 11, color: "Orange").Digits()) : null),
                MainModel.Summary(sessions), () => Layout.SideTab = "sessions"));
        left.Content = row;
    }

    void BuildRight()
    {
        var row = Ui.H(2);
        if (tiles.Usage is { Tokens: > 0 } u)
            row.Children.Add(Item(Ui.Text(L("今日 %@ token", UsageFormat.Compact(u.Tokens)), 11, color: "Text2").Digits(), L("今日用量：点击查看"), () => PagePopup.Show(MainModel.UsageId)));
        foreach (var device in tiles.Limits)
        {
            var parts = new List<Control>();
            foreach (var agent in device.Agents)
                foreach (var w in agent.Windows.Where(w => w.Kind is "five_hour" or "seven_day" or "day").Take(2))
                {
                    var pct = Math.Round(w.Percent);
                    parts.Add(Ui.Text($"{w.Label} {pct:0}%", 11, color: pct >= 80 ? "Red" : "Text2").Digits());
                }
            if (parts.Count == 0) continue;
            var name = device.Local ? L("本机") : Lang.Machine(device.Name);
            row.Children.Add(Item(Ui.H(5, [Ui.Text(name, 11, FontWeight.Medium, "Text2"), .. parts]), L("各台电脑的订阅额度：点击查看用量"), () => PagePopup.Show(MainModel.UsageId)));
        }
        row.Children.Add(Item(Ui.Sym("arrow.clockwise", 10.5, tiles.LimitsBusy ? "Accent" : "Text2"), L("刷新额度和今日用量"), tiles.RefreshLimits));
        right.Content = row;
    }
}

/// 分屏上面一排项目（同 Mac 版 ProjectStrip）：「全部」+ 打开过的项目，顺序固定（同浏览器标签）；点一个，下面整套标签换成这个项目的；
/// 「+」打开别的项目。铺在标题栏那一带，空白处拖窗口，右边让给界面切换按钮和窗口按钮
public sealed class ProjectStrip : Border
{
    readonly StackPanel row = new() { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };

    public ProjectStrip(Control buttons)
    {
        Height = MainWindow.TitlebarHeight;
        BorderThickness = new Thickness(0, 0, 0, 0.5);
        this.Res(BackgroundProperty, "TabStrip").Res(BorderBrushProperty, "Separator");
        var scroll = new ScrollViewer
        {
            Content = row, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled, VerticalAlignment = VerticalAlignment.Center,
        };
        var drag = new Border { Background = Brushes.Transparent };
        drag.PointerPressed += WindowChrome.DragWindow;
        buttons.VerticalAlignment = VerticalAlignment.Center;
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 0, MainWindow.CaptionWidth + MainWindow.CornerReserve + 6, 0);
        // 按钮靠右占住自己的宽度，项目格用剩下的（窄窗口时横着滚，不被按钮压住）
        var dock = new DockPanel();
        DockPanel.SetDock(buttons, Dock.Right);
        dock.Children.Add(buttons);
        dock.Children.Add(scroll.Margin(10, 0, 8, 0).HAlign(HorizontalAlignment.Left));
        Child = new Panel { Children = { drag, dock } };
        ProjectSpaces.Changed += Schedule;
        ProjectList.Changed += Schedule;
        ChatPanes.Shared.OpenKeysChanged += Schedule;
        AppModel.Shared.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppModel.Sessions)) Schedule(); };
        DetachedFromVisualTree += (_, _) => { ProjectSpaces.Changed -= Schedule; ProjectList.Changed -= Schedule; ChatPanes.Shared.OpenKeysChanged -= Schedule; };
        Build();
    }

    bool pending;

    void Schedule()
    {
        if (pending) return;
        pending = true;
        Dispatcher.UIThread.Post(() => { pending = false; Build(); }, DispatcherPriority.Background);
    }

    void Build()
    {
        row.Children.Clear();
        var current = ProjectSpaces.Current;
        row.Children.Add(Chip("", L("全部"), null, current.Length == 0, null));
        foreach (var id in ProjectSpaces.Opened)
        {
            var project = ProjectList.Get(id);
            var name = project?.Name ?? System.IO.Path.GetFileName(id.Split('\n').Last().TrimEnd('/', '\\'));
            var live = project is null ? [] : ProjectList.Live(project);
            var dot = live.Any(s => s.IsWaiting) ? "Orange" : live.Any(s => s.IsBusy) ? "Accent" : live.Count > 0 ? "Green" : "Text4";
            var tip = project is null ? name : $"{project.Name} · {project.SourceName} · {Format.ShortPath(project.Cwd)}";
            row.Children.Add(Chip(id, name, dot, current == id, tip));
        }
        var plus = new Tap(Ui.Sym("plus", 12, "Text2").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center), null, SideMetric.Radius) { Width = 26, Height = 26 }
            .Keys("Transparent", "Fill08").Tip(L("打开项目"));
        plus.Menu(PlusMenu);
        plus.Click = () => plus.ContextMenu?.Open(plus);
        row.Children.Add(plus);
    }

    /// 一格：选中 = 淡主题色底 + 细边（同会话标签的选中样子）；项目格悬停或选中时右边一个 ×
    static Control Chip(string id, string title, string? dot, bool on, string? tip)
    {
        var close = id.Length == 0 ? null : new Tap(Ui.Sym("xmark", 8, "Text2").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center), () => ProjectSpaces.Remove(id), 8)
            { Width = 16, Height = 16, Opacity = on ? 1 : 0 }.Keys("Transparent", "Fill10").Tip(L("从这一排移出（项目的标签仍会保留）"));
        var content = Ui.H(SideMetric.Gap,
            dot is null ? Ui.Sym("rectangle.split.3x1", 11, on ? "Accent" : "Text2") : Ui.Dot(7, dot),
            Ui.Text(title, 12, on ? FontWeight.SemiBold : FontWeight.Medium, on ? "Text" : "Text2").Trim().MaxW(180),
            ProjectSpaces.TabCount(id) is var n && n > 0 ? Ui.Text(n.ToString(), 10.5, color: "Text3").Digits() : null,
            close);
        var chip = new Tap(content, () => ProjectSpaces.Switch(id), SideMetric.Radius) { Height = 28, Padding = new Thickness(10, 0, close is null ? 10 : 5, 0), BorderThickness = new Thickness(1) };
        if (on) { chip.Keys("AccentFill14", "AccentFill14"); chip.Res(BorderBrushProperty, "AccentEdge32"); }
        else { chip.Keys("Transparent", "Fill06"); chip.BorderBrush = Brushes.Transparent; }
        if (close is not null)
        {
            chip.PointerEntered += (_, _) => close.Opacity = 1;
            chip.PointerExited += (_, _) => close.Opacity = on ? 1 : 0;
        }
        chip.Menu(() => id.Length == 0 ? [] : [Ui.Item(L("从这一排移出"), () => ProjectSpaces.Remove(id)), Ui.Item(L("在项目栏中显示"), () => { Layout.OpenProject = id; Layout.SideTab = "projects"; })]);
        return chip.Tip(tip ?? L("所有项目的会话标签"));
    }

    /// 「+」：没在这一排的项目（活动中的在前），最后「新建任务…」
    static IEnumerable<Control> PlusMenu()
    {
        var opened = ProjectSpaces.Opened.ToHashSet();
        var rest = ProjectList.Items.Where(p => !opened.Contains(p.Id)).OrderByDescending(ProjectList.Active).ThenByDescending(p => p.LastActive).Take(20).ToList();
        foreach (var p in rest)
            yield return Ui.Item($"{p.Name}  ·  {p.SourceName}", () => ProjectSpaces.Switch(p.Id));
        if (rest.Count > 0) yield return Ui.Divider();
        yield return Ui.Item(L("新建任务…"), () => MainModel.Shared.NewTask());
    }
}
