using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 第一次打开的新手引导（同 Mac 版 Onboarding.swift，11-02 起：装好之后不知道怎么用、电脑上没有任何 Agent 的大有人在）。四步：
/// 第一步 了解 Kiteline：它是编程 Agent 的辅助工具，检测本机装了哪些 Agent（/api/machine）；一个都没有时醒目提醒，列表外的可以填写提交（/api/feedback → 统计后台）
/// 第二步 检查运行环境：就绪检查（同设置 → 权限）+ 开机 / 登录时自动启动
/// 第三步 连接手机：下载 iPhone App 的二维码 + 配对二维码和配对码
/// 第四步 虚拟屏幕：为什么要开、开关
/// 第一次启动、还没配过手机时自动弹；设置 → 关于、主窗口欢迎页的「新手引导」随时能再打开
public sealed class OnboardingWindow : Window
{
    static OnboardingWindow? shown;
    /// 自测截图用
    public static Window? Current => shown;
    const string ShownKey = "onboardingShown";
    const string AppStore = "https://apps.apple.com/cn/app/kiteline/id6825244029";
    /// 自测截图：假装一个 Agent 都没检测到（看提醒的样子）
    public static bool PretendNone;

    int step;
    readonly Grid bar = new() { ColumnDefinitions = new ColumnDefinitions("*,*,*,*") };
    readonly ContentControl page = new();
    readonly ContentControl footer = new();
    readonly ScrollViewer scroll;
    DispatcherTimer? ticker;

    // 第一步：检测结果（null = 还在检测）和「你使用的 Agent 不在列表中？」
    List<JsonNode>? agents;
    bool checking, showForm, sending, sent, failed;
    readonly TextBox wanted = new() { Watermark = L("Agent 名称，例如 Cline、Aider、Gemini CLI"), FontSize = Look.Pt(13), Padding = new Thickness(10, 6) };
    readonly TextBox note = new()
    {
        Watermark = L("补充说明（选填）：使用方式、所在系统等"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
        MinHeight = 64, MaxHeight = 140, FontSize = Look.Pt(13), Padding = new Thickness(10, 8),
    };

    static string[] Ordinals => [L("第一步"), L("第二步"), L("第三步"), L("第四步")];
    static string[] Titles => [L("了解 Kiteline"), L("检查运行环境"), L("连接手机"), L("虚拟屏幕")];

    public static void Open(int step = 0)
    {
        if (shown is null)
        {
            shown = new OnboardingWindow();
            shown.Closed += (_, _) => shown = null;
            WindowChrome.FitToScreen(shown);
            shown.Show();
        }
        shown.Go(step);
        shown.Activate();
    }

    /// 主窗口出来时调：没弹过、也还没配过手机（升级上来的老用户不弹）才弹，弹过一次就不再自动弹（中途关掉也算）
    public static async void ShowOnFirstLaunch()
    {
        if (Program.Headless || Prefs.Bool(ShownKey)) return;
        Prefs.Set(ShownKey, true);
        try
        {
            var status = await AppModel.Shared.Api.Get("/api/desktop/status");
            if (status.Arr("devices").Items().Any()) return;
        }
        catch { return; }
        Open();
    }

    OnboardingWindow()
    {
        Width = 780;
        Height = 660;
        MinWidth = 720;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Look.Family;
        Title = L("欢迎使用 Kiteline");
        this.Res(BackgroundProperty, "Window");
        scroll = new ScrollViewer { Content = page, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        var top = new Border { Child = bar, Padding = new Thickness(32, 22, 32, 8) };
        var bottom = new Border { Child = footer, Padding = new Thickness(24, 12), BorderThickness = new Thickness(0, 0.5, 0, 0) }.Res(Border.BorderBrushProperty, "Separator");
        var dock = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        dock.Children.Add(top);
        dock.Children.Add(bottom);
        dock.Children.Add(scroll);
        Content = new Panel { Children = { dock, new ToastLayer(24) } };
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        void Relabel() { Title = L("欢迎使用 Kiteline"); FontFamily = Look.Family; Go(step); }
        Lang.Changed += Relabel;
        Closed += (_, _) => { ticker?.Stop(); Lang.Changed -= Relabel; };
        Detect();
    }

    void Go(int index)
    {
        step = Math.Clamp(index, 0, 3);
        ticker?.Stop();
        ticker = null;
        DrawBar();
        DrawFooter();
        Draw();
        scroll.Offset = default;
    }

    void Draw()
    {
        page.Content = (step switch
        {
            0 => AgentsStep(),
            1 => EnvironmentStep(),
            2 => PhoneStep(),
            _ => ScreenStep(),
        }).Margin(40, 18, 40, 24);
    }

    /// 顶上的四步：序号圈 +「第一步」+ 标题；当前一步淡强调色底 + 细边，做过的打勾。点了直接跳过去
    void DrawBar()
    {
        bar.Children.Clear();
        for (var i = 0; i < 4; i++)
        {
            var index = i;
            var current = i == step;
            var done = i < step;
            var dot = new Border
            {
                Width = 22, Height = 22, CornerRadius = new CornerRadius(11),
                Child = done ? Ui.Sym("checkmark", 11, "White").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center)
                    : Ui.Text($"{i + 1}", 11, FontWeight.Bold, current ? "White" : "Text2").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center),
            }.Res(Border.BackgroundProperty, current || done ? "Accent" : "Fill08");
            var label = Ui.VFill(1, Ui.Text(Ordinals[i], 10.5, color: "Text2"),
                Ui.Text(Titles[i], 12.5, current ? FontWeight.SemiBold : FontWeight.Normal, current ? "Text" : "Text2").Trim());
            var cell = Ui.Box(Ui.H(9, dot, label.Shrink()), new Thickness(10, 7), current ? "AccentFill14" : null, 10, current ? "AccentEdge32" : "Separator", 0.5);
            var tap = new Tap(cell, () => Go(index), 10).Margin(i == 0 ? 0 : 4, 0, i == 3 ? 0 : 4, 0);
            Grid.SetColumn(tap, i);
            bar.Children.Add(tap);
        }
    }

