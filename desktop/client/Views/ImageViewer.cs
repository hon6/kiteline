using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 看大图（同 Mac 版 MacImageViewer）：一张张看，左右键切换；能放大缩小、拖着看（见 ZoomImage）
public static class ImageViewer
{
    /// 一张图：电脑上的（对话里的图、待办截图，经接口取）或本机现成的（文件面板里的图片、输入框里刚附的图）
    sealed record Source(string? Path, Dictionary<string, string>? Query, byte[]? Data);

    /// path：图从哪个接口取（对话里的图 /api/media，待办的截图 /api/todos/media）
    public static void Show(string key, IReadOnlyList<ChatImage> images, int index, string path = "/api/media") =>
        Open(images.Select(i => new Source(path, new Dictionary<string, string> { ["key"] = key, ["ref"] = i.Ref }, null)).ToList(), index, null);

    /// 本机现成的图（原图数据）；name 是只有一张时标题显示的文件名
    public static void ShowLocal(IReadOnlyList<byte[]> images, int index = 0, string? name = null) =>
        Open(images.Select(d => new Source(null, null, d)).ToList(), index, name);

    /// 待办里的截图：已存的经接口取，刚加的直接看
    public static void ShowShots(IReadOnlyList<TodoShot> shots, int index) =>
        Open(shots.Select(s => s.Saved is { } saved ? new Source(TodoItem.MediaPath, TodoItem.MediaQuery(saved.Ref), null) : new Source(null, null, s.Jpeg ?? s.Preview)).ToList(), index, null);

    /// 最近打开的看大图（自测截图用）
    public static Window? LastWindow { get; private set; }

