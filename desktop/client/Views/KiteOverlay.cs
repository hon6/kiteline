using System.Diagnostics;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;

namespace Kiteline.Views;

/// 主窗口顶上飞的纸鸢（同 Mac 版 KiteOverlay，主题色）：一块透明、鼠标穿透的小窗口挂在主窗口上沿，纸鸢的头和翅尖探出窗口上沿，
/// 胸口两根提线汇成一根，垂进侧栏顶部、渐渐隐去（像拴在 App 里）。纸鸢随主窗口移动，主窗口最小化、全屏、关闭时跟着收起。
/// - 窗口上方空间不够（贴着屏幕顶 / 顶栏）时，纸鸢再往下落一点，头不被切掉
/// - 侧栏太窄时不显示
/// - 收起时停掉动画，不耗电；系统关了动画效果就不起飞、不远近缩放
/// - 设置 → 通用 → 外观里可以关掉
public sealed class KiteOverlay
{
    public static KiteOverlay? Shared { get; private set; }

    /// 偏好开关（默认开）
    public static bool Enabled
    {
        get => Prefs.Bool("kiteFlight", true);
        set
        {
            Prefs.Set("kiteFlight", value);
            Prefs.Save();
            Shared?.Refresh();
        }
    }

    /// 纸鸢整体（384 格子）画多大
    const double Span = 124;
    /// 窗口上沿往上留多高：只让头和翅尖探出去（再加上飘动的余量）
    const double Sky = 52;
    /// 往下盖住窗口顶部多少：标题栏 + 搜索框（燕尾、风筝线垂到这里）
    const double Below = 104;
    /// 纸鸢重心在窗口上沿下面多少
    const double Sink = 12;
    /// 纸鸢停的位置按 Mac 版 480 宽的子窗口算；实际的透明小窗口只盖住纸鸢飘动、起飞的范围（重心左边 150、右边 90）：
    /// 透明窗口每帧都要整块重新合成，越小越省（没有显卡的电脑上差一倍）
    const double PanelWidth = 480, Left = 150, Right = 90;

    readonly Window host;
    /// 侧栏：左上角就是主窗口内容的左上角（Linux 的阴影边、最大化时的边框都已经算进去了），宽度决定纸鸢停在哪
    Control sidebar;
    readonly KiteFlight flight = new();
    Window? panel;
    bool opened;

    /// 主窗口搭好内容后调（自测截图时不挂）；换语言重搭内容时再调一次，只换量位置用的侧栏
    public static void Attach(Window host, Control sidebar)
    {
        if (Program.Headless) return;
        if (Shared is { } overlay && overlay.host == host)
        {
            overlay.sidebar.SizeChanged -= overlay.SidebarResized;
            overlay.sidebar = sidebar;
            sidebar.SizeChanged += overlay.SidebarResized;
            return;
        }
        Shared = new KiteOverlay(host, sidebar);
    }

    void SidebarResized(object? sender, SizeChangedEventArgs e) => Layout();

    KiteOverlay(Window host, Control sidebar)
    {
        this.host = host;
        this.sidebar = sidebar;
        host.Opened += (_, _) => { opened = true; Refresh(); };
        host.Closed += (_, _) => { opened = false; Hide(); };
        host.PositionChanged += (_, _) => Layout();
        host.PropertyChanged += (_, e) =>
        {
            if (e.Property == Window.WindowStateProperty || e.Property == Visual.IsVisibleProperty) Refresh();
        };
        // 拖侧栏改宽度、窗口大小变了：重排
        sidebar.SizeChanged += SidebarResized;
    }

    /// 该显示就挂上并重新排位置，不该显示就收起
    public void Refresh()
    {
        // 世界模式里收起了会话列表：纸鸢跟着侧栏一起收起来（不然停在世界的标题条上）
        var visible = opened && host.IsVisible && host.WindowState is not (WindowState.Minimized or WindowState.FullScreen) && Enabled && sidebar.IsVisible;
        if (!visible) { Hide(); return; }
        panel ??= MakePanel();
        if (!panel.IsVisible)
        {
            panel.Show(host);
            ClickThrough(panel);
            // 每次重新出现都从左下方飞上来
            flight.Takeoff();
        }
        Layout();
        flight.Paused = false;
    }

    void Hide()
    {
        flight.Paused = true;
        panel?.Hide();
    }