    void DrawFooter()
    {
        footer.Content = Ui.H(10,
            new Tap(Ui.Text(L("稍后再说"), 13, FontWeight.Medium, "Text2").Pad(6, 3), Close, 6).Keys("Transparent", "Fill08"),
            Ui.Text(L("可随时在「设置 → 关于」中再次打开新手引导"), 11, color: "Text3").Shrink(),
            new Spacer(),
            step > 0 ? new GlassButton(L("上一步"), null, () => Go(step - 1), height: 32) : null,
            step < 3 ? new GlassButton(L("下一步"), null, () => Go(step + 1), prominent: true, height: 32)
                : new GlassButton(L("开始使用"), null, Close, prominent: true, height: 32));
    }

    /// 每一步的标题 + 一段说明
    static Control Header(string title, string detail) =>
        Ui.VFill(6, Ui.Text(title, 21, FontWeight.SemiBold), Ui.Text(detail, 13, color: "Text2", lines: 0).Wrap());

    // MARK: 第一步 了解 Kiteline

    async void Detect(int attempt = 0)
    {
        checking = true;
        if (step == 0) Draw();
        List<JsonNode>? found = null;
        try
        {
            var detail = await AppModel.Shared.Api.Get("/api/machine", new Dictionary<string, string> { ["source"] = "local" });
            if (detail?["agents"] is JsonArray list && list.Count > 0) found = list.Items().ToList();
        }
        catch { }
        if (found is null && attempt < 20)
        {
            // 本机来源还没连上（刚装好第一次启动，watcher 在部署）：隔 3 秒再问
            DispatcherTimer.RunOnce(() => Detect(attempt + 1), TimeSpan.FromSeconds(3));
            return;
        }
        agents = found ?? [];
        if (PretendNone) agents = agents.Select(a => (JsonNode)new JsonObject { ["id"] = a.Str("id"), ["name"] = a.Str("name"), ["installed"] = false }).ToList();
        checking = false;
        if (!Installed.Any()) showForm = true;
        if (step == 0) Draw();
    }

    IEnumerable<JsonNode> Installed => (agents ?? []).Where(a => a.Truthy("installed"));

    static string FormName(string form) => form switch { "vscode" => L("VS Code 扩展"), "cli" => L("终端"), "desktop" => L("桌面版"), _ => form };