    static void Open(IReadOnlyList<Source> images, int index, string? name)
    {
        if (images.Count == 0) return;
        var zoom = new ZoomImage();
        var current = Math.Clamp(index, 0, images.Count - 1);
        var title = Ui.Text("", 13, FontWeight.SemiBold);
        var percent = Ui.Text("100%", 12.5, FontWeight.Medium).Digits();
        Tap? previous = null, next = null;
        void Load()
        {
            title.Text = images.Count > 1 ? $"{current + 1} / {images.Count}" : name ?? L("图片");
            if (previous is not null) previous.Opacity = current == 0 ? 0.35 : 1;
            if (next is not null) next.Opacity = current == images.Count - 1 ? 0.35 : 1;
            zoom.Source = null;
            var item = images[current];
            if (item.Data is byte[] data)
            {
                try { using var stream = new MemoryStream(data); zoom.Source = new Bitmap(stream); }
                catch (Exception) { AppModel.Shared.Flash(L("无法获取图片")); }
            }
            else if (item.Path is string path && item.Query is { } query)
            {
                var at = current;
                ImageCache.Load(path, query, b => { if (at == current) zoom.Source = b; });
            }
        }
        void Step(int delta)
        {
            var target = Math.Clamp(current + delta, 0, images.Count - 1);
            if (target == current) return;
            current = target;
            Load();
        }
        // 原图的数据（拷贝、存储、用默认应用打开）：PNG / JPEG 原样
        async Task<byte[]?> Original()
        {
            var item = images[current];
            if (item.Data is byte[] data) return data;
            try { return item.Path is string path ? await AppModel.Shared.Api.MediaData(path, item.Query) : null; }
            catch (Exception) { return null; }
        }

        Window? window = null;
        // 工具栏（同 Mac 版看大图）：左边翻页和标题，右边缩放一组、拷贝 / 存储 / 用默认应用打开一组，各成一块玻璃，最右「完成」
        previous = images.Count > 1 ? ToolIcon("chevron.left", () => Step(-1), L("上一张（←）")) : null;
        next = images.Count > 1 ? ToolIcon("chevron.right", () => Step(1), L("下一张（→）")) : null;
        var fit = ToolIcon("arrow.up.left.and.down.right.magnifyingglass", zoom.Fit, L("适合窗口（Ctrl+9）"));
        var actual = (Tap)new Tap(percent, zoom.ActualSize, 14) { MinWidth = 52, Height = 30, Padding = new Thickness(6, 0) }.Keys("Transparent", "Fill10").Tip(L("实际大小（Ctrl+0）"));
        percent.HorizontalAlignment = HorizontalAlignment.Center;
        percent.VerticalAlignment = VerticalAlignment.Center;
        var bar = Ui.H(8,
            previous is null ? null : ToolGroup(previous, next),
            title, new Spacer(12),
            ToolGroup(ToolIcon("minus.magnifyingglass", () => zoom.ZoomBy(1 / 1.25), L("缩小（Ctrl+-）")), actual,
                      ToolIcon("plus.magnifyingglass", () => zoom.ZoomBy(1.25), L("放大（Ctrl++）")), fit),
            ToolGroup(ToolIcon("doc.on.doc", () => Copy(window, Original), L("拷贝图片（Ctrl+C）")),
                      ToolIcon("square.and.arrow.down", () => SaveAs(window, Original, name), L("存储为文件")),
                      ToolIcon("arrow.up.forward.app", () => OpenExternally(Original), L("用默认应用打开（可标注、另存）"))),
            new GlassButton(L("完成"), null, () => window?.Close(), height: 32)).Pad(14, 10);
        zoom.Swipe += delta => Step(delta);
        zoom.Changed += () =>
        {
            percent.Text = $"{Math.Round(zoom.Scale * 100)}%";
            fit.Opacity = zoom.Fitting ? 0.35 : 1;
        };
        var panel = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        panel.Children.Add(bar);
        panel.Children.Add(new Border { Child = zoom }.Res(Border.BackgroundProperty, "ChatBackground"));
        window = new Window
        {
            // 多张时工具栏多一组翻页按钮：最窄 560 才放得下（工具栏不会折叠，窄了「完成」会被挤出窗口）
            Title = images.Count > 1 || name is null ? L("图片") : name, Width = 900, Height = 700, MinWidth = images.Count > 1 ? 560 : 480, MinHeight = 320,
            CanResize = true, ShowInTaskbar = false, FontFamily = Look.Family,
        };
        // 顶上统一的标题栏（标题、最大化、关闭，同别的弹窗），下面是看图的工具栏
        window.Content = new Panel { Children = { Dialog.WithTitleBar(window, panel), new ToastLayer(24) } };
        window.Res(Window.BackgroundProperty, "Sheet");
        // 按住标题栏、工具栏空白处拖动、四周拖边改大小（同别的弹窗）；图上按住是拖着看图
        Dialog.Chromeless(window, titleBar: true);
        LastWindow = window;
        window.Closed += (_, _) => { if (LastWindow == window) LastWindow = null; };
        window.AddHandler(InputElement.KeyDownEvent, (_, e) =>
        {
            var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.KeyModifiers.HasFlag(KeyModifiers.Meta);
            switch (e.Key)
            {
                case Key.Escape: window.Close(); break;
                case Key.Right when !ctrl: Step(1); break;
                case Key.Left when !ctrl: Step(-1); break;
                case Key.OemPlus or Key.Add when ctrl: zoom.ZoomBy(1.25); break;
                case Key.OemMinus or Key.Subtract when ctrl: zoom.ZoomBy(1 / 1.25); break;
                case Key.D0 or Key.NumPad0 when ctrl: zoom.ActualSize(); break;
                case Key.D9 or Key.NumPad9 when ctrl: zoom.Fit(); break;
                case Key.C when ctrl: Copy(window, Original); break;
                case Key.S when ctrl: SaveAs(window, Original, name); break;
                default: return;
            }
            e.Handled = true;
        }, RoutingStrategies.Tunnel);
        Dialog.ShowPlaced(window, Dialog.Owner());
        Load();
    }

