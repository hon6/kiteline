using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.Net;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

// 会话浏览器（同 iPhone / Mac 版 KitelineKit/Browser）：agent 用 Kiteline 的浏览器时，对话页右上角浮出实时画面小窗，
// 点开放大到半个会话 / 整个会话（盖在对话页上，BrowserDock）、整个应用 / 全屏（盖在主窗口上，BrowserLayer）。
// 放大后左边是画面、右边是 agent 的指令列表；可以接管：点、拖、滚轮、直接打字、按键、地址栏、切标签页。
// 画面只在这些视图显示时向后台要（watch 每 5 秒续一次），小窗要缩略档、放大要大画面档

public enum BrowserSize { Mini, Half, Session, App, FullScreen }

public sealed class BrowserStore
{
    public static BrowserStore Shared { get; } = new();

    public sealed record Frame(Bitmap Image, long Seq, double CssWidth, double CssHeight, string Url, string Title);
    public sealed record Action(double? Time, string Tool, string Text);
    public sealed record Tab(string Id, string Url, string Title, bool Current);

    readonly Dictionary<string, Frame> frames = new();
    readonly Dictionary<string, List<Action>> actions = new();
    readonly Dictionary<string, List<Tab>> tabs = new();
    readonly Dictionary<string, BrowserSize> sizes = new();
    readonly Dictionary<string, double> dismissed = new();
    readonly HashSet<string> controlling = [];
    readonly Dictionary<string, Dictionary<Guid, string>> viewers = new();
    readonly Dictionary<string, CancellationTokenSource> leases = new();
    readonly string viewerId = Guid.NewGuid().ToString();

    /// 放到「整个应用 / 全屏」的会话
    public string? Focus { get; private set; }
    /// 画面到了（会话 key）
    public event Action<string>? FrameArrived;
    /// 大小、接管、指令、标签页变了（会话 key；null = 全部）
    public event Action<string?>? Changed;

    static Api Api => AppModel.Shared.Api;
    static Dictionary<string, string> Q(string key) => new() { ["key"] = key };

    public Frame? FrameOf(string key) => frames.GetValueOrDefault(key);
    public IReadOnlyList<Action> Actions(string key) => actions.GetValueOrDefault(key) ?? [];
    public IReadOnlyList<Tab> Tabs(string key) => tabs.GetValueOrDefault(key) ?? [];
    public BrowserSize Size(string key) => sizes.GetValueOrDefault(key, BrowserSize.Mini);
    public bool IsControlling(string key) => controlling.Contains(key);

    /// 小窗被拖到哪（相对右上角的默认位置）：记在本机偏好里，各会话共用
    public Point MiniOffset
    {
        get => new(Prefs.Number("browserMiniX") ?? 0, Prefs.Number("browserMiniY") ?? 0);
        set { Prefs.Set("browserMiniX", value.X); Prefs.Set("browserMiniY", value.Y); }
    }

    public void SetSize(string key, BrowserSize size)
    {
        sizes[key] = size;
        if (size is BrowserSize.App or BrowserSize.FullScreen) Focus = key;
        else if (Focus == key) Focus = null;
        Changed?.Invoke(null);
    }

    /// 会话在用浏览器就显示（小窗，或收起后的小圆钮）
    public bool Visible(string key, BrowserInfo? info) => info is not null;

    /// 小窗收起成小圆钮了（× 只是收起：浏览器照常运行、agent 照常操作；点圆钮恢复；agent 请你接管时自动展开）
    public bool Collapsed(string key, BrowserInfo? info) =>
        info is not null && info.Ask is null && dismissed.TryGetValue(key, out var at) && at == (info.Since ?? 0);

    public void Dismiss(string key, BrowserInfo? info)
    {
        dismissed[key] = info?.Since ?? 0;
        SetSize(key, BrowserSize.Mini);
    }

    public void Expand(string key)
    {
        dismissed.Remove(key);
        Changed?.Invoke(key);
    }

    /// 关掉「回放」卡片（录像还在）
    public Task Forget(string key) => Post(key, new JsonObject { ["op"] = "forget" }, quiet: true);

    public async Task CloseBrowser(string key)
    {
        await Post(key, new JsonObject { ["op"] = "close" });
        SetSize(key, BrowserSize.Mini);
    }

    // MARK: 看画面

    public void Watch(string key, Guid token, string level)
    {
        if (!viewers.TryGetValue(key, out var map)) viewers[key] = map = new();
        map[token] = level;
        Lease(key, first: true);
    }

    public void Unwatch(string key, Guid token)
    {
        if (!viewers.TryGetValue(key, out var map)) return;
        map.Remove(token);
        if (map.Count > 0) { Lease(key, first: false); return; }
        viewers.Remove(key);
        if (leases.Remove(key, out var cts)) cts.Cancel();
        _ = Post(key, new JsonObject { ["op"] = "unwatch", ["viewer"] = viewerId }, quiet: true);
    }

    string Level(string key) => viewers.TryGetValue(key, out var map) && map.Values.Contains("full") ? "full" : "thumb";

    /// 每 5 秒续一次（档位变了马上续）：后台 15 秒没续就当没人看、停推
    void Lease(string key, bool first)
    {
        if (leases.Remove(key, out var old)) old.Cancel();
        var cts = new CancellationTokenSource();
        leases[key] = cts;
        _ = Task.Run(async () =>
        {
            var initial = first;
            while (!cts.IsCancellationRequested)
            {
                try
                {
                    var reply = await Api.Post("/api/browser", new { op = "watch", viewer = viewerId, level = Level(key), first = initial }, Q(key), cts.Token);
                    initial = false;
                    Dispatcher.UIThread.Post(() => Apply(key, reply));
                }
                catch { /* 浏览器被回收了、会话结束了：等下一轮（会话数据里没了 browser，小窗自己收起） */ }
                try { await Task.Delay(5000, cts.Token); } catch { return; }
            }
        });
    }

    void Apply(string key, JsonNode? reply)
    {
        if (reply.Arr("actions") is JsonArray rows)
            actions[key] = rows.Items().Select(r => new Action(r.Num("t"), r.Str("tool") ?? "", r.Str("text") ?? "")).ToList();
        if (reply.Arr("tabs") is JsonArray list)
            tabs[key] = list.Items().Where(t => t.Str("id") is not null)
                .Select(t => new Tab(t.Str("id")!, t.Str("url") ?? "", t.Str("title") ?? "", t.Bool("current") == true)).ToList();
        Changed?.Invoke(key);
    }