    Control AgentsStep()
    {
        var intro = Ui.HTop(18, new KiteIcon(64),
            Header(L("Kiteline 是编程 Agent 的辅助工具"),
                L("Kiteline 本身不写代码，也不提供 AI 能力。它连接你电脑上正在使用的编程 Agent，让你在手机上查看会话进展、回复消息、处理确认请求。使用前，请先在电脑上安装并使用至少一种 Agent，例如 VS Code 中的 Claude Code、Codex。")).Shrink());

        var list = new StackPanel { Spacing = 10 };
        list.Children.Add(Ui.H(8, Ui.Text(L("本机检测到的 Agent"), 13, FontWeight.SemiBold), new Spacer(),
            checking ? new Spinner(12) : null, Form.Button(L("重新检测"), () => Detect())));
        if (agents is null)
        {
            list.Children.Add(Ui.Text(L("正在检测…"), 12, color: "Text2"));
        }
        else
        {
            if (!Installed.Any()) list.Children.Add(NoAgents());
            foreach (var agent in agents.OrderBy(a => a.Truthy("installed") ? 0 : 1))
            {
                var on = agent.Truthy("installed");
                var forms = agent.Obj("forms") is JsonObject f
                    ? f.OrderBy(kv => kv.Key switch { "vscode" => 0, "cli" => 1, _ => 2 })
                        .Select(kv => (FormName(kv.Key) + " " + (J.AsString(kv.Value) ?? "")).Trim()).ToList()
                    : [];
                list.Children.Add(Ui.H(10,
                    Ui.Sym(on ? "checkmark.circle" : "circle", 14, on ? "Accent" : "Text3"),
                    Ui.Text(agent.Str("name") ?? agent.Str("id"), 13, on ? FontWeight.Medium : FontWeight.Normal, on ? "Text" : "Text2"),
                    new Spacer(),
                    Ui.Text(on ? (forms.Count > 0 ? string.Join(L("、"), forms) : L("已安装")) : L("未检测到"), 11.5, color: "Text2").Trim()));
            }
        }
        return Ui.VFill(18, intro, Card.Make(list, 16), Feedback());
    }

    /// 一个 Agent 都没有：说清楚要先装什么
    Control NoAgents()
    {
        Control Bullet(string text) => Ui.HTop(6, Ui.Text("·", 12, FontWeight.Bold), Ui.Text(text, 12, lines: 0).Wrap().Shrink());
        var body = Ui.VFill(8,
            Ui.Text(L("未检测到任何编程 Agent"), 13, FontWeight.SemiBold),
            Ui.Text(L("Kiteline 需要配合 Agent 使用，否则手机上不会有任何会话。你可以："), 12, color: "Text2", lines: 0).Wrap(),
            Ui.VFill(4,
                Bullet(L("安装 VS Code，在「扩展」中搜索并安装 Claude Code 或 Codex")),
                Bullet(L("或安装 Claude Code、Codex、OpenCode 等命令行工具")),
                Bullet(L("安装完成并开始一个会话后，点击「重新检测」"))),
            Ui.H(8, Form.Button(L("下载 VS Code"), () => SettingsWindow.OpenPath("https://code.visualstudio.com/download"), prominent: true),
                Form.Button(L("重新检测"), () => Detect())));
        return Ui.Box(Ui.HTop(12, Ui.Sym("exclamationmark.triangle", 16, "Orange"), body.Shrink()), new Thickness(14), "OrangeFill13", 12, "OrangeEdge40", 0.5);
    }

    // 「你使用的 Agent 不在列表中？」：填名字 + 补充说明，提交到统计后台
    Control Feedback()
    {
        if (sent) return Ui.H(6, Ui.Sym("checkmark.circle", 13, "Text2"), Ui.Text(L("已提交，感谢反馈。我们会根据反馈优先接入更多 Agent。"), 12.5, color: "Text2"));
        if (!showForm)
            return new Tap(Ui.H(6, Ui.Sym("text.bubble", 13, "Accent"), Ui.Text(L("我使用的 Agent 不在列表中"), 12.5, FontWeight.Medium, "Accent")).Pad(4, 3),
                () => { showForm = true; Draw(); }, 6).HAlign(HorizontalAlignment.Left);
        var submit = Form.Button(sending ? L("正在提交…") : L("提交"), Submit, prominent: true);
        submit.IsEnabled = !sending;
        return Card.Make(Ui.VFill(10,
            Ui.VFill(3, Ui.Text(L("你使用的 Agent 不在列表中？"), 13, FontWeight.SemiBold),
                Ui.Text(L("告诉我们你正在使用或计划使用的 Agent，我们会根据反馈优先接入。"), 12, color: "Text2", lines: 0).Wrap()),
            wanted, note,
            Ui.H(10, submit, failed ? Ui.Text(L("提交失败，请检查网络后重试"), 11.5, color: "Orange") : null)), 16);
    }

