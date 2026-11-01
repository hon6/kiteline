using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// Kiteline 主窗口（同 Mac 版 MainWindowController + MainView）：左边会话列表，右边完整对话（可以分屏、开标签）。
/// Windows 上内容铺进标题栏（同 Mac 的统一工具栏）：最上面一排是侧栏顶端和标签栏，右上角留给系统的窗口按钮
public sealed class MainWindow : Window
{
    public static MainWindow? Current { get; private set; }
    /// 标题栏那一带的高度（同 Mac 的工具栏 52 点）
    public const double TitlebarHeight = 52;
    /// 右上角窗口按钮占的宽度（Windows 是系统的三个按钮，Linux 是自己画的）
    public static double CaptionWidth => WindowChrome.CaptionWidth;

    readonly AppModel model = AppModel.Shared;
    readonly MainModel main = MainModel.Shared;
    ContentControl detail = new();
    ColumnDefinition sidebarColumn = new();
    /// 左边栏和它右边的细线、拖宽度的把手：世界模式里收起会话列表时一起藏起来
    Control? sidebarPanel, sidebarLine, sidebarSplitter;
    /// 侧栏顶上的世界入口（进了世界底下一道主题色）
    WorldGlobe? globe;
    ToastLayer toast = new();
    SidebarGlass glass = new();
    /// Linux 自己画的外框：阴影、圆角裁剪、一圈细边
    Border? shadow, frame, edge;
    /// 最后获得键盘焦点的控件：窗口重新激活时还给它
    WeakReference<Control>? lastFocus;