    Window MakePanel()
    {
        var window = new Window
        {
            Title = "Kiteline",
            SystemDecorations = SystemDecorations.None,
            CanResize = false,
            ShowInTaskbar = false,
            ShowActivated = false,
            Focusable = false,
            IsHitTestVisible = false,
            WindowStartupLocation = WindowStartupLocation.Manual,
            TransparencyLevelHint = [WindowTransparencyLevel.Transparent],
            Background = Brushes.Transparent,
            Width = Left + Right,
            Height = Sky + Below,
            Content = flight,
        };
        window.Opened += (_, _) => Layout();
        return window;
    }

    /// 排位置：小窗口贴着主窗口内容的左上角，往上伸出 headroom、往下盖住标题栏
    void Layout()
    {
        if (panel is not { IsVisible: true } || !opened || TopLevel.GetTopLevel(sidebar) is null) return;
        var scale = host.RenderScaling;
        var top = sidebar.PointToScreen(new Point(0, 0));
        var work = host.Screens.ScreenFromWindow(host)?.WorkingArea;
        var headroom = Math.Clamp(work is { } area ? (top.Y - area.Y) / scale : Sky, 0, Sky);
        // 重心在窗口上沿下面一点：头和翅尖探出窗口，身子落在标题栏里。上面没地方时再往下挪，头不被切掉
        var sink = Sink + Math.Max(0, 18 - headroom);
        var width = sidebar.Bounds.Width;
        flight.IsVisible = width >= 220;
        var homeX = Math.Min(PanelWidth - 70, Math.Max(170, width - 78));
        // 线从结往下垂，在搜索框上渐渐隐去
        flight.Configure(new Point(Left, headroom + sink), new Point(Left + 24, headroom + 74), Span);
        if (Math.Abs(panel.Height - (headroom + Below)) > 0.5) panel.Height = headroom + Below;
        // 窗口的 Position 和内容左上角之间可能差一圈边框，按实际量的补上
        var inset = panel.PointToScreen(new Point(0, 0)) - panel.Position;
        var at = new PixelPoint(top.X + (int)Math.Round((homeX - Left) * scale) - inset.X, top.Y - (int)Math.Round(headroom * scale) - inset.Y);
        if (panel.Position != at) panel.Position = at;
    }

    /// 鼠标点上去穿透到下面（主窗口或别的程序），也不抢焦点、不进 Alt+Tab
    static void ClickThrough(Window window)
    {
        if (window.TryGetPlatformHandle()?.Handle is not IntPtr handle || handle == IntPtr.Zero) return;
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var style = GetWindowLongPtr(handle, GWL_EXSTYLE).ToInt64();
                SetWindowLongPtr(handle, GWL_EXSTYLE, new IntPtr(style | WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE));
                SetLayeredWindowAttributes(handle, 0, 255, LWA_ALPHA);
            }
            else if (OperatingSystem.IsLinux())
            {
                // X11：输入区域设成空（窗口照样画，点击落到下面的窗口）
                display = display == IntPtr.Zero ? XOpenDisplay(IntPtr.Zero) : display;
                if (display == IntPtr.Zero) return;
                XShapeCombineRectangles(display, handle, ShapeInput, 0, 0, IntPtr.Zero, 0, ShapeSet, 0);
                XFlush(display);
            }
        }
        catch { }
    }

    static IntPtr display;

    const int GWL_EXSTYLE = -20;
    const long WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;
    const uint LWA_ALPHA = 2;
    const int ShapeInput = 2, ShapeSet = 0;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")]
    static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);
    [DllImport("libX11.so.6")]
    static extern IntPtr XOpenDisplay(IntPtr name);
    [DllImport("libX11.so.6")]
    static extern int XFlush(IntPtr display);
    [DllImport("libXext.so.6")]
    static extern void XShapeCombineRectangles(IntPtr display, IntPtr window, int kind, int x, int y, IntPtr rectangles, int count, int op, int ordering);
}

/// 顶上飞的纸鸢（同 Mac 版 KiteFlightView，动作参数一样）：120 秒一圈，各个周期都取 120 的约数，首尾无缝衔接——
/// 左右飘、上下浮（两组周期叠加），身子随风偏，远近微缩放，两条燕尾各自摆；线从提线结拉到 anchor，
/// 中段往下坠一点、横着轻晃（线越长坠得越多），由实到虚渐渐隐去。起飞时只升纸鸢，线头留在原处，线跟着一点点放长。
/// 坐标都是 y 朝下；home = 纸鸢重心停在哪，anchor = 线拴在哪
public sealed class KiteFlight : Panel
{
    const double Loop = 120;
    const double Fps = 30;
    const double TakeoffDuration = 1.6, FadeDuration = 0.55;

