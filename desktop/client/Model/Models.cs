using System.Globalization;
using System.Text.Json.Nodes;
using static Kiteline.Lang;

namespace Kiteline.Model;

// 后台的数据（/api/state、/api/events、/api/history），同 iOS 版 Model/Models.swift。
// 字段一律可选、缺了就用默认值

public sealed record Usage(int? Context, int? Window, string? Model, int? Percent)
{
    public static Usage? Parse(JsonNode? n) => n is JsonObject ? new Usage(n.Int("context"), n.Int("window"), n.Str("model"), n.Int("percent")) : null;
}

/// 排队等 Claude 读的一条消息（Id 是电脑上排队用的编号）
public sealed record QueuedItem(string Id, string Text);

public sealed record SessionInfo
{
    public string Key { get; init; } = "";
    public string Title { get; init; } = "";
    public string SourceId { get; init; } = "";
    public string SourceName { get; init; } = "";
    public string? SourceKind { get; init; }
    /// waiting（等你确认）/ busy（正在工作）/ idle / unknown
    public string Activity { get; init; } = "unknown";
    public string? ActivityText { get; init; }
    public string? Blocking { get; init; }
    public string? Reason { get; init; }
    public string? Preview { get; init; }
    public string? PendingTool { get; init; }
    public bool CanReply { get; init; }
    public string? Cwd { get; init; }
    public double? UpdatedAt { get; init; }
    public double? StartedAt { get; init; }
    public Usage? Usage { get; init; }
    public string? Error { get; init; }
    public string? Effort { get; init; }
    public bool? Ultracode { get; init; }
    /// 权限模式：default / acceptEdits / plan / auto / bypassPermissions
    public string? PermissionMode { get; init; }
    public string? CwdShort { get; init; }
    public int Subagents { get; init; }
    /// 会话里开着几个终端（终端按钮的角标）
    public int Terminals { get; init; }
    /// 只能看、不能远程操作（Proma 这类没有对外接口的）
    public bool ReadOnly { get; init; }
    /// 只读时给用户看的一句话（插件给）
    public string? ReadOnlyReason { get; init; }
    /// 哪个编程 agent 的会话（claude-code / codex / opencode）
    public string Agent { get; init; } = Agents.DefaultId;
    /// 看、回复、确认、中断以外还能出的按钮，逗号隔开（同 iOS 版 caps）：mode / model / compact / subagents / tests。
    /// 按这个出按钮，不认 agent 名字；老版本后台不给：Claude Code 的会话全有，别家全没有
    public string Caps { get; init; } = "";
    /// 待确认卡片上的按钮（插件给），原样存成 JSON 文字：记录按值比较，存列表就每次都算「变了」
    public string? PendingOptionsJson { get; init; }
    /// 在那台电脑上的会话 id（代码 IDE 里认「哪个会话在哪个分支」用）
    public string? SessionId { get; init; }
    /// 工作目录所在的 git 分支；在附加的工作树里时 Worktree 是那个工作树的目录
    public string? Branch { get; init; }
    public string? Worktree { get; init; }
    /// 这一轮任务做到第几步（「2/4 开发中」，见 StageInfo）：后台只在忙、等确认时给，老版本后台没有
    public StageInfo? Stage { get; init; }
    /// 目标（/goal，见 GoalInfo）：agent 围着它跨多轮一直做；没设目标、老版本后台没有
    public GoalInfo? Goal { get; init; }
    /// 远端电脑上、在 VS Code 里跑的 Claude Code，能转到后台运行（对话页提示「支持后台托管」，见 Views/HostedSetup.cs）
    public bool Hostable { get; init; }
    /// 最后一次在任何一端看过这个会话的时间（毫秒，同 iOS 版 viewedAt）：「新消息」按它和本机记的取较晚的算
    public double? ViewedAt { get; init; }
    /// 最近一轮是别的会话来信引起的（会话之间的往来、群消息）：不算给你的新消息
    public bool FromPeer { get; init; }
    /// 列表里显示的目标：还在做的一直显示；结束了的（达成、做不到）一小时内还显示
    public GoalInfo? ListGoal => Goal is { } g && (g.Running || g.At is double at && Format.NowMs - at < 3_600_000) ? g : null;

