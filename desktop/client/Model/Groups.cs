using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using static Kiteline.Lang;

namespace Kiteline.Model;

// 会话群（同 iOS 版 Model/Groups.swift；后台 groups.py / Mac 版 Groups.swift 存着，/api/groups + 实时通道的 groups、group_msg 事件）：
// 用户把几个会话（可以在不同电脑、不同项目里）拉进一个群，它们经 Kiteline 互相发消息协作；用户也在群里，能看到全部往来、直接发话。
// 成员会话全都关了 = 历史群；在历史群里发消息，后台会把成员会话恢复过来接着协作。

public sealed record GroupMember(string Key, string Title, string? Machine, string? Project, string? Agent)
{
    /// 「gpu-server · content-studio」
    public string Place => string.Join(" · ", new[] { Machine is null ? null : Lang.Machine(Machine), Project }.Where(s => !string.IsNullOrEmpty(s)));

    /// 现在叫什么：在跑的用会话列表里的标题（改过名的跟着变）
    public string Name => AppModel.Shared.Session(Key)?.Title ?? Title;

    public static GroupMember? Parse(JsonNode? n) =>
        n.Str("key") is string key ? new GroupMember(key, n.Str("title") ?? "", n.Str("machine"), n.Str("project"), n.Str("agent")) : null;
}

/// 群消息里的一张图 / 一个文件：Ref 是电脑上存的文件名，Name 是原名
public sealed record GroupMedia(string Ref, string Name, long Size)
{
    public const string Path = "/api/groups/media";

    public static List<GroupMedia> List(JsonNode? n) =>
        n is JsonArray list ? list.Items().Where(m => m.Str("ref") is not null).Select(m => new GroupMedia(m.Str("ref")!, m.Str("name") ?? "", (long)(m.Num("size") ?? 0))).ToList() : [];
}

public sealed class GroupMessage
{
    public string Id = "";
    public double Ts;
    /// 成员 key；me = 用户；system = 群提示
    public string From = "system";
    public string FromTitle = "", Text = "";
    public List<string>? To;
    /// 各收件成员的投递状态：pending / sent / filled / ended / paused / failed
    public Dictionary<string, string> States = new();
    public Dictionary<string, string> Notes = new();
    public string? ItemId, Event;
    public List<string> Args = [];
    /// 用户随消息发的图、文件（存在电脑上，经 /api/groups/media 取）
    public List<GroupMedia> Images = [], Files = [];

    public bool Mine => From == "me";
    public bool System => From == "system";

    public static GroupMessage? Parse(JsonNode? n)
    {
        if (n.Str("id") is not string id) return null;
        static Dictionary<string, string> Map(JsonNode? o) =>
            o is JsonObject obj ? obj.Where(p => p.Value is not null).ToDictionary(p => p.Key, p => p.Value!.ToString()) : new();
        return new GroupMessage
        {
            Id = id, Ts = n.Num("ts") ?? 0, From = n.Str("from") ?? "system", FromTitle = n.Str("fromTitle") ?? "", Text = n.Str("text") ?? "",
            To = n.Get("to") is JsonArray ? n.Strings("to") : null, States = Map(n.Get("states")), Notes = Map(n.Get("notes")),
            ItemId = n.Str("itemId"), Event = n.Str("event"), Args = n.Get("args") is JsonArray ? n.Strings("args") : [],
            Images = GroupMedia.List(n.Get("images")), Files = GroupMedia.List(n.Get("files")),
        };
    }

    /// 群提示显示成什么（按界面语言拼；不认识的种类用后台拼好的中文）
    public string EventText
    {
        get
        {
            var names = string.Join(L("、"), Args);
            return Event switch
            {
                "created" => L("建群：%@", names),
                "joined" => L("加入群：%@", names),
                "left" => L("移出群：%@", names),
                "renamed" => L("群名改为「%@」", names),
                "named" when Args.Count == 2 => L("%@ 给群起名「%@」", Args[0], Args[1]),
                "paused" => L("已暂停转发"),
                "resumed" => L("已继续转发"),
                "autopaused" => L("agent 之间已连续往来 %@ 条，已暂停转发；轻点「继续转发」接着投递", Args.FirstOrDefault() ?? ""),
                _ => Text,
            };
        }
    }
}

public sealed class GroupInfo
{
    public string Id = "", Name = "";
    /// Marked 标记（排最上面、群名后一颗星）、Muted 免打扰（agent 发言不推送）：同会话
    public bool AutoName, Paused, Marked, Muted;
    public string? Topic;
    public double CreatedAt, UpdatedAt;
    public int Count;
    public List<GroupMember> Members = [];
    public GroupMessage? Last;