    /// 有新指令（会话数据里的 last 变了）：刷新列表
    public async Task RefreshActions(string key, bool force = false)
    {
        if (!force && !viewers.ContainsKey(key)) return;
        try { Apply(key, await Api.Post("/api/browser", new { op = "actions" }, Q(key))); } catch { }
    }

    /// 实时连接上的 browser_frame（网络线程上调；解码在这里做，界面线程只换图）
    public void Receive(string name, JsonNode? json)
    {
        if (name != "browser_frame" || json.Str("key") is not string key || json.Str("data") is not string data) return;
        if (!viewers.ContainsKey(key)) return;
        var seq = (long)(json.Num("seq") ?? 0);
        Bitmap image;
        try { image = new Bitmap(new MemoryStream(Convert.FromBase64String(data))); }
        catch { return; }
        var frame = new Frame(image, seq, json.Num("cssW") ?? 0, json.Num("cssH") ?? 0, json.Str("url") ?? "", json.Str("title") ?? "");
        Dispatcher.UIThread.Post(() =>
        {
            if (frames.TryGetValue(key, out var have) && have.Seq > seq) return;
            frames[key] = frame;
            FrameArrived?.Invoke(key);
        });
    }

    // MARK: 接管

    public async Task TakeOver(string key)
    {
        controlling.Add(key);
        Changed?.Invoke(key);
        await Post(key, new JsonObject { ["op"] = "control", ["on"] = true, ["device"] = Environment.MachineName });
    }

    /// 交还给 agent（agent 在 browser ask 里等着的话，留言带给它）
    public async Task HandBack(string key, string note = "")
    {
        controlling.Remove(key);
        Changed?.Invoke(key);
        await Post(key, new JsonObject { ["op"] = "control", ["on"] = false, ["text"] = note, ["device"] = Environment.MachineName });
    }

    /// 点击、拖动、滚动、打字、按键、地址栏：x / y 是在画面上的比例（0～1）
    public void Input(string key, JsonObject body)
    {
        body["op"] = "input";
        _ = Post(key, body, quiet: true);
    }

    public async Task SelectTab(string key, string id)
    {
        try { Apply(key, await Api.Post("/api/browser", new { op = "tab", tab = id }, Q(key))); } catch (Exception e) { AppModel.Shared.Flash(e.Message); }
    }

    static async Task Post(string key, JsonObject body, bool quiet = false)
    {
        try { await Api.Post("/api/browser", body, Q(key)); }
        catch (Exception e) { if (!quiet) Dispatcher.UIThread.Post(() => AppModel.Shared.Flash(e.Message)); }
    }
}

/// 对话页上的浮层：小窗、半个会话、整个会话（ChatView 里盖在对话和输入区上面）
public sealed partial class BrowserDock : Panel
{
    readonly string key;
    BrowserInfo? info;
    BrowserSize shown = (BrowserSize)(-1);
    Control? view;

    public BrowserDock(string key)
    {
        this.key = key;
        IsVisible = false;
        // 半个会话：高度跟着对话页变
        SizeChanged += (_, e) => { if (view is BrowserViewer half && shown == BrowserSize.Half) half.Height = Math.Max(260, e.NewSize.Height * 0.5); };
        BrowserStore.Shared.Changed += k => { if (k is null || k == key) Dispatcher.UIThread.Post(Rebuild); };
    }

    public void Update(SessionInfo? session)
    {
        var last = info;
        info = session?.Browser;
        if (info?.Last != last?.Last && view is BrowserViewer) _ = BrowserStore.Shared.RefreshActions(key);
        Rebuild();
    }

    void Rebuild()
    {
        var store = BrowserStore.Shared;
        var visible = info is not null && store.Visible(key, info);
        var size = visible ? store.Size(key) : BrowserSize.App;   // App / FullScreen：这里不画；浏览器关了只有「回放」卡片
        IsVisible = visible && size is BrowserSize.Mini or BrowserSize.Half or BrowserSize.Session;
        // 小窗外面的地方要能点到对话：只有放大时整块接鼠标
        IsHitTestVisible = IsVisible;
        if (!IsVisible)
        {
            if (view is not null) { Children.Clear(); view = null; shown = (BrowserSize)(-1); }
            return;
        }
        if (size == shown && view is not null)
        {
            (view as BrowserMini)?.Update(info!);
            (view as BrowserViewer)?.Update(info!);
            return;
        }
        Children.Clear();
        shown = size;
        view = size switch
        {
            BrowserSize.Mini => new BrowserMini(key, info!) { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top },
            BrowserSize.Half => new BrowserViewer(key, info!, size) { VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(8) },
            _ => new BrowserViewer(key, info!, size),
        };
        Children.Add(view);
        if (view is BrowserViewer half && size == BrowserSize.Half) half.Height = Math.Max(260, Bounds.Height * 0.5);
        if (view is BrowserViewer grown) GrowFromMini(grown);
    }
}

public sealed partial class BrowserDock
{
    /// 放大时从小窗所在的位置长出来（同 iPhone / Mac；用户：不要从上面滑下来，要从小窗放大）。
    /// 0.2 秒、按 15 帧手动刷缩放（不用合成器动画：没有显卡时更费，见 Views/Common.cs 的 Beat）
    void GrowFromMini(Control target)
    {
        var area = Bounds.Size;
        if (area.Width <= 0 || area.Height <= 0) return;
        var offset = BrowserStore.Shared.MiniOffset;
        const double miniWidth = 250, miniHeight = 250 * 0.62 + 50;
        var cx = area.Width - 12 - miniWidth / 2 + offset.X;
        var cy = 56 + miniHeight / 2 + offset.Y;
        var height = target.Height is double h && !double.IsNaN(h) ? h : area.Height;
        target.RenderTransformOrigin = new RelativePoint(cx / area.Width, cy / Math.Max(1, height), RelativeUnit.Relative);
        var scale = new ScaleTransform(miniWidth / area.Width, miniWidth / area.Width);
        target.RenderTransform = scale;
        target.Opacity = 0.3;
        var start = DateTime.UtcNow;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1000.0 / 15) };
        timer.Tick += (_, _) =>
        {
            var t = Math.Min(1, (DateTime.UtcNow - start).TotalMilliseconds / 200);
            var ease = 1 - Math.Pow(1 - t, 3);
            var s = miniWidth / area.Width + (1 - miniWidth / area.Width) * ease;
            scale.ScaleX = scale.ScaleY = s;
            target.Opacity = 0.3 + 0.7 * ease;
            if (t >= 1)
            {
                timer.Stop();
                target.RenderTransform = null;
                target.Opacity = 1;
            }
        };
        timer.Start();
    }
}

