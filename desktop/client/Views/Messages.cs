using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 一行消息（同 Mac 版 MessageRow）：头像 + 气泡 + 下面一行小字时间。同一个人连着说的几条，只有第一条显示头像，气泡的小尖角也只在那条上。
/// 头像 30，两边留 24，头像和气泡隔 12；我的气泡左边至少空 min(200, 23% 宽)；每条上下各 10，换人说话时上面 20
public sealed class MessageRow : Grid
{
    const double AvatarSize = 30, Gap = 12, Edge = 24, MeRoom = 200, MeRatio = 0.23, RowGap = 10, TurnGap = 20;

    public MessageRow(bool me, bool first, double? time, Control content, string agent, double chatWidth, (string Text, string Id)? speak = null, string? key = null)
    {
        Margin = new Thickness(Edge, ChatType.Px(first ? TurnGap : RowGap), Edge, ChatType.Px(RowGap));
        // 助手的头像：按 Agent 详情里设的画，点了打开 Agent 详情
        var avatar = first ? (me ? MyAvatar.Make(AvatarSize) : key is not null ? new ChatAgentAvatar(key, agent, AvatarSize) : AgentAvatar.Make(agent, AvatarSize))
            : new Border { Width = AvatarSize, Height = 1 };
        avatar.VerticalAlignment = VerticalAlignment.Top;
        var column = new StackPanel { Spacing = 6, HorizontalAlignment = me ? HorizontalAlignment.Right : HorizontalAlignment.Left };
        column.Children.Add(content);
        if (time is double t)
        {
            var footer = Ui.H(6, Ui.Text(Format.Clock(t), 11, color: "Text3"),
                speak is { } s ? new Tap(Ui.Sym("speaker.wave.2", 11, "Text3"), () => Speaker.Toggle(s.Text, s.Id), 4).Tip(L("朗读这条")) : null);
            footer.Margin = new Thickness(4, 0);
            footer.HorizontalAlignment = me ? HorizontalAlignment.Right : HorizontalAlignment.Left;
            column.Children.Add(footer);
        }
        if (me)
        {
            ColumnDefinitions = new ColumnDefinitions($"*,{Gap},{AvatarSize}");
            column.Margin = new Thickness(chatWidth > 0 ? Math.Min(MeRoom, chatWidth * MeRatio) : MeRoom, 0, 0, 0);
            SetColumn(column, 0);
            SetColumn(avatar, 2);
        }
        else
        {
            ColumnDefinitions = new ColumnDefinitions($"{AvatarSize},{Gap},*");
            SetColumn(avatar, 0);
            SetColumn(column, 2);
        }
        Children.Add(avatar);
        Children.Add(column);
    }
}

/// 对话里助手的头像：Claude Code 是强调色方块里它的白色标志，别的 agent 是石墨底上它的白色标志（同 Mac 版 AgentAvatar）
public static class AgentAvatar
{
    public static Control Make(string agent, double size)
    {
        if (agent == Agents.DefaultId)
            return new Border
            {
                Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.27),
                Child = new AgentGlyph(agent, size * 0.6, "White") { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            }.Res(Border.BackgroundProperty, "Accent");
        return new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.27), Background = Palette.Brush(0x383838),
            Child = new AgentGlyph(agent, size * 0.56, "White") { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
    }
}

/// 我的头像：电脑账户头像（或在设置里换的），没有图就显示名字首字（同 Mac 版 MyAvatar）
public static class MyAvatar
{
    public static Control Make(double size)
    {
        var me = AppModel.Shared.Me;
        var name = me?.Name ?? L("我");
        var tile = new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.27), ClipToBounds = true,
            Child = new TextBlock { Text = Format.Initials(name), FontSize = size * 0.4, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
                .Res(TextBlock.ForegroundProperty, "Accent"),
        }.Res(Border.BackgroundProperty, "IconTile");
        if (me?.Avatar is { Length: > 0 } path && Uri.TryCreate("http://x" + path, UriKind.Absolute, out var uri))
        {
            var query = uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
                .Select(p => p.Split('=', 2)).DistinctBy(p => Uri.UnescapeDataString(p[0])).ToDictionary(p => Uri.UnescapeDataString(p[0]), p => p.Length > 1 ? Uri.UnescapeDataString(p[1]) : "");
            ImageCache.Load(uri.AbsolutePath, query, bitmap => tile.Child = new Image { Source = bitmap, Stretch = Stretch.UniformToFill, Width = size, Height = size });
        }
        return tile;
    }
}

/// 气泡（同 Mac 版 Bubble）：圆角块，带头像的那条边上一个小尖角对着第一行字；右键菜单（复制、引用、朗读……）
public sealed class Bubble : Panel
{
    readonly bool mine;
    readonly bool tail;
    readonly Border box;

