using System.Diagnostics;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using SkiaSharp;
using static Kiteline.Lang;

namespace Kiteline.UI;

/// 窗口外框（同 Mac 的圆角窗口 + 液态玻璃侧栏）：
/// - Windows 11：系统画圆角，窗口底用亚克力（透出后面的桌面并模糊），没有就退到云母、再没有就不透明；
/// - Linux：不用系统标题栏，自己画圆角、阴影、右上角窗口按钮（顺序照 GNOME 的 button-layout），四边拖动改大小；
///   KDE 有窗口模糊就用真模糊；GNOME 没有，侧栏改画模糊后的桌面壁纸（按窗口在屏幕上的位置取那一块），看着同毛玻璃。
public static class WindowChrome
{
    /// Linux 窗口四周留给阴影（兼拖边改大小）的宽度；最大化时为 0
    public const double ShadowMargin = 18;
    public const double Radius = 14;

    /// 是否自己画外框（Linux）
    public static bool Custom => OperatingSystem.IsLinux() && !Program.Headless;

    /// 打开前按所在屏幕的可用范围收小（矮屏幕上 780 高的窗口标题栏会跑到屏幕外、拖不动），再放到正中
    public static void FitToScreen(Window window, double margin = 40)
    {
        if (window.Screens.Primary?.WorkingArea is not { } area) return;
        var scale = window.Screens.Primary.Scaling;
        double maxW = area.Width / scale - margin, maxH = area.Height / scale - margin;
        if (window.MinWidth > maxW) window.MinWidth = maxW;
        if (window.MinHeight > maxH) window.MinHeight = maxH;
        if (window.Width > maxW) window.Width = maxW;
        if (window.Height > maxH) window.Height = maxH;
        window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
    }

    /// 窗口按钮在左边还是右边（Linux 照 GNOME 设置；Windows 系统按钮在右边）
    public static bool ButtonsLeft { get; private set; }
    public static IReadOnlyList<string> Buttons { get; private set; } = ["minimize", "maximize", "close"];

    /// 右上角窗口按钮占的宽度（页面工具栏、标签栏右边让出来）
    public static double CaptionWidth => OperatingSystem.IsWindows() ? 138 : Custom && !ButtonsLeft ? CaptionButtons.WidthFor(Buttons.Count) : 0;
    /// 左上角窗口按钮占的宽度（侧栏顶上的新任务按钮往右挪）
    public static double CaptionLeftWidth => Custom && ButtonsLeft ? CaptionButtons.WidthFor(Buttons.Count) : 0;

    public static void Load()
    {
        if (!Custom) return;
        var layout = Gsettings("org.gnome.desktop.wm.preferences", "button-layout");
        if (string.IsNullOrEmpty(layout)) return;
        var parts = layout.Split(':');
        string[] Names(string s) => s.Split(',').Select(n => n.Trim()).Where(n => n is "minimize" or "maximize" or "close").ToArray();
        var left = Names(parts[0]);
        var right = parts.Length > 1 ? Names(parts[1]) : [];
        if (left.Length > 0 && right.Length == 0) { ButtonsLeft = true; Buttons = left; }
        else if (right.Length > 0) Buttons = right;
        if (!Buttons.Contains("close")) Buttons = [.. Buttons, "close"];   // 关闭总要有
    }

    public static string? Gsettings(string schema, string key)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo("gsettings", ["get", schema, key]) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false });
            if (p is null) return null;
            var output = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit(2000);
            return p.ExitCode == 0 ? output.Trim('\'') : null;
        }
        catch { return null; }
    }

    /// 标题栏那一带的空白处：拖动移窗口，双击最大化 / 还原
    public static void DragWindow(object? sender, PointerPressedEventArgs e)
    {
        if (!ReferenceEquals(e.Source, sender) || sender is not Visual v || TopLevel.GetTopLevel(v) is not Window w || !e.GetCurrentPoint(w).Properties.IsLeftButtonPressed) return;
        if (e.ClickCount == 2) w.WindowState = w.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        else w.BeginMoveDrag(e);
    }

    // MARK: Windows 11 材质、圆角

    /// Windows 上能不能用系统的亚克力 / 云母：Windows 11、开着「透明效果」、有显卡加速
    public static bool WindowsGlass => windowsGlass ??= DetectWindowsGlass();
    static bool? windowsGlass;

    static bool DetectWindowsGlass()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) return false;
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("EnableTransparency") is int on && on == 0) return false;
        }
        catch { }
        // 显示适配器是「基本显示适配器」「远程显示适配器」：系统不画模糊和圆角
        var device = new DisplayDevice { cb = Marshal.SizeOf<DisplayDevice>() };
        for (uint i = 0; EnumDisplayDevices(null, i, ref device, 0); i++)
        {
            if ((device.StateFlags & 1) != 0 && (device.DeviceString.Contains("Basic Display", StringComparison.OrdinalIgnoreCase)
                || device.DeviceString.Contains("Basic Render", StringComparison.OrdinalIgnoreCase) || device.DeviceString.Contains("Remote Display", StringComparison.OrdinalIgnoreCase)))
                return false;
            device = new DisplayDevice { cb = Marshal.SizeOf<DisplayDevice>() };
        }
        return true;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DisplayDevice
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplayDevicesW")]
    static extern bool EnumDisplayDevices(string? device, uint index, ref DisplayDevice info, uint flags);

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// 让系统给窗口画圆角（Windows 11；Windows 10 没有这个属性，调了也没事）
    public static void RoundCorners(Window window)
    {
        if (!OperatingSystem.IsWindows() || window.TryGetPlatformHandle()?.Handle is not IntPtr hwnd) return;
        try
        {
            var round = 2;   // DWMWCP_ROUND
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));   // DWMWA_WINDOW_CORNER_PREFERENCE
        }
        catch { }
    }
}

