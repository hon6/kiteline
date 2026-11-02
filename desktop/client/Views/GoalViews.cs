using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 目标（/goal）各状态的说法、图标、颜色（同 Mac 版 GoalText）：进行中主题色、停下了橙、达成绿、做不到红
public static class GoalText
{
    public static string Label(string state) => state switch
    {
        "paused" => L("目标已暂停"),
        "blocked" => L("目标受阻"),
        "limited" => L("目标额度已用完"),
        "met" => L("目标已达成"),
        "failed" => L("目标无法达成"),
        "error" => L("目标已中止"),
        _ => L("目标进行中"),
    };

    /// 列表小标识上的字：进行中写第几轮
    public static string Badge(string state, int? round) => state == "active" && round is > 1 ? L("目标 · 第 %@ 轮", round) : Label(state);

    public static string Symbol(string state) => state switch
    {
        "paused" => "pause",
        "blocked" or "limited" => "exclamationmark.circle",
        "met" => "checkmark.circle",
        "failed" or "error" => "xmark.circle",
        _ => "flag",
    };

    /// (字色, 淡底, 细边)
    public static (string Fg, string Fill, string Edge) Tint(string state) => state switch
    {
        "paused" or "blocked" or "limited" => ("Orange", "OrangeFill13", "OrangeEdge40"),
        "met" => ("Added", "AddedFill", "AddedEdge40"),
        "failed" or "error" => ("Removed", "RemovedFill", "RemovedEdge40"),
        _ => ("Accent", "AccentFill14", "AccentEdge40"),
    };

    /// 对话里目标那几行提示前的小图标
    public static string EventSymbol(string kind) => kind switch
    {
        "met" => "checkmark.circle",
        "failed" or "error" => "xmark.circle",
        "paused" => "pause",
        "check" => "arrow.triangle.2.circlepath",
        _ => "flag",
    };

    /// 「3 轮 · 12m · 45.2k token」：结束了的目标用了多少（没有的项不写）
    public static string Stats(int? turns, int? seconds, int? tokens)
    {
        var parts = new List<string>();
        if (turns is > 0) parts.Add(L("%lld 轮", turns));
        if (seconds is > 0) parts.Add(Format.Duration(seconds.Value));
        if (tokens is > 0) parts.Add(L("%@ token", Format.Tokens(tokens.Value)));
        return string.Join(" · ", parts);
    }
}

/// 列表里的「目标 · 第 3 轮」（同 Mac 版 GoalBadge）：淡色底、细边，颜色按状态
public static class GoalBadge
{
    public static Border Make(GoalInfo goal, double size = 11)
    {
        var (fg, fill, edge) = GoalText.Tint(goal.State);
        var box = Ui.Box(Ui.H(size * 0.28, Ui.Sym(GoalText.Symbol(goal.State), size * 0.92, fg),
                              Ui.Text(GoalText.Badge(goal.State, goal.Round), size, FontWeight.Medium, fg)),
                         new Thickness(size * 0.5, size * 0.14), fill, size, edge);
        box.HorizontalAlignment = HorizontalAlignment.Left;
        box.VerticalAlignment = VerticalAlignment.Center;
        ToolTip.SetTip(box, goal.Text);
        return box;
    }
}

/// 对话页输入框上方（任务进展条之上）的目标条（同 Mac 版 GoalStrip）：目标是什么、到哪了（第几轮、最近一次检查还差什么），
/// 点一下打开目标面板。结束了的（达成、做不到、出错）显示结果，点 × 收起（同一个目标不再出来）
public sealed class GoalStrip : Panel
{
    const double Corner = 12;
    const string DismissedKey = "goalStripDismissed";
    readonly Border card = new() { CornerRadius = new CornerRadius(Corner), BorderThickness = new Thickness(0.5), ClipToBounds = true };
    readonly DispatcherTimer timer;
    GoalInfo? goal;
    string key = "";
    string? built;