/// 盖在主窗口上的（整个应用 / 全屏）
public sealed class BrowserLayer : Panel
{
    public static BrowserLayer Shared { get; } = new();
    string? key;
    BrowserSize size;
    WindowState before = WindowState.Normal;

    BrowserLayer()
    {
        IsVisible = false;
        BrowserStore.Shared.Changed += _ => Dispatcher.UIThread.Post(Rebuild);
        AppModel.Shared.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppModel.Sessions)) Rebuild(); };
    }

    void Rebuild()
    {
        var store = BrowserStore.Shared;
        var focus = store.Focus;
        var info = focus is null ? null : AppModel.Shared.Session(focus)?.Browser;
        var show = focus is not null && store.Visible(focus, info);
        var nextSize = show ? store.Size(focus!) : BrowserSize.Mini;
        SetFullScreen(show && nextSize == BrowserSize.FullScreen);
        if (!show)
        {
            if (IsVisible) { Children.Clear(); IsVisible = false; key = null; }
            return;
        }
        if (focus == key && nextSize == size && Children.FirstOrDefault() is BrowserViewer viewer) { viewer.Update(info!); return; }
        key = focus;
        size = nextSize;
        Children.Clear();
        Children.Add(new BrowserViewer(focus!, info!, nextSize));
        IsVisible = true;
    }

    void SetFullScreen(bool on)
    {
        if ((Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.MainWindow is not Window window) return;
        if (on && window.WindowState != WindowState.FullScreen)
        {
            before = window.WindowState;
            window.WindowState = WindowState.FullScreen;
        }
        else if (!on && window.WindowState == WindowState.FullScreen)
        {
            window.WindowState = before == WindowState.FullScreen ? WindowState.Normal : before;
        }
    }
}

/// 小窗：缩略画面 + 标题 + 最近一条指令；点一下放大到半个会话，右键选别的大小
public sealed class BrowserMini : Border
{
    readonly string key;
    readonly Image image = new() { Stretch = Stretch.Uniform };
    readonly TextBlock title = Ui.Text("", 11, FontWeight.SemiBold).Trim();
    readonly TextBlock last = Ui.Text("", 10.5, color: "Text2").Mono().Trim();
    readonly TextBlock ask = Ui.Text("", 11, FontWeight.SemiBold, "Accent", 2).Wrap();
    readonly Guid token = Guid.NewGuid();
    BrowserInfo info;
    const double W = 250;