    public bool IsWaiting => Activity == "waiting";
    /// 正在做（忙、等确认）才显示阶段
    public StageInfo? LiveStage => IsBusy || IsWaiting ? Stage : null;
    public bool IsBusy => Activity == "busy";
    /// 只用来挑说法（「等同于在 VS Code 中按 Esc」）；功能有没有一律看 Can
    public bool IsClaude => Agent == Agents.DefaultId;
    public bool Can(string cap) => Caps.Split(',').Contains(cap);
    public IReadOnlyList<PendingOption>? PendingOptions => PendingOption.ParseList(PendingOptionsJson);
    /// Claude 忙时发的、排队等它读的消息（原样存 JSON，记录相等比较才不会每次都算变了）；null = 电脑端或会话里的插件是老版本，只能强插、改不了
    public string? QueueJson { get; init; }
    public IReadOnlyList<QueuedItem>? Queue => QueueJson is null ? null
        : (JsonNode.Parse(QueueJson) as JsonArray ?? []).Select(n => n.Str("id") is { } id && n.Str("text") is { } text ? new QueuedItem(id, text) : null)
            .OfType<QueuedItem>().ToList();
    /// 不能回复时输入框里的说明：插件给的优先
    public string ReadOnlyNote => ReadOnlyReason ?? (IsClaude ? L("终端会话需在 tmux 中运行才能回复") : L("仅可查看，请在 %@ 中回复", Speaker));
    public const string ClaudeCaps = "mode,model,compact,subagents,tests";
    public string Speaker => Agents.Info(Agent).Speaker;
    /// 项目文件夹名
    public string Folder => Path.GetFileName((Cwd ?? "").TrimEnd('/', '\\'));

    public static SessionInfo? Parse(JsonNode? n)
    {
        var key = n.Str("key");
        if (string.IsNullOrEmpty(key)) return null;
        var agent = n.Str("agent");
        var claude = string.IsNullOrEmpty(agent) || agent == Agents.DefaultId;
        var options = n.Arr("pendingOptions");
        return new SessionInfo
        {
            Key = key,
            Title = n.Str("title") ?? n.Str("name") ?? L("会话"),
            SourceId = n.Str("sourceId") ?? "",
            SourceName = Lang.Machine(n.Str("sourceName") ?? ""),
            SourceKind = n.Str("sourceKind"),
            Activity = n.Str("activity") ?? "unknown",
            ActivityText = n.Str("activityText"),
            Blocking = n.Str("blocking"),
            Reason = n.Str("reason"),
            Preview = n.Str("preview"),
            PendingTool = n.Str("pendingTool"),
            CanReply = n.Bool("canReply") ?? false,
            Cwd = n.Str("cwd"),
            UpdatedAt = n.Num("updatedAt"),
            StartedAt = n.Num("startedAt"),
            Usage = Usage.Parse(n.Get("usage")),
            Error = n.Str("error"),
            Effort = n.Str("effort"),
            Ultracode = n.Bool("ultracode"),
            PermissionMode = n.Str("permissionMode"),
            CwdShort = n.Str("cwdShort"),
            Subagents = n.Int("subagents") ?? 0,
            Terminals = n.Int("terminals") ?? 0,
            ReadOnly = n.Bool("readOnly") ?? false,
            ReadOnlyReason = n.Str("readOnlyReason") is { Length: > 0 } reason ? reason : null,
            Agent = string.IsNullOrEmpty(agent) ? Agents.DefaultId : agent,
            Caps = n.Get("caps") is JsonArray ? string.Join(",", n.Strings("caps").Order()) : claude ? ClaudeCaps : "",
            PendingOptionsJson = options is { Count: > 0 } ? options.ToJsonString() : null,
            QueueJson = n.Get("queue") is JsonArray queue ? queue.ToJsonString() : null,
            SessionId = n.Str("sessionId"),
            Branch = n.Str("branch") is { Length: > 0 } branch ? branch : null,
            Worktree = n.Str("worktree") is { Length: > 0 } tree ? tree : null,
            Stage = StageInfo.Parse(n.Get("stage")),
            Goal = GoalInfo.Parse(n.Get("goal")),
            Hostable = n.Bool("hostable") ?? false,
            ViewedAt = n.Num("viewedAt"),
            FromPeer = n.Bool("fromPeer") ?? false,
        };
    }
}

