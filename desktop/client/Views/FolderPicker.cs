using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.Net;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 新任务「打开其他文件夹」（同 Mac / iPhone 的 FolderPicker）：一层层点进某台电脑上的文件夹，选定后在那里新建会话。
/// 本机用系统的选文件夹框（见 NewTaskSheet），这个给经 SSH 连的别的电脑用（/api/dirs，watcher 的 dirs）
public sealed class FolderPicker
{
    sealed record Entry(string Name, string Path, bool Git);

    readonly string sourceId;
    readonly Window window;
    readonly TaskCompletionSource<string?> done = new();
    readonly StackPanel crumbs = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly ScrollViewer crumbScroll;
    readonly TextBox filter;
    readonly StackPanel rows = new();
    readonly ScrollViewer scroller;
    readonly ContentControl overlay = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock failed = Ui.Text("", 11.5, color: "Orange", lines: 2).Wrap();
    readonly TextBlock hint = Ui.Text("", 11.5, color: "Text2", lines: 2).Wrap();
    readonly Tap openButton;

    string path = "", home = "", sep = "/";
    string? parent;
    List<Entry> entries = [];
    List<string> roots = [];
    bool truncated, hidden, loading;

    /// 选好返回路径，取消返回 null
    public static Task<string?> Pick(string sourceId, string machine, string start)
    {
        var picker = new FolderPicker(sourceId, machine);
        _ = picker.Load(start);
        return picker.done.Task;
    }

    FolderPicker(string sourceId, string machine)
    {
        this.sourceId = sourceId;
        filter = new TextBox { Watermark = L("筛选文件夹"), Width = 160, FontSize = Look.Pt(12.5), Padding = new Thickness(8, 4) };
        filter.Classes.Add("search");
        filter.TextChanged += (_, _) => Draw();
        var up = Small("arrow.up", () => { if (parent is { } p) _ = Load(p); }, L("上一级"));
        var more = Small("ellipsis.circle", () => { }, L("更多"));
        more.Click = () => ShowMenu(more);
        crumbScroll = new ScrollViewer
        {
            Content = crumbs, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        var top = Ui.H(8, up, crumbScroll.Shrink(), new Spacer(), filter, more);

        scroller = new ScrollViewer { Content = rows.Pad(4), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var list = new Border
        {
            CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(0.5), ClipToBounds = true, MinHeight = 200,
            Child = new Panel { Children = { scroller, overlay } },
        }.Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");

        var openLabel = Ui.Text(L("打开"), 13, FontWeight.SemiBold, "White").HAlign(HorizontalAlignment.Center);
        openButton = new Tap(openLabel.Pad(18, 0), () => Finish(path), 7) { Height = 30, MinWidth = 88 }.Keys("Action", "Action");
        var cancel = new Tap(Ui.Text(L("取消"), 13).HAlign(HorizontalAlignment.Center).Pad(18, 0), () => window!.Close(), 7) { Height = 30, MinWidth = 72, BorderThickness = new Thickness(0.5) }
            .Keys("Fill10", "Fill15").Res(Border.BorderBrushProperty, "Fill12");
        var footer = Ui.H(10, hint.Shrink(), new Spacer(), cancel, openButton);

        var dock = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(footer, Dock.Bottom);
        DockPanel.SetDock(failed, Dock.Bottom);
        top.Margin = new Thickness(0, 0, 0, 10);
        failed.Margin = new Thickness(0, 8, 0, 0);
        footer.Margin = new Thickness(0, 12, 0, 0);
        dock.Children.Add(top);
        dock.Children.Add(footer);
        dock.Children.Add(failed);
        dock.Children.Add(list);

        window = Dialog.Make(dock.Pad(20, 4, 20, 20), 560, L("选择文件夹 · %@", machine));
        window.SizeToContent = SizeToContent.Manual;
        window.Height = 560;
        window.MinHeight = 360;
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) window.Close(); };
        window.Closed += (_, _) => done.TrySetResult(null);
        Update();
        Draw();
        Dialog.Show(window, modal: true);
    }

