using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Kiteline.Model;

/// 一个会话的对话内容：后台推来的条目、翻页状态、还没回显的发送（同 iOS 版 ChatStore）
public sealed partial class ChatStore : ObservableObject
{
    public string Key { get; }
    readonly Dictionary<string, ChatItem> items = new();
    /// 工具结果按工具调用 id 存，画工具那一步时一起显示
    readonly Dictionary<string, ChatItem> results = new();
    public IReadOnlyDictionary<string, ChatItem> Items => items;
    public IReadOnlyDictionary<string, ChatItem> Results => results;

    List<PendingSend> pending = [];
    public IReadOnlyList<PendingSend> Pending => pending;

    [ObservableProperty] bool hasMore = true;
    [ObservableProperty] bool loading;
    [ObservableProperty] bool loaded;
    /// 每次内容变了加一：对话页看它重排
    [ObservableProperty] int revision;

    /// 用户点开过的折叠步骤组
    public HashSet<string> Expanded { get; } = [];
    /// 离开超过 10 分钟再回来：从这个时间之后的标「以下是新消息」
    public double? NewSince { get; set; }
    /// 刚点过「允许 / 拒绝」的那个确认：等后台状态更新前别再弹出来
    public string? AnsweredPrompt { get; set; }
    /// 提问卡片上已经选了的（切出去再回来还在）
    public Dictionary<string, List<QuestionAnswer>> Answers { get; } = new();
    /// 引用：发的时候带在前面
    [ObservableProperty] string? quote;
    /// 用语音发的消息（按转写文字对应），对话里画成语音条
    public Dictionary<string, VoiceClip> Voices { get; } = new();
    /// 输入区里还没发的附图
    public List<ComposeAttachment> Attachments { get; } = [];
    /// 输入区上面的常用语展开着（每个会话各记各的）
    [ObservableProperty] bool quickRepliesShown;
    /// 终端面板开着（在输入区的位置，见 Terminal/TerminalPanel）
    [ObservableProperty] bool terminalOpen;
    /// 刚切过的权限模式、换过的模型、发过的 /effort：后台记录里认出来之前按切过去的显示（同 iOS 版）
    public (string Mode, string? Baseline)? ModeOverride { get; set; }
    public (string Model, string? Baseline, string Send)? ModelOverride { get; set; }
    public (string Effort, string? Baseline, string Send)? EffortOverride { get; set; }
    public (bool On, bool Baseline, string Send)? UltracodeOverride { get; set; }

    public ChatStore(string key) => Key = key;

    /// 正在生成的那一块（电脑推的 live，见 watcher 的 LiveTap）：画在对话最后、一个字一个字长出来（同 iOS 版）。
    /// 对话记录要等一整块说完才写，以前长回复要等很久才一下子出来，终端里却早就逐字出了（11-24）
    ChatItem? live;
    string liveBlock = "", liveText = "";
    double liveTs;
    int liveN;
    /// 电脑说这一块说完了：记录里那条（几乎同时到）到了再撤，免得中间空一下；3 秒还没到也撤
    bool liveEnding;

    /// 电脑推来的 live 事件：text 是整段（新的一块、或隔一会儿补一次），append 是接在后面的（n 接不上就等下一次整段）
    public void ApplyLive(JsonNode json)
    {
        if (json.Bool("clear") == true)
        {
            if (live is null || liveEnding) return;
            liveEnding = true;
            var block = liveBlock;
            Avalonia.Threading.DispatcherTimer.RunOnce(() =>
            {
                if (!liveEnding || liveBlock != block) return;
                live = null;
                liveEnding = false;
                Revision++;
            }, TimeSpan.FromSeconds(3));
            return;
        }
        if (json.Str("id") is not string id || json.Str("kind") is not string kind || json.Int("n") is not int n) return;
        if (json.Str("text") is string text)
        {
            // 排在已有内容后面：用电脑上这一块开始的时刻（和记录同一个钟），不早于已有的最后一条
            if (live is null || liveBlock != id)
                liveTs = Math.Max(json.Num("at") ?? 0, (items.Values.Select(i => i.Ts ?? 0).DefaultIfEmpty(0).Max()) + 1);
            liveText = text;
        }
        else if (json.Str("append") is string append && live is not null && liveBlock == id && n == liveN + 1)
            liveText += append;
        else
            return;
        liveBlock = id;
        liveN = n;
        liveEnding = false;
        live = ChatItem.Parse(new JsonObject { ["t"] = kind, ["id"] = "live", ["ts"] = liveTs, ["text"] = liveText, ["detail"] = id });
        Revision++;
    }

    public void Add(IEnumerable<ChatItem> incoming)
    {
        var users = new List<ChatItem>();
        var any = false;
        var goalNoted = false;
        foreach (var item in incoming)
        {
            any = true;
            if (item.T == "result" && item.ToolId is string toolId) results[toolId] = item;
            if (item.T == "user" && seenUsers.Add($"{item.Id}|{item.Ts ?? 0}")) users.Add(item);
            if (item.T == "event" && item.Goal is not null) goalNoted = true;
            items[item.Id] = item;
        }
        if (!any) return;
        if (users.Count > 0 && pending.Count > 0) Settle(users);
        if (liveEnding && items.Values.Count > 0 && incoming.Any(i => i.T is "text" or "thinking" or "tool"))
        {
            live = null;
            liveEnding = false;
        }
        // 发的 /goal：对话里出了「已设定目标」这类提示就算到了（Codex 的目标不当成一句话回显）
        if (goalNoted) pending = pending.Where(p => p.IsFailed || !p.Text.StartsWith("/goal")).ToList();
        Revision++;
    }