    Point home, anchor;
    double span = 124;
    /// 一圈里走到第几秒、起飞走了几秒（暂停时都停住）
    double clock, takeoff = TakeoffDuration;
    readonly bool reduceMotion = ReduceMotion();
    readonly Stopwatch watch = new();
    DispatcherTimer? timer;
    bool paused = true;

    public KiteFlight()
    {
        IsHitTestVisible = false;
        Children.Add(new Layer(context => { DrawLine(context); DrawKite(context); }));
    }

    public void Configure(Point home, Point anchor, double span)
    {
        if (home == this.home && anchor == this.anchor && span == this.span) return;
        this.home = home;
        this.anchor = anchor;
        this.span = span;
        Redraw();
    }

    /// 从左下方升起来、慢慢停到原位
    public void Takeoff()
    {
        if (reduceMotion) return;
        takeoff = 0;
        Opacity = 0;
        Redraw();
    }

    /// 暂停 / 继续（看不见的时候停住，不耗电）
    public bool Paused
    {
        get => paused;
        set
        {
            if (value == paused) return;
            paused = value;
            if (paused) { timer?.Stop(); watch.Stop(); return; }
            watch.Restart();
            timer ??= new DispatcherTimer(TimeSpan.FromSeconds(1 / Fps), DispatcherPriority.Render, (_, _) => Tick());
            timer.Start();
        }
    }

    void Tick()
    {
        var delta = watch.Elapsed.TotalSeconds;
        watch.Restart();
        clock = (clock + delta) % Loop;
        if (takeoff < TakeoffDuration) takeoff = Math.Min(TakeoffDuration, takeoff + delta);
        Redraw();
    }

    void Redraw()
    {
        Opacity = Math.Min(1, takeoff / FadeDuration);
        foreach (var child in Children) child.InvalidateVisual();
    }

    static double Wave(double t, double period, double phase = 0) => Math.Sin(2 * Math.PI * t / period + phase);

    /// 起飞这一段纸鸢离原位多远（缓出：先快后慢停住）
    Vector Rise()
    {
        if (takeoff >= TakeoffDuration) return default;
        var left = 1 - Bezier(takeoff / TakeoffDuration, 0.2, 0.7, 0.3, 1);
        return new Vector(-span * 0.35 * left, span * 0.55 * left);
    }

    /// 第 t 秒纸鸢的姿态：重心、身子偏的角度（弧度，顺时针为正）、远近缩放、提线结在哪
    (Point Center, double Angle, double Depth, Point Knot) Pose(double t)
    {
        var k = span / 100;
        var unit = span / KiteMark.Grid;
        var dx = (7 * Wave(t, 10) + 2.5 * Wave(t, 4, 1.1)) * k;
        var dy = (6 * Wave(t, 6, 0.5) + 2 * Wave(t, 3)) * k;
        var angle = (4 * Wave(t, 5, 0.3) + 1.5 * Wave(t, 2, 0.7) + 2 * Wave(t, 10, Math.PI / 2)) * Math.PI / 180;
        var depth = reduceMotion ? 1 : 1 + 0.03 * Wave(t, 8);
        var center = home + new Vector(dx, dy) + Rise();
        // 提线结跟着纸鸢转：结相对重心的偏移转过 angle、缩放 depth
        double ox = (KiteMark.Knot.X - KiteMark.Center.X) * unit * depth, oy = (KiteMark.Knot.Y - KiteMark.Center.Y) * unit * depth;
        var knot = new Point(center.X + ox * Math.Cos(angle) - oy * Math.Sin(angle), center.Y + ox * Math.Sin(angle) + oy * Math.Cos(angle));
        return (center, angle, depth, knot);
    }

    double Scaling => TopLevel.GetTopLevel(this)?.RenderScaling ?? 1;

