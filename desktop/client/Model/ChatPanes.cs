using System.Text.Json.Nodes;

namespace Kiteline.Model;

public enum Axis { Horizontal, Vertical }

public enum DropZone { Center, Leading, Trailing, Top, Bottom }

/// 分屏（同 Mac 版 KitelineKit/Views/ChatPanes.swift 的模型，Mac 那套规则原样照搬）：一块一块放会话，可以左右分、上下分，一层层嵌套。
/// 每块是一组标签页（同浏览器）：左边栏点开的会话在当前块里新开一个标签，切走了标签还在，点标签切回来，× 关掉；
/// 关掉最后一个标签，这一块也关掉（只剩一块时变回空白）。点过、在打字的那块是「当前块」：左边栏点会话换掉的是它。
/// 不限块数；对半分太窄时同一排一起平分、再从旁边富余的块里匀出地方。关掉 App 再打开还是原来那样（Prefs「chatPanes」）
public sealed class ChatPanes
{
    public static ChatPanes Shared { get; } = new();

    public sealed class Pane
    {
        public Guid Id { get; init; } = Guid.NewGuid();
        public string? Key { get; set; }
        public List<string> Tabs { get; set; } = [];
        /// 点「+」开新标签之前正显示的：新标签不要了（×）就回到它
        public string? Previous { get; set; }

        public Pane(string? key = null)
        {
            Key = key;
            if (key is not null) Tabs.Add(key);
        }
    }

    public abstract class Node { public abstract Guid Id { get; } }
    public sealed class PaneNode(Pane pane) : Node
    {
        public Pane Pane { get; } = pane;
        public override Guid Id => Pane.Id;
    }
    public sealed class SplitNode : Node
    {
        public Guid SplitId { get; init; } = Guid.NewGuid();
        public override Guid Id => SplitId;
        public Axis Axis { get; set; }
        public List<Node> Items { get; set; } = [];
        public List<double> Fractions { get; set; } = [];
    }

    public const int MaxPanes = int.MaxValue;
    /// 分的时候尽量让每块不窄于 320；窗口里匀不出来也照分
    public static readonly (double Width, double Height) MinSize = (320, 220);
    /// 拖分隔条最多拖到这么小（标题条上的按钮还点得到）
    public static readonly (double Width, double Height) DragMin = (160, 120);
    public const double DividerThickness = 1;

    public Node Root { get; private set; }
    public Guid FocusId { get; private set; }
    /// 每块现在多大（画出来时量的）
    public Dictionary<Guid, (double Width, double Height)> Sizes { get; } = new();
    /// 整个分屏多大
    public (double Width, double Height) Bounds { get; set; }
    public event Action? Changed;

    public ChatPanes()
    {
        var pane = new Pane();
        Root = new PaneNode(pane);
        FocusId = pane.Id;
    }

    // MARK: 查

    public List<Pane> Panes => Leaves(Root);
    public int Count => Panes.Count;
    /// 开着的会话（从左上到右下，切到后面的标签也算）
    public List<string> Keys => Panes.SelectMany(p => p.Tabs).ToList();
    /// 当前块的会话（当前块还没选会话时是空的）
    public string? Focused => Panes.FirstOrDefault(p => p.Id == FocusId)?.Key;
    /// 什么都还没开：只有一块，而且是空的
    public bool IsPristine => Count == 1 && Panes[0].Key is null && Panes[0].Tabs.Count == 0;

    public Pane? PaneById(Guid id) => Panes.FirstOrDefault(p => p.Id == id);
    public Pane? PaneHolding(string key) => Panes.FirstOrDefault(p => p.Tabs.Contains(key));

    static List<Pane> Leaves(Node node) => node switch
    {
        PaneNode p => [p.Pane],
        SplitNode s => s.Items.SelectMany(Leaves).ToList(),
        _ => [],
    };

    void Commit()
    {
        Changed?.Invoke();
        Save();
    }

    // MARK: 改

