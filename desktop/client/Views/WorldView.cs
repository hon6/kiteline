using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using Microsoft.Web.WebView2.Core;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 世界模式（同 Mac 版 Sources/WorldView.swift）：机房 = agent、卫星 = 设备、方块人 = 会话的像素世界。网页各端共用一份（Resources/world），
/// 电脑端后台在 /world/ 上提供，网页自己连后台取状态、收实时事件、发私聊（world.md（内部文档）「直连模式」）。
/// Windows 用系统的 WebView2 嵌在右边整块（Win11 自带运行时）；Linux 上 Avalonia 嵌不了网页，开成单独的浏览器应用窗口。
/// 网页里点屏幕 / 卫星 / 门：WebView2 里经 postMessage 交给这里；浏览器窗口里经后台 POST /api/world/intent → 实时事件 world_intent 回来
public static class World
{
    static bool? embedded;

    /// 能把网页嵌进主窗口（Windows 装了 WebView2 运行时）；不能就开浏览器窗口
    public static bool Embedded => embedded ??= OperatingSystem.IsWindows() && WorldWeb.RuntimeVersion() is not null;

    /// 网页地址：后台 /world/，带主令牌（网页自己连后台）、界面语言、主题色。page = world（像素园区）/ flow（数据流大屏）
    public static Uri Url(string page = "world")
    {
        var api = AppModel.Shared.Api;
        var accent = Palette.GetColor("Accent");
        var query = $"t={Uri.EscapeDataString(api.Token)}&lang={(IsEnglish ? "en" : "zh")}&brand=%23{accent.R:X2}{accent.G:X2}{accent.B:X2}";
        return new Uri(api.Base, $"world/{(page == "flow" ? "flow" : "index")}.html?" + query);
    }

    /// 侧栏上的地球、Ctrl+Shift+E：能嵌就进出世界模式，不能嵌就打开浏览器窗口
    public static void Toggle() => MainModel.Shared.ToggleWorld("world");

    /// 侧栏上的数据流、Ctrl+Shift+D：同上，换成数据流大屏那一页
    public static void ToggleFlow() => MainModel.Shared.ToggleWorld("flow");

    /// 浏览器窗口里打开：有 Chrome / Chromium / Edge 就开成没有地址栏的应用窗口（像单独一个程序），没有就交给默认浏览器
    public static void OpenWindow(string page = "world")
    {
        var url = Url(page).ToString();
        foreach (var exe in AppBrowsers())
        {
            try
            {
                var start = new ProcessStartInfo(exe) { UseShellExecute = false };
                start.ArgumentList.Add("--app=" + url);
                start.ArgumentList.Add("--new-window");
                start.Environment.Remove("LD_LIBRARY_PATH");   // 别把打包版自己的库路径带给浏览器
                Process.Start(start);
                AppModel.Shared.Flash(page == "flow" ? L("数据流大屏已在新窗口中打开") : L("世界已在新窗口中打开"));
                return;
            }
            catch { }
        }
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            AppModel.Shared.Flash(page == "flow" ? L("数据流大屏已在浏览器中打开") : L("世界已在浏览器中打开"));
        }
        catch (Exception e) { AppModel.Shared.Flash(L("无法打开浏览器：%@", e.Message)); }
    }

    static IEnumerable<string> AppBrowsers()
    {
        if (OperatingSystem.IsWindows())
        {
            foreach (var root in new[] { Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.ProgramFiles })
            {
                var edge = Path.Combine(Environment.GetFolderPath(root), "Microsoft", "Edge", "Application", "msedge.exe");
                if (File.Exists(edge)) { yield return edge; yield break; }
            }
            yield break;
        }
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(':', StringSplitOptions.RemoveEmptyEntries);
        foreach (var name in new[] { "google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge", "microsoft-edge-stable", "brave-browser" })
            if (dirs.Select(d => Path.Combine(d, name)).FirstOrDefault(File.Exists) is string found) yield return found;
    }

    /// 左边栏点了会话：世界里镜头飞过去
    public static void Focus(string key) => WorldPanel.Current?.Post(new JsonObject { ["type"] = "focus", ["key"] = key });

    /// 网页里点了什么：WebView2 的 postMessage，或浏览器窗口经后台转回来的实时事件 world_intent
    public static void Intent(JsonNode? json)
    {
        var main = MainModel.Shared;
        switch (json.Str("type"))
        {
            case "open" when json.Str("key") is string key:
                // 世界嵌在主窗口里：对话页排在世界右边；浏览器窗口里点的：主窗口打开这个会话、提到前面
                if (main.WorldMode) main.WorldDetail = key;
                else { main.Selection = key; Bring(); }
                break;
            case "machine" when json.Str("sourceId") is string id:
                if (!main.WorldMode) Bring();
                AgentDetails.OpenMachine(id, AppModel.Shared.Sources.FirstOrDefault(s => s.Id == id)?.Name ?? "");
                break;
            case "exit":
                main.SetWorld(false);
                break;
        }
    }

    static void Bring()
    {
        if (MainWindow.Current is not { } window) return;
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }
}