    void DrawLine(DrawingContext ctx)
    {
        var knot = Pose(clock).Knot;
        var chord = anchor - knot;
        var length = Math.Sqrt(chord.X * chord.X + chord.Y * chord.Y);
        var sag = length * (0.07 + 0.02 * Wave(clock, 3));
        var swing = length * 0.05 * Wave(clock, 2.4, 0.9);
        var path = new StreamGeometry();
        using (var g = path.Open())
        {
            g.BeginFigure(knot, false);
            g.CubicBezierTo(new Point(knot.X + chord.X * 0.3 + swing, knot.Y + chord.Y * 0.3 + sag),
                            new Point(knot.X + chord.X * 0.7 + swing * 0.5, knot.Y + chord.Y * 0.7 + sag * 0.8), anchor);
            g.EndFigure(false);
        }
        var color = Palette.GetColor("Accent");
        var brush = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(knot, RelativeUnit.Absolute),
            EndPoint = new RelativePoint(anchor, RelativeUnit.Absolute),
            GradientStops =
            {
                new GradientStop(Color.FromArgb(191, color.R, color.G, color.B), 0),
                new GradientStop(Color.FromArgb(191, color.R, color.G, color.B), 0.4),
                new GradientStop(Color.FromArgb(0, color.R, color.G, color.B), 1),
            },
        };
        // 至少一个物理像素粗，不然 100% 缩放下几乎看不见
        var width = Math.Max(1.2 * span / KiteMark.Grid, 1 / Scaling);
        ctx.DrawGeometry(null, new Pen(brush, width, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round), path);
    }

    void DrawKite(DrawingContext ctx)
    {
        var (center, angle, depth, _) = Pose(clock);
        var unit = span / KiteMark.Grid;
        var art = Art();
        var brush = Palette.Get("Accent");
        var matrix = Matrix.CreateTranslation(-KiteMark.Center.X, -KiteMark.Center.Y) * Matrix.CreateScale(unit * depth, unit * depth)
                     * Matrix.CreateRotation(angle) * Matrix.CreateTranslation(center.X, center.Y);
        using (ctx.PushTransform(matrix))
        {
            // 阴影往下 4 点（身子偏的角度很小，跟着一起转看不出来）
            ctx.DrawImage(art.Shadow, KiteArt.Box.Translate(new Vector(0, 4 / (unit * depth))));
            Tail(art.TailLeft, KiteMark.TailLeftRoot, 3.5 * Wave(clock, 1.5));
            Tail(art.TailDown, KiteMark.TailDownRoot, 3 * Wave(clock, 2, 1.3));
            ctx.DrawGeometry(brush, null, art.Others);
        }

        void Tail(Geometry tail, Point root, double degrees)
        {
            var turn = Matrix.CreateTranslation(-root.X, -root.Y) * Matrix.CreateRotation(degrees * Math.PI / 180) * Matrix.CreateTranslation(root.X, root.Y);
            using (ctx.PushTransform(turn)) ctx.DrawGeometry(brush, null, tail);
        }
    }

    KiteArt? art;

    /// 换了主题色、缩放、大小才重新出图
    KiteArt Art()
    {
        var color = Palette.GetColor("Accent");
        var scaling = Scaling;
        if (art is null || art.Color != color || art.Scaling != scaling || art.Span != span)
            art = new KiteArt(color, scaling, span);
        return art;
    }

    /// CSS 那种三次贝塞尔缓动：x 是时间进度，返回动作进度
    static double Bezier(double x, double x1, double y1, double x2, double y2)
    {
        var s = x;
        for (var i = 0; i < 8; i++)
        {
            var error = 3 * x1 * s * (1 - s) * (1 - s) + 3 * x2 * s * s * (1 - s) + s * s * s - x;
            var slope = 3 * x1 * (1 - s) * (1 - s) + 6 * (x2 - x1) * s * (1 - s) + 3 * (1 - x2) * s * s;
            if (Math.Abs(slope) < 1e-6) break;
            s = Math.Clamp(s - error / slope, 0, 1);
        }
        return 3 * y1 * s * (1 - s) * (1 - s) + 3 * y2 * s * s * (1 - s) + s * s * s;
    }

    /// 系统关了动画效果（Windows「动画效果」、GNOME「动画」）
    static bool ReduceMotion()
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var on = true;
                return SystemParametersInfo(0x1042, 0, ref on, 0) && !on;   // SPI_GETCLIENTAREAANIMATION
            }
            if (OperatingSystem.IsLinux())
            {
                var info = new ProcessStartInfo("gsettings", "get org.gnome.desktop.interface enable-animations") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
                using var p = Process.Start(info);
                var output = p?.StandardOutput.ReadToEnd().Trim();
                p?.WaitForExit(1000);
                return output == "false";
            }
        }
        catch { }
        return false;
    }

    [DllImport("user32.dll")]
    static extern bool SystemParametersInfo(uint action, uint param, ref bool value, uint winIni);

    sealed class Layer(Action<DrawingContext> draw) : Control
    {
        public override void Render(DrawingContext context) => draw(context);
    }
}