    async void Submit()
    {
        var name = (wanted.Text ?? "").Trim();
        if (name.Length == 0 || sending) { if (name.Length == 0) wanted.Focus(); return; }
        sending = true;
        failed = false;
        Draw();
        try
        {
            var reply = await AppModel.Shared.Api.Post("/api/feedback", new JsonObject
            {
                ["agents"] = name, ["note"] = (note.Text ?? "").Trim(),
                ["detected"] = new JsonArray(Installed.Select(a => (JsonNode?)a.Str("id")).ToArray()),
            });
            sent = reply.Truthy("ok");
            failed = !sent;
        }
        catch { failed = true; }
        sending = false;
        if (step == 0) Draw();
    }

    // MARK: 第二步 检查运行环境

    Control EnvironmentStep()
    {
        var stack = new StackPanel { Spacing = 0 };
        stack.Children.Add(Header(L("检查运行环境"),
            L("Kiteline 需要以下组件和权限，才能把你在手机上发送的消息和确认操作送到电脑上的会话中。未就绪的项目下方会说明处理方法。")));
        var cards = new ContentControl { Content = new Spinner(16).HAlign(HorizontalAlignment.Left).Margin(0, 16, 0, 0) };
        stack.Children.Add(cards);
        var autostart = new ContentControl();
        stack.Children.Add(autostart);
        Dispatcher.UIThread.Post(async () =>
        {
            try
            {
                var reply = await AppModel.Shared.Api.Get("/api/readiness");
                var list = new StackPanel();
                foreach (var card in SettingsWindow.ReadinessCards(reply)) list.Children.Add(card);
                cards.Content = list;
                var status = await AppModel.Shared.Api.Get("/api/desktop/status");
                autostart.Content = Card.Make(Form.Toggle(OperatingSystem.IsWindows() ? L("开机时自动启动 Kiteline") : L("登录时自动启动 Kiteline"), status.Truthy("autostart"),
                    on => _ = AppModel.Shared.Api.Post("/api/desktop/settings", new JsonObject { ["autostart"] = on }),
                    L("推荐开启：电脑开机后手机即可连接，无需手动打开。")), 4).Margin(0, 14, 0, 0);
            }
            catch (Exception e) { cards.Content = Ui.Text(e.Message, 12, color: "Text2", lines: 0).Wrap().Margin(0, 16, 0, 0); }
        });
        return stack;
    }

    // MARK: 第三步 连接手机

    Control PhoneStep()
    {
        var pairQr = new SettingsWindow.QrView("");
        var codeText = new TextBlock { Text = "------", FontFamily = Look.Mono, FontSize = Look.Pt(26), FontWeight = FontWeight.SemiBold, LetterSpacing = 2 };
        codeText.Res(TextBlock.ForegroundProperty, "Text");
        var expiryText = Ui.Text("", 11, color: "Text2");
        var pairedIcon = Ui.Sym("iphone", 14, "Text2");
        var pairedText = Ui.Text(L("等待手机配对…"), 12.5);
        double expiry = 0;
        var query = "";
        var bases = new List<string>();
        var known = -1;

        async void Load(bool renew)
        {
            try
            {
                var pairing = await AppModel.Shared.Api.Post("/api/desktop/pairing", new JsonObject { ["renew"] = renew });
                var addresses = pairing.Arr("addresses").Items().Select(a => (Label: L(a.Str("label") ?? ""), Base: a.Str("base") ?? "")).Where(a => a.Base.Length > 0).ToList();
                var selected = Math.Max(0, addresses.FindIndex(a => a.Label == L("局域网")));
                query = pairing.Str("query") ?? "";
                bases = addresses.Select(a => a.Base).ToList();
                pairQr.Text = addresses.Count > 0 ? $"{addresses[selected].Base}/?{query}" : pairing.Str("link") ?? "";
                var code = pairing.Str("code") ?? "";
                codeText.Text = code.Length == 6 ? $"{code[..3]} {code[3..]}" : "------";
                expiry = pairing.Num("expiry") ?? 0;
            }
            catch (Exception e) { AppModel.Shared.Flash(e.Message); }
        }

        async void Poll()
        {
            try
            {
                var status = await AppModel.Shared.Api.Get("/api/desktop/status");
                var count = status.Arr("devices").Items().Count();
                if (count != known)
                {
                    known = count;
                    pairedIcon.Symbol = count > 0 ? "checkmark.circle" : "iphone";
                    pairedIcon.Res(TextBlock.ForegroundProperty, count > 0 ? "Accent" : "Text2");
                    pairedText.Text = count > 0 ? L("已配对 %lld 台设备，可以进入下一步。", count) : L("等待手机配对…");
                }
            }
            catch { }
        }

        var seconds = 0;
        void Tick()
        {
            var left = Math.Max(0, (int)((expiry - Format.NowMs) / 1000));
            expiryText.Text = left > 0 ? L("%@ 后失效 · 仅可使用一次", $"{left / 60}:{left % 60:00}") : L("正在生成新配对码…");
            if (left == 0 && expiry > 0) { expiry = 0; Load(true); }
            if (seconds++ % 2 == 0) Poll();
        }
        Load(false);
        Tick();
        ticker = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => Tick());
        ticker.Start();

