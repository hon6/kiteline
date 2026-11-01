using System.Text.Json.Nodes;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using Kiteline.Net;
using static Kiteline.Lang;

namespace Kiteline.Model;

/// 整个客户端的状态：会话列表、各会话的对话、和本机后台的实时连接，以及发消息、点允许这些操作（同 iOS 版 AppModel）。
/// 都在界面线程上改
public sealed partial class AppModel : ObservableObject
{
    public static AppModel Shared { get; private set; } = null!;

    public Api Api { get; }

    // 后台推来的状态（/api/state、事件流 state）
    [ObservableProperty] string host = "";
    [ObservableProperty] string version = "";
    [ObservableProperty] IReadOnlyList<SessionInfo> sessions = [];
    [ObservableProperty] IReadOnlyList<SourceInfo> sources = [];
    [ObservableProperty] Me? me;
    [ObservableProperty] IReadOnlyList<string> quickReplies = [];
    /// 后台能做的（state 的 features）：老版本后台没有的功能不给入口
    public IReadOnlyList<string> Features { get; private set; } = [];
    [ObservableProperty] IReadOnlyList<string> pinned = [];
    /// 标记的会话（新标记的在前）：所有列表最上面，不受分组限制；关闭会话、会话结束时电脑端自动取消
    [ObservableProperty] IReadOnlyList<string> marked = [];
    /// 用户给会话、给某家 agent 设的头像和昵称（Agent 详情里改的，见 Views/AgentDetails.cs）
    [ObservableProperty] FacesPayload faces = new();
    [ObservableProperty] IReadOnlySet<string> muted = new HashSet<string>();
    [ObservableProperty] bool quietActive;
    /// 各台机器的 CPU、内存（来源 id → 数据，sys 事件每 5 秒一条）
    public Dictionary<string, MachineStats> MachineStats { get; } = new();
    public event Action? MachineStatsChanged;

    // 连接
    [ObservableProperty] bool connected;
    [ObservableProperty] bool everConnected;
    [ObservableProperty] string? connectionError;

    /// 正在看的会话（分屏时是当前块）
    public string? Current { get; set; }
    readonly Dictionary<string, int> openCounts = new();
    /// 窗口在前台时收到的提醒，弹成横幅
    [ObservableProperty] NotifyEvent? banner;
    /// 一闪而过的提示
    [ObservableProperty] string? toast;
    /// 超过每日花费上限、问一句「仍然发送吗」
    [ObservableProperty] (string Key, string Id, string Message)? capPrompt;
    /// 通知收件箱里还没看过的条数
    [ObservableProperty] int inboxUnread;
    /// 新建任务后等新会话出现，出现了就自动打开
    [ObservableProperty] string? pendingOpen;

    readonly Dictionary<string, ChatStore> chats = new();
    readonly Dictionary<string, PastSession> pastMeta = new();
    public IReadOnlyDictionary<string, PastSession> PastMeta => pastMeta;
    /// 打开某个会话时要跳到的那条（历史搜索的命中、待办出处）
    public Dictionary<string, string> JumpRequests { get; } = new();
    (string SourceId, string Cwd, HashSet<string> Known, DateTime Until)? awaitNew;
    /// 输入框里没发出去的话：列表里显示「[草稿]」
    readonly Dictionary<string, string> drafts;
    readonly Dictionary<string, double> seen;
    CancellationTokenSource? streamCancel;
    bool needResync;
    DispatcherTimer? toastTimer;
    /// 开着的对话页定时报「打开过」（见 ReportViewed）
    DispatcherTimer? viewedTimer;

    public event Action<string, JsonNode?>? TodosEvent;
    /// 收藏变了（整份，见 FavoriteState）
    public event Action<string, JsonNode?>? FavoritesEvent;

    public AppModel(Api api)
    {
        Api = api;
        Shared = this;
        seen = Prefs.NumberMap("seen");
        drafts = Prefs.StringMap("drafts");
        // 换了界面语言：实时连接按新语言重连（后台在出口按连接的语言翻译状态、提示），重连后整份状态重新拉一遍
        Lang.Changed += () =>
        {
            if (streamCancel is null) return;
            Stop();
            Start();
        };
    }

    // MARK: 草稿

    public string? Draft(string key) => drafts.TryGetValue(key, out var d) ? d : null;