    public BrowserMini(string key, BrowserInfo info)
    {
        this.key = key;
        this.info = info;
        Width = W;
        CornerRadius = new CornerRadius(12);
        ClipToBounds = true;
        BorderThickness = new Thickness(1);
        // 不在自己身上挂阴影：Avalonia 里元素自带 BoxShadow 时后画的子元素会被吞掉（离屏截图实测整块空白）
        this.Res(BackgroundProperty, "Surface").Res(BorderBrushProperty, "Separator");
        var live = Ui.H(4, Ui.Dot(6, Brushes.Red), Ui.Text(L("实时"), 9, FontWeight.SemiBold, "White")).Pad(6, 3);
        live.Background = new SolidColorBrush(Color.FromArgb(128, 0, 0, 0));
        live.CornerRadius = new CornerRadius(8);
        live.HorizontalAlignment = HorizontalAlignment.Left;
        live.VerticalAlignment = VerticalAlignment.Top;
        live.Margin = new Thickness(6);
        var close = new Tap(Ui.Sym("xmark", 9, "White").Pad(5), () => BrowserStore.Shared.Dismiss(key, this.info), 10)
        { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(5) }
            .Tip(L("收起成小图标（浏览器照常运行）"));
        close.Background = new SolidColorBrush(Color.FromArgb(115, 0, 0, 0));
        var shot = new Panel { Height = W * 0.62, Children = { image, live, close } };
        shot.Res(Panel.BackgroundProperty, "Fill05");
        card = Ui.VFill(0, shot, Ui.VFill(2, title, last, ask).Pad(8, 6));
        // 收起后的小圆钮：地球 + 红点（浏览器还在运行），点一下恢复小窗
        var dot = Ui.Dot(8, Brushes.Red);
        dot.HorizontalAlignment = HorizontalAlignment.Right;
        dot.VerticalAlignment = VerticalAlignment.Top;
        dot.Margin = new Thickness(0, 6, 6, 0);   // 圆钮裁成圆形：红点往里放，别被裁掉
        pill = new Panel { Width = 40, Height = 40, Children = { Ui.Sym("globe", 17).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center), dot } };
        ToolTip.SetTip(pill, L("展开浏览器小窗"));
        Child = card;
        Cursor = new Cursor(StandardCursorType.Hand);
        // 拖到对话页里任何地方（别挡住要看的内容），位置记住、各会话共用；没拖动就是点一下放大到半个会话
        Point? pressAt = null;
        var startOffset = BrowserStore.Shared.MiniOffset;
        var moved = false;
        PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed || close.IsPointerOver) return;
            pressAt = e.GetPosition(Parent as Visual);
            startOffset = BrowserStore.Shared.MiniOffset;
            moved = false;
            e.Pointer.Capture(this);
        };
        PointerMoved += (_, e) =>
        {
            if (pressAt is not Point at) return;
            var now = e.GetPosition(Parent as Visual);
            var dx = now.X - at.X;
            var dy = now.Y - at.Y;
            if (!moved && Math.Abs(dx) + Math.Abs(dy) < 6) return;
            moved = true;
            Place(new Point(startOffset.X + dx, startOffset.Y + dy));
        };
        PointerReleased += (_, e) =>
        {
            if (pressAt is null) return;
            pressAt = null;
            e.Pointer.Capture(null);
            if (moved) BrowserStore.Shared.MiniOffset = offset;
            else if (e.InitialPressMouseButton == MouseButton.Left)
            {
                if (this.info.Closed) BrowserStore.Shared.SetSize(key, BrowserSize.Half);   // 浏览器关了：放大后直接放录像
                else if (BrowserStore.Shared.Collapsed(key, this.info)) BrowserStore.Shared.Expand(key);
                else BrowserStore.Shared.SetSize(key, BrowserSize.Half);
            }
        };
        Place(BrowserStore.Shared.MiniOffset);
        this.Menu(() =>
        [
            Ui.Item(L("半个会话"), () => BrowserStore.Shared.SetSize(key, BrowserSize.Half)),
            Ui.Item(L("整个会话"), () => BrowserStore.Shared.SetSize(key, BrowserSize.Session)),
            Ui.Item(L("整个应用"), () => BrowserStore.Shared.SetSize(key, BrowserSize.App)),
            Ui.Item(L("全屏"), () => BrowserStore.Shared.SetSize(key, BrowserSize.FullScreen)),
        ]);
        Update(info);
        AttachedToVisualTree += (_, _) =>
        {
            BrowserStore.Shared.FrameArrived += OnFrame;
            BrowserStore.Shared.Watch(key, token, "thumb");
            OnFrame(key);
        };
        DetachedFromVisualTree += (_, _) =>
        {
            BrowserStore.Shared.FrameArrived -= OnFrame;
            BrowserStore.Shared.Unwatch(key, token);
        };
    }

    Point offset;

    /// 相对右上角默认位置（距顶 56、距右 12）挪多少：往左为负、往下为正，不许拖出对话页
    void Place(Point want)
    {
        offset = Clamp(want);
        Margin = new Thickness(0, 56 + offset.Y, 12 - offset.X, 0);
    }

    Point Clamp(Point want)
    {
        var area = (Parent as Control)?.Bounds.Size ?? default;
        if (area.Width <= 0 || area.Height <= 0) return want;
        var height = Bounds.Height > 0 ? Bounds.Height : W * 0.62 + 50;
        var minX = -(area.Width - Width - 20);
        var maxY = Math.Max(0, area.Height - height - 56 - 8);
        return new Point(Math.Min(0, Math.Max(minX, want.X)), Math.Min(maxY, Math.Max(-48, want.Y)));
    }

    void OnFrame(string k)
    {
        if (k == key && BrowserStore.Shared.FrameOf(key) is { } frame) image.Source = frame.Image;
    }

    readonly Control card;
    readonly Control pill;
    Control? replayCard;

    /// 浏览器关了、留着录像：「回放」卡片（点一下看回放，× 不再显示）
    Control ReplayCard()
    {
        var forget = new Tap(Ui.Sym("xmark", 9).Pad(5), () => _ = BrowserStore.Shared.Forget(key), 10).Tip(L("不再显示"));
        return Ui.H(8, Ui.Sym("play", 16, "Accent"),
                    Ui.VFill(1, Ui.Text(L("回放浏览器操作"), 11.5, FontWeight.SemiBold), title).Grow(), forget).Pad(10, 8);
    }

    public void Update(BrowserInfo info)
    {
        this.info = info;
        var collapsed = !info.Closed && BrowserStore.Shared.Collapsed(key, info);
        Child = info.Closed ? (replayCard ??= ReplayCard()) : collapsed ? pill : card;
        Width = collapsed ? 40 : W;
        CornerRadius = new CornerRadius(collapsed ? 20 : 12);
        title.Text = info.Title.Length > 0 ? info.Title : info.ShortUrl;
        last.Text = info.Last.Length > 0 ? info.Last : info.ShortUrl;
        ask.Text = info.Ask ?? "";
        ask.IsVisible = info.Ask is not null;
    }
}

/// 放大：顶栏（标题 / 地址、标签页、前进后退刷新、四档大小、缩回小窗）、请接管 / 接管中的条、画面、指令列表
public sealed class BrowserViewer : Grid
{
    readonly string key;
    readonly BrowserSize size;
    readonly Guid token = Guid.NewGuid();
    readonly Image image = new() { Stretch = Stretch.Uniform };
    readonly Panel screen = new() { ClipToBounds = true, Focusable = true };
    readonly Border outline = new() { BorderThickness = new Thickness(2), IsHitTestVisible = false, IsVisible = false };
    readonly TextBlock title = Ui.Text("", 13, FontWeight.SemiBold).Trim();
    readonly TextBlock url = Ui.Text("", 11, color: "Text2").Trim();
    readonly Panel bars = new();
    readonly StackPanel actionList = new();
    readonly ScrollViewer actionScroll;
    readonly TextBlock actionCount = Ui.Text("0", 11, color: "Text2");
    readonly Panel navButtons;
    BrowserInfo info;
    bool dragging;
    Point downAt;
    long lastMove;