    /// 工具栏里的一个图标按钮
    static Tap ToolIcon(string symbol, Action action, string tip) =>
        (Tap)new Tap(Ui.Sym(symbol, 16).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center), action, 14) { Width = 34, Height = 30 }
            .Keys("Transparent", "Fill10").Tip(tip);

    /// 一组按钮放在一块玻璃上（同 Mac 版工具栏的分组）
    static Border ToolGroup(params Control?[] items) =>
        new Border { CornerRadius = new CornerRadius(17), Padding = new Thickness(2), BorderThickness = new Thickness(0.5), Child = Ui.H(0, items) }
            .Res(Border.BackgroundProperty, "Glass").Res(Border.BorderBrushProperty, "GlassEdge");

    static string Extension(byte[] data) => data.Length > 3 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 ? "png" : "jpg";

    static async void Copy(Window? window, Func<Task<byte[]?>> original)
    {
        if (await original() is not byte[] data) { AppModel.Shared.Flash(L("无法获取图片")); return; }
        AppModel.Shared.Flash(await ImageClipboard.Copy(window, data) ? L("已拷贝图片") : L("无法拷贝图片"));
    }

    /// 存成文件：原图（PNG / JPEG 原样），默认放「下载」，文件名同 Mac 版
    static async void SaveAs(Window? window, Func<Task<byte[]?>> original, string? name)
    {
        if (window is null) return;
        if (await original() is not byte[] data) { AppModel.Shared.Flash(L("无法获取图片")); return; }
        var ext = Extension(data);
        var options = new FilePickerSaveOptions
        {
            Title = L("存储为文件"), DefaultExtension = ext, ShowOverwritePrompt = true,
            SuggestedFileName = name ?? L("Kiteline 图片 %@.%@", DateTime.Now.ToString("yyyy-MM-dd HH.mm.ss"), ext),
            FileTypeChoices = [ext == "png" ? FilePickerFileTypes.ImagePng : FilePickerFileTypes.ImageJpg],
            SuggestedStartLocation = await window.StorageProvider.TryGetWellKnownFolderAsync(WellKnownFolder.Downloads),
        };
        if (await window.StorageProvider.SaveFilePickerAsync(options) is not { } file) return;
        try
        {
            await using (var stream = await file.OpenWriteAsync()) await stream.WriteAsync(data);
            AppModel.Shared.Flash(L("已存储"));
        }
        catch (Exception e) { AppModel.Shared.Flash(L("存储失败：%@", e.Message)); }
    }

    /// 用系统默认的看图程序打开（同 Mac 版「用『预览』打开」）：存一份到临时目录再打开
    static async void OpenExternally(Func<Task<byte[]?>> original)
    {
        if (await original() is not byte[] data) { AppModel.Shared.Flash(L("无法获取图片")); return; }
        try
        {
            var file = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"Kiteline-{Guid.NewGuid().ToString("N")[..8]}.{Extension(data)}");
            await File.WriteAllBytesAsync(file, data);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(file) { UseShellExecute = true });
        }
        catch (Exception e) { AppModel.Shared.Flash(L("保存失败：%@", e.Message)); }
    }

    /// 让这个缩略图点一下就放大看（本机现成的图）
    public static T ZoomOnClick<T>(this T control, Func<IReadOnlyList<byte[]>> images, Func<int> index, string? name = null) where T : Control
    {
        ToolTip.SetTip(control, L("点击放大查看"));
        return control.OnTap(() => ShowLocal(images(), index(), name));
    }
}

/// 能放大缩小、拖着看的图（同 Mac 版 ZoomImageView）：Ctrl + 滚轮（触控板双指捏合也是这样传来的）以鼠标处为中心缩放；
/// 双击在「适合窗口」和「实际大小」之间切换；放大后按住拖动、滚动移着看。窗口改大小时没手动缩放过的继续适合窗口。
/// 横向放得下时，触控板双指左右划、横向滚轮、或按住左右拖，翻上一张 / 下一张（Swipe）
public sealed class ZoomImage : Panel
{
    readonly ScrollViewer scroll;
    readonly Image image = new() { Stretch = Stretch.Fill };
    readonly LayoutTransformControl holder;
    Point? dragFrom;
    Vector dragOffset;

    /// 现在的倍数（1 = 原图大小）
    public double Scale { get; private set; } = 1;
    /// 跟着窗口适合大小（没手动缩放过）
    public bool Fitting { get; private set; } = true;
    public event Action? Changed;
    /// 左右滑翻页：-1 上一张、1 下一张
    public event Action<int>? Swipe;
    double swipeX;
    bool swiped;
    DateTime swipeAt;
    /// 最近建的一个（自测用）
    public static ZoomImage? Last { get; private set; }

