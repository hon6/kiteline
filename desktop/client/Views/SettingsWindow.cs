using System.Diagnostics;
using System.Globalization;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using QRCoder;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// Kiteline 设置（同 Mac 版 SettingsWindow）：顶上一排页签（图标 + 名字），下面是这一页。
/// 改的是本机 Kiteline 后台的配置（经 /api/desktop/*、/api/profile 等接口），外观、字体这些只改这个客户端
public sealed class SettingsWindow : Window
{
    static SettingsWindow? shown;
    /// 自测截图用
    public static Window? Current => shown;

    /// 顶上的标签。英文另写一套短的（同 Mac 版 SettingsTab.title）：11 个标签要在 800 宽的窗口里摆下，表里的长译名放不下
    static readonly (string Id, string Symbol, string Title, string English)[] Tabs =
    [
        ("general", "gearshape", "通用", "General"), ("phrases", "text.bubble", "快捷短语", "Replies"), ("schedules", "alarm", "定时任务", "Schedules"),
        ("phone", "iphone", "手机访问", "Phone"), ("remote", "globe", "远程访问", "Remote"), ("devices", "person.badge.key", "设备", "Devices"),
        ("watch", "applewatch", "Apple Watch", "Watch"), ("sources", "server.rack", "来源", "Sources"), ("plugins", "puzzlepiece.extension", "插件", "Plugins"),
        ("permissions", "lock.shield", "权限", "Privacy"),
        ("audit", "list.bullet.rectangle", "操作记录", "Log"), ("about", "info.circle", "关于", "About"),
    ];

    static string TabTitle(string id) => Tabs.First(t => t.Id == id) is var tab && Lang.IsEnglish ? tab.English : tab.Title;

    readonly StackPanel tabs = new() { Orientation = Orientation.Horizontal, Spacing = 2, HorizontalAlignment = HorizontalAlignment.Center };
    readonly ContentControl page = new();
    string current = "general";
    DispatcherTimer? ticker;

    public static void Open(string tab)
    {
        if (shown is null)
        {
            shown = new SettingsWindow();
            shown.Closed += (_, _) => shown = null;
            WindowChrome.FitToScreen(shown);
            shown.Show();
        }
        shown.Select(Tabs.Any(t => t.Id == tab) ? tab : "general");
        shown.Activate();
    }

    SettingsWindow()
    {
        Width = 800;
        Height = 720;
        MinWidth = 800;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Look.Family;
        this.Res(BackgroundProperty, "Window");
        var bar = new Border { Child = tabs, Padding = new Thickness(0, 10, 0, 10), BorderThickness = new Thickness(0, 0, 0, 0.5) }
            .Res(Border.BorderBrushProperty, "Separator");
        var dock = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        dock.Children.Add(bar);
        dock.Children.Add(new ScrollViewer { Content = page, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled });
        Content = new Panel { Children = { dock, new ToastLayer(24) } };
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        // 换了界面语言：标签栏和当前页按新语言重画
        void Relabel() { FontFamily = Look.Family; Select(current); }
        Lang.Changed += Relabel;
        Closed += (_, _) => { ticker?.Stop(); Lang.Changed -= Relabel; };
    }

    void Select(string id)
    {
        current = id;
        tabs.Children.Clear();
        foreach (var (tabId, symbol, _, _) in Tabs)
        {
            var on = tabId == id;
            var content = Ui.Stack(Orientation.Vertical, 3, Align.Center, [Ui.Sym(symbol, 20, on ? "Text" : "Text2"), Ui.Text(TabTitle(tabId), 12, on ? FontWeight.SemiBold : FontWeight.Normal, on ? "Text" : "Text2")]);
            var tap = new Tap(content.Pad(8, 6), () => Select(tabId), 8) { MinWidth = 60 };
            if (on) tap.Keys("Fill10", "Fill10"); else tap.Keys("Transparent", "Fill05");
            tabs.Children.Add(tap);
        }
        Title = id == "general" ? L("Kiteline 设置") : TabTitle(id);
        ticker?.Stop();
        ticker = null;
        page.Content = id switch
        {
            "general" => General(),
            "phrases" => Phrases(),
            "schedules" => Schedules(),
            "phone" => Phone(),
            "remote" => Remote(),
            "devices" => Devices(),
            "watch" => Watch(),
            "sources" => Sources(),
            "plugins" => PluginsPage.Build(),
            "permissions" => Permissions(),
            "audit" => Audit(),
            _ => About(),
        };
    }

    static Kiteline.Net.Api Api => AppModel.Shared.Api;

    static async void Post(string path, JsonObject body, Action<JsonNode?>? done = null)
    {
        try { done?.Invoke(await Api.Post(path, body)); }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
    }

    /// 先放一个转圈，数据回来再画
    static Control Loading(Func<Task<Control>> build)
    {
        var host = new ContentControl { Content = new Spinner(18).HAlign(HorizontalAlignment.Center).Margin(0, 60, 0, 0) };
        Dispatcher.UIThread.Post(async () =>
        {
            try { host.Content = await build(); }
            catch (Exception e) { host.Content = Form.Section(null, [], e.Message); }
        });
        return host;
    }

    // MARK: 通用

    Control General() => Loading(async () =>
    {
        var config = await Api.Get("/api/desktop/config") ?? new JsonObject();
        var status = await Api.Get("/api/desktop/status");
        var profile = await Api.Get("/api/profile");
        var budget = await Api.Get("/api/budget");
        var bark = await Api.Get("/api/bark");
        var form = Form.Page();
        void Set(string key, JsonNode? value) => Post("/api/desktop/config", new JsonObject { [key] = value });

        form.Children.Add(ProfileSection(profile));
        form.Children.Add(LookSection(status));
        // 消息翻译（同 Mac 版 设置 → 通用 →「翻译」）：存在这台电脑的客户端偏好里
        form.Children.Add(TranslateUi.Section());
        form.Children.Add(Form.Section(L("会话之间的消息"), [
            Form.Toggle(L("纸鸢传信：纸鸢从发信会话飞到收信会话"), PeerPrefs.Flights, on => PeerPrefs.Set(PeerPrefs.FlightsKey, on)),
            Form.Toggle(L("风筝线：流动的虚线连起最近 15 分钟有往来的会话"), PeerPrefs.Lanes, on => PeerPrefs.Set(PeerPrefs.LanesKey, on)),
            Form.Toggle(L("对话中显示「致 / 来自」某会话的信件"), PeerPrefs.Cards, on => PeerPrefs.Set(PeerPrefs.CardsKey, on)),
            Form.Toggle(L("分屏中的信绳：同一封信的两张信件用绳子连起"), PeerPrefs.Ropes, on => PeerPrefs.Set(PeerPrefs.RopesKey, on)),
        ], L("会话之间用 SendMessage 互发消息时显示。会话开在分屏中时，纸鸢在标签之间飞。")));

        // 提醒：免打扰时段开了才出两个时间
        var quietTimes = new ContentControl();
        void DrawQuiet(string start, string end) => quietTimes.Content = start.Length == 0 ? null
            : Form.Row(L("时段"), Ui.H(8, Ui.Text(L("从"), 13, color: "Text2"), TimeBox(start, t => Set("quietStart", t)), Ui.Text(L("到"), 13, color: "Text2"), TimeBox(end, t => Set("quietEnd", t))));
        DrawQuiet(config.Str("quietStart") ?? "", config.Str("quietEnd") ?? "");
        form.Children.Add(Form.Section(L("提醒"), [
            Form.Toggle(L("Claude 请求确认时提醒"), config.Truthy("notifyOnNeedsAttention"), on => Set("notifyOnNeedsAttention", on)),
            Form.Toggle(L("Claude 完成任务时提醒"), config.Truthy("notifyOnConclusion"), on => Set("notifyOnConclusion", on)),
            Form.Toggle(L("等待确认超过 10 分钟、30 分钟时再次提醒"), config.Truthy("remindWaiting"), on => Set("remindWaiting", on)),
            Form.Toggle(L("免打扰时段（仅推送需要确认的消息）"), (config.Str("quietStart") ?? "").Length > 0, on =>
            {
                Set("quietStart", on ? "23:00" : "");
                Set("quietEnd", on ? "08:00" : "");
                DrawQuiet(on ? "23:00" : "", on ? "08:00" : "");
            }),
            quietTimes,
        ]));

        if (config["autoCloseIdle"] is not null)   // 旧版后台没有这项
            form.Children.Add(Form.Section(L("会话"), [
                Form.Toggle(L("自动关闭 24 小时未查看的会话"), config.Truthy("autoCloseIdle"), on => Set("autoCloseIdle", on)),
            ], L("24 小时内未在 Kiteline 中打开过详情的会话（包括已标记、已置顶的），将自动关闭其在电脑上的标签页并移入「历史会话」；其他会话发来消息、会话在后台回复均不计为打开。正在运行的会话待本轮结束后再关闭；需要切换 VS Code 时，等电脑 10 分钟无人操作后进行。在历史会话中打开并发送消息即可恢复。")));

        form.Children.Add(Form.Section(L("日报"), [
            TimedToggle(L("每天推送日报"), L("推送时间"), config.Str("digestTime") ?? "", "21:30", t => Set("digestTime", t)),
            TimedToggle(L("早安简报（昨晚动态及待确认会话）"), L("早安简报时间"), config.Str("morningTime") ?? "", "08:30", t => Set("morningTime", t)),
        ], L("按时汇总当天各项目的工作内容（对话轮数、改动文件、测试结果、截图），推送到手机。")));

        form.Children.Add(BarkSection(bark));
        form.Children.Add(BudgetSection(budget));

        var locales = new[] { ("zh-CN", L("普通话")), ("zh-HK", L("粤语")), ("zh-TW", L("台湾国语")), ("en-US", "English") };
        var localeBox = new ComboBox { Width = 160, ItemsSource = locales.Select(l => l.Item2).ToList(), SelectedIndex = Math.Max(0, Array.FindIndex(locales, l => l.Item1 == config.Str("voiceLocale"))) };
        localeBox.SelectionChanged += (_, _) => { if (localeBox.SelectedIndex >= 0) Set("voiceLocale", locales[localeBox.SelectedIndex].Item1); };
        form.Children.Add(Form.Section(L("从手机或本机发送消息"), [
            Form.Toggle(L("发送后直接提交给 Claude"), config.Truthy("submitOnSend"), on => Set("submitOnSend", on)),
            Form.Row(L("「按住说话」识别语言"), localeBox),
        ]));
        // VS Code 在虚拟屏幕中运行（同 Mac 版 VirtualScreenSection、侧栏底栏的显示器按钮）
        VirtualScreenState.Shared.Apply(status.Obj("virtualScreen"));
        if (VirtualScreenState.Shared.Supported) form.Children.Add(VirtualScreenSection());
        form.Children.Add(Form.Section(L("Agent 集成"), [
            // 三项技能（同 Mac 版）：由各台电脑上的 watcher 装给 Claude Code、Codex、OpenCode、DeepSeek Harness 等，关掉就删掉
            Form.Toggle(L("安装截图技能"), config["installAgentSkill"] is null || config.Truthy("installAgentSkill"), on => Set("installAgentSkill", on)),
            Form.Toggle(L("安装网页测试技能"), config["installTestSkill"] is null || config.Truthy("installTestSkill"), on => Set("installTestSkill", on)),
            Form.Toggle(L("安装待办与关键信息技能"), config["installTodoSkill"] is null || config.Truthy("installTodoSkill"), on => Set("installTodoSkill", on)),
            Form.Toggle(L("安装任务阶段技能"), config["installStageSkill"] is null || config.Truthy("installStageSkill"), on => Set("installStageSkill", on)),
            Form.Row(L("其他编程 agent"), Form.Button(L("在「插件」中管理"), () => Select("plugins"))),
        ], L("技能会装给这台电脑和远端电脑上的各个编程 agent（Claude Code、Codex、OpenCode、DeepSeek Harness 等）。截图技能使 agent 回复时尽量附带相关截图；网页测试技能使 agent 完成网页功能后在浏览器中实际操作一遍，并发来带截图的测试报告；待办与关键信息技能使 agent 把需要以后处理的事加入待办，并把账号、密码等关键信息单独发来，方便收藏；任务阶段技能使 agent 按任务的实际做法规划步骤，并在进入每一步时主动报告，会话列表据此显示「2/4 开发中」；Claude Code 进入下一步却没有报告时，Kiteline 会提醒它补报（未安装时按 agent 的操作自动识别）。各 agent 的接入、开关和兼容情况在「插件」页查看和管理。")));
        form.Children.Add(Form.Section(L("启动"), [
            Form.Toggle(OperatingSystem.IsWindows() ? L("开机时自动启动 Kiteline") : L("登录时自动启动 Kiteline"), status.Truthy("autostart"),
                on => Post("/api/desktop/settings", new JsonObject { ["autostart"] = on })),
        ], L("自动启动时只在后台运行（托盘图标），不打开主窗口。")));
        form.Children.Add(Form.Section(L("帮助改进 Kiteline"), [
            Form.Toggle(L("发送使用统计"), config.Truthy("usageStats"), on => Set("usageStats", on)),
        ], L("定期发送设备数量与型号、会话的 Agent、模型、token 用量、上下文长度与时长，以及你在 Kiteline 中的名字，用于改进产品。不包含对话、代码、文件和项目路径。")));
        return form;
    });

