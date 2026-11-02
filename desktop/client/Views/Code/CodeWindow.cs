using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views.Code;

/// 代码 IDE（同 Mac 面板里的宽屏 IDE，照 VS Code 的布局）：左边活动栏（资源管理器 / 源代码管理 / 分支与会话 / 提交历史），
/// 侧栏，右边标签页编辑区和状态栏。一个会话一个窗口，再点「文件」「改动」切回已经开着的那个
public sealed partial class CodeWindow
{
    static readonly Dictionary<string, CodeWindow> Open_ = [];

    /// 打开（已经开着就拿到前面）：activity 是 explorer / scm / branches；file 给了就打开那个文件
    public static CodeWindow Open(string key, string activity = "explorer", string? file = null)
    {
        if (!Open_.TryGetValue(key, out var w))
        {
            w = new CodeWindow(key);
            Open_[key] = w;
            Dialog.Show(w.window);
            _ = w.Begin();
        }
        else w.window.Activate();
        w.activity = activity;
        w.DrawSidebar();
        w.DrawActivityBar();
        if (file is not null) w.OpenFile(file);
        return w;
    }

    /// 自测用：最近打开的那个
    public static CodeWindow? Last { get; private set; }
    public Window Window => window;

    sealed record Tab(string Kind, string Path = "", string? Mode = null, string? Commit = null, string? OldPath = null)
    {
        public string Id => Kind switch
        {
            "file" => "file:" + Path,
            "diff" => $"diff:{Mode}:{Commit}:{Path}",
            "history" => "history:" + Path,
            _ => "commit:" + Commit,
        };
        public string Title => Kind switch
        {
            "file" => CodePaths.Name(Path),
            "diff" => CodePaths.Name(Path) + (Commit is not null ? $" ({Commit[..Math.Min(7, Commit.Length)]})" : Mode == "staged" ? L("（已暂存）") : L("（工作区）")),
            "history" => Path.Length > 0 ? L("「%@」的历史", CodePaths.Name(Path)) : L("提交历史"),
            _ => (Commit ?? "")[..Math.Min(8, (Commit ?? "").Length)],
        };
        public string Symbol => Kind switch { "file" => "doc.text", "diff" => "plusminus.circle", "history" => "clock.arrow.circlepath", _ => "number" };
    }

    sealed class FileState
    {
        public string? Sha, Eol, Error;
        public bool Loaded, IsText, Editable = true, Truncated, Lossy;
    }

    readonly string key;
    readonly Window window;
    readonly RepoState repo;
    readonly CodeEditor code = new();
    readonly DiffView diff;
    readonly List<Tab> tabs = [];
    readonly Dictionary<string, FileState> files = [];
    readonly Dictionary<string, DiffPayload> diffs = [];
    string? active;
    string activity = "explorer";
    bool split = true;

    // 资源管理器
    readonly Dictionary<string, List<JsonNode>> listings = [];
    readonly HashSet<string> expanded = [""];
    string rootName = "";
    (List<string> Paths, bool Cut)? clipboard;

    // 界面上会变的几块
    readonly ContentControl sidebar = new();
    readonly StackPanel activityBar = new() { Spacing = 4, Margin = new Thickness(0, 8, 0, 0) };
    readonly StackPanel tabStrip = new() { Orientation = Orientation.Horizontal };
    readonly ContentControl header = new();
    readonly ContentControl native = new();
    readonly Border editorHost = new();
    readonly Border diffHost = new();
    readonly ContentControl status = new();
    readonly TextBlock titleText = Ui.Text(L("代码"), 13, FontWeight.SemiBold).Trim();
    readonly ContentControl titleBranch = new();
    const double TitleHeight = 44;