    public GroupMember? Member(string key) => Members.FirstOrDefault(m => m.Key == key);

    /// 还有成员会话在跑的 = 进行中的群；全都关了 = 历史群
    public bool Live => Members.Any(m => AppModel.Shared.Session(m.Key) is not null);

    public static GroupInfo? Parse(JsonNode? n)
    {
        if (n.Str("id") is not string id) return null;
        return new GroupInfo
        {
            Id = id, Name = n.Str("name") ?? "", AutoName = n.Truthy("autoName"), Paused = n.Truthy("paused"), Topic = n.Str("topic"),
            Marked = n.Truthy("marked"), Muted = n.Truthy("muted"),
            CreatedAt = n.Num("createdAt") ?? 0, UpdatedAt = n.Num("updatedAt") ?? 0, Count = n.Int("count") ?? 0,
            Members = n.Arr("members").Items().Select(GroupMember.Parse).OfType<GroupMember>().ToList(), Last = GroupMessage.Parse(n.Get("last")),
        };
    }
}

/// 各群概要 + 打开过的群的消息（同 iOS 版 GroupBoard）
public sealed partial class GroupState : ObservableObject
{
    public static GroupState Shared { get; } = new();

    [ObservableProperty] IReadOnlyList<GroupInfo> items = [];
    /// 群 id → 全部消息（打开群时取一次，之后跟着 group_msg 事件加）；变了 Version 加一
    readonly Dictionary<string, List<GroupMessage>> messages = new();
    [ObservableProperty] int version;

    public GroupInfo? Group(string id) => Items.FirstOrDefault(g => g.Id == id);
    public IReadOnlyList<GroupMessage> Messages(string id) => messages.TryGetValue(id, out var list) ? list : [];
    public IEnumerable<GroupInfo> Containing(string key) => Items.Where(g => g.Member(key) is not null);

    /// 连着的后台能拉群（老版本没有，不给入口）：取过一次群列表就算
    [ObservableProperty] bool supported;

    public async Task Load()
    {
        try
        {
            Apply(await AppModel.Shared.Api.Get("/api/groups"));
            Supported = true;
        }
        catch (Exception) { }
    }

    /// groups 事件、/api/groups：整份换掉
    public void Apply(JsonNode? reply)
    {
        if (reply?.Get("items") is not JsonArray) return;
        Items = Ordered(reply.Arr("items").Items().Select(GroupInfo.Parse).OfType<GroupInfo>());
        foreach (var gone in messages.Keys.Where(id => Group(id) is null).ToList()) messages.Remove(gone);
        Supported = true;
    }

    /// 标记的排前面，再按最近动静
    static List<GroupInfo> Ordered(IEnumerable<GroupInfo> list) => list.OrderByDescending(g => g.Marked).ThenByDescending(g => g.UpdatedAt).ToList();

    /// group_msg 事件：一条新消息，或投递状态变了
    public void Receive(JsonNode? json)
    {
        if (json.Str("id") is not string id || GroupMessage.Parse(json.Get("message")) is not GroupMessage message) return;
        Upsert(id, message);
    }

