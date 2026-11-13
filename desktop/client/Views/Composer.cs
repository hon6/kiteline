using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 对话页底部的输入区（同 Mac 版 MacComposer）：常用语（平时收着，点下面那排最右边的「⌃」才出来）、附图、
/// 输入框（回车发送，Shift+回车换行，输入法选字的回车不算），Claude 在干活时红色停止键，空着时「+」选图，有字时绿色「发送」；
/// 输入框下面一排：权限模式、模型和思考等级、上下文、任务清单进度、子 agent。Ctrl+V 粘贴截图、把图拖进来都能附上。
/// 群聊页用的也是它（给了 group）：发到群里，下面那排换成「发给全部成员 ⌄」
public sealed class Composer : StackPanel
{
    const double Spacing0 = 8, Edge = 12, IconWidth = 34, IconInset = 2;
    readonly string key;
    readonly ChatStore chat;
    readonly TextBox input;
    readonly Border field;
    readonly Panel buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Spacing0 - IconInset * 2, VerticalAlignment = VerticalAlignment.Bottom };
    readonly StackPanel quickRow = new() { IsVisible = false };
    readonly StackPanel attachRow = new() { Orientation = Orientation.Horizontal, Spacing = 10, IsVisible = false, Margin = new Thickness(0, 7, 0, 0) };
    readonly Panel chipRow = new DockPanel();
    SessionInfo? session;
    /// 发到群里（群聊页）：没有停止键、权限模式那排
    readonly ComposeGroup? group;

    public Action? OnStop, OnMode, OnModel, OnCompact, OnTodos, OnAgents;

    public Composer(string key, ComposeGroup? group = null)
    {
        this.key = key;
        this.group = group;
        chat = AppModel.Shared.Chat(key);
        Spacing = Spacing0;
        MaxWidth = 832;
        Margin = new Thickness(24, Spacing0, 24, Edge);
        input = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontSize = Look.Pt(14), MinHeight = 38, MaxHeight = 132,
            BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(12, 9, 12, 9),
            VerticalContentAlignment = VerticalAlignment.Top, Classes = { "plain" },
            Text = AppModel.Shared.Draft(key) ?? "",
        };
        input.TextChanged += (_, _) => { AppModel.Shared.SetDraft(key, input.Text ?? ""); UpdateButtons(); };
        input.AddHandler(KeyDownEvent, OnKey, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        input.PasteImages(6, Attach);
        field = new Border { Child = input, CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(0.5) };
        field.Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");
        var fieldShadow = new Border { CornerRadius = new CornerRadius(14), Background = Brushes.Transparent, BoxShadow = BoxShadows.Parse("0 2 10 0 #0F000000") };
        var fieldBox = new Panel { Children = { fieldShadow, field } };
        var row = new DockPanel { Margin = new Thickness(0, 0, -IconInset, 0) };
        DockPanel.SetDock(buttons, Dock.Right);
        buttons.Margin = new Thickness(Spacing0 - IconInset, 0, 0, 0);
        row.Children.Add(buttons);
        row.Children.Add(fieldBox);
        Children.Add(quickRow);
        Children.Add(attachRow);
        Children.Add(row);
        Children.Add(chipRow);
        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DropEvent, OnDrop);
        Update(group is null ? AppModel.Shared.Session(key) : null);
    }

    public void Focus() => input.Focus();

    /// 自测用：哪个会话 / 群的输入栏；打字后按发送
    internal string TargetKey => key;
    internal void Submit(string text) { input.Text = text; Send(); }

    bool Enabled => group is not null || (session?.CanReply ?? true);
    /// 能附图：会话都能；群要后台收得了群里的图（老版本只收文字）
    bool CanAttach => group is null || GroupState.MediaSupported;
    bool HasContent => (input.Text ?? "").Trim().Length > 0 || chat.Attachments.Count > 0;
    bool QuickAvailable => Enabled && AppModel.Shared.QuickReplies.Count > 0;

    /// 会话状态变了（在忙 / 能不能回复 / 用量……）：重画按钮和下面那排
    public void Update(SessionInfo? s)
    {
        session = s;
        input.IsEnabled = Enabled;
        input.Watermark = group is not null
            ? (GroupState.Shared.Group(group.Id) is { Live: false } ? L("发消息，恢复成员会话接着协作") : L("在群里发消息，成员都会收到"))
            : s is null ? L("发送消息即可在 VS Code 中继续对话") : s.CanReply ? L("发消息给 %@", s.Speaker) : s.ReadOnlyNote;
        UpdateButtons();
        UpdateChips();
        UpdateQuick();
        UpdateAttachments();
    }

    void UpdateButtons()
    {
        buttons.Children.Clear();
        if (session is { IsBusy: true, CanReply: true })
            buttons.Children.Add(new CircleGlyph(true, () => OnStop?.Invoke(), "Red").Tip(session.IsClaude ? L("中断 Claude（等同于在 VS Code 中按 Esc）") : L("中断 %@", session.Speaker)));
        if (HasContent)
        {
            var send = new Tap(Ui.Text(L("发送"), 14, FontWeight.SemiBold, "White"), Send, 14) { Height = 38, Padding = new Thickness(16, 0), Margin = new Thickness(IconInset, 0) };
            send.Keys("Action", "Action");
            send.Child!.HorizontalAlignment = HorizontalAlignment.Center;
            buttons.Children.Add(send);
        }
        else buttons.Children.Add(new CircleGlyph(false, Pick, "Text2").Tip(L("发送图片")));
        UpdateQuick();
    }

    /// 输入框下面那排：权限模式、模型、上下文……；最右边「⌃」展开 / 收起常用语
    void UpdateChips()
    {
        chipRow.Children.Clear();
        if (!(session?.CanReply ?? false) && group is null && !QuickAvailable) { chipRow.IsVisible = false; return; }
        chipRow.IsVisible = true;
        if (QuickAvailable)
        {
            var shown = chat.QuickRepliesShown;
            var toggle = new Tap(Ui.Sym(shown ? "chevron.down" : "chevron.up", 11, shown ? "Accent" : "Text").HAlign(HorizontalAlignment.Center), () =>
            {
                chat.QuickRepliesShown = !chat.QuickRepliesShown;
                UpdateChips();
                UpdateQuick();
            }, 14) { Width = 28, Height = 28, Margin = new Thickness(Spacing0, 0, 0, 0) };
            toggle.Keys(shown ? "Tile" : "Field", "Fill12");
            toggle.Tip(shown ? L("收起常用语") : L("常用语"));
            DockPanel.SetDock(toggle, Dock.Right);
            chipRow.Children.Add(toggle);
        }
        if (group is not null) chipRow.Children.Add(RecipientsChip(group));
        else if (session is { CanReply: true } s)
        {
            // 上方给终端按钮的角标留地方：横着滚的一排会裁掉超出自己的部分，内容往下挪、整排再往上提回来
            var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Spacing0, Margin = new Thickness(0, 6, 6, 0) };
            foreach (var c in SessionChips.Make(key, s, chat, OnMode, OnModel, OnCompact, OnTodos, OnAgents)) chips.Children.Add(c);
            chipRow.Children.Add(new ScrollViewer { Content = chips, Margin = new Thickness(0, -6, 0, 0), HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled });
        }
    }

    /// 群：「发给全部成员 ⌄」，点开勾选只发给哪几个成员（同会话那排的小按钮）
    Control RecipientsChip(ComposeGroup target)
    {
        var info = GroupState.Shared.Group(target.Id);
        var picked = info?.Members.Where(m => target.Recipients.Contains(m.Key)).Select(m => m.Name).ToList() ?? [];
        var icon = Ui.Sym(picked.Count == 0 ? "person.2" : "person", 11, picked.Count == 0 ? "Text" : "Accent");
        icon.FontWeight = FontWeight.SemiBold;
        var label = Ui.Text(picked.Count == 0 ? L("发给全部成员") : L("只发给 %@", string.Join(L("、"), picked)), 11.5, color: picked.Count == 0 ? "Text" : "Accent");
        var content = Ui.H(4, icon, label.Shrink(), Ui.Sym("chevron.down", 9, picked.Count == 0 ? "Text" : "Accent"));
        if (picked.Count == 0) content.Opacity = 0.75;
        content.VerticalAlignment = VerticalAlignment.Center;
        var chip = new Tap(content, null, 14) { Height = 28, Padding = new Thickness(9, 0), HorizontalAlignment = HorizontalAlignment.Left, MaxWidth = 420 };
        chip.Keys("Field", "Fill12");
        chip.Menu(() =>
        {
            var members = GroupState.Shared.Group(target.Id)?.Members ?? [];
            void Changed() => UpdateChips();
            return [
                Ui.Item(L("全部成员"), () => { target.Recipients.Clear(); Changed(); }, check: target.Recipients.Count == 0 ? "checkmark" : null),
                Ui.Divider(),
                .. members.Select(m => (Control)Ui.Item(m.Name, () => { if (!target.Recipients.Remove(m.Key)) target.Recipients.Add(m.Key); Changed(); },
                                                         check: target.Recipients.Contains(m.Key) ? "checkmark" : null)),
            ];
        });
        chip.Click = () => chip.ContextMenu?.Open(chip);
        chip.Tip(L("选择发给哪些成员"));
        return chip;
    }

    /// 发一段字（常用语、发送键）：会话、群
    void SendText(string text, IReadOnlyList<ComposeAttachment> images)
    {
        if (group is null) { AppModel.Shared.Send(key, text, images); return; }
        var target = group;
        var to = target.Recipients.Count > 0 ? target.Recipients.ToList() : null;
        _ = SendToGroup(target, text, to, images);
    }

    async Task SendToGroup(ComposeGroup target, string text, List<string>? to, IReadOnlyList<ComposeAttachment> images)
    {
        // 没发出去：把字放回输入框（输入框这时还空着的话）
        if (!await GroupState.Shared.Send(target.Id, text, to, images) && text.Length > 0 && (input.Text ?? "").Length == 0) input.Text = text;
    }

    /// 常用语：点一下直接发，右键放进输入框；最后一个铅笔去编辑
    void UpdateQuick()
    {
        var show = chat.QuickRepliesShown && QuickAvailable && !HasContent && !(session?.IsWaiting ?? false);
        quickRow.IsVisible = show;
        if (!show) return;
        quickRow.Children.Clear();
        var wrap = new WrapPanel();
        foreach (var phrase in AppModel.Shared.QuickReplies)
        {
            var text = phrase;
            var chip = new Tap(Ui.Text(text, 13).Pad(12, 0), () => SendText(text, []), 15) { Height = 30, MaxWidth = 360, Margin = new Thickness(0, 0, Spacing0, Spacing0) };
            chip.Keys("Field", "Fill10");
            chip.Child!.VerticalAlignment = VerticalAlignment.Center;
            chip.Menu(() => [Ui.Item(L("放进输入框"), () => { input.Text = text; input.CaretIndex = text.Length; input.Focus(); })]);
            wrap.Children.Add(chip);
        }
        var edit = new Tap(Ui.Sym("pencil", 12, "Text3").Pad(12, 0), () => SettingsWindow.Open("phrases"), 15) { Height = 30, Margin = new Thickness(0, 0, Spacing0, Spacing0) };
        edit.Keys("Field", "Fill10");
        edit.Child!.VerticalAlignment = VerticalAlignment.Center;
        edit.Tip(L("编辑快捷短语"));
        wrap.Children.Add(edit);
        quickRow.Children.Add(wrap);
    }

    void UpdateAttachments()
    {
        attachRow.Children.Clear();
        attachRow.IsVisible = chat.Attachments.Count > 0;
        foreach (var item in chat.Attachments.ToList())
        {
            var cell = new Panel { Width = 96, Height = 96 };
            try
            {
                using var s = new MemoryStream(item.Preview);
                cell.Children.Add(new Image { Source = new Bitmap(s), Stretch = Stretch.UniformToFill, Width = 96, Height = 96 }.Clip(10)
                    .ZoomOnClick(() => chat.Attachments.Select(a => a.Data).ToList(), () => Math.Max(0, chat.Attachments.IndexOf(item))));
            }
            catch (Exception) { }
            var x = Ui.Sym("xmark", 10, "White");
            x.FontWeight = FontWeight.Bold;
            x.HorizontalAlignment = HorizontalAlignment.Center;
            var remove = new Tap(x, () => { chat.Attachments.Remove(item); UpdateAttachments(); UpdateButtons(); }, 11)
            {
                Width = 22, Height = 22, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                RenderTransform = new TranslateTransform(7, -7), Background = new SolidColorBrush(Color.FromArgb(184, 0, 0, 0)),
            };
            remove.Normal = "Transparent";
            cell.Children.Add(remove);
            attachRow.Children.Add(cell);
        }
    }

    void OnKey(object? sender, KeyEventArgs e)
    {
        // 回车发送、Shift+回车换行（输入法还在组字时回车先交给输入法上屏，不会走到这里）
        if (e.Key == Key.Enter && !e.KeyModifiers.HasFlag(KeyModifiers.Shift) && !e.KeyModifiers.HasFlag(KeyModifiers.Control))
        {
            e.Handled = true;
            Send();
        }
    }

    void OnDrop(object? sender, DragEventArgs e)
    {
        if (e.Data.GetFiles() is { } files)
        {
            var list = new List<byte[]>();
            foreach (var f in files.OfType<IStorageFile>().Take(6))
                if (f.TryGetLocalPath() is string path && IsImage(path)) list.Add(File.ReadAllBytes(path));
            Attach(list);
        }
    }

    static bool IsImage(string path) => new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic" }.Contains(Path.GetExtension(path).ToLowerInvariant());

    async void Pick()
    {
        if (!CanAttach) { AppModel.Shared.Flash(L("电脑端的 Kiteline 版本较旧，群里暂不能发图片，请更新")); return; }
        if (!Enabled || TopLevel.GetTopLevel(this)?.StorageProvider is not { } storage) return;
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = true, Title = L("发送图片"), FileTypeFilter = [FilePickerFileTypes.ImageAll] });
        Attach(files.Select(f => f.TryGetLocalPath()).Where(p => p is not null).Select(p => File.ReadAllBytes(p!)).ToList());
    }

    /// 压成 JPEG 加进要发的图，一次最多 6 张（同 Mac 版 MacComposer.attach）
    public void Attach(IReadOnlyList<byte[]> list)
    {
        if (!CanAttach && list.Count > 0) { AppModel.Shared.Flash(L("电脑端的 Kiteline 版本较旧，群里暂不能发图片，请更新")); return; }
        foreach (var data in list.Take(Math.Max(0, 6 - chat.Attachments.Count)))
            if (ImagePrep.Prepare(data) is { } prepared)
                chat.Attachments.Add(new ComposeAttachment(Guid.NewGuid().ToString(), $"image-{chat.Attachments.Count + 1}.jpg", prepared.Jpeg, prepared.Preview));
        UpdateAttachments();
        UpdateButtons();
        input.Focus();
    }

    /// 空着输入框按回车发排队的第一条：等电脑回应前不重复发
    bool jumping;

    async Task Jump(string qid)
    {
        jumping = true;
        try { await AppModel.Shared.QueueAction(key, qid, "now"); }
        finally { jumping = false; }
    }

    void Send()
    {
        var text = (input.Text ?? "").Trim();
        if (!Enabled) return;
        if (text.Length == 0 && chat.Attachments.Count == 0)
        {
            // 空着输入框按回车：有排队的消息就把最前面一条马上发出去（强插），再按再发下一条；没有排队的什么也不做（同 iOS）
            if (group is null && !jumping && chat.QueueRows(session).FirstOrDefault() is { } first) _ = Jump(first.Id);
            return;
        }
        if (chat.Quote is string quote) { text = string.Join("\n", quote.Split('\n').Select(l => "> " + l)) + "\n\n" + text; chat.Quote = null; }
        SendText(text, chat.Attachments.ToList());
        input.Text = "";
        AppModel.Shared.SetDraft(key, "");
        chat.Attachments.Clear();
        UpdateAttachments();
        UpdateButtons();
    }
}