    /// later：菜单打开时才算的一项（收藏 / 取消收藏：收藏过没有会变）
    public Bubble(bool mine, bool tail, Control content, string? copyText = null, IEnumerable<(string Title, Action Run)>? actions = null,
                  Func<(string Title, Action Run)?>? later = null)
    {
        this.mine = mine;
        this.tail = tail;
        box = new Border { Child = content, Padding = new Thickness(ChatType.PadH, ChatType.PadV), CornerRadius = new CornerRadius(ChatType.Radius) };
        box.Res(Border.BackgroundProperty, mine ? "Bubble" : "BotBubble");
        Children.Add(box);
        HorizontalAlignment = mine ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        ClipToBounds = false;
        var menu = new List<(string, Action)>();
        if (!string.IsNullOrWhiteSpace(copyText)) menu.Add((L("拷贝"), () => SessionMenu.Copy(copyText)));
        if (actions is not null) menu.AddRange(actions);
        if (menu.Count > 0 || later is not null)
            this.Menu(() => menu.Concat(later?.Invoke() is { } extra ? [extra] : []).Select(m => (Control)Ui.Item(m.Item1, m.Item2)));
    }

    /// 气泡上的字的颜色：我的气泡跟着主题（经典主题是深色字）
    public static string TextColor(bool mine) => mine ? "BubbleText" : "Text";

    protected override Size ArrangeOverride(Size finalSize)
    {
        var size = base.ArrangeOverride(finalSize);
        tailShape?.Arrange(new Rect(mine ? finalSize.Width - 1 : -5, 0, 6, finalSize.Height));
        return size;
    }

    Tail? tailShape;

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (tail && tailShape is null) { tailShape = new Tail(mine); Children.Add(tailShape); }
    }

    /// 尖角（6×12）对着第一行字的中间：上内边距 + 半行 − 尖角一半
    sealed class Tail(bool mine) : Control
    {
        public override void Render(DrawingContext context)
        {
            var y = ChatType.PadV + ChatType.Size * 0.75 - 6;
            var brush = Palette.Get(mine ? "Bubble" : "BotBubble");
            var g = new StreamGeometry();
            using (var ctx = g.Open())
            {
                if (mine)
                {
                    ctx.BeginFigure(new Point(0, y), true);
                    ctx.LineTo(new Point(6, y + 6));
                    ctx.LineTo(new Point(0, y + 12));
                }
                else
                {
                    ctx.BeginFigure(new Point(6, y), true);
                    ctx.LineTo(new Point(0, y + 6));
                    ctx.LineTo(new Point(6, y + 12));
                }
                ctx.EndFigure(true);
            }
            context.DrawGeometry(brush, null, g);
        }
    }
}

/// 我说的（同 Mac 版 UserMessage）：语音发的画成语音条 + 下面转写的文字；工作时插进去的标一句
public static class UserMessage
{
    public static Control Make(string key, ChatItem item, bool first)
    {
        var model = AppModel.Shared;
        var text = item.Text ?? "";
        var chat = model.Chat(key);
        var stack = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
        if (text.Length > 0 && chat.Voices.TryGetValue(text.Trim(), out var clip))
        {
            if (item.Images is { Count: > 0 } imgs) stack.Children.Add(new Bubble(true, first, new MessageImages(key, imgs), later: () => FavoriteState.Shared.MenuAction(key, item, true)));
            stack.Children.Add(VoiceBubble.Make(clip.Id, clip.Duration, true, first && (item.Images?.Count ?? 0) == 0));
            stack.Children.Add(Transcript(text));
        }
        else
        {
            // 手机发过来的文件（PDF、Excel……）是消息末尾的「[附件] 路径」行：拆出来画成文件卡片，点了打开
            var (shown, files) = FileLinks.SplitAttached(text);
            var content = new StackPanel { Spacing = 6 };
            if (item.Images is { Count: > 0 } images) content.Children.Add(new MessageImages(key, images));
            if (files.Count > 0) content.Children.Add(FileOpen.Chips(key, files));
            if (shown.Length > 0) content.Children.Add(new RichText(shown, ChatType.Size, color: Bubble.TextColor(true)));
            stack.Children.Add(new Bubble(true, first, content, shown, text.Length == 0 ? null :
            [
                (L("引用"), () => chat.Quote = Quote.Make(text)),
                (L("重新发送"), () => model.Send(key, text, [])),
                // 把这句要求做成提示词链接（发给同事、贴进 PR 评论）：对方用 Kiteline 打开就是填好的「新任务」，项目按这个会话的目录名对
                (L("复制为提示词链接"), () => SessionMenu.Copy(PromptLinks.Make(shown.Trim(),
                    (model.Session(key)?.Cwd ?? (model.PastMeta.TryGetValue(key, out var past) ? past.Cwd : null)) is string cwd
                        ? System.IO.Path.GetFileName(cwd.TrimEnd('/', '\\')) : null))),
            ], () => FavoriteState.Shared.MenuAction(key, item, true)));
        }
        if (item.Queued == true) stack.Children.Add(Ui.Text(L("Claude 工作时插入"), 11, color: "Text2").HAlign(HorizontalAlignment.Right));
        return stack;
    }