/// 目标（/goal；Claude Code 2.1.139 起、Codex 0.128 起，同 iOS 版 GoalViews.swift 的 GoalInfo）：agent 围着一个目标跨多轮一直做，
/// 每轮结束检查一次，确认达成才停。State：active 进行中 / paused 停下了（发消息继续）/ blocked 受阻 / limited 额度或预算用完 /
/// met 已达成 / failed 无法达成 / error 出错中止。Reason 是最近一次检查的说法（还差什么），Note 是停下的原因
public sealed record GoalInfo(string Text, string State, int? Checks, string? Reason, string? Note, double? Since, double? At,
    int? Turns, double? DurationMs, int? Tokens, int? Budget)
{
    public bool Running => State is "active" or "paused" or "blocked" or "limited";
    /// 正在第几轮（检查过 n 次没达成 = 在做第 n+1 轮）；没有检查次数的（Codex）不说
    public int? Round => Checks is int c ? (Running ? c + 1 : Math.Max(1, c)) : null;
    /// 同一个目标的标识（收起结束提示时记它）
    public string Id => $"{(long)(Since ?? 0)}|{(Text.Length > 60 ? Text[..60] : Text)}";

    /// 一共做了多久（秒）：结束了的用记下的；还在做的从设定算到现在
    public int? Seconds(double now)
    {
        if (DurationMs is double ms && ms > 0 && (!Running || Since is null)) return (int)(ms / 1000);
        if (Since is not double since) return DurationMs is double d ? (int)(d / 1000) : null;
        var end = Running ? now : At ?? since;
        return (int)Math.Max(0, (end - since) / 1000);
    }

    public static GoalInfo? Parse(JsonNode? n)
    {
        if (n is not JsonObject || n.Str("text") is not { Length: > 0 } text) return null;
        return new GoalInfo(text, n.Str("state") ?? "active", n.Int("checks"), n.Str("reason") is { Length: > 0 } r ? r : null,
            n.Str("note") is { Length: > 0 } note ? note : null, n.Num("since"), n.Num("at"), n.Int("turns"), n.Num("durationMs"), n.Int("tokens"), n.Int("budget"));
    }
}