/// 输入栏发到群里（同 iOS / Mac 版 ComposeGroup）：发给哪几个成员（空 = 全部）；草稿、附图记在 @group:<群 id> 上
public sealed class ComposeGroup(string id)
{
    public string Id { get; } = id;
    public HashSet<string> Recipients { get; } = [];
    public string Key => MainModel.GroupPrefix + Id;
}

/// 细线圆圈里一个方块（停止）或加号（同 Mac 版 CircleGlyph）：圈 30，占位 34×38
public sealed class CircleGlyph : Tap
{
    public CircleGlyph(bool stop, Action action, string color) : base(new Art(stop, color), action, 0)
    {
        Width = 34;
        Height = 38;
        Keys("Transparent", "Transparent");
    }

    sealed class Art(bool stop, string color) : Control
    {
        public override void Render(DrawingContext context)
        {
            var brush = Palette.Get(color);
            var c = new Point(Bounds.Width / 2, Bounds.Height / 2);
            context.DrawEllipse(null, new Pen(brush, 1.6), c, 14.2, 14.2);
            if (stop) context.DrawRectangle(brush, null, new Rect(c.X - 5, c.Y - 5, 10, 10), 2, 2);
            else
            {
                var pen = new Pen(brush, 1.8, lineCap: PenLineCap.Round);
                context.DrawLine(pen, new Point(c.X, c.Y - 6), new Point(c.X, c.Y + 6));
                context.DrawLine(pen, new Point(c.X - 6, c.Y), new Point(c.X + 6, c.Y));
            }
        }
    }
}