    /// 语音转出来的文字：语音条下面的浅色块（同微信「转文字」）
    public static Control Transcript(string text) =>
        Ui.Box(new RichText(text.Length == 0 ? L("转写中…") : text, ChatType.Size, color: text.Length == 0 ? "Text2" : "Text"),
               new Thickness(ChatType.PadH, ChatType.PadV), "BotBubble", ChatType.Radius).HAlign(HorizontalAlignment.Right);
}

/// Claude 的文字回复（同 Mac 版 BotText）：Markdown；认出有要你做的事，下面问一句「加入待办？」
public static class BotText
{
    public static Control Make(string key, ChatItem item, bool first, Action<string> openLink)
    {
        var model = AppModel.Shared;
        var text = item.Text ?? "";
        var bubble = new Bubble(false, first, new MarkdownView(text, fill: false, openLink), Markdown.Plain(text),
        [
            (L("引用"), () => model.Chat(key).Quote = Quote.Make(text)),
            (L("加入待办"), () => TodoActions.Add(key, item)),
            (L("朗读"), () => Speaker.Toggle(text, item.Id)),
        ], () => FavoriteState.Shared.MenuAction(key, item, false));
        if (item.Asks is not { Count: > 0 } asks) return bubble;
        return new StackPanel { Spacing = 8, Children = { bubble, AskPrompt.Make(key, item, asks) } };
    }
}

/// Claude 发来的图（同 Mac 版 AgentImageMessage）
public static class AgentImageMessage
{
    public static Control Make(string key, ChatItem item, bool first, Action<string> openLink)
    {
        var stack = new StackPanel { Spacing = 8, MaxWidth = 360 };
        stack.Children.Add(Ui.H(5, Ui.Sym("photo", 12, "Text2"), Ui.Text(L("%@ 发来图片", AppModel.Shared.Session(key)?.Speaker ?? "Claude"), 11.5, color: "Text2")));
        if (item.Images is { Count: > 0 } images) stack.Children.Add(new MessageImages(key, images));
        if (item.Text is { Length: > 0 } text) stack.Children.Add(new MarkdownView(text, true, openLink));
        return new Bubble(false, first, stack, item.Text, later: () => FavoriteState.Shared.MenuAction(key, item, false));
    }
}

/// agent 发来的网页（agent_page，watcher 的 send-page，同 Mac 版 AgentPageMessage）：一张卡片，点了取回来用默认浏览器打开，下面是一句说明
public static class AgentPageMessage
{
    public static Control Make(string key, ChatItem item, bool first, Action<string> openLink)
    {
        var stack = new StackPanel { Spacing = 8, MaxWidth = 360 };
        stack.Children.Add(Ui.H(5, Ui.Sym("doc.text", 12, "Text2"), Ui.Text(L("%@ 发来网页", AppModel.Shared.Session(key)?.Speaker ?? "Claude"), 11.5, color: "Text2")));
        var glyph = Ui.Sym("chart.bar", 18, "Accent");
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        var icon = Ui.Box(glyph, new Avalonia.Thickness(0), "Fill10", 7);
        icon.Width = 34;
        icon.Height = 38;
        var hint = Ui.Text(L("在浏览器中打开"), 11);
        hint.Opacity = 0.7;
        var texts = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Ui.Text(item.Title ?? L("网页"), 13, FontWeight.SemiBold, lines: 2).Wrap());
        texts.Children.Add(hint);
        var row = new DockPanel { LastChildFill = true };
        var chevron = Ui.Sym("chevron.right", 11, "Text3");
        chevron.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(icon, Dock.Left);
        DockPanel.SetDock(chevron, Dock.Right);
        icon.Margin = new Avalonia.Thickness(0, 0, 10, 0);
        row.Children.Add(icon);
        row.Children.Add(chevron);
        row.Children.Add(texts);
        stack.Children.Add(new Tap(row.Pad(8, 8), () => FileOpen.OpenPage(key, item), 10).Keys("Fill05", "Fill10"));
        if (item.Caption is { Length: > 0 } caption) stack.Children.Add(new MarkdownView(caption, true, openLink));
        return new Bubble(false, first, stack, item.Text, later: () => FavoriteState.Shared.MenuAction(key, item, false));
    }
}