/// 任务做到第几步（同 iOS 版 StageViews.swift 的 StageInfo；watcher 按工具调用推断，或 agent 用 stage 命令报的）：
/// 列表里「正在工作」前的「2/4 开发中」、对话页上的任务进展。步骤名、走过的步骤存成文字：记录按值比较，存列表就每次都算「变了」
/// 任务分了几部分（几个端）时 Part 是正在做的那部分，PartsText 每行「名字\t第几步\t做完没有」；Step 这些说的是正在做的那部分
public sealed record StageInfo(int Step, int Total, string Label, string Steps, double? Since, double? TurnAt, string? Note, bool Auto, string Marks,
                               string? Part = null, string PartsText = "")
{
    /// 「2/4 开发中」、分了部分的「iPhone · 2/4 开发中」（步骤名按界面语言换，agent 自定的原样）
    public string Short => (Part is null ? "" : Part + " · ") + $"{Step}/{Total} {L(Label)}";
    /// 哪部分、第几步、名字、说明：变了任务进展条才重建
    public string Token => $"{Part}/{Step}/{Total}/{Label}/{Note}";

    /// 各部分：名字、做到第几步（0 = 还没开始）、做完没有；正在做的那部分的第几步用 Step
    public IReadOnlyList<(string Name, int Step, bool Done)> Parts =>
        PartsText.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => line.Split('\t'))
            .Where(f => f.Length == 3).Select(f => (f[0], f[0] == Part ? Step : int.TryParse(f[1], out var n) ? n : 0, f[2] == "1")).ToList();

    /// 第几步（从 0 数）叫什么：当前这步用 Label（第 4 步按在做的事是「汇报中」或「发布中」），其余用流程里的名字
    public string Name(int index)
    {
        if (index == Step - 1) return L(Label);
        var names = Steps.Split('\n');
        return index < names.Length ? L(names[index]) : (index + 1).ToString();
    }

    /// 这一轮里每一步累计用了多久（秒）；没走到过的是 null。来回走过的（测完又改）加在一起
    public int?[] Seconds(double nowMs)
    {
        var output = new int?[Total];
        var list = new List<(int Step, double At)>();
        foreach (var mark in Marks.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = mark.Split(':');
            if (parts.Length == 2 && int.TryParse(parts[0], out var s) && double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var at))
                list.Add((s, at));
        }
        if (list.Count == 0) list.Add((Step, Since ?? TurnAt ?? nowMs));
        for (var i = 0; i < list.Count; i++)
        {
            var index = list[i].Step - 1;
            if (index < 0 || index >= Total) continue;
            var end = i + 1 < list.Count ? list[i + 1].At : nowMs;
            output[index] = (output[index] ?? 0) + (int)Math.Max(0, (end - list[i].At) / 1000);
        }
        return output;
    }

    public static StageInfo? Parse(JsonNode? n)
    {
        if (n is not JsonObject || n.Int("step") is not int step || n.Int("total") is not int total || n.Str("label") is not { Length: > 0 } label) return null;
        if (total < 2 || step < 1 || step > total) return null;
        var marks = n.Arr("marks") is JsonArray list
            ? string.Join(";", list.OfType<JsonArray>().Where(m => m.Count == 2 && J.AsNumber(m[0]) is not null && J.AsNumber(m[1]) is not null)
                .Select(m => $"{(int)J.AsNumber(m[0])!.Value}:{J.AsNumber(m[1])!.Value.ToString(CultureInfo.InvariantCulture)}"))
            : "";
        var parts = n.Arr("parts") is JsonArray partList
            ? partList.OfType<JsonObject>().Where(p => p.Str("name") is { Length: > 0 })
                .Select(p => $"{p.Str("name")!.Replace("\t", " ").Replace("\n", " ")}\t{p.Int("step") ?? 0}\t{((p.Bool("done") ?? false) ? 1 : 0)}").ToList()
            : [];
        var part = parts.Count >= 2 && n.Str("part") is { Length: > 0 } name && parts.Any(p => p.StartsWith(name + "\t")) ? name : null;
        return new StageInfo(step, total, label, string.Join("\n", n.Strings("steps")), n.Num("since"), n.Num("turnAt"),
            n.Str("note") is { Length: > 0 } note ? note : null, n.Bool("auto") ?? true, marks, part, part is null ? "" : string.Join("\n", parts));
    }
}

/// 待确认卡片上的一个按钮（插件给）：Key 是点了发回后台的按键，Style 为 primary 主按钮 / destructive 拒绝 / normal 次要
public sealed record PendingOption(string Key, string Label, string Style)
{
    public static IReadOnlyList<PendingOption>? ParseList(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try
        {
            var list = (JsonNode.Parse(json) as JsonArray).Items()
                .Select(o => o.Str("key") is { Length: > 0 } key && o.Str("label") is { Length: > 0 } label ? new PendingOption(key, label, o.Str("style") ?? "normal") : null)
                .OfType<PendingOption>().ToList();
            return list.Count > 0 ? list : null;
        }
        catch (Exception) { return null; }
    }
}

/// Hosted：这台能后台运行 Claude Code 时才有，on / off（按设备开，见 Views/HostedSetup.cs）；本机、Windows、老版本后台没有
public sealed record SourceInfo(string Id, string Name, string? Kind, bool Online, string? Status, string? Hosted = null)
{
    public static SourceInfo? Parse(JsonNode? n) =>
        n.Str("id") is string id ? new SourceInfo(id, Lang.Machine(n.Str("name") ?? id), n.Str("kind"), n.Bool("online") ?? false, n.Str("status"), n.Str("hosted")) : null;
}

public sealed record Me(string? Name, string? Avatar)
{
    public static Me? Parse(JsonNode? n) => n is JsonObject ? new Me(n.Str("name"), n.Str("avatar")) : null;
}

public sealed record MachineStats(double? Cpu, int? Cores, double? MemTotal, double? MemUsed)
{
    public static MachineStats? Parse(JsonNode? n) => n is JsonObject ? new MachineStats(n.Num("cpu"), n.Int("cores"), n.Num("memTotal"), n.Num("memUsed")) : null;

