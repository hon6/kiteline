using CommunityToolkit.Mvvm.ComponentModel;
using static Kiteline.Lang;

namespace Kiteline.Model;

/// 主窗口的界面状态（同 Mac 版 KitelineModel）：左边栏选中的是哪一项（会话 key 或 @today 这些入口）、搜索词、列表的分组排序筛选
public sealed partial class MainModel : ObservableObject
{
    public static MainModel Shared { get; } = new();

    public const string TodayId = "@today";
    public const string HistoryId = "@history";
    public const string UsageId = "@usage";
    public const string ProjectsId = "@projects";
    public const string TodosId = "@todos";
    public const string FavoritesId = "@favorites";
    /// 会话群：全部群（进行中 + 历史群）、某个群（@group:<群 id>，同会话一样开成右边分屏里的一个标签）
    public const string GroupsId = "@groups";
    public const string GroupPrefix = "@group:";

    /// 是群的 key（@group:<群 id>）就给群 id，会话的 key 给 null
    public static string? GroupIdOf(string? key) => key is not null && key.StartsWith(GroupPrefix) ? key[GroupPrefix.Length..] : null;

    /// 选中了会话：右边分屏里已经开着就切到那块，没开着就放进当前块（同 Mac 版 KitelineModel.selection）
    [ObservableProperty] string? selection;
    [ObservableProperty] string query = "";
    /// 「新任务」面板；preset = 预先选中的项目
    public (string SourceId, string Cwd)? NewTaskPreset { get; set; }
    public event Action? NewTaskRequested;

    /// 世界模式（同 Mac 版 KitelineModel.worldMode）：右边整块是像素世界（Views/WorldView.cs）。记在偏好里，下次打开还是世界。
    /// 只在能把网页嵌进主窗口时（Windows）有；Linux 上世界开在单独的浏览器窗口里，主窗口照常
    [ObservableProperty] bool worldMode = Prefs.Bool("worldMode") && Views.World.Embedded;
    /// 世界里点了某人的屏幕：这个会话的对话页排在世界右边
    [ObservableProperty] string? worldDetail;
    /// 世界模式里收起了左边的会话列表（世界占满整个窗口）
    [ObservableProperty] bool sidebarCollapsed;

    /// 世界那块放哪一页（同 Mac 版 KitelineModel.worldPage）：world = 像素园区，flow = 数据流大屏；两页共用一个网页面板
    [ObservableProperty] string worldPage = Prefs.String("worldPage") == "flow" ? "flow" : "world";

    public void SetWorld(bool on)
    {
        if (on && !Views.World.Embedded) { Views.World.OpenWindow(WorldPage); return; }
        WorldMode = on;
    }

    /// 地球 / 数据流两个入口：没开就打开这一页；开着别的那页就切过来；开着的正是这页就离开（Linux 上开浏览器窗口）
    public void ToggleWorld(string page)
    {
        if (!Views.World.Embedded) { Views.World.OpenWindow(page); return; }
        if (WorldMode && WorldPage == page) { WorldMode = false; return; }
        if (WorldPage != page) { WorldDetail = null; WorldPage = page; }
        WorldMode = true;
    }

    partial void OnWorldPageChanged(string value) => Prefs.Set("worldPage", value);

    partial void OnWorldModeChanged(bool value)
    {
        Prefs.Set("worldMode", value);
        if (value) return;
        // 平时的界面没有收起会话列表的按钮：回来时展开
        WorldDetail = null;
        SidebarCollapsed = false;
    }

    partial void OnSelectionChanged(string? oldValue, string? newValue)
    {
        // 世界模式里点了左边栏顶上的入口（今日动态、待办……）：离开世界去那一页；点会话 = 世界里镜头飞过去（同 Mac 版）
        if (WorldMode && newValue is not null && newValue.StartsWith('@')) WorldMode = false;
        // 会话、群（同会话一样开成一个标签）：右边分屏里已经开着就切过去，没开着放进当前块
        if (newValue is null || (newValue.StartsWith('@') && GroupIdOf(newValue) is null) || newValue == oldValue) return;
        ChatPanes.Shared.Show(newValue);
        if (WorldMode && GroupIdOf(newValue) is null) Views.World.Focus(newValue);
    }

    public void NewTask(SessionInfo? item = null)
    {
        NewTaskPreset = item is null ? null : (item.SourceId, item.Cwd ?? "");
        NewTaskRequested?.Invoke();
    }

    public void NewTask(string sourceId, string cwd)
    {
        NewTaskPreset = (sourceId, cwd);
        NewTaskRequested?.Invoke();
    }

    // 分组、排序、筛选（同手机、Mac，存的键也一样）：分组 none / source / project / agent；排序 started / recent / status / name；
    // 状态 all / busy / waiting / error；设备 = 来源 id（空 = 全部设备）；项目 = 项目名（目录最后一级；空 = 全部项目）
    public string Grouping { get => Prefs.String("listGrouping") ?? "none"; set { Prefs.Set("listGrouping", value); OnPropertyChanged(); } }
    public string Sorting { get => Prefs.String("listSorting") ?? "started"; set { Prefs.Set("listSorting", value); OnPropertyChanged(); } }
    public string StatusFilter { get => Prefs.String("listFilter") ?? "all"; set { Prefs.Set("listFilter", value); OnPropertyChanged(); } }
    public string SourceFilter { get => Prefs.String("listSource") ?? ""; set { Prefs.Set("listSource", value); OnPropertyChanged(); } }
    public string ProjectFilter { get => Prefs.String("listProject") ?? ""; set { Prefs.Set("listProject", value); OnPropertyChanged(); } }
    /// 左边栏现在看的页签（同 Mac 版 listTab）：sessions 会话 / groups 群 / tabgroups 会话组；没有的（电脑不支持）回到会话
    public string ListTab { get => Prefs.String("listTab") ?? "sessions"; set { Prefs.Set("listTab", value); OnPropertyChanged(); } }

    /// 搜索过的会话
    public IEnumerable<SessionInfo> Filtered(IEnumerable<SessionInfo> sessions)
    {
        var q = Query.Trim().ToLowerInvariant();
        if (q.Length == 0) return sessions;
        return sessions.Where(s => s.Title.ToLowerInvariant().Contains(q) || (s.Cwd ?? "").ToLowerInvariant().Contains(q)
                                   || s.SourceName.ToLowerInvariant().Contains(q) || Agents.Info(s.Agent).Name.ToLowerInvariant().Contains(q));
    }

    /// 窗口标题栏上的概况（同 Mac 版 KitelineModel.summary）
    public static string Summary(IReadOnlyList<SessionInfo> sessions)
    {
        if (sessions.Count == 0) return L("没有运行中的会话");
        var waiting = sessions.Count(s => s.IsWaiting);
        var busy = sessions.Count(s => s.IsBusy);
        var parts = new List<string> { L("%@ 个会话", sessions.Count) };
        if (waiting > 0) parts.Add(L("%@ 个待确认", waiting));
        if (busy > 0) parts.Add(L("%@ 个正在工作", busy));
        return string.Join(" · ", parts);
    }
}