    public GoalStrip()
    {
        IsVisible = false;
        MaxWidth = 832;
        Margin = new Thickness(24, 0);
        // 同任务进展条：白底细边、浅阴影；阴影单独一层、不放子控件（离屏截图会把内容画到两倍的位置）
        card.Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");
        Children.Add(new Border { CornerRadius = new CornerRadius(Corner), Background = Brushes.Transparent, BoxShadow = BoxShadows.Parse("0 2 10 0 #0F000000") });
        Children.Add(card);
        timer = new DispatcherTimer(TimeSpan.FromSeconds(30), DispatcherPriority.Background, (_, _) => { built = null; Render(); });
    }

    static bool Dismissed(GoalInfo goal) => (Prefs.String(DismissedKey) ?? "").Split('\n').Contains(goal.Id);

    public void Update(string sessionKey, GoalInfo? next)
    {
        key = sessionKey;
        goal = next is not null && (next.Running || !Dismissed(next)) ? next : null;
        IsVisible = goal is not null;
        if (goal is null) { built = null; timer.Stop(); return; }
        var signature = $"{goal}|{Bounds.Width >= 300}";
        if (signature != built) { built = signature; Render(); }
        if (VisualRoot is not null && goal.Running) timer.Start(); else timer.Stop();
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e) { base.OnAttachedToVisualTree(e); if (goal?.Running == true) timer.Start(); }
    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e) { base.OnDetachedFromVisualTree(e); timer.Stop(); }

    void Render()
    {
        if (goal is not GoalInfo g) return;
        var (fg, _, _) = GoalText.Tint(g.State);
        var detail = g.Running ? g.Note ?? g.Reason : g.State == "met" ? null : g.Reason ?? g.Note;
        var title = Ui.H(6, Ui.Text(GoalText.Label(g.State), 12.5, FontWeight.SemiBold, fg), Ui.Text(g.Text, 12.5, color: "Text").Opacity(0.8).Shrink());
        // 还差什么（最近一次检查的说法）/ 为什么停下：一眼看出进展；窄的分屏块里放不下就不写
        var lines = Ui.VFill(2, title, detail is not null && (Bounds.Width == 0 || Bounds.Width >= 300) ? Ui.Text(detail, 11.5, color: "Text2").Trim() : null);
        var seconds = g.Seconds(Format.NowMs);
        var progress = g.Running
            ? string.Join(" · ", new[] { g.Round is > 1 ? L("第 %@ 轮", g.Round) : null, seconds is int s ? Format.Duration(s) : null }.OfType<string>())
            : GoalText.Stats(g.Turns ?? g.Checks, seconds, null);
        Control end = g.Running ? Ui.Sym("chevron.up", 10, "Text2")
            : new Tap(Ui.Sym("xmark", 10, "Text2").Pad(5), Dismiss, 4).Keys("Transparent", "Fill08").Tip(L("收起"));
        var row = Ui.H(8, Ui.Sym(GoalText.Symbol(g.State), 13, fg), lines.Shrink(), new Spacer(4), Ui.Text(progress, 12, color: "Text2").Digits(), end);
        card.Child = new Tap(row.Pad(12, 7, 10, 7), () => GoalSheet.Open(key), 0) { MinHeight = 34 }.Keys("Transparent", "Fill05").Tip(L("查看目标"));
    }

    void Dismiss()
    {
        if (goal is null) return;
        var ids = (Prefs.String(DismissedKey) ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries).Append(goal.Id).TakeLast(50);
        Prefs.Set(DismissedKey, string.Join("\n", ids));
        Update(key, null);
    }
}

/// 目标面板（同 Mac 版 GoalSheet）：没设目标时写一个（多行，可以说话输入），点「开始」发 /goal；设了的看进展（第几轮、用了多久、
/// 最近一次检查还差什么），可以清除、换一个，Codex 的还能暂停 / 继续。从输入框下面的「目标」、目标条、会话菜单打开
public static class GoalSheet
{
    /// Claude Code 的 /goal 最长 4000 字
    const int Limit = 4000;