    CodeWindow(string key)
    {
        this.key = key;
        Last = this;
        repo = RepoStates.Get(key);
        diff = new DiffView(code);
        repo.Changed += () => Dispatcher.UIThread.Post(() => { DrawActivityBar(); DrawSidebar(); DrawStatus(); DrawTitle(); if (ActiveTab?.Kind is "history" or "commit") DrawNative(); });
        code.DirtyChanged += (_, _) => Dispatcher.UIThread.Post(() => { DrawTabs(); DrawHeader(); });
        code.CursorChanged += () => Dispatcher.UIThread.Post(DrawStatus);
        code.Save = id => { if (tabs.FirstOrDefault(t => t.Id == id) is { Kind: "file" } tab) _ = Save(tab); };
        editorHost.Child = code.Editor;
        diffHost.Child = diff;

        // 标题栏同正经窗口：项目名、当前分支，最大化、关闭按钮（Windows 用系统的，Linux 照 GNOME 的按钮顺序自己画）；按住拖动、双击最大化
        var titleBar = Ui.H(10, Ui.Sym("chevron.left.forwardslash.chevron.right", 13, "Accent"), titleText.Shrink(), titleBranch, new Spacer());
        titleBar.Background = Brushes.Transparent;
        titleBar.Height = TitleHeight;
        titleBar.Margin = new Thickness(14, 0, OperatingSystem.IsWindows() ? WindowChrome.CaptionWidth : 6, 0);
        titleBar.PointerPressed += (_, e) =>
        {
            if (e.Source is not Control source || source.FindAncestorOfType<Tap>(true) is not null || !e.GetCurrentPoint(window).Properties.IsLeftButtonPressed) return;
            if (e.ClickCount == 2) ToggleMaximize(); else window.BeginMoveDrag(e);
            e.Handled = true;
        };
        var sideColumn = new Border { Child = sidebar, Width = 290 }.Res(Border.BackgroundProperty, "Sidebar");
        var splitter = new GridSplitter { Width = 4, ResizeDirection = GridResizeDirection.Columns, Background = Brushes.Transparent };
        var main = new DockPanel();
        var tabRow = new ScrollViewer { Content = tabStrip, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled, Height = 34 }
            .Res(ScrollViewer.BackgroundProperty, "Fill03");
        DockPanel.SetDock(tabRow, Dock.Top);
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(status, Dock.Bottom);
        main.Children.Add(tabRow);
        main.Children.Add(header);
        main.Children.Add(status);
        main.Children.Add(new Panel { Children = { editorHost, diffHost, native } });
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("46,Auto,4,*") };
        var bar = new Border { Child = activityBar }.Res(Border.BackgroundProperty, "Fill05");
        Grid.SetColumn(sideColumn, 1);
        Grid.SetColumn(splitter, 2);
        Grid.SetColumn(main, 3);
        grid.Children.Add(bar);
        grid.Children.Add(sideColumn);
        grid.Children.Add(splitter);
        grid.Children.Add(main);
        splitter.DragDelta += (_, e) => sideColumn.Width = Math.Clamp(sideColumn.Width + e.Vector.X, 200, 560);
        var root = new DockPanel();
        DockPanel.SetDock(titleBar, Dock.Top);
        root.Children.Add(titleBar);
        root.Children.Add(Ui.Rule("Separator", 0.5).Self(Align.Stretch));
        DockPanel.SetDock(root.Children[^1], Dock.Top);
        root.Children.Add(grid);
        window = Dialog.Make(root, 1240, L("代码"), titleBar: false);   // 自己画了标题栏和窗口按钮
        window.SizeToContent = SizeToContent.Manual;
        window.Height = 820;
        window.MinWidth = 820;
        window.MinHeight = 520;
        // 挂在主窗口上、不进任务栏的窗口收不起来：不要最小化
        window.CanMinimize = false;
        if (OperatingSystem.IsWindows())
        {
            window.ExtendClientAreaChromeHints = Avalonia.Platform.ExtendClientAreaChromeHints.PreferSystemChrome;
            window.ExtendClientAreaTitleBarHeightHint = TitleHeight;
        }
        else if (WindowChrome.Custom)
        {
            var buttons = new CaptionButtons(window, WindowChrome.Buttons.Where(b => b != "minimize"));
            if (WindowChrome.ButtonsLeft) { titleBar.Children.Insert(0, buttons); titleBar.Margin = new Thickness(0, 0, 14, 0); }
            else titleBar.Children.Add(buttons);
        }
        window.Closing += async (_, e) =>
        {
            var dirty = tabs.Where(t => code.IsDirty(t.Id)).ToList();
            if (dirty.Count == 0 || closingConfirmed) return;
            e.Cancel = true;
            if (await Dialogs.Confirm(L("有 %@ 个文件未保存，关闭后修改会丢失。", dirty.Count), L("不保存并关闭"), destructive: true))
            {
                closingConfirmed = true;
                window.Close();
            }
        };
        window.Closed += (_, _) => { Open_.Remove(key); if (Last == this) Last = null; };
        DrawActivityBar();
        DrawTabs();
        DrawHeader();
        DrawNative();
        DrawStatus();
        DrawTitle();
    }

    bool closingConfirmed;
    Tab? ActiveTab => tabs.FirstOrDefault(t => t.Id == active);

    async Task Begin()
    {
        await Task.WhenAll(repo.Refresh(), LoadFolder(""));
        titleText.Text = repo.Overview?.Name is { Length: > 0 } name ? name : rootName;
        window.Title = titleText.Text;
        DrawSidebar();
    }

    void ToggleMaximize() => window.WindowState = window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    /// 标题栏上的当前分支（和远端差几个提交）：点开分支与会话（同 Mac 工具栏）
    void DrawTitle()
    {
        if (repo.Overview is not { Repo: not null } o) { titleBranch.Content = null; return; }
        var row = Ui.H(5, Ui.Sym("arrow.triangle.branch", 11, "Text2"), Ui.Text(o.Branch ?? "HEAD", 12, color: "Text2").Trim().Shrink());
        if (o.Ahead > 0) row.Children.Add(Ui.Text($"↑{o.Ahead}", 12, color: "Text2"));
        if (o.Behind > 0) row.Children.Add(Ui.Text($"↓{o.Behind}", 12, color: "Text2"));
        titleBranch.Content = new Tap(row.Pad(8, 3), () => { activity = "branches"; DrawActivityBar(); DrawSidebar(); }, 6)
            .Keys("Fill05", "Fill08").Tip(L("分支与会话"));
    }

    // MARK: 活动栏

    void DrawActivityBar()
    {
        activityBar.Children.Clear();
        Control Button(string id, string symbol, string tip, int badge = 0, bool muted = false, Action? action = null)
        {
            var on = id == activity || (id == "history" && ActiveTab?.Kind == "history");
            var icon = Ui.Sym(symbol, 18, on ? "Text" : "Text3");
            var cell = new Panel { Width = 46, Height = 40, Children = { icon.HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center) } };
            if (on && id != "history") cell.Children.Add(new Border { Width = 2.5, Height = 22, CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Left }.Res(Border.BackgroundProperty, "Accent"));
            if (badge > 0)
                cell.Children.Add(new Border
                {
                    MinWidth = 16, Height = 16, CornerRadius = new CornerRadius(8), Padding = new Thickness(4, 0), HorizontalAlignment = HorizontalAlignment.Right,
                    VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 6, 4),
                    Child = Ui.Text(Math.Min(badge, 99).ToString(), 9.5, FontWeight.Bold, "White").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center),
                }.Res(Border.BackgroundProperty, muted ? "Text3" : "Accent"));
            return new Tap(cell, action ?? (() => { activity = id; DrawActivityBar(); DrawSidebar(); }), 6).Keys("Transparent", "Fill08").Tip(tip);
        }
        var o = repo.Overview;
        activityBar.Children.Add(Button("explorer", "doc.on.doc", L("资源管理器")));
        activityBar.Children.Add(Button("scm", "arrow.triangle.branch", L("源代码管理"), o?.ChangeCount ?? 0));
        activityBar.Children.Add(Button("branches", "point.3.connected.trianglepath.dotted", L("分支与会话"), o?.Sessions.Count ?? 0, true));
        activityBar.Children.Add(Button("history", "clock.arrow.circlepath", L("提交历史"), action: () => OpenTab(new Tab("history"))));
    }

    void DrawSidebar()
    {
        sidebar.Content = activity switch
        {
            "scm" => ScmPanel(),
            "branches" => BranchesPanel(),
            _ => ExplorerPanel(),
        };
    }

    // MARK: 标签

    void OpenTab(Tab tab)
    {
        if (tabs.All(t => t.Id != tab.Id))
        {
            var index = tabs.FindIndex(t => t.Id == active);
            tabs.Insert(index >= 0 ? index + 1 : tabs.Count, tab);
        }
        Activate(tab.Id);
    }

    public void OpenFile(string path) => OpenTab(new Tab("file", path));

    /// 自测：history / diff:<路径> / staged:<路径> / commit:<提交号> / activity:<scm|branches|explorer>
    public void SelfTestTab(string arg)
    {
        var parts = arg.Split(':', 2);
        var value = parts.Length > 1 ? parts[1] : "";
        switch (parts[0])
        {
            case "history": OpenTab(new Tab("history")); break;
            case "diff": OpenDiff(RepoChange.Simple(value), "unstaged"); break;
            case "staged": OpenDiff(RepoChange.Simple(value), "staged"); break;
            case "commit": OpenTab(new Tab("commit", Commit: value)); break;
            case "split": split = value != "0"; if (ActiveTab is { } t && diffs.TryGetValue(t.Id, out var p)) diff.Show(p, split, Palette.IsDark); DrawHeader(); break;
            case "activity": activity = value; DrawActivityBar(); DrawSidebar(); break;
            case "op": _ = repo.Perform(value, null, value); break;
        }
    }

    void OpenDiff(RepoChange change, string mode, string? commit = null) => OpenTab(new Tab("diff", change.Path, mode, commit, change.OldPath));

    void Activate(string id)
    {
        if (tabs.FirstOrDefault(t => t.Id == id) is not { } tab) return;
        active = id;
        if (tab.Kind == "file")
        {
            if (code.Has(id)) code.Show(id);
            else _ = LoadFile(tab);
        }
        else if (tab.Kind == "diff")
        {
            if (diffs.TryGetValue(id, out var payload)) diff.Show(payload, split, Palette.IsDark);
            else _ = LoadDiff(tab);
        }
        DrawActivityBar();
        DrawTabs();
        DrawHeader();
        DrawNative();
        DrawStatus();
    }

    async void CloseTab(Tab tab)
    {
        if (code.IsDirty(tab.Id))
        {
            if (!await Dialogs.Confirm(L("「%@」有未保存的修改，关闭后修改会丢失。", tab.Title), L("不保存并关闭"), destructive: true)) return;
        }
        var index = tabs.IndexOf(tab);
        tabs.Remove(tab);
        if (tab.Kind == "file") { code.Close(tab.Id); files.Remove(tab.Path); }
        diffs.Remove(tab.Id);
        if (active == tab.Id)
        {
            active = null;
            if (tabs.Count > 0) { Activate(tabs[Math.Min(index, tabs.Count - 1)].Id); return; }
        }
        DrawTabs(); DrawHeader(); DrawNative(); DrawStatus(); DrawActivityBar();
    }

    void DrawTabs()
    {
        tabStrip.Children.Clear();
        foreach (var tab in tabs)
        {
            var on = tab.Id == active;
            var dirty = code.IsDirty(tab.Id);
            var close = new Tap(Ui.Sym(dirty ? "circle" : "xmark", dirty ? 8 : 9, "Text2").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center).Size(16, 16),
                () => CloseTab(tab), 4).Keys("Transparent", "Fill10").Tip(L("关闭"));
            var row = Ui.H(6, Ui.Sym(tab.Symbol, 11, "Text3"), Ui.Text(tab.Title, 12.5, color: on ? "Text" : "Text2").Trim(), close);
            var body = new Panel { Children = { row.Pad(12, 0, 6, 0).VAlign(VerticalAlignment.Center) } };
            // 当前标签：顶上一道强调色（同 VS Code），右边细线隔开
            if (on) body.Children.Add(new Border { Height = 2, VerticalAlignment = VerticalAlignment.Top }.Res(Border.BackgroundProperty, "Accent"));
            body.Children.Add(Ui.VRule("Separator", 0.5).HAlign(HorizontalAlignment.Right));
            var cell = new Tap(body, () => Activate(tab.Id), 0) { Height = 34 }.Keys(on ? "Window" : "Transparent", on ? "Window" : "Fill05");
            cell.Menu(() =>
            {
                var items = new List<Control>
                {
                    Ui.Item(L("关闭"), () => CloseTab(tab)),
                    Ui.Item(L("关闭其他标签"), () => { foreach (var other in tabs.Where(t => t.Id != tab.Id && !code.IsDirty(t.Id)).ToList()) CloseTab(other); }),
                };
                if (tab.Kind == "file")
                {
                    items.Add(Ui.Divider());
                    items.Add(Ui.Item(L("拷贝相对路径"), () => Copy(tab.Path)));
                    items.Add(Ui.Item(L("在资源管理器中显示"), () => { activity = "explorer"; _ = Reveal(tab.Path); }));
                    items.Add(Ui.Item(L("查看文件历史"), () => OpenTab(new Tab("history", tab.Path))));
                }
                return items;
            });
            tabStrip.Children.Add(cell);
        }
    }

    // MARK: 文件

    async Task LoadFile(Tab tab)
    {
        var state = files.TryGetValue(tab.Path, out var s) ? s : files[tab.Path] = new FileState();
        try
        {
            var f = await CodeApi.Open(key, tab.Path);
            state.Loaded = true;
            state.Sha = f.Str("sha");
            state.Eol = f.Str("eol");
            state.Truncated = f.Truthy("truncated");
            state.Lossy = f.Truthy("lossy");
            state.IsText = f.Str("text") is not null && !f.Truthy("secret");
            state.Editable = state.IsText && !state.Truncated && !state.Lossy;
            state.Error = f.Truthy("secret") ? L("此文件可能包含密钥或密码（.env、证书、私钥等），默认不显示。")
                : f.Truthy("binary") ? L("二进制文件，无法直接查看。") : f.Truthy("image") ? L("图片文件，可用其他应用打开。") : null;
            if (state.IsText)
            {
                code.Open(tab.Id, tab.Path, f.Str("text") ?? "", !state.Editable);
                try
                {
                    var baseline = await CodeApi.Diff(key, tab.Path, "unstaged");
                    if (baseline.Original is not null || baseline.Modified is not null) code.SetBaseline(tab.Id, baseline.Original ?? "");
                }
                catch (Exception) { /* 不是仓库：没有改动竖条 */ }
            }
        }
        catch (Exception e) { state.Error = e.Message; state.Loaded = true; }
        if (active == tab.Id) { DrawHeader(); DrawNative(); DrawStatus(); }
    }

    async Task<bool> Save(Tab tab, bool force = false)
    {
        if (code.Text(tab.Id) is not { } text || !files.TryGetValue(tab.Path, out var state)) return false;
        try
        {
            var body = new JsonObject { ["path"] = tab.Path, ["text"] = text };
            if (state.Sha is not null) body["base"] = state.Sha;
            if (force) body["force"] = true;
            var result = await CodeApi.Fs(key, "write", body);
            if (result.Truthy("conflict"))
            {
                if (await Dialogs.Confirm(L("电脑上的「%@」在你打开之后被修改过（可能是 Claude 改的）。", tab.Title), L("用我的版本覆盖"), destructive: true))
                    return await Save(tab, true);
                if (await Dialogs.Confirm(L("放弃我的修改，载入电脑上的版本？"), L("载入电脑上的版本")))
                {
                    var f = await CodeApi.Open(key, tab.Path);
                    state.Sha = f.Str("sha");
                    code.Replace(tab.Id, f.Str("text") ?? "");
                }
                return false;
            }
            state.Sha = result.Str("sha");
            if (code.Text(tab.Id) == text) code.MarkSaved(tab.Id);
            AppModel.Shared.Flash(L("已保存「%@」", tab.Title));
            _ = repo.Refresh();
            return true;
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); return false; }
    }

    async Task LoadDiff(Tab tab)
    {
        try
        {
            var payload = await CodeApi.Diff(key, tab.Path, tab.Mode ?? "unstaged", tab.Commit, tab.OldPath);
            diffs[tab.Id] = payload;
            if (active == tab.Id) diff.Show(payload, split, Palette.IsDark);
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
        if (active == tab.Id) { DrawHeader(); DrawNative(); }
    }

    // MARK: 编辑区：路径条、内容、状态栏

    void DrawHeader()
    {
        var tab = ActiveTab;
        if (tab is null || tab.Kind is "history" or "commit") { header.Content = null; return; }
        if (tab.Kind == "diff")
        {
            header.Content = diffs.TryGetValue(tab.Id, out var payload) ? DiffBar(tab, payload) : null;
            return;
        }
        var crumbs = Ui.H(3);
        var parts = tab.Path.Split('/');
        for (var i = 0; i < parts.Length; i++)
        {
            if (i > 0) crumbs.Children.Add(Ui.Sym("chevron.right", 8, "Text3"));
            crumbs.Children.Add(Ui.Text(parts[i], 12, color: "Text2"));
        }
        var state = files.GetValueOrDefault(tab.Path);
        var bar = Ui.H(10, crumbs.Shrink());
        if (state is { Loaded: true, IsText: true, Editable: false })
            bar.Children.Add(Ui.Text(state.Truncated ? L("只读：文件过大") : L("只读：非 UTF-8"), 11, color: "Orange"));
        bar.Children.Add(new Spacer());
        if (code.IsDirty(tab.Id)) bar.Children.Add(Form.Button(L("保存"), () => _ = Save(tab), prominent: true).Tip(L("保存（Ctrl+S）")));
        bar.Children.Add(IconButton("magnifyingglass", L("查找和替换（Ctrl+F）"), code.Find));
        bar.Children.Add(IconButton("plusminus.circle", L("查看未提交的改动"), () =>
        {
            var staged = repo.Overview?.Staged.Any(c => c.Path == tab.Path) == true && repo.Overview?.Unstaged.All(c => c.Path != tab.Path) == true;
            OpenDiff(RepoChange.Simple(tab.Path), staged ? "staged" : "unstaged");
        }));
        var more = IconButton("ellipsis", L("更多"), () => { });
        more.Menu(() => FileMenu(tab));
        more.Click = () => more.ContextMenu?.Open(more);
        bar.Children.Add(more);
        header.Content = new Border { Child = bar.Pad(12, 0), Height = 30, BorderThickness = new Thickness(0, 0, 0, 1) }
            .Res(Border.BackgroundProperty, "Fill03").Res(Border.BorderBrushProperty, "Separator");
    }

    IEnumerable<Control> FileMenu(Tab tab)
    {
        var wrap = Prefs.Bool("codeWrap");
        return
        [
            Ui.Item(L("撤销"), () => code.Editor.Undo()),
            Ui.Item(L("重做"), () => code.Editor.Redo()),
            Ui.Item(L("跳到行…"), async () => { if (await Prompt(L("跳到行"), null, "", L("行号")) is { } text && int.TryParse(text, out var n)) code.GotoLine(n); }),
            Ui.Item(L("自动换行"), () => { Prefs.Set("codeWrap", !wrap); code.SetWrap(!wrap); }, check: wrap ? "on" : null),
            Ui.Submenu(L("字号 %@", (int)code.Editor.FontSize), [
                Ui.Item(L("放大"), () => code.SetFontSize(Math.Min(24, code.Editor.FontSize + 1))),
                Ui.Item(L("缩小"), () => code.SetFontSize(Math.Max(9, code.Editor.FontSize - 1))),
                Ui.Item(L("默认大小"), () => code.SetFontSize(13)),
            ]),
            Ui.Divider(),
            Ui.Item(L("查看文件历史"), () => OpenTab(new Tab("history", tab.Path))),
            Ui.Item(L("在资源管理器中显示"), () => { activity = "explorer"; _ = Reveal(tab.Path); }),
            Ui.Item(L("在对话中引用"), () => Quote(tab.Path), AppModel.Shared.Session(key)?.CanReply == true),
            Ui.Item(L("拷贝相对路径"), () => Copy(tab.Path)),
            Ui.Divider(),
            Ui.Item(L("重新载入"), async () =>
            {
                if (code.IsDirty(tab.Id) && !await Dialogs.Confirm(L("重新载入会丢掉未保存的修改。"), L("重新载入"), destructive: true)) return;
                code.Close(tab.Id);
                await LoadFile(tab);
            }),
        ];
    }

    void DrawNative()
    {
        var tab = ActiveTab;
        editorHost.IsVisible = tab?.Kind == "file" && files.GetValueOrDefault(tab.Path) is { IsText: true };
        diffHost.IsVisible = tab?.Kind == "diff" && diffs.TryGetValue(tab.Id, out var p) && !p.Binary;
        native.IsVisible = !editorHost.IsVisible && !diffHost.IsVisible;
        if (!native.IsVisible) { native.Content = null; return; }
        native.Content = tab switch
        {
            null => Welcome(),
            { Kind: "file" } when files.GetValueOrDefault(tab.Path) is { Loaded: true } s => Centered(Ui.Text(s.Error ?? L("无法打开文件"), 13, color: "Text2", lines: 0).Wrap()),
            { Kind: "diff" } when diffs.TryGetValue(tab.Id, out var payload) => Centered(Ui.Text(payload.Binary ? L("无法显示二进制文件的差异。") : L("无差异"), 13, color: "Text2")),
            { Kind: "history" } => HistoryView(tab.Path.Length > 0 ? tab.Path : null),
            { Kind: "commit" } => CommitView(tab.Commit ?? ""),
            _ => Centered(new Spinner(18)),
        };
    }

    static Control Centered(Control c) => c.HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center).Margin(30, 30, 30, 30);

    Control Welcome()
    {
        var o = repo.Overview;
        var stack = Ui.Stack(Orientation.Vertical, 12, Align.Center, [
            Ui.Sym("chevron.left.forwardslash.chevron.right", 38, "Text3"),
            Ui.Text(o?.Name ?? rootName, 17, FontWeight.SemiBold),
            o?.Repo is not null ? Ui.Text(L("分支「%@」", o.Branch ?? "HEAD") + " · " + (o.ChangeCount > 0 ? L("%@ 个文件有改动", o.ChangeCount) : L("工作区干净")), 13, color: "Text2") : null,
            Ui.H(10, Form.Button(L("源代码管理"), () => { activity = "scm"; DrawActivityBar(); DrawSidebar(); }),
                Form.Button(L("提交历史"), () => OpenTab(new Tab("history"))),
                Form.Button(L("分支与会话"), () => { activity = "branches"; DrawActivityBar(); DrawSidebar(); })),
            Ui.Text(L("从左侧选择文件开始编辑；Ctrl+S 保存，Ctrl+F 查找。"), 12, color: "Text3"),
        ]);
        return Centered(stack);
    }

    void DrawStatus()
    {
        var tab = ActiveTab;
        var row = Ui.H(14);
        if (repo.Overview?.Branch is { } branch)
            row.Children.Add(new Tap(Ui.H(4, Ui.Sym("arrow.triangle.branch", 10, "Text2"), Ui.Text(branch, 11, color: "Text2")), () => { activity = "branches"; DrawActivityBar(); DrawSidebar(); }, 3)
                .Keys("Transparent", "Fill08"));
        row.Children.Add(new Spacer());
        if (tab?.Kind == "file" && files.GetValueOrDefault(tab.Path) is { IsText: true } state)
        {
            row.Children.Add(Ui.Text(L("行 %@，列 %@", code.Line, code.Column) + (code.Selected > 0 ? L("（已选 %@）", code.Selected) : ""), 11, color: "Text2"));
            row.Children.Add(Ui.Text(state.Eol == "crlf" ? "CRLF" : "LF", 11, color: "Text2"));
            row.Children.Add(Ui.Text("UTF-8", 11, color: "Text2"));
            if (code.Language.Length > 0) row.Children.Add(Ui.Text(code.Language, 11, color: "Text2"));
        }
        status.Content = new Border { Child = row.Pad(10, 0), Height = 22 }.Res(Border.BackgroundProperty, "Fill05");
    }

    // MARK: 小工具

    static Tap IconButton(string symbol, string tip, Action action) =>
        (Tap)new Tap(Ui.Sym(symbol, 12, "Text2").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center).Size(24, 22), action, 5).Keys("Transparent", "Fill08").Tip(tip);

    void Copy(string text) { _ = window.Clipboard?.SetTextAsync(text); AppModel.Shared.Flash(L("已拷贝")); }

    void Quote(string path)
    {
        var draft = (AppModel.Shared.Draft(key) ?? "").Trim();
        AppModel.Shared.SetDraft(key, (draft.Length > 0 ? draft + " " : "") + "@" + path + " ");
        AppModel.Shared.Flash(L("已填入对话输入框"));
    }

    /// 起名字的小窗（新建文件 / 分支、改名、跳到行）：确定返回文字，取消返回 null
    public static Task<string?> Prompt(string title, string? message, string initial, string? watermark = null, string confirm = "")
    {
        var done = new TaskCompletionSource<string?>();
        var box = new TextBox { Text = initial, Watermark = watermark, FontSize = Look.Pt(13), Padding = new Thickness(8, 5) };
        Window? w = null;
        void Ok() { var t = (box.Text ?? "").Trim(); done.TrySetResult(t.Length > 0 ? t : null); w?.Close(); }
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Ok(); e.Handled = true; } else if (e.Key == Key.Escape) { w?.Close(); e.Handled = true; } };
        var ok = PromptCard.CardButton(confirm.Length > 0 ? confirm : L("确定"), true, Ok);
        var cancel = PromptCard.CardButton(L("取消"), false, () => { done.TrySetResult(null); w?.Close(); });
        var stack = new StackPanel { Spacing = 12 };   // 标题在统一的标题栏里
        if (message is not null) stack.Children.Add(Ui.Text(message, 12, color: "Text2", lines: 0).Wrap());
        stack.Children.Add(box);
        stack.Children.Add(new ButtonPair(cancel, ok));
        w = new Window
        {
            Width = 420, SizeToContent = SizeToContent.Height, CanResize = true, MinWidth = 320, ShowInTaskbar = false, Title = title,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = Look.Family,
        };
        w.Content = Dialog.WithTitleBar(w, stack.Pad(20, 4, 20, 20));
        w.Res(Window.BackgroundProperty, "Sheet");
        Dialog.Chromeless(w, titleBar: true);
        w.Opened += (_, _) => { box.Focus(); box.SelectAll(); };
        w.Closed += (_, _) => done.TrySetResult(null);
        Dialog.Show(w, modal: true);
        return done.Task;
    }

    static string Relative(double? ms)
    {
        if (ms is not double t || t <= 0) return "";
        var span = DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeMilliseconds((long)t);
        if (span.TotalSeconds < 60) return L("刚刚");
        if (span.TotalMinutes < 60) return L("%@ 分钟前", (int)span.TotalMinutes);
        if (span.TotalHours < 24) return L("%@ 小时前", (int)span.TotalHours);
        return Format.Short(t);
    }

    static Control SectionHeader(string title, int count, params Control[] actions)
    {
        var row = Ui.H(8, Ui.Text(title, 11.5, FontWeight.SemiBold, "Text2"),
            new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0), Child = Ui.Text(count.ToString(), 10.5, FontWeight.SemiBold, "Text2") }.Res(Border.BackgroundProperty, "Fill08"),
            new Spacer());
        foreach (var a in actions) row.Children.Add(a);
        return row.Pad(12, 12, 8, 4);
    }

    static Control StatusLetter(string status)
    {
        var (letter, color) = status switch
        {
            "D" => ("D", "Removed"),
            "A" => ("A", "Added"),
            "?" or "??" => ("U", "Added"),
            "U" => ("!", "Orange"),
            "R" => ("R", "Orange"),
            _ => ("M", "Orange"),
        };
        return Ui.Text(letter, 11, FontWeight.Bold, color).Mono().Width(14);
    }
}
