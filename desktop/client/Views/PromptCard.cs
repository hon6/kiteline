using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// Claude 停下来等你时，输入框上方的卡片：权限确认、批准计划、回答提问（同 Mac 版 PromptCard）。
/// 最宽 832、居中，圆角 16，细边 + 阴影
public static class PromptCard
{
    /// 这个会话现在等你确认的是哪一个：按之前核对（点的这一下 Claude 那边刚好换成了下一个确认，就不按）
    public static string Current(string key, ChatStore chat) => $"{key}|{chat.OpenTool?.Id ?? "-"}|{AppModel.Shared.Session(key)?.Blocking ?? ""}";

    public static Control? Make(SessionInfo session, ChatStore chat, double cap)
    {
        var tool = chat.OpenTool;
        var signature = Current(session.Key, chat);
        if (!session.IsWaiting || !session.CanReply || chat.AnsweredPrompt == signature) return null;
        Control body;
        if (tool is { Name: "AskUserQuestion" } && tool.Input.Arr("questions") is { Count: > 0 }) body = new QuestionCard(session, chat, tool, signature, cap);
        else if (tool is { Name: "ExitPlanMode" }) body = Plan(session, chat, tool.Input.Str("plan") ?? "", signature, cap);
        else if (tool is not null) body = Permission(session, chat, tool, signature);
        else body = Confirm(session, chat, signature);
        // 阴影单独一层（和内容放在同一个元素上，离屏截图里内容会画不出来）
        var card = new Border { Child = body, Padding = new Thickness(14), CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(0.5) };
        card.Res(Border.BackgroundProperty, "Card").Res(Border.BorderBrushProperty, "Separator");
        var shadow = new Border { CornerRadius = new CornerRadius(16), Background = Brushes.Transparent, BoxShadow = BoxShadows.Parse("0 6 24 0 #1F000000") };
        return new Panel { MaxWidth = 832, Margin = new Thickness(24, 0), Children = { shadow, card } };
    }

    static Control Title(string symbol, string text) =>
        Ui.H(8, Ui.Sym(symbol, 15, "Accent"), Ui.Text(text, 15, FontWeight.SemiBold).Shrink());

    static Control Permission(SessionInfo session, ChatStore chat, ChatItem tool, string signature)
    {
        var input = tool.Input;
        var command = new[] { "command", "file_path", "url", "pattern" }.Select(k => input.Str(k)).FirstOrDefault(s => !string.IsNullOrEmpty(s));
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(Title("exclamationmark.triangle.fill", L("%@ 想使用 %@", session.Speaker, Tools.DisplayName(tool.Name))));
        stack.Children.Add(Ui.Text(session.Blocking ?? input.Str("description") ?? L("需要你的授权"), 13, color: "Text2", lines: 3).Wrap());
        if (command is not null)
        {
            var text = new SelectableTextBlock { Text = command, FontFamily = Look.Mono, FontSize = Look.Pt(13), TextWrapping = TextWrapping.Wrap, MaxLines = 5, TextTrimming = TextTrimming.CharacterEllipsis };
            text.Res(TextBlock.ForegroundProperty, "Text");
            stack.Children.Add(CopyCorner.Wrap(Ui.Box(text, new Thickness(10), "Code", 10).HAlign(HorizontalAlignment.Stretch), command, 5));
        }
        stack.Children.Add(Keys(session, chat, signature, (L("拒绝"), "esc"), (L("允许"), "1"),
            Agents.Info(session.Agent).AllowsAlways ? (L("允许，且本会话不再询问"), "2") : null));
        return stack;
    }

    static Control Plan(SessionInfo session, ChatStore chat, string plan, string signature, double cap)
    {
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(Title("map.fill", L("%@ 已拟定计划，等待你批准", session.Speaker)));
        if (plan.Length > 0)
        {
            var scroll = new ScrollViewer { Content = new MarkdownView(plan).Pad(12), MaxHeight = Math.Min(280, cap) };
            stack.Children.Add(Ui.Box(scroll, new Thickness(0), "Code", 12));
        }
        stack.Children.Add(Keys(session, chat, signature, (L("继续规划"), "esc"), (L("批准执行"), "1")));
        return stack;
    }

    static Control Confirm(SessionInfo session, ChatStore chat, string signature)
    {
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(Title("exclamationmark.triangle.fill", L("需要确认")));
        stack.Children.Add(Ui.Text(session.Blocking ?? session.Reason ?? "", 13, color: "Text2", lines: 3).Wrap());
        stack.Children.Add(Keys(session, chat, signature, (L("取消"), "esc"), (L("确认"), "enter")));
        return stack;
    }