    public void Reset()
    {
        live = null;
        liveEnding = false;
        items.Clear();
        results.Clear();
        HasMore = true;
        Loaded = false;
        Revision++;
    }

    /// 收到过的用户消息（id + 时间；Reset 后也留着）：重新加载历史时再来一遍的旧消息不拿去认回显
    readonly HashSet<string> seenUsers = new();

    /// 发出去的消息在对话记录里回显了，撤掉本地的「发送中」。
    /// 只认这条发出之后才有的用户消息（两边的钟可能差一点，放宽两分钟）：以前只比文字，重连、重新加载历史时早先发过的同样的话
    /// （「继续」「好的」）被当成回显，还没送到的这条就被悄悄撤掉、也不再重发（11-20 反馈，同 iOS）
    void Settle(List<ChatItem> users)
    {
        var before = pending.Count;
        pending = pending.Where(p =>
        {
            if (p.IsFailed) return true;
            if (p.Voice is not null && p.Text.Length == 0) return true;   // 语音还没转写完，认不出是哪条
            var head = p.Text.Length > 24 ? p.Text[..24] : p.Text;
            return !users.Any(u => (u.Ts ?? double.MaxValue) >= p.At - 120_000
                && (head.Length == 0 ? (u.Images?.Count ?? 0) > 0 : (u.Text ?? "").Contains(head)));
        }).ToList();
        if (pending.Count != before) Revision++;
    }

    /// 语音的转写刚回来：回显可能已经先到了，再对一遍
    public void SettleAgain()
    {
        var users = items.Values.Where(i => i.T == "user").ToList();
        if (users.Count > 0) Settle(users);
    }

    public void AddPending(PendingSend p)
    {
        pending = [.. pending, p];
        Revision++;
    }

    public void RemovePending(Func<PendingSend, bool> match)
    {
        var next = pending.Where(p => !match(p)).ToList();
        if (next.Count == pending.Count) return;
        pending = next;
        Revision++;
    }

    public void Update(string id, Func<PendingSend, PendingSend> change)
    {
        var index = pending.FindIndex(p => p.Id == id);
        if (index < 0) return;
        var next = pending.ToList();
        next[index] = change(next[index]);
        pending = next;
        Revision++;
    }

    public void Touch() => Revision++;

    /// 刚在这台设备上调过排队消息（上移 / 下移 / 改 / 删）：电脑的新队列传回来之前按调过的显示，别让列表跳回去
    public (List<QueuedItem> Items, DateTime At)? QueueDraft { get; set; }
    /// 排队列表收起了
    public bool QueueCollapsed { get; set; }

    /// 输入框上方排队列表的一行：电脑队列里的（Editable，能上移、下移、编辑、删除）或这台设备刚发、还没在队列里出现的（只能强插）
    /// Sending：还在发往电脑的路上（发的时候 Claude 正忙，先列在这里），还不能强插
    public sealed record QueueRow(string Id, string Text, bool Editable, bool Sending = false);

    /// 排队列表：电脑给了队列就按它（加上刚发、还没出现在里面的）；老版本（没有队列）列这台设备记下的排队消息（同 iOS）
    public List<QueueRow> QueueRows(SessionInfo? session)
    {
        var mine = pending.Where(p => p.InQueueStrip).ToList();
        if (session?.Queue is not { } queue) return mine.Select(p => new QueueRow(p.Qid ?? p.Id, p.Text, false, p.State == SendState.Sending)).ToList();
        if (QueueDraft is { } draft && DateTime.Now - draft.At < TimeSpan.FromSeconds(4)) queue = draft.Items;
        var known = queue.Select(q => q.Id).ToHashSet();
        return queue.Select(q => new QueueRow(q.Id, q.Text, true))
            .Concat(mine.Where(p => !p.Seen && !known.Contains(p.Qid ?? "")).Select(p => new QueueRow(p.Qid ?? p.Id, p.Text, false, p.State == SendState.Sending))).ToList();
    }

    /// 往前翻页的位置
    public long? OldestOffset => items.Values.Where(i => !i.Id.StartsWith('o')).Select(i => (long?)i.Offset).Min();
    public double? OldestTs => items.Values.Select(i => i.Ts).Where(t => t is not null).Min();

    /// 本轮从哪开始算（最后一条用户消息的时间）
    public double? TurnStart => items.Values.Where(i => i.T == "user").Select(i => i.Ts).Where(t => t is not null).Max();

    /// 最新一次任务清单
    public List<JsonNode> Todos
    {
        get
        {
            ChatItem? last = null;
            foreach (var i in items.Values)
                if (i.T == "tool" && i.Name == "TodoWrite" && (last is null || ChatItem.Compare(i, last) > 0)) last = i;
            return last?.Input.Arr("todos").Items().ToList() ?? [];
        }
    }

    public ChatItem? OpenTool => ChatLayout.OpenTool(items, results);

    /// 行只跟会话在忙 / 等确认 / 空闲有关
    public List<ChatRow> Rows(string? activity)
    {
        if (live is null) return ChatLayout.Build(items, results, pending, activity, Expanded, NewSince);
        var all = new Dictionary<string, ChatItem>(items) { [live.Id] = live };
        return ChatLayout.Build(all, results, pending, activity, Expanded, NewSince);
    }
}

/// 发过的一段语音：后台存着录音，按 id 取回来放
public sealed record VoiceClip(string Id, double Duration);

/// 提问卡片上一题的回答
public sealed class QuestionAnswer
{
    public HashSet<string> Picked { get; } = [];
    public string Other { get; set; } = "";
}

/// 输入区里的一张附图
public sealed record ComposeAttachment(string Id, string Name, byte[] Data, byte[] Preview);