    /// 左边栏点了某个会话：已经开着就切到那块的那个标签，没开着就在当前块新开一个标签
    public void Show(string key)
    {
        if (PaneHolding(key) is Pane open) Activate(open.Id, key);
        else SetKey(FocusId, key);
    }

    public void Focus(Guid id)
    {
        if (FocusId != id && PaneById(id) is not null) { FocusId = id; Commit(); }
    }

    /// 某一块放哪个会话：新开一个标签（排在正显示的那个后面，同浏览器），已经开着就切过去。key 是空的 = 显示「选择会话」
    public void SetKey(Guid id, string? key)
    {
        if (PaneById(id) is not Pane pane) return;
        if (key is null) pane.Key = null;
        else
        {
            if (!pane.Tabs.Contains(key))
            {
                var at = pane.Key is string shown && pane.Tabs.IndexOf(shown) is var i && i >= 0 ? i + 1 : pane.Tabs.Count;
                pane.Tabs.Insert(at, key);
            }
            pane.Key = key;
            pane.Previous = null;
        }
        FocusId = id;
        Commit();
    }

    /// 点了某个标签
    public void Activate(Guid id, string key)
    {
        if (PaneById(id) is Pane pane && pane.Tabs.Contains(key)) { pane.Key = key; pane.Previous = null; }
        FocusId = id;
        Commit();
    }

    /// 「+」：在这一块开个新标签，先列出没打开的会话让你选
    public void NewTab(Guid id)
    {
        if (PaneById(id) is not Pane pane) return;
        if (pane.Key is not null) pane.Previous = pane.Key;
        pane.Key = null;
        FocusId = id;
        Commit();
    }

    /// 关掉一个标签：正显示的就切到右边那个（没有就左边，同浏览器）；关掉的是最后一个，这一块也关掉（只剩一块时变回空白）。
    /// key 是空的 = 关掉「选择会话」那个新标签，回到开它之前的那个
    public void CloseTab(Guid id, string? key)
    {
        if (PaneById(id) is not Pane pane) return;
        if (key is null)
        {
            var back = pane.Previous is string p && pane.Tabs.Contains(p) ? p : pane.Tabs.LastOrDefault();
            if (back is null && Count > 1) { Close(id); return; }
            pane.Key = back;
            pane.Previous = null;
            Commit();
            return;
        }
        var index = pane.Tabs.IndexOf(key);
        if (index < 0) return;
        var tabs = pane.Tabs.ToList();
        tabs.RemoveAt(index);
        if (tabs.Count == 0 && pane.Key == key && Count > 1) { Close(id); return; }
        var shownNext = pane.Key == key ? (tabs.Count == 0 ? null : tabs[Math.Min(index, tabs.Count - 1)]) : pane.Key;
        pane.Tabs = tabs;
        pane.Key = shownNext;
        if (pane.Previous == key) pane.Previous = null;
        Commit();
    }

    /// 把会话放到某一块的第 index 个标签的位置（拖标签排顺序、从别的块拖到某个标签上）
    public void Place(string key, Guid? source, Guid id, int index)
    {
        var existing = source is Guid s && PaneById(s)?.Tabs.Contains(key) == true ? s : PaneHolding(key)?.Id;
        var at = index;
        if (existing == id && PaneById(id) is Pane self && self.Tabs.IndexOf(key) is var from && from >= 0)
        {
            if (from < at) at -= 1;
        }
        else if (existing is Guid other) CloseTab(other, key);
        if (PaneById(id) is not Pane pane) { SetKey(FocusId, key); return; }
        pane.Tabs.Remove(key);
        pane.Tabs.Insert(Math.Clamp(at, 0, pane.Tabs.Count), key);
        pane.Key = key;
        pane.Previous = null;
        FocusId = id;
        Commit();
    }