/// 世界模式时右边整块（只在 Windows 上有）：顶上一条（离开世界、收起会话列表、标题；空白处按住拖窗口），下面是网页；
/// 点了某人的屏幕，这个会话的对话页排在网页右边。WebView2 是原生子窗口，Avalonia 画的东西盖不到它上面，所以并排放、不浮在上面。
/// 只建一个（离开世界时藏起来、网页停画，回来不重新加载）
public sealed class WorldPanel : Grid
{
    public static WorldPanel? Current { get; private set; }
    public static WorldPanel Shared => Current ??= new WorldPanel();

    readonly MainModel main = MainModel.Shared;
    readonly WorldWeb web = new();
    readonly Panel stage = new();
    readonly ColumnDefinition cardColumn = new(new GridLength(0));
    readonly Border cardBox = new() { IsVisible = false, BorderThickness = new Thickness(1, 0, 0, 0) };
    readonly Tap sidebarButton;
    readonly Tap door;
    readonly TextBlock title;
    ChatView? card;

    WorldPanel()
    {
        RowDefinitions = new RowDefinitions($"{MainWindow.TitlebarHeight},*");
        this.Res(BackgroundProperty, "Window");
        web.Message += World.Intent;
        web.Failed += ShowFailure;

        // 顶上一条：同 Mac 工具栏上的「离开世界」「收起会话列表」
        door = Bar("door.left.hand.open", L("离开"), () => main.SetWorld(false));
        sidebarButton = Bar("sidebar.left", "", () => main.SidebarCollapsed = !main.SidebarCollapsed);
        title = Ui.Text("", 14, FontWeight.SemiBold);
        title.VerticalAlignment = VerticalAlignment.Center;
        var drag = new Border { Background = Brushes.Transparent };
        drag.PointerPressed += WindowChrome.DragWindow;
        var buttons = Ui.H(6, sidebarButton, door, new Border { Width = 6 }, title);
        buttons.Margin = new Thickness(12, 0, MainWindow.CaptionWidth + 8, 0);
        buttons.VerticalAlignment = VerticalAlignment.Center;
        buttons.HorizontalAlignment = HorizontalAlignment.Left;
        var line = new Border { Height = 1, VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false }.Res(Border.BackgroundProperty, "Separator");
        Children.Add(new Panel { Children = { drag, buttons, line } });

        // 下面：网页 | 点开的会话
        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
        body.ColumnDefinitions.Add(cardColumn);
        stage.Background = new SolidColorBrush(StageColor(main.WorldPage));
        stage.Children.Add(web);
        body.Children.Add(stage);
        cardBox.Res(Border.BorderBrushProperty, "Separator");
        Grid.SetColumn(cardBox, 1);
        body.Children.Add(cardBox);
        SetRow(body, 1);
        Children.Add(body);

        body.SizeChanged += (_, e) => SizeCard(e.NewSize.Width);
        main.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainModel.WorldDetail)) ShowCard(main.WorldDetail);
            if (e.PropertyName == nameof(MainModel.SidebarCollapsed)) UpdateSidebarButton();
            if (e.PropertyName == nameof(MainModel.WorldMode)) web.SetShown(main.WorldMode);
            if (e.PropertyName == nameof(MainModel.WorldPage)) UpdatePage(true);
        };
        UpdatePage(false);
        UpdateSidebarButton();
        web.SetShown(main.WorldMode);
    }

    /// 发给网页（World.receive）
    public void Post(JsonObject message) => web.Post(message);

    static Avalonia.Media.Color StageColor(string page) => page == "flow" ? Avalonia.Media.Color.FromRgb(0x06, 0x07, 0x0B) : Avalonia.Media.Color.FromRgb(0x2A, 0x2B, 0x2F);

    /// 换页（地球 ↔ 数据流）：标题、门的提示、底色跟着换，网页重新加载那一页
    void UpdatePage(bool reload)
    {
        var flow = main.WorldPage == "flow";
        title.Text = flow ? L("数据流") : L("世界");
        door.Tip(flow ? L("离开数据流大屏，回到会话（Ctrl+Shift+D）") : L("离开世界模式，回到会话（Ctrl+Shift+E）"));
        stage.Background = new SolidColorBrush(StageColor(main.WorldPage));
        if (reload) web.Navigate(World.Url(main.WorldPage).ToString());
    }

    static Tap Bar(string symbol, string text, Action click)
    {
        Control content = text.Length == 0
            ? Ui.Sym(symbol, 15, "Text")
            : Ui.H(6, Ui.Sym(symbol, 15, "Text"), Ui.Text(text, 13, FontWeight.Medium));
        content.HorizontalAlignment = HorizontalAlignment.Center;
        content.VerticalAlignment = VerticalAlignment.Center;
        var tap = new Tap(new Border { Child = content, Padding = new Thickness(text.Length == 0 ? 0 : 10, 0) }, click, 8)
        {
            MinWidth = 32, Height = 32,
        }.Keys("Transparent", "Fill08", "Fill12");
        return tap;
    }

    void UpdateSidebarButton() => sidebarButton.Tip(main.SidebarCollapsed ? L("展开会话列表") : L("收起会话列表"));

    /// 点开的会话：宽度同 Mac（右边一半，480～860）；窗口窄时给世界留一块
    void SizeCard(double width)
    {
        if (main.WorldDetail is null) { cardColumn.Width = new GridLength(0); return; }
        var w = Math.Clamp(width * 0.5, Math.Min(420, width * 0.6), 860);
        cardColumn.Width = new GridLength(Math.Round(w));
    }

    void ShowCard(string? key)
    {
        if (card is not null && card.Key == key) return;
        card?.Closed();
        card = null;
        cardBox.Child = null;
        cardBox.IsVisible = key is not null;
        if (key is not null)
        {
            card = new ChatView(key);
            var name = AppModel.Shared.Session(key)?.Title ?? AppModel.Shared.PastMeta.GetValueOrDefault(key)?.Title ?? L("会话");
            var head = Ui.Text(name, 13, FontWeight.SemiBold).Trim().Shrink();
            head.VerticalAlignment = VerticalAlignment.Center;
            var inMain = Bar("macwindow", L("在主窗口中打开"), () =>
            {
                main.SetWorld(false);
                main.Selection = key;
            });
            var close = Bar("xmark", "", () => main.WorldDetail = null).Tip(L("关闭（Esc）"));
            var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto"), Height = 44, Margin = new Thickness(14, 0, 8, 0) };
            header.Children.Add(head);
            Grid.SetColumn(inMain, 1);
            Grid.SetColumn(close, 2);
            header.Children.Add(inMain);
            header.Children.Add(close);
            var line = new Border { Height = 1 }.Res(Border.BackgroundProperty, "Separator");
            var column = new DockPanel();
            DockPanel.SetDock(header, Dock.Top);
            DockPanel.SetDock(line, Dock.Top);
            column.Children.Add(header);
            column.Children.Add(line);
            column.Children.Add(card);
            column.Res(BackgroundProperty, "ChatBackground");
            cardBox.Child = column;
        }
        SizeCard(stage.Bounds.Width + cardColumn.ActualWidth);
    }

    /// 网页没加载起来（WebView2 坏了、后台太旧没有 /world/）：说明原因，给个「在浏览器中打开」
    void ShowFailure(string reason)
    {
        stage.Children.Clear();
        var box = Ui.Stack(Orientation.Vertical, 12, Align.Center, [
            Ui.Text(L("无法加载世界"), 17, FontWeight.SemiBold, "White"),
            Ui.Text(reason, 13, color: "White", lines: 4).Wrap(),
            new GlassButton(L("在浏览器中打开"), "arrow.up.forward.app", () => World.OpenWindow(main.WorldPage), height: 32),
        ]);
        box.MaxWidth = 420;
        box.HorizontalAlignment = HorizontalAlignment.Center;
        box.VerticalAlignment = VerticalAlignment.Center;
        stage.Children.Add(box);
    }
}