    public double? MemRatio => MemUsed is double used && MemTotal is double total && total > 0 ? Math.Clamp(used / total, 0, 1) : null;

    public string Summary
    {
        get
        {
            var parts = new List<string>();
            if (Cpu is double cpu) parts.Add($"CPU {MachineFormat.Percent(cpu)}" + (Cores is int c ? L("（%@ 核）", c) : ""));
            if (MemUsed is double used && MemTotal is double total)
                parts.Add(L("内存已用 %@，共 %@，可用 %@", MachineFormat.Gigabytes(used), MachineFormat.Gigabytes(total), MachineFormat.Gigabytes(total - used)));
            return string.Join(L("，"), parts);
        }
    }
}

public static class MachineFormat
{
    public static string Percent(double ratio) => $"{(int)Math.Round(ratio * 100)}%";

    /// 按 1024 进位：10 GB 以上取整，以下留一位
    public static string Gigabytes(double bytes)
    {
        var value = Math.Max(bytes, 0) / 1_073_741_824;
        return value >= 10 ? $"{value:0} GB" : $"{value:0.0} GB";
    }
}

/// 用户给某个会话（或某家 agent 的全部会话）设的头像和昵称（同 Mac 版 AgentFace）：电脑上存着，/api/state 的 faces 带来。
/// avatar 的写法：mark:<agentId|kite>:<底色> / emoji:<表情>:<底色> / text:<底色> / image:<id>；空 = agent 自己的标志
public sealed record AgentFace(string Name, string Avatar)
{
    public bool IsEmpty => Name.Length == 0 && Avatar.Length == 0;

    public static AgentFace? Parse(JsonNode? n) => n is JsonObject ? new(n.Str("name") ?? "", n.Str("avatar") ?? "") : null;
}

/// /api/state 的 faces：会话自己的（按会话 key）、某家 agent 默认的（按 agent id）
public sealed class FacesPayload
{
    public Dictionary<string, AgentFace> Sessions { get; } = new();
    public Dictionary<string, AgentFace> Agents { get; } = new();

    /// 某个会话现在用的：会话自己的优先，没有就用这家 agent 默认的
    public AgentFace? Face(string key, string agent) => Sessions.GetValueOrDefault(key) ?? Agents.GetValueOrDefault(agent);

    public static FacesPayload Parse(JsonNode? n)
    {
        var faces = new FacesPayload();
        foreach (var (field, into) in new[] { ("sessions", faces.Sessions), ("agents", faces.Agents) })
            if (n.Obj(field) is JsonObject map)
                foreach (var (id, value) in map)
                    if (AgentFace.Parse(value) is AgentFace face) into[id] = face;
        return faces;
    }

    public bool SameAs(FacesPayload other) =>
        Sessions.Count == other.Sessions.Count && Agents.Count == other.Agents.Count
        && Sessions.All(p => other.Sessions.GetValueOrDefault(p.Key) == p.Value) && Agents.All(p => other.Agents.GetValueOrDefault(p.Key) == p.Value);
}

public sealed class StatePayload
{
    public string? Host, Version, Platform;
    public FacesPayload? Faces;
    public List<SessionInfo>? Sessions;
    public List<SourceInfo>? Sources;
    public List<string>? QuickReplies, Muted, Pinned, Marked;
    /// 后台能做的（同 iOS 版 hostFeatures）：groupMedia = 群里能发图、文件
    public List<string>? Features;
    /// 「支持后台运行 Claude Code」的提示选了不再提示（state 的 hosted.tipOff）
    public bool? HostedTipOff;
    public Me? Me;
    public bool? SubmitOnSend, QuietActive;
    public Dictionary<string, MachineStats>? Sys;

