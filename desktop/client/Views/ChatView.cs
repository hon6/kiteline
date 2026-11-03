using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 一个会话的对话页（同 Mac 版 ChatView）：内容最宽 880 居中，消息少时贴底；上面「查看更早的消息」；
/// 贴着底部时新消息跟着滚下去，往上翻着看时底部冒「新消息 ↓」；底下是任务进展条、确认卡片和输入区
public sealed class ChatView : Grid
{
    public string Key { get; }
    public Guid Pane { get; set; }
    readonly AppModel model = AppModel.Shared;
    readonly ChatStore chat;
    readonly ScrollViewer scroll;
    readonly StackPanel list = new();
    readonly Border header = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly Panel working = new();
    readonly Border content;
    readonly StackPanel deck = new() { Spacing = 8 };
    readonly Composer composer;
    readonly Border newPill;
    /// 输入框上方的任务进展条（见 StageStrip）、它上面的目标条（见 GoalStrip）
    readonly StageStrip stageStrip = new();
    readonly GoalStrip goalStrip = new();
    readonly Dictionary<string, (ChatRow Row, Control View)> views = new();
    readonly List<Control> order = [];
    Control? promptCard;
    string? promptSignature;
    double lastWidth;
    bool stick = true;
    bool pending;
    double lastExtent;
    string? lastRowId;

    public ChatView(string key)
    {
        Key = key;
        chat = model.Chat(key);
        RowDefinitions = new RowDefinitions("*,Auto");
        this.Res(BackgroundProperty, "ChatBackground");
        var column = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
        column.Children.Add(header);
        column.Children.Add(list);
        column.Children.Add(working);
        column.Children.Add(new Border { Height = 6 });
        content = new Border { Child = column, MaxWidth = 880, Padding = new Thickness(0, 0, 0, 4) };
        scroll = new ScrollViewer
        {
            Content = content,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        scroll.ScrollChanged += Scrolled;
        scroll.SizeChanged += (_, _) => { content.MinHeight = scroll.Viewport.Height; if (stick) ScrollToEnd(); };
        var area = new Panel { Children = { scroll } };
        newPill = new Border
        {
            IsVisible = false, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 10),
            Child = new Tap(Ui.H(6, Ui.Sym("arrow.down", 12, "Action"), Ui.Text(L("新消息"), 12, FontWeight.SemiBold, "Action")).Pad(14, 8), () => { stick = true; ScrollToEnd(); newPill!.IsVisible = false; }, 16)
                .Keys("GlassSolid", "Fill12"),
            CornerRadius = new CornerRadius(16), BoxShadow = BoxShadows.Parse("0 2 8 0 #1A000000"),
        };
        area.Children.Add(newPill);
        SetRow(area, 0);
        Children.Add(area);
        composer = new Composer(key)
        {
            OnStop = ConfirmStop, OnCompact = ConfirmCompact,
            OnMode = () => Perform(SessionAction.Mode), OnModel = () => Perform(SessionAction.Model),
            OnTodos = () => Sheets.Show(L("任务清单"), TodoCard.Make(chat.Todos), 420, 480), OnAgents = () => Perform(SessionAction.Agents),
        };
        deck.Children.Add(goalStrip);
        deck.Children.Add(stageStrip);
        deck.Children.Add(composer);
        var deckBox = new Border { Child = deck, Padding = new Thickness(0, 8, 0, 0) };
        deckBox.Res(Border.BackgroundProperty, "ChatBackground");
        SetRow(deckBox, 1);
        Children.Add(deckBox);

        chat.PropertyChanged += ChatChanged;
        model.PropertyChanged += ModelChanged;
        ChatActions.Requested += External;
        model.Open(key, focus: ChatPanes.Shared.Focused == key);
        _ = model.LoadPastMeta(key);
        if (model.JumpRequests.Remove(key, out var jump)) Dispatcher.UIThread.Post(() => JumpTo(jump), DispatcherPriority.Background);
        Rebuild();
        UpdateSession();
    }

