namespace Kiteline.Model;

/// 一步（思考 / 工具调用 / 单独的工具结果）的状态：转圈、等确认、成功、出错
public enum StepState { None, Running, Waiting, Ok, Failed }

public sealed record Step(ChatItem Item, ChatItem? Result, StepState State)
{
    public string Id => Item.Id;
}

/// Unconfirmed：空闲的会话发出去好一会儿，Claude 没动、对话里也没出现这条（多半没提交上）
/// Later：Claude 正在做这一轮，消息排在当前这一步（正在跑的工具）做完后读到，回显可能要等很久，不按时撤掉（同 iOS）
public enum SendState { Sending, Sent, Filled, Queued, Failed, Unconfirmed, Later }

/// 发出去、还没在对话记录里回显的消息
public sealed record PendingSend
{
    public required string Id { get; init; }
    public string Text { get; init; } = "";
    /// 附图：缩略图（显示用）和要发的内容（name + base64）
    public IReadOnlyList<byte[]> Previews { get; init; } = [];
    public IReadOnlyList<Dictionary<string, string>> Payload { get; init; } = [];
    public SendState State { get; init; } = SendState.Sending;
    public string? Error { get; init; }
    public bool Override { get; init; }
    /// 语音：时长（秒）和录音（失败重发要用）；文字是转写回来以后才有
    public double? Voice { get; init; }
    public byte[]? Audio { get; init; }
    /// 排队（Later）时电脑给的编号，对上会话的 Queue；Seen = 已经在队列里出现过（之后不在了 = 已交给 Claude 或在别处删了）
    public string? Qid { get; init; }
    public bool Seen { get; init; }

    public bool IsFailed => State == SendState.Failed;
}

/// 对话页的一行
public abstract record ChatRow
{
    public abstract string Id { get; }

    /// 这一行里有没有这条（搜索结果跳转用：工具调用在步骤组里）
    public virtual bool Contains(string itemId) => false;
}

public sealed record SeparatorRow(string ItemId, string Text) : ChatRow { public override string Id => "sep-" + ItemId; }
public sealed record NewMarkerRow : ChatRow { public override string Id => "new-marker"; }
public sealed record UserRow(ChatItem Item, bool First) : ChatRow
{
    public override string Id => Item.Id;
    public override bool Contains(string itemId) => Item.Id == itemId;
}
/// Claude 的回复正文、发来的图、任务清单
public sealed record BotRow(ChatItem Item, bool First) : ChatRow
{
    public override string Id => Item.Id;
    public override bool Contains(string itemId) => Item.Id == itemId;
}
/// 一串连续的步骤（思考、工具）；Hidden = 折叠起来的前几步
public sealed record StepsRow(string HeadId, IReadOnlyList<Step> Steps, int Hidden, bool First) : ChatRow
{
    public override string Id => "steps-" + HeadId;
    public override bool Contains(string itemId) => Steps.Any(s => s.Item.Id == itemId || s.Result?.Id == itemId);
    public bool Equals(StepsRow? other) => other is not null && HeadId == other.HeadId && Hidden == other.Hidden && First == other.First && Steps.SequenceEqual(other.Steps);
    public override int GetHashCode() => HashCode.Combine(HeadId, Hidden, First, Steps.Count);
}
public sealed record EventRow(ChatItem Item) : ChatRow
{
    public override string Id => Item.Id;
    public override bool Contains(string itemId) => Item.Id == itemId;
}
public sealed record PendingRow(PendingSend Pending, bool First) : ChatRow { public override string Id => "pending-" + Pending.Id; }

/// 把一个会话的所有条目排成对话页的行（同 iOS 版 ChatLayout）
public static class ChatLayout
{
    /// 认得的对话项种类；以后的插件新加的种类按一行提示（event）显示：不丢、不报错，也不当成回复
    static readonly HashSet<string> KnownKinds = ["user", "text", "thinking", "tool", "result", "agent_image", "agent_page", "agent_todo", "agent_key", "group_say", "event"];

    public static bool IsStep(ChatItem item) => item.T == "thinking" || item.T == "result" || (item.T == "tool" && item.Name != "TodoWrite" && !IsPeerCard(item));

    /// 会话之间的消息画成一封信（发出的那步、收到的那条），不夹在步骤里；设置里关了就照旧
    public static bool IsPeerCard(ChatItem item) => item.Peer is not null && PeerPrefs.Cards && (item.T == "tool" || item.T == "event");