    public ZoomImage()
    {
        Last = this;
        holder = new LayoutTransformControl
        {
            Child = image, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Cursor = new Cursor(StandardCursorType.Hand),
        };
        scroll = new ScrollViewer
        {
            Content = holder, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        Children.Add(scroll);
        scroll.SizeChanged += (_, _) => { if (Fitting) Fit(); };
        AddHandler(PointerWheelChangedEvent, Wheel, RoutingStrategies.Tunnel);
        holder.PointerPressed += Pressed;
        holder.PointerMoved += Moved;
        holder.PointerReleased += (_, e) =>
        {
            // 按住左右拖过 80、横向为主，松手翻页（放大到要横着移时是拖着看，不翻）
            if (dragFrom is Point from && FitsHorizontally)
            {
                var move = e.GetPosition(this) - from;
                if (Math.Abs(move.X) > 80 && Math.Abs(move.X) > Math.Abs(move.Y) * 1.5) Swipe?.Invoke(move.X > 0 ? -1 : 1);
            }
            dragFrom = null;
            e.Pointer.Capture(null);
        };
    }

    public Bitmap? Source
    {
        get => image.Source as Bitmap;
        set
        {
            image.Source = value;
            if (value is not null) { image.Width = value.Size.Width; image.Height = value.Size.Height; }
            Fit();
        }
    }

    /// 适合窗口：整张放得下；小图不放大（最多原大小）
    double FitScale
    {
        get
        {
            if (Source is not { } b || b.Size.Width <= 0 || b.Size.Height <= 0 || scroll.Bounds.Width <= 0) return 1;
            return Math.Min(1, Math.Min(scroll.Bounds.Width / b.Size.Width, scroll.Bounds.Height / b.Size.Height));
        }
    }

    public void Fit()
    {
        Fitting = true;
        Apply(FitScale, null);
    }

    public void ActualSize()
    {
        Fitting = false;
        Apply(1, null);
    }

    public void ZoomBy(double factor, Point? at = null)
    {
        Fitting = false;
        Apply(Scale * factor, at);
    }

    /// 按 at（滚动区里的点，不给就是正中）缩放：缩放前后这一点下面还是图上的同一处
    void Apply(double scale, Point? at)
    {
        scale = Math.Clamp(scale, 0.02, 16);
        var viewport = scroll.Bounds.Size;
        var focus = at ?? new Point(viewport.Width / 2, viewport.Height / 2);
        var extent = scroll.Extent;
        var rel = new Point(extent.Width > 0 ? (scroll.Offset.X + focus.X) / extent.Width : 0.5,
                            extent.Height > 0 ? (scroll.Offset.Y + focus.Y) / extent.Height : 0.5);
        Scale = scale;
        holder.LayoutTransform = new ScaleTransform(scale, scale);
        scroll.UpdateLayout();
        var next = scroll.Extent;
        scroll.Offset = new Vector(Math.Max(0, rel.X * next.Width - focus.X), Math.Max(0, rel.Y * next.Height - focus.Y));
        Changed?.Invoke();
    }

    /// 横向放得下（没放大到要横着移）：这时左右滑是翻页，不是移着看
    bool FitsHorizontally => holder.Bounds.Width <= scroll.Bounds.Width + 1;

    void Wheel(object? sender, PointerWheelEventArgs e)
    {
        if (!e.KeyModifiers.HasFlag(KeyModifiers.Control) && !e.KeyModifiers.HasFlag(KeyModifiers.Meta))
        {
            if (Swipe is null || !FitsHorizontally || Math.Abs(e.Delta.X) <= Math.Abs(e.Delta.Y)) return;
            // 触控板一次划动会连着来很多个事件：停顿 0.4 秒以上算新的一次，一次只翻一张；鼠标横向滚轮一格翻一张
            var now = DateTime.UtcNow;
            if ((now - swipeAt).TotalMilliseconds > 400) { swipeX = 0; swiped = false; }
            swipeAt = now;
            swipeX += e.Delta.X;
            if (!swiped && Math.Abs(swipeX) >= 1) { swiped = true; Swipe(swipeX > 0 ? -1 : 1); }
            e.Handled = true;
            return;
        }
        ZoomBy(Math.Pow(1.15, e.Delta.Y), e.GetPosition(scroll));
        e.Handled = true;
    }

    void Pressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(holder).Properties.IsLeftButtonPressed) return;
        e.Handled = true;
        if (e.ClickCount == 2)
        {
            // 双击：适合窗口 ⇄ 实际大小（对着双击的那一点放大）
            if (Fitting || Math.Abs(Scale - FitScale) < 0.01) { Fitting = false; Apply(FitScale >= 1 ? 2 : 1, e.GetPosition(scroll)); }
            else Fit();
            return;
        }
        dragFrom = e.GetPosition(this);
        dragOffset = scroll.Offset;
        e.Pointer.Capture(holder);
    }

    void Moved(object? sender, PointerEventArgs e)
    {
        if (dragFrom is not Point from) return;
        var now = e.GetPosition(this);
        scroll.Offset = dragOffset - (now - from);
    }
}