/// 输入框下面那排小按钮（同 Mac 版 SessionChips）：权限模式、模型和思考等级、上下文、任务清单进度、派过的子 agent
public static class SessionChips
{
    public static IEnumerable<Control> Make(string key, SessionInfo s, ChatStore chat, Action? onMode, Action? onModel, Action? onCompact, Action? onTodos, Action? onAgents)
    {
        // 权限模式、换模型、压缩、子 agent：后台说这个 agent 有才给（caps）
        if (s.Can("mode"))
        {
            var mode = PermissionMode.Current(key);
            yield return Chip(mode?.Symbol ?? "exclamationmark.shield", mode?.Name ?? L("跳过确认"), onMode);
        }
        if (s.Can("model"))
        {
            var (name, effort) = ModelLabel.Parts(key);
            var label = Ui.H(4, Ui.Text(name, 11.5, color: "Text").Opacity(0.75), effort is null ? null : Ui.Text(effort, 11.5, color: "Text2"));
            yield return Pill(label, onModel);
        }
        if (!s.Can("mode") && !s.Can("model"))
        {
            yield return Pill(Ui.H(5, new AgentGlyph(s.Agent, 12, "Text"), Ui.Text(s.Usage?.Model ?? Agents.Info(s.Agent).Name, 11.5, color: "Text").Opacity(0.75)), null);
        }
        if (s.Usage?.Percent is int percent)
            yield return Pill(Ui.H(4, new ContextRing(percent), Ui.Text($"{percent}%", 11.5, color: "Text2").Digits()), s.Can("compact") ? onCompact : null);
        // 目标（/goal）：没设时点开写一个，设了的显示进行中 / 暂停（会话支持才有）
        if (s.Can("goal") && s.CanReply)
        {
            var goal = s.Goal is { Running: true } g ? g : null;
            var (fg, fill, _) = goal is null ? ("Text", "Field", "") : GoalText.Tint(goal.State);
            var icon = Ui.Sym(GoalText.Symbol(goal?.State ?? "active"), 11, fg);
            icon.FontWeight = FontWeight.SemiBold;
            var label = Ui.H(4, icon, Ui.Text(goal is null ? L("目标") : GoalText.Label(goal.State), 11.5, color: fg));
            var chip = (Tap)Pill(goal is null ? label.Opacity(0.75) : label, () => GoalSheet.Open(key));
            if (goal is not null) chip.Keys(fill, fill);
            yield return chip.Tip(L("设定目标：%@ 围绕目标持续工作，确认达成才停", s.Speaker));
        }
        var todos = chat.Todos;
        var done = todos.Count(t => t.Str("status") == "completed");
        if (todos.Count > 0 && done < todos.Count) yield return Chip("checklist", L("任务 %@/%@", done, todos.Count), onTodos);
        if (s.Subagents > 0 && s.Can("subagents")) yield return Chip("point.3.connected.trianglepath.dotted", L("子 agent %@", s.Subagents), onAgents);
        // 会话里的终端（开在会话所在的电脑上）：点开从底下升起终端面板，角标是开着几个
        if (s.Can("term")) yield return new Terminal.TerminalChip(s, chat);
    }