/// agent 经待办技能记的一条待办（agent_todo，同 Mac 版 AgentTodoMessage）。只有你能做的（forUser）：「现在处理 / 加入待办」，
/// 选了现在处理的，处理好后点「已处理好」回到输入框告诉 agent；agent 自己的：显示它现在的状态、进度，点了打开待办页
public static class AgentTodoMessage
{
    public static Control Make(string key, ChatItem item, bool first)
    {
        var host = new ContentControl();
        var state = TodoState.Shared;
        void Draw() => host.Content = Content(key, item, first);
        void Changed(object? s, System.ComponentModel.PropertyChangedEventArgs e) => Draw();
        host.AttachedToVisualTree += (_, _) => { state.PropertyChanged += Changed; Draw(); };
        host.DetachedFromVisualTree += (_, _) => state.PropertyChanged -= Changed;
        Draw();
        return host;
    }

    static Control Content(string key, ChatItem item, bool first)
    {
        var state = TodoState.Shared;
        var mine = state.Items.FirstOrDefault(i => i.Source?.Key == key && i.Source?.ItemId == item.Id);
        var speaker = AppModel.Shared.Session(key)?.Speaker ?? "Claude";
        var forUser = item.ForUser == true;
        var stack = new StackPanel { Spacing = 6, MaxWidth = 360 };
        stack.Children.Add(Ui.H(5, Ui.Sym(forUser ? "hand.raised" : "checklist", 12, "Text2"),
            Ui.Text(forUser ? L("需要你来做") : L("%@ 的待办", speaker), 11.5, color: "Text2")));
        stack.Children.Add(Ui.Text(item.Text ?? "", 14, FontWeight.SemiBold, lines: 0).Wrap());
        if (item.Detail is { Length: > 0 } detail) stack.Children.Add(Ui.Text(detail, 12.5, color: "Text2", lines: 0).Wrap());
        Control? action = null;
        void ToTodos() => MainModel.Shared.Selection = MainModel.TodosId;
        if (forUser)
        {
            if (mine is not null)
                action = new Tap(Ui.H(5, Ui.Sym("checkmark.circle.fill", 12, "Text2"), Ui.Text(L("已加入待办"), 12, color: "Text2")), ToTodos, 4)
                    .Keys("Transparent", "Transparent");
            else if (state.IsHandled(key, item.Id))
                // 选了「现在处理」：处理好后在这里告诉 agent
                action = Ui.H(10, Ui.Text(L("处理好后告诉 %@", speaker), 12, color: "Text2"),
                    new Tap(Ui.Text(L("已处理好"), 12, FontWeight.SemiBold, "Accent").Pad(4, 2), () => TodoState.ReplyDone(key, item.Text ?? ""), 4)
                        .Keys("Transparent", "Fill05"));
            else
                action = Ui.H(10,
                    new Tap(Ui.Text(L("现在处理"), 12, FontWeight.SemiBold, "Accent").Pad(12, 0), () => state.Dismiss(key, item.Id), 14) { Height = 28 }
                        .Keys("AccentFill14", "AccentFill20"),
                    new Tap(Ui.Text(L("加入待办"), 12, FontWeight.SemiBold, "Text2").Pad(12, 0), () =>
                    {
                        if (state.Suggestions.FirstOrDefault(x => x.Key == key && x.ItemId == item.Id) is { } pending) _ = state.AddSuggestion(pending);
                        else _ = state.Add([item.Text ?? ""], key, item.Id, ts: item.Ts, detail: item.Detail, forUser: true, agent: true);
                    }, 14) { Height = 28 }.Keys("Fill06", "Fill10"));
        }
        else if (mine is not null)
        {
            var doing = mine.Status == "doing" && !mine.Done;
            var label = mine.Done ? L("已完成") : doing ? L("进行中") : L("待处理");
            var progress = string.IsNullOrEmpty(mine.Progress) ? null : Ui.Text("· " + mine.Progress, 12, color: doing ? "Accent" : "Text2", lines: 2).Wrap().Shrink();
            action = new Tap(Ui.HTop(5, Ui.Sym(mine.Done ? "checkmark.circle.fill" : doing ? "arrow.triangle.2.circlepath" : "circle.dashed", 12, doing ? "Accent" : "Text2"),
                Ui.Text(label, 12, color: doing ? "Accent" : "Text2"), progress), ToTodos, 4).Keys("Transparent", "Transparent");
        }
        if (action is not null)
        {
            action.HorizontalAlignment = HorizontalAlignment.Left;
            stack.Children.Add(action);
        }
        return new Bubble(false, first, stack, item.Text);
    }
}

