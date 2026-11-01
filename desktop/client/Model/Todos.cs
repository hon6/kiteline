using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using static Kiteline.Lang;

namespace Kiteline.Model;

/// 待办出自哪条消息；Cwd、Agent 是那个会话的项目目录、哪个 agent（新后台才给，agent 的待办按项目、按 Agent 分组用）
public sealed record TodoSource(string Key, string ItemId, string Title, string? Machine, double? Ts, string? Cwd = null, string? Agent = null);

/// agent 的待办现在是哪个会话在处理
public sealed record TodoHandler(string Key, string Title, string? Machine, string? Cwd = null, string? Agent = null);

/// 一条待办（同 iOS 版 TodoItem）：附的截图在 /api/todos/media?ref=。Detail 说明（agent 记的时候写的）、ForUser 只有你能做的（agent 提醒你、你加进来的）、
/// Agent agent 记的；agent 自己的待办另有 Ref 编号、Status（pending / doing / done）、Progress 进度、Handler 在处理的会话
public sealed record TodoItem(string Id, string Text, bool Done, double CreatedAt, double? DoneAt, TodoSource? Source, IReadOnlyList<ChatImage> Images,
                              string? Detail = null, bool ForUser = false, bool Agent = false,
                              string? Ref = null, string? Status = null, string? Progress = null, TodoHandler? Handler = null, double? UpdatedAt = null)
{
    /// agent 自己的待办（它自己会做，你只看是哪个会话在处理、到哪一步了）；其余是我的待办
    public bool AgentTask => Agent && !ForUser;
    /// 待办上直接显示「创建会话」：agent 自己的、还没做完（没人接着做时自己开个会话交代下去）
    public bool SuggestsSession => AgentTask && !Done;
    /// 新会话的任务内容：标题 + 说明
    public string Task => string.IsNullOrEmpty(Detail) ? Text : Text + "\n\n" + Detail;

    public const string MediaPath = "/api/todos/media";
    public static Dictionary<string, string> MediaQuery(string reference) => new() { ["key"] = "todos", ["ref"] = reference };

    public static TodoItem? Parse(JsonNode? n)
    {
        if (n is null) return null;
        TodoSource? source = null;
        if (n.Obj("source") is JsonNode s && s.Str("key") is string key)
            source = new TodoSource(key, s.Str("itemId") ?? "", s.Str("title") ?? "", (s.Str("machine") is string m1 ? Lang.Machine(m1) : null), s.Num("ts"),
                                    s.Str("cwd"), s.Str("agent"));
        TodoHandler? handler = n.Obj("handler") is JsonNode h && h.Str("key") is string hk
            ? new TodoHandler(hk, h.Str("title") ?? "", h.Str("machine") is string m3 ? Lang.Machine(m3) : null, h.Str("cwd"), h.Str("agent")) : null;
        return new TodoItem(n.Str("id") ?? Guid.NewGuid().ToString(), n.Str("text") ?? "", n.Truthy("done"), n.Num("createdAt") ?? 0, n.Num("doneAt"),
                            source, n.Arr("images").Items().Select(ChatImage.Parse).OfType<ChatImage>().ToList(),
                            n.Str("detail"), n.Truthy("forUser"), n.Truthy("agent"),
                            n.Str("ref"), n.Str("status"), n.Str("progress"), handler, n.Num("updatedAt"));
    }
}

/// agent 提醒你做的事（只有你能做的，如注册账号、申请密钥），还没决定「现在处理」还是「加入待办」
public sealed record TodoSuggestion(string Key, string ItemId, string Title, string? Machine, double? Ts, IReadOnlyList<string> Asks, double At, string? Detail = null)
{
    public string Id => $"{Key}|{ItemId}";

    public static TodoSuggestion? Parse(JsonNode? n) =>
        n.Str("key") is string key && n.Str("itemId") is string itemId
            ? new TodoSuggestion(key, itemId, n.Str("title") ?? "", (n.Str("machine") is string m2 ? Lang.Machine(m2) : null), n.Num("ts"), n.Strings("asks").ToList(), n.Num("at") ?? 0,
                                 n.Str("detail"))
            : null;
}

/// 「加入待办」面板要加的：出自哪条消息、认出来的几件事
public sealed record AddTodosRequest(string? Key, string? ItemId, string? Title, double? Ts, IReadOnlyList<string> Candidates);

/// 编辑面板里的一张截图：原来就有的（ref），或刚加的（压过的 JPEG + 小预览）
public sealed record TodoShot(string Id, ChatImage? Saved, byte[]? Jpeg, byte[]? Preview)
{
    public static TodoShot FromSaved(ChatImage image) => new(image.Ref, image, null, null);
    public static TodoShot FromNew(byte[] jpeg, byte[] preview) => new(Guid.NewGuid().ToString(), null, jpeg, preview);

