using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Kiteline.Model;
using Kiteline.Net;
using Kiteline.UI;
using Kiteline.Views;

namespace Kiteline;

public partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        Palette.Install(this);
        // 所有窗口（主窗口、弹窗、看大图……）的图标：Kiteline 的纸鸢（不然标题栏、任务栏、Alt+Tab 里是系统默认的空白图标）
        var icon = new Avalonia.Controls.WindowIcon(Avalonia.Platform.AssetLoader.Open(new Uri("avares://KitelineApp/Assets/kiteline.ico")));
        var style = new Avalonia.Styling.Style(x => Avalonia.Styling.Selectors.Is<Avalonia.Controls.Window>(x));
        style.Setters.Add(new Avalonia.Styling.Setter(Avalonia.Controls.Window.IconProperty, icon));
        Styles.Add(style);
        // Linux 上 ’ “ ” … 按每段文字的内容排（见 Punctuation）
        Punctuation.Install();
        // Windows 上的中文输入法：每个窗口出来时挂上（Avalonia 自己那套换过输入控件后收不到字，见 WinIme）
        Avalonia.Controls.Control.LoadedEvent.AddClassHandler<Avalonia.Controls.TopLevel>((top, _) => WinIme.Install(top));
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var host = LocalHost.Find(Program.Args);
            // 界面语言：和电脑端后台同一个设置（自测可用 --lang zh / en 指定）
            var lang = Array.IndexOf(Program.Args, "--lang") is var i and >= 0 && i + 1 < Program.Args.Length ? Program.Args[i + 1] : null;
            if (lang is not null) Lang.Pin(lang);
            else Lang.Use(Lang.Saved(host?.ConfigDir ?? LocalHost.ConfigDirectory()));
            if (host is null)
            {
                desktop.MainWindow = new NoHostWindow();
            }
            else
            {
                Boot(host, remember: true);
                desktop.MainWindow = new MainWindow();
                desktop.ShutdownRequested += (_, _) => Prefs.Save();
            }
        }
        base.OnFrameworkInitializationCompleted();
    }

    /// 连上本机后台：读偏好、外观，开实时连接
    public static void Boot(LocalHost host, bool remember)
    {
        if (remember) Prefs.Load(host.ConfigDir); else Prefs.UseMemory();
        Look.Load();
        if (remember) Views.Appearance.Apply();   // 设置里选的浅色 / 深色（自测用命令行的 --dark）
        var model = new AppModel(new Api(host));
        if (remember) ChatPanes.Shared.Remember();
        model.TodosEvent += (_, json) => TodoState.Shared.Apply(json);
        model.FavoritesEvent += (_, json) => Avalonia.Threading.Dispatcher.UIThread.Post(() => FavoriteState.Shared.Apply(json));
        model.Start();
        _ = TodoState.Shared.Refresh();
        _ = FavoriteState.Shared.Refresh();
        if (!Program.Headless) UpdateState.Shared.Start(model.Api);
    }
}