    public BrowserViewer(string key, BrowserInfo info, BrowserSize size)
    {
        this.key = key;
        this.info = info;
        this.size = size;
        this.Res(BackgroundProperty, "ChatBackground");
        RowDefinitions = new RowDefinitions("Auto,Auto,*");
        if (size == BrowserSize.Half)
        {
            ClipToBounds = true;
        }

        // 顶栏
        var tabsButton = new Tap(Ui.VFill(1, title, url).Pad(4, 2), null, 6).Grow();
        tabsButton.Menu(() =>
        {
            var items = new List<Control>();
            foreach (var tab in BrowserStore.Shared.Tabs(key))
                items.Add(Ui.Item(tab.Title.Length > 0 ? tab.Title : tab.Url, () => _ = BrowserStore.Shared.SelectTab(key, tab.Id), check: tab.Current ? "checkmark" : null));
            return items;
        });
        navButtons = Ui.H(2,
            IconButton("chevron.left", L("后退"), () => Nav("back")),
            IconButton("chevron.right", L("前进"), () => Nav("forward")),
            IconButton("arrow.clockwise", L("刷新"), () => Nav("reload")));
        var sizesBar = Ui.H(2,
            SizeButton(L("半个会话"), L("半个会话"), BrowserSize.Half),
            SizeButton(L("整个会话"), L("整个会话"), BrowserSize.Session),
            SizeButton(L("整个应用"), L("整个应用"), BrowserSize.App),
            SizeButton(L("全屏"), L("全屏"), BrowserSize.FullScreen));
        var header = Ui.H(8, Ui.Sym("globe", 14, "Text2"), tabsButton, navButtons, sizesBar,
            IconButton("arrow.down.right.and.arrow.up.left", L("缩回小窗"), () => BrowserStore.Shared.SetSize(key, BrowserSize.Mini)),
            // 真正结束浏览器（小窗上的 × 只是收起）：agent 再用浏览器时会重新打开
            IconButton("stop", L("关闭浏览器"), async () =>
            {
                if (await Dialogs.Confirm(L("Agent 正在进行的网页操作会中断，它再次使用浏览器时会重新打开（登录状态保留）。"), L("关闭浏览器"), true, L("关闭这个会话的浏览器？")))
                    await BrowserStore.Shared.CloseBrowser(key);
            })).Pad(12, 8);
        var headerBox = new Border { Child = header, BorderThickness = new Thickness(0, 0, 0, 1) }.Res(Border.BorderBrushProperty, "Separator");
        SetRow(headerBox, 0);
        Children.Add(headerBox);
        SetRow(bars, 1);
        Children.Add(bars);

        // 画面 + 指令列表
        outline.Res(Border.BorderBrushProperty, "Accent");
        screen.Children.Add(image);
        screen.Children.Add(outline);
        // 看录像：盖在实时画面上（「回到实时」在角上）
        var back = new Tap(Ui.Text(L("回到实时"), 11.5, FontWeight.SemiBold, "White").Pad(10, 4), () => replay.GoLive(), 12);
        back.Keys("Accent", "Accent");
        back.HorizontalAlignment = HorizontalAlignment.Right;
        back.VerticalAlignment = VerticalAlignment.Top;
        back.Margin = new Thickness(8);
        replayBadge = Ui.Text("", 11, FontWeight.SemiBold, "White").Pad(8, 4);
        replayBadge.Background = new SolidColorBrush(Color.FromArgb(140, 0, 0, 0));
        replayBadge.CornerRadius = new CornerRadius(10);
        replayBadge.HorizontalAlignment = HorizontalAlignment.Left;
        replayBadge.VerticalAlignment = VerticalAlignment.Top;
        replayBadge.Margin = new Thickness(8);
        replayLayer = new Panel { IsVisible = false, Children = { replayImage, replayBadge, back } };
        replayLayer.Res(Panel.BackgroundProperty, "ChatBackground");
        backButton = back;
        screen.Children.Add(replayLayer);
        replay = new BrowserReplayBar(key);
        replay.Changed += () => Dispatcher.UIThread.Post(OnReplay);
        screen.Res(Panel.BackgroundProperty, "Fill03");
        screen.PointerPressed += Pressed;
        screen.PointerMoved += Moved;
        screen.PointerReleased += Released;
        screen.PointerWheelChanged += Wheel;
        screen.KeyDown += KeyPressed;
        screen.AddHandler(TextInputEvent, Typed, Avalonia.Interactivity.RoutingStrategies.Tunnel | Avalonia.Interactivity.RoutingStrategies.Bubble);
        actionScroll = new ScrollViewer { Content = actionList, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        var listHead = Ui.H(6, Ui.Text(L("Agent 的操作"), 12, FontWeight.SemiBold).Grow(), actionCount).Pad(12, 8);
        var listPanel = new DockPanel();
        DockPanel.SetDock(listHead, Dock.Top);
        listPanel.Children.Add(listHead);
        DockPanel.SetDock(replay, Dock.Top);
        listPanel.Children.Add(replay);   // 回放控制就在「Agent 的操作」这一块里（不弹窗）
        listPanel.Children.Add(actionScroll);
        var body = new Grid();
        body.SizeChanged += (_, e) =>
        {
            var wide = e.NewSize.Width >= 720;
            if (body.Tag as bool? == wide) return;
            body.Tag = wide;
            body.Children.Clear();
            body.ColumnDefinitions.Clear();
            body.RowDefinitions.Clear();
            var rule = wide ? Ui.VRule() : Ui.Rule();
            if (wide)
            {
                body.ColumnDefinitions = new ColumnDefinitions($"*,Auto,{Math.Min(340, e.NewSize.Width * 0.3)}");
                SetColumn(screen, 0); SetColumn(rule, 1); SetColumn(listPanel, 2);
                SetRow(screen, 0); SetRow(rule, 0); SetRow(listPanel, 0);
            }
            else
            {
                body.RowDefinitions = new RowDefinitions($"*,Auto,{Math.Min(200, e.NewSize.Height * 0.3)}");
                SetRow(screen, 0); SetRow(rule, 1); SetRow(listPanel, 2);
                SetColumn(screen, 0); SetColumn(rule, 0); SetColumn(listPanel, 0);
            }
            body.Children.Add(screen);
            body.Children.Add(rule);
            body.Children.Add(listPanel);
        };
        SetRow(body, 2);
        Children.Add(body);

        Update(info);
        AttachedToVisualTree += (_, _) =>
        {
            BrowserStore.Shared.FrameArrived += OnFrame;
            BrowserStore.Shared.Changed += OnChanged;
            if (!info.Closed) BrowserStore.Shared.Watch(key, token, "full");
            OnFrame(key);
            OnChanged(key);
            _ = replay.StartIfClosed(info.Closed);   // 浏览器关了：放大后直接放录像
        };
        DetachedFromVisualTree += (_, _) =>
        {
            BrowserStore.Shared.FrameArrived -= OnFrame;
            BrowserStore.Shared.Changed -= OnChanged;
            BrowserStore.Shared.Unwatch(key, token);
        };
    }

    Control IconButton(string icon, string tip, System.Action action) => new Tap(Ui.Sym(icon, 13).Pad(7, 5), action, 6).Tip(tip);

    Control SizeButton(string text, string tip, BrowserSize option)
    {
        var on = option == size;
        var label = Ui.Text(text, 11.5, on ? FontWeight.SemiBold : FontWeight.Normal, on ? "Accent" : "Text");
        var tap = new Tap(label.Pad(8, 4), () => BrowserStore.Shared.SetSize(key, option), 6).Tip(tip);
        if (on) tap.Keys("AccentFill20", "AccentFill20");
        return tap;
    }

    void OnFrame(string k)
    {
        if (k == key && BrowserStore.Shared.FrameOf(key) is { } frame) image.Source = frame.Image;
    }

    readonly BrowserReplayBar replay;
    readonly Image replayImage = new() { Stretch = Stretch.Uniform };
    readonly Border replayBadge;
    readonly Panel replayLayer;
    readonly Control backButton;

    void OnReplay()
    {
        replayLayer.IsVisible = replay.Active || info.Closed;
        replayImage.Source = replay.Image;
        backButton.IsVisible = !info.Closed;
        ((TextBlock)replayBadge.Child!).Text = replay.Playing ? L("回放中") : L("回放已暂停");
        RebuildBars();
        OnChanged(key);
    }

    void OnChanged(string? k)
    {
        if (k is not null && k != key) return;
        Dispatcher.UIThread.Post(() =>
        {
            RebuildBars();
            var rows = BrowserStore.Shared.Actions(key);
            actionCount.Text = rows.Count.ToString();
            actionList.Children.Clear();
            if (rows.Count == 0) actionList.Children.Add(Ui.Text(L("还没有操作记录"), 12, color: "Text2").Pad(12, 8));
            for (var i = 0; i < rows.Count; i++)
            {
                var row = rows[i];
                var latest = replay.Moment is double at
                    ? row == rows.LastOrDefault(a => (a.Time ?? 0) > 0 && a.Time <= at)
                    : i == rows.Count - 1;
                var time = row.Time is double t ? DateTimeOffset.FromUnixTimeSeconds((long)t).ToLocalTime().ToString("HH:mm:ss") : "--:--";
                var line = Ui.HTop(8, Ui.Text(time, 10.5, color: "Text3").Mono(),
                                   Ui.Text(row.Text, 11.5, color: latest ? "Text" : "Text2", lines: 3).Mono().Wrap().Shrink()).Pad(12, 4);
                if (latest) line.Res(Border.BackgroundProperty, "AccentFill20");
                actionList.Children.Add(line);
            }
            if (!replay.Active) actionScroll.ScrollToEnd();
        });
    }

    public void Update(BrowserInfo info)
    {
        var lastChanged = info.Last != this.info.Last;
        this.info = info;
        title.Text = info.Title.Length > 0 ? info.Title : L("浏览器");
        url.Text = info.ShortUrl;
        RebuildBars();
        if (lastChanged) _ = BrowserStore.Shared.RefreshActions(key);
    }

    /// 请接管 / 接管中的条
    void RebuildBars()
    {
        var store = BrowserStore.Shared;
        if (replay.Active || info.Closed)
        {
            // 看录像时没有接管（录像点不了）
            bars.Children.Clear();
            navButtons.IsVisible = outline.IsVisible = false;
            return;
        }
        var controlling = store.IsControlling(key);
        navButtons.IsVisible = controlling;
        outline.IsVisible = controlling;
        bars.Children.Clear();
        if (controlling)
        {
            var typing = new TextBox { Watermark = L("输入文字，回车发送到网页（也可以点画面后直接打字）"), FontSize = 12 }.Grow();
            typing.KeyDown += (_, e) =>
            {
                if (e.Key != Key.Enter) return;
                if (!string.IsNullOrEmpty(typing.Text)) store.Input(key, new JsonObject { ["type"] = "text", ["text"] = typing.Text });
                store.Input(key, new JsonObject { ["type"] = "key", ["key"] = "Enter" });
                typing.Text = "";
                e.Handled = true;
            };
            var note = new TextBox { Watermark = L("给 Agent 留言（可不填）"), FontSize = 12, Width = 200, IsVisible = info.Ask is not null };
            var handBack = new Tap(Ui.Text(L("交还给 Agent"), 12, FontWeight.SemiBold, "White").Pad(12, 5), () => _ = store.HandBack(key, note.Text ?? ""), 6);
            handBack.Keys("Accent", "Accent");
            var address = new TextBox { Watermark = L("输入网址，回车打开"), FontSize = 12, Width = 220 };
            address.KeyDown += (_, e) =>
            {
                if (e.Key != Key.Enter || string.IsNullOrWhiteSpace(address.Text)) return;
                store.Input(key, new JsonObject { ["type"] = "nav", ["action"] = "goto", ["url"] = address.Text.Trim() });
                address.Text = "";
                e.Handled = true;
            };
            var row1 = Ui.H(6, address, typing, KeyButton("⌫", "Backspace", L("退格")), KeyButton("Tab", "Tab", "Tab"), KeyButton("↵", "Enter", L("回车")),
                            KeyButton("PgUp", "PageUp", L("向上翻页")), KeyButton("PgDn", "PageDown", L("向下翻页")));
            var row2 = Ui.H(8, Ui.Sym("hand.raised", 12, "Text2"), Ui.Text(L("你正在操作浏览器，Agent 的指令仍会执行"), 11.5, color: "Text2").Trim().Grow(), note, handBack);
            var box = Ui.VFill(6, row1, row2).Pad(12, 8);
            box.Res(Border.BackgroundProperty, "Fill05");   // 淡底，不用整块主题色（同 Mac 版）
            bars.Children.Add(box);
        }
        else if (info.Ask is string ask)
        {
            var start = new Tap(Ui.Text(L("开始接管"), 12, FontWeight.SemiBold, "White").Pad(12, 5), () => { _ = store.TakeOver(key); screen.Focus(); }, 6);
            start.Keys("Accent", "Accent");
            var box = Ui.H(10, Ui.Sym("hand.raised", 14, "Accent"),
                           Ui.VFill(2, Ui.Text(L("Agent 请你接管浏览器"), 12, FontWeight.SemiBold), Ui.Text(ask, 11.5, color: "Text2", lines: 3).Wrap()).Grow(),
                           start).Pad(12, 8);
            box.Res(Border.BackgroundProperty, "Fill05");   // 淡底，不用整块主题色（同 Mac 版）
            bars.Children.Add(box);
        }
        else
        {
            var take = new Tap(Ui.H(6, Ui.Sym("cursorarrow", 12), Ui.Text(L("接管"), 12)).Pad(10, 4), () => { _ = store.TakeOver(key); screen.Focus(); }, 6)
                .Tip(L("自己点、自己输入（比如登录、过验证码），弄完交还给 Agent"));
            bars.Children.Add(Ui.H(8, Ui.Text(L("实时画面"), 11.5, color: "Text2").Grow(), take).Pad(12, 4));
        }
    }

    Control KeyButton(string text, string name, string tip) =>
        new Tap(Ui.Text(text, 11.5).Pad(8, 4), () => BrowserStore.Shared.Input(key, new JsonObject { ["type"] = "key", ["key"] = name }), 6)
            .Keys("Fill06", "Fill10").Tip(tip);

    void Nav(string action) => BrowserStore.Shared.Input(key, new JsonObject { ["type"] = "nav", ["action"] = action });

    // MARK: 画面上的鼠标、键盘（接管时才送进网页）

    /// 画面在 screen 里实际画在哪（等比缩放居中）
    Rect Fitted()
    {
        if (image.Source is not Bitmap bitmap || bitmap.PixelSize.Width == 0) return default;
        var box = screen.Bounds.Size;
        var scale = Math.Min(box.Width / bitmap.PixelSize.Width, box.Height / bitmap.PixelSize.Height);
        var w = bitmap.PixelSize.Width * scale;
        var h = bitmap.PixelSize.Height * scale;
        return new Rect((box.Width - w) / 2, (box.Height - h) / 2, w, h);
    }

    JsonObject? At(string type, Point point)
    {
        var rect = Fitted();
        if (rect.Width <= 0 || rect.Height <= 0) return null;
        return new JsonObject
        {
            ["type"] = type,
            ["x"] = Math.Clamp((point.X - rect.X) / rect.Width, 0, 1),
            ["y"] = Math.Clamp((point.Y - rect.Y) / rect.Height, 0, 1),
        };
    }

    bool Controlling => BrowserStore.Shared.IsControlling(key);

    void Pressed(object? sender, PointerPressedEventArgs e)
    {
        if (!Controlling || !e.GetCurrentPoint(screen).Properties.IsLeftButtonPressed) return;
        screen.Focus();
        downAt = e.GetPosition(screen);
        dragging = false;
        e.Pointer.Capture(screen);
        e.Handled = true;
    }

    void Moved(object? sender, PointerEventArgs e)
    {
        if (!Controlling || !e.GetCurrentPoint(screen).Properties.IsLeftButtonPressed) return;
        var point = e.GetPosition(screen);
        if (!dragging && Math.Abs(point.X - downAt.X) + Math.Abs(point.Y - downAt.Y) > 6)
        {
            dragging = true;
            if (At("down", downAt) is { } down) BrowserStore.Shared.Input(key, down);
        }
        // 拖动最多每秒 30 次（滑块够顺，又不把连接灌满）
        if (dragging && Environment.TickCount64 - lastMove > 33 && At("move", point) is { } move)
        {
            lastMove = Environment.TickCount64;
            move["pressed"] = true;
            BrowserStore.Shared.Input(key, move);
        }
    }

    void Released(object? sender, PointerReleasedEventArgs e)
    {
        if (!Controlling || e.InitialPressMouseButton != MouseButton.Left) return;
        var point = e.GetPosition(screen);
        if (At(dragging ? "up" : "click", point) is { } body) BrowserStore.Shared.Input(key, body);
        dragging = false;
        e.Pointer.Capture(null);
        e.Handled = true;
    }

    void Wheel(object? sender, PointerWheelEventArgs e)
    {
        if (!Controlling || At("wheel", e.GetPosition(screen)) is not { } body) return;
        body["dx"] = -e.Delta.X * 100;
        body["dy"] = -e.Delta.Y * 100;
        BrowserStore.Shared.Input(key, body);
        e.Handled = true;
    }

    static readonly Dictionary<Key, string> Keys = new()
    {
        [Key.Enter] = "Enter", [Key.Back] = "Backspace", [Key.Tab] = "Tab", [Key.Escape] = "Escape", [Key.Delete] = "Delete",
        [Key.Left] = "ArrowLeft", [Key.Right] = "ArrowRight", [Key.Up] = "ArrowUp", [Key.Down] = "ArrowDown",
        [Key.Home] = "Home", [Key.End] = "End", [Key.PageUp] = "PageUp", [Key.PageDown] = "PageDown",
    };

    void KeyPressed(object? sender, KeyEventArgs e)
    {
        if (!Controlling || !Keys.TryGetValue(e.Key, out var name)) return;
        BrowserStore.Shared.Input(key, new JsonObject { ["type"] = "key", ["key"] = name });
        e.Handled = true;
    }

    void Typed(object? sender, TextInputEventArgs e)
    {
        if (!Controlling || string.IsNullOrEmpty(e.Text) || !screen.IsFocused) return;
        BrowserStore.Shared.Input(key, new JsonObject { ["type"] = "text", ["text"] = e.Text });
        e.Handled = true;
    }
}

/// 浏览器操作回放（同 iPhone / Mac 版 BrowserReplay）：就在放大视图「Agent 的操作」上面这一条里回放，不弹窗（用户：反复弹很烦）。
/// 平时上面是实时画面、进度条停在最右边（实时）；点播放或把进度条往回拖，上面换成录像，列表里高亮当时那条指令；「回到实时」回来。
/// 录像里只存画面变了的帧，相邻两帧的时间差就是画面停了多久：正常速度按实际时长停留；「跳过等待」把超过 1 秒的停顿压成 0.6 秒；2 / 4 / 8 倍速
public sealed class BrowserReplayBar : StackPanel
{
    readonly string key;
    readonly Slider slider = new() { Minimum = 0, Maximum = 1, Value = 1 };
    readonly TextBlock clock = Ui.Text(L("实时"), 11, color: "Accent").Mono();
    readonly TextBlock playIcon = Ui.Text("▶", 13);
    readonly Dictionary<int, Bitmap> images = new();
    readonly HashSet<int> fetching = [];
    List<double> frames = [];
    double end;
    int index;
    bool playing, skipWait = true, seeking;
    double speed = 1;
    string? current;
    CancellationTokenSource? loop;

