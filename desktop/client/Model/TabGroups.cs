using System.Text.Json.Nodes;
using Avalonia.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Model;

/// 会话组的颜色（同 Edge 九种，同 Mac 版 TabGroupColor）：斜杠前浅色外观、后深色外观
public sealed record TabGroupColor(string Id, string Title, uint Light, uint Dark)
{
    public static readonly TabGroupColor[] All =
    [
        new("grey", "灰色", 0x5F6368, 0xBDC1C6),
        new("blue", "蓝色", 0x1A73E8, 0x8AB4F8),
        new("red", "红色", 0xD93025, 0xF28B82),
        new("yellow", "黄色", 0xE8A200, 0xFDD663),
        new("green", "绿色", 0x188038, 0x81C995),
        new("pink", "粉色", 0xD01884, 0xFF8BCB),
        new("purple", "紫色", 0xA142F4, 0xC58AF9),
        new("cyan", "青色", 0x007B83, 0x78D9EC),
        new("orange", "橙色", 0xFA903E, 0xFCAD70),
    ];

    /// 老组没有颜色时按先后轮；新建的先挑没人用过的（同 Mac 版 cycle / nextColor）
    public static readonly string[] Cycle = ["blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange", "grey"];

    public static TabGroupColor Grey => All[0];
    public static TabGroupColor? Find(string? id) => All.FirstOrDefault(c => c.Id == id);

    public uint Hex => Palette.IsDark ? Dark : Light;
    public IBrush Brush => Palette.Brush(Hex);
    public string Name => L(Title);
}

/// 一个会话组（同 Mac 版 TabGroups.Group）：名字、颜色、组里的会话 key（先后 = 分屏从左到右）。存在电脑上，各端同步
public sealed record TabGroupItem(string Id, string Name, string? Color, IReadOnlyList<string> Keys)
{
    public static TabGroupItem? Parse(JsonNode? n)
    {
        if (n.Str("id") is not string id || id.Length == 0) return null;
        return new TabGroupItem(id, n.Str("name") is { Length: > 0 } name ? name : L("会话组"), n.Str("color"), n.Strings("keys").Distinct().ToList());
    }

    public JsonObject Json()
    {
        var o = new JsonObject { ["id"] = Id, ["name"] = Name, ["keys"] = new JsonArray(Keys.Select(k => (JsonNode?)JsonValue.Create(k)).ToArray()) };
        if (Color is not null) o["color"] = Color;
        return o;
    }
}

/// 会话组（同 Mac 版 TabGroups，见 KitelineKit/Views/TabGroups.swift）：组名、颜色、组里的会话、先后存在电脑上（/api/tabgroups，实时推 tabgroups 事件整份），
/// 各端看到同一套。分屏布局只存这台客户端自己（app-prefs 的 tabGroupLayouts）：切走一组时记下它的布局，切回来照原样摆。
/// 正显示的那组的会话就是分屏里的会话：分屏里关掉一个标签 = 从组里拿掉；在组里加标签（打开会话）= 加进组。
public sealed partial class TabGroupState : ObservableObject
{
    public static TabGroupState Shared { get; } = new();

    /// 布局存档的键：未分组的标签页用空串
    const string LooseId = "";

    [ObservableProperty] IReadOnlyList<TabGroupItem> items = [];
    /// 正显示的那组（null = 未分组的标签页）
    [ObservableProperty] string? active;

    readonly HashSet<string> expanded;
    /// 组 id → 切走时记下的分屏布局（ChatPanes.Snapshot 的格式）；未分组的标签页用 LooseId
    JsonObject layouts;
    /// 电脑上那份取到过没有（取到之前不推，免得用空的盖掉）
    bool loaded;

    TabGroupState()
    {
        active = Prefs.String("tabGroupActive") is { Length: > 0 } saved ? saved : null;
        expanded = Prefs.Node("tabGroupExpanded") is JsonArray arr ? arr.Items().Select(J.AsString).OfType<string>().ToHashSet() : [];
        layouts = (Prefs.Node("tabGroupLayouts") as JsonObject)?.DeepClone() as JsonObject ?? new JsonObject();
        ChatPanes.Shared.Changed += OnPanesChanged;
    }