/// agent 发来的关键信息（agent_key：账号密码、密钥、地址，同 Mac 版 AgentKeyMessage）：一项一行、能单独复制；密码这类默认遮住，
/// 点眼睛才显示；下面一键收藏
public static class AgentKeyMessage
{
    public static Control Make(string key, ChatItem item, bool first)
    {
        var host = new ContentControl();
        var favorites = FavoriteState.Shared;
        var shown = new HashSet<int>();
        void Draw() => host.Content = Content(key, item, first, shown, Draw);
        void Changed(object? s, System.ComponentModel.PropertyChangedEventArgs e) => Draw();
        host.AttachedToVisualTree += (_, _) => { favorites.PropertyChanged += Changed; Draw(); };
        host.DetachedFromVisualTree += (_, _) => favorites.PropertyChanged -= Changed;
        Draw();
        return host;
    }

    static Control Content(string key, ChatItem item, bool first, HashSet<int> shown, Action redraw)
    {
        var favorites = FavoriteState.Shared;
        var saved = favorites.Contains(key, item.Id);
        var stack = new StackPanel { Spacing = 8, MaxWidth = 360 };
        stack.Children.Add(Ui.H(5, Ui.Sym("key.fill", 12, "Text2"), Ui.Text(L("关键信息"), 11.5, color: "Text2")));
        stack.Children.Add(Ui.Text(item.Title ?? "", 14, FontWeight.SemiBold, lines: 0).Wrap());
        var fields = item.Fields ?? [];
        for (var i = 0; i < fields.Count; i++)
        {
            var index = i;
            var field = fields[i];
            var value = field.Value ?? "";
            var hidden = field.Secret && !shown.Contains(index);
            var texts = new StackPanel { Spacing = 1 };
            if (field.Name is { Length: > 0 } name) texts.Children.Add(Ui.Text(name, 11.5, color: "Text2"));
            var shownValue = new SelectableTextBlock
            {
                Text = hidden ? new string('•', Math.Clamp(value.Length, 6, 12)) : value, FontFamily = Look.Mono, FontSize = Look.Pt(12.5),
                TextWrapping = TextWrapping.Wrap,
            };
            shownValue.Res(TextBlock.ForegroundProperty, "Text");
            texts.Children.Add(shownValue);
            var buttons = new List<Control?>();
            if (field.Secret)
                buttons.Add(new Tap(Ui.Sym(hidden ? "eye" : "eye.slash", 13, "Text2"), () => { if (!shown.Remove(index)) shown.Add(index); redraw(); }, 6)
                    { Width = 28, Height = 28 }.Keys("Transparent", "Fill05").Tip(hidden ? L("显示") : L("隐藏")));
            buttons.Add(new Tap(Ui.Sym("doc.on.doc", 12.5, "Text2"), () => { _ = MainWindow.Current?.Clipboard?.SetTextAsync(value); AppModel.Shared.Flash(L("已复制")); }, 6)
                { Width = 28, Height = 28 }.Keys("Transparent", "Fill05").Tip(L("复制")));
            var row = Ui.H(8, [texts.Grow(), .. buttons]).Pad(10, 7);
            stack.Children.Add(new Border { Child = row, CornerRadius = new CornerRadius(8) }.Res(Border.BackgroundProperty, "Fill05"));
        }
        if (item.Note is { Length: > 0 } note) stack.Children.Add(Ui.Text(note, 12.5, color: "Text2", lines: 0).Wrap());
        var star = new Tap(Ui.H(6, Ui.Sym(saved ? "star.fill" : "star", 12, saved ? "Accent" : "Text"), Ui.Text(saved ? L("已收藏") : L("收藏"), 12.5, FontWeight.Medium)).Pad(12, 5),
            () => { if (saved) favorites.Remove(key, item.Id); else favorites.Add(key, item, false); }, 14).Keys("Fill06", "Fill10");
        star.HorizontalAlignment = HorizontalAlignment.Left;
        stack.Children.Add(star);
        return new Bubble(false, first, stack, item.Text, later: () => favorites.MenuAction(key, item, false));
    }
}