    public static void Open(string key)
    {
        var replacing = false;
        NavSheet.Open(L("目标"), sheet =>
        {
            var model = AppModel.Shared;
            var session = model.Session(key);
            var goal = session?.Goal;
            var speaker = session?.Speaker ?? "Agent";
            var stack = new StackPanel { Margin = new Thickness(14, 4, 14, 16), Spacing = 10 };
            if (goal is not null) stack.Children.Add(Current(goal, speaker));
            if (goal is { Running: true } && !replacing && session is { CanReply: true })
                stack.Children.Add(Actions(key, goal, session, sheet, () => { replacing = true; sheet.Reload(); }));
            if (goal is not { Running: true } || replacing)
                stack.Children.Add(Editor(key, session, goal, sheet));
            return NavSheet.Scroll(stack);
        }, 540, 600);
    }

    /// 现在的目标：状态、原文、进展（第几轮 / 用了几轮、用时、token、停下的原因、最近一次检查）
    static Control Current(GoalInfo goal, string speaker)
    {
        var head = Ui.VFill(4,
            Ui.H(8, GoalBadge.Make(goal, 12), new Spacer(4), goal.Since is double since ? Ui.Text(L("设定于 %@", Format.ListTime(since)), 11.5, color: "Text2") : null),
            new SelectableTextBlock { Text = goal.Text, TextWrapping = TextWrapping.Wrap, FontSize = Look.Pt(14) }).Pad(12, 10);
        var rows = new List<Control> { head };
        void Info(string title, string value) => rows.Add(Ui.H(12, Ui.Text(title, 13), new Spacer(8), Ui.Text(value, 13, color: "Text2")).Pad(12, 8));
        void Reason(string title, string text) => rows.Add(Ui.VFill(3, Ui.Text(title, 11.5, color: "Text2"),
            new SelectableTextBlock { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = Look.Pt(13) }).Pad(12, 8));
        if (goal.Running && goal.Round is int round)
            Info(L("进度"), round > 1 ? L("第 %@ 轮（已检查 %@ 次）", round, goal.Checks ?? 0) : L("第 1 轮"));
        else if ((goal.Turns ?? goal.Checks) is int turns && turns > 0)
            Info(L("用了"), L("%lld 轮", turns));
        if (goal.Seconds(Format.NowMs) is int seconds) Info(L("用时"), Format.Duration(seconds));
        if (goal.Tokens is int tokens && tokens > 0)
            Info("Token", goal.Budget is int budget ? L("%@ / 预算 %@", Format.Tokens(tokens), Format.Tokens(budget)) : Format.Tokens(tokens));
        if (goal.Note is string note) Reason(goal.State == "limited" ? L("原因") : L("停下的原因"), note);
        if (goal.Reason is string reason)
            Reason(goal.Running ? L("最近一次检查") : goal.State == "met" ? L("检查结论") : L("原因"), reason);
        else if (goal.Running && goal.Note is null)
            Reason(L("最近一次检查"), goal.Checks is null ? L("由 %@ 在每轮结束时自行判断是否达成", speaker) : L("本轮结束后检查"));
        return ChatSheets.Group(rows, 12);
    }