    static Control Chip(string symbol, string text, Action? action)
    {
        var icon = Ui.Sym(symbol, 11, "Text");
        icon.FontWeight = FontWeight.SemiBold;
        return Pill(Ui.H(4, icon, Ui.Text(text, 11.5, color: "Text")).Opacity(0.75), action);
    }

    static Control Pill(Control content, Action? action)
    {
        var tap = new Tap(content, action, 14) { Height = 28, Padding = new Thickness(9, 0) };
        tap.Keys("Field", action is null ? "Field" : "Fill12");
        content.VerticalAlignment = VerticalAlignment.Center;
        if (action is null) tap.Cursor = Cursor.Default;
        return tap;
    }
}

/// 上下文占用的小圆环：90% 以上红、70% 以上橙，其余绿（同 Mac 版 ContextRing）
public sealed class ContextRing : Control
{
    readonly int percent;
    public ContextRing(int percent) { this.percent = percent; Width = 13; Height = 13; VerticalAlignment = VerticalAlignment.Center; }

    public override void Render(DrawingContext context)
    {
        var rect = new Rect(1.25, 1.25, 10.5, 10.5);
        context.DrawEllipse(null, new Pen(Palette.Get("Fill12"), 2.5), rect);
        var ratio = Math.Min(percent, 100) / 100.0;
        if (ratio <= 0) return;
        var color = percent >= 90 ? Palette.Get("Removed") : percent >= 70 ? Palette.Get("Orange") : Palette.Get("Added");
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            var c = rect.Center; var r = rect.Width / 2;
            var start = -Math.PI / 2; var end = start + Math.PI * 2 * Math.Min(ratio, 0.999);
            ctx.BeginFigure(new Point(c.X + r * Math.Cos(start), c.Y + r * Math.Sin(start)), false);
            ctx.ArcTo(new Point(c.X + r * Math.Cos(end), c.Y + r * Math.Sin(end)), new Size(r, r), 0, ratio > 0.5, SweepDirection.Clockwise);
            ctx.EndFigure(false);
        }
        context.DrawGeometry(null, new Pen(color, 2.5, lineCap: PenLineCap.Round), g);
    }
}