    public MainWindow()
    {
        Current = this;
        Title = "Kiteline";
        Width = Prefs.Number("windowWidth") ?? 1120;
        Height = Prefs.Number("windowHeight") ?? 760;
        MinWidth = 820;
        MinHeight = 520;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Look.Family;
        if (OperatingSystem.IsWindows())
        {
            ExtendClientAreaToDecorationsHint = true;
            ExtendClientAreaChromeHints = ExtendClientAreaChromeHints.PreferSystemChrome;
            ExtendClientAreaTitleBarHeightHint = TitlebarHeight;
            // 窗口底用系统材质（同 Mac 的液态玻璃侧栏）：亚克力透出后面并模糊，其次云母。
            // Windows 10（亚克力拖动窗口会卡）、关了透明效果、没有显卡加速（虚拟机、远程桌面：系统只画一块灰底）时不透明
            if (WindowChrome.WindowsGlass)
            {
                TransparencyLevelHint = [WindowTransparencyLevel.AcrylicBlur, WindowTransparencyLevel.Mica, WindowTransparencyLevel.None];
                Background = Brushes.Transparent;
            }
            else this.Res(BackgroundProperty, "Window");
        }
        else if (WindowChrome.Custom)
        {
            SystemDecorations = SystemDecorations.None;
            TransparencyLevelHint = [WindowTransparencyLevel.Blur, WindowTransparencyLevel.Transparent, WindowTransparencyLevel.None];
            Background = Brushes.Transparent;
        }
        else this.Res(BackgroundProperty, "Window");

        // 模糊壁纸要跟着窗口在屏幕上的位置取
        PositionChanged += (_, _) => { if (SidebarGlass.Current == SidebarGlass.Mode.Wallpaper) glass.InvalidateVisual(); };
        // 有新版本时的绿色箭头在侧栏底栏里（SidebarFooter）；装好了弹窗问要不要现在重启
        UpdateState.Shared.Ready += UpdateDialog.Open;
        if (WindowChrome.Custom)
        {
            AddHandler(PointerPressedEvent, ResizePressed, Avalonia.Interactivity.RoutingStrategies.Tunnel);
            AddHandler(PointerMovedEvent, ResizeHover, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
            PropertyChanged += (_, e) => { if (e.Property == WindowStateProperty || e.Property == IsActiveProperty) UpdateFrame(); };
        }
        Build();
        Opened += (_, _) =>
        {
            WindowChrome.RoundCorners(this);
            UpdateGlass();
            UpdateFrame();
        };
        PropertyChanged += (_, e) => { if (e.Property == ActualTransparencyLevelProperty) UpdateGlass(); };

        main.PropertyChanged += SelectionChanged;
        main.NewTaskRequested += () => NewTaskSheet.Open(main.NewTaskPreset);
        ChatPanes.Shared.Changed += () =>
        {
            // 在右边点了另一块：左边栏跟着选中（空块 = 不选）
            var focused = ChatPanes.Shared.Focused;
            if (main.Selection is null || !main.Selection.StartsWith('@') || MainModel.GroupIdOf(main.Selection) is not null) { if (focused != main.Selection) main.Selection = focused; }
            UpdateDetail();
        };
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppModel.Toast)) ToastLayer.Present(model.Toast);
            if (e.PropertyName == nameof(AppModel.PendingOpen) && model.PendingOpen is string key) { model.PendingOpen = null; main.Selection = key; }
        };
        Look.Changed += () => { FontFamily = Look.Family; UpdateDetail(true); };
        // 换了界面语言：整个窗口按新语言重新搭一遍（同 Mac 版不用重启）
        Lang.Changed += () =>
        {
            Build();
            UpdateGlass();
        };
        KeyDown += OnKey;
        // 切到别的程序再切回来（投递把 VS Code 切到前台又还回来、Alt+Tab）：Avalonia 不会把键盘焦点还给原来的输入框，
        // 回来接着打字没反应（10-25 Windows 实测）。记下最后获得焦点的控件，窗口重新激活时焦点没了就还回去（同 Mac 版）
        AddHandler(GotFocusEvent, (_, e) => { if (e.Source is Control c) lastFocus = new WeakReference<Control>(c); },
            Avalonia.Interactivity.RoutingStrategies.Bubble, handledEventsToo: true);
        Activated += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            if (lastFocus?.TryGetTarget(out var c) == true && c.IsEffectivelyVisible && c.IsEffectivelyEnabled
                && Avalonia.VisualTree.VisualExtensions.IsAttachedToVisualTree(c) && FocusManager?.GetFocusedElement() is null or Window)
                c.Focus();
        });
        Closing += (_, _) =>
        {
            Prefs.Set("windowWidth", Width);
            Prefs.Set("windowHeight", Height);
            Prefs.Save();
        };
    }

    /// 搭窗口里的内容（第一次、换语言时）
    void Build()
    {
        var grid = new Grid();
        sidebarColumn = new ColumnDefinition(new GridLength(Prefs.Number("sidebarWidth") ?? SidebarView.Width0)) { MinWidth = 260, MaxWidth = 400 };
        grid.ColumnDefinitions.Add(sidebarColumn);
        grid.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
        glass = new SidebarGlass();
        var sidebar = new Panel { Children = { glass, new SidebarView(), SidebarTopBar() } };
        sidebarPanel = sidebar;
        Grid.SetColumn(sidebar, 0);
        // 顶上飞的纸鸢（透明小窗口挂在主窗口上沿，同 Mac 版）
        KiteOverlay.Attach(this, sidebar);
        // 侧栏右边一道细线；拖动改宽度的把手叠在右边内容的左缘（透明、不占地方，不然中间会露出一道缝）
        var line = new Border { Width = 1, HorizontalAlignment = HorizontalAlignment.Right, IsHitTestVisible = false }.Res(Border.BackgroundProperty, "SidebarEdge");
        Grid.SetColumn(line, 0);
        var splitter = new GridSplitter
        {
            Width = 6, MinWidth = 0, Margin = new Thickness(-3, 0, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, Background = Brushes.Transparent,
            ResizeDirection = GridResizeDirection.Columns, ResizeBehavior = GridResizeBehavior.PreviousAndCurrent,
        };
        splitter.DragCompleted += (_, _) => Prefs.Set("sidebarWidth", sidebarColumn.ActualWidth);
        Grid.SetColumn(splitter, 1);
        sidebarLine = line;
        sidebarSplitter = splitter;
        // 右边不透明（只有侧栏是玻璃）
        detail = new ContentControl();
        shownKind = null;
        // 世界模式（只在 Windows 能嵌网页时有）：世界那一层一直挂着，离开时藏起来、回来不重新加载
        var detailLayers = new Panel { Children = { detail } };
        if (World.Embedded)
        {
            var world = WorldPanel.Shared;
            if (world.Parent is Panel old) old.Children.Remove(world);
            detailLayers.Children.Add(world);
        }
        var detailBox = new Border { Child = detailLayers }.Res(Border.BackgroundProperty, "Window");
        Grid.SetColumn(detailBox, 1);
        grid.Children.Add(sidebar);
        grid.Children.Add(line);
        grid.Children.Add(detailBox);
        grid.Children.Add(splitter);
        toast = new ToastLayer();
        var body = new Panel { Children = { grid, toast } };
        if (WindowChrome.Custom)
        {
            var buttons = new CaptionButtons(this, WindowChrome.Buttons)
            {
                HorizontalAlignment = WindowChrome.ButtonsLeft ? HorizontalAlignment.Left : HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top, Height = TitlebarHeight,
            };
            body.Children.Add(buttons);
            // 阴影单独一层（同一元素上的阴影会吞掉后画的内容），圆角裁剪在 frame 上，细边盖在最上面
            // 阴影层要有实底才画得出阴影（被上面的 frame 盖住，看不到底色）
            shadow = new Border { CornerRadius = new CornerRadius(WindowChrome.Radius), IsHitTestVisible = false };
            shadow.Res(Border.BackgroundProperty, "Window");
            frame = new Border { CornerRadius = new CornerRadius(WindowChrome.Radius), Child = body };
            // Border 自己的裁剪只按直角：圆角按几何形状裁
            frame.SizeChanged += (_, _) => ClipFrame();
            edge = new Border { CornerRadius = new CornerRadius(WindowChrome.Radius), BorderThickness = new Thickness(1), IsHitTestVisible = false };
            edge.Res(Border.BorderBrushProperty, "WindowEdge");
            Content = new Panel { Children = { shadow, frame, edge } };
            UpdateFrame();
        }
        else Content = body;
        UpdateDetail();
        UpdateWorld();
        // 在会话以外的地方按下（侧栏、今日动态……）：接着弹的窗对着整个窗口居中（会话那一块按下时再设上，见 ChatPanesView）
        AddHandler(PointerPressedEvent, (_, _) => Dialog.Anchor = null, Avalonia.Interactivity.RoutingStrategies.Tunnel);
    }

    /// 侧栏顶上（标题栏那一带）：新任务按钮（Mac 上在红绿灯右边，这里没有红绿灯，靠左放）
    Control SidebarTopBar()
    {
        var compose = new Tap(Ui.Sym("square.and.pencil", 15, "Text"), () => main.NewTask(), 18)
        {
            Width = 36, Height = 36, BorderThickness = new Thickness(0.5),
        }.Keys("Glass", "Fill12").Tip(L("在指定项目中新建 Claude Code 会话"));
        compose.Res(Border.BorderBrushProperty, "GlassEdge");
        compose.Child!.HorizontalAlignment = HorizontalAlignment.Center;
        // 世界模式的入口：像素地球（鼠标移上去会转）；再点一下回到会话（Linux 上世界开在浏览器窗口里）
        globe = new WorldGlobe { Active = main.WorldMode, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var world = new Tap(globe, World.Toggle, 18) { Width = 36, Height = 36, BorderThickness = new Thickness(0.5) }.Keys("Glass", "Fill12");
        world.Res(Border.BorderBrushProperty, "GlassEdge");
        world.PointerEntered += (_, _) => globe.Hover(true);
        world.PointerExited += (_, _) => globe.Hover(false);
        world.Tip(main.WorldMode ? L("离开世界模式，回到会话（Ctrl+Shift+E）") : L("世界模式：机房、卫星和像素小人，一眼看全所有会话（Ctrl+Shift+E）"));
        var bar = Ui.H(8, compose, world).Margin(16 + WindowChrome.CaptionLeftWidth, 8, 16, 0);
        bar.VerticalAlignment = VerticalAlignment.Top;
        bar.HorizontalAlignment = HorizontalAlignment.Left;
        return bar;
    }

    /// 系统给了什么透明效果 → 侧栏用哪种玻璃
    void UpdateGlass()
    {
        var level = ActualTransparencyLevel;
        // Linux 上只有 KDE 真有窗口模糊（GNOME 报了 Blur 也只是透明）
        var realBlur = level == WindowTransparencyLevel.AcrylicBlur || level == WindowTransparencyLevel.Mica
            || (level == WindowTransparencyLevel.Blur && (!OperatingSystem.IsLinux() || (Environment.GetEnvironmentVariable("XDG_CURRENT_DESKTOP") ?? "").Contains("KDE", StringComparison.OrdinalIgnoreCase)));
        if (realBlur)
            SidebarGlass.Use(SidebarGlass.Mode.System);
        else if ((level == WindowTransparencyLevel.Transparent || level == WindowTransparencyLevel.Blur) && OperatingSystem.IsLinux())
        {
            SidebarGlass.Use(SidebarGlass.Mode.Wallpaper);
            if (Screens.ScreenFromWindow(this) is { } screen) Wallpaper.Load(screen.Bounds.Size, ActualThemeVariant == Avalonia.Styling.ThemeVariant.Dark);
        }
        else
        {
            SidebarGlass.Use(SidebarGlass.Mode.Opaque);
            if (!OperatingSystem.IsLinux()) this.Res(BackgroundProperty, "Window");
        }
        UpdateFrame();
    }

    bool Rounded => WindowState == WindowState.Normal && ActualTransparencyLevel != WindowTransparencyLevel.None;

    /// Linux 外框：正常大小时四周留阴影、圆角；最大化 / 全屏 / 不能透明时铺满、直角
    void UpdateFrame()
    {
        if (frame is null || shadow is null || edge is null) return;
        var rounded = Rounded;
        var margin = rounded ? new Thickness(WindowChrome.ShadowMargin) : default;
        var radius = new CornerRadius(rounded ? WindowChrome.Radius : 0);
        foreach (var b in new[] { shadow, frame, edge }) { b.Margin = margin; b.CornerRadius = radius; }
        edge.IsVisible = rounded;
        ClipFrame();
        shadow.BoxShadow = rounded
            ? new BoxShadows(new BoxShadow { OffsetY = IsActive ? 6 : 3, Blur = IsActive ? 26 : 14, Color = Palette.Color(0, IsActive ? 0.5 : 0.3) },
                             [new BoxShadow { Blur = 2, Spread = 0.5, Color = Palette.Color(0, 0.18) }])
            : default;
    }

    void ClipFrame()
    {
        if (frame is null) return;
        var r = frame.CornerRadius.TopLeft;
        frame.Clip = new RectangleGeometry(new Rect(frame.Bounds.Size), r, r);
    }

    /// 四周（阴影那一圈加往里 4 点）按下 → 拖边改大小
    WindowEdge? EdgeAt(Point p)
    {
        if (WindowState != WindowState.Normal) return null;
        var grip = (Rounded ? WindowChrome.ShadowMargin : 0) + 5;
        var corner = grip + 10;
        double w = Bounds.Width, h = Bounds.Height;
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

    void ResizePressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed || EdgeAt(e.GetPosition(this)) is not WindowEdge edgeHit) return;
        BeginResizeDrag(edgeHit, e);
        e.Handled = true;
    }

    WindowEdge? hoverEdge;

    void ResizeHover(object? sender, PointerEventArgs e)
    {
        var at = EdgeAt(e.GetPosition(this));
        if (at == hoverEdge) return;
        hoverEdge = at;
        Cursor = at switch
        {
            WindowEdge.North or WindowEdge.South => new Cursor(StandardCursorType.SizeNorthSouth),
            WindowEdge.West or WindowEdge.East => new Cursor(StandardCursorType.SizeWestEast),
            WindowEdge.NorthWest => new Cursor(StandardCursorType.TopLeftCorner),
            WindowEdge.NorthEast => new Cursor(StandardCursorType.TopRightCorner),
            WindowEdge.SouthWest => new Cursor(StandardCursorType.BottomLeftCorner),
            WindowEdge.SouthEast => new Cursor(StandardCursorType.BottomRightCorner),
            _ => Cursor.Default,
        };
    }

    void SelectionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainModel.Selection)) UpdateDetail();
        if (e.PropertyName is nameof(MainModel.WorldMode) or nameof(MainModel.SidebarCollapsed)) UpdateWorld();
    }

    /// 进出世界、收起会话列表（同 Mac 版 SidebarState）：世界那一层盖住平时的右边；收起时侧栏那一列宽度归零，世界占满窗口
    void UpdateWorld()
    {
        var on = main.WorldMode && World.Embedded;
        detail.IsVisible = !on;
        if (WorldPanel.Current is { } world) world.IsVisible = on;
        if (globe is not null)
        {
            globe.Active = on;
            if (globe.Parent is Tap tap) tap.Tip(on ? L("离开世界模式，回到会话（Ctrl+Shift+E）") : L("世界模式：机房、卫星和像素小人，一眼看全所有会话（Ctrl+Shift+E）"));
        }
        var collapsed = on && main.SidebarCollapsed;
        foreach (var c in new[] { sidebarPanel, sidebarLine, sidebarSplitter }) if (c is not null) c.IsVisible = !collapsed;
        KiteOverlay.Shared?.Refresh();
        sidebarColumn.MinWidth = collapsed ? 0 : 260;
        sidebarColumn.Width = new GridLength(collapsed ? 0 : Prefs.Number("sidebarWidth") ?? SidebarView.Width0);
    }

    string? shownKind;

    /// 右边显示什么（同 Mac 版 DetailView）
    void UpdateDetail(bool force = false)
    {
        var selection = main.Selection;
        var kind = selection switch
        {
            MainModel.TodayId => "today",
            MainModel.HistoryId => "history",
            MainModel.UsageId => "usage",
            MainModel.ProjectsId => "projects",
            MainModel.TodosId => "todos",
            MainModel.FavoritesId => "favorites",
            MainModel.GroupsId => "groups",
            // 选中的是会话、群（同会话一样开成分屏里的一个标签）
            _ when selection is not null || !ChatPanes.Shared.IsPristine => "chat",
            _ => "welcome",
        };
        if (kind == shownKind && !force) return;
        shownKind = kind;
        detail.Content = kind switch
        {
            "chat" => new ChatPanesView(),
            "today" => Pages.Today(),
            "history" => Pages.History(),
            "usage" => Pages.Usage(),
            "projects" => Pages.Projects(),
            "todos" => Pages.Todos(),
            "favorites" => Pages.Favorites(),
            "groups" => new GroupsPage(),
            _ => new WelcomeView(),
        };
    }

    void OnKey(object? sender, KeyEventArgs e)
    {
        var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        var shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        var panes = ChatPanes.Shared;
        // 同浏览器：Ctrl+T 新标签、Ctrl+W 关标签、Ctrl+Tab / Ctrl+Shift+Tab 切换、Ctrl+1…9 跳转（Mac 上是 ⌘）
        if (ctrl && e.Key == Key.T) { panes.NewTab(panes.FocusId); main.Selection = null; e.Handled = true; }
        else if (ctrl && e.Key == Key.W && !shift)
        {
            if (panes.PaneById(panes.FocusId) is { } pane) panes.CloseTab(pane.Id, pane.Key);
            e.Handled = true;
        }
        else if (ctrl && e.Key == Key.Tab && panes.PaneById(panes.FocusId) is { Tabs.Count: > 1 } p)
        {
            var i = p.Key is string k ? p.Tabs.IndexOf(k) : -1;
            var next = shift ? (i <= 0 ? p.Tabs.Count - 1 : i - 1) : (i + 1) % p.Tabs.Count;
            panes.Activate(p.Id, p.Tabs[next]);
            e.Handled = true;
        }
        else if (ctrl && e.Key >= Key.D1 && e.Key <= Key.D9 && panes.PaneById(panes.FocusId) is { } q && q.Tabs.Count > 0)
        {
            var n = e.Key - Key.D1;
            panes.Activate(q.Id, e.Key == Key.D9 ? q.Tabs[^1] : q.Tabs[Math.Min(n, q.Tabs.Count - 1)]);
            e.Handled = true;
        }
        // Ctrl+Shift+[ / ]：上一个 / 下一个标签（同 Mac 版 ⇧⌘[ / ⇧⌘]）
        else if (ctrl && shift && e.Key is Key.OemOpenBrackets or Key.OemCloseBrackets && panes.PaneById(panes.FocusId) is { Tabs.Count: > 1 } b)
        {
            var i = b.Key is string k ? b.Tabs.IndexOf(k) : -1;
            panes.Activate(b.Id, b.Tabs[e.Key == Key.OemOpenBrackets ? (i <= 0 ? b.Tabs.Count - 1 : i - 1) : (i + 1) % b.Tabs.Count]);
            e.Handled = true;
        }
        else if (ctrl && e.Key == Key.N) { main.NewTask(); e.Handled = true; }
        // Ctrl+Shift+E：进出世界（同 Mac 版 ⇧⌘E）；Esc：关掉世界里点开的会话
        else if (ctrl && shift && e.Key == Key.E) { World.Toggle(); e.Handled = true; }
        else if (e.Key == Key.Escape && main.WorldMode && main.WorldDetail is not null) { main.WorldDetail = null; e.Handled = true; }
        else if (ctrl && e.Key == Key.Y) { main.Selection = MainModel.HistoryId; e.Handled = true; }   // 历史会话（同 Mac 版 ⌘Y）
        else if (ctrl && e.Key == Key.OemComma) { SettingsWindow.Open("general"); e.Handled = true; }
        // 对右边正在看的会话（同 Mac 版「会话」菜单）：Ctrl+F 在对话里搜索、Ctrl+I 会话信息、Ctrl+. 中断、Ctrl+` 切换终端
        // （搜索已经结束的对话也行；会话信息、中断要会话还在）
        else if (ctrl && !shift && e.Key is Key.F or Key.I or Key.OemPeriod or Key.Oem3 && panes.PaneById(panes.FocusId)?.Key is string focused)
        {
            var session = AppModel.Shared.Session(focused);
            if (e.Key == Key.F) ChatActions.Perform(focused, SessionAction.Search);
            else if (e.Key == Key.Oem3 && session?.Can("term") == true) ChatActions.Perform(focused, SessionAction.Terminal);   // Ctrl+`：切换终端（同 VS Code）
            else if (e.Key == Key.I && session is not null) ChatActions.Perform(focused, SessionAction.Info);
            else if (e.Key == Key.OemPeriod && session is { IsBusy: true }) ChatActions.Perform(focused, SessionAction.Stop);
            e.Handled = true;
        }
    }
}