    /// 最后一个还没有结果的工具调用：Claude 正在跑它，或者正等你确认它
    public static ChatItem? OpenTool(IReadOnlyDictionary<string, ChatItem> items, IReadOnlyDictionary<string, ChatItem> results) =>
        items.Values.Where(i => i.T == "tool" && !results.ContainsKey(i.ToolId ?? "")).Aggregate((ChatItem?)null, (best, i) => best is null || ChatItem.Compare(i, best) > 0 ? i : best);

    public static List<ChatRow> Build(IReadOnlyDictionary<string, ChatItem> items, IReadOnlyDictionary<string, ChatItem> results, IReadOnlyList<PendingSend> pending,
                                      string? activity, IReadOnlySet<string> expanded, double? newSince)
    {
        var toolIds = items.Values.Where(i => i.T == "tool" && i.ToolId is not null).Select(i => i.ToolId!).ToHashSet();
        var list = items.Values.Where(item =>
        {
            if (item.T == "result" && item.ToolId is string toolId && toolIds.Contains(toolId)) return false;   // 并进工具那一步
            if (item.T == "thinking" && string.IsNullOrWhiteSpace(item.Text)) return false;
            if (!KnownKinds.Contains(item.T) && string.IsNullOrEmpty(item.Text) && item.Detail is null) return false;
            return true;
        }).ToList();
        list.Sort(ChatItem.Compare);
        var open = OpenTool(items, results);

        var rows = new List<ChatRow>();
        double? prevTs = null;
        var prevSide = "";
        var steps = new List<Step>();
        var stepsFirst = false;
        var markedNew = false;

        void FlushSteps(bool live)
        {
            if (steps.Count == 0) return;
            var head = steps[0];
            var collapse = steps.Count > 6 && !live && !expanded.Contains(head.Id);
            rows.Add(new StepsRow(head.Id, steps.ToArray(), collapse ? steps.Count - 3 : 0, stepsFirst));
            steps = [];
        }

        var firstId = list.Count > 0 ? list[0].Id : null;
        foreach (var item in list)
        {
            if (item.Ts is double ts && (prevTs is null || ts - prevTs.Value > 5 * 60 * 1000))
            {
                FlushSteps(false);
                rows.Add(new SeparatorRow(item.Id, Format.Separator(ts)));
                prevSide = "";
            }
            if (newSince is double since && !markedNew && item.Ts is double t2 && t2 > since && item.Id != firstId)
            {
                FlushSteps(false);
                rows.Add(new NewMarkerRow());
                markedNew = true;
                prevSide = "";
            }
            if (item.Ts is double t3) prevTs = t3;

            if (item.T == "event" && IsPeerCard(item))
            {
                FlushSteps(false);
                rows.Add(new BotRow(item, prevSide != "bot"));
                prevSide = "bot";
            }
            else if (item.T == "event" || !KnownKinds.Contains(item.T))
            {
                FlushSteps(false);
                rows.Add(new EventRow(item));
                prevSide = "center";
            }
            else if (item.T == "user")
            {
                FlushSteps(false);
                rows.Add(new UserRow(item, prevSide != "me"));
                prevSide = "me";
            }
            else if (IsStep(item))
            {
                if (steps.Count == 0) stepsFirst = prevSide != "bot";
                steps.Add(new Step(item, StepResult(item, results), State(item, results, open, activity)));
                prevSide = "bot";
            }
            else
            {
                FlushSteps(false);
                rows.Add(new BotRow(item, prevSide != "bot"));
                prevSide = "bot";
            }
        }
        // 最后一组步骤：Claude 还在忙就别折叠
        FlushSteps(activity is not null && activity != "idle");
        // 排队的（Later）不在对话里画，在输入框上方的排队列表里（QueueStrip）
        var shown = pending.Where(p => p.State != SendState.Later).ToList();
        for (var i = 0; i < shown.Count; i++)
            rows.Add(new PendingRow(shown[i], i == 0 && prevSide != "me"));
        return rows;
    }

    static ChatItem? StepResult(ChatItem item, IReadOnlyDictionary<string, ChatItem> results)
    {
        if (item.T == "result") return item;
        if (item.T == "tool" && item.ToolId is string toolId && results.TryGetValue(toolId, out var r)) return r;
        return null;
    }

    static StepState State(ChatItem item, IReadOnlyDictionary<string, ChatItem> results, ChatItem? open, string? activity)
    {
        if (item.T == "thinking") return StepState.None;
        if (StepResult(item, results) is ChatItem result) return result.IsError == true ? StepState.Failed : StepState.Ok;
        if (activity is null) return StepState.None;
        if (open?.Id == item.Id) return activity == "waiting" ? StepState.Waiting : activity == "busy" ? StepState.Running : StepState.None;
        return activity == "busy" ? StepState.Running : StepState.None;
    }
}