/// 对话里的图（同 Mac 版 MessageImages）：100 的方形缩略图（三张、五张以上一排三个 80 的），点开看大图。
/// gallery：点开后左右滑着看的一组（比如一张步骤卡片里所有工具结果的图），从点的那张开始；不给就只看这条自己的
public sealed class MessageImages : WrapPanel
{
    /// path：图从哪个接口取（对话里的图 /api/media，群里的图 /api/groups/media，key 是 @group:<群 id>）
    public MessageImages(string key, IReadOnlyList<ChatImage> images, IReadOnlyList<ChatImage>? gallery = null, string path = "/api/media")
    {
        var columns = images.Count == 1 ? 1 : images.Count is 2 or 4 ? 2 : 3;
        var side = columns == 3 ? 80.0 : 100.0;
        // 每格连右边、下边 4 的间隔一共占 side + 4（ItemWidth）：上限按这个算，不然一排放不下 columns 个（两张图会上下摞着）
        MaxWidth = columns * (side + 4) + 0.5;
        ItemWidth = side + 4;
        ItemHeight = side + 4;
        for (var i = 0; i < images.Count; i++)
        {
            var index = i;
            var cell = new Border { Width = side, Height = side, CornerRadius = new CornerRadius(6), ClipToBounds = true, Margin = new Thickness(0, 0, 4, 4) };
            cell.Res(Border.BackgroundProperty, "Fill06");
            var failed = false;
            void Fill()
            {
                failed = false;
                cell.Child = null;
                // 自己再取几次都没取到：整格是「轻点重试」（同 Mac 版）
                ImageCache.Load(path, new Dictionary<string, string> { ["key"] = key, ["ref"] = images[index].Ref, ["thumb"] = "200" },
                    bitmap => cell.Child = new Image { Source = bitmap, Stretch = Stretch.UniformToFill, Width = side, Height = side },
                    () =>
                    {
                        failed = true;
                        cell.Child = Ui.Stack(Orientation.Vertical, 4, Align.Center, [Ui.Sym("arrow.clockwise", 13, "Text2"), Ui.Text(L("轻点重试"), 11, color: "Text2")])
                            .HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center);
                    });
            }
            Fill();
            cell.OnTap(() =>
            {
                if (failed) { Fill(); return; }
                var all = gallery ?? images;
                var at = gallery is null ? index : Math.Max(0, gallery.ToList().FindIndex(g => g.Ref == images[index].Ref));
                ImageViewer.Show(key, all, at, path);
            });
            Children.Add(cell);
        }
    }
}

/// 从后台取图（缩略图、原图、头像），解码后缓存
public static class ImageCache
{
    static readonly Dictionary<string, Task<Bitmap?>> Tasks = new();

    public static Task<Bitmap?> Get(string path, IDictionary<string, string> query)
    {
        var key = path + "?" + string.Join("&", query.OrderBy(kv => kv.Key).Select(kv => kv.Key + "=" + kv.Value));
        if (Tasks.TryGetValue(key, out var task) && !(task.IsCompleted && task.Result is null)) return task;
        task = Fetch(path, query);
        Tasks[key] = task;
        if (Tasks.Count > 600) foreach (var old in Tasks.Keys.Take(200).ToList()) Tasks.Remove(old);
        return task;
    }

    static async Task<Bitmap?> Fetch(string path, IDictionary<string, string> query)
    {
        try
        {
            var data = await AppModel.Shared.Api.MediaData(path, query);
            using var stream = new MemoryStream(data);
            return new Bitmap(stream);
        }
        catch (Exception) { return null; }
    }

    /// 没取到（图推来时正好断线、电脑那边正忙、图还在转）就隔一会儿自己再取几次（同 Mac 版 RemoteImage），都不行回 failed。
    /// 以前只取一次，失败了那一格就一直是灰块（2026-11-03 反馈测试报告的图「有时候会丢」）
    public static async void Load(string path, IDictionary<string, string> query, Action<Bitmap> done, Action? failed = null)
    {
        foreach (var delay in new[] { 5, 10, 20, 40, 60, 0 })
        {
            if (await Get(path, query) is Bitmap bitmap) { done(bitmap); return; }
            if (delay == 0) break;
            await Task.Delay(TimeSpan.FromSeconds(delay));
        }
        failed?.Invoke();
    }
}

/// 语音条（同微信）：时长越长越宽，点一下播放 / 停止
public static class VoiceBubble
{
    public static Control Make(string? id, double duration, bool mine, bool tail)
    {
        var seconds = Math.Max(1, (int)Math.Round(duration));
        var row = Ui.H(6, mine ? new Spacer() : null, mine ? null : Ui.Sym("waveform", 13, Bubble.TextColor(mine)),
            Ui.Text($"{seconds}″", ChatType.Size, color: Bubble.TextColor(mine)), mine ? Ui.Sym("waveform", 13, Bubble.TextColor(mine)) : null, mine ? null : new Spacer());
        row.Width = 44 + Math.Min(seconds, 60) * 2.6;
        var bubble = new Bubble(mine, tail, row);
        if (id is not null) bubble.OnTap(() => Speaker.PlayVoice(id));
        return bubble;
    }
}

