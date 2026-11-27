using System.Text;
using System.Text.Json.Nodes;
using Avalonia.Threading;
using Kiteline.Views;
using Kiteline.Views.Code;
using static Kiteline.Lang;

namespace Kiteline.Model;

/// 新版界面（同 Mac 版 11-20 起的新版界面，见 docs/platforms/mac-app.md「新版界面」）：经典界面原样留着做默认，窗口右上角一个按钮切到新版。
/// 新版 = 最左一条图标栏 + 一栏内容（会话 / 项目 / 待办 / 收藏）+ 底部状态栏；分屏上面一排项目，每个项目一套标签
public static class Layout
{
    /// 用的是新版界面（偏好 newLayout，默认经典）
    public static bool New => Prefs.Bool("newLayout");
    /// 换了界面（主窗口整个重搭）
    public static event Action? Changed;
    /// 图标栏换了一栏、项目栏选了别的项目
    public static event Action? SideChanged;

    public static void Set(bool on)
    {
        if (on == New) return;
        // 两套界面各有一套分屏：经典 = 「全部」那一套；新版 = 上次看的项目那一套（切回经典时放回经典那一套，同 Mac）
        if (on)
        {
            Prefs.Set("newLayout", true);
            ProjectSpaces.Enter();
        }
        else
        {
            ProjectSpaces.Leave();
            Prefs.Set("newLayout", false);
        }
        Changed?.Invoke();
    }

    /// 图标栏上面四项决定这一栏列什么：sessions 会话 / projects 项目 / todos 待办 / favorites 收藏（同 Mac 版 KitelineModel.sideTab）
    public static string SideTab
    {
        get => Prefs.String("sideTab") is "projects" or "todos" or "favorites" ? Prefs.String("sideTab")! : "sessions";
        set { if (value == SideTab) return; Prefs.Set("sideTab", value); SideChanged?.Invoke(); }
    }

    /// 项目栏里选中的项目（ProjectInfo.Id；空 = 没选）
    public static string OpenProject
    {
        get => Prefs.String("openProject") ?? "";
        set { if (value == OpenProject) return; Prefs.Set("openProject", value); SideChanged?.Invoke(); }
    }

    public static void NotifySide() => SideChanged?.Invoke();
}

/// 一个项目（某台电脑上的一个工作目录），项目栏和顶上那排项目用；同 ProjectsPage 的 ProjectItem，多记一份缓存
public static class ProjectList
{
    public static List<ProjectItem> Items { get; private set; } = Cached();
    public static bool Loaded { get; private set; }
    public static event Action? Changed;
    static int seq;
    static DispatcherTimer? timer;

    /// 上次读到的先显示（同 Mac 的 projects-cache.json：重启后先给上次的、后台刷新，电脑还没连上时读回来的空结果不盖缓存）
    static List<ProjectItem> Cached()
    {
        try
        {
            return Prefs.Node("projectsCache") is JsonArray arr ? arr.Select(ProjectItem.Parse).OfType<ProjectItem>().ToList() : [];
        }
        catch { return []; }
    }

    public static void Start()
    {
        if (timer is not null) return;
        timer = new DispatcherTimer(TimeSpan.FromSeconds(120), DispatcherPriority.Background, (_, _) => Load());
        timer.Start();
        AppModel.Shared.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppModel.Connected) && AppModel.Shared.Connected) Load(); };
        Load();
    }

    public static async void Load()
    {
        var current = ++seq;
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/projects", new Dictionary<string, string> { ["detail"] = "1" });
            if (current != seq) return;
            var raw = reply.Arr("projects");
            var items = raw.Items().Select(ProjectItem.Parse).OfType<ProjectItem>().Where(p => p.Exists || Live(p).Count > 0).ToList();
            Loaded = true;
            if (items.Count == 0 && Items.Count > 0 && !AppModel.Shared.Connected) return;
            Items = items;
            if (raw is JsonArray arr) Prefs.Set("projectsCache", arr.DeepClone());
            Changed?.Invoke();
        }
        catch { Loaded = true; Changed?.Invoke(); }
    }

    public static ProjectItem? Get(string? id) => id is null ? null : Items.FirstOrDefault(p => p.Id == id);

    /// 这个项目里正在跑的会话
    public static List<SessionInfo> Live(ProjectItem project) =>
        AppModel.Shared.Sessions.Where(s => s.SourceId == project.SourceId && s.ProjectCwd == project.Cwd).ToList();

    public static string IdOf(SessionInfo s) => $"{s.SourceId}\n{s.Cwd ?? ""}";

    /// 会话所在的项目（列表里还没有它时按会话现编一个，名字取目录最后一级）
    public static ProjectItem? Of(SessionInfo s) =>
        string.IsNullOrEmpty(s.Cwd) ? null : Get(IdOf(s)) ?? new ProjectItem(s.SourceId, s.SourceName, s.Cwd!, s.Folder, null, true, s.UpdatedAt ?? 0, 0, 0, null, null);

    /// 「活动中」：有会话在跑或今天动过（同 Mac 项目列表的两节）
    public static bool Active(ProjectItem p) => Live(p).Count > 0 || p.Today > 0;

    /// 文件、Git 按会话找电脑和目录（同 Mac 的 ProjectsModel.codeKey）：这个项目里在跑的会话，没有就用最近一次会话
    public static string? CodeKey(ProjectItem p) =>
        Live(p).OrderByDescending(s => s.UpdatedAt ?? 0).FirstOrDefault()?.Key ?? (p.SessionId is string sid ? $"{p.SourceId}#{sid}" : null);
}