    /// 「VS Code 在虚拟屏幕中运行」：开关 + 开着时虚拟屏幕里有几个窗口；底栏按钮、托盘菜单里开关了也跟着变
    static Control VirtualScreenSection()
    {
        var screen = VirtualScreenState.Shared;
        var host = new ContentControl();
        void Draw() => host.Content = Form.Section("VS Code", [
            Form.Toggle(L("VS Code 在虚拟屏幕中运行"), screen.On, on => { if (on != screen.On) screen.Toggle(on); }),
            screen.On ? Form.Value(L("虚拟屏幕中的窗口"), L("%lld 个", screen.Windows)) : null,
        ], L("将 VS Code 的窗口移到一块看不见的虚拟屏幕上：Kiteline 发送消息、按键时，VS Code 不会出现在你面前，完成后自动回到你原来使用的程序。鼠标不会进入虚拟屏幕。需要查看 VS Code 时，关闭此项或点击「在 VS Code 中打开」即可移回；退出 Kiteline 时窗口自动回到原处。"));
        void Changed(object? _, System.ComponentModel.PropertyChangedEventArgs e) => Dispatcher.UIThread.Post(Draw);
        screen.PropertyChanged += Changed;
        host.DetachedFromVisualTree += (_, _) => screen.PropertyChanged -= Changed;
        Draw();
        return host;
    }

    /// 带时间的开关：开了才出时间框
    static Control TimedToggle(string label, string timeLabel, string value, string fallback, Action<string> changed)
    {
        var holder = new StackPanel();
        var time = new ContentControl();
        void Draw(string v) => time.Content = v.Length == 0 ? null : Ui.Rule("Separator", 0.5).Margin(10, 0, 10, 0) is var rule
            ? new StackPanel { Children = { rule, Form.Row(timeLabel, TimeBox(v, changed)) } } : null;
        holder.Children.Add(Form.Toggle(label, value.Length > 0, on => { var v = on ? fallback : ""; changed(v); Draw(v); }));
        holder.Children.Add(time);
        Draw(value);
        return holder;
    }