    public void SetDraft(string key, string text)
    {
        var clean = string.IsNullOrWhiteSpace(text) ? null : text;
        if (Draft(key) == clean) return;
        if (clean is null) drafts.Remove(key); else drafts[key] = clean;
        Prefs.Set("drafts", drafts);
        OnPropertyChanged(nameof(Drafts));
    }

    public IReadOnlyDictionary<string, string> Drafts => drafts;

    // MARK: 查询

    public SessionInfo? Session(string key) => Sessions.FirstOrDefault(s => s.Key == key);

    public ChatStore Chat(string key)
    {
        if (!chats.TryGetValue(key, out var chat)) chats[key] = chat = new ChatStore(key);
        return chat;
    }

    public bool IsPinned(string key) => Pinned.Contains(key);
    public bool IsMarked(string key) => Marked.Contains(key);

    /// 这个会话的助手现在用的头像昵称（会话自己的 → 这家 agent 默认的；都没设为 null）
    public AgentFace? Face(string key) => Faces.Face(key, Session(key)?.Agent ?? Agents.DefaultId);

    /// /api/agent-face 存完回来的整份 faces：马上换上（不等下一次状态推送）
    public void SetFaces(JsonNode? reply) => Faces = FacesPayload.Parse(new JsonObject
    {
        ["sessions"] = reply.Obj("sessions")?.DeepClone() ?? new JsonObject(),
        ["agents"] = reply.Obj("agents")?.DeepClone() ?? new JsonObject(),
    });
    public bool IsMuted(string key) => Muted.Contains(key);

    /// 标记的永远排最前（新标记的在上），然后是置顶的（按置顶顺序），其余看排序方式：
    /// started 开始时间（新的在上）/ recent 最近活动 / status 状态优先（等你确认 → 出错 → 在跑 → 空闲）/ name 名称。最后按 key 定死先后
    public List<SessionInfo> SortedSessions(string order, IEnumerable<SessionInfo>? source = null)
    {
        static double Rank(SessionInfo s) => s.Error is not null ? 0.5 : s.Activity switch { "waiting" => 0, "busy" => 1, "idle" => 2, _ => 3 };
        var pins = Pinned.ToList();
        var marks = Marked.ToList();
        int Pin(SessionInfo s) { var i = pins.IndexOf(s.Key); return i < 0 ? int.MaxValue : i; }
        int Mark(SessionInfo s) { var i = marks.IndexOf(s.Key); return i < 0 ? int.MaxValue : i; }
        var list = (source ?? Sessions).ToList();
        list.Sort((a, b) =>
        {
            if (Mark(a) != Mark(b)) return Mark(a).CompareTo(Mark(b));
            if (Pin(a) != Pin(b)) return Pin(a).CompareTo(Pin(b));
            switch (order)
            {
                case "recent":
                    if ((a.UpdatedAt ?? 0) != (b.UpdatedAt ?? 0)) return (b.UpdatedAt ?? 0).CompareTo(a.UpdatedAt ?? 0);
                    break;
                case "status":
                    if (Rank(a) != Rank(b)) return Rank(a).CompareTo(Rank(b));
                    if ((a.UpdatedAt ?? 0) != (b.UpdatedAt ?? 0)) return (b.UpdatedAt ?? 0).CompareTo(a.UpdatedAt ?? 0);
                    break;
                case "name":
                    var c = string.Compare(a.Title, b.Title, StringComparison.CurrentCultureIgnoreCase);
                    if (c != 0) return c;
                    break;
                default:
                    if ((a.StartedAt ?? 0) != (b.StartedAt ?? 0)) return (b.StartedAt ?? 0).CompareTo(a.StartedAt ?? 0);
                    break;
            }
            return string.CompareOrdinal(a.Key, b.Key);
        });
        return list;
    }

    public bool IsUnread(SessionInfo s) => !IsOpen(s.Key) && (s.UpdatedAt ?? 0) > (seen.TryGetValue(s.Key, out var v) ? v : 0) && !s.IsBusy;

    /// 这个会话正开在屏幕上（分屏里的任一块）
    public bool IsOpen(string key) => openCounts.TryGetValue(key, out var n) && n > 0;