/// 每个项目一套分屏（同 Mac 版 ProjectSpaces）：顶上那排点哪个项目，下面整套标签换成它的；「全部」= 经典界面那一套。
/// 存在偏好 projectSpaces 里（键 = 项目 id，"" = 全部），当前看的是 projectSpace
public static class ProjectSpaces
{
    public static string Current => Prefs.String("projectSpace") ?? "";
    public static event Action? Changed;

    /// 顶上那排列着的项目（用户打开过的，点 × 移出；顺序固定，同浏览器标签，新的接在最后）
    public static List<string> Opened
    {
        get => Prefs.Node("projectStripOpened") is JsonArray a ? a.Select(x => x?.GetValue<string>()).OfType<string>().Distinct().ToList() : [];
        private set => Prefs.Set("projectStripOpened", new JsonArray(value.Select(v => (JsonNode?)JsonValue.Create(v)).ToArray()));
    }

    static JsonObject Store => Prefs.Node("projectSpaces") as JsonObject ?? new JsonObject();

    static void Save(string id)
    {
        var store = Store.DeepClone().AsObject();
        store[id] = ChatPanes.Shared.Snapshot();
        Prefs.Set("projectSpaces", store);
    }

    static void Load(string id)
    {
        if (Store[id] is JsonObject saved) ChatPanes.Shared.Restore(saved.DeepClone().AsObject());
        else ChatPanes.Shared.Restore(ChatPanes.Columns([]));
    }

    /// 切到某个项目（"" = 全部）的那一套标签
    public static void Switch(string id)
    {
        if (id == Current) return;
        Save(Current);
        Prefs.Set("projectSpace", id);
        if (id.Length > 0) Open(id);
        Load(id);
        Changed?.Invoke();
    }

    /// 放进顶上那排（已经在就不动）
    public static void Open(string id)
    {
        var opened = Opened;
        if (opened.Contains(id)) return;
        opened.Add(id);
        Opened = opened;
        Changed?.Invoke();
    }

    /// 点 ×：移出顶上那排；正看着它就回「全部」
    public static void Remove(string id)
    {
        var opened = Opened;
        opened.Remove(id);
        Opened = opened;
        if (Current == id) Switch("");
        Changed?.Invoke();
    }

    /// 进新版界面：换回上次在新版里看的那个项目的一套
    public static void Enter()
    {
        var last = Prefs.String("projectSpaceNew") ?? "";
        if (last.Length > 0 && last != Current) Switch(last);
    }

    /// 回经典界面：记下新版里看的是哪个项目，放回「全部」那一套
    public static void Leave()
    {
        Prefs.Set("projectSpaceNew", Current);
        Switch("");
    }

    /// 在列表里点了别的项目的会话：先切到那个项目（同 Mac：A 项目下别冒出 B 项目的会话）；正看「全部」时不切
    public static void Follow(string key)
    {
        if (!Layout.New || Current.Length == 0 || AppModel.Shared.Session(key) is not SessionInfo s || string.IsNullOrEmpty(s.Cwd)) return;
        var id = ProjectList.IdOf(s);
        if (id == Current) return;
        Switch(id);
    }