/// 什么都没选时右边的欢迎页（同 Mac 版 WelcomeView）
public sealed class WelcomeView : Panel
{
    public WelcomeView()
    {
        AppModel.Shared.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppModel.Sessions)) Build(); };
        Build();
    }

    void Build()
    {
        Children.Clear();
        var model = AppModel.Shared;
        var main = MainModel.Shared;
        var icon = new KiteIcon(128);
        var first = model.Sessions.FirstOrDefault(s => s.IsWaiting) ?? model.Sessions.FirstOrDefault(s => s.IsBusy) ?? model.Sessions.FirstOrDefault();
        var buttons = Ui.H(12,
            first is null ? null : new GlassButton(L("打开「%@」", first.Title), "bubble.left.and.text.bubble.right", () => main.Selection = first.Key, prominent: true, height: 32),
            new GlassButton(L("在手机上使用"), "iphone.gen3", () => SettingsWindow.Open("phone"), height: 32));
        var stack = Ui.Stack(Orientation.Vertical, 18, Align.Center, [
            icon,
            Ui.Stack(Orientation.Vertical, 6, Align.Center, [Ui.Text("Kiteline", 30, FontWeight.Bold), Ui.Text(MainModel.Summary(model.Sessions), 15, color: "Text2")]),
            buttons,
        ]);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        // 顶上标题栏那一带按住能拖动窗口、双击最大化（同 Mac 的工具栏）
        var titlebar = new Border { Height = MainWindow.TitlebarHeight, VerticalAlignment = VerticalAlignment.Top, Background = Brushes.Transparent };
        titlebar.PointerPressed += WindowChrome.DragWindow;
        Children.Add(titlebar);
        Children.Add(stack);
    }
}