    /// 正在看录像（上面的画面换成录像）
    public bool Active { get; private set; }
    public bool Playing => playing;
    /// 正在播的那一刻（秒）：列表据此高亮当时的指令
    public double? Moment => Active && index < frames.Count ? frames[index] / 1000 : null;
    public Bitmap? Image
    {
        get
        {
            for (var k = index; k >= Math.Max(0, index - 40); k--) if (images.TryGetValue(k, out var b)) return b;
            return null;
        }
    }
    /// 画面、播放状态变了（放大视图换画面、高亮指令）
    public event Action? Changed;

    static Api Api => AppModel.Shared.Api;
    Dictionary<string, string> Q => new() { ["key"] = key };

    /// 最近建的一个（自测步骤 browser:replay 用）
    public static BrowserReplayBar? Last { get; private set; }

    public BrowserReplayBar(string key)
    {
        this.key = key;
        Last = this;
        Spacing = 4;
        Margin = new Thickness(12, 2, 12, 6);
        slider.PropertyChanged += (_, e) => { if (e.Property == RangeBase.ValueProperty && !seeking) _ = Scrub(slider.Value); };
        var play = new Tap(playIcon.Pad(8, 3), () => _ = TogglePlay(), 6).Tip(L("回放"));
        var skip = new CheckBox { Content = L("跳过等待"), IsChecked = true, FontSize = 11.5 };
        skip.IsCheckedChanged += (_, _) => { skipWait = skip.IsChecked == true; UpdateClock(); };
        var speeds = new ComboBox { ItemsSource = new[] { "1×", "2×", "4×", "8×" }, SelectedIndex = 0, Width = 70, FontSize = 11.5 };
        speeds.SelectionChanged += (_, _) => { speed = new[] { 1.0, 2, 4, 8 }[Math.Max(0, speeds.SelectedIndex)]; UpdateClock(); };
        var row1 = new DockPanel();
        DockPanel.SetDock(play, Dock.Left);
        DockPanel.SetDock(clock, Dock.Right);
        clock.VerticalAlignment = VerticalAlignment.Center;
        clock.Margin = new Thickness(6, 0, 0, 0);
        row1.Children.Add(play);
        row1.Children.Add(clock);
        row1.Children.Add(slider);
        Children.Add(row1);
        Children.Add(Ui.H(8, skip, new Border().Grow(), speeds));
        DetachedFromVisualTree += (_, _) => Pause();
    }