    /// 关掉这个标签（会话不再显示）
    public void Closed()
    {
        chat.PropertyChanged -= ChatChanged;
        model.PropertyChanged -= ModelChanged;
        ChatActions.Requested -= External;
        model.Close(Key);
    }

    void ChatChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ChatStore.Revision) or nameof(ChatStore.Loading) or nameof(ChatStore.HasMore) or nameof(ChatStore.Loaded)) Schedule();
        if (e.PropertyName == nameof(ChatStore.TerminalOpen)) UpdateTerminal();
    }

    /// 终端开着时输入框换成终端面板（确认卡片照常在上面）；收起时面板留着不扔，再打开还是那几个标签
    Terminal.TerminalPanel? terminalPanel;
    void UpdateTerminal()
    {
        var open = chat.TerminalOpen && Session?.Can("term") == true;
        composer.IsVisible = !open;
        if (open && terminalPanel is null) deck.Children.Add(terminalPanel = new Terminal.TerminalPanel(Key, chat));
        if (terminalPanel is not null) terminalPanel.IsVisible = open;
    }

    void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.Sessions) or nameof(AppModel.Connected) or nameof(AppModel.QuickReplies)) { Schedule(); UpdateSession(); }
    }

    void Schedule()
    {
        if (pending) return;
        pending = true;
        Dispatcher.UIThread.Post(() => { pending = false; Rebuild(); }, DispatcherPriority.Background);
    }

    SessionInfo? Session => model.Session(Key);

    protected override Size ArrangeOverride(Size finalSize)
    {
        var width = Math.Min(finalSize.Width, 880);
        if (Math.Abs(width - lastWidth) > 40 && lastWidth > 0) { lastWidth = width; views.Clear(); Schedule(); }
        else if (lastWidth == 0) lastWidth = width;
        return base.ArrangeOverride(finalSize);
    }

    void Rebuild()
    {
        var session = Session;
        var activity = session?.Activity;
        var rows = chat.Rows(activity);
        // 上面：加载中 / 查看更早的消息 / 已是最早的消息
        header.Child = chat.Loading ? new Spinner(16).Pad(10).HAlign(HorizontalAlignment.Center)
            : chat.HasMore && chat.Loaded ? new Tap(Ui.Text(L("查看更早的消息"), 12, color: "Accent").Pad(10), LoadOlder, 6).HAlign(HorizontalAlignment.Center)
            : chat.Loaded && chat.Items.Count > 0 ? Ui.Text(L("— 已是最早的消息 —"), 11.5, color: "Text2").Pad(10).HAlign(HorizontalAlignment.Center)
            : null;
        var next = new List<Control>(rows.Count);
        var used = new HashSet<string>();
        var agent = session?.Agent ?? Agents.DefaultId;
        foreach (var row in rows)
        {
            used.Add(row.Id);
            if (views.TryGetValue(row.Id, out var cached) && cached.Row.Equals(row)) { next.Add(cached.View); continue; }
            var view = Build(row, agent);
            views[row.Id] = (row, view);
            next.Add(view);
        }
        foreach (var gone in views.Keys.Where(k => !used.Contains(k)).ToList()) views.Remove(gone);
        if (!next.SequenceEqual(order))
        {
            list.Children.Clear();
            list.Children.AddRange(next);
            order.Clear();
            order.AddRange(next);
        }
        UpdateWorking(session);
        // 对话记录变了（刚加载完、Claude 换了个要确认的工具）：确认卡片跟着换
        UpdateSession();
        // 新消息来了：本来就在底部（或是我刚发的）就跟着滚下去；往上翻着看就只冒「新消息 ↓」
        var last = rows.LastOrDefault()?.Id;
        if (last != lastRowId)
        {
            var mine = rows.LastOrDefault() is PendingRow;
            if (stick || mine) { stick = true; newPill.IsVisible = false; ScrollToEnd(); }
            else if (lastRowId is not null) newPill.IsVisible = true;
            lastRowId = last;
        }
    }

    Control Build(ChatRow row, string agent) => RowView(Key, row, agent, lastWidth > 0 ? lastWidth : 880, OpenLink);

    /// 一行记录画成什么（对话页、子 agent 的完整记录共用）
    public static Control RowView(string key, ChatRow row, string agent, double width, Action<string> openLink)
    {
        switch (row)
        {
            case SeparatorRow s:
                // 同微信：时间居中、浅灰小字（上面多空一点，和上一段对话分开）
                return Ui.Text(s.Text, 12, color: "Text2").HAlign(HorizontalAlignment.Center).Margin(0, 16, 0, 0);
            case NewMarkerRow:
                var marker = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,*"), Margin = new Thickness(40, 20, 40, 4) };
                var left = Ui.Rule(); var right = Ui.Rule();
                var label = Ui.Text(L("以下是新消息"), 11.5, color: "Accent").Margin(8, 0, 8, 0);
                Grid.SetColumn(left, 0); Grid.SetColumn(label, 1); Grid.SetColumn(right, 2);
                left.VerticalAlignment = VerticalAlignment.Center; right.VerticalAlignment = VerticalAlignment.Center;
                marker.Children.Add(left); marker.Children.Add(label); marker.Children.Add(right);
                return marker;
            case UserRow u:
                // Kiteline 送进来的会话群消息：画成一张群消息卡片（不显示给 agent 看的群说明、回复方法）
                if (GroupText.Parse(u.Item.Text) is { } inbound) return GroupCards.Inbound(key, u.Item, inbound);
                return new MessageRow(true, u.First, u.Item.Ts, UserMessage.Make(key, u.Item, u.First), agent, width);
            case BotRow b:
                Control body = b.Item.Peer is not null ? PeerCard.Make(key, b.Item) : b.Item.T switch
                {
                    "agent_image" => AgentImageMessage.Make(key, b.Item, b.First, openLink),
                    "agent_page" => AgentPageMessage.Make(key, b.Item, b.First, openLink),
                    "agent_todo" => AgentTodoMessage.Make(key, b.Item, b.First),
                    "agent_key" => AgentKeyMessage.Make(key, b.Item, b.First),
                    "group_say" => GroupCards.Say(key, b.Item, b.First),
                    "tool" => TodoCard.Make(b.Item.Input.Arr("todos").Items().ToList()),
                    _ => BotText.Make(key, b.Item, b.First, openLink),
                };
                return new MessageRow(false, b.First, b.Item.Ts, body, agent, width, b.Item.T == "text" ? (b.Item.Text ?? "", b.Item.Id) : null, key);
            case StepsRow st:
                return new MessageRow(false, st.First, st.Steps.LastOrDefault()?.Item.Ts, StepsCard.Make(key, st), agent, width, key: key);
            case Kiteline.Model.EventRow e:
                return Views.EventRow.Make(e.Item);
            case PendingRow p:
                return new MessageRow(true, p.First, null, PendingMessage.Make(key, p.Pending, p.First), agent, width);
        }
        return new Panel();
    }

    /// 正在工作：小纸鸢 + 状态词 + 用时 · 在做什么（同 Mac 版 WorkingView）；很久没动静变红
    void UpdateWorking(SessionInfo? session)
    {
        working.Children.Clear();
        if (session is not { IsBusy: true } || !model.Connected) return;
        var since = (chat.TurnStart ?? session.UpdatedAt ?? Format.NowMs) / 1000;
        working.Children.Add(new WorkingView(since, session));
    }

    /// 会话状态变了：确认卡片、输入区
    void UpdateSession()
    {
        var session = Session;
        composer.Update(session);
        goalStrip.Update(Key, model.Connected ? session?.Goal : null);
        stageStrip.Update(model.Connected ? session?.LiveStage : null, Bounds.Height);
        var signature = session is null ? null : PromptCard.Current(Key, chat) + "|" + session.IsWaiting + session.CanReply + chat.AnsweredPrompt + session.Activity;
        if (signature == promptSignature && promptCard is not null == (session?.IsWaiting ?? false)) { UpdateWorking(session); return; }
        promptSignature = signature;
        if (promptCard is not null) deck.Children.Remove(promptCard);
        var cap = ChatPanes.Shared.Count > 1 && Bounds.Height > 0 ? Math.Max(48, Bounds.Height * 0.7 - 210) : double.PositiveInfinity;
        promptCard = session is null ? null : PromptCard.Make(session, chat, cap);
        if (promptCard is not null) deck.Children.Insert(deck.Children.IndexOf(stageStrip) + 1, promptCard);   // 进展条在最上面
        UpdateWorking(session);
    }

    void Scrolled(object? sender, ScrollChangedEventArgs e)
    {
        var distance = scroll.Extent.Height - scroll.Offset.Y - scroll.Viewport.Height;
        if (Math.Abs(scroll.Extent.Height - lastExtent) > 0.5)
        {
            // 内容高度变了 = 来了新内容：贴底的跟着滚到底
            lastExtent = scroll.Extent.Height;
            if (stick && distance > 1) ScrollToEnd();
        }
        else
        {
            // 位置变了 = 你在翻：离底部 160 以内算贴底
            stick = distance < 160;
            if (stick) newPill.IsVisible = false;
        }
    }

    void ScrollToEnd() => Dispatcher.UIThread.Post(() => scroll.Offset = new Vector(0, Math.Max(0, scroll.Extent.Height - scroll.Viewport.Height)), DispatcherPriority.Background);

    async void LoadOlder()
    {
        // 加载更早的消息：加载完停在原来看的那条上，不跳走
        stick = false;
        var before = scroll.Extent.Height - scroll.Offset.Y;
        await model.LoadHistory(Key, older: true);
        Dispatcher.UIThread.Post(() => scroll.Offset = new Vector(0, Math.Max(0, scroll.Extent.Height - before)), DispatcherPriority.Background);
    }

    /// 搜索结果、待办出处：滚到那条（还没加载到就往前翻页找）
    async void JumpTo(string target)
    {
        stick = false;
        for (var i = 0; i < 12; i++)
        {
            var row = chat.Rows(Session?.Activity).FirstOrDefault(r => r.Contains(target));
            if (row is not null && views.TryGetValue(row.Id, out var v))
            {
                Dispatcher.UIThread.Post(() => v.View.BringIntoView(), DispatcherPriority.Background);
                return;
            }
            if (!chat.HasMore) break;
            await model.LoadHistory(Key, older: true);
            Rebuild();
        }
        model.Flash(L("未找到此消息（可能尚未加载）"));
    }

    /// 消息里的链接：网址照常用浏览器开；文件（Claude 常写成 [README.md](README.md)、`~/Desktop/报价单.xlsx`）：
    /// 项目目录里的代码、文本打开文件页；目录外的（Claude 常放桌面）和办公文档、图片用默认的程序打开（见 FileOpen）
    void OpenLink(string url)
    {
        if (url.StartsWith("http://") || url.StartsWith("https://")) { Links.Open(url); return; }
        var raw = FileLinks.PathOf(url) ?? Uri.UnescapeDataString(url.Split('#')[0]);
        var path = FileLinks.StripLine(raw);
        if (path.Length == 0) return;
        var cwd = Session?.Cwd ?? (model.PastMeta.TryGetValue(Key, out var past) ? past.Cwd : null);
        string? inProject = null;
        if (!FileLinks.IsAbsolute(path)) inProject = path.StartsWith("./") ? path[2..] : path;
        else if (cwd is { Length: > 0 } && path.StartsWith(cwd.TrimEnd('/', '\\') + (path.Contains('\\') ? "\\" : "/"))) inProject = path[(cwd.TrimEnd('/', '\\').Length + 1)..];
        if (inProject is { Length: > 0 } && !inProject.StartsWith("../") && !FileLinks.DocumentExtensions.Contains(FileLinks.Ext(path)))
            ChatSheets.File(Key, inProject);
        else
            FileOpen.Open(Key, path);
    }

    void External(string key, SessionAction action)
    {
        if (key == Key) Perform(action);
    }

    public void Perform(SessionAction action)
    {
        switch (action)
        {
            case SessionAction.Stop: ConfirmStop(); break;
            case SessionAction.Compact: ConfirmCompact(); break;
            case SessionAction.Bottom: stick = true; ScrollToEnd(); break;
            case SessionAction.Files: ChatSheets.Files(Key); break;
            case SessionAction.Changes: ChatSheets.Changes(Key); break;
            case SessionAction.Tests: ChatSheets.Tests(Key); break;
            case SessionAction.Agents: ChatSheets.Agents(Key); break;
            case SessionAction.Search: ChatSheets.Search(Key, JumpTo); break;
            case SessionAction.Info: ChatSheets.Info(Key); break;
            case SessionAction.Terminal: chat.TerminalOpen = !chat.TerminalOpen; break;
            case SessionAction.Mode: ChatSheets.Mode(Key); break;
            case SessionAction.Model: ChatSheets.Model(Key); break;
            case SessionAction.Goal: GoalSheet.Open(Key); break;
            case SessionAction.NewTask:
                if (model.Session(Key) is { } s) MainModel.Shared.NewTask(s);
                break;
        }
    }

    async void ConfirmStop()
    {
        var s = Session;
        var message = s?.IsClaude ?? true
            ? L("中断 Claude 等同于在 Claude Code 中按 Esc：Claude 将停在当前步骤（正在执行的命令也会终止），之后可继续对话")
            : L("中断 %@：将停在当前步骤（正在执行的命令也会终止），之后可继续对话", s!.Speaker);
        if (await Dialogs.Confirm(message, L("中断"), destructive: true))
            await model.Press(Key, "esc", L("已中断（等同于按 Esc）"));
    }

    async void ConfirmCompact()
    {
        if (await Dialogs.Confirm(L("压缩上下文等同于在 Claude Code 中输入 /compact：将此前的对话总结为摘要以释放空间，部分细节可能丢失"), L("压缩上下文")))
            model.Send(Key, "/compact", []);
    }
}

