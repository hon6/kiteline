using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 输入框上方的排队列表（同 Mac / iPhone 版 QueueStrip、小程序 pages/chat）：Claude 正忙时发的消息先排在这里，等它做完当前这一步再读到。
/// 标题「⏱ 排队中 N 条」点一下收起；每条右边依次是上移、下移、编辑、删除，最右边「强插」= 中断 Claude 当前这一步，排队的消息马上发送。
/// 两块都在时从上到下：排队 → 任务进展 → 输入框
public sealed class QueueStrip : Panel
{
    const double Corner = 12;
    const double Button = 24;
    readonly Border card = new() { CornerRadius = new CornerRadius(Corner), BorderThickness = new Thickness(0.5), ClipToBounds = true };
    string key = "";
    ChatStore? chat;
    SessionInfo? session;
    string? built;
    string? editing;
    string? busy;

    public QueueStrip()
    {
        IsVisible = false;
        MaxWidth = 832;
        Margin = new Thickness(24, 0);
        // 同任务进展条：白底细边、浅阴影；阴影单独一层、不放子控件（离屏截图会把内容画到两倍的位置）
        card.Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");
        Children.Add(new Border { CornerRadius = new CornerRadius(Corner), Background = Brushes.Transparent, BoxShadow = BoxShadows.Parse("0 2 10 0 #0F000000") });
        Children.Add(card);
    }

    /// 会话状态或本机的发送变了
    public void Update(string sessionKey, ChatStore store, SessionInfo? next)
    {
        key = sessionKey;
        chat = store;
        session = next;
        var rows = store.QueueRows(next);
        IsVisible = rows.Count > 0;
        if (rows.Count == 0) { built = null; editing = null; return; }
        var signature = string.Join("\n", rows.Select(r => $"{r.Id}|{r.Editable}|{r.Text}")) + $"|{store.QueueCollapsed}|{editing}|{busy}|{Bounds.Width >= 340}";
        if (signature == built) return;
        built = signature;
        Render(rows);
    }

    void Refresh() { built = null; if (chat is not null) Update(key, chat, session); }

    void Render(List<ChatStore.QueueRow> rows)
    {
        var stack = new StackPanel();
        stack.Children.Add(Header(rows.Count));
        if (chat?.QueueCollapsed != true)
            for (var i = 0; i < rows.Count; i++)
            {
                stack.Children.Add(Ui.Rule("Fill06", 0.5).Margin(12, 0, 0, 0));
                stack.Children.Add(rows[i].Id == editing ? Editor(rows[i]) : Line(rows[i], i, rows.Count));
            }
        card.Child = stack;
    }

    /// 标题行：⏱ 排队中 N 条 · Claude 完成当前这一步后读到 …… ⌄
    Control Header(int count)
    {
        var collapsed = chat?.QueueCollapsed == true;
        var row = Ui.H(6, Ui.Sym("clock", 11, "Text"), Ui.Text(L("排队中 %@ 条", count), 12.5, FontWeight.SemiBold),
            Bounds.Width == 0 || Bounds.Width >= 340 ? Ui.Text(L("Claude 完成当前这一步后读到"), 12.5, color: "Text2").Shrink() : null,
            new Spacer(4), Ui.Sym(collapsed ? "chevron.up" : "chevron.down", 10, "Text2"));
        return new Tap(row.Pad(12, 0, 12, 0), () => { if (chat is not null) chat.QueueCollapsed = !chat.QueueCollapsed; Refresh(); }, 0) { MinHeight = 34 }
            .Keys("Transparent", "Fill05").Tip(collapsed ? L("展开") : L("收起"));
    }