/// 侧栏的玻璃底：系统有窗口模糊（Windows 亚克力 / 云母、KDE 模糊）时只铺一层半透明的底色；
/// 没有但能透明（GNOME）时画模糊后的桌面壁纸再盖底色；都不行就是不透明的侧栏色
public sealed class SidebarGlass : Control
{
    public enum Mode { Opaque, System, Wallpaper }

    public static Mode Current { get; private set; } = Mode.Opaque;
    public static event Action? Changed;

    public static void Use(Mode mode)
    {
        if (Current == mode) return;
        Current = mode;
        Changed?.Invoke();
    }

    public SidebarGlass()
    {
        IsHitTestVisible = false;
        Changed += InvalidateVisual;
        Wallpaper.Ready += InvalidateVisual;
        ActualThemeVariantChanged += (_, _) => InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        var rect = new Rect(Bounds.Size);
        switch (Current)
        {
            case Mode.System:
                context.FillRectangle(Palette.Get("SidebarTint"), rect);
                break;
            case Mode.Wallpaper when Wallpaper.Image is { } image && TopLevel.GetTopLevel(this) is Window window && window.Screens.ScreenFromWindow(window) is { } screen:
                // 这块控件在屏幕上的位置（物理像素）→ 壁纸图里的那一块
                var origin = this.PointToScreen(new Point(0, 0));
                var scale = window.RenderScaling;
                var screenRect = screen.Bounds;
                var fx = image.PixelSize.Width / (double)screenRect.Width;
                var fy = image.PixelSize.Height / (double)screenRect.Height;
                var source = new Rect((origin.X - screenRect.X) * fx, (origin.Y - screenRect.Y) * fy, Bounds.Width * scale * fx, Bounds.Height * scale * fy);
                context.DrawImage(image, source, rect);
                context.FillRectangle(Palette.Get("SidebarWallpaperTint"), rect);
                break;
            default:
                context.FillRectangle(Palette.Get("Sidebar"), rect);
                break;
        }
    }
}

/// 模糊后的桌面壁纸（GNOME：org.gnome.desktop.background），按主屏大小裁成「铺满」再缩小、模糊
public static class Wallpaper
{
    public static Bitmap? Image { get; private set; }
    public static event Action? Ready;
    static string? loadedFor;

    /// 读壁纸并模糊（后台做）；dark = 深色外观（GNOME 深色模式下用 picture-uri-dark）
    public static void Load(PixelSize screen, bool dark)
    {
        var uri = (dark ? WindowChrome.Gsettings("org.gnome.desktop.background", "picture-uri-dark") : null) is { Length: > 0 } d ? d
            : WindowChrome.Gsettings("org.gnome.desktop.background", "picture-uri");
        var options = WindowChrome.Gsettings("org.gnome.desktop.background", "picture-options") ?? "zoom";
        var color = WindowChrome.Gsettings("org.gnome.desktop.background", "primary-color");
        var key = $"{uri}|{options}|{screen}";
        if (key == loadedFor) return;
        loadedFor = key;
        Task.Run(() =>
        {
            var bitmap = Render(uri, options, color, screen);
            if (bitmap is null) return;
            Dispatcher.UIThread.Post(() =>
            {
                Image = bitmap;
                Ready?.Invoke();
            });
        });
    }