    public async Task LoadMessages(string id)
    {
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/groups/messages", new Dictionary<string, string> { ["id"] = id });
            messages[id] = reply.Arr("items").Items().Select(GroupMessage.Parse).OfType<GroupMessage>().ToList();
            Version++;
        }
        catch (Exception) { }
    }

    void Upsert(string id, GroupMessage message)
    {
        if (messages.TryGetValue(id, out var list))
        {
            var index = list.FindIndex(m => m.Id == message.Id);
            if (index >= 0) list[index] = message;
            else { list.Add(message); list.Sort((a, b) => a.Ts.CompareTo(b.Ts)); }
        }
        if (Group(id) is GroupInfo group && !message.System && (group.Last?.Ts ?? 0) <= message.Ts) group.Last = message;
        Version++;
    }

    // MARK: 操作

    /// 建群，返回群 id
    public async Task<string?> Create(IEnumerable<string> keys, string topic)
    {
        try
        {
            var reply = await AppModel.Shared.Api.Post("/api/groups/create", new JsonObject { ["keys"] = new JsonArray(keys.Select(k => (JsonNode)k).ToArray()), ["topic"] = topic });
            await Load();
            return reply.Get("group").Str("id");
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); return null; }
    }

    public Task<bool> Add(string id, IEnumerable<string> keys) => Call("/api/groups/add", new JsonObject { ["id"] = id, ["keys"] = new JsonArray(keys.Select(k => (JsonNode)k).ToArray()) });
    public Task<bool> Remove(string id, string key) => Call("/api/groups/remove", new JsonObject { ["id"] = id, ["key"] = key });
    public Task<bool> Rename(string id, string name) => Call("/api/groups/rename", new JsonObject { ["id"] = id, ["name"] = name });
    public Task<bool> Pause(string id, bool paused) => Call("/api/groups/pause", new JsonObject { ["id"] = id, ["paused"] = paused });
    public Task<bool> Delete(string id) => Call("/api/groups/delete", new JsonObject { ["id"] = id });

    /// 标记 / 免打扰：先在本机改（星星、铃铛立刻变），后台没接住再改回来；不用重取列表（后台会推 groups 事件）
    public async void Mark(string id, bool on) => await Flag(id, "/api/groups/mark", "marked", on, (g, v) => g.Marked = v);
    public async void Mute(string id, bool on) => await Flag(id, "/api/groups/mute", "muted", on, (g, v) => g.Muted = v);

    async Task Flag(string id, string path, string field, bool on, Action<GroupInfo, bool> set)
    {
        if (Group(id) is not GroupInfo group) return;
        set(group, on);
        Items = Ordered(Items);
        try { await AppModel.Shared.Api.Post(path, new JsonObject { ["id"] = id, [field] = on }); }
        catch (Exception e)
        {
            set(group, !on);
            Items = Ordered(Items);
            AppModel.Shared.Flash(e.Message);
        }
    }

    /// 后台能在群里收图、文件（老版本只收文字：输入栏不给「+」选图）
    public static bool MediaSupported => AppModel.Shared.Features.Contains("groupMedia");

    /// 在群里发话（可带图）：发给全部成员（或 to 里的几个）；关了的成员后台会先恢复它
    public async Task<bool> Send(string id, string text, IReadOnlyCollection<string>? to, IReadOnlyList<ComposeAttachment>? images = null)
    {
        var body = new JsonObject { ["id"] = id, ["text"] = text };
        if (to is { Count: > 0 }) body["to"] = new JsonArray(to.Select(k => (JsonNode)k).ToArray());
        if (images is { Count: > 0 })
            body["images"] = new JsonArray(images.Select(i => (JsonNode)new JsonObject { ["name"] = i.Name, ["data"] = Convert.ToBase64String(i.Data) }).ToArray());
        try
        {
            var reply = await AppModel.Shared.Api.Post("/api/groups/send", body);
            if (GroupMessage.Parse(reply.Get("message")) is GroupMessage message) Upsert(id, message);
            return true;
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); return false; }
    }

    async Task<bool> Call(string path, JsonObject body)
    {
        try
        {
            var reply = await AppModel.Shared.Api.Post(path, body);
            if (path == "/api/groups/delete") Apply(reply); else await Load();
            if (body["id"]?.ToString() is string id && Group(id) is not null) await LoadMessages(id);
            return true;
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); return false; }
    }
}

/// 后台送进会话的群消息认出来（同 iOS 版 GroupText）：群名、带没带群说明、一条条谁说了什么
public static class GroupText
{
    public sealed record Part(string Who, string Text);
    public sealed record Inbound(string Name, bool Brief, List<Part> Parts);

    public static Inbound? Parse(string? text)
    {
        if (text is null || !(text.StartsWith("【Kiteline 会话群「") || text.StartsWith("【群「"))) return null;
        string name = "";
        bool brief = false, inBrief = false;
        var parts = new List<Part>();
        (string Who, string Text)? current = null;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith("【Kiteline 会话群「")) { name = Between(line, "「", "」"); brief = inBrief = true; continue; }
            if (inBrief) { if (line.Length == 0) inBrief = false; continue; }
            var close = line.IndexOf('】');
            if (line.StartsWith("【群「") && close > 0)
            {
                if (current is { } c) parts.Add(new Part(c.Who, c.Text.Trim()));
                var head = line[..close];
                if (name.Length == 0) name = Between(head, "「", "」");
                var at = head.IndexOf("」· ", StringComparison.Ordinal);
                var rest = line[(close + 1)..];
                current = (at >= 0 ? head[(at + 3)..] : "", rest.StartsWith("（只发给你）") ? "" : rest);
                continue;
            }
            if (line.StartsWith("（回复群里：")) continue;
            if (current is { } cur) current = (cur.Who, cur.Text.Length == 0 ? raw : cur.Text + "\n" + raw);
        }
        if (current is { } last) parts.Add(new Part(last.Who, last.Text.Trim()));
        return name.Length == 0 ? null : new Inbound(name, brief, parts);
    }

    static string Between(string text, string open, string close)
    {
        var a = text.IndexOf(open, StringComparison.Ordinal);
        if (a < 0) return "";
        var b = text.IndexOf(close, a + open.Length, StringComparison.Ordinal);
        return b < 0 ? "" : text[(a + open.Length)..b];
    }
}