    public static StatePayload Parse(JsonNode? n)
    {
        var state = new StatePayload
        {
            Host = n.Str("host"),
            Version = n.Str("version"),
            Platform = n.Str("platform"),
            Me = Me.Parse(n.Get("me")),
            SubmitOnSend = n.Bool("submitOnSend"),
            QuietActive = n.Bool("quietActive"),
        };
        // 插件给的 agent 名称和标志先登记，下面的会话（新 agent 的）显示时就画得出来
        if (n.Arr("agents") is JsonArray agents) Agents.Register(agents.Items());
        if (n.Arr("sessions") is JsonArray sessions) state.Sessions = sessions.Items().Select(SessionInfo.Parse).OfType<SessionInfo>().ToList();
        if (n.Arr("sources") is JsonArray sources) state.Sources = sources.Items().Select(SourceInfo.Parse).OfType<SourceInfo>().ToList();
        if (n.Get("quickReplies") is JsonArray) state.QuickReplies = n.Strings("quickReplies");
        if (n.Get("features") is JsonArray) state.Features = n.Strings("features");
        if (n.Obj("hosted") is JsonObject hosted) state.HostedTipOff = hosted.Bool("tipOff") ?? false;
        if (n.Get("muted") is JsonArray) state.Muted = n.Strings("muted");
        if (n.Get("pinned") is JsonArray) state.Pinned = n.Strings("pinned");
        if (n.Get("marked") is JsonArray) state.Marked = n.Strings("marked");
        if (n.Obj("faces") is JsonObject faces) state.Faces = FacesPayload.Parse(faces);
        if (n.Obj("sys") is JsonObject sys)
        {
            state.Sys = new();
            foreach (var (id, value) in sys)
                if (MachineStats.Parse(value) is MachineStats stats) state.Sys[id] = stats;
        }
        return state;
    }
}

/// 连着的是哪种电脑。界面文字一律写「电脑」；客户端本身就跑在 Windows / Linux 上，只有 macOS 独有的操作路径看它
public static class HostPlatform
{
    public static string Current { get; set; } = "";
    public static bool IsMac => Current == "" || Current == "macos";
}

public sealed record ChatImage(string Ref, string? Mime, string? Name)
{
    public static ChatImage? Parse(JsonNode? n) => n.Str("ref") is string r ? new ChatImage(r, n.Str("mime"), n.Str("name")) : null;
}

/// 关键信息里的一项：名称 + 值；Secret（密码、令牌）默认遮住，点一下才显示
public sealed record KeyField(string? Name, string? Value, bool Secret);

/// 对话里的一条：user（我说的）/ text（Claude 回复）/ thinking / tool（调用工具）/ result（工具结果）/
/// agent_image（Claude 发来的图）/ event（系统提示，比如用量到上限）
public sealed class ChatItem : IEquatable<ChatItem>
{
    public string T = "";
    public string Id = "";
    public double? Ts;
    public string? Text, Name, ToolId, Brief, Level, Detail;
    public JsonNode? Input;
    public bool? IsError, Truncated, Queued;
    public double? ResetAt;
    public int? FullLength;
    public List<ChatImage>? Images;
    /// Claude 的回复里认出来的「需要你来做」的事：消息下面问一句「加入待办？」
    public List<string>? Asks;
    /// 会话之间的消息：发出的那步（tool SendMessage）、收到的那条（event）带着，见 Model/Peers.cs
    public PeerInfo? Peer;
    /// SendMessage 的结果里的 msg_id（和收信那边配对）
    public string? MsgId;
    /// agent 经待办技能记的待办（agent_todo）：要你自己动手的事
    public bool? ForUser;
    /// agent 发来的关键信息（agent_key）：标题、一项项的值、补充说明；Text 是拼好的纯文字（收藏、复制用）
    public string? Title, Note;
    /// agent 发来的网页（agent_page）：标题在 Title，一句说明在这里，网页本身在 Images 里（照图片的路子取）
    public string? Caption;
    public List<KeyField>? Fields;
    /// agent 发到会话群的（group_say）：哪个群、只发给了谁（成员 key）
    public string? Group;
    public List<string>? To;
    /// 目标的那几行提示（event）：set / check / met / failed / paused / cleared / error；达成、做不到的带用了几轮、多久、多少 token
    public string? Goal;
    public int? GoalTurns, GoalTokens;
    public double? GoalMs;
    /// 原样的 JSON：比较两条是不是同一份内容（同 Swift 的 Hashable）
    public string Raw = "";