    /// 关掉这一块里除了 key 以外的标签 / key 右边的标签
    public void CloseOtherTabs(Guid id, string key, bool rightOnly = false)
    {
        if (PaneById(id) is not Pane pane) return;
        var index = pane.Tabs.IndexOf(key);
        if (index < 0) return;
        pane.Tabs = rightOnly ? pane.Tabs.Take(index + 1).ToList() : [key];
        if (pane.Key is string shown && !pane.Tabs.Contains(shown)) pane.Key = key;
        pane.Previous = null;
        FocusId = id;
        Commit();
    }

    /// 把一块一分为二，新的一半在 edge 那边、放 key（空 = 先选会话），新的一半成为当前块
    public Guid? Split(Guid id, DropZone edge, string? key)
    {
        var pane = new Pane(key);
        if (!SplitTree(id, AxisOf(edge), pane, edge is DropZone.Trailing or DropZone.Bottom)) return null;
        FocusId = pane.Id;
        Commit();
        return pane.Id;
    }

    /// 当前块一分为二：down = 上下分，否则左右分
    public bool SplitFocused(string? key = null, bool? down = null) =>
        Split(FocusId, down == true ? DropZone.Bottom : DropZone.Trailing, key) is not null;

    static Axis AxisOf(DropZone edge) => edge is DropZone.Leading or DropZone.Trailing ? Axis.Horizontal : Axis.Vertical;

    bool SplitTree(Guid id, Axis axis, Pane pane, bool after)
    {
        if (Count >= MaxPanes || PaneById(id) is null) return false;
        Root = Splitting(Root, id, axis, pane, after, Halves(id, axis));
        if (Bounds.Width > 0 && Bounds.Height > 0) Fitted(Root, Bounds, pane.Id);
        return true;
    }

    /// 这一块沿 axis 对半分后，每半还够不够最小尺寸（还没量过大小时当作够）
    bool Halves(Guid id, Axis axis)
    {
        if (!Sizes.TryGetValue(id, out var size)) return true;
        return axis == Axis.Horizontal ? size.Width >= MinSize.Width * 2 + DividerThickness : size.Height >= MinSize.Height * 2 + DividerThickness;
    }

    /// 关掉一块（只剩一块时不能关）：空出来的地方按比例分给同一层剩下的
    public void Close(Guid id)
    {
        if (Count <= 1 || PaneById(id) is null) return;
        var order = Panes.Select(p => p.Id).ToList();
        if (Removing(Root, id) is Node next) Root = Normalized(next);
        Sizes.Remove(id);
        if (FocusId == id)
        {
            var index = order.IndexOf(id);
            var rest = order.Where(x => x != id).ToList();
            FocusId = rest[Math.Min(index, rest.Count - 1)];
        }
        Commit();
    }

    /// 关掉开着这个会话的标签
    public void Close(string key)
    {
        if (PaneHolding(key) is Pane pane) CloseTab(pane.Id, key);
    }

    /// 把会话拖到某一块上：中间 = 在这块开个标签；四边 = 从那边分出来。拖的会话已经开在别的块里：挪过来
    public void Drop(string key, Guid? source, Guid target, DropZone zone)
    {
        var existing = source is Guid s && PaneById(s)?.Tabs.Contains(key) == true ? s : PaneHolding(key)?.Id;
        if (existing == target)
        {
            if (zone != DropZone.Center && PaneById(target) is Pane p && p.Tabs.Count > 1)
            {
                CloseTab(target, key);
                if (Split(target, zone, key) is null) SetKey(target, key);
            }
            else Activate(target, key);
            return;
        }
        if (existing is Guid other) CloseTab(other, key);
        if (zone == DropZone.Center || PaneById(target) is null) SetKey(PaneById(target) is null ? FocusId : target, key);
        else if (Split(target, zone, key) is null) SetKey(target, key);
    }