/// 正在工作那一行（同 Mac 版 WorkingView）：随风晃的小纸鸢 + 状态词（每 5 秒换一个）+ (用时 · 正在做什么)；20 分钟没动静变红
public sealed class WorkingView : Panel
{
    static readonly string[] Verbs = ["Accomplishing", "Actualizing", "Baking", "Booping", "Brewing", "Calculating", "Cerebrating", "Churning",
        "Clauding", "Coalescing", "Cogitating", "Combobulating", "Concocting", "Considering", "Contemplating", "Cooking", "Crafting", "Crunching",
        "Deciphering", "Deliberating", "Discombobulating", "Doing", "Elucidating", "Enchanting", "Envisioning", "Finagling", "Flibbertigibbeting",
        "Forging", "Frolicking", "Generating", "Germinating", "Hatching", "Herding", "Honking", "Ideating", "Imagining", "Incubating", "Inferring",
        "Manifesting", "Marinating", "Meandering", "Moseying", "Mulling", "Mustering", "Noodling", "Percolating", "Perusing", "Philosophizing",
        "Pondering", "Processing", "Puttering", "Puzzling", "Reticulating", "Ruminating", "Schlepping", "Shimmying", "Simmering", "Smooshing",
        "Spelunking", "Spinning", "Stewing", "Sussing", "Synthesizing", "Thinking", "Tinkering", "Transmuting", "Unfurling", "Unraveling", "Vibing",
        "Wandering", "Whirring", "Wibbling", "Working", "Wrangling"];