    /// 电脑支持会话组（state 的 features 里有 tabGroups）才有这个页签
    public bool Supported => AppModel.Shared.Features.Contains("tabGroups");
    public bool Loaded => loaded;

    public TabGroupItem? Group(string? id) => id is null ? null : Items.FirstOrDefault(g => g.Id == id);
    public IReadOnlyList<string> Keys(string? id) => Group(id)?.Keys ?? [];
    public bool IsExpanded(string id) => expanded.Contains(id);

    /// 未分组的会话：正显示的是未分组时就是分屏里的，否则是切走时记下的那套
    public IReadOnlyList<string> LooseKeys() =>
        Active is null ? ChatPanes.Shared.Keys.Where(k => k.Length > 0).Distinct().ToList()
        : PaneKeys(layouts[LooseId]).Where(k => k.Length > 0).Distinct().ToList();

    /// 把组里还在运行、能回复的会话拉成一个群（群名用组名），建好打开群聊（同群选择面板的建群）
    public async void MakeGroup(string id)
    {
        var model = AppModel.Shared;
        if (Group(id) is not { } group) return;
        var keys = group.Keys.Where(k => model.Session(k) is { CanReply: true }).Distinct().ToList();
        if (keys.Count < 2)
        {
            model.Flash(L("会话组里至少要有两个运行中的会话才能建群"));
            return;
        }
        if (await GroupState.Shared.Create(keys, group.Name) is string gid) MainModel.Shared.Selection = MainModel.GroupPrefix + gid;
    }

    /// 组的颜色：存的颜色 → 没有就按先后轮一个
    public TabGroupColor ColorOf(string? id)
    {
        var index = Items.ToList().FindIndex(g => g.Id == id);
        if (index < 0) return TabGroupColor.Grey;
        return TabGroupColor.Find(Items[index].Color) ?? TabGroupColor.Find(TabGroupColor.Cycle[index % TabGroupColor.Cycle.Length]) ?? TabGroupColor.Grey;
    }