    public void MarkSeen(string key)
    {
        seen[key] = Math.Max(Format.NowMs, Session(key)?.UpdatedAt ?? 0);
        Prefs.Set("seen", seen);
    }

    /// 某台机器现在的 CPU、内存：连着、这台机器在线才给
    public MachineStats? LiveStats(string sourceId)
    {
        if (!Connected || !(Sources.FirstOrDefault(s => s.Id == sourceId)?.Online ?? true)) return null;
        return MachineStats.TryGetValue(sourceId, out var stats) ? stats : null;
    }

    public void RememberPast(PastSession session) => pastMeta[session.Key] = session;

    public async Task LoadPastMeta(string key)
    {
        if (Session(key) is not null || pastMeta.ContainsKey(key)) return;
        try
        {
            var reply = await Api.Get("/api/session-meta", new Dictionary<string, string> { ["key"] = key });
            if (PastSession.Parse(reply.Get("session")) is PastSession past) { pastMeta[key] = past; OnPropertyChanged(nameof(PastMeta)); }
        }
        catch (Exception) { }
    }

    /// 新建任务开始了：等这个项目里冒出一个新会话，3 分钟内出现就自动打开
    public void AwaitNewSession(string sourceId, string cwd) =>
        awaitNew = (sourceId, cwd, Sessions.Select(s => s.Key).ToHashSet(), DateTime.Now.AddMinutes(3));

    void CheckAwaitNew()
    {
        if (awaitNew is not { } wait) return;
        if (DateTime.Now > wait.Until) { awaitNew = null; return; }
        var hit = Sessions.FirstOrDefault(s => !wait.Known.Contains(s.Key) && s.SourceId == wait.SourceId && (s.Cwd == wait.Cwd || (s.Cwd ?? "").StartsWith(wait.Cwd + "/")));
        if (hit is null) return;
        awaitNew = null;
        Flash(L("新会话已开始"));
        PendingOpen = hit.Key;
    }

    // MARK: 连接

    public void Start()
    {
        if (streamCancel is not null) return;
        streamCancel = new CancellationTokenSource();
        _ = Connect(streamCancel.Token);
        viewedTimer ??= new DispatcherTimer(TimeSpan.FromMinutes(10), DispatcherPriority.Background, (_, _) => { if (WindowShown()) ReportViewed(); });
        viewedTimer.Start();
    }

    public void Stop()
    {
        viewedTimer?.Stop();
        streamCancel?.Cancel();
        streamCancel = null;
        Connected = false;
        needResync = true;
    }