    /// 卡片上的按键：发给后台，成功后这张卡片先收起，等后台的状态更新。
    /// 按钮由后台给（插件的 pendingOptions）就照它画：拒绝 + 主按钮并排，其余排在下面；没给就是调用处写的老三样
    static Control Keys(SessionInfo session, ChatStore chat, string signature, (string Label, string Key) cancel, (string Label, string Key) confirm, (string Label, string Key)? extra = null)
    {
        var options = session.PendingOptions ?? new[] { new PendingOption(cancel.Key, cancel.Label, "destructive"), new PendingOption(confirm.Key, confirm.Label, "primary") }
            .Concat(extra is { } x ? [new PendingOption(x.Key, x.Label, "normal")] : Array.Empty<PendingOption>()).ToList();
        var stack = new StackPanel { Spacing = 8 };
        var busy = false;
        async void Press(PendingOption k)
        {
            if (busy) return;
            if (Current(session.Key, chat) != signature)
            {
                AppModel.Shared.Flash(L("%@ 的确认请求已更新，请查看后再操作", session.Speaker));
                return;
            }
            busy = true;
            stack.Opacity = 0.6;
            if (await AppModel.Shared.Press(session.Key, k.Key, L("已选择：%@", k.Label))) { chat.AnsweredPrompt = signature; chat.Touch(); }
            busy = false;
            stack.Opacity = 1;
        }
        var no = options.FirstOrDefault(o => o.Style == "destructive");
        var yes = options.FirstOrDefault(o => o.Style == "primary");
        if (no is not null && yes is not null)
        {
            stack.Children.Add(new ButtonPair(CardButton(no.Label, false, () => Press(no), "Removed"), CardButton(yes.Label, true, () => Press(yes))));
            foreach (var other in options.Where(o => !ReferenceEquals(o, no) && !ReferenceEquals(o, yes)))
                stack.Children.Add(new Tap(Ui.Text(other.Label, 13, color: other.Style == "destructive" ? "Removed" : "Accent"), () => Press(other), 6)
                    { Padding = new Thickness(8, 4), HorizontalAlignment = HorizontalAlignment.Center });
        }
        else
        {
            // 没有「拒绝 + 主按钮」这一对（比如全是并列的选项）：一个一行
            foreach (var option in options)
                stack.Children.Add(CardButton(option.Label, option.Style == "primary", () => Press(option), option.Style == "destructive" ? "Removed" : null));
        }
        return stack;
    }

    /// 卡片底下的大按钮（同 Mac 版 CardButtonStyle）：44 高、圆角 12；主按钮填主按钮色白字，另一个是淡底
    public static Tap CardButton(string label, bool prominent, Action action, string? color = null)
    {
        var text = Ui.Text(label, 16, FontWeight.SemiBold, prominent ? "White" : color ?? "Text").HAlign(HorizontalAlignment.Center);
        var tap = new Tap(text, action, 12) { MinHeight = 44, HorizontalAlignment = HorizontalAlignment.Stretch };
        if (prominent) tap.Keys("Action", "Action"); else tap.Keys("Fill08", "Fill12");
        return tap;
    }
}

/// 卡片底下的两个大按钮：放得下就左右并排；太窄就上下叠，主按钮在上（同 Mac 版 ButtonPair）
public sealed class ButtonPair : Panel
{
    readonly Control secondary, primary;
    bool stacked;

    public ButtonPair(Control secondary, Control primary)
    {
        this.secondary = secondary;
        this.primary = primary;
        Children.Add(secondary);
        Children.Add(primary);
    }

    protected override Size MeasureOverride(Size available)
    {
        secondary.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        primary.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var need = secondary.DesiredSize.Width + primary.DesiredSize.Width + 10 + 40;
        stacked = !double.IsInfinity(available.Width) && need > available.Width;
        var width = double.IsInfinity(available.Width) ? need : available.Width;
        if (stacked)
        {
            primary.Measure(new Size(width, double.PositiveInfinity));
            secondary.Measure(new Size(width, double.PositiveInfinity));
            return new Size(width, primary.DesiredSize.Height + 8 + secondary.DesiredSize.Height);
        }
        var half = (width - 10) / 2;
        primary.Measure(new Size(half, double.PositiveInfinity));
        secondary.Measure(new Size(half, double.PositiveInfinity));
        return new Size(width, Math.Max(primary.DesiredSize.Height, secondary.DesiredSize.Height));
    }

    protected override Size ArrangeOverride(Size final)
    {
        if (stacked)
        {
            primary.Arrange(new Rect(0, 0, final.Width, primary.DesiredSize.Height));
            secondary.Arrange(new Rect(0, primary.DesiredSize.Height + 8, final.Width, secondary.DesiredSize.Height));
        }
        else
        {
            var half = (final.Width - 10) / 2;
            secondary.Arrange(new Rect(0, 0, half, final.Height));
            primary.Arrange(new Rect(half + 10, 0, half, final.Height));
        }
        return final;
    }
}

/// Claude 用 AskUserQuestion 问你：单选 / 多选，也可以自己写（同 Mac 版 QuestionCard）
public sealed class QuestionCard : StackPanel
{
    readonly SessionInfo session;
    readonly ChatStore chat;
    readonly ChatItem tool;
    readonly string signature;
    readonly List<JsonNode> questions;
    readonly double cap;
    Tap? submitButton;
    bool busy;

    public QuestionCard(SessionInfo session, ChatStore chat, ChatItem tool, string signature, double cap)
    {
        this.session = session;
        this.chat = chat;
        this.tool = tool;
        this.signature = signature;
        this.cap = cap;
        questions = tool.Input.Arr("questions").Items().ToList();
        Spacing = 12;
        Build();
    }