/// 权限模式（同 iOS / Mac 版 PermissionMode）
public sealed record PermissionMode(string Id, string Title, string Detail, string Symbol)
{
    public static readonly PermissionMode Manual = new("default", "手动", "每次修改文件前均需确认", "hand.raised");
    public static readonly PermissionMode AcceptEdits = new("acceptEdits", "自动接受编辑", "修改文件无需确认，其他操作照常确认", "chevron.left.forwardslash.chevron.right");
    public static readonly PermissionMode Plan = new("plan", "计划", "先分析代码并制定计划，经你批准后再执行", "list.bullet.clipboard");
    public static readonly PermissionMode Auto = new("auto", "自动", "通过安全检查的操作自动放行，存在风险的操作需要确认", "bolt");
    /// ⇧Tab 的顺序（和 VS Code 里模式菜单的顺序一样）
    public static readonly PermissionMode[] Cycle = [Manual, AcceptEdits, Plan, Auto];

    public string Name => L(Title);

    /// 对话记录里的值；没记过当作手动；跳过所有确认的模式不在 ⇧Tab 里，返回 null
    public static PermissionMode? From(string? raw) => raw is null ? Manual : Cycle.FirstOrDefault(m => m.Id == raw);

    /// 会话现在是哪个模式：刚切过、Claude Code 还没在记录里写下新模式时，先按切过去的算
    public static PermissionMode? Current(string key)
    {
        var server = AppModel.Shared.Session(key)?.PermissionMode;
        var chat = AppModel.Shared.Chat(key);
        if (chat.ModeOverride is { } o && o.Baseline == server) return From(o.Mode);
        return From(server);
    }
}

/// 模型和思考等级的标签（同 Mac 版 ModelLabel）：「Opus 5.5  高」
public static class ModelLabel
{
    public static (string Name, string? Effort) Parts(string key)
    {
        var model = AppModel.Shared;
        var session = model.Session(key);
        var chat = model.Chat(key);
        var used = session?.Usage?.Model;
        var current = chat.ModelOverride is { } m && m.Baseline == used ? m.Model : used;
        var effortRaw = chat.EffortOverride is { } e && e.Baseline == session?.Effort ? e.Effort : session?.Effort;
        var ultra = chat.UltracodeOverride is { } u && u.Baseline == (session?.Ultracode ?? false) ? u.On : session?.Ultracode ?? false;
        var name = Tools.ModelName(current);
        var effort = Effort.Name(effortRaw ?? "auto") + (ultra ? " · Ultracode" : "");
        return (name.Length == 0 ? L("模型") : name, effort);
    }
}