    async Task Connect(CancellationToken cancel)
    {
        var delay = 1.0;
        while (!cancel.IsCancellationRequested)
        {
            try
            {
                var opened = false;
                await foreach (var (name, data) in Api.Events(cancel))
                {
                    if (!opened)
                    {
                        opened = true;
                        delay = 0.3;
                        Opened();
                    }
                    Handle(name, data);
                }
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { return; }
            catch (Exception e)
            {
                ConnectionError = e.Message;
            }
            Connected = false;
            needResync = true;
            try { await Task.Delay(TimeSpan.FromSeconds(delay), cancel); }
            catch (OperationCanceledException) { return; }
            delay = Math.Min(Math.Max(delay * 2, 1), 15);
        }
    }

    void Opened()
    {
        Connected = true;
        EverConnected = true;
        ConnectionError = null;
        Terminal.TerminalStore.Shared.Reconnected();
        FlushQueued();
        _ = RefreshInbox();
        _ = PeerBoard.Shared.Load(Api);
        Avalonia.Threading.Dispatcher.UIThread.Post(() => _ = GroupState.Shared.Load());   // 会话群（老版本后台没有这个接口：取不到就不给入口）
        if (needResync)
        {
            needResync = false;
            Resync();
        }
    }

    void Handle(string name, string data)
    {
        var json = J.Parse(data);
        switch (name)
        {
            case "state":
                Apply(StatePayload.Parse(json));
                break;
            case "entries":
                if (json.Str("key") is string key)
                {
                    var chat = Chat(key);
                    var items = json.Arr("items").Items().Select(ChatItem.Parse).OfType<ChatItem>().ToList();
                    chat.Add(items);
                }
                break;
            case "reset":
                if (json.Str("key") is string reset && chats.TryGetValue(reset, out var c))
                {
                    c.Reset();
                    if (IsOpen(reset)) _ = LoadHistory(reset, false);
                }
                break;
            case "notify":
                var note = NotifyEvent.Parse(json);
                if (note.Inbox) InboxUnread++;
                if (note.Key is null || !IsOpen(note.Key)) Banner = note;
                break;
            case "todos":
                TodosEvent?.Invoke(name, json);
                break;
            case "favorites":
                FavoritesEvent?.Invoke(name, json);
                break;
            case "peers":
                PeerBoard.Shared.Receive(json);
                break;
            case "groups":
                Avalonia.Threading.Dispatcher.UIThread.Post(() => GroupState.Shared.Apply(json));
                break;
            case "group_msg":
                Avalonia.Threading.Dispatcher.UIThread.Post(() => GroupState.Shared.Receive(json));
                break;
            case "term" or "term_exit":
                Terminal.TerminalStore.Shared.Receive(name, json);
                break;
            case "world_intent":
                // 浏览器窗口里的世界点了屏幕 / 卫星 / 门（网页经后台转回来，见 Views/WorldView.cs）
                Avalonia.Threading.Dispatcher.UIThread.Post(() => Views.World.Intent(json));
                break;
            case "plugin_error":
                // Agent 插件出错：弹窗问要不要发报告（同一个错后台只推一次）
                Avalonia.Threading.Dispatcher.UIThread.Post(() => Views.PluginReport.Ask(json));
                break;
            case "sys":
                if (json.Str("id") is string id && Model.MachineStats.Parse(json.Get("stats")) is MachineStats stats)
                {
                    MachineStats[id] = stats;
                    MachineStatsChanged?.Invoke();
                }
                break;
        }
    }

    void Apply(StatePayload state)
    {
        Host = state.Host ?? Host;
        Version = state.Version ?? Version;
        HostPlatform.Current = state.Platform ?? "";
        var incoming = state.Sessions ?? [];
        // 和上次一模一样就不换：换了的话所有读 Sessions 的界面都要重算
        if (!incoming.SequenceEqual(Sessions)) Sessions = incoming;
        var sources = state.Sources ?? [];
        if (!sources.SequenceEqual(Sources)) Sources = sources;
        if (state.Sys is { } sys)
        {
            MachineStats.Clear();
            foreach (var (k, v) in sys) MachineStats[k] = v;
            MachineStatsChanged?.Invoke();
        }
        if (Me != state.Me) Me = state.Me;
        var quick = state.QuickReplies ?? [];
        if (!quick.SequenceEqual(QuickReplies)) QuickReplies = quick;
        if (state.Features is { } features) Features = features;
        var pins = state.Pinned ?? [];
        if (!pins.SequenceEqual(Pinned)) Pinned = pins;
        if (state.Marked is { } marks && !marks.SequenceEqual(Marked)) Marked = marks;
        if (state.Faces is { } faces && !faces.SameAs(Faces)) Faces = faces;
        var muted = (state.Muted ?? []).ToHashSet();
        if (!muted.SetEquals(Muted)) Muted = muted;
        QuietActive = state.QuietActive ?? false;
        // 第一次见到的会话不算未读，之后有新动静才亮红点
        var changed = false;
        foreach (var s in Sessions)
            if (!seen.ContainsKey(s.Key)) { seen[s.Key] = s.UpdatedAt ?? Format.NowMs; changed = true; }
        if (changed) Prefs.Set("seen", seen);
        foreach (var key in openCounts.Keys.ToList())
            if (Session(key) is not null) MarkSeen(key);
        CheckAwaitNew();
    }

    /// 断线重连：中间的变化可能漏了，重新拉列表和正在看的会话的最新一页
    public async void Resync()
    {
        await Refresh();
        foreach (var key in openCounts.Keys.ToList())
            if (Chat(key).Loaded) await LoadHistory(key, false);
    }

    public async Task Refresh()
    {
        try { Apply(StatePayload.Parse(await Api.Get("/api/state"))); }
        catch (Exception e) { Show(e); }
    }

    public async Task LoadHistory(string key, bool older)
    {
        var chat = Chat(key);
        if (chat.Loading || (older && !chat.HasMore)) return;
        chat.Loading = true;
        try
        {
            var query = new Dictionary<string, string> { ["key"] = key, ["limit"] = "60" };
            if (older)
            {
                if (chat.OldestOffset is long offset) query["before"] = offset.ToString();
                if (chat.OldestTs is double ts) query["beforeTs"] = ((long)ts).ToString();
            }
            var page = await Api.Get("/api/history", query);
            var items = page.Arr("items").Items().Select(ChatItem.Parse).OfType<ChatItem>().ToList();
            if (older || !chat.Loaded) chat.HasMore = (page.Bool("hasMore") ?? false) && items.Count > 0;
            chat.Loaded = true;
            chat.Add(items);
        }
        catch (Exception e) { Show(e); }
        finally { chat.Loading = false; }
    }

    /// 打开一个会话：离开超过 10 分钟的，标出「以下是新消息」。分屏里不是当前块的（focus = false）不抢朗读
    public void Open(string key, bool focus = true)
    {
        openCounts[key] = (openCounts.TryGetValue(key, out var n) ? n : 0) + 1;
        if (focus || Current is null) Current = key;
        var chat = Chat(key);
        chat.NewSince = seen.TryGetValue(key, out var last) && Format.NowMs - last > 10 * 60 * 1000 ? last : null;
        MarkSeen(key);
        ReportViewed([key]);
        _ = LoadHistory(key, false);
        _ = LoadVoices(key);
    }

    /// 告诉后台这几个会话的详情打开过：后台会把 24 小时没在 Kiteline 里打开过详情的会话自动关掉、移进历史（idleclose.py / Mac 的 IdleClose）。
    /// 对话页打开时报一次；开着、窗口在屏幕上（没最小化、没收进托盘）时每 10 分钟再报一次。
    /// 只报人打开着的对话页：别的会话发来消息、它在后台回复，都不经过这里
    public void ReportViewed(IEnumerable<string>? keys = null)
    {
        var list = (keys ?? openCounts.Keys).ToList();
        if (list.Count == 0) return;
        _ = PostViewed(new JsonObject { ["keys"] = new JsonArray(list.Select(k => (JsonNode?)JsonValue.Create(k)).ToArray()) });
    }

    async Task PostViewed(JsonObject body)
    {
        try { await Api.Post("/api/viewed", body); }
        catch (Exception) { }   // 旧版后台没有这个接口
    }

    static bool WindowShown() =>
        Avalonia.Application.Current?.ApplicationLifetime is Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime life
        && life.Windows.Any(w => w.IsVisible && w.WindowState != Avalonia.Controls.WindowState.Minimized);

    /// 只在打开对话页时取：后台把这个请求也当「打开过详情」（不报 /api/viewed 的旧版靠它），别处别调
    async Task LoadVoices(string key)
    {
        try
        {
            var reply = await Api.Get("/api/voices", new Dictionary<string, string> { ["key"] = key });
            var chat = Chat(key);
            foreach (var entry in reply.Arr("voices").Items())
                if (entry.Str("id") is string id && entry.Str("text") is string text)
                    chat.Voices[text.Trim()] = new VoiceClip(id, entry.Num("duration") ?? 0);
            chat.Touch();
        }
        catch (Exception) { }
    }

    public void Close(string key)
    {
        var left = (openCounts.TryGetValue(key, out var n) ? n : 1) - 1;
        if (left > 0) openCounts[key] = left; else openCounts.Remove(key);
        if (Current == key && left <= 0) Current = openCounts.Keys.FirstOrDefault();
        MarkSeen(key);
    }

    // MARK: 操作

    static string NewId() => Convert.ToString(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), 16) + Random.Shared.Next(1_000_000).ToString("x");