    /// 发给电脑的样子：留下的给 ref，新加的给 data
    public JsonObject Payload => Saved is not null
        ? new JsonObject { ["ref"] = Saved.Ref }
        : new JsonObject { ["data"] = Convert.ToBase64String(Jpeg ?? []), ["mime"] = "image/jpeg" };
}

/// 我的待办 + Claude 说要你做、还没决定加不加的提示（同 iOS 版 Model/Todos.swift）；后台推 todos 事件、/api/todos 拉
public sealed partial class TodoState : ObservableObject
{
    public static TodoState Shared { get; } = new();

    [ObservableProperty] IReadOnlyList<TodoItem> items = [];
    [ObservableProperty] IReadOnlyList<TodoSuggestion> suggestions = [];
    /// 加过 / 忽略过的消息（"key|itemId"）：对话里不再问
    [ObservableProperty] IReadOnlySet<string> handled = new HashSet<string>();

    /// 我的未完成待办（角标、侧栏的数）：agent 的待办它自己会做，不算
    public int Open => Items.Count(i => !i.Done && !i.AgentTask);
    /// Claude 刚说、还没加的事一共几件
    public int Suggested => Suggestions.Sum(s => s.Asks.Count);

    /// 这条消息里的事加进来了几条
    public int Added(string key, string itemId) => Items.Count(i => i.Source?.Key == key && i.Source?.ItemId == itemId);
    public bool IsHandled(string key, string itemId) => Handled.Contains($"{key}|{itemId}");

    public void Apply(JsonNode? reply)
    {
        if (reply is null) return;
        if (reply.Get("items") is JsonArray) Items = reply.Arr("items").Items().Select(TodoItem.Parse).OfType<TodoItem>().ToList();
        if (reply.Get("suggestions") is JsonArray) Suggestions = reply.Arr("suggestions").Items().Select(TodoSuggestion.Parse).OfType<TodoSuggestion>().ToList();
        if (reply.Get("handled") is JsonArray) Handled = reply.Strings("handled").ToHashSet();
        OnPropertyChanged(nameof(Open));
    }

    public async Task Refresh()
    {
        try { Apply(await AppModel.Shared.Api.Get("/api/todos")); }
        catch (Exception) { }
    }