    public static ChatItem? Parse(JsonNode? n)
    {
        if (n is not JsonObject || n.Str("id") is not string id || n.Str("t") is not string t) return null;
        return new ChatItem
        {
            T = t,
            Id = id,
            Ts = n.Num("ts"),
            Text = n.Str("text"),
            Name = n.Str("name"),
            ToolId = n.Str("toolId"),
            Input = n.Get("input")?.DeepClone(),
            Brief = n.Str("brief"),
            IsError = n.Bool("isError"),
            Images = n.Arr("images") is JsonArray images ? images.Items().Select(ChatImage.Parse).OfType<ChatImage>().ToList() : null,
            Level = n.Str("level"),
            ResetAt = n.Num("resetAt"),
            Detail = n.Str("detail"),
            Truncated = n.Bool("truncated"),
            FullLength = n.Int("fullLength"),
            Queued = n.Bool("queued"),
            Asks = n.Get("asks") is JsonArray ? n.Strings("asks") : null,
            Peer = PeerInfo.Parse(n.Get("peer")),
            MsgId = n.Str("msgId"),
            ForUser = n.Bool("forUser"),
            Title = n.Str("title"),
            Note = n.Str("note"),
            Caption = n.Str("caption"),
            Fields = n.Arr("fields") is JsonArray fields ? fields.Items().Select(f => new KeyField(f.Str("name"), f.Str("value"), f.Truthy("secret"))).ToList() : null,
            Group = n.Str("group"),
            To = n.Get("to") is JsonArray ? n.Strings("to") : null,
            Goal = n.Str("goal"),
            GoalTurns = n.Get("goalStats").Int("turns"),
            GoalTokens = n.Get("goalStats").Int("tokens"),
            GoalMs = n.Get("goalStats").Num("durationMs"),
            Raw = n.ToJsonString(),
        };
    }

    /// 排序：时间 → transcript 里的偏移 → 同一行里的第几块（id 形如「偏移.序号」，Claude 发图的是 o 开头）
    public long Offset => Id.StartsWith('o') ? 0 : long.TryParse(Id.Split('.')[0], out var o) ? o : 0;
    public int Sub => Id.Split('.') is { Length: > 1 } parts && int.TryParse(parts[1], out var s) ? s : 0;

    public static int Compare(ChatItem a, ChatItem b)
    {
        var ta = a.Ts ?? 0; var tb = b.Ts ?? 0;
        if (ta != tb) return ta.CompareTo(tb);
        if (a.Offset != b.Offset) return a.Offset.CompareTo(b.Offset);
        return a.Sub.CompareTo(b.Sub);
    }

    public bool Equals(ChatItem? other) => other is not null && Id == other.Id && Raw == other.Raw;
    public override bool Equals(object? obj) => Equals(obj as ChatItem);
    public override int GetHashCode() => HashCode.Combine(Id, Raw);
}

/// 后台推来的提醒（需要你确认、有结论了……）
public sealed record NotifyEvent(string? Title, string? Body, string? Key, string? Kind, string? Route, bool Inbox, string? ItemId)
{
    public static NotifyEvent Parse(JsonNode? n)
    {
        var key = n.Str("key");
        var route = n.Str("route");
        // inbox 是收件箱里那条的 id（字符串，没记就是空串）或者 true / false：按「有没有」算
        var inbox = n.Get("inbox") is JsonNode i && (J.AsString(i) is string s ? s != "" && s != "false" : false);
        return new NotifyEvent(n.Str("title"), n.Str("body"), string.IsNullOrEmpty(key) ? null : key, n.Str("kind"),
                               string.IsNullOrEmpty(route) ? null : route, inbox, n.Str("itemId"));
    }
}

/// 已经结束的会话（历史会话、打开它时标题栏用）
public sealed record PastSession(string Key, string Title, string? Cwd, string SourceName, string? FirstPrompt, double? LastActive, bool Live, string? Activity)
{
    public static PastSession? Parse(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var sourceId = n.Str("sourceId") ?? "";
        var key = n.Str("key") ?? $"{sourceId}#{n.Str("sessionId") ?? ""}";
        var cwd = n.Str("cwd");
        var first = n.Str("firstPrompt");
        return new PastSession(key, n.Str("title") ?? first ?? (cwd is null ? L("会话") : Path.GetFileName(cwd.TrimEnd('/'))),
                               cwd, Lang.Machine(n.Str("sourceName") ?? ""), first, n.Num("lastActive"), n.Truthy("live"), n.Str("activity"));
    }

    public string DisplayTitle => Title;
}
