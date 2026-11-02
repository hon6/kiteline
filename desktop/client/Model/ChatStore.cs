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

    public void Add(IEnumerable<ChatItem> incoming)
    {
        var users = new List<ChatItem>();
        var any = false;
        var goalNoted = false;
        foreach (var item in incoming)
        {
            any = true;
            if (item.T == "result" && item.ToolId is string toolId) results[toolId] = item;
            if (item.T == "user") users.Add(item);
            if (item.T == "event" && item.Goal is not null) goalNoted = true;
            items[item.Id] = item;
        }
        if (!any) return;
        if (users.Count > 0 && pending.Count > 0) Settle(users);
        // 发的 /goal：对话里出了「已设定目标」这类提示就算到了（Codex 的目标不当成一句话回显）
        if (goalNoted) pending = pending.Where(p => p.IsFailed || !p.Text.StartsWith("/goal")).ToList();
        Revision++;
    }

    public void Reset()
    {
        items.Clear();
        results.Clear();
        HasMore = true;
        Loaded = false;
        Revision++;
    }

    /// 发出去的消息在对话记录里回显了，撤掉本地的「发送中」
    void Settle(List<ChatItem> users)
    {
        var before = pending.Count;
        pending = pending.Where(p =>
        {
            if (p.IsFailed) return true;
            if (p.Voice is not null && p.Text.Length == 0) return true;   // 语音还没转写完，认不出是哪条
            var head = p.Text.Length > 24 ? p.Text[..24] : p.Text;
            return !users.Any(u => head.Length == 0 ? (u.Images?.Count ?? 0) > 0 : (u.Text ?? "").Contains(head));
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
    public List<ChatRow> Rows(string? activity) => ChatLayout.Build(items, results, pending, activity, Expanded, NewSince);
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