    static Bitmap? Render(string? uri, string options, string? color, PixelSize screen)
    {
        try
        {
            // 缩到屏幕的 1/4 再模糊：又快又省内存，放大回去本来就是糊的
            const int factor = 4;
            var w = Math.Max(1, screen.Width / factor);
            var h = Math.Max(1, screen.Height / factor);
            using var surface = SKSurface.Create(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
            var canvas = surface.Canvas;
            canvas.Clear(SKColor.TryParse(color ?? "", out var fill) ? fill : new SKColor(0x2C, 0x2C, 0x2E));
            var path = uri is null ? null : uri.StartsWith("file://") ? Uri.UnescapeDataString(new Uri(uri).LocalPath) : uri;
            if (path is not null && File.Exists(path) && !path.EndsWith(".xml", StringComparison.OrdinalIgnoreCase) && options != "none")
            {
                using var source = SKBitmap.Decode(path);
                if (source is not null)
                {
                    SKRect dest;
                    var sw = (float)source.Width; var sh = (float)source.Height;
                    switch (options)
                    {
                        case "stretched": case "spanned": dest = new SKRect(0, 0, w, h); break;
                        case "scaled":
                        {
                            var s = Math.Min(w / sw, h / sh);
                            dest = SKRect.Create((w - sw * s) / 2, (h - sh * s) / 2, sw * s, sh * s);
                            break;
                        }
                        case "centered":
                            dest = SKRect.Create((w - sw / factor) / 2, (h - sh / factor) / 2, sw / factor, sh / factor);
                            break;
                        default:   // zoom：铺满、多出来的裁掉
                        {
                            var s = Math.Max(w / sw, h / sh);
                            dest = SKRect.Create((w - sw * s) / 2, (h - sh * s) / 2, sw * s, sh * s);
                            break;
                        }
                    }
                    using var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium, IsAntialias = true };
                    canvas.DrawBitmap(source, dest, paint);
                }
            }
            using var snapshot = surface.Snapshot();
            // 模糊 + 稍微提一点饱和度（同 macOS 的毛玻璃，透出来的颜色更鲜一点）
            using var blurred = SKSurface.Create(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
            var saturation = 1.15f;
            float r = 0.2126f * (1 - saturation), g = 0.7152f * (1 - saturation), b = 0.0722f * (1 - saturation);
            using var colorFilter = SKColorFilter.CreateColorMatrix([
                r + saturation, g, b, 0, 0,
                r, g + saturation, b, 0, 0,
                r, g, b + saturation, 0, 0,
                0, 0, 0, 1, 0,
            ]);
            using var blur = SKImageFilter.CreateBlur(14, 14, SKShaderTileMode.Clamp);
            using var filter = SKImageFilter.CreateColorFilter(colorFilter, blur);
            using (var paint = new SKPaint { ImageFilter = filter })
                blurred.Canvas.DrawImage(snapshot, 0, 0, paint);
            using var image = blurred.Snapshot();
            using var data = image.Encode(SKEncodedImageFormat.Png, 90);
            using var stream = new MemoryStream(data.ToArray());
            return new Bitmap(stream);
        }
        catch { return null; }
    }
}

/// Linux 自己画的窗口按钮（同 GNOME 的样式：圆形淡底、细线图标；关闭在悬停时变红）
public sealed class CaptionButtons : StackPanel
{
    const double Size = 24, Gap = 8, Edge = 14;

    public static double WidthFor(int count) => count * Size + (count - 1) * Gap + Edge * 2;

    public CaptionButtons(Window window, IEnumerable<string> buttons)
    {
        Orientation = Orientation.Horizontal;
        Spacing = Gap;
        Margin = new Thickness(Edge, 0);
        VerticalAlignment = VerticalAlignment.Center;
        foreach (var name in buttons)
        {
            var glyph = new Glyph(name, window);
            var tap = new Tap(glyph, name switch
            {
                "minimize" => () => window.WindowState = WindowState.Minimized,
                "maximize" => () => window.WindowState = window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized,
                _ => window.Close,
            }, Size / 2) { Width = Size, Height = Size }.Keys("Fill08", name == "close" ? "Red" : "Fill12", name == "close" ? "Red" : "Fill15");
            tap.Cursor = Cursor.Default;
            tap.Tip(name switch { "minimize" => L("最小化"), "maximize" => L("最大化"), _ => L("关闭") });
            if (name == "close")
            {
                tap.PointerEntered += (_, _) => glyph.Hot = true;
                tap.PointerExited += (_, _) => glyph.Hot = false;
            }
            Children.Add(tap);
        }
    }

    sealed class Glyph : Control
    {
        readonly string name;
        bool hot;

        public Glyph(string name, Window window)
        {
            this.name = name;
            Width = Size;
            Height = Size;
            IsHitTestVisible = false;
            window.PropertyChanged += (_, e) => { if (e.Property == Window.WindowStateProperty) InvalidateVisual(); };
        }

        public bool Hot { set { hot = value; InvalidateVisual(); } }

        public override void Render(DrawingContext context)
        {
            var brush = hot ? Brushes.White : Palette.Get("Text");
            var pen = new Pen(brush, 1.2, lineCap: PenLineCap.Round);
            var c = Size / 2;
            switch (name)
            {
                case "minimize":
                    context.DrawLine(pen, new Point(c - 4, c + 0.5), new Point(c + 4, c + 0.5));
                    break;
                case "maximize":
                    if (TopLevel.GetTopLevel(this) is Window { WindowState: WindowState.Maximized })
                    {
                        context.DrawRectangle(null, pen, new Rect(c - 4, c - 2, 6, 6), 1, 1);
                        context.DrawLine(pen, new Point(c - 2, c - 4), new Point(c + 4, c - 4));
                        context.DrawLine(pen, new Point(c + 4, c - 4), new Point(c + 4, c + 2));
                    }
                    else context.DrawRectangle(null, pen, new Rect(c - 4, c - 4, 8, 8), 1.5, 1.5);
                    break;
                default:
                    context.DrawLine(pen, new Point(c - 3.8, c - 3.8), new Point(c + 3.8, c + 3.8));
                    context.DrawLine(pen, new Point(c + 3.8, c - 3.8), new Point(c - 3.8, c + 3.8));
                    break;
            }
        }
    }
}