    readonly double since;
    readonly SessionInfo session;
    readonly TextBlock verb, detail;
    DispatcherTimer? timer;

    public WorkingView(double since, SessionInfo session)
    {
        this.since = since;
        this.session = session;
        MinHeight = ChatType.Size * 1.85;
        // 和气泡左边对齐（24 边距 + 30 头像 + 10 间隔）
        Margin = new Thickness(64, 4, 24, 8);
        var stuck = session.UpdatedAt is double u ? (int)((Format.NowMs - u) / 60000) : 0;
        if (stuck >= 20)
        {
            var quiet = stuck >= 120 ? L("%@ 小时", stuck / 60) : L("%@ 分钟", stuck);
            var text = new RichText([new MdSpan(L("可能停滞：")), new MdSpan(quiet, Bold: true),
                new MdSpan(L("无新进展") + (session.ActivityText is string a ? L("（正在 %@）", a) : ""))], ChatType.Size, color: "Removed");
            Children.Add(Ui.H(6, Ui.Sym("exclamationmark.triangle.fill", ChatType.Size, "Removed"), text.Shrink()));
            verb = detail = new TextBlock();
            return;
        }
        verb = Ui.Text("", ChatType.Size, color: "Accent");
        detail = Ui.Text("", ChatType.Size, color: "Text2").Shrink();
        Children.Add(Ui.H(6, new KiteSpinner(ChatType.Size * 1.25).Width(18), verb, detail));
        Tick();
    }

