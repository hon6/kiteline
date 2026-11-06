using Avalonia;
using Avalonia.VisualTree;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media.Imaging;
using Avalonia.Styling;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.Net;
using Kiteline.UI;
using Kiteline.Views;

namespace Kiteline;

/// 自测（同 Mac 版 SelfTest）：离屏起一个主窗口连本机后台，按步骤操作、截图（没有屏幕的机器上也能跑）。
///   --render <png> [--dark] [--lang en] [--size 1120x760] [--steps "title:首页卡片间距;wait:2;shot:a.png;select:@today;shot:b.png"]
/// 不读写这台电脑上的偏好（截图之间互不影响）
static class SelfTest
{
    public static int Run(string[] args)
    {
        string? Arg(string name) { var i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
        var png = Arg("--render") ?? "shot.png";
        var size = (Arg("--size") ?? "1120x760").Split('x').Select(double.Parse).ToArray();
        var steps = Arg("--steps") ?? $"wait:3;shot:{png}";

        AppBuilder.Configure<App>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false }).SetupWithoutStarting();
        Window.WindowOpenedEvent.AddClassHandler<Window>((w, _) => { if (!opened.Contains(w)) opened.Add(w); });
        var app = Application.Current!;
        app.RequestedThemeVariant = args.Contains("--dark") ? ThemeVariant.Dark : ThemeVariant.Light;
        Palette.Install(app);
        var host = LocalHost.Find(args);
        if (host is null) { Console.Error.WriteLine("没找到后台：用 --server / --token 指定"); return 1; }
        // 截图默认中文（不跟系统，几次截图一致）；--lang en 截英文，步骤里 lang:en 测当场切换
        Lang.Pin(Arg("--lang") ?? "zh");
        App.Boot(host, remember: false);
        var window = new MainWindow { Width = size[0], Height = size[1] };
        window.Show();
        Pump(2.5);
        foreach (var step in steps.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = step.Split(':', 2);
            var name = parts[0].Trim();
            var arg = parts.Length > 1 ? parts[1] : "";
            var model = AppModel.Shared;
            var main = MainModel.Shared;
            switch (name)
            {
                case "wait": Pump(double.Parse(arg)); break;
                case "select": main.Selection = arg.Length == 0 ? null : arg; break;
                case "groupmembers": Views.GroupChatPage.StartWithMembers = true; break;   // 之后打开的群聊页直接展开成员面板
                case "grouppick": Views.GroupPicker.Open([], null); break;                  // 点「建群」：拉群面板（什么都没勾）
                // 第一个群的输入栏（同会话的输入栏）：groupattach:<图片路径>[*张数] = 附图（同粘贴截图）；groupsend:<文字> = 打字后点发送
                case "groupattach" or "groupsend":
                    if (GroupState.Shared.Items.FirstOrDefault() is not GroupInfo g0) { Console.WriteLine("[capture] 还没有会话群"); break; }
                    if (window.GetVisualDescendants().OfType<Views.Composer>().FirstOrDefault(c => c.TargetKey == MainModel.GroupPrefix + g0.Id) is not Views.Composer box)
                    { Console.WriteLine("[capture] 群的输入栏没开着"); break; }
                    if (name == "groupsend") { box.Submit(arg); break; }
                    var shot = arg.Split('*');
                    box.Attach(Enumerable.Repeat(File.ReadAllBytes(shot[0]), shot.Length > 1 ? int.Parse(shot[1]) : 1).ToList());
                    break;
                // 第一个群：group = 开进当前块的标签；groupsplit = 开在右侧分屏；groupdrawer = 点标签栏上的成员按钮；groupjoin:<会话标题> = 把会话拖到群那块中间
                case "group" or "groupsplit" or "groupdrawer" or "groupjoin":
                    if (GroupState.Shared.Items.FirstOrDefault() is not GroupInfo first) { Console.WriteLine("[capture] 还没有会话群"); break; }
                    var groupKey = MainModel.GroupPrefix + first.Id;
                    if (name == "group") main.Selection = groupKey;
                    else if (name == "groupsplit") SessionMenu.OpenSplit(groupKey, false);
                    else if (name == "groupdrawer") Views.GroupChatPage.ToggleMembers(first.Id);
                    else if (model.Sessions.FirstOrDefault(x => x.Title == arg) is SessionInfo joiner)
                        Console.WriteLine($"[capture] 拖进群：{(Views.GroupChatPage.JoinDropped(joiner.Key, ChatPanes.Shared.Focused) ? "已进群" : "照常放")}");
                    break;
                case "title":
                    if (model.Sessions.FirstOrDefault(s => s.Title == arg) is SessionInfo s) main.Selection = s.Key;
                    else Console.WriteLine($"[capture] 没找到会话「{arg}」");
                    break;
                case "split" or "splitdown":
                    if (model.Sessions.FirstOrDefault(x => x.Title == arg) is SessionInfo t) SessionMenu.OpenSplit(t.Key, name == "splitdown");
                    break;
                case "query": main.Query = arg; break;
                case "theme": Look.SetTheme(LookTheme.Named(arg)); break;
                // 改一项界面偏好（只在这次自测的内存里）：pref:todosGrouping=project，等号后面空着 = 删掉
                case "pref": var pref = arg.Split('=', 2); Prefs.Set(pref[0], pref.Length > 1 && pref[1].Length > 0 ? pref[1] : null); break;
                // 检查更新的几种状态：update:available / downloading / ready …（假数据）。available 带 prompt：后台说该弹了，会自动弹出更新弹窗；
                // 同时带一台旧版本的手机（phones），关掉更新弹窗后下一轮会弹「手机端有新版本」
                case "update":
                    UpdateState.Shared.Inject(new System.Text.Json.Nodes.JsonObject
                    {
                        ["phase"] = arg, ["version"] = "1.0.22", ["current"] = "1.0.19", ["size"] = 38500000, ["received"] = 14200000, ["supported"] = true,
                        ["notes"] = "新功能\n· 新版本提醒", ["behind"] = 3, ["key"] = "linux:1.0.22", ["prompt"] = arg == "available",
                        ["releases"] = new System.Text.Json.Nodes.JsonArray(
                            new System.Text.Json.Nodes.JsonObject { ["version"] = "1.0.22", ["date"] = "2026-11-03", ["notes"] = "新功能\n· 新版本提醒：发现新版本时自动弹出，可勾选此版本不再提示\n· 手机与电脑互相提醒新版本", ["notesEn"] = "New\n· Update reminders\n· Your phone and computer remind each other about updates" },
                            new System.Text.Json.Nodes.JsonObject { ["version"] = "1.0.21", ["date"] = "2026-11-02", ["notes"] = "新功能\n· 数据流大屏", ["notesEn"] = "New\n· Flow board" },
                            new System.Text.Json.Nodes.JsonObject { ["version"] = "1.0.20", ["date"] = "2026-11-01", ["notes"] = "问题修复\n· 修正若干问题", ["notesEn"] = "Bug Fixes\n· Fixed several issues" }),
                        ["phones"] = new System.Text.Json.Nodes.JsonObject
                        {
                            ["version"] = "1.7", ["notes"] = "新功能\n· 打开 App 时提示新版本\n\n改进\n· 手机与电脑互相提醒", ["key"] = "ios:1.7", ["prompt"] = true,
                            ["devices"] = new System.Text.Json.Nodes.JsonArray(new System.Text.Json.Nodes.JsonObject { ["name"] = "hon6 的 iPhone", ["version"] = "1.5" }),
                        },
                    });
                    break;
                case "updatedialog": Views.UpdateDialog.Open(); break;
                case "phonedialog": Views.PhoneUpdateDialog.Open(auto: false); break;
                case "closeupdate": Views.UpdateDialog.Current?.Close(); break;
                case "dialogshot": Pump(0.4); if ((Views.Dialog.Last ?? Views.UpdateDialog.Current ?? Views.PhoneUpdateDialog.Current) is Window dialog) Shot(dialog, arg); break;
                case "updateshot": Pump(0.4); if (Views.UpdateDialog.Current is Window updateDialog) Shot(updateDialog, arg); else Console.Error.WriteLine("更新弹窗没开"); break;
                case "phoneshot": Pump(0.4); if (Views.PhoneUpdateDialog.Current is Window phoneDialog) Shot(phoneDialog, arg); else Console.Error.WriteLine("手机端弹窗没开"); break;
                case "link": Model.PromptLinks.Handle(arg); break;   // 当作点了这条提示词链接（kiteline://new#p=…）
                case "newtask": Views.NewTaskSheet.Open(arg.Length > 0 && Model.AppModel.Shared.Sessions.FirstOrDefault(x => x.Title == arg) is { } picked ? (picked.SourceId, picked.Cwd ?? "") : null); break;
                case "todoedit": Views.TodoEditor.Open(Views.TodoEditor.Target.New()); break;
                // 对话里的面板：action:files / changes / tests / agents / search / info / mode / model；openfile:<路径>；closedialog
                case "action":
                    if (Enum.TryParse<SessionAction>(arg, true, out var act) && main.Selection is string current) ChatActions.Perform(current, act);
                    break;
                case "openfile": if (main.Selection is string fileKey) ChatSheets.File(fileKey, arg); break;
                case "closedialog": Views.Dialog.Last?.Close(); break;
                // 代码 IDE：code:<explorer|scm|branches>、codefile:<路径>、codetab:history / diff:<路径> / commit:<提交号>
                case "code": if (main.Selection is string codeKey) Views.Code.CodeWindow.Open(codeKey, arg.Length > 0 ? arg : "explorer"); break;
                case "codefile": Views.Code.CodeWindow.Last?.OpenFile(arg); break;
                case "codetab": Views.Code.CodeWindow.Last?.SelfTestTab(arg); break;
                case "stageopen": foreach (var strip in window.GetVisualDescendants().OfType<Views.StageStrip>()) strip.Toggle(); break;   // 展开输入框上方的任务进展条
                // 弹窗对着哪一块会话：anchor = 当前显示的第一块对话（同在那一块里点了一下）
                case "anchor": Views.Dialog.Anchor = window.GetVisualDescendants().OfType<Views.ChatView>().FirstOrDefault(); break;
                // 最近打开的弹窗在哪、多大，主窗口和对着的那块会话在哪（核对是否居中）
                case "dialogpos":
                {
                    Pump(0.4);
                    var shown = Views.Dialog.Last ?? Views.ImageViewer.LastWindow;
                    if (shown is null) { Console.WriteLine("[capture] 没有开着的弹窗"); break; }
                    var anchorAt = Views.Dialog.Anchor is { } a ? $"{a.PointToScreen(new Point(0, 0))} {a.Bounds.Size}" : "无";
                    Console.WriteLine($"[capture] 弹窗 {shown.Position} {shown.FrameSize ?? shown.ClientSize}，可改大小 {shown.CanResize}，最小 {shown.MinWidth}×{shown.MinHeight}；主窗口 {window.Position} {window.ClientSize}；会话 {anchorAt}");
                    break;
                }
                // 看大图：imageview:<本机图片路径>；zoom:in / out / fit / actual；imageshot:<路径>
                case "imageview": Views.ImageViewer.ShowLocal([System.IO.File.ReadAllBytes(arg)], 0, System.IO.Path.GetFileName(arg)); break;
                case "zoom":
                    if (Views.ZoomImage.Last is { } zoom)
                    {
                        switch (arg) { case "in": zoom.ZoomBy(1.25); break; case "out": zoom.ZoomBy(0.8); break; case "fit": zoom.Fit(); break; case "actual": zoom.ActualSize(); break; }
                        Pump(0.3);
                        Console.WriteLine($"[capture] 缩放 {arg}：{Math.Round(zoom.Scale * 100)}%{(zoom.Fitting ? "（适合窗口）" : "")}");
                    }
                    break;
                case "imageshot": Pump(0.4); if (Views.ImageViewer.LastWindow is Window viewer) Shot(viewer, arg); break;
                // 收藏当前会话最后一条文字回复、最后一条带图的消息（同右键「收藏」）
                // translate[:engine]：点当前会话最后一条文字回复的「翻译」（跳过第一次的设置弹窗）；translate:ask 看设置弹窗；translated 打印状态
                case "translate":
                    if (main.Selection is string trKey && model.Chat(trKey).Items.Values.OrderBy(i => i.Ts ?? 0)
                            .LastOrDefault(i => i.T == "text" && i.Peer is null && !string.IsNullOrWhiteSpace(i.Text)) is { } trItem)
                    {
                        Model.Translator.Configured = arg != "ask";
                        if (arg.Length > 0 && arg != "ask") Model.Translator.Engine = arg;
                        Model.Translator.Tap(trItem.Id, trItem.Text!);
                        Console.WriteLine($"[capture] 翻译 {trItem.Id}");
                    }
                    break;
                case "autotranslate": Model.Translator.Configured = true; if (arg.Length > 0 && arg != "on" && arg != "off") Model.Translator.Engine = arg; Model.Translator.AutoTranslateOn = arg != "off"; break;
                case "translated":
                    if (main.Selection is string tdKey)
                        foreach (var it in model.Chat(tdKey).Items.Values)
                            if (Model.Translator.StateOf(it.Id) is { } st)
                                Console.WriteLine($"[capture] 翻译状态 {it.Id}={st.Phase} {st.Error} {(st.Text ?? "")[..Math.Min(60, (st.Text ?? "").Length)]}");
                    break;
                case "favlatest":
                    if (main.Selection is string favKey)
                    {
                        var items = model.Chat(favKey).Items.Values.OrderBy(i => i.Ts ?? 0).ToList();
                        if (items.LastOrDefault(i => i.T == "text" && !string.IsNullOrEmpty(i.Text)) is { } text) FavoriteState.Shared.Add(favKey, text, false);
                        if (items.LastOrDefault(i => i.Images is { Count: > 0 }) is { } pic) FavoriteState.Shared.Add(favKey, pic, pic.T == "user");
                        Pump(2);
                        Console.WriteLine($"[capture] 收藏 {FavoriteState.Shared.Items.Count} 条");
                    }
                    break;
                // 设置窗口：settings:<页>[:高度]（截长页时把窗口拉高），settingsshot:<路径>
                case "agent":
                {
                    // agent:<会话 key>|<子 agent id>[|full]
                    var target = arg.Split('|');
                    ChatSheets.OpenAgent(target[0], target[1], target.Length > 2 && target[2] == "full");
                    Pump(3);
                    break;
                }
                case "lang":
                    Lang.Pin(arg);
                    Pump(1.5);
                    break;
                case "settings":
                    var tab = arg.Split(':');
                    Views.SettingsWindow.Open(tab[0]);
                    if (tab.Length > 1 && Views.SettingsWindow.Current is Window sw) sw.Height = double.Parse(tab[1]);
                    break;
                case "settingsshot": Pump(0.4); if (Views.SettingsWindow.Current is Window settings) Shot(settings, arg); break;
                // 更新记录窗口：changelog 打开，changelogshot:<png> 截它
                case "changelog": Views.ChangelogWindow.Open(); break;
                // 新手引导：onboarding:<第几步，0～3>[:none]（none = 假装一个 Agent 都没检测到），onboardingshot:<png> 截它
                case "onboarding":
                    var ob = arg.Split(':');
                    Views.OnboardingWindow.PretendNone = ob.Length > 1 && ob[1] == "none";
                    Views.OnboardingWindow.Current?.Close();   // 每次重开：重新检测 Agent（none 才生效）
                    Pump(0.3);
                    Views.OnboardingWindow.Open(int.Parse(ob[0]));
                    Pump(4);
                    break;
                case "onboardingshot": Pump(0.4); if (Views.OnboardingWindow.Current is Window onboarding) Shot(onboarding, arg); break;
                // 放一只纸鸢：peerfly:发信标题>收信标题（按会话标题找 key；收信写不存在的标题 = 对方不在列表里，看「发给」小胶囊）
                case "peerfly":
                    var ends = arg.Split('>');
                    string? KeyOf(string title) => model.Sessions.FirstOrDefault(s => s.Title == title)?.Key;
                    Model.PeerBoard.Shared.Receive(new System.Text.Json.Nodes.JsonObject
                    {
                        ["links"] = new System.Text.Json.Nodes.JsonArray(new System.Text.Json.Nodes.JsonObject
                        {
                            ["id"] = "demo-" + Guid.NewGuid().ToString("N")[..6], ["from"] = KeyOf(ends[0]), ["to"] = KeyOf(ends[1]) ?? "other#" + ends[1],
                            ["toTitle"] = ends[1], ["sentAt"] = Model.Format.NowMs,
                        }),
                    });
                    break;
                case "changelogshot": Pump(0.4); if (Views.ChangelogWindow.Current is Window changelog) Shot(changelog, arg); break;
                // 开源许可窗口：licenses[:组件名] 打开（并选中那个组件），licensesshot:<png> 截它
                case "licenses": Views.LicensesWindow.Open(); if (arg.Length > 0) Views.LicensesWindow.Select(arg); break;
                case "licensesshot": Pump(0.4); if (Views.LicensesWindow.Current is Window licenses) Shot(licenses, arg); break;
                // 设置 → 插件：兼容表全部展开（在 settings:plugins 之前写）；插件出错的弹窗（之后用 dialogshot 截）
                case "pluginsexpand": Views.PluginsPage.ExpandAll = true; break;
                // 默认不接的插件打开前的确认框：optinconfirm:<插件 id>（之后用 dialogshot 截）
                case "optinconfirm":
                    var listing = model.Api.Get("/api/desktop/plugins");
                    for (var i = 0; i < 200 && !listing.IsCompleted; i++) Pump(0.05);
                    var plugin = listing.IsCompletedSuccessfully ? listing.Result.Arr("plugins").Items().FirstOrDefault(p => p.Str("id") == arg) : null;
                    if (plugin is not null && Views.PluginsPage.OptIn(plugin) is { } optIn) _ = Views.PluginsPage.ConfirmOptIn(plugin.Str("name") ?? arg, optIn);
                    break;
                case "pluginerror":
                    Views.PluginReport.Ask(new System.Text.Json.Nodes.JsonObject { ["key"] = "k", ["id"] = "codex", ["name"] = "Codex", ["version"] = "1.0.3",
                        ["error"] = arg.Length > 0 ? arg : "ValueError: thread/status 的格式变了", ["host"] = "本机" });
                    break;
                case "size": var wh = arg.Split('x').Select(double.Parse).ToArray(); window.Width = wh[0]; window.Height = wh[1]; break;
                case "cols": Console.WriteLine($"[capture] 分屏：{ChatPanes.Shared.Summary}；左边栏选中 {main.Selection ?? "-"}"); break;
                case "shot": Pump(0.4); Shot(window, arg); break;
                // 会话里的终端：往正在看的终端里打字（keytext:ls -la）、按键（key:Enter / key:C+ctrl），走真的键盘事件
                case "keytext":
                    window.GetVisualDescendants().OfType<Terminal.TermView>().FirstOrDefault(v => v.IsEffectivelyVisible)?.FocusInput();
                    Pump(0.1);
                    window.KeyTextInput(arg);
                    break;
                case "key":
                    window.GetVisualDescendants().OfType<Terminal.TermView>().FirstOrDefault(v => v.IsEffectivelyVisible)?.FocusInput();
                    Pump(0.1);
                    var keyParts = arg.Split('+');
                    var mods = Avalonia.Input.RawInputModifiers.None;
                    if (keyParts.Contains("ctrl")) mods |= Avalonia.Input.RawInputModifiers.Control;
                    if (keyParts.Contains("shift")) mods |= Avalonia.Input.RawInputModifiers.Shift;
                    if (keyParts.Contains("alt")) mods |= Avalonia.Input.RawInputModifiers.Alt;
                    window.KeyPress(Enum.Parse<Avalonia.Input.Key>(keyParts[0], true), mods, Avalonia.Input.PhysicalKey.None, null);
                    window.KeyRelease(Enum.Parse<Avalonia.Input.Key>(keyParts[0], true), mods, Avalonia.Input.PhysicalKey.None, null);
                    break;
                case "tree": Tree(window, arg); break;
                case "hoverdivider":
                    // 分隔条当作指针停在上面（看拖动把手）：arg = 沿线的位置
                    foreach (var divider in window.GetVisualDescendants().OfType<Views.ChatPanesView.PaneDivider>()) divider.DebugHover(double.Parse(arg));
                    break;
                case "copyshown": Views.CopyCorner.CaptureShown = true; break;
                // Agent 详情（按会话标题找）、设备详情（来源 id），之后用 dialogshot 截
                case "agentinfo":
                    if (model.Sessions.FirstOrDefault(x => x.Title == arg) is { } who) Views.AgentDetails.Open(who.Key);
                    break;
                case "machine": Views.AgentDetails.OpenMachine(arg); break;
                case "pickopen": Views.AgentDetails.DemoPick = true; break;
                case "hoverrow":
                    // 左边栏标题含 arg 的那张会话卡片当作鼠标停在上面（看右上角的「×」）
                    var hoverRow = window.GetVisualDescendants().OfType<Views.SessionRowView>().FirstOrDefault(r => r.ShownTitle?.Contains(arg) == true);
                    hoverRow?.Hover(true);
                    Console.WriteLine($"[capture] 悬停卡片「{arg}」：{(hoverRow is null ? "没找到" : "已悬停")}");
                    break;
                case "tap":
                    // 点一下写着这段字的按钮（最上面的窗口先找）：tap:打开其他文件夹…
                    var tapped = Windows().Reverse().SelectMany(w => w.GetVisualDescendants().OfType<Tap>())
                        .FirstOrDefault(t => t.IsEffectivelyVisible && t.GetVisualDescendants().OfType<TextBlock>().Any(b => b.Text == arg));
                    Console.WriteLine(tapped is null ? $"[capture] 没找到按钮「{arg}」" : $"[capture] 点了「{arg}」");
                    tapped?.Click?.Invoke();
                    break;
                case "titleshot":
                    // 按标题截某个窗口：titleshot:新任务=路径.png
                    var pair = arg.Split('=', 2);
                    if (Windows().LastOrDefault(w => w.Title == pair[0]) is Window titled) Shot(titled, pair[1]); else Console.Error.WriteLine($"没有标题为「{pair[0]}」的窗口");
                    break;
                case "text":
                    // 单独画一行字（核对字体回退的宽度）：text:字号|文字|路径
                    var bits = arg.Split('|');
                    var tb = bits.Length > 4 ? Ui.Text(bits[1], double.Parse(bits[0]), color: bits[4]) : new TextBlock { Text = bits[1], FontSize = double.Parse(bits[0]), FontFamily = Look.Family };
                    if (bits.Length <= 4) tb.Foreground = Avalonia.Media.Brushes.White;
                    var holder = new Border { Child = bits.Length > 3 ? Ui.H(4, Ui.Sym("xmark.seal", 11, "Red"), tb) : tb, Background = Avalonia.Media.Brushes.DarkSlateGray, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top,
                        CornerRadius = new CornerRadius(bits.Length > 3 ? 10 : 0), Padding = new Thickness(bits.Length > 3 ? 8 : 0, bits.Length > 3 ? 3 : 0) };
                    var probe2 = new Window { Width = 400, Height = 80, Content = holder, FontFamily = Look.Family };
                    probe2.Show(); Pump(0.3);
                    Console.WriteLine($"[capture] 「{bits[1]}」量出来 {tb.Bounds.Width:0.0}×{tb.Bounds.Height:0.0}，字体 {Look.Family}");
                    Shot(probe2, bits[2], 2); probe2.Close();
                    break;
                case "kite":
                    // 单独画一只大纸鸢（核对形状）：kite:路径
                    var probe = new Window { Width = 400, Height = 400, Content = new KiteIcon(384) };
                    probe.Show(); Pump(0.3); Shot(probe, arg, 2); probe.Close();
                    break;
                default: Console.WriteLine($"[capture] 不认识的步骤：{step}"); break;
            }
            Pump(0.3);
        }
        return 0;
    }

    /// 让界面线程跑一会儿：处理排队的任务（网络回来的数据）、推动画和重绘
    static void Pump(double seconds)
    {
        var until = DateTime.Now.AddSeconds(seconds);
        while (DateTime.Now < until)
        {
            Dispatcher.UIThread.RunJobs();
            AvaloniaHeadlessPlatform.ForceRenderTimerTick();
            Thread.Sleep(15);
        }
    }

    /// 排查用：列出界面层级（类型、位置、大小）；arg = 只列类型名里含这个的子树
    /// 离屏时没有应用生命周期管窗口：开过的窗口自己记（tap、titleshot 用）
    static readonly List<Window> opened = [];
    static IEnumerable<Window> Windows() => opened.Where(w => w.IsVisible);

    static void Tree(Visual root, string filter)
    {
        void Walk(Visual v, int depth, bool on)
        {
            var name = v.GetType().Name;
            on = on || filter.Length == 0 || name.Contains(filter);
            if (on)
            {
                var p = v.TranslatePoint(new Point(0, 0), root) ?? default;
                var text = v is TextBlock t ? $" \"{t.Text}\" {t.FontSize} {t.FontFamily.Name}" : "";
                Console.WriteLine($"{new string(' ', depth)}{name} ({p.X:0},{p.Y:0} {v.Bounds.Width:0}×{v.Bounds.Height:0}){(v.IsVisible ? "" : " 隐藏")}{text}");
            }
            foreach (var c in Avalonia.VisualTree.VisualExtensions.GetVisualChildren(v)) Walk(c, depth + 1, on);
        }
        Walk(root, 0, false);
    }

    /// 按 2 倍画成 PNG（和 Mac 版截图一样大）
    static void Shot(Window window, string path, double scale = 2)
    {
        var w = window.Bounds.Width > 0 ? window.Bounds.Width : window.Width;
        var h = window.Bounds.Height > 0 ? window.Bounds.Height : window.Height;
        using var bitmap = new RenderTargetBitmap(new PixelSize((int)(w * scale), (int)(h * scale)), new Vector(96 * scale, 96 * scale));
        bitmap.Render(window);
        bitmap.Save(path);
        Console.WriteLine($"[capture] {path} {(int)w}×{(int)h}");
    }
}