/// 任务清单（TodoWrite，同 Mac 版 TodoCard）
public static class TodoCard
{
    public static Control Make(IReadOnlyList<JsonNode> todos)
    {
        var done = todos.Count(t => t.Str("status") == "completed");
        var stack = new StackPanel { Spacing = ChatType.Px(4) };
        stack.Children.Add(Ui.H(6, Ui.Sym("checklist", ChatType.Size, "Text"), Ui.Text(L("任务清单"), ChatType.Size, FontWeight.Bold), new Spacer(),
            Ui.Text($"{done}/{todos.Count}", ChatType.Size, color: "Text2").Digits()).Margin(0, 0, 0, 2));
        foreach (var todo in todos)
        {
            var status = todo.Str("status") ?? "";
            var text = status == "in_progress" ? todo.Str("activeForm") ?? todo.Str("content") ?? "" : todo.Str("content") ?? "";
            var icon = Ui.Sym(status == "completed" ? "checkmark.circle.fill" : status == "in_progress" ? "circle.dotted.circle" : "circle", ChatType.Size,
                status == "completed" ? "Added" : status == "in_progress" ? "Accent" : "Text2");
            icon.VerticalAlignment = VerticalAlignment.Top;
            icon.Margin = new Thickness(0, ChatType.Size * 0.2, 0, 0);
            var label = new RichText(text, ChatType.Size, status == "in_progress" ? FontWeight.SemiBold : FontWeight.Normal, status == "completed" ? "Text2" : "Text");
            if (status == "completed") label.TextDecorations = TextDecorations.Strikethrough;
            var row = new DockPanel();
            icon.Margin = new Thickness(0, icon.Margin.Top, 8, 0);
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            row.Children.Add(label);
            stack.Children.Add(row);
        }
        var box = Ui.Box(stack, new Thickness(ChatType.PadH, ChatType.PadV + ChatType.Px(2)), "BotBubble", ChatType.Radius);
        box.MaxWidth = ChatType.Px(340);
        box.HorizontalAlignment = HorizontalAlignment.Left;
        return box;
    }
}

/// 系统提示（用量到上限、子任务回报、上下文已压缩……），居中小字；带详情的轻点查看（同 Mac 版 EventRow）
public static class EventRow
{
    public static Control Make(ChatItem item)
    {
        var text = item.Text ?? "";
        if (item.ResetAt is double reset)
            text = reset > Format.NowMs ? L("%@，%@ 恢复", text, Format.ResetTime(reset)) : L("%@（%@ 已恢复）", text, Format.ResetTime(reset));
        var color = item.Level == "error" ? "Removed" : "Text2";
        // 目标的那几行（设定、每轮检查、达成……）：前面带个小图标，达成的写上用了几轮、多久
        if (item.Goal is not null && GoalText.Stats(item.GoalTurns, item.GoalMs is double ms ? (int)(ms / 1000) : null, item.GoalTokens) is { Length: > 0 } stats)
            text += " · " + stats;
        var label = Ui.Text(text, 11.5, color: color, lines: 0).Wrap();
        label.TextAlignment = TextAlignment.Center;
        Control content = item.Detail is null ? label : Ui.H(4, label.Shrink(), Ui.Sym("chevron.right", 9, color));
        if (item.Goal is string kind) content = Ui.H(4, Ui.Sym(GoalText.EventSymbol(kind), 11, color), content.Shrink());
        var box = Ui.Box(content, new Thickness(12, 6), "Fill06", 8);
        box.HorizontalAlignment = HorizontalAlignment.Center;
        box.Margin = new Thickness(40, 10);
        if (item.Detail is string detail) box.OnTap(() => Sheets.Text(item.Text ?? "", detail));
        return box;
    }
}