    public async Task Load()
    {
        if (!Supported) return;
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/tabgroups");
            await Avalonia.Threading.Dispatcher.UIThread.InvokeAsync(() => Apply(reply));
        }
        catch (Exception) { }
    }

    /// 电脑上的整份（接口的回复、tabgroups 事件）。UI 线程调用
    public void Apply(JsonNode? reply)
    {
        if (reply?.Get("groups") is not JsonArray list) return;
        var next = list.Items().Select(TabGroupItem.Parse).OfType<TabGroupItem>().ToList();
        Replace(next, sync: loaded);
        if (!loaded && Active is string first && Group(first) is { } group) Diff(ChatPanes.Shared.Keys, group.Keys);   // 第一次取到：分屏跟着电脑上的组走
        loaded = true;
    }

    /// 换成新的整份。sync：组里的会话变了，分屏跟着加、关（本机改的时候分屏已经是对的，不用再碰）
    void Replace(IReadOnlyList<TabGroupItem> next, bool sync)
    {
        var old = Items;
        Items = next;
        if (Active is string a)
        {
            if (Group(a) is not { } now) Active = null;   // 组被删了：分屏照旧留着，当未分组的
            else if (sync && old.FirstOrDefault(g => g.Id == a) is { } before) Diff(before.Keys, now.Keys);
        }
        var ids = next.Select(g => g.Id).ToHashSet();
        foreach (var id in layouts.Select(kv => kv.Key).Where(k => k != LooseId && !ids.Contains(k)).ToList()) layouts.Remove(id);
        SaveLayouts();
    }

    /// 分屏跟着组里的会话走：拿掉的关掉，新加的在最右边多一列（同 Mac 版 arrange / add）
    static void Diff(IReadOnlyList<string> before, IReadOnlyList<string> after)
    {
        var panes = ChatPanes.Shared;
        foreach (var key in before.Except(after).ToList()) if (panes.Keys.Contains(key)) panes.Close(key);
        foreach (var key in after.Except(before).ToList())
        {
            if (panes.Keys.Contains(key)) continue;
            if (panes.IsPristine) panes.SetKey(panes.Panes[0].Id, key);
            else panes.Split(panes.Panes[^1].Id, DropZone.Trailing, key);
        }
    }

    /// 分屏变了：正显示的那组记下新布局；组里的会话跟分屏对齐（关了标签就从组里拿掉，在组里开了会话就加进来）
    void OnPanesChanged()
    {
        if (Active is not string id) return;
        layouts[id] = ChatPanes.Shared.Snapshot();
        SaveLayouts();
        if (!loaded || Group(id) is not { } group) return;
        var keys = ChatPanes.Shared.Keys.Where(k => k.Length > 0).Distinct().ToList();
        if (keys.ToHashSet().SetEquals(group.Keys)) return;
        Replace(Items.Select(g => g.Id == id ? g with { Keys = keys } : g).ToList(), sync: false);
        Push();
    }

    /// 切到某一组（null = 未分组的标签页）。focus 有值就选中它。切走的那组布局先记下
    public void Activate(string? id, string? focus = null)
    {
        if (id is not null && Group(id) is null) return;
        var panes = ChatPanes.Shared;
        var current = Active ?? LooseId;
        var target = id ?? LooseId;
        if (target == current && focus is null) return;
        layouts[current] = panes.Snapshot();
        JsonObject layout;
        if (id is null) layout = layouts[LooseId] as JsonObject ?? ChatPanes.Columns([]);
        else
        {
            var group = Group(id)!;
            // 存着的布局还是这组的会话才用它（组里的会话在别处改过就照组重摆）
            layout = layouts[id] as JsonObject is { } saved && PaneKeys(saved.Get("root")).ToHashSet().SetEquals(group.Keys) ? saved : ChatPanes.Columns(group.Keys);
        }
        Active = id;
        panes.Restore(layout);
        if (focus is not null && panes.PaneHolding(focus) is { } holder) panes.Focus(holder.Id);
        SaveLayouts();
        MainModel.Shared.Selection = panes.Focused;
    }

    /// 每个会话一列（同 Mac 版 arrange）：存下这组的布局；正显示的话马上摆出来
    public void Arrange(string id)
    {
        if (Group(id) is not { } group) return;
        layouts[id] = ChatPanes.Columns(group.Keys);
        SaveLayouts();
        if (Active == id)
        {
            ChatPanes.Shared.Restore((JsonObject)layouts[id]!);
            MainModel.Shared.Selection = group.Keys.FirstOrDefault();
        }
    }

    /// 新建一组（同 Mac 版 create）：fromCurrent = 未分组的标签页直接收成一组（分屏不重建）；否则用 keys 摆好再切过去。返回新组的 id
    public string Create(string? name, IReadOnlyList<string> keys, bool fromCurrent = false)
    {
        var panes = ChatPanes.Shared;
        var id = Guid.NewGuid().ToString();
        var list = fromCurrent && Active is null && !panes.IsPristine ? panes.Keys.Distinct().ToList() : keys.Distinct().ToList();
        var group = new TabGroupItem(id, string.IsNullOrWhiteSpace(name) ? SuggestedName(list) : name.Trim(), NextColor(), list);
        if (fromCurrent && Active is null && !panes.IsPristine)
        {
            layouts[id] = panes.Snapshot();
            layouts[LooseId] = ChatPanes.Columns([]);
            Replace([.. Items, group], sync: false);
            Active = id;
            SaveLayouts();
        }
        else
        {
            layouts[id] = ChatPanes.Columns(list);
            Replace([.. Items, group], sync: false);
            Activate(id, list.FirstOrDefault());
        }
        Push();
        return id;
    }

    /// 改名、改颜色（同 Mac 版 rename / recolor）
    public void Update(string id, string name, string color) =>
        Edit(id, g => g with { Name = string.IsNullOrWhiteSpace(name) ? g.Name : name.Trim(), Color = color });

    /// 往组里加会话：不在组里的加到最右边（同 Mac 版 add）
    public void Add(string id, IEnumerable<string> keys)
    {
        if (Group(id) is not { } group) return;
        var add = keys.Where(k => k.Length > 0 && !group.Keys.Contains(k)).Distinct().ToList();
        if (add.Count == 0) return;
        Edit(id, g => g with { Keys = [.. g.Keys, .. add] });
    }

    /// 从组里拿掉一个会话（分屏里那个标签关掉，会话本身不关）
    public void Remove(string id, string key) => Edit(id, g => g with { Keys = g.Keys.Where(k => k != key).ToList() });

    /// 删除会话组（只删布局，会话不关；正显示的那组删了，分屏照旧留着）
    public void Delete(string id)
    {
        if (Group(id) is null) return;
        if (Active == id) Active = null;
        layouts.Remove(id);
        expanded.Remove(id);
        PersistExpanded();
        Replace(Items.Where(g => g.Id != id).ToList(), sync: false);
        Push();
    }

    public void ToggleExpanded(string id)
    {
        if (!expanded.Remove(id)) expanded.Add(id);
        PersistExpanded();
        OnPropertyChanged(nameof(Items));
    }

    void Edit(string id, Func<TabGroupItem, TabGroupItem> change)
    {
        if (Group(id) is null) return;
        Replace(Items.Select(g => g.Id == id ? change(g) : g).ToList(), sync: true);
        Push();
    }

    /// 同 Mac 版 suggestedName：都在同一个项目就叫项目名，不然「会话组 N」
    public string SuggestedName(IReadOnlyList<string> keys)
    {
        var folders = keys.Select(k => AppModel.Shared.Session(k)?.Folder ?? "").Distinct().ToList();
        if (folders.Count == 1 && folders[0].Length > 0) return folders[0];
        var names = Items.Select(g => g.Name).ToHashSet();
        var n = Items.Count + 1;
        while (names.Contains(L("会话组 %@", n))) n++;
        return L("会话组 %@", n);
    }

    string NextColor()
    {
        var used = Items.Select(g => ColorOf(g.Id).Id).ToHashSet();
        return TabGroupColor.Cycle.FirstOrDefault(c => !used.Contains(c)) ?? TabGroupColor.Cycle[Items.Count % TabGroupColor.Cycle.Length];
    }

    /// 只写电脑上（/api/tabgroups/set，整份换掉），回来的整份再收下
    void Push()
    {
        if (!loaded) return;
        var body = new JsonObject { ["groups"] = new JsonArray(Items.Select(g => (JsonNode?)g.Json()).ToArray()) };
        _ = PushAsync(body);
    }

    async Task PushAsync(JsonObject body)
    {
        try
        {
            var reply = await AppModel.Shared.Api.Post("/api/tabgroups/set", body);
            await Avalonia.Threading.Dispatcher.UIThread.InvokeAsync(() => Apply(reply));
        }
        catch (Exception)
        {
            await Avalonia.Threading.Dispatcher.UIThread.InvokeAsync(() => AppModel.Shared.Flash(L("会话组没有存下，请检查电脑上的 Kiteline 是否在运行")));
        }
    }

    partial void OnActiveChanged(string? value) => Prefs.Set("tabGroupActive", value ?? "");

    void PersistExpanded() => Prefs.Set("tabGroupExpanded", new JsonArray(expanded.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()));

    void SaveLayouts() => Prefs.Set("tabGroupLayouts", layouts.DeepClone());

    /// 分屏布局里有哪些会话（按存档格式读）
    static IEnumerable<string> PaneKeys(JsonNode? node)
    {
        if (node?.Arr("items") is JsonArray items)
        {
            foreach (var child in items.Items()) foreach (var key in PaneKeys(child)) yield return key;
            yield break;
        }
        foreach (var tab in node.Strings("tabs")) yield return tab;
        if (node.Str("key") is string single && !node.Strings("tabs").Contains(single)) yield return single;
    }
}