/// App 图标：圆角方块里一只纸鸢（同 Mac 的 App 图标），底下一层柔和的阴影
public sealed class KiteIcon : Panel
{
    public KiteIcon(double size)
    {
        Width = size;
        Height = size;
        var inset = size * 0.06;
        // 阴影单独一层（和内容画在同一个元素上时，2 倍离屏截图里内容会画不出来）
        Children.Add(new Border
        {
            Margin = new Thickness(inset), CornerRadius = new CornerRadius(size * 0.22), Background = Brushes.Transparent,
            BoxShadow = new BoxShadows(new BoxShadow { OffsetY = 8, Blur = 18, Color = Palette.Color(0, 0.25) }),
        });
        Children.Add(new Art(size));
    }

    sealed class Art(double size) : Control
    {
        public override void Render(DrawingContext context)
        {
            var rect = new Rect(0, 0, size, size).Deflate(size * 0.06);
            context.DrawRectangle(new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Palette.Color(0x2B2B2E), 0), new GradientStop(Palette.Color(0x1C1C1E), 1) },
            }, null, rect, size * 0.22, size * 0.22);
            KiteMark.DrawStill(context, rect.Deflate(size * 0.16), Palette.Get("Accent"), full: true);
        }
    }
}

/// 一闪而过的提示（同 Mac 版 KitelineKit.flash 的小提示）：窗口底部正中一块深色圆角
public sealed class ToastLayer : Panel
{
    readonly Border pill;
    readonly TextBlock text;
    static readonly List<ToastLayer> Layers = [];