    /// 加几条；带 key + itemId 就记下出自哪条消息（这条消息算处理过，不再问）；附的截图跟着第一条
    public async Task<bool> Add(IEnumerable<string> texts, string? key = null, string? itemId = null, string? title = null, double? ts = null,
                                IReadOnlyList<TodoShot>? shots = null, string? detail = null, bool forUser = false, bool agent = false)
    {
        var clean = texts.Select(t => t.Trim()).Where(t => t.Length > 0).ToList();
        if (clean.Count == 0) return false;
        var body = new JsonObject { ["texts"] = new JsonArray(clean.Select(t => (JsonNode)t).ToArray()) };
        if (!string.IsNullOrEmpty(detail)) body["detail"] = detail;
        if (forUser) body["forUser"] = true;
        if (agent) body["agent"] = true;
        if (shots is { Count: > 0 }) body["images"] = new JsonArray(shots.Select(s => (JsonNode)s.Payload).ToArray());
        if (key is not null && itemId is not null)
        {
            body["key"] = key;
            body["itemId"] = itemId;
            body["title"] = title ?? AppModel.Shared.Session(key)?.Title ?? "";
            if (ts is double t) body["ts"] = t;
        }
        try
        {
            Apply(await AppModel.Shared.Api.Post("/api/todos/add", body));
            AppModel.Shared.Flash(clean.Count == 1 ? L("已加入待办") : L("已加入待办（%@ 项）", clean.Count));
            return true;
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); return false; }
    }

    public void SetDone(TodoItem item, bool done)
    {
        // 先在这边打上勾，电脑回来的整份再换掉
        Items = Items.Select(i => i.Id == item.Id ? i with { Done = done, DoneAt = done ? Format.NowMs : null } : i).ToList();
        OnPropertyChanged(nameof(Open));
        Request("/api/todos/update", new JsonObject { ["id"] = item.Id, ["done"] = done });
    }

    /// 改字、改截图（shots = 改完以后的整组）
    public async Task<bool> Edit(TodoItem item, string text, IReadOnlyList<TodoShot> shots)
    {
        var clean = text.Trim();
        if (clean.Length == 0) return false;
        var body = new JsonObject { ["id"] = item.Id, ["text"] = clean };
        if (!shots.Select(s => s.Id).SequenceEqual(item.Images.Select(i => i.Ref)))
            body["images"] = new JsonArray(shots.Select(s => (JsonNode)s.Payload).ToArray());
        try
        {
            Apply(await AppModel.Shared.Api.Post("/api/todos/update", body));
            return true;
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); return false; }
    }

    public void Delete(IEnumerable<string> ids)
    {
        var set = ids.ToHashSet();
        Items = Items.Where(i => !set.Contains(i.Id)).ToList();
        Request("/api/todos/delete", new JsonObject { ["ids"] = new JsonArray(set.Select(i => (JsonNode)i).ToArray()) });
    }

    public void ClearDone()
    {
        Items = Items.Where(i => !i.Done).ToList();
        Request("/api/todos/clear-done", new JsonObject());
    }

    /// 这条消息里的不加（对话里、待办页上不再问）
    public void Dismiss(string key, string itemId)
    {
        Suggestions = Suggestions.Where(s => !(s.Key == key && s.ItemId == itemId)).ToList();
        Handled = new HashSet<string>(Handled) { $"{key}|{itemId}" };
        Request("/api/todos/dismiss", new JsonObject { ["key"] = key, ["itemId"] = itemId });
    }

    /// 「全部忽略」：现在列着的都不加（只报看得见的这几条，刚冒出来的新提示不跟着丢）
    public void DismissAll()
    {
        var shown = Suggestions.ToList();
        if (shown.Count == 0) return;
        Handled = new HashSet<string>(Handled.Concat(shown.Select(s => s.Id)));
        Suggestions = [];
        Request("/api/todos/dismiss", new JsonObject
        {
            ["items"] = new JsonArray(shown.Select(s => (JsonNode)new JsonObject { ["key"] = s.Key, ["itemId"] = s.ItemId }).ToArray()),
        });
    }

    async void Request(string path, JsonObject body)
    {
        try { Apply(await AppModel.Shared.Api.Post(path, body)); }
        catch (Exception e)
        {
            AppModel.Shared.Flash(e.Message);
            await Refresh();
        }
    }

    /// agent 提醒你做的事：「加入待办」（说明一起带上，算我的待办）
    public Task<bool> AddSuggestion(TodoSuggestion s) =>
        Add(s.Asks.Take(1), s.Key, s.ItemId, s.Title, s.Ts, detail: s.Detail, forUser: true, agent: true);

    /// 「现在处理」：不加进待办（这条记为处理过），打开那个会话；处理好后回到会话告诉 agent
    public void HandleNow(string key, string itemId)
    {
        Dismiss(key, itemId);
        OpenSource(key, itemId);
    }

    /// 「回到会话」/「已处理好」：打开那个会话，输入框里先写好「已处理好：…」，用户确认后再发（不直接发，防点错）
    public static void ReplyDone(string key, string text)
    {
        if (string.IsNullOrWhiteSpace(AppModel.Shared.Draft(key))) AppModel.Shared.SetDraft(key, L("已处理好：%@", text));
        MainModel.Shared.Selection = key;
    }

    /// agent 的待办在哪台机器、哪个项目、哪个 agent（分组用，同 iPhone / Mac 版 todoPlace）：看在处理它的会话（没人接手就是记下它的），
    /// 后台没记的（老后台、早先记的）从还在的会话、看过的历史会话里补；都没有就是 null
    public static (string SourceId, string? Machine, string? Cwd, string? Agent) Place(TodoItem item)
    {
        var model = AppModel.Shared;
        var key = item.Handler?.Key ?? item.Source?.Key ?? "";
        var sourceId = key.IndexOf('#') is > 0 and var hash ? key[..hash] : "";
        var live = model.Session(key);
        var past = model.PastMeta.TryGetValue(key, out var p) ? p : null;
        var machine = item.Handler?.Machine ?? item.Source?.Machine ?? live?.SourceName ?? model.Sources.FirstOrDefault(s => s.Id == sourceId)?.Name;
        var cwd = item.Handler?.Cwd ?? (item.Handler is null ? item.Source?.Cwd : null) ?? live?.Cwd ?? past?.Cwd ?? item.Source?.Cwd;
        var agent = item.Handler?.Agent ?? (item.Handler is null ? item.Source?.Agent : null) ?? live?.Agent ?? item.Source?.Agent;
        return (sourceId, machine, string.IsNullOrEmpty(cwd) ? null : cwd, agent);
    }

    /// 跳到出自的那条消息：打开会话（已经结束的也行），滚到那条、闪一下
    /// 待办出自的会话在哪台机器的哪个目录（「创建会话」时选中原项目）
    public static (string SourceId, string Cwd)? Origin(TodoItem item)
    {
        if (item.Source?.Key is not string key || key.IndexOf('#') is not (> 0 and var hash)) return null;
        var cwd = AppModel.Shared.Session(key)?.Cwd ?? (AppModel.Shared.PastMeta.TryGetValue(key, out var past) ? past.Cwd : null);
        return cwd is null ? null : (key[..hash], cwd);
    }

    /// 「创建会话」：打开新建会话，内容带上这条待办、选好原项目，用户看过、改好再开始（不直接发，防点错）
    public static void CreateSession(TodoItem item) => Views.NewTaskSheet.Open(Origin(item), item.Task);

    public static void OpenSource(string key, string itemId)
    {
        AppModel.Shared.JumpRequests[key] = itemId;
        MainModel.Shared.Selection = key;
    }
}