/// 顶上纸鸢的三层形状（两条燕尾 + 其余连提线）和预先模糊好的阴影位图：纸鸢每帧按矢量画（Skia 有缓存，比贴位图省），
/// 阴影只在换了主题色、缩放、大小时算一次（逐帧做模糊太费）。位图盖住 384 格子外加一圈 Pad（留给模糊）
sealed class KiteArt
{
    public const double Pad = 60;
    public static readonly Rect Box = new(-Pad, -Pad, KiteMark.Grid + Pad * 2, KiteMark.Grid + Pad * 2);
    public readonly Color Color;
    public readonly double Scaling, Span;
    public readonly Geometry TailLeft, TailDown, Others;
    public readonly Bitmap Shadow;

    public KiteArt(Color color, double scaling, double span)
    {
        Color = color;
        Scaling = scaling;
        Span = span;
        var unit = span / KiteMark.Grid;
        // 提线同 Mac（1.2 格子单位），低分屏上加粗到至少 0.8 个像素，看得见
        (TailLeft, TailDown, Others) = KiteMark.Layers(Math.Max(1.2, Math.Round(0.8 / (unit * scaling) * 4) / 4));
        // 阴影：整只纸鸢的剪影模糊开（同 Mac 的 shadowRadius 6、不透明度 0.22）
        var pixels = (int)Math.Ceiling((KiteMark.Grid + Pad * 2) * unit * scaling);
        var silhouette = Paint(new CombinedGeometry(GeometryCombineMode.Union, new CombinedGeometry(GeometryCombineMode.Union, TailLeft, TailDown), Others), pixels);
        Shadow = Blur(silhouette, 4 * scaling, 0.22);
    }

    static RenderTargetBitmap Paint(Geometry geometry, int pixels)
    {
        var bitmap = new RenderTargetBitmap(new PixelSize(pixels, pixels), new Vector(96, 96));
        var scale = pixels / (KiteMark.Grid + Pad * 2);
        using (var ctx = bitmap.CreateDrawingContext())
        using (ctx.PushTransform(Matrix.CreateTranslation(Pad, Pad) * Matrix.CreateScale(scale, scale)))
            ctx.DrawGeometry(Brushes.Black, null, geometry);
        return bitmap;
    }

    /// 只取透明度，三遍方框模糊近似高斯（sigma 像素），画成黑色、乘上 opacity
    static Bitmap Blur(Bitmap source, double sigma, double opacity)
    {
        var size = source.PixelSize;
        int w = size.Width, h = size.Height, stride = w * 4;
        var bytes = new byte[stride * h];
        var handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try { source.CopyPixels(new PixelRect(size), handle.AddrOfPinnedObject(), bytes.Length, stride); }
        finally { handle.Free(); }
        var alpha = new float[w * h];
        for (var i = 0; i < alpha.Length; i++) alpha[i] = bytes[i * 4 + 3];
        var radius = Math.Max(1, (int)Math.Round(Math.Sqrt(4 * sigma * sigma + 1) / 2));
        var temp = new float[alpha.Length];
        for (var pass = 0; pass < 3; pass++)
        {
            BoxBlur(alpha, temp, w, h, radius, horizontal: true);
            BoxBlur(temp, alpha, w, h, radius, horizontal: false);
        }
        var output = new WriteableBitmap(size, new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Premul);
        var result = new byte[stride * h];
        for (var i = 0; i < alpha.Length; i++) result[i * 4 + 3] = (byte)Math.Clamp(Math.Round(alpha[i] * opacity), 0, 255);
        using (var locked = output.Lock())
            for (var y = 0; y < h; y++) Marshal.Copy(result, y * stride, locked.Address + y * locked.RowBytes, stride);
        return output;
    }

    static void BoxBlur(float[] from, float[] to, int w, int h, int r, bool horizontal)
    {
        int lines = horizontal ? h : w, length = horizontal ? w : h;
        for (var line = 0; line < lines; line++)
        {
            int At(int i) => horizontal ? line * w + i : i * w + line;
            float sum = 0;
            for (var i = -r; i <= r; i++) sum += i >= 0 && i < length ? from[At(i)] : 0;
            for (var i = 0; i < length; i++)
            {
                to[At(i)] = sum / (2 * r + 1);
                var add = i + r + 1;
                var drop = i - r;
                if (add < length) sum += from[At(add)];
                if (drop >= 0) sum -= from[At(drop)];
            }
        }
    }
}