/// WebView2 嵌在 Avalonia 里（Windows）：NativeControlHost 给一个子窗口，WebView2 的控制器挂在上面、跟着它改大小。
/// 网页 → 这里：chrome.webview.postMessage（对象）；这里 → 网页：World.receive(…)
public sealed class WorldWeb : NativeControlHost
{
    CoreWebView2Controller? controller;
    IntPtr hwnd;
    bool shown;
    bool active = true;
    /// 网页还没加载好时要发的消息（加载好了一起发）
    readonly List<string> queued = [];
    bool loaded;
    TopLevel? top;

    public event Action<JsonNode?>? Message;
    public event Action<string>? Failed;

    /// 装了的 WebView2 运行时版本；没装、或不是 Windows 返回 null
    public static string? RuntimeVersion()
    {
        if (!OperatingSystem.IsWindows()) return null;
        try { return CoreWebView2Environment.GetAvailableBrowserVersionString(); }
        catch { return null; }
    }

    protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent)
    {
        var handle = base.CreateNativeControlCore(parent);
        hwnd = handle.Handle;
        _ = Start(hwnd);
        return handle;
    }

    protected override void DestroyNativeControlCore(IPlatformHandle control)
    {
        hwnd = IntPtr.Zero;
        loaded = false;
        controller?.Close();
        controller = null;
        base.DestroyNativeControlCore(control);
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        top = TopLevel.GetTopLevel(this);
        if (top is Window window)
        {
            window.PositionChanged += Moved;
            window.PropertyChanged += WindowChanged;
        }
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        if (top is Window window)
        {
            window.PositionChanged -= Moved;
            window.PropertyChanged -= WindowChanged;
        }
        top = null;
        base.OnDetachedFromVisualTree(e);
    }

    async Task Start(IntPtr parent)
    {
        try
        {
            // 用户数据（缓存、网页存的设置）放 %LOCALAPPDATA%\Kiteline\WebView2：程序目录可能不能写；
            // 朗读要不经点击就能放声音
            var data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Kiteline", "WebView2");
            var options = new CoreWebView2EnvironmentOptions("--autoplay-policy=no-user-gesture-required");
            var env = await CoreWebView2Environment.CreateAsync(null, data, options);
            var made = await env.CreateCoreWebView2ControllerAsync(parent);
            if (hwnd != parent) { made.Close(); return; }   // 等的时候子窗口已经没了（离开、换语言重搭窗口）
            controller = made;
            made.DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, 0x2A, 0x2B, 0x2F);
            var core = made.CoreWebView2;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsZoomControlEnabled = false;
            core.Settings.AreDevToolsEnabled = Environment.GetEnvironmentVariable("KITELINE_WORLD_DEVTOOLS") == "1";
            core.WebMessageReceived += (_, e) =>
            {
                JsonNode? json;
                try { json = JsonNode.Parse(e.WebMessageAsJson); } catch { return; }
                Message?.Invoke(json);
            };
            // 网页里的外链：交给默认浏览器，不在世界里开新窗口
            core.NewWindowRequested += (_, e) =>
            {
                e.Handled = true;
                try { Process.Start(new ProcessStartInfo(e.Uri) { UseShellExecute = true }); } catch { }
            };
            core.NavigationCompleted += (_, e) =>
            {
                if (!e.IsSuccess) { Failed?.Invoke(L("网页加载失败（%@）。请确认电脑端是最新版本。", e.WebErrorStatus.ToString())); return; }
                loaded = true;
                foreach (var script in queued) _ = core.ExecuteScriptAsync(script);
                queued.Clear();
                SendActive();
            };
            // 焦点在网页里时 Ctrl+Shift+E / D 也能离开世界、数据流（键先到 WebView2，不经过 Avalonia）
            made.AcceleratorKeyPressed += (_, e) =>
            {
                if (e.KeyEventKind != CoreWebView2KeyEventKind.KeyDown || !Down(0x11) || !Down(0x10)) return;
                if (e.VirtualKey == 'E') { e.Handled = true; Dispatcher.UIThread.Post(World.Toggle); }
                else if (e.VirtualKey == 'D') { e.Handled = true; Dispatcher.UIThread.Post(World.ToggleFlow); }
            };
            Resize();
            made.IsVisible = shown;
            core.Navigate(World.Url(MainModel.Shared.WorldPage).ToString());
        }
        catch (Exception e)
        {
            Failed?.Invoke(e.Message);
        }
    }

    [DllImport("user32.dll")]
    static extern short GetKeyState(int key);
    static bool Down(int key) => (GetKeyState(key) & 0x8000) != 0;

    /// 发给网页：World.receive(消息)；还没加载好就先排着
    public void Post(JsonObject message)
    {
        var script = "window.World && World.receive(" + message.ToJsonString(new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) + ")";
        if (controller is { } c && loaded) _ = c.CoreWebView2.ExecuteScriptAsync(script);
        else queued.Add(script);
    }

    /// 换一页（地球 ↔ 数据流）：同一个 WebView2 重新加载；没建好时建好会按当前页面加载
    public void Navigate(string url)
    {
        if (controller is not { } c) return;
        loaded = false;
        queued.Clear();
        c.CoreWebView2.Navigate(url);
    }

    /// 进出世界：藏起来时网页停画（WebView2 看不见时页面是 hidden）。
    /// 键盘焦点跟着走：进来交给网页（W A S D 直接能用），离开时还给主窗口——不然焦点留在藏起来的网页里，按键（再按 Ctrl+Shift+E）没反应
    public void SetShown(bool value)
    {
        shown = value;
        if (controller is { } c)
        {
            c.IsVisible = value;
            if (value) c.MoveFocus(CoreWebView2MoveFocusReason.Programmatic);
        }
        if (!value && top?.TryGetPlatformHandle()?.Handle is IntPtr main && main != IntPtr.Zero) SetFocus(main);
        SendActive();
    }

    [DllImport("user32.dll")]
    static extern IntPtr SetFocus(IntPtr hwnd);

    protected override Size ArrangeOverride(Size finalSize)
    {
        var size = base.ArrangeOverride(finalSize);
        Dispatcher.UIThread.Post(Resize, DispatcherPriority.Render);
        return size;
    }

    void Resize()
    {
        if (controller is not { } c) return;
        var scale = top?.RenderScaling ?? 1;
        c.Bounds = new System.Drawing.Rectangle(0, 0, (int)Math.Ceiling(Bounds.Width * scale), (int)Math.Ceiling(Bounds.Height * scale));
    }

    void Moved(object? sender, PixelPointEventArgs e) => controller?.NotifyParentWindowPositionChanged();

    void WindowChanged(object? sender, AvaloniaPropertyChangedEventArgs e)
    {
        if (e.Property == Window.IsActiveProperty || e.Property == Window.WindowStateProperty) SendActive();
    }

    /// 主窗口不在前台时网页降到 12 帧，最小化 / 不在世界时停画
    void SendActive()
    {
        if (!loaded) return;
        var window = top as Window;
        var visible = shown && window?.WindowState != WindowState.Minimized;
        if (controller is { } c && c.IsVisible != visible) c.IsVisible = visible;
        Post(new JsonObject { ["type"] = "active", ["active"] = window?.IsActive ?? true, ["visible"] = visible });
    }
}