    Control Line(ChatStore.QueueRow row, int index, int count)
    {
        var text = Ui.Text(row.Text.Trim().Replace('\n', ' '), 13).Shrink();
        // 斜杠命令（/effort、/model……）Claude Code 只在一轮做完后执行，插不进这一轮（同 iOS）
        var label = Ui.H(6, text, IsCommand(row.Text) ? Ui.Text(L("这一轮结束后执行"), 11.5, color: "Text2") : null).Grow();
        label.Margin = new Thickness(0, 0, 6, 0);
        // 强插：一个实心圆圈里一个上箭头（11-11），主题色
        var arrow = Ui.Sym("arrow.up.circle.fill", 19, "Accent");
        arrow.HorizontalAlignment = HorizontalAlignment.Center;
        arrow.VerticalAlignment = VerticalAlignment.Center;
        var nowButton = new Tap(arrow, () => Act(row, "now"), 6)
        { Width = Button, Height = Button, Margin = new Thickness(2, 0, 0, 0), IsEnabled = busy is null, Opacity = busy is null ? 1 : 0.4 }
            .Tip(L("强插：中断 Claude 当前这一步，排队的消息马上发送"));
        var line = Ui.H(2, label,
            row.Editable ? Icon("arrow.up", L("上移"), index == 0, () => Act(row, "move", dir: -1)) : null,
            row.Editable ? Icon("arrow.down", L("下移"), index == count - 1, () => Act(row, "move", dir: 1)) : null,
            row.Editable ? Icon("pencil", L("编辑"), false, () => { editing = row.Id; Refresh(); }) : null,
            row.Editable ? Icon("trash", L("删除"), false, () => Act(row, "delete")) : null,
            nowButton);
        return new Border { Child = line, Padding = new Thickness(12, 0, 8, 0), MinHeight = 36 };
    }

    /// 编辑：多行输入框 + 取消 / 保存（Ctrl+Enter 保存、Esc 取消）
    Control Editor(ChatStore.QueueRow row)
    {
        var input = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 140, FontSize = Look.Pt(13),
            Padding = new Thickness(10, 7), BorderThickness = new Thickness(0), Text = row.Text, Watermark = L("消息内容"),
        };
        input.Classes.Add("plain");
        var box = Ui.Box(input, new Thickness(0), "Fill05", 8);
        void Save()
        {
            var text = (input.Text ?? "").Trim();
            editing = null;
            if (text.Length > 0 && text != row.Text) Act(row, "edit", text: text);
            else Refresh();
        }
        input.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && e.KeyModifiers.HasFlag(KeyModifiers.Control)) { Save(); e.Handled = true; }
            else if (e.Key == Key.Escape) { editing = null; Refresh(); e.Handled = true; }
        };
        var buttons = Ui.H(8,
            new Tap(Ui.Text(L("取消"), 12, color: "Text2").Pad(8, 3), () => { editing = null; Refresh(); }, 6),
            new Tap(Ui.Text(L("保存"), 12, FontWeight.SemiBold, "Accent").Pad(8, 3), Save, 6)).Self(Align.End);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        input.AttachedToVisualTree += (_, _) => { input.Focus(); input.CaretIndex = input.Text?.Length ?? 0; };
        return new StackPanel { Spacing = 6, Margin = new Thickness(12, 8), Children = { box, buttons } };
    }

    /// 斜杠命令：「/」后面紧跟命令名，再是空白或结尾（开头是路径的「/home/…」不算）
    public static bool IsCommand(string text) =>
        System.Text.RegularExpressions.Regex.IsMatch(text.Trim(), @"^/[\w:.-]+(\s|$)");

    static Control Icon(string symbol, string label, bool disabled, Action action)
    {
        var tap = new Tap(Ui.Sym(symbol, 12, "Text2").Self(Align.Center), disabled ? null : action, 6)
        { Width = Button, Height = Button, Opacity = disabled ? 0.3 : 1 }.Tip(label);
        tap.Child!.HorizontalAlignment = HorizontalAlignment.Center;
        tap.Child.VerticalAlignment = VerticalAlignment.Center;
        if (disabled) tap.Cursor = Cursor.Default;
        return tap;
    }

    async void Act(ChatStore.QueueRow row, string action, string? text = null, int? dir = null)
    {
        if (busy is not null) return;
        if (action == "now") { busy = row.Id; Refresh(); }
        await AppModel.Shared.QueueAction(key, row.Id, action, text, dir);
        if (action == "now") busy = null;
        Refresh();
    }
}