        // 配对链接长、码点密：白底卡片 150、边距压到 6，二维码才不至于缩得太小
        Control QrCard(Control qr) => new Border { Width = 150, Height = 150, CornerRadius = new CornerRadius(12), Background = Brushes.White, Padding = new Thickness(6), Child = qr };
        Control StepCard(int number, string title, Control qr, string detail, Control? extra) => Card.Make(Ui.VFill(12,
            Ui.H(8, Ui.Box(Ui.Text($"{number}", 11, FontWeight.Bold, "Accent").HAlign(HorizontalAlignment.Center), new Thickness(0, 1), null, 10, "AccentEdge40", 1).Size(20, 20),
                Ui.Text(title, 14, FontWeight.SemiBold)),
            Ui.HTop(14, QrCard(qr), Ui.VFill(10, Ui.Text(detail, 12, color: "Text2", lines: 0).Wrap(), extra).Shrink())), 16);

        var cards = new Grid { ColumnDefinitions = new ColumnDefinitions("*,16,*") };
        // 第 1 步：iPhone 扫 App Store 的码，安卓用微信扫小程序码（11-10 起：安卓用户用小程序）
        Control Code(Control qr, string caption) => Ui.VFill(8,
            new Border { Width = 112, Height = 112, CornerRadius = new CornerRadius(12), Background = Brushes.White, Padding = new Thickness(5), Child = qr },
            Ui.Text(caption, 11, color: "Text2", lines: 0).Wrap().Size(112, double.NaN));
        var mpCode = new Image { Source = new Avalonia.Media.Imaging.Bitmap(Avalonia.Platform.AssetLoader.Open(new Uri("avares://KitelineApp/Assets/miniprogram-code.jpg"))) };
        var download = Card.Make(Ui.VFill(12,
            Ui.H(8, Ui.Box(Ui.Text("1", 11, FontWeight.Bold, "Accent").HAlign(HorizontalAlignment.Center), new Thickness(0, 1), null, 10, "AccentEdge40", 1).Size(20, 20),
                Ui.Text(L("安装手机端"), 14, FontWeight.SemiBold)),
            Ui.HTop(14,
                Code(new SettingsWindow.QrView(AppStore), L("iPhone：相机扫码，或在 App Store 中搜索「Kiteline」")),
                Code(mpCode, L("安卓：微信扫码，打开 Kiteline 小程序")))), 16);
        var pair = StepCard(2, L("扫码或输入配对码"), pairQr,
            L("打开 App 或小程序，扫描此二维码，或输入下方的 6 位配对码。首次配对时手机与电脑需连接同一网络。"), Ui.VFill(2, codeText, expiryText));
        Grid.SetColumn(pair, 2);
        cards.Children.Add(download);
        cards.Children.Add(pair);
        return Ui.VFill(18,
            Header(L("在手机上使用 Kiteline"), L("iPhone 安装 Kiteline App，安卓手机使用 Kiteline 微信小程序；与这台电脑配对后，即可在手机上查看会话、回复消息和处理确认请求。Apple Watch App 随 iPhone 自动安装。")),
            cards,
            Card.Make(Ui.H(8, pairedIcon, pairedText, new Spacer(), Form.Button(L("更多选项"), () => SettingsWindow.Open("phone"))), 12),
            Ui.Text(L("在外部网络（如 5G、其他 Wi-Fi）中使用：在设置的「远程访问」中开启，需订阅 Kiteline Pro。"), 11.5, color: "Text2", lines: 0).Wrap());
    }

    // MARK: 第四步 虚拟屏幕

    Control ScreenStep()
    {
        var screen = VirtualScreenState.Shared;
        var toggleHost = new ContentControl();
        void DrawToggle()
        {
            var detail = !screen.Supported ? L("此电脑暂不支持") : screen.On ? L("已开启 · 虚拟屏幕中有 %lld 个窗口", screen.Windows) : L("推荐在离开电脑、主要用手机操作时开启");
            if (screen.Note.Length > 0) detail += "\n" + L(screen.Note);
            toggleHost.Content = Card.Make(Form.Toggle(L("VS Code 在虚拟屏幕中运行"), screen.On, on => { if (on != screen.On) screen.Toggle(on); }, detail, screen.Supported), 4);
        }
        void Changed(object? _, System.ComponentModel.PropertyChangedEventArgs e) => Dispatcher.UIThread.Post(DrawToggle);
        screen.PropertyChanged += Changed;
        toggleHost.DetachedFromVisualTree += (_, _) => screen.PropertyChanged -= Changed;
        DrawToggle();
        Dispatcher.UIThread.Post(async () =>
        {
            try { screen.Apply((await AppModel.Shared.Api.Get("/api/desktop/status")).Obj("virtualScreen")); } catch { }
        });

        Control Monitor(string label, bool dashed, Control content)
        {
            // 看不见的那块：底色更淡、边框更深，和你的屏幕区分开
            var frame = new Border { Width = 190, Height = 96, CornerRadius = new CornerRadius(10), Child = content, BorderThickness = new Thickness(1) }
                .Res(Border.BackgroundProperty, dashed ? "Fill03" : "Fill05").Res(Border.BorderBrushProperty, dashed ? "Text3" : "Separator");
            return Ui.Stack(Orientation.Vertical, 8, Align.Center, [frame, Ui.Text(label, 11, color: "Text2")]);
        }
        Control Tile(string symbol) => Ui.Box(Ui.Sym(symbol, 15, "Text2").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center), new Thickness(0), "Fill08", 5).Size(34, 26);
        var yours = Monitor(L("你的屏幕"), false, Ui.H(6, Tile("globe"), Tile("doc.text"), Tile("bubble.left")).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center));
        var hidden = Monitor(L("虚拟屏幕（看不见）"), true, Ui.H(8,
            Ui.Box(Ui.Sym("chevron.left.forwardslash.chevron.right", 15, "Accent").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center), new Thickness(0), "AccentFill14", 6).Size(44, 30),
            Ui.Text("VS Code", 12, FontWeight.Medium)).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center));
        var phone = Ui.Stack(Orientation.Vertical, 6, Align.Center, [Ui.Sym("iphone", 26, "Text2"), Ui.Text(L("手机发来的消息"), 11, color: "Text2")]);
        var diagram = Ui.H(18, yours, hidden, Ui.Sym("arrow.left", 14, "Text3"), phone).HAlign(HorizontalAlignment.Center);

        Control Tip(string text) => Ui.HTop(6, Ui.Sym("info.circle", 11, "Text2").Margin(0, 2, 0, 0), Ui.Text(text, 12, color: "Text2", lines: 0).Wrap().Shrink());
        return Ui.VFill(18,
            Header(L("让 VS Code 在虚拟屏幕中运行"),
                L("你在手机上发送消息时，Kiteline 需要切换到 VS Code，把消息填进对应的会话并提交。开启虚拟屏幕后，VS Code 的窗口会放到一块看不见的屏幕上：消息送达时不会弹到你面前、不打断你正在做的事，完成后自动回到你原来使用的程序。")),
            diagram,
            toggleHost,
            Ui.VFill(5,
                Tip(L("鼠标不会进入虚拟屏幕，不影响你正常使用电脑。")),
                Tip(L("需要查看 VS Code 时，在 Kiteline 中点击「在 VS Code 中打开」即可移回，或关闭此开关。")),
                Tip(L("退出 Kiteline 时窗口自动回到原处；可随时在「设置 → 通用」或主窗口左下角的显示器按钮中开关。"))));
    }
}