/// 侧栏上世界模式的入口：像素地球（同 Mac 版 WorldGlobeIcon）——9 行的圆，地图循环滚动；鼠标移上去转起来，进了世界底下一道主题色
public sealed class WorldGlobe : Control
{
    /// 18 列的地图，每格一个方块：w 水、g 草地、d 深色草地、s 沙滩
    static readonly string[] Map =
    [
        "wwwggwwwwwwsggwwww",
        "wwgggdwwwwggggwwww",
        "wsgdggswwwggdgswww",
        "wwgggwwwwwwgggwwgw",
        "wwwgwwwwggwwgwwggg",
        "wwwwwwwgdggwwwwgdg",
        "wwwswwwggggswwwwgw",
        "wwgggwwwgdgwwwwwww",
        "wwwgwwwwwgwwwwwsww",
    ];
    static readonly int[] Rows = [3, 5, 7, 9, 9, 9, 7, 5, 3];

    readonly DispatcherTimer spin = new() { Interval = TimeSpan.FromMilliseconds(110) };
    int shift = 4;
    bool active;

    public bool Active { get => active; set { active = value; InvalidateVisual(); } }

    public WorldGlobe()
    {
        Width = 20;
        Height = 22;
        spin.Tick += (_, _) => { shift = (shift + 1) % 18; InvalidateVisual(); };
    }