    /// bottom = 提示离窗口底边多远（主窗口让开输入框，弹窗贴近底边）
    public ToastLayer(double bottom = 90)
    {
        IsHitTestVisible = false;
        text = Ui.Text("", 13, FontWeight.Medium, "White", lines: 2).Wrap();
        text.TextAlignment = TextAlignment.Center;
        pill = new Border
        {
            Child = text, Padding = new Thickness(16, 9), CornerRadius = new CornerRadius(12), MaxWidth = 460,
            Background = new SolidColorBrush(Palette.Color(0x1C1C1E, 0.92)),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, bottom), IsVisible = false,
        };
        Children.Add(pill);
        AttachedToVisualTree += (_, _) => Layers.Add(this);
        DetachedFromVisualTree += (_, _) => Layers.Remove(this);
    }

    /// 提示显示在当前活动的窗口里（弹窗、设置窗口挡着主窗口时也看得到）；Kiteline 的窗口都不在前台时显示在主窗口
    public static void Present(string? message)
    {
        var target = Layers.FirstOrDefault(l => TopLevel.GetTopLevel(l) is Window { IsActive: true })
                     ?? Layers.FirstOrDefault(l => TopLevel.GetTopLevel(l) is MainWindow);
        foreach (var layer in Layers.ToList()) layer.Show(layer == target ? message : null);
    }

    public void Show(string? message)
    {
        pill.IsVisible = !string.IsNullOrEmpty(message);
        text.Text = message ?? "";
    }
}
