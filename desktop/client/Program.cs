using Avalonia;

namespace Kiteline;

static class Program
{
    public static string[] Args { get; private set; } = [];
    /// 离屏自测（没有真窗口：不画自己的外框）
    public static bool Headless { get; private set; }

    [STAThread]
    public static int Main(string[] args)
    {
        Args = args;
        // 自测：离屏把主窗口画成图片（同 Mac 版的 --render）：--render <png> [--dark] [--size 宽x高] [--steps "select:@today;wait:2;shot:x.png"]
        if (args.Contains("--render")) { Headless = true; return SelfTest.Run(args); }
        // 已经开着一个：叫它到前面来，这份退出
        if (UI.SingleInstance.ActivateExisting()) return 0;
        UI.SingleInstance.Listen();
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        return 0;
    }

    /// X11 的窗口类名 kiteline：GNOME / KDE 按它对上 kiteline.desktop（概览、任务栏里显示 Kiteline 的图标，和菜单里的 Kiteline 归成一个程序）
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UsePlatformDetect()
        .With(new X11PlatformOptions { WmClass = "kiteline" }).LogToTrace();
}