    /// 发消息（可带图）。会话已经结束的，后台会先在 VS Code 里恢复这段对话再发。返回这条的 id
    public string Send(string key, string text, IReadOnlyList<ComposeAttachment> images)
    {
        var id = NewId();
        Chat(key).AddPending(new PendingSend
        {
            Id = id, Text = text, Previews = images.Select(i => i.Preview).ToList(),
            Payload = images.Select(i => new Dictionary<string, string> { ["name"] = i.Name, ["data"] = Convert.ToBase64String(i.Data) }).ToList(),
        });
        _ = Deliver(key, id);
        return id;
    }

    /// 听写、按住说话：录音交给后台转写，转写完直接发
    public void SendVoice(string key, byte[] audio, double duration, IReadOnlyList<ComposeAttachment> images)
    {
        var id = NewId();
        Chat(key).AddPending(new PendingSend
        {
            Id = id, Voice = duration, Audio = audio, Previews = images.Select(i => i.Preview).ToList(),
            Payload = images.Select(i => new Dictionary<string, string> { ["name"] = i.Name, ["data"] = Convert.ToBase64String(i.Data) }).ToList(),
        });
        _ = Deliver(key, id);
    }

    /// 只转写、不发送：文字放进输入框给你改了再发
    public async Task<string?> Transcribe(byte[] audio)
    {
        try
        {
            var reply = await Api.Post("/api/voice", new Dictionary<string, object> { ["data"] = Convert.ToBase64String(audio), ["mime"] = "audio/wav", ["mode"] = "text" });
            return reply.Str("text");
        }
        catch (Exception e) { Show(e); return null; }
    }