    double Hold(int i)
    {
        if (i < 0 || i >= frames.Count) return 0;
        var next = i + 1 < frames.Count ? frames[i + 1] : Math.Max(end, frames[i]);
        var gap = Math.Max(0, next - frames[i]) / 1000;
        return skipWait && gap > 1.0 ? 0.6 : gap;
    }

    /// 实时时点播放：从头放；看录像时暂停 / 继续
    public async Task TogglePlay()
    {
        if (playing) { Pause(); return; }
        if (!Active && !await Enter()) return;
        if (index >= frames.Count - 1) await Seek(0);
        Start();
    }

    /// 浏览器关了：一打开就放录像
    public async Task StartIfClosed(bool closed)
    {
        if (closed && !Active) await TogglePlay();
    }

    async Task Scrub(double value)
    {
        if (value >= 0.999 && Active) { GoLive(); return; }
        if (!Active && !await Enter()) return;
        Pause();
        await Seek((int)Math.Round(value * Math.Max(0, frames.Count - 1)));
    }

    public void GoLive()
    {
        Pause();
        Active = false;
        seeking = true;
        slider.Value = 1;
        seeking = false;
        clock.Text = L("实时");
        clock.Res(TextBlock.ForegroundProperty, "Accent");
        Changed?.Invoke();
    }