    /// 鼠标在按钮上就转（按钮把进出转过来）
    public void Hover(bool on)
    {
        if (on) spin.Start(); else { spin.Stop(); shift = 4; InvalidateVisual(); }
    }

    public override void Render(DrawingContext context)
    {
        var cell = Math.Floor(Math.Min(Bounds.Width, Bounds.Height) / 9);
        var x0 = (Bounds.Width - cell * 9) / 2;
        var y0 = (Bounds.Height - cell * 9) / 2;
        for (var r = 0; r < 9; r++)
        {
            var start = (9 - Rows[r]) / 2;
            for (var c = start; c < start + Rows[r]; c++)
            {
                var kind = Map[r][(c + shift) % 18];
                // 同一种方块深浅错开一点，像我的世界的贴图
                var odd = (r + c + shift) % 3 == 0;
                var color = kind switch
                {
                    'g' => odd ? Avalonia.Media.Color.FromRgb(92, 158, 56) : Avalonia.Media.Color.FromRgb(107, 176, 66),
                    'd' => Avalonia.Media.Color.FromRgb(69, 128, 46),
                    's' => Avalonia.Media.Color.FromRgb(219, 204, 140),
                    _ => odd ? Avalonia.Media.Color.FromRgb(51, 107, 214) : Avalonia.Media.Color.FromRgb(64, 122, 230),
                };
                context.FillRectangle(new SolidColorBrush(color), new Rect(x0 + c * cell, y0 + r * cell, cell, cell));
            }
        }
        // 左上一点高光：有点立体
        context.FillRectangle(new SolidColorBrush(Colors.White, 0.35), new Rect(x0 + cell * 2, y0 + cell * 2, cell, cell));
        if (active) context.FillRectangle(Palette.Get("Accent"), new Rect(x0 + cell * 2, y0 + cell * 9 + 1, cell * 5, Math.Max(1.5, cell / 2)));
    }
}