    /// 某一套里开着几个标签（顶上项目格的小字）
    public static int TabCount(string id)
    {
        if (id == Current) return ChatPanes.Shared.Keys.Count;
        return Store[id] is JsonObject saved ? Count(saved["root"]) : 0;
        static int Count(JsonNode? n) => n?["items"] is JsonArray items ? items.Sum(Count) : n?["tabs"] is JsonArray tabs ? tabs.Count : 0;
    }
}

/// 文件标签（同 Mac 版 CodeTabs 的 @code:…）：项目栏里点文件、改动、提交历史，都在分屏里开成标签，和会话标签混排、随便分屏。
/// key = "@code:" + base64url(JSON {k 会话, t 种类 file/diff/history/commit, p 路径, m diff 模式, c 提交, o 原路径})
public static class CodeTabs
{
    public const string Prefix = "@code:";
    public sealed record Info(string Key, string Kind, string Path, string? Mode, string? Commit, string? OldPath);

    /// 标签上的小圆点（有没保存的修改）要重画
    public static event Action? Changed;
    public static void NotifyChanged() => Changed?.Invoke();
    static readonly Dictionary<string, CodeWindow> Views = [];

    public static bool Is(string? key) => key?.StartsWith(Prefix, StringComparison.Ordinal) == true;

    public static string Make(string sessionKey, string kind, string path, string? mode = null, string? commit = null, string? oldPath = null)
    {
        var o = new JsonObject { ["k"] = sessionKey, ["t"] = kind, ["p"] = path };
        if (mode is not null) o["m"] = mode;
        if (commit is not null) o["c"] = commit;
        if (oldPath is not null) o["o"] = oldPath;
        return Prefix + Convert.ToBase64String(Encoding.UTF8.GetBytes(o.ToJsonString())).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    public static Info? Parse(string? key)
    {
        if (!Is(key)) return null;
        try
        {
            var b64 = key![Prefix.Length..].Replace('-', '+').Replace('_', '/');
            b64 = b64.PadRight(b64.Length + (4 - b64.Length % 4) % 4, '=');
            var o = JsonNode.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(b64)));
            return o.Str("k") is string k && o.Str("t") is string t ? new Info(k, t, o.Str("p") ?? "", o.Str("m"), o.Str("c"), o.Str("o")) : null;
        }
        catch { return null; }
    }

    /// 在分屏里打开（已经开着就切过去）
    public static void Open(string sessionKey, string kind, string path, string? mode = null, string? commit = null, string? oldPath = null)
    {
        var key = Make(sessionKey, kind, path, mode, commit, oldPath);
        ChatPanes.Shared.Show(key);
    }

    public static string Title(string key) => Parse(key) is { } i ? CodeWindow.TabTitle(i.Kind, i.Path, i.Mode, i.Commit) : L("文件");
    public static string Symbol(string key) => Parse(key) is { } i ? CodeWindow.TabSymbol(i.Kind) : "doc.text";
    public static string Tip(string key) => Parse(key) is { } i ? (i.Path.Length > 0 ? i.Path : Title(key)) : "";

    /// 分屏里这个标签的内容（同一个 key 只建一次）
    public static Avalonia.Controls.Control View(string key)
    {
        if (!Views.TryGetValue(key, out var w))
        {
            var i = Parse(key);
            w = i is null ? CodeWindow.ForTab("", "file", "", null, null, null) : CodeWindow.ForTab(i.Key, i.Kind, i.Path, i.Mode, i.Commit, i.OldPath);
            Views[key] = w;
        }
        return w.View!;
    }

    public static bool IsDirty(string key) => Views.TryGetValue(key, out var w) && w.Dirty;

    /// 标签关掉了：丢掉它的编辑器
    public static void Forget(string key) => Views.Remove(key);

    /// 关标签：有没保存的修改先问「保存 / 不保存 / 取消」（同 Mac 的 installCodeTabGuard）
    public static async void Close(Guid pane, string key)
    {
        if (IsDirty(key) && Views.TryGetValue(key, out var w))
        {
            switch (await Dialogs.Choose(L("「%@」有未保存的修改。不保存的话，修改会丢失。", Title(key)), L("保存"), L("不保存")))
            {
                case 1: if (!await w.SaveAll()) return; break;
                case 2: break;
                default: return;
            }
        }
        ChatPanes.Shared.CloseTab(pane, key);
    }
}