    async Task<bool> Enter()
    {
        try
        {
            var list = await Api.Post("/api/browser", new { op = "recordings" }, Q);
            var id = list.Arr("recordings").Items().FirstOrDefault()?.Str("id");
            if (id is null) { AppModel.Shared.Flash(L("还没有录到画面")); return false; }
            var reply = await Api.Post("/api/browser", new { op = "recording", rec = id }, Q);
            if (current != id) { images.Clear(); fetching.Clear(); }
            current = id;
            frames = reply.Arr("frames").Items().Select(f => f is JsonArray a && a.Count > 0 ? a[0]?.GetValue<double>() ?? 0 : 0).ToList();
            end = reply.Num("end") ?? (frames.Count > 0 ? frames[^1] : 0);
            await BrowserStore.Shared.RefreshActions(key, force: true);
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); return false; }
        Active = frames.Count > 0;
        clock.Res(TextBlock.ForegroundProperty, "Text2");
        return Active;
    }

    void Start()
    {
        playing = true;
        playIcon.Text = "❚❚";
        loop?.Cancel();
        var cts = loop = new CancellationTokenSource();
        Dispatcher.UIThread.Post(async () =>
        {
            while (!cts.IsCancellationRequested && index < frames.Count)
            {
                await Show(index);
                try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(0.03, Hold(index) / speed)), cts.Token); } catch { return; }
                if (index + 1 >= frames.Count) { Pause(); return; }
                index++;
            }
        });
        Changed?.Invoke();
    }

    void Pause()
    {
        playing = false;
        playIcon.Text = "▶";
        loop?.Cancel();
        Changed?.Invoke();
    }

    async Task Seek(int i)
    {
        index = Math.Clamp(i, 0, Math.Max(0, frames.Count - 1));
        await Show(index);
    }

    async Task Show(int i)
    {
        await Ensure(i);
        seeking = true;
        slider.Value = frames.Count > 1 ? (double)i / (frames.Count - 1) : 0;
        seeking = false;
        UpdateClock();
        Changed?.Invoke();
    }

    /// 取这一帧所在的一段（一次 20 帧）和下一段
    async Task Ensure(int i)
    {
        if (current is null) return;
        var block = i / 20 * 20;
        foreach (var start in new[] { block, block + 20 })
        {
            if (start >= frames.Count || images.ContainsKey(start) || !fetching.Add(start)) continue;
            try
            {
                var reply = await Api.Post("/api/browser", new { op = "rframes", rec = current, from = start, count = 20 }, Q);
                foreach (var row in reply.Arr("frames").Items())
                {
                    if (row.Int("i") is not int n || row.Str("data") is not string data) continue;
                    try { images[n] = new Bitmap(new MemoryStream(Convert.FromBase64String(data))); } catch { }
                }
            }
            catch { }
            fetching.Remove(start);
        }
    }

    void UpdateClock()
    {
        if (!Active) return;
        double total = 0, pos = 0;
        for (var i = 0; i < frames.Count; i++) { total += Hold(i); if (i < index) pos += Hold(i); }
        clock.Text = $"{Span(pos / speed)}/{Span(total / speed)}";
    }

    static string Span(double seconds)
    {
        var s = (int)Math.Round(seconds);
        return s >= 3600 ? $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}" : $"{s / 60}:{s % 60:00}";
    }
}