    List<QuestionAnswer> Answers
    {
        get
        {
            if (!chat.Answers.TryGetValue(tool.Id, out var saved)) chat.Answers[tool.Id] = saved = [];
            while (saved.Count < questions.Count) saved.Add(new QuestionAnswer());
            return saved;
        }
    }

    bool Complete => Answers.Take(questions.Count).All(a => a.Picked.Count > 0 || a.Other.Trim().Length > 0);

    void Build()
    {
        Children.Clear();
        Children.Add(Ui.H(8, Ui.Sym("questionmark.bubble.fill", 15, "Accent"), Ui.Text(L("%@ 提问", session.Speaker), 15, FontWeight.SemiBold)));
        var blocks = new StackPanel { Spacing = 16 };
        for (var i = 0; i < questions.Count; i++) blocks.Children.Add(Block(i, questions[i]));
        Children.Add(new ScrollViewer { Content = blocks, MaxHeight = Math.Min(380, cap) });
        submitButton = PromptCard.CardButton(L("确定"), true, Submit);
        submitButton.Opacity = Complete ? 1 : 0.4;
        Children.Add(new ButtonPair(PromptCard.CardButton(L("跳过"), false, Skip, "Removed"), submitButton));
    }

    Control Block(int index, JsonNode question)
    {
        var multi = question.Bool("multiSelect") == true;
        var answer = Answers[index];
        var stack = new StackPanel { Spacing = 8 };
        if (question.Str("header") is { Length: > 0 } header)
            stack.Children.Add(Ui.Box(Ui.Text(header, 11.5, FontWeight.SemiBold, "Accent"), new Thickness(8, 3), "IconTile", 10).HAlign(HorizontalAlignment.Left));
        stack.Children.Add(Ui.Text(question.Str("question") ?? "", 16, FontWeight.SemiBold, lines: 0).Wrap());
        foreach (var option in question.Arr("options").Items())
        {
            var label = option.Str("label") ?? "";
            var on = answer.Picked.Contains(label);
            var icon = Ui.Sym(on ? (multi ? "checkmark.square.fill" : "checkmark.circle.fill") : (multi ? "square" : "circle"), 16, on ? "Action" : "Text2");
            icon.VerticalAlignment = VerticalAlignment.Top;
            var texts = new StackPanel { Spacing = 2 };
            texts.Children.Add(Ui.Text(label, 15, lines: 0).Wrap());
            if (option.Str("description") is { Length: > 0 } desc) texts.Children.Add(Ui.Text(desc, 13, color: "Text2", lines: 0).Wrap());
            var row = new DockPanel();
            icon.Margin = new Thickness(0, 1, 10, 0);
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            row.Children.Add(texts);
            var tap = new Tap(row.Pad(10), () =>
            {
                if (multi) { if (!answer.Picked.Remove(label)) answer.Picked.Add(label); }
                else { answer.Picked.Clear(); answer.Picked.Add(label); answer.Other = ""; }
                Build();
            }, 14);
            if (on) tap.Keys("ActionFill10", "ActionFill10"); else tap.Keys("Fill03", "Fill06");
            stack.Children.Add(tap);
        }
        var other = new TextBox
        {
            Text = answer.Other, Watermark = L("其他（自定义）"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 96,
            FontSize = Look.Pt(15), BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(0, 4),
        };
        other.TextChanged += (_, _) =>
        {
            answer.Other = other.Text ?? "";
            if (!multi && answer.Other.Trim().Length > 0) answer.Picked.Clear();
            if (submitButton is not null) submitButton.Opacity = Complete ? 1 : 0.4;
        };
        var dictate = new DictateButton(said => { other.Text = DictateButton.Append(said, other.Text); other.Focus(); }, compact: true);
        stack.Children.Add(Ui.Box(Ui.H(8, other.Grow(), dictate), new Thickness(10, 6), "Fill03", 14).HAlign(HorizontalAlignment.Stretch));
        return stack;
    }

    async void Submit()
    {
        if (busy || !Complete) return;
        if (PromptCard.Current(session.Key, chat) != signature) { AppModel.Shared.Flash(L("%@ 的确认请求已更新，请查看后再操作", session.Speaker)); return; }
        busy = true;
        var payload = questions.Select((q, i) => new Dictionary<string, object>
        {
            ["question"] = q.Str("question") ?? "", ["picked"] = Answers[i].Picked.ToList(), ["other"] = Answers[i].Other,
        }).ToList();
        if (await AppModel.Shared.Answer(session.Key, tool, payload)) { chat.AnsweredPrompt = signature; chat.Touch(); }
        busy = false;
    }

    async void Skip()
    {
        if (busy) return;
        if (PromptCard.Current(session.Key, chat) != signature) { AppModel.Shared.Flash(L("%@ 的确认请求已更新，请查看后再操作", session.Speaker)); return; }
        busy = true;
        if (await AppModel.Shared.Press(session.Key, "esc", L("已跳过"))) { chat.AnsweredPrompt = signature; chat.Touch(); }
        busy = false;
    }
}