    /// 时间框（同 Mac 表单里的时分选择）：小小一格「21:30」，改完回车或点别处生效；写错了恢复原样
    static TextBox TimeBox(string value, Action<string> changed)
    {
        var box = Form.Field(value, "00:00", 72);
        box.TextAlignment = TextAlignment.Center;
        var last = value;
        void Apply()
        {
            var text = (box.Text ?? "").Trim().Replace('：', ':');
            if (!text.Contains(':') && text.Length is 3 or 4) text = text[..^2] + ":" + text[^2..];
            var parts = text.Split(':');
            if (parts.Length == 2 && int.TryParse(parts[0], out var h) && int.TryParse(parts[1], out var m) && h is >= 0 and < 24 && m is >= 0 and < 60)
            {
                var normalized = $"{h:00}:{m:00}";
                box.Text = normalized;
                if (normalized != last) { last = normalized; changed(normalized); }
            }
            else box.Text = last;
        }
        box.LostFocus += (_, _) => Apply();
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Apply(); };
        return box;
    }

    // MARK: 我

    Control ProfileSection(JsonNode? profile)
    {
        var defaultName = profile.Str("macName") ?? "";
        var name = Form.Field(profile.Str("myName"), defaultName, 260);
        var faceHost = new ContentControl();
        void DrawFace(JsonNode? p)
        {
            var shownName = (p.Str("myName") ?? "").Trim() is { Length: > 0 } n ? n : defaultName;
            var avatar = p.Obj("me").Str("avatar") ?? "";
            var face = new Border { Width = 52, Height = 52, CornerRadius = new CornerRadius(52 * 0.22), ClipToBounds = true };
            if (avatar.Length > 0)
            {
                var image = new Image { Stretch = Stretch.UniformToFill };
                face.Child = image;
                ImageCache.Load("/api/avatar", new Dictionary<string, string> { ["v"] = avatar }, b => image.Source = b);
            }
            else
            {
                face.Res(Border.BackgroundProperty, "IconTile");
                face.Child = Ui.Text(Format.Initials(shownName), 52 * 0.38, FontWeight.SemiBold, "Accent").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center);
            }
            faceHost.Content = face;
        }
        DrawFace(profile);
        void SaveName() => Post("/api/profile", new JsonObject { ["name"] = name.Text ?? "" }, DrawFace);
        name.LostFocus += (_, _) => SaveName();
        name.KeyDown += (_, e) => { if (e.Key == Key.Enter) SaveName(); };
        var change = Form.Button(L("更换头像…"), () => { });
        change.Click = () =>
        {
            var menu = new ContextMenu
            {
                ItemsSource = new Control[]
                {
                    Ui.Item(L("选择图片…"), async () =>
                    {
                        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { Title = L("选择头像"), FileTypeFilter = [FilePickerFileTypes.ImageAll] });
                        if (files.FirstOrDefault()?.TryGetLocalPath() is string path)
                            Post("/api/profile", new JsonObject { ["image"] = Convert.ToBase64String(File.ReadAllBytes(path)) }, DrawFace);
                    }),
                    Ui.Item(L("使用名字首字"), () => Post("/api/profile", new JsonObject { ["avatar"] = "text" }, DrawFace)),
                },
            };
            menu.Open(change);
        };
        var block = Ui.H(14, faceHost, Ui.VFill(8, Ui.H(8, Ui.Text(L("名字"), 13), new Spacer(), name), Ui.H(0, new Spacer(), change)).Grow());
        return Form.Section(L("我"), [Form.Block(block)], L("对话中你一侧显示的头像和名字，手机与电脑共用。名字留空时使用电脑的用户名。"));
    }

    // MARK: 外观（只改这个客户端）

    /// 「跟随系统 / 浅色 / 深色」这类三段：英文「Follow System」放不进 260
    static double SegmentWidth => Lang.IsEnglish ? 330 : 260;

    Control LookSection(JsonNode? status)
    {
        var appearance = new LookSegmented([("system", L("跟随系统")), ("light", L("浅色")), ("dark", L("深色"))], Prefs.String("appearance") ?? "system", Appearance.Set) { Width = SegmentWidth };
        var language = new LookSegmented([("system", L("跟随系统")), ("zh", L("简体中文")), ("en", "English")], status.Str("uiLanguage") ?? "system",
            v => Post("/api/desktop/settings", new JsonObject { ["uiLanguage"] = v }, _ => Lang.Use(v))) { Width = SegmentWidth };
        var themes = new WrapPanel();
        void DrawThemes()
        {
            themes.Children.Clear();
            foreach (var theme in LookTheme.All.Append(Look.Theme.Id == "custom" ? Look.Theme : LookTheme.Custom(Prefs.String("lookCustom") is string hex && uint.TryParse(hex.TrimStart('#'), NumberStyles.HexNumber, null, out var c) ? c : 0xD97757)))
            {
                var on = theme.Id == Look.Theme.Id;
                var dark = ActualThemeVariant == Avalonia.Styling.ThemeVariant.Dark;
                var swatch = new Panel { Width = 28, Height = 28 };
                if (theme.Id == "custom")
                    swatch.Children.Add(new Avalonia.Controls.Shapes.Ellipse { Width = 28, Height = 28, Fill = new ConicGradientBrush
                    {
                        GradientStops = { new GradientStop(Colors.Red, 0), new GradientStop(Colors.Orange, 0.17), new GradientStop(Colors.Yellow, 0.33), new GradientStop(Colors.Green, 0.5),
                                          new GradientStop(Colors.Cyan, 0.67), new GradientStop(Colors.Blue, 0.83), new GradientStop(Colors.Red, 1) },
                    } });
                else swatch.Children.Add(new Avalonia.Controls.Shapes.Ellipse { Width = 28, Height = 28, Fill = Palette.Brush(dark ? theme.AccentDark : theme.Accent) });
                swatch.Children.Add(new Avalonia.Controls.Shapes.Ellipse { Width = 17, Height = 17, Fill = Palette.Brush(dark ? theme.BubbleDark : theme.Bubble),
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
                if (on) swatch.Children.Add(Ui.Sym("checkmark", 9, "White").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center));
                var ring = new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(17), BorderThickness = new Thickness(on ? 2 : 0), Child = swatch.HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center) };
                if (on) ring.BorderBrush = Palette.Brush(dark ? theme.AccentDark : theme.Accent);
                var cell = Ui.Stack(Orientation.Vertical, 6, Align.Center, [ring, Ui.Text(L(theme.Name), 12, on ? FontWeight.SemiBold : FontWeight.Normal, on ? "Text" : "Text2")]);
                var picked = theme;
                themes.Children.Add(new Tap(cell.Pad(4, 4), () => { Look.SetTheme(picked); DrawThemes(); }, 8) { Width = 82 }.Keys("Transparent", "Fill05"));
            }
        }
        DrawThemes();
        var custom = new TextBox { Width = 110, Watermark = "#D97757", Text = Prefs.String("lookCustom") ?? "", FontSize = Look.Pt(13) };
        custom.Classes.Add("search");
        void ApplyCustom()
        {
            var text = (custom.Text ?? "").Trim().TrimStart('#');
            if (text.Length == 6 && uint.TryParse(text, NumberStyles.HexNumber, null, out var hex)) { Look.SetTheme(LookTheme.Custom(hex)); DrawThemes(); }
        }
        custom.LostFocus += (_, _) => ApplyCustom();
        custom.KeyDown += (_, e) => { if (e.Key == Key.Enter) ApplyCustom(); };

        var fonts = new StackPanel();
        void DrawFonts()
        {
            fonts.Children.Clear();
            foreach (var group in LookFont.All.Select(f => f.Group).Distinct())
            {
                fonts.Children.Add(Ui.Text(L(group), 11.5, color: "Text2").Margin(0, 8, 0, 4));
                var list = new StackPanel();
                var options = LookFont.All.Where(f => f.Group == group).ToList();
                for (var i = 0; i < options.Count; i++)
                {
                    var option = options[i];
                    var family = new FontFamily(string.Join(", ", option.Families.Append("sans-serif")));
                    var on = option.Id == Look.Font.Id;
                    var row = Ui.H(10, new TextBlock { Text = L(option.Name), FontFamily = family, FontSize = Look.Pt(14) },
                        new TextBlock { Text = L("Aa 你好"), FontFamily = family, FontSize = Look.Pt(14) },
                        Ui.Text(option.Available ? L(option.Note) : L("这台电脑上没有安装"), 11.5, color: "Text2").Trim().Shrink(), new Spacer(),
                        on ? Ui.Sym("checkmark", 13, "Accent") : null);
                    var tap = new Tap(row.Pad(10, 8), () => { if (option.Available) { Look.SetFont(option); DrawFonts(); } }, 0).Keys("Transparent", "Fill05");
                    tap.Opacity = option.Available ? 1 : 0.5;
                    list.Children.Add(tap);
                    if (i < options.Count - 1) list.Children.Add(Ui.Rule("Separator", 0.5).Margin(10, 0, 0, 0));
                }
                fonts.Children.Add(new Border { CornerRadius = new CornerRadius(8), Child = list, ClipToBounds = true }.Res(Border.BackgroundProperty, "Fill03"));
            }
        }
        DrawFonts();
        var size = new Slider { Minimum = 0, Maximum = LookSize.All.Length - 1, TickFrequency = 1, IsSnapToTickEnabled = true, Width = 220,
            Value = Array.FindIndex(LookSize.All, s => s.Id == Look.Size.Id) };
        var sizeName = Ui.Text(L(Look.Size.Name), 13, color: "Text2").Width(40);
        // 滑块用主题色（同 Mac 的 tint），不用系统强调色
        foreach (var key in new[] { "SliderTrackValueFill", "SliderTrackValueFillPointerOver", "SliderTrackValueFillPressed", "SliderThumbBackground", "SliderThumbBackgroundPointerOver", "SliderThumbBackgroundPressed" })
            size.Resources[key] = Palette.Get("Accent");
        size.PropertyChanged += (_, e) =>
        {
            if (e.Property != Avalonia.Controls.Primitives.RangeBase.ValueProperty) return;
            var picked = LookSize.All[(int)Math.Round(size.Value)];
            if (picked.Id == Look.Size.Id) return;
            Look.SetSize(picked);
            sizeName.Text = L(picked.Name);
        };
        return Form.Section(L("外观"), [
            Form.Row(L("外观"), appearance),
            Form.Row(L("语言"), language),
            Form.Toggle(L("主窗口顶部的纸鸢"), KiteOverlay.Enabled, v => KiteOverlay.Enabled = v),
            Form.Block(Ui.VFill(10, Ui.Text(L("主题色"), 13), themes)),
            Form.Row(L("自定义颜色"), custom),
            Form.Block(Ui.VFill(4, Ui.Text(L("字体"), 13), fonts)),
            Form.Row(L("字号"), Ui.H(10, Ui.Text("A", 11), size, new TextBlock { Text = "A", FontSize = 17 }, sizeName)),
        ], L("主题色用于强调色、主按钮以及你发送的消息气泡。代码始终使用等宽字体。此处设置仅作用于这台电脑上的 Kiteline：iPhone 请在 iPhone 的设置中修改，Apple Watch 请在「Apple Watch」页修改。"));
    }

    // MARK: Bark、花费

    static Control BarkSection(JsonNode? bark)
    {
        var url = Form.Field(bark.Str("url"), L("https://api.day.app/你的密钥"), 300);
        var modes = new[] { ("attention", L("仅推送需要确认的消息（及花费提醒）")), ("all", L("全部提醒")), ("off", L("暂停")) };
        var mode = new ComboBox { Width = 260, ItemsSource = modes.Select(m => m.Item2).ToList(), SelectedIndex = Math.Max(0, Array.FindIndex(modes, m => m.Item1 == bark.Str("mode"))) };
        var key = new TextBox { Width = 240, PasswordChar = '•', Watermark = L("16 / 24 / 32 个字符"), FontSize = Look.Pt(13) };
        key.Classes.Add("search");
        void Save() => Post("/api/bark", new JsonObject { ["url"] = (url.Text ?? "").Trim(), ["mode"] = modes[Math.Max(0, mode.SelectedIndex)].Item1, ["key"] = key.Text ?? "" });
        url.LostFocus += (_, _) => Save();
        key.LostFocus += (_, _) => { if ((key.Text ?? "").Length > 0) Save(); };
        mode.SelectionChanged += (_, _) => Save();
        var test = Form.Button(L("发送测试"), () => Post("/api/bark/test", new JsonObject(), r => AppModel.Shared.Flash(r.Truthy("ok") ? L("已发送，请在手机上的 Bark 中确认是否收到。") : r.Str("error") ?? L("发送失败"))));
        // 填了地址才出推送范围、加密、测试（同 Mac）
        var more = new StackPanel { IsVisible = (bark.Str("url") ?? "").Length > 0 };
        foreach (var row in new[] { Form.Row(L("推送范围"), mode), Form.Row(L("加密密钥（可选）"), key), Form.Row("", test) })
        {
            more.Children.Add(Ui.Rule("Separator", 0.5).Margin(10, 0, 10, 0));
            more.Children.Add(row);
        }
        url.TextChanged += (_, _) => more.IsVisible = (url.Text ?? "").Trim().StartsWith("https://", StringComparison.OrdinalIgnoreCase);
        return Form.Section(L("Bark 备用推送"), [
            new StackPanel { Children = { Form.Row(L("Bark 地址"), url), more } },
        ], L("当网页推送被专注模式屏蔽，或因未安装证书而无法接收时，可作为备用通道：安装免费的 Bark App，并将其提供的地址填入此处。需要确认的消息以「时效性」级别推送，专注模式下同样会提醒。推送内容会经过 Bark 服务器；如需保护隐私，请在 Bark App 中开启加密，并在此填入相同的密钥。"));
    }

    static Control BudgetSection(JsonNode? budget)
    {
        var daily = budget.Num("daily") ?? 0;
        var cap = budget.Num("cap") ?? 0;
        void Save() => Post("/api/budget", new JsonObject { ["daily"] = daily, ["cap"] = cap });
        Control Amount(string label, Func<double> get, Action<double> set)
        {
            var box = Form.Field(get().ToString("0", CultureInfo.InvariantCulture), null, 90);
            box.TextAlignment = TextAlignment.Right;
            void Apply() { if (double.TryParse(box.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) && v >= 1) { set(v); Save(); } }
            box.LostFocus += (_, _) => Apply();
            box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Apply(); };
            return Form.Row(label, box);
        }
        var budgetRow = new ContentControl();
        var capRow = new ContentControl();
        void Draw()
        {
            budgetRow.Content = daily > 0 ? Amount(L("每日预算（美元）"), () => daily, v => daily = v) : null;
            capRow.Content = cap > 0 ? Amount(L("每日上限（美元）"), () => cap, v => cap = v) : null;
        }
        Draw();
        return Form.Section(L("花费提醒与上限"), [
            Form.Toggle(L("每日花费超出预算时提醒"), daily > 0, on => { daily = on ? 100 : 0; Save(); Draw(); }),
            budgetRow,
            Form.Toggle(L("每日花费达到上限后拦截"), cap > 0, on => { cap = on ? 300 : 0; Save(); Draw(); }),
            capRow,
        ], L("提醒：当日所有机器的总花费达到预算的 80% 和 100% 时各推送一次。上限：达到上限后跳过定时任务，新建任务、恢复会话和手机发送消息需先确认（允许操作与回答提问不受影响）。花费数据取自 Claude Code 的记录。"));
    }

    // MARK: 快捷短语

    Control Phrases()
    {
        var items = AppModel.Shared.QuickReplies.ToList();
        var list = new StackPanel();
        var page = Form.Page();
        page.Children.Add(Ui.Text(L("显示在对话页输入框上方：点击直接发送给 Claude，右键则填入输入框以便编辑。手机与电脑共用此列表。"), 12, color: "Text2", lines: 0).Wrap().Margin(0, 12, 0, 10));
        void Save()
        {
            var cleaned = items.Select(t => t.Trim()).Where(t => t.Length > 0).Distinct().Take(24).ToList();
            Post("/api/quick-replies", new JsonObject { ["replies"] = new JsonArray(cleaned.Select(t => (JsonNode)t).ToArray()) });
        }
        void Draw()
        {
            list.Children.Clear();
            for (var i = 0; i < items.Count; i++)
            {
                var index = i;
                var box = new TextBox { Text = items[i], Watermark = L("短语"), Background = Brushes.Transparent, BorderThickness = new Thickness(0), FontSize = Look.Pt(13) };
                box.Classes.Add("plain");
                box.TextChanged += (_, _) => items[index] = box.Text ?? "";
                box.LostFocus += (_, _) => Save();
                Control Arrow(string symbol, int delta) => new Tap(Ui.Sym(symbol, 10, "Text3").Pad(4, 2), () =>
                {
                    var j = index + delta;
                    if (j < 0 || j >= items.Count) return;
                    (items[index], items[j]) = (items[j], items[index]);
                    Save();
                    Draw();
                }, 4).Keys("Transparent", "Fill08");
                var remove = new Tap(Ui.Sym("minus.circle", 13, "Text3").Pad(4, 2), () => { items.RemoveAt(index); Save(); Draw(); }, 4).Keys("Transparent", "Fill08").Tip(L("删除"));
                var row = Ui.H(6, Ui.Sym("line.3.horizontal", 11, "Text3"), box.Grow(), Arrow("chevron.up", -1), Arrow("chevron.down", 1), remove).Pad(10, 2);
                row.Background = i % 2 == 1 ? Palette.Get("Fill03") : Brushes.Transparent;
                list.Children.Add(row);
            }
            if (items.Count == 0) list.Children.Add(Ui.Text(L("暂无短语"), 13, color: "Text2").Margin(10, 10, 0, 10));
        }
        Draw();
        page.Children.Add(new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(0.5), Child = list, MinHeight = 300, ClipToBounds = true }
            .Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator"));
        var add = Form.Button("+", () => { if (items.Count < 24) { items.Add(""); Draw(); } });
        add.Tip(L("添加"));
        page.Children.Add(Ui.H(8, add, new Spacer(),
            Form.Button(L("恢复默认"), () => { items = ["继续", "按此方案执行", "截图查看效果", "运行测试并发送结果", "总结本次改动", "暂停，等我回来再继续"]; Save(); Draw(); }),
            Form.Button(L("保存"), Save, prominent: true)).Margin(0, 10, 0, 0));
        return page;
    }

    // MARK: 定时任务

    Control Schedules() => Loading(async () =>
    {
        var reply = await Api.Get("/api/schedules");
        var page = Form.Page();
        var refresh = PageBar.Button("arrow.clockwise", L("刷新"), () => Select("schedules"));
        page.Children.Add(Ui.HTop(10, Ui.Text(L("到达设定时间后，在项目的 VS Code 窗口中新建会话并将任务发送给 Claude。新建方式：在主窗口「新任务」或手机端新任务中选择「定时」。"), 12, color: "Text2", lines: 0).Wrap().Shrink(), new Spacer(), refresh).Margin(0, 12, 0, 10));
        var list = new StackPanel();
        var tasks = reply.Arr("schedules").Items().ToList();
        if (tasks.Count == 0) list.Children.Add(Ui.Text(L("暂无定时任务"), 13, color: "Text2").Margin(10, 10, 0, 10));
        foreach (var task in tasks)
        {
            var id = task.Str("id") ?? "";
            var toggle = new MacSwitch(task.Truthy("enabled"), on => Post("/api/schedules/update", new JsonObject { ["id"] = id, ["enabled"] = on }));
            var meta = Ui.H(10);
            if (task.Num("nextRun") is double next) meta.Children.Add(Ui.Text(L("下次 %@", Format.Short(next)), 11, color: "Accent"));
            if (task.Num("lastRun") is double last)
                meta.Children.Add(Ui.Text(L("上次 %@：%@", Format.Short(last), task.Str("lastResult") ?? ""), 11, color: task.Bool("lastOk") == false ? "Red" : "Text2").Trim().Shrink());
            var body = Ui.VFill(3, Ui.H(6, Ui.Text(task.Str("label") ?? "", 13, FontWeight.Bold), Ui.Text(System.IO.Path.GetFileName((task.Str("cwd") ?? "").TrimEnd('/', '\\')), 12, FontWeight.SemiBold, "Text2")),
                Ui.Text(task.Str("prompt") ?? "", 12, lines: 2).Wrap(), meta);
            var run = Form.Button(L("运行"), () => Post("/api/schedules/run", new JsonObject { ["id"] = id }, _ => Select("schedules")));
            run.Tip(L("立即运行一次"));
            var delete = new Tap(Ui.Sym("trash", 13, "Text2").Pad(6, 4), () => Post("/api/schedules/delete", new JsonObject { ["id"] = id }, _ => Select("schedules")), 6).Keys("Transparent", "Fill08").Tip(L("删除"));
            list.Children.Add(Ui.HTop(10, toggle.Margin(0, 2, 0, 0), body.Grow(), run, delete).Pad(10, 8));
            list.Children.Add(Ui.Rule("Separator", 0.5));
        }
        page.Children.Add(new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(0.5), Child = list, MinHeight = 340, ClipToBounds = true }
            .Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator"));
        return page;
    });

    // MARK: 手机访问

    /// 重置配对令牌（同 Mac 版）：手机丢失、链接泄露时用，所有已配对的手机失效、要重新扫码
    Control ResetTokenButton()
    {
        var button = Form.Button(L("重置令牌…"), async () =>
        {
            if (!await Dialogs.Confirm(L("所有已配对的手机都将失效，需重新扫码。适用于手机丢失或链接泄露的情况。"), L("重置"), destructive: true, title: L("重置配对令牌？"))) return;
            try
            {
                var reply = await Api.Post("/api/desktop/reset-token");
                if (reply.Str("token") is not { Length: > 0 } token) return;
                // 后台把所有连接（包括这个客户端的）都断开了：换上新令牌重连，再刷新二维码
                AppModel.Shared.Api.UseToken(token);
                AppModel.Shared.Stop();
                AppModel.Shared.Start();
                Select("phone");
            }
            catch (Exception e) { AppModel.Shared.Flash(e.Message); }
        });
        // 危险操作，字用红色（同 Mac 的 role: .destructive）
        foreach (var label in Avalonia.LogicalTree.LogicalExtensions.GetLogicalDescendants(button).OfType<TextBlock>()) label.Res(TextBlock.ForegroundProperty, "Removed");
        return button;
    }

    Control Phone() => Loading(async () =>
    {
        var pairing = await Api.Post("/api/desktop/pairing", new JsonObject { ["renew"] = false });
        var status = await Api.Get("/api/desktop/status");
        var addresses = pairing.Arr("addresses").Items().Select(a => (Label: L(a.Str("label") ?? ""), Base: a.Str("base") ?? "")).Where(a => a.Base.Length > 0).ToList();
        var query = pairing.Str("query") ?? "";
        var selected = Math.Max(0, addresses.FindIndex(a => a.Label == L("局域网")));
        string Link() => addresses.Count > 0 ? $"{addresses[selected].Base}/?{query}" : pairing.Str("link") ?? "";

        var qr = new QrView(Link());
        var qrCard = new Border { Width = 246, Height = 246, CornerRadius = new CornerRadius(22), Background = Brushes.White, Padding = new Thickness(14), Child = qr };
        var shadow = new Border { Width = 246, Height = 246, CornerRadius = new CornerRadius(22), Background = Brushes.White, BoxShadow = BoxShadows.Parse("0 6 14 0 #2E000000") };
        var address = new ComboBox { Width = 246, FontSize = Look.Pt(12), ItemsSource = addresses.Select(a => $"{a.Label}  {a.Base}").ToList(), SelectedIndex = selected };
        address.SelectionChanged += (_, _) => { if (address.SelectedIndex >= 0) { selected = address.SelectedIndex; qr.Text = Link(); } };
        var copy = Form.Button(L("复制链接"), () => { _ = Clipboard?.SetTextAsync(Link()); AppModel.Shared.Flash(L("已复制配对链接")); });
        var left = Ui.Stack(Orientation.Vertical, 12, Align.Center, [new Panel { Children = { shadow, qrCard } }, address, copy]);

        var code = pairing.Str("code") ?? "";
        var expiry = pairing.Num("expiry") ?? 0;
        var codeText = new TextBlock { Text = Spaced(code), FontFamily = Look.Mono, FontSize = Look.Pt(36), FontWeight = FontWeight.SemiBold, LetterSpacing = 3 };
        codeText.Res(TextBlock.ForegroundProperty, "Text");
        var expiryText = Ui.Text("", 11.5, color: "Text2");
        async void Renew()
        {
            var fresh = await Api.Post("/api/desktop/pairing", new JsonObject { ["renew"] = true });
            code = fresh.Str("code") ?? "";
            expiry = fresh.Num("expiry") ?? 0;
            query = fresh.Str("query") ?? query;
            codeText.Text = Spaced(code);
            qr.Text = Link();
        }
        void Tick()
        {
            var leftSeconds = Math.Max(0, (int)((expiry - Format.NowMs) / 1000));
            expiryText.Text = leftSeconds > 0 ? L("%@ 后失效 · 仅可使用一次", $"{leftSeconds / 60}:{leftSeconds % 60:00}") : L("正在生成新配对码…");
            if (leftSeconds == 0 && expiry > 0) { expiry = 0; Renew(); }
        }
        Tick();
        ticker = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => Tick());
        ticker.Start();
        var codeCard = Card.Make(Ui.VFill(6, Ui.Text(L("或在手机上输入配对码"), 12, color: "Text2"), codeText,
            Ui.H(10, expiryText, new Spacer(), Form.Button(L("刷新"), Renew))));
        Control Status(string symbol, string title, string value) =>
            Ui.H(8, Ui.Sym(symbol, 12, "Text2").Width(18), Ui.Text(title, 12), new Spacer(), Ui.Text(value, 12, color: "Text2").Trim());
        var devices = status.Arr("devices").Items().Count();
        var statusCard = Card.Make(Ui.VFill(8,
            Status("antenna.radiowaves.left.and.right", L("服务"), status.Str("https") ?? ""),
            Status("iphone", L("在线的手机"), L("%lld 台", status.Int("clients") ?? 0)),
            Status("person.badge.key", L("已配对的设备"), L("%lld 台设备", devices))));
        Control Tip(string number, string text) => Ui.HTop(6,
            new Border { Width = 16, Height = 16, CornerRadius = new CornerRadius(8), Child = Ui.Text(number, 10, FontWeight.Bold).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center) }.Res(Border.BackgroundProperty, "Fill10"),
            Ui.Text(text, 11.5, color: "Text2", lines: 0).Wrap().Shrink());
        var right = new StackPanel
        {
            Width = 350, Spacing = 16,
            Children =
            {
                Ui.VFill(4, Ui.Text(L("使用手机上的 Kiteline 扫码"), 17, FontWeight.SemiBold), Ui.Text(L("从 App Store 安装 Kiteline，打开后扫描此二维码即可完成配对。"), 12, color: "Text2", lines: 0).Wrap()),
                codeCard, statusCard,
                Ui.VFill(5, Tip("1", L("局域网：手机与电脑连接同一 Wi-Fi 时，选择「局域网」地址。")), Tip("2", L("外部网络：在设置中开启「远程访问」后，手机可通过 5G 或其他 Wi-Fi 连接（端到端加密）。"))),
                ResetTokenButton().HAlign(HorizontalAlignment.Left),
            },
        };
        return Ui.HTop(22, left, right).HAlign(HorizontalAlignment.Center).Margin(24, 24, 24, 24);
    });

    static string Spaced(string code) => code.Length == 6 ? $"{code[..3]} {code[3..]}" : code.Length == 0 ? "------" : code;

    /// 二维码（QRCoder 算模块，自己画方块：白底黑块，不糊）；新手引导第三步也用
    internal sealed class QrView : Control
    {
        bool[,]? modules;
        string text = "";

        public QrView(string text) { Text = text; }

        public string Text
        {
            get => text;
            set
            {
                text = value;
                try
                {
                    using var generator = new QRCodeGenerator();
                    var data = generator.CreateQrCode(value, QRCodeGenerator.ECCLevel.M);
                    var size = data.ModuleMatrix.Count;
                    modules = new bool[size, size];
                    for (var y = 0; y < size; y++)
                        for (var x = 0; x < size; x++) modules[x, y] = data.ModuleMatrix[y][x];
                }
                catch { modules = null; }
                InvalidateVisual();
            }
        }

        public override void Render(DrawingContext context)
        {
            if (modules is null) return;
            var count = modules.GetLength(0);
            var cell = Math.Floor(Math.Min(Bounds.Width, Bounds.Height) / count * 2) / 2;
            var offset = (Math.Min(Bounds.Width, Bounds.Height) - cell * count) / 2;
            for (var y = 0; y < count; y++)
                for (var x = 0; x < count; x++)
                    if (modules[x, y]) context.FillRectangle(Brushes.Black, new Rect(offset + x * cell, offset + y * cell, cell + 0.3, cell + 0.3));
        }
    }

    // MARK: 远程访问

    Control Remote() => Loading(async () =>
    {
        var status = await Api.Get("/api/desktop/status");
        var config = await Api.Get("/api/desktop/config");
        var state = status.Obj("remote").Str("state") ?? "stopped";
        var (dot, text) = state switch
        {
            "online" => ("Green", L("已连接中继")),
            "connecting" or "starting" => ("Orange", L("连接中…")),
            _ => ("Red", status.Obj("remote").Str("error") is { Length: > 0 } e ? e : L("未运行")),
        };
        var relay = Form.Field(config.Str("relayURL"), L("留空则使用 Kiteline 中继（%@）", (config.Str("builtinRelay") ?? "").Replace("https://", "")), 320);
        var apply = Form.Button(L("应用"), () => Post("/api/desktop/config", new JsonObject { ["relayURL"] = (relay.Text ?? "").Trim() }, _ => AppModel.Shared.Flash(L("已保存"))));
        var page = Form.Page();
        page.Children.Add(Form.Section(null, [
            Form.Toggle(L("开启远程访问"), status.Truthy("remoteEnabled"), on => Post("/api/desktop/settings", new JsonObject { ["remoteEnabled"] = on }, _ => Select("remote"))),
        ], L("手机不在同一 Wi-Fi 时（如办公室、外出、4G/5G 网络）也能连接这台电脑。优先直连，无法直连时经中继转发；全程端到端加密，中继无法查看内容。无需注册账号。")));
        page.Children.Add(Form.Section(L("状态"), [
            Form.Row(L("连接"), Ui.H(6, Ui.Dot(7, dot), Ui.Text(text, 13, color: "Text2"))),
        ]));
        page.Children.Add(Form.Section(L("中继服务器"), [Form.Row(L("中继地址"), relay), Form.Row("", apply)]));
        return page;
    });

    // MARK: 设备

    Control Devices() => Loading(async () =>
    {
        var reply = await Api.Get("/api/devices");
        var page = Form.Page();
        page.Children.Add(Ui.Text(L("每台已配对的手机都有独立的密钥。如手机丢失或不再使用，可在此停用：密钥将失效、连接断开，并停止向其推送。"), 12, color: "Text2", lines: 0).Wrap().Margin(0, 12, 0, 10));
        var list = new StackPanel();
        var devices = reply.Arr("devices").Items().ToList();
        if (devices.Count == 0) list.Children.Add(Ui.Text(L("暂无已配对的设备。请使用「手机访问」中的二维码或配对码进行配对。"), 13, color: "Text2", lines: 0).Wrap().Margin(10, 10, 10, 10));
        for (var i = 0; i < devices.Count; i++)
        {
            var d = devices[i];
            var name = d.Str("name") ?? "";
            var online = d.Truthy("online");
            var symbol = name.Contains("iPad") ? "ipad" : name.Contains("Watch") ? "applewatch" : "iphone";
            var title = Ui.H(6, Ui.Text(name, 13, FontWeight.SemiBold).Trim().Shrink(),
                online ? new Border { Padding = new Thickness(5, 1), CornerRadius = new CornerRadius(8), Child = Ui.Text(L("在线"), 10, FontWeight.Medium, "Green") }.Res(Border.BackgroundProperty, "GreenFill13") : null);
            var detail = Ui.Text(L("最后使用 %@ · %@ · %@配对于 %@", Format.Short(d.Num("lastSeen")), d.Str("lastIP") ?? "", d.Str("via") ?? "", Format.Short(d.Num("createdAt"))), 11, color: "Text2").Trim();
            var id = d.Str("id") ?? "";
            var revoke = Form.Button(L("停用"), async () =>
            {
                if (await Dialogs.Confirm(L("此设备将立即断开，之后需重新扫码或输入配对码才能连接。"), L("停用"), destructive: true, title: L("停用「%@」？", name)))
                    Post("/api/desktop/revoke", new JsonObject { ["id"] = id }, _ => Select("devices"));
            });
            var row = Ui.H(10, Ui.Sym(symbol, 18, online ? "Green" : "Text2").Width(26), Ui.VFill(2, title, detail).Grow(), revoke).Pad(10, 6);
            row.Background = i % 2 == 1 ? Palette.Get("Fill03") : Brushes.Transparent;
            list.Children.Add(row);
        }
        page.Children.Add(new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(0.5), Child = list, MinHeight = 300, ClipToBounds = true }
            .Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator"));
        page.Children.Add(Ui.HTop(10, Ui.Text(L("扫码链接本身也是一把密钥（手机首次打开后会换成专属密钥），10 分钟内有效、只能用一次。"), 11, color: "Text3", lines: 0).Wrap().Shrink(), new Spacer(),
            PageBar.Button("arrow.clockwise", L("刷新"), () => Select("devices"))).Margin(0, 10, 0, 0));
        return page;
    });

    // MARK: Apple Watch

    Control Watch() => Loading(async () =>
    {
        var reply = await Api.Get("/api/watch");
        var prefs = reply.Obj("prefs");
        void Set(string key, bool on) => Post("/api/watch", new JsonObject { [key] = on });
        var page = Form.Page();
        page.Children.Add(Form.Section(null, [
            Form.Block(Ui.HTop(12, new DuoIcon("applewatch", 40), Ui.VFill(4, Ui.Text(L("手表经由 iPhone 连接，无需单独配对"), 13, FontWeight.SemiBold),
                Ui.Text(L("iPhone 上的 Kiteline 连接此电脑后，打开手表上的 Kiteline 即可查看会话进度、允许操作、回答提问和语音回复。手表版 Kiteline 随 iPhone App 一同提供：iPhone「Watch」App → 可安装的 App → Kiteline。"), 12, color: "Text2", lines: 0).Wrap()).Shrink())),
        ]));
        var watches = reply.Arr("watches").Items().ToList();
        page.Children.Add(Form.Section(L("已配对手表的 iPhone"), watches.Count == 0
            ? [Form.Block(Ui.Text(L("暂无 iPhone 上报已配对的 Apple Watch。在已配对手表的 iPhone 上打开一次 Kiteline 后将显示在此处。"), 12, color: "Text2", lines: 0).Wrap())]
            : watches.Select(w => Form.Value(w.Str("device") ?? "", w.Str("label") ?? ""))));
        page.Children.Add(Form.Section(L("确认"), [
            Form.Toggle(L("双指互点 = 允许"), prefs.Truthy("doubleTap"), on => Set("doubleTap", on)),
            Form.Toggle(L("危险命令需在手表上二次确认"), prefs.Truthy("guardDanger"), on => Set("guardDanger", on)),
            Form.Toggle(L("确认框中显示「总是允许」"), prefs.Truthy("alwaysAllow"), on => Set("alwaysAllow", on)),
        ]));
        page.Children.Add(Form.Section(L("显示"), [
            Form.Toggle(L("隐藏已静音的会话"), prefs.Truthy("hideMuted"), on => Set("hideMuted", on)),
            Form.Toggle(L("显示花费"), prefs.Truthy("showCost"), on => Set("showCost", on)),
            Form.Toggle(L("触感反馈"), prefs.Truthy("haptics"), on => Set("haptics", on)),
        ]));
        return page;
    });

    // MARK: 来源

    /// 来源（同 Mac 版 SourcesPane）：本机和 Remote-SSH 主机，每个可改名、重新连接、重新部署观察器、停用、移除；
    /// 「添加 Remote-SSH 主机」先用 ssh 免密测一下连接再加。VS Code 里连过、还没加的主机列在下面，一键添加
    Control Sources() => Loading(async () =>
    {
        var reply = await Api.Get("/api/desktop/sources");
        var page = Form.Page();
        page.Children.Add(Ui.Text(L("Kiteline 监听以下机器上的 Claude Code：本机、你在 VS Code 中通过 Remote-SSH 连接的远端主机，以及添加的其他 Kiteline 电脑。首次连接远端时将自动部署观察器。"), 12, color: "Text2", lines: 0).Wrap().Margin(0, 12, 0, 10));
        void Reload() => Select("sources");
        var list = new StackPanel();
        var rows = reply.Arr("sources").Items().ToList();
        // 有能后台运行、还没开的远端设备：问一声要不要开（选了「不再提示」就不问，各行的按钮照旧在；同 Mac 版 SourcesPane）。
        // 只问远端的：本机默认就开着，用户自己关掉的不再问
        var candidates = rows.Where(r => r.Str("kind") == "ssh" && r.Str("hosted") == "off" && r.Truthy("online")).Select(r => Lang.Machine(r.Str("name") ?? "")).ToList();
        if (candidates.Count > 0 && !AppModel.Shared.HostedTipOff)
        {
            var hint = new StackPanel { Spacing = 8 };
            hint.Children.Add(Ui.Text(L("「%@」支持在后台运行 Claude Code：新建任务、恢复会话不再打开 VS Code，可减少 VS Code 的内存占用。是否开启？",
                string.Join("」「", candidates)), 12, lines: 0).Wrap());
            var never = new Tap(Ui.Text(L("不再提示"), 12, color: "Text2").Pad(6, 3), null, 6).Keys("Transparent", "Fill08");
            never.Click = async () => { await AppModel.Shared.SetHosted(tipOff: true); Reload(); };
            hint.Children.Add(Ui.H(12, Form.Button(L("检测出口并开启…"), () => HostedSetup.Open(changed: Reload), prominent: true), never));
            page.Children.Add(Card.Make(Ui.HTop(10, Ui.Sym("moon.stars", 14, "Accent"), hint.Grow()), 12, 12).Margin(0, 0, 0, 12));
        }
        for (var i = 0; i < rows.Count; i++)
        {
            list.Children.Add(SourceRow(rows[i], Reload));
            if (i < rows.Count - 1) list.Children.Add(Ui.Rule("Separator", 0.5).Margin(46, 0, 0, 0));
        }
        page.Children.Add(Card.Make(list, 6, 6));

        // 已添加的 Kiteline 电脑（互联，同 Mac 版 PeerComputersCard）：在线状态、连不上的原因、移除
        var peers = reply.Arr("peers").Items().ToList();
        if (peers.Count > 0)
        {
            var box = new StackPanel();
            for (var i = 0; i < peers.Count; i++)
            {
                var peer = peers[i];
                var peerId = peer.Str("id") ?? "";
                var problem = peer.Str("problem");
                var remove = new Tap(Ui.Text(L("移除"), 11.5, color: "Text2").Pad(6, 3), () => RemovePeer(peerId, peer.Str("name") ?? "", Reload), 6).Keys("Transparent", "Fill08");
                box.Children.Add(Ui.H(10, new Border { Width = 28, Child = Ui.Sym("desktopcomputer", 14, "Text") },
                    new StackPanel { Spacing = 2, Children = {
                        Ui.Text(peer.Str("name") ?? "", 12.5, FontWeight.SemiBold).Trim(),
                        Ui.H(5, Ui.Dot(6, problem is null ? "Green" : "Red"),
                             Ui.Text(problem is null ? L("已互联 · %@", (peer.Str("address") ?? "").Split(':')[0]) : problem, 11, color: "Text2").Trim().Shrink()) } }.Grow(),
                    remove).Pad(8, 7));
                if (i < peers.Count - 1) box.Children.Add(Ui.Rule("Separator", 0.5).Margin(46, 0, 0, 0));
            }
            page.Children.Add(Card.Make(box, 6, 6).Margin(0, 12, 0, 0));
        }

        // VS Code 里连过的 Remote-SSH 主机（正开着的在前）：一键添加
        var suggestions = reply.Arr("suggestions").Items().ToList();
        var message = Ui.Text("", 11.5, color: "Text2", lines: 0).Wrap();
        message.IsVisible = false;
        async void Add(string host, string name, Action<bool>? busy = null)
        {
            busy?.Invoke(true);
            message.IsVisible = true;
            message.Text = L("正在通过 ssh 连接 %@…", host);
            try
            {
                await Api.Post("/api/desktop/sources/add", new JsonObject { ["host"] = host, ["name"] = name });
                Reload();
            }
            catch (Exception e) { message.Text = e.Message; busy?.Invoke(false); }
        }
        if (suggestions.Count > 0)
        {
            var box = new StackPanel { Spacing = 6 };
            box.Children.Add(Ui.Text(L("VS Code 中连接过的 Remote-SSH 主机"), 12, FontWeight.Medium, "Text2"));
            foreach (var item in suggestions)
            {
                var host = item.Str("host") ?? "";
                var add = Form.Button(L("添加"), () => { });
                add.Click = () => Add(host, "", on => add.IsEnabled = !on);
                box.Children.Add(Ui.H(10, Ui.Sym("server.rack", 14, "Text2"), Ui.Text(host, 13).Trim().Shrink(),
                    item.Truthy("open") ? new Border { Padding = new Thickness(6, 1), CornerRadius = new CornerRadius(8), Child = Ui.Text(L("已连接"), 10.5, FontWeight.Medium, "Green") }.Res(Border.BackgroundProperty, "GreenFill13") : null,
                    new Spacer(), add));
            }
            page.Children.Add(Card.Make(box, 12, 10).Margin(0, 12, 0, 0));
        }

        // 手动添加：主机写法同 ssh 命令
        var form = new StackPanel { Spacing = 10, IsVisible = false };
        var hostBox = Form.Field("", L("主机（与 ssh 命令中的写法一致，如 my-server 或 10.0.0.5）"), 460);
        var nameBox = Form.Field("", L("显示名（可选）"), 460);
        var confirm = Form.Button(L("添加"), () => { }, prominent: true);
        var openForm = new Tap(Ui.H(6, Ui.Sym("plus", 12, "Text"), Ui.Text(L("添加 Remote-SSH 主机"), 13)).Pad(12, 0), null, 6) { Height = 28 }.Keys("Fill10", "Fill15");
        var reconnect = Form.Button(L("全部重新连接"), () => Post("/api/desktop/sources/reconnect", new JsonObject(), _ => { AppModel.Shared.Flash(L("正在重新连接")); Reload(); }));
        // 添加 Kiteline 电脑：输那台电脑的地址和它「手机访问」页上的 6 位验证码，那台电脑上点「允许」（同 Mac 版 AddPeerCard）
        var peerForm = new StackPanel { Spacing = 10, IsVisible = false };
        var addressBox = Form.Field("", L("地址（IP 或域名，如 192.168.1.20；端口不是 8766 时写成 IP:端口）"), 460);
        var codeBox = Form.Field("", L("6 位验证码"), 460);
        var peerConfirm = Form.Button(L("添加"), () => { }, prominent: true);
        var openPeer = new Tap(Ui.H(6, Ui.Sym("desktopcomputer", 12, "Text"), Ui.Text(L("添加 Kiteline 电脑"), 13)).Pad(12, 0), null, 6) { Height = 28 }.Keys("Fill10", "Fill15")
            .Tip(L("添加另一台安装了 Kiteline 的电脑，在这里查看并操作它的会话"));
        var bottom = Ui.H(10, openForm, openPeer, new Spacer(), reconnect);
        peerConfirm.Click = async () =>
        {
            var address = (addressBox.Text ?? "").Trim();
            var code = new string((codeBox.Text ?? "").Where(char.IsDigit).ToArray());
            if (address.Length == 0 || code.Length != 6) { message.IsVisible = true; message.Text = L("请输入对方电脑上显示的 6 位验证码"); return; }
            peerConfirm.IsEnabled = false;
            if (peerConfirm.Child is TextBlock t) t.Text = L("等待对方电脑确认…");
            message.IsVisible = true;
            message.Text = L("已发出请求，请在那台电脑上点「允许」（60 秒内）");
            try
            {
                await Api.Post("/api/desktop/sources/peer/add", new JsonObject { ["address"] = address, ["code"] = code });
                Reload();
            }
            catch (Exception e)
            {
                message.Text = e.Message;
                peerConfirm.IsEnabled = true;
                if (peerConfirm.Child is TextBlock t2) t2.Text = L("添加");
            }
        };
        codeBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) peerConfirm.Click?.Invoke(); };
        peerForm.Children.Add(Ui.Text(L("添加 Kiteline 电脑"), 13, FontWeight.SemiBold));
        peerForm.Children.Add(Ui.Text(L("在那台电脑上打开 Kiteline「设置 → 手机访问」，填入它的地址和页面上显示的 6 位验证码，再到那台电脑上点「允许」。两台电脑之间直接连接（局域网、公网 IP 或你自己的组网），不经过 Kiteline 的中继。"), 11.5, color: "Text2", lines: 0).Wrap());
        peerForm.Children.Add(addressBox);
        peerForm.Children.Add(codeBox);
        peerForm.Children.Add(Ui.H(10, new Spacer(), Form.Button(L("取消"), () => { peerForm.IsVisible = false; bottom.IsVisible = true; message.IsVisible = false; }), peerConfirm));
        openPeer.Click = () => { peerForm.IsVisible = true; bottom.IsVisible = false; addressBox.Focus(); };
        var peerCard = Card.Make(peerForm, 14, 12);
        peerCard.Margin = new Thickness(0, 12, 0, 0);
        peerCard.Bind(IsVisibleProperty, peerForm.GetObservable(IsVisibleProperty));
        page.Children.Add(peerCard);
        confirm.Click = () =>
        {
            var host = (hostBox.Text ?? "").Trim();
            if (host.Length == 0) return;
            Add(host, (nameBox.Text ?? "").Trim(), on =>
            {
                confirm.IsEnabled = !on;
                if (confirm.Child is TextBlock t) t.Text = on ? L("正在检查连接…") : L("添加");
            });
        };
        hostBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) confirm.Click?.Invoke(); };
        form.Children.Add(Ui.Text(L("添加 Remote-SSH 主机"), 13, FontWeight.SemiBold));
        form.Children.Add(hostBox);
        form.Children.Add(nameBox);
        form.Children.Add(Ui.H(10, new Spacer(), Form.Button(L("取消"), () => { form.IsVisible = false; bottom.IsVisible = true; message.IsVisible = false; }), confirm));
        openForm.Click = () => { form.IsVisible = true; bottom.IsVisible = false; hostBox.Focus(); };
        var formCard = Card.Make(form, 14, 12);
        formCard.Margin = new Thickness(0, 12, 0, 0);
        formCard.Bind(IsVisibleProperty, form.GetObservable(IsVisibleProperty));
        page.Children.Add(formCard);
        page.Children.Add(message.Margin(4, 10, 4, 0));
        page.Children.Add(bottom.Margin(0, 12, 0, 0));
        return page;
    });

    /// 移除 Kiteline 电脑：两台互相看不到对方的会话，经这台登记到对方的手机也失效
    void RemovePeer(string peerId, string name, Action reload)
    {
        _ = Ask();
        async Task Ask()
        {
            if (await Dialogs.Confirm(L("移除后两台电脑互相看不到对方的会话；经这台电脑登记到「%@」上的手机也会失效。之后可以重新添加。", name), L("移除"),
                                      destructive: true, title: L("移除电脑「%@」？", name)))
                Post("/api/desktop/sources/peer/remove", new JsonObject { ["id"] = peerId }, _ => reload());
        }
    }

    /// 一个来源：图标、名字（双击改名）、主机、状态；右边「⋯」菜单
    Control SourceRow(JsonNode source, Action reload)
    {
        var id = source.Str("id") ?? "";
        var ssh = source.Str("kind") == "ssh";
        var peerSource = source.Str("kind") == "kiteline";
        var enabled = source.Truthy("enabled") || source["enabled"] is null;
        var online = source.Truthy("online");
        var name = Lang.Machine(source.Str("name") ?? "");
        var host = source.Str("host");
        var title = Ui.Text(name, 13, FontWeight.SemiBold).Trim();
        var nameHost = new ContentControl { Content = Ui.H(6, title, host is { Length: > 0 } && host != name ? Ui.Text(host, 11, color: "Text3").Trim() : null) };
        void Rename()
        {
            var box = Form.Field(source.Str("name") == host ? "" : name, ssh ? host : L("本机"), 220);
            void Commit(bool save)
            {
                if (save) Post("/api/desktop/sources/update", new JsonObject { ["id"] = id, ["name"] = (box.Text ?? "").Trim() }, _ => reload());
                else reload();
            }
            box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Commit(true); else if (e.Key == Key.Escape) { e.Handled = true; Commit(false); } };
            box.LostFocus += (_, _) => Commit(true);
            nameHost.Content = box;
            box.Focus();
            box.SelectAll();
        }
        title.DoubleTapped += (_, _) => Rename();
        title.Tip(L("双击改名"));
        var status = Ui.H(5, Ui.Dot(6, online ? "Green" : enabled ? "Red" : "Text3"), Ui.Text(enabled ? source.Str("status") ?? "" : L("已停用"), 11, color: "Text2").Trim().Shrink());
        var more = new Tap(Ui.Sym("ellipsis.circle", 15, "Text2").Pad(4), null, 6).Keys("Transparent", "Fill08");
        more.Click = () =>
        {
            var menu = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedRight };
            menu.Items.Add(Ui.Item(L("设备详情…"), () => AgentDetails.OpenMachine(id, name)));
            menu.Items.Add(Ui.Item(L("改名…"), Rename));
            menu.Items.Add(Ui.Item(L("重新连接"), () => Post("/api/desktop/sources/reconnect", new JsonObject { ["id"] = id }, _ => reload())));
            if (ssh) menu.Items.Add(Ui.Item(L("重新部署观察器"), () => Post("/api/desktop/sources/reconnect", new JsonObject { ["id"] = id }, _ => reload())));
            menu.Items.Add(Ui.Item(enabled ? L("停用") : L("启用"), () => Post("/api/desktop/sources/update", new JsonObject { ["id"] = id, ["enabled"] = !enabled }, _ => reload())));
            if (peerSource)
            {
                menu.Items.Add(new Separator());
                menu.Items.Add(Ui.Item(L("移除这台电脑…"), () => RemovePeer(source.Str("peerId") ?? "", name, reload)));
            }
            else if (id != "local")
            {
                menu.Items.Add(new Separator());
                menu.Items.Add(Ui.Item(L("移除"), () => Post("/api/desktop/sources/remove", new JsonObject { ["id"] = id }, _ => reload())));
            }
            menu.ShowAt(more);
        };
        var icon = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(8), Child = Ui.Sym(ssh ? "server.rack" : peerSource ? "desktopcomputer" : "laptopcomputer", 16, "Text").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center) }
            .Res(Border.BackgroundProperty, "Fill06");
        // ⓘ：设备详情（IP、系统、处理器、内存、装了哪些 agent）
        var details = new Tap(Ui.Sym("info.circle", 15, "Text2").Pad(4), () => AgentDetails.OpenMachine(id, name), 6).Keys("Transparent", "Fill08").Tip(L("设备详情"));
        // 能后台运行 Claude Code 的电脑（本机、远端）：开没开、点开检测出口和开关（见 HostedSetup）
        Control? hosted = null;
        if (source.Str("hosted") is { } state)
        {
            if (state == "on") status.Children.Add(Ui.Text(L("· 后台运行 Claude Code"), 11, color: "Text2").Trim().Shrink());
            hosted = new Tap(Ui.Text(state == "on" ? L("后台运行：已开启") : L("后台运行…"), 11.5, color: state == "on" ? "Text2" : "Accent").Pad(6, 3),
                             () => HostedSetup.Open(id, changed: reload), 6).Keys("Transparent", "Fill08").Tip(L("在这台电脑上后台运行 Claude Code：检测出口 IP、开启或关闭"));
        }
        return Ui.H(12, icon, Ui.VFill(2, nameHost, status).Grow(), hosted, details, more).Pad(8, 8);
    }

    // MARK: 权限（Windows / Linux：就绪检查）

    Control Permissions() => Loading(async () =>
    {
        var reply = await Api.Get("/api/readiness");
        var page = Form.Page();
        page.Children.Add(Ui.Text(L("以下各项完成后即可使用全部功能。"), 12, color: "Text2").Margin(0, 12, 0, 6));
        foreach (var card in ReadinessCards(reply)) page.Children.Add(card);
        return page;
    });

    /// 就绪检查的一项一张卡片（设置 → 权限、新手引导第二步共用）：没就绪的带原因、修法和「一键安装」这类按钮
    internal static IEnumerable<Control> ReadinessCards(JsonNode? reply)
    {
        foreach (var item in reply.Arr("items").Items())
        {
            var level = item.Str("level") ?? "ok";
            var (color, label, fill) = level switch { "ok" => ("Green", L("已就绪"), "GreenFill13"), "warn" => ("Orange", L("需要处理"), "OrangeFill13"), _ => ("Red", L("不可用"), "OrangeFill13") };
            var badge = new Border { Padding = new Thickness(5, 1), CornerRadius = new CornerRadius(8), Child = Ui.Text(label, 10.5, FontWeight.Medium, color) }.Res(Border.BackgroundProperty, fill);
            var body = new StackPanel { Spacing = 3, Children = { Ui.H(8, Ui.Text(item.Str("title") ?? "", 13, FontWeight.SemiBold), badge), Ui.Text(item.Str("detail") ?? "", 12, color: "Text2", lines: 0).Wrap() } };
            if (level != "ok" && item.Str("fix") is { Length: > 0 } fix) body.Children.Add(Ui.Text(fix, 11.5, color: "Text3", lines: 0).Wrap());
            Control? action = null;
            if (level != "ok" && item.Obj("action") is JsonNode a && a.Str("id") is string actionId)
                action = Form.Button(a.Str("label") ?? L("一键安装"), () => Post("/api/readiness/fix", new JsonObject { ["action"] = actionId }, r => AppModel.Shared.Flash(r.Str("message") ?? "")));
            var icon = Ui.Sym(level == "ok" ? "checkmark.circle" : "exclamationmark.triangle", 16, color);
            yield return Card.Make(Ui.HTop(12, icon.Margin(0, 1, 0, 0), body.Grow(), action), 12, 12).Margin(0, 8, 0, 0);
        }
    }

    // MARK: 操作记录

    Control Audit() => Loading(async () =>
    {
        var reply = await Api.Get("/api/audit", new Dictionary<string, string> { ["limit"] = "300" });
        var page = Form.Page();
        page.Children.Add(Ui.HTop(10, Ui.Text(L("记录手机与对话页的所有操作：发送消息、确认、新建任务、恢复会话、修改设置、配对。失败的操作以红色标示。"), 12, color: "Text2", lines: 0).Wrap().Shrink(), new Spacer(),
            PageBar.Button("arrow.clockwise", L("刷新"), () => Select("audit"))).Margin(0, 12, 0, 10));
        var list = new StackPanel();
        var entries = reply.Arr("entries").Items().ToList();
        if (entries.Count == 0) list.Children.Add(Ui.Text(L("暂无记录"), 13, color: "Text2").Margin(10, 10, 0, 10));
        for (var i = 0; i < entries.Count; i++)
        {
            var entry = entries[i];
            var ok = entry.Bool("ok") != false;
            var title = string.Join(" · ", new[] { entry.Str("action"), entry.Str("target") }.Where(s => !string.IsNullOrEmpty(s)));
            var body = new StackPanel { Spacing = 2, Children = { Ui.Text(title, 12.5, FontWeight.SemiBold).Trim() } };
            if (entry.Str("detail") is { Length: > 0 } detail) body.Children.Add(Ui.Text(detail, 11.5, lines: 2).Wrap());
            if (!ok && entry.Str("message") is { Length: > 0 } message) body.Children.Add(Ui.Text(message, 11.5, color: "Red", lines: 2).Wrap());
            body.Children.Add(Ui.Text(entry.Str("client") ?? "", 10.5, color: "Text3"));
            var row = Ui.HTop(10, Ui.Text(Format.Short(entry.Num("ts")), 11, color: "Text2").Width(52), body.Grow(), Ui.Sym(ok ? "checkmark.circle.fill" : "xmark.circle.fill", 14, ok ? "Green" : "Red")).Pad(10, 6);
            row.Background = i % 2 == 1 ? Palette.Get("Fill03") : Brushes.Transparent;
            list.Children.Add(row);
        }
        page.Children.Add(new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(0.5), Child = list, MinHeight = 380, ClipToBounds = true }
            .Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator"));
        return page;
    });

    // MARK: 关于

    Control About() => Loading(async () =>
    {
        var status = await Api.Get("/api/desktop/status");
        var client = typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3) ?? "";
        var version = L("版本 %@", status.Str("version") ?? "") + (client.Length > 0 ? " · " + L("客户端 %@", client) : "");
        var dataDir = status.Str("dataDir") ?? "";
        Tap Link(string title, Action action) => (Tap)new Tap(Ui.Text(title, 13, FontWeight.Medium, "Text2").Pad(6, 3), action, 6).Keys("Transparent", "Fill08");
        Control Pill(string title, string url) => Form.Button(title, () => OpenPath(url + (Lang.Current == "en" ? "#en" : "")));
        var links = Ui.H(18,
            // 在客户端里看（时间轴，同 Mac 版「更新记录」）
            Link(L("更新记录"), ChangelogWindow.Open),
            Link(L("新手引导"), () => OnboardingWindow.Open()),
            Link(L("检查更新"), () => { _ = UpdateState.Shared.Check(); UpdateDialog.Open(); }),
            Link(L("打开数据目录"), () => OpenPath(dataDir)),
            Link(L("打开配置文件"), () => OpenPath(System.IO.Path.Combine(dataDir, "config.json"))),
            Link(L("复制诊断信息"), () =>
            {
                var text = $"Kiteline {status.Str("version")} · client {client} · {status.Str("platform")} · {Environment.OSVersion}\nHTTPS: {status.Str("https")}\n" +
                           $"remote: {status.Obj("remote").Str("state")}\nsources: {string.Join("; ", status.Arr("sources").Items().Select(s => s.Str("status")))}";
                _ = Clipboard?.SetTextAsync(text);
                AppModel.Shared.Flash(L("已复制诊断信息"));
            }));
        var stack = Ui.Stack(Orientation.Vertical, 14, Align.Center, [
            new KiteIcon(128),
            Ui.Text("Kiteline", 34, FontWeight.Bold),
            Ui.Text(L("随时随地与 Claude Code 协作"), 15, color: "Text2"),
            Ui.Text(version, 13, color: "Text3"),
            links.Margin(0, 8, 0, 0),
            Ui.H(16, Pill(L("隐私政策"), "https://tars.betac.cn/privacy"), Pill(L("使用条款"), "https://tars.betac.cn/terms"), Pill(L("支持与反馈"), "https://tars.betac.cn/support"), Pill(L("在 GitHub 点星"), "https://github.com/hon6/kiteline"),
                Form.Button(L("开源许可"), LicensesWindow.Open)),
        ]);
        return stack.HAlign(HorizontalAlignment.Center).Margin(0, 70, 0, 40);
    });

    internal static void OpenPath(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
    }
}

/// 外观：跟随系统 / 浅色 / 深色（只改这个客户端，存偏好）
public static class Appearance
{
    public static void Apply()
    {
        if (Application.Current is not { } app) return;
        app.RequestedThemeVariant = (Prefs.String("appearance") ?? "system") switch
        {
            "light" => Avalonia.Styling.ThemeVariant.Light,
            "dark" => Avalonia.Styling.ThemeVariant.Dark,
            _ => Avalonia.Styling.ThemeVariant.Default,
        };
    }

    public static void Set(string value)
    {
        Prefs.Set("appearance", value);
        Apply();
    }
}