/// 发出去还没在对话里回显的消息（同 Mac 版 PendingMessage）
public static class PendingMessage
{
    public static Control Make(string key, PendingSend p, bool first)
    {
        var model = AppModel.Shared;
        var stack = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
        var dim = p.State == SendState.Sending ? 0.7 : 1;
        if (p.Voice is double seconds)
        {
            if (p.Previews.Count > 0) stack.Children.Add(new Bubble(true, first, Previews(p.Previews)).Opacity(dim));
            stack.Children.Add(VoiceBubble.Make(null, seconds, true, first && p.Previews.Count == 0).Opacity(dim));
            if (!p.IsFailed || p.Text.Length > 0) stack.Children.Add(UserMessage.Transcript(p.Text));
        }
        else
        {
            var content = new StackPanel { Spacing = 6 };
            if (p.Previews.Count > 0) content.Children.Add(Previews(p.Previews));
            if (p.Text.Length > 0) content.Children.Add(new RichText(p.Text, ChatType.Size, color: Bubble.TextColor(true)));
            stack.Children.Add(new Bubble(true, first, content).Opacity(dim));
        }
        Control? status = p.State switch
        {
            SendState.Sending => new Spinner(14).HAlign(HorizontalAlignment.Right),
            SendState.Filled => Ui.Text(L("已填入 VS Code 输入框，未提交"), 11, color: "Orange").HAlign(HorizontalAlignment.Right),
            SendState.Queued => Ui.Text(L("离线，连接后自动发送"), 11, color: "Orange").HAlign(HorizontalAlignment.Right),
            // 电脑报了已提交，对话里却一直没出现（同 iOS）。不给「重新发送」：老版本电脑端不核对输入框，文字可能还留在里面，再发一次会和它拼在一起
            SendState.Unconfirmed => Ui.H(10,
                Ui.HTop(4, Ui.Sym("exclamationmark.triangle.fill", 11, "Orange").Margin(0, 2, 0, 0), Ui.Text(L("对话中未出现这条消息，请在电脑上查看"), 11, color: "Orange", lines: 2).Wrap().Shrink()).Shrink(),
                new Tap(Ui.Text(L("移除"), 11, FontWeight.Medium, "Text2"), () => model.Discard(key, p.Id), 4).Tip(L("移除这条消息"))).HAlign(HorizontalAlignment.Right).MaxW(560),
            // 原因长的折成两行（同 Mac 的 lineLimit(2)），不要一行撑出窗口
            SendState.Failed => Ui.H(10,
                new Tap(Ui.HTop(4, Ui.Sym("exclamationmark.circle.fill", 11, "Removed").Margin(0, 2, 0, 0), Ui.Text(L("%@　轻点重新发送", p.Error ?? ""), 11, color: "Removed", lines: 2).Wrap().Shrink()), () => model.Retry(key, p.Id), 4).Shrink(),
                new Tap(Ui.Text(L("移除"), 11, FontWeight.Medium, "Text2"), () => model.Discard(key, p.Id), 4).Tip(L("移除这条未发送的消息"))).HAlign(HorizontalAlignment.Right).MaxW(560),
            _ => null,
        };
        if (status is not null) stack.Children.Add(status);
        return stack;
    }

    /// 还没发到后台的图（本地缩略图）
    public static Control Previews(IReadOnlyList<byte[]> previews)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        foreach (var data in previews)
        {
            try
            {
                using var s = new MemoryStream(data);
                row.Children.Add(new Image { Source = new Bitmap(s), Width = 72, Height = 72, Stretch = Stretch.UniformToFill }.Clip(6));
            }
            catch (Exception) { }
        }
        return row;
    }
}

/// 转圈（同系统的小号 ProgressView）
public sealed class Spinner : Control
{
    readonly double size;
    double angle;
    DispatcherTimer? timer;

    public Spinner(double size = 16) { this.size = size; Width = size; Height = size; IsHitTestVisible = false; }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(80), DispatcherPriority.Render, (_, _) => { angle = (angle + 30) % 360; InvalidateVisual(); });
        timer.Start();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        timer?.Stop();
    }

    public override void Render(DrawingContext context)
    {
        var c = new Point(size / 2, size / 2);
        var color = Palette.GetColor("Text2");
        for (var i = 0; i < 12; i++)
        {
            var a = (angle + i * 30) * Math.PI / 180;
            var alpha = (byte)(40 + 215 * i / 11);
            var pen = new Pen(new SolidColorBrush(Color.FromArgb(alpha, color.R, color.G, color.B)), size * 0.09, lineCap: PenLineCap.Round);
            context.DrawLine(pen, new Point(c.X + Math.Cos(a) * size * 0.25, c.Y + Math.Sin(a) * size * 0.25), new Point(c.X + Math.Cos(a) * size * 0.45, c.Y + Math.Sin(a) * size * 0.45));
        }
    }
}

public static class Quote
{
    /// 引用回复取哪几行：代码块换成「（代码）」，去掉表格分隔线，最多 6 行、300 字（同 Mac 版 Quote）
    public static string Make(string text)
    {
        var noCode = System.Text.RegularExpressions.Regex.Replace(text, "```[\\s\\S]*?```", L("（代码）"));
        var lines = noCode.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0 && !System.Text.RegularExpressions.Regex.IsMatch(l, @"^\|?\s*:?-{3,}")).ToList();
        var quoted = string.Join("\n", lines.Take(6));
        if (quoted.Length > 300) quoted = quoted[..300] + "…"; else if (lines.Count > 6) quoted += "\n…";
        return quoted;
    }
}