    /// 拖到某一块的 (x, y)（块里的坐标）上会落在哪：靠近哪条边就从哪边分
    public DropZone? Zone(double x, double y, Guid id, Guid? source, string? key)
    {
        var existing = source is Guid s && PaneById(s) is not null ? s : key is null ? null : PaneHolding(key)?.Id;
        var own = existing == id;
        if (own && (PaneById(id)?.Tabs.Count ?? 0) <= 1) return null;
        if (!Sizes.TryGetValue(id, out var size) || size.Width <= 0 || size.Height <= 0) return own ? null : DropZone.Center;
        var fx = x / size.Width; var fy = y / size.Height;
        var edges = new[] { (DropZone.Leading, fx), (DropZone.Trailing, 1 - fx), (DropZone.Top, fy), (DropZone.Bottom, 1 - fy) };
        var nearest = edges.MinBy(e => e.Item2);
        if (nearest.Item2 >= 0.28) return own ? null : DropZone.Center;
        return nearest.Item1;
    }

    /// 拖第 index 条分隔条：从按下时的比例 start 挪 delta（占这一层总长的比例）
    public void Drag(Guid splitId, int index, IReadOnlyList<double> start, double delta, double length)
    {
        if (length <= 0 || FindSplit(Root, splitId) is not SplitNode split) return;
        if (start.Count != split.Items.Count || index + 1 >= start.Count) return;
        var pair = start[index] + start[index + 1];
        var low = Math.Min(MinLength(split.Items[index], split.Axis, DragMin) / length, start[index]);
        var high = Math.Max(low, pair - Math.Min(MinLength(split.Items[index + 1], split.Axis, DragMin) / length, start[index + 1]));
        var left = Math.Clamp(start[index] + delta, low, high);
        split.Fractions = start.ToList();
        split.Fractions[index] = left;
        split.Fractions[index + 1] = pair - left;
        Commit();
    }

    public void Equalize(Guid splitId)
    {
        if (FindSplit(Root, splitId) is not SplitNode split) return;
        split.Fractions = Enumerable.Repeat(1.0 / split.Items.Count, split.Items.Count).ToList();
        Commit();
    }

    public List<double> Fractions(Guid splitId) => FindSplit(Root, splitId)?.Fractions.ToList() ?? [];

    static SplitNode? FindSplit(Node node, Guid id) => node is SplitNode s ? (s.SplitId == id ? s : s.Items.Select(i => FindSplit(i, id)).FirstOrDefault(x => x is not null)) : null;

    /// 排查用：「左右[*首页 50% | 上下[订单 50% / 空 50%] 50%]」（* 是当前块）
    public string Summary
    {
        get
        {
            string Describe(Node node) => node switch
            {
                PaneNode p => (p.Pane.Id == FocusId ? "*" : "") + (p.Pane.Tabs.Count == 0 ? "空" :
                    string.Join(",", p.Pane.Tabs.Select(t => (t == p.Pane.Key ? "^" : "") + (t.Length > 6 ? t[^6..] : t)).Concat(p.Pane.Key is null ? ["^新标签"] : []))),
                SplitNode s => (s.Axis == Axis.Horizontal ? "左右[" : "上下[") +
                    string.Join(s.Axis == Axis.Horizontal ? " | " : " / ", s.Items.Select((it, i) => $"{Describe(it)} {(int)Math.Round(s.Fractions[i] * 100)}%")) + "]",
                _ => "",
            };
            return Describe(Root);
        }
    }

    // MARK: 树的操作

    static Node Splitting(Node node, Guid id, Axis axis, Pane pane, bool after, bool halve)
    {
        switch (node)
        {
            case PaneNode p:
                if (p.Pane.Id != id) return node;
                return new SplitNode { Axis = axis, Items = after ? [node, new PaneNode(pane)] : [new PaneNode(pane), node], Fractions = [0.5, 0.5] };
            case SplitNode s:
                var index = s.Items.FindIndex(i => i.Id == id);
                if (s.Axis == axis && index >= 0 && s.Items[index] is PaneNode)
                {
                    // 同一个方向：插在旁边
                    var half = s.Fractions[index] / 2;
                    s.Fractions[index] = half;
                    var at = after ? index + 1 : index;
                    s.Items.Insert(at, new PaneNode(pane));
                    s.Fractions.Insert(at, half);
                    if (!halve) s.Fractions = Enumerable.Repeat(1.0 / s.Items.Count, s.Items.Count).ToList();
                    return s;
                }
                s.Items = s.Items.Select(i => Splitting(i, id, axis, pane, after, halve)).ToList();
                return s;
        }
        return node;
    }