    void Tick()
    {
        var elapsed = Math.Max(0, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 - since);
        // 状态词每 5 秒换一个；同一轮里顺序固定（按开始时间取种子）
        var seed = unchecked((long)since * 2654435761L);
        var index = (int)(Math.Abs(unchecked(seed + (long)(elapsed / 5) * 40503L)) % Verbs.Length);
        verb.Text = Verbs[index] + "…";
        detail.Text = $"({Format.Duration((int)elapsed)}{(session.ActivityText is string a ? " · " + a : "")})";
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        timer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => Tick());
        timer.Start();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e) { base.OnDetachedFromVisualTree(e); timer?.Stop(); }
}

/// 确认框（同 Mac 的 confirmationDialog）
public static class Dialogs
{
    /// title 给了就是加粗的一行标题，message 是下面的说明（同 Mac 的 NSAlert）
    public static Task<bool> Confirm(string message, string confirm, bool destructive = false, string? title = null)
    {
        var done = new TaskCompletionSource<bool>();
        // 标题（有的话）在统一的标题栏里（同别的弹窗）
        Control text = Ui.Text(message, 13, lines: 0).Wrap();
        Window? window = null;
        var ok = PromptCard.CardButton(confirm, !destructive, () => { done.TrySetResult(true); window?.Close(); }, destructive ? "Removed" : null);
        var cancel = PromptCard.CardButton(L("取消"), false, () => { done.TrySetResult(false); window?.Close(); });
        var stack = new StackPanel { Spacing = 16, Children = { text, new ButtonPair(cancel, ok) } };
        window = new Window
        {
            Width = 420, SizeToContent = SizeToContent.Height, CanResize = true, MinWidth = 320, MinHeight = 120, ShowInTaskbar = false, Title = title ?? "",
            WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = Look.Family,
        };
        window.Content = Dialog.WithTitleBar(window, stack.Pad(20, 4, 20, 20));
        window.Res(Window.BackgroundProperty, "Sheet");
        Dialog.Chromeless(window, titleBar: true);
        window.Closed += (_, _) => done.TrySetResult(false);
        // 对着发起它的那一块会话正中（同别的弹窗）；按住空白处能拖走、拖边能改大小；记成最近的弹窗（自测能截）
        Dialog.Show(window, modal: true);
        return done.Task;
    }
}