    /// 停下了的发一句「继续」（Claude Code 收到消息就接着做）；Codex 的暂停 / 继续走它自己的目标状态；都能清除、换一个
    static Control Actions(string key, GoalInfo goal, SessionInfo session, NavSheet sheet, Action replace)
    {
        var buttons = Ui.H(8);
        if (session.Can("goal-pause"))
        {
            buttons.Children.Add(goal.State == "active"
                ? Form.Button(L("暂停目标"), () => Command(key, "/goal pause", sheet)).Tip(L("%@ 做完这一轮后不再续做", session.Speaker))
                : Form.Button(L("继续目标"), () => Command(key, "/goal resume", sheet), prominent: true).Tip(L("%@ 接着一轮一轮推进", session.Speaker)));
        }
        else if (goal.State != "active")
        {
            buttons.Children.Add(Form.Button(L("继续"), () => Command(key, L("继续"), sheet), prominent: true).Tip(L("发送「继续」，%@ 接着推进目标", session.Speaker)));
        }
        buttons.Children.Add(Form.Button(L("清除目标"), async () =>
        {
            if (await Dialogs.Confirm(L("清除目标后 %@ 不再自动续做，正在进行的这一轮不受影响", session.Speaker), L("清除目标"), destructive: true))
                Command(key, "/goal clear", sheet);
        }));
        buttons.Children.Add(Form.Button(L("换一个目标"), replace));
        return buttons;
    }

    /// 写目标：多行、可以说话输入；输入框里已经写了字的直接带过来（一键把要说的话变成目标）
    static Control Editor(string key, SessionInfo? session, GoalInfo? goal, NavSheet sheet)
    {
        var model = AppModel.Shared;
        var draft = (model.Draft(key) ?? "").Trim();
        var fromDraft = draft.Length > 0 && goal is not { Running: true };
        var input = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 110, MaxHeight = 260, FontSize = Look.Pt(14),
            Padding = new Thickness(10, 8), Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            Watermark = L("例如：把登录模块的单元测试全部跑通，并修复发现的问题"), Text = fromDraft ? draft : "",
        };
        input.Classes.Add("plain");
        var count = Ui.Text("", 11.5, color: "Text2").Digits();
        Tap? start = null;
        void Changed()
        {
            var length = (input.Text ?? "").Trim().Length;
            count.Text = length > Limit - 500 ? L("%@ / %@ 字", length, Limit) : "";
            count.Res(TextBlock.ForegroundProperty, length > Limit ? "Removed" : "Text2");
            if (start is not null)
            {
                start.IsEnabled = length > 0 && length <= Limit && session?.CanReply == true;
                start.Opacity = start.IsEnabled ? 1 : 0.4;   // 按钮样式不认禁用：淡下去，免得看着能点
            }
        }
        void Start()
        {
            var text = (input.Text ?? "").Trim();
            if (text.Length == 0 || text.Length > Limit) return;
            // 一行发出去：终端里的会话按行投递，换行会提前提交
            var line = string.Join(" ", text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0));
            Command(key, "/goal " + line, sheet);
            if (fromDraft) model.SetDraft(key, "");
        }
        start = Form.Button(L("开始"), Start, prominent: true);
        input.TextChanged += (_, _) => Changed();
        var field = new Border
        {
            CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(0.5),
            Child = new StackPanel
            {
                Children =
                {
                    input,
                    Ui.H(8, new DictateButton(said => { input.Text = DictateButton.Append(said, input.Text); input.Focus(); input.CaretIndex = input.Text?.Length ?? 0; }),
                        new Spacer(), count).Pad(8, 0, 8, 8),
                },
            },
        }.Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");
        Changed();
        Dispatcher.UIThread.Post(() => input.Focus(), DispatcherPriority.Background);
        var stack = new StackPanel { Spacing = 8 };
        if (goal is { Running: true }) stack.Children.Add(Ui.Text(L("新目标会替换当前目标"), 12, FontWeight.SemiBold, "Text2"));
        stack.Children.Add(field);
        stack.Children.Add(ChatSheets.Note(L("%@ 将围绕这个目标跨多轮持续工作，每轮结束检查一次是否达成，确认完成才停下。写清楚怎样算完成（例如「所有测试通过且无报错」）。达成、无法达成或中途停下时会推送提醒。",
            session?.Speaker ?? "Agent")));
        stack.Children.Add(Ui.H(8, new Spacer(), start));
        return stack;
    }

    static void Command(string key, string text, NavSheet sheet)
    {
        AppModel.Shared.Send(key, text, []);
        sheet.Close();
    }
}