    /// 刚分出来的那块所在的每一层，从外往里排一遍：装着它的那一项不够最小尺寸，就从同一层别的项超出最小尺寸的部分里匀过来
    static void Fitted(Node node, (double Width, double Height) size, Guid pane)
    {
        if (node is not SplitNode s) return;
        var path = s.Items.FindIndex(i => Contains(i, pane));
        if (path < 0) return;
        var horizontal = s.Axis == Axis.Horizontal;
        var length = Math.Max(0, (horizontal ? size.Width : size.Height) - (s.Items.Count - 1) * DividerThickness);
        if (length > 0)
        {
            var mins = s.Items.Select((item, i) =>
            {
                var need = MinLength(item, s.Axis, MinSize) / length;
                return i == path ? need : Math.Min(need, s.Fractions[i]);
            }).ToList();
            var others = mins.Where((_, i) => i != path).Sum();
            if (others + mins[path] > 1) mins[path] = Math.Max(s.Fractions[path], 1 - others);
            s.Fractions = Clamped(s.Fractions, mins);
        }
        var share = length * s.Fractions[path];
        Fitted(s.Items[path], horizontal ? (share, size.Height) : (size.Width, share), pane);
    }

    static bool Contains(Node node, Guid pane) => node switch
    {
        PaneNode p => p.Pane.Id == pane,
        SplitNode s => s.Items.Any(i => Contains(i, pane)),
        _ => false,
    };

    /// 比例里不够各自最小值的补足，补的从其余项超出最小值的部分里按超出多少扣；最小值加起来就超过 1 时不动
    public static List<double> Clamped(List<double> fractions, List<double> mins)
    {
        if (fractions.Count != mins.Count || mins.Sum() > 1.0001) return fractions;
        var raised = fractions.Zip(mins, Math.Max).ToList();
        var deficit = raised.Sum() - fractions.Sum();
        if (deficit <= 0.0001) return fractions;
        var spare = raised.Zip(mins, (r, m) => Math.Max(0, r - m)).ToList();
        var total = spare.Sum();
        if (total <= 0) return fractions;
        return raised.Select((r, i) => r - Math.Min(spare[i], deficit * spare[i] / total)).ToList();
    }

    static Node? Removing(Node node, Guid id)
    {
        switch (node)
        {
            case PaneNode p: return p.Pane.Id == id ? null : node;
            case SplitNode s:
                var items = new List<Node>(); var fractions = new List<double>();
                for (var i = 0; i < s.Items.Count; i++)
                    if (Removing(s.Items[i], id) is Node kept) { items.Add(kept); fractions.Add(s.Fractions[i]); }
                if (items.Count == 0) return null;
                if (items.Count == 1) return items[0];   // 这一层只剩一个：不要这一层
                var total = fractions.Sum();
                s.Items = items;
                s.Fractions = fractions.Select(f => total > 0 ? f / total : 1.0 / items.Count).ToList();
                return s;
        }
        return node;
    }

    /// 里面一层和外面同方向的（关掉中间一块后会出现）：摊平成一层
    static Node Normalized(Node node)
    {
        if (node is not SplitNode s) return node;
        var items = new List<Node>(); var fractions = new List<double>();
        for (var i = 0; i < s.Items.Count; i++)
        {
            var child = Normalized(s.Items[i]);
            if (child is SplitNode inner && inner.Axis == s.Axis)
            {
                items.AddRange(inner.Items);
                fractions.AddRange(inner.Fractions.Select(f => f * s.Fractions[i]));
            }
            else { items.Add(child); fractions.Add(s.Fractions[i]); }
        }
        s.Items = items;
        s.Fractions = fractions;
        return s;
    }