    static Tap Small(string symbol, Action action, string tip) =>
        new Tap(Ui.Sym(symbol, 13, "Text2").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center).Size(28, 26), action, 6).Keys("Transparent", "Fill08").Tip(tip);

    void ShowMenu(Control anchor)
    {
        var menu = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedRight };
        menu.Items.Add(Ui.Item(L("新建文件夹…"), NewFolder, enabled: path.Length > 0));
        menu.Items.Add(Ui.Item(L("显示隐藏文件夹"), () => { hidden = !hidden; _ = Load(path); }, check: hidden ? "" : null));
        menu.Items.Add(new Separator());
        menu.Items.Add(Ui.Item(L("主目录"), () => _ = Load(home), enabled: home.Length > 0));
        foreach (var drive in roots) menu.Items.Add(Ui.Item(drive, () => _ = Load(drive)));
        menu.ShowAt(anchor);
    }

    async void NewFolder()
    {
        var name = await Code.CodeWindow.Prompt(L("新建文件夹"), L("在「%@」中新建", Name(path)), "", L("文件夹名称"), L("新建"));
        if (name is not null) await Load(path, name);
    }

    async Task Load(string target, string? mkdir = null)
    {
        loading = true;
        Update();
        try
        {
            var api = AppModel.Shared.Api;
            var reply = mkdir is null
                ? await api.Get("/api/dirs", new Dictionary<string, string> { ["sourceId"] = sourceId, ["path"] = target, ["hidden"] = hidden ? "1" : "0" })
                : await api.Post("/api/dirs", new JsonObject { ["sourceId"] = sourceId, ["path"] = target, ["mkdir"] = mkdir, ["hidden"] = hidden });
            path = reply.Str("path") ?? target;
            parent = reply.Str("parent");
            home = reply.Str("home") ?? "";
            sep = reply.Str("sep") ?? "/";
            entries = reply.Arr("entries").Items().Select(n => n.Str("path") is string p ? new Entry(n.Str("name") ?? p, p, n.Truthy("git")) : null).OfType<Entry>().ToList();
            roots = reply.Arr("roots").Items().Select(n => n?.GetValue<string>()).OfType<string>().ToList();
            truncated = reply.Truthy("truncated");
            failed.Text = "";
            filter.Text = "";
            scroller.Offset = default;
        }
        catch (Exception e)
        {
            // 点进去没成功（没权限……）：留在原地，下面提示一句；一开始就没打开的整块显示原因
            failed.Text = path.Length > 0 ? e.Message : "";
            if (path.Length == 0) overlay.Content = Ui.Text(e.Message, 13, color: "Text2", lines: 3).Wrap();
        }
        loading = false;
        Draw();
        Update();
    }

    void Update()
    {
        var ready = !loading && path.Length > 0;
        openButton.Opacity = ready ? 1 : 0.45;
        openButton.IsHitTestVisible = ready;
        hint.Text = path.Length > 0 ? L("点击文件夹进入，选好后点击「打开」，将在「%@」中新建会话。", Name(path)) : "";
    }

    void Draw()
    {
        DrawCrumbs();
        rows.Children.Clear();
        var q = (filter.Text ?? "").Trim().ToLowerInvariant();
        var shown = q.Length == 0 ? entries : entries.Where(e => e.Name.ToLowerInvariant().Contains(q)).ToList();
        foreach (var entry in shown)
        {
            var git = entry.Git
                ? new Border { Padding = new Thickness(6, 1), CornerRadius = new CornerRadius(8), Child = Ui.Text("Git", 10.5, FontWeight.Medium, "Text2") }.Res(Border.BackgroundProperty, "Fill08")
                : null;
            var name = Ui.Text(entry.Name, 13).Trim();
            if (entry.Name.StartsWith('.')) name.Opacity = 0.55;
            var line = Ui.H(10, Ui.Sym("folder", 15, "Accent"), name.Shrink(), new Spacer(6), git, Ui.Sym("chevron.right", 10, "Text3"));
            var target = entry.Path;
            var row = new Tap(line.Pad(10, 7), () => _ = Load(target), 6).Keys("Transparent", "Fill05");
            row.Cursor = Cursor.Default;
            rows.Children.Add(row);
        }
        if (truncated && q.Length == 0) rows.Children.Add(Ui.Text(L("此目录文件夹过多，仅列出前 2000 个。"), 11.5, color: "Text3").Pad(10, 6));
        if (path.Length == 0) { if (overlay.Content is not TextBlock) overlay.Content = new Spinner(18); }
        else overlay.Content = shown.Count == 0 ? Ui.Text(q.Length == 0 ? L("此文件夹中没有子文件夹") : L("没有匹配的文件夹"), 13, color: "Text2") : null;
    }

    /// 当前路径一级一级的，点了回到那一级：在主目录里的从「主目录」起，别的从根（/、C:\）起
    void DrawCrumbs()
    {
        crumbs.Children.Clear();
        if (path.Length == 0) return;
        var homeDir = home.Length > 1 ? home.TrimEnd('/', '\\') : home;
        var list = new List<(string Label, string Path)>();
        string rest;
        if (homeDir.Length > 0 && (path == homeDir || path.StartsWith(homeDir + sep, StringComparison.Ordinal)))
        {
            list.Add((L("主目录"), homeDir));
            rest = path[homeDir.Length..];
        }
        else if (sep == "\\" && path.IndexOf(':') is var colon and > 0)
        {
            var drive = path[..(colon + 1)] + "\\";
            list.Add((drive, drive));
            rest = path[(colon + 1)..];
        }
        else
        {
            list.Add((L("根目录"), "/"));
            rest = path;
        }
        var current = list[0].Path;
        foreach (var part in rest.Split(sep[0], StringSplitOptions.RemoveEmptyEntries))
        {
            current = current.EndsWith(sep, StringComparison.Ordinal) ? current + part : current + sep + part;
            list.Add((part, current));
        }
        for (var i = 0; i < list.Count; i++)
        {
            if (i > 0) crumbs.Children.Add(Ui.Text(sep, 12, color: "Text3").VAlign(VerticalAlignment.Center).Pad(2, 0));
            var here = i == list.Count - 1;
            var label = Ui.Text(list[i].Label, 12, here ? FontWeight.SemiBold : FontWeight.Normal, here ? "Text" : "Accent");
            var target = list[i].Path;
            crumbs.Children.Add(here ? (Control)label.Pad(4, 3) : new Tap(label.Pad(4, 3), () => _ = Load(target), 4).Keys("Transparent", "Fill08"));
        }
        // 路径深了停在最右边（看得见现在在哪一级）
        Avalonia.Threading.Dispatcher.UIThread.Post(() => crumbScroll.Offset = new Vector(Math.Max(0, crumbScroll.Extent.Width - crumbScroll.Viewport.Width), 0),
            Avalonia.Threading.DispatcherPriority.Loaded);
    }

    string Name(string p) => p.Split(sep[0], StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? p;

    void Finish(string picked)
    {
        if (picked.Length == 0) return;
        done.TrySetResult(picked);
        window.Close();
    }

    /// 选文件夹从哪开始：这台电脑上的项目大多放在哪个文件夹（如 ~/Projects）——出现最多的上一级目录，一样多取最近用过的（cwds 最近的在前）
    public static string UsualStart(IEnumerable<string> cwds)
    {
        var counts = new Dictionary<string, int>();
        var order = new List<string>();
        foreach (var cwd in cwds)
        {
            var cut = cwd.LastIndexOfAny(['/', '\\']);
            if (cut <= 0) continue;
            var parent = cwd[..cut];
            if (parent.EndsWith(':')) continue;   // 盘符（C:）不算
            if (!counts.ContainsKey(parent)) order.Add(parent);
            counts[parent] = counts.GetValueOrDefault(parent) + 1;
        }
        var best = "";
        foreach (var parent in order) if (counts[parent] > counts.GetValueOrDefault(best)) best = parent;
        return best;
    }
}