    public void Discard(string key, string id) => Chat(key).RemovePending(p => p.Id == id);

    public void Retry(string key, string id, bool overrideCap = false)
    {
        Chat(key).Update(id, p => p with { State = SendState.Sending, Error = null, Override = overrideCap || p.Override });
        _ = Deliver(key, id);
    }

    async Task Deliver(string key, string id)
    {
        var chat = Chat(key);
        var p = chat.Pending.FirstOrDefault(x => x.Id == id);
        if (p is null) return;
        var live = Session(key) is not null;
        try
        {
            JsonNode? reply;
            if (p.Audio is byte[] audio)
            {
                reply = await Api.Post("/api/voice", new Dictionary<string, object>
                {
                    ["data"] = Convert.ToBase64String(audio), ["mime"] = "audio/wav", ["duration"] = p.Voice ?? 0, ["mode"] = "send", ["images"] = p.Payload,
                }, new Dictionary<string, string> { ["key"] = key });
                if (reply.Str("text") is string text)
                {
                    chat.Update(id, x => x with { Text = text });
                    if (reply.Str("voiceId") is string voiceId) chat.Voices[text.Trim()] = new VoiceClip(voiceId, p.Voice ?? 0);
                    chat.SettleAgain();
                }
            }
            else
            {
                reply = await Api.Post(live ? "/api/send" : "/api/resume", new Dictionary<string, object>
                {
                    ["text"] = p.Text, ["images"] = p.Payload, ["override"] = p.Override, ["cid"] = p.Id,
                }, new Dictionary<string, string> { ["key"] = key });
            }
            var submitted = reply.Bool("submitted") ?? false;
            chat.Update(id, x => x with { State = submitted ? SendState.Sent : SendState.Filled });
            if (!submitted) Flash(reply.Str("message") ?? L("已填入 VS Code 输入框，未提交"));
            // 发给空闲的会话：15 秒后 Claude 还没动、对话里也没出现这条，多半没提交上（回车被输入法拿去上屏拼音之类），
            // 标出来，别让它两分钟后悄悄消失（同 Mac 版）。斜杠命令不回显成消息，不算
            if (submitted && live && Session(key) is { IsBusy: false, IsWaiting: false }
                && !(chat.Pending.FirstOrDefault(x => x.Id == id)?.Text ?? "").StartsWith('/'))
            {
                _ = Task.Delay(TimeSpan.FromSeconds(15)).ContinueWith(_ =>
                {
                    if (Session(key) is { IsBusy: false, IsWaiting: false } && chat.Pending.Any(x => x.Id == id && x.State == SendState.Sent))
                        chat.Update(id, x => x with { State = SendState.Unconfirmed });
                }, TaskScheduler.FromCurrentSynchronizationContext());
            }
            // 等对话记录回显来撤掉占位；万一没回显，两分钟后也撤掉（没提交上的留着，等用户自己移除）
            _ = Task.Delay(TimeSpan.FromMinutes(2)).ContinueWith(_ => chat.RemovePending(x => x.Id == id && !x.IsFailed && x.State != SendState.Unconfirmed),
                TaskScheduler.FromCurrentSynchronizationContext());
        }
        catch (OfflineError)
        {
            chat.Update(id, x => x with { State = SendState.Queued });   // 连不上后台：排队，连上后自动发
        }
        catch (ApiError e)
        {
            chat.Update(id, x => x with { State = SendState.Failed, Error = e.Message });
            if (e.Body.Bool("capExceeded") == true) CapPrompt = (key, id, e.Message);
        }
        catch (Exception e)
        {
            chat.Update(id, x => x with { State = SendState.Failed, Error = e.Message });
        }
    }