    /// 一块（或一组）沿 axis 至少要多长
    public static double MinLength(Node node, Axis axis, (double Width, double Height) unit) => node switch
    {
        PaneNode => axis == Axis.Horizontal ? unit.Width : unit.Height,
        SplitNode s => s.Axis == axis
            ? s.Items.Sum(i => MinLength(i, axis, unit)) + (s.Items.Count - 1) * DividerThickness
            : s.Items.Max(i => MinLength(i, axis, unit)),
        _ => 0,
    };

    // MARK: 记住分屏（关掉 App 再打开、重装之后还是原来那样，同 Mac 版 remember）

    bool remembering;

    public void Remember()
    {
        if (remembering) return;
        if (Prefs.Node("chatPanes") is JsonObject saved && Restored(saved.Get("root")) is Node node)
        {
            Root = node;
            var ids = Panes.Select(p => p.Id).ToList();
            FocusId = Guid.TryParse(saved.Str("focus"), out var focus) && ids.Contains(focus) ? focus : ids[0];
        }
        remembering = true;
    }

    void Save()
    {
        if (!remembering) return;
        Prefs.Set("chatPanes", new JsonObject { ["root"] = Stored(Root), ["focus"] = FocusId.ToString() });
    }

    static JsonNode Stored(Node node) => node switch
    {
        PaneNode p => new JsonObject
        {
            ["id"] = p.Pane.Id.ToString(),
            // 正开着「选择会话」新标签的：存成开它之前显示的那个
            ["key"] = p.Pane.Key ?? (p.Pane.Previous is string prev && p.Pane.Tabs.Contains(prev) ? prev : p.Pane.Tabs.LastOrDefault()),
            ["tabs"] = new JsonArray(p.Pane.Tabs.Select(t => (JsonNode?)JsonValue.Create(t)).ToArray()),
        },
        SplitNode s => new JsonObject
        {
            ["id"] = s.SplitId.ToString(),
            ["vertical"] = s.Axis == Axis.Vertical,
            ["items"] = new JsonArray(s.Items.Select(Stored).ToArray()),
            ["fractions"] = new JsonArray(s.Fractions.Select(f => (JsonNode?)JsonValue.Create(f)).ToArray()),
        },
        _ => new JsonObject(),
    };

    /// 读回来的不对（存坏了）就当没存过；同一个会话只留第一处
    static Node? Restored(JsonNode? saved)
    {
        var ids = new HashSet<Guid>();
        var seen = new HashSet<string>();
        Node? Read(JsonNode? item)
        {
            if (!Guid.TryParse(item.Str("id"), out var id) || !ids.Add(id)) return null;
            if (item.Arr("items") is JsonArray items)
            {
                var fractions = item.Arr("fractions").Items().Select(J.AsNumber).ToList();
                if (items.Count < 2 || fractions.Count != items.Count || fractions.Any(f => f is not > 0)) return null;
                var children = items.Items().Select(Read).ToList();
                if (children.Any(c => c is null)) return null;
                var total = fractions.Sum(f => f!.Value);
                return new SplitNode { SplitId = id, Axis = item.Bool("vertical") == true ? Axis.Vertical : Axis.Horizontal, Items = children!, Fractions = fractions.Select(f => f!.Value / total).ToList() };
            }
            var tabs = item.Strings("tabs");
            if (tabs.Count == 0 && item.Str("key") is string k) tabs = [k];
            var pane = new Pane { Id = id };
            pane.Tabs = tabs.Where(seen.Add).ToList();
            pane.Key = item.Str("key") is string key && pane.Tabs.Contains(key) ? key : pane.Tabs.FirstOrDefault();
            return new PaneNode(pane);
        }
        return Read(saved) is Node root ? Normalized(root) : null;
    }
}