    /// 连上了：把离线时排队的消息依次发出去
    void FlushQueued()
    {
        foreach (var (key, chat) in chats)
            foreach (var p in chat.Pending.Where(p => p.State == SendState.Queued).ToList()) Retry(key, p.Id);
    }

    /// 确认框上的按键：1 允许 / 2 总是允许 / esc 拒绝或中断 / enter 确认
    public async Task<bool> Press(string key, string button, string label)
    {
        try
        {
            await Api.Post("/api/key", new Dictionary<string, object> { ["key"] = button }, new Dictionary<string, string> { ["key"] = key });
            Flash(label);
            return true;
        }
        catch (Exception e) { Show(e); return false; }
    }

    /// 关闭会话：后台关掉它在 VS Code 里的标签页（终端里发 /exit），会话进「历史会话」（同 iOS 版 AppModel.close）
    public async Task<bool> CloseSession(string key)
    {
        try
        {
            var reply = await Api.Post("/api/close", new Dictionary<string, object>(), new Dictionary<string, string> { ["key"] = key });
            Flash(reply.Str("message") ?? L("已关闭会话"));
            return true;
        }
        catch (Exception e) { Show(e); return false; }
    }

    public async Task<bool> Answer(string key, ChatItem tool, List<Dictionary<string, object>> answers)
    {
        try
        {
            var reply = await Api.Post("/api/answer", new Dictionary<string, object> { ["answers"] = answers, ["toolId"] = tool.ToolId ?? "" },
                                       new Dictionary<string, string> { ["key"] = key });
            Flash(reply.Bool("submitted") == true ? L("已回答") : reply.Str("message") ?? L("已填入"));
            return true;
        }
        catch (Exception e) { Show(e); return false; }
    }

    public async void SetPinned(string key, bool on)
    {
        try
        {
            await Api.Post("/api/pin", new Dictionary<string, object> { ["key"] = key, ["pinned"] = on });
            Pinned = on ? [key, .. Pinned.Where(k => k != key)] : Pinned.Where(k => k != key).ToList();
        }
        catch (Exception e) { Show(e); }
    }

    /// 标记 / 取消标记：先在本机改（星星立刻亮 / 灭），电脑没接住再改回来
    public async void SetMarked(string key, bool on)
    {
        var before = Marked;
        Marked = on ? [key, .. Marked.Where(k => k != key)] : Marked.Where(k => k != key).ToList();
        try { await Api.Post("/api/mark", new Dictionary<string, object> { ["key"] = key, ["marked"] = on }); }
        catch (Exception e) { Marked = before; Show(e); }
    }

    public async void SetMuted(string key, bool on)
    {
        try
        {
            await Api.Post("/api/mute", new Dictionary<string, object> { ["key"] = key, ["muted"] = on });
            var next = Muted.ToHashSet();
            if (on) next.Add(key); else next.Remove(key);
            Muted = next;
        }
        catch (Exception e) { Show(e); }
    }

    // MARK: 通知收件箱

    double InboxSeen => Prefs.Number("inboxSeen") ?? 0;

    public async Task RefreshInbox()
    {
        try
        {
            var reply = await Api.Get("/api/inbox", new Dictionary<string, string> { ["limit"] = "100", ["since"] = ((long)InboxSeen).ToString() });
            InboxUnread = reply.Arr("entries")?.Count ?? 0;
        }
        catch (Exception) { }
    }

    public void MarkInboxSeen(double latest)
    {
        if (latest > InboxSeen) Prefs.Set("inboxSeen", latest);
        InboxUnread = 0;
    }

    // MARK: 提示

    public void Flash(string text)
    {
        Toast = text;
        toastTimer ??= new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        toastTimer.Stop();
        toastTimer.Tick -= ClearToast;
        toastTimer.Tick += ClearToast;
        toastTimer.Start();
    }

    void ClearToast(object? sender, EventArgs e)
    {
        toastTimer?.Stop();
        Toast = null;
    }

    public void Show(Exception error) => Flash(error.Message);
}
