using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views.Code;

// IDE 窗口的各个面板（同 iOS 版 CodeExplorer / SourceControlView / GitBranchesView / GitHistoryView）
public sealed partial class CodeWindow
{
    // MARK: 资源管理器

    async Task LoadFolder(string folder)
    {
        try
        {
            var list = await CodeApi.List(key, folder);
            listings[folder] = list.Arr("entries").Items().ToList();
            if (folder.Length == 0) rootName = CodePaths.Name((list.Str("root") ?? "").Replace('\\', '/').TrimEnd('/'));
        }
        catch (Exception e) { if (folder.Length == 0) AppModel.Shared.Flash(e.Message); }
        if (activity == "explorer") DrawSidebar();
    }

    async Task Reveal(string path)
    {
        var folder = "";
        foreach (var part in CodePaths.Folder(path).Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            folder = CodePaths.Join(folder, part);
            expanded.Add(folder);
            if (!listings.ContainsKey(folder)) await LoadFolder(folder);
        }
        DrawActivityBar();
        DrawSidebar();
    }

    async Task RefreshFolders()
    {
        foreach (var folder in expanded.Where(f => f.Length == 0 || listings.ContainsKey(f)).ToList()) await LoadFolder(folder);
    }

    Control ExplorerPanel()
    {
        var rows = new StackPanel();
        void Walk(string folder, int depth)
        {
            foreach (var e in listings.GetValueOrDefault(folder) ?? [])
            {
                var name = e.Str("name") ?? "";
                var path = CodePaths.Join(folder, name);
                var dir = e.Str("type") == "dir";
                rows.Children.Add(ExplorerRow(path, name, dir, e.Str("git"), depth, e.Truthy("link")));
                if (dir && expanded.Contains(path)) Walk(path, depth + 1);
            }
        }
        Walk("", 0);
        if (!listings.ContainsKey("")) rows.Children.Add(new Spinner(16).Margin(0, 20, 0, 0).HAlign(HorizontalAlignment.Center));
        var head = Ui.H(4, Ui.Text((rootName.Length > 0 ? rootName : L("项目")).ToUpperInvariant(), 11.5, FontWeight.SemiBold, "Text2").Trim().Shrink(), new Spacer(),
            IconButton("doc.badge.plus", L("新建文件"), () => NewItem("", false)),
            IconButton("folder", L("新建文件夹"), () => NewItem("", true)),
            IconButton("arrow.clockwise", L("刷新"), () => _ = RefreshFolders()),
            IconButton("chevron.up", L("全部折叠"), () => { expanded.Clear(); expanded.Add(""); DrawSidebar(); }));
        head.Menu(() => FolderMenu(""));
        var search = new TextBox { Watermark = L("按文件名搜索"), FontSize = Look.Pt(12.5), Padding = new Thickness(10, 4), Margin = new Thickness(10, 0, 10, 6) };
        search.Classes.Add("search");
        var body = new ContentControl { Content = new ScrollViewer { Content = rows } };
        DispatcherTimer? debounce = null;
        search.TextChanged += (_, _) =>
        {
            debounce?.Stop();
            debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
            debounce.Tick += async (_, _) =>
            {
                debounce?.Stop();
                var q = (search.Text ?? "").Trim();
                if (q.Length == 0) { body.Content = new ScrollViewer { Content = rows }; return; }
                try
                {
                    var found = (await AppModel.Shared.Api.Get("/api/files/find", new Dictionary<string, string> { ["key"] = key, ["q"] = q })).Strings("results");
                    var list = new StackPanel();
                    if (found.Count == 0) list.Children.Add(Ui.Text(L("未找到文件名包含「%@」的文件", q), 12, color: "Text2", lines: 0).Wrap().Margin(14, 8, 14, 8));
                    foreach (var path in found)
                        list.Children.Add(new Tap(Ui.VFill(1, Ui.Text(CodePaths.Name(path), 12.5).Trim(), Ui.Text(CodePaths.Folder(path).Length > 0 ? CodePaths.Folder(path) : "./", 11, color: "Text2").Trim()).Pad(14, 4),
                            () => { OpenFile(path); _ = Reveal(path); }, 0).Keys("Transparent", "Fill08"));
                    body.Content = new ScrollViewer { Content = list };
                }
                catch (Exception e) { AppModel.Shared.Flash(e.Message); }
            };
            debounce.Start();
        };
        var dock = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(search, Dock.Top);
        dock.Children.Add(head.Pad(12, 10, 6, 6));
        dock.Children[^1].SetValue(DockPanel.DockProperty, Dock.Top);
        dock.Children.Add(search);
        dock.Children.Add(body);
        return dock;
    }

    Control ExplorerRow(string path, string name, bool dir, string? git, int depth, bool link)
    {
        var open = expanded.Contains(path);
        var activeFile = ActiveTab is { Kind: "file" } t && t.Path == path;
        var color = git switch { "?" or "A" => "Added", "M" or "•" or "R" => "Orange", "D" => "Removed", _ => "Text" };
        var chevron = Ui.Sym(open ? "chevron.down" : "chevron.right", 9, "Text2").Width(12);
        chevron.Opacity = dir ? 1 : 0;
        var row = Ui.H(5, new Control { Width = depth * 14 }, chevron, Ui.Sym(dir ? "folder" : "doc.text", 13, dir ? "Accent" : "Text3"),
            Ui.Text(name + (link ? " ↪︎" : ""), 12.5, color: color).Trim().Shrink().Opacity(name.StartsWith('.') ? 0.6 : 1));
        if (clipboard is { Cut: true } clip && clip.Paths.Contains(path)) row.Children.Add(Ui.Sym("scissors", 10, "Text3"));
        row.Children.Add(new Spacer());
        if (git is { Length: > 0 }) row.Children.Add(Ui.Text(git == "?" ? "U" : git, 10.5, FontWeight.Bold, color).Mono());
        var tap = new Tap(row.Pad(10, 0, 10, 0), () =>
        {
            if (dir)
            {
                if (!expanded.Remove(path)) { expanded.Add(path); if (!listings.ContainsKey(path)) { _ = LoadFolder(path); return; } }
                DrawSidebar();
            }
            else OpenFile(path);
        }, 0) { Height = 24 }.Keys(activeFile ? "AccentFill14" : "Transparent", activeFile ? "AccentFill16" : "Fill08");
        tap.Menu(() => dir ? FolderMenu(path) : FileItemMenu(path));
        // 拖到文件夹上 = 移动（按住移动几像素才算拖，免得点一下就变成拖动）
        Point? down = null;
        tap.PointerPressed += (_, e) => { if (e.GetCurrentPoint(tap).Properties.IsLeftButtonPressed) down = e.GetPosition(tap); };
        tap.PointerReleased += (_, _) => down = null;
        tap.PointerMoved += async (_, e) =>
        {
            if (down is not { } start || !e.GetCurrentPoint(tap).Properties.IsLeftButtonPressed) return;
            var delta = e.GetPosition(tap) - start;
            if (Math.Abs(delta.X) + Math.Abs(delta.Y) < 8) return;
            down = null;
            var data = new DataObject();
            data.Set("kiteline/code-path", path);
            await DragDrop.DoDragDrop(e, data, DragDropEffects.Move);
        };
        if (dir)
        {
            DragDrop.SetAllowDrop(tap, true);
            tap.AddHandler(DragDrop.DropEvent, (_, e) =>
            {
                if (e.Data.Get("kiteline/code-path") is string from && from != path && CodePaths.Folder(from) != path && !path.StartsWith(from + "/"))
                {
                    clipboard = ([from], true);
                    _ = Paste(path);
                }
            });
        }
        return tap;
    }

    IEnumerable<Control> FolderMenu(string folder)
    {
        var items = new List<Control>
        {
            Ui.Item(L("新建文件…"), () => NewItem(folder, false)),
            Ui.Item(L("新建文件夹…"), () => NewItem(folder, true)),
        };
        if (clipboard is { } clip)
            items.Add(Ui.Item(clip.Cut ? L("移动到这里（%@ 项）", clip.Paths.Count) : L("粘贴（%@ 项）", clip.Paths.Count), () => _ = Paste(folder)));
        items.Add(Ui.Item(L("上传文件到这里…"), () => _ = Upload(folder)));
        if (folder.Length > 0)
        {
            items.Add(Ui.Divider());
            items.AddRange(CommonItems(folder));
        }
        return items;
    }

    IEnumerable<Control> FileItemMenu(string path)
    {
        var items = new List<Control>
        {
            Ui.Item(L("打开"), () => OpenFile(path)),
            Ui.Item(L("查看文件历史"), () => OpenTab(new Tab("history", path))),
            Ui.Divider(),
        };
        items.AddRange(CommonItems(path));
        return items;
    }

    IEnumerable<Control> CommonItems(string path) =>
    [
        Ui.Item(L("复制"), () => { clipboard = ([path], false); AppModel.Shared.Flash(L("已复制，在目标文件夹上选择「粘贴」")); }),
        Ui.Item(L("剪切"), () => { clipboard = ([path], true); AppModel.Shared.Flash(L("已剪切，在目标文件夹上选择「移动到这里」")); DrawSidebar(); }),
        Ui.Item(L("创建副本"), () => _ = Fs("copy", new JsonObject { ["paths"] = new JsonArray(path), ["dest"] = CodePaths.Folder(path) }, [CodePaths.Folder(path)], L("已创建副本"))),
        Ui.Item(L("重命名…"), () => Rename(path)),
        Ui.Item(L("拷贝相对路径"), () => Copy(path)),
        Ui.Item(L("在对话中引用"), () => Quote(path), AppModel.Shared.Session(key)?.CanReply == true),
        Ui.Divider(),
        Ui.Item(L("删除"), () => Delete(path)),
    ];

    async Task<JsonNode?> Fs(string op, JsonObject body, IEnumerable<string> refresh, string? done = null)
    {
        try
        {
            var result = await CodeApi.Fs(key, op, body);
            foreach (var folder in refresh.Distinct()) if (folder.Length == 0 || listings.ContainsKey(folder)) await LoadFolder(folder);
            if (done is not null) AppModel.Shared.Flash(done);
            _ = repo.Refresh();
            return result;
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); return null; }
    }

    async void NewItem(string folder, bool dir)
    {
        var name = await Prompt(dir ? L("新建文件夹") : L("新建文件"), folder.Length == 0 ? L("位置：项目根目录") : L("位置：%@", folder),
            "", dir ? L("文件夹名") : L("文件名（可带子目录，如 src/app.js）"), L("创建"));
        if (name is null) return;
        var path = CodePaths.Join(folder, name.Replace('\\', '/'));
        var result = await Fs("create", new JsonObject { ["path"] = path, ["kind"] = dir ? "dir" : "file" }, [folder, CodePaths.Folder(path)]);
        if (result is null) return;
        expanded.Add(folder);
        if (dir) { expanded.Add(path); DrawSidebar(); return; }
        await Reveal(path);
        OpenFile(path);
    }

    async void Rename(string path)
    {
        var name = CodePaths.Name(path);
        var next = await Prompt(L("重命名"), null, name, name, L("重命名"));
        if (next is null || next == name) return;
        var result = await Fs("rename", new JsonObject { ["path"] = path, ["name"] = next }, [CodePaths.Folder(path)]);
        if (result.Str("path") is { } renamed) Renamed(path, renamed);
    }

    void Renamed(string old, string renamed)
    {
        foreach (var tab in tabs.Where(t => t.Kind == "file" && (t.Path == old || t.Path.StartsWith(old + "/"))).ToList())
        {
            var index = tabs.IndexOf(tab);
            var wasActive = active == tab.Id;
            code.Close(tab.Id);
            files.Remove(tab.Path);
            tabs[index] = new Tab("file", renamed + tab.Path[old.Length..]);
            if (wasActive) Activate(tabs[index].Id);
        }
        DrawTabs();
    }

    async void Delete(string path)
    {
        if (!await Dialogs.Confirm(L("删除「%@」？会移到电脑的废纸篓，可以从那里恢复。", CodePaths.Name(path)), L("移到废纸篓"), destructive: true)) return;
        if (await Fs("delete", new JsonObject { ["paths"] = new JsonArray(path) }, [CodePaths.Folder(path)], L("已移到废纸篓")) is null) return;
        foreach (var tab in tabs.Where(t => t.Kind == "file" && (t.Path == path || t.Path.StartsWith(path + "/"))).ToList())
        {
            code.MarkSaved(tab.Id);
            CloseTab(tab);
        }
    }

    async Task Paste(string folder)
    {
        if (clipboard is not { } clip) return;
        var result = await Fs(clip.Cut ? "move" : "copy", new JsonObject { ["paths"] = new JsonArray(clip.Paths.Select(p => (JsonNode)p).ToArray()), ["dest"] = folder },
            clip.Paths.Select(CodePaths.Folder).Append(folder), clip.Cut ? L("已移动") : L("已粘贴"));
        if (result is null) return;
        if (clip.Cut)
        {
            foreach (var p in clip.Paths) Renamed(p, CodePaths.Join(folder, CodePaths.Name(p)));
            clipboard = null;
        }
        expanded.Add(folder);
        DrawSidebar();
    }

    async Task Upload(string folder)
    {
        var picked = await window.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = true, Title = L("上传文件到这里…") });
        var count = 0;
        foreach (var file in picked)
        {
            await using var stream = await file.OpenReadAsync();
            using var memory = new MemoryStream();
            await stream.CopyToAsync(memory);
            if (await Fs("upload", new JsonObject { ["dest"] = folder, ["name"] = file.Name, ["data"] = Convert.ToBase64String(memory.ToArray()) }, [folder]) is not null) count++;
        }
        if (count > 0) { expanded.Add(folder); AppModel.Shared.Flash(L("已上传 %@ 个文件", count)); DrawSidebar(); }
    }

    // MARK: 源代码管理

    Control ScmPanel()
    {
        var o = repo.Overview;
        if (o is null) return repo.LoadError is { } error ? Centered(Ui.Text(error, 12.5, color: "Text2", lines: 0).Wrap()) : Centered(new Spinner(16));
        if (o.Repo is null)
            return Centered(Ui.Stack(Orientation.Vertical, 10, Align.Center, [
                Ui.Text(L("不是 Git 仓库"), 14, FontWeight.SemiBold),
                Ui.Text(o.Reason ?? L("此目录还没有使用 Git 管理。"), 12, color: "Text2", lines: 0).Wrap(),
                Form.Button(L("初始化仓库"), () => _ = repo.Perform("init", null, L("正在初始化"), L("已初始化 Git 仓库")), prominent: true),
            ]));
        var stack = new StackPanel();
        stack.Children.Add(SyncBar(o));
        if (o.State is { } state) stack.Children.Add(StateBanner(state, o));
        if (o.IdentityMissing)
            stack.Children.Add(Ui.Text(L("这台电脑还未设置 Git 提交者（user.name / user.email），提交会失败。请先在电脑上设置。"), 11.5, color: "Orange", lines: 0).Wrap().Margin(12, 4, 12, 4));
        stack.Children.Add(CommitBox(o));
        if (o.Conflicts.Count > 0)
        {
            stack.Children.Add(SectionHeader(L("合并冲突"), o.Conflicts.Count));
            foreach (var c in o.Conflicts) stack.Children.Add(ChangeRow(c, "unstaged"));
        }
        if (o.Staged.Count > 0)
        {
            stack.Children.Add(SectionHeader(L("暂存的更改"), o.Staged.Count, IconButton("minus", L("全部取消暂存"), () => _ = repo.Perform("unstage_all", null, L("正在取消暂存")))));
            foreach (var c in o.Staged) stack.Children.Add(ChangeRow(c, "staged"));
        }
        var changes = o.Changes.ToList();
        stack.Children.Add(SectionHeader(L("更改"), changes.Count + Math.Max(0, o.UntrackedCount - o.Untracked.Count),
            IconButton("arrow.uturn.backward", L("全部丢弃"), async () =>
            {
                if (changes.Count == 0) return;
                if (!await Dialogs.Confirm(L("丢弃全部 %@ 个文件的更改？已修改的文件会恢复原样，新文件会移到废纸篓。", changes.Count), L("全部丢弃"), destructive: true)) return;
                await repo.Perform("discard", new JsonObject { ["paths"] = new JsonArray(changes.Select(c => (JsonNode)c.Path).ToArray()) }, L("正在丢弃"), L("已丢弃更改"));
            }),
            IconButton("plus", L("全部暂存"), () => _ = repo.Perform("stage_all", null, L("正在暂存")))));
        if (changes.Count == 0 && o.Staged.Count == 0 && o.Conflicts.Count == 0)
            stack.Children.Add(Ui.Text(L("工作区干净，无未提交的更改"), 12, color: "Text2").Margin(14, 2, 14, 8));
        foreach (var c in changes) stack.Children.Add(ChangeRow(c, c.Status == "?" ? "untracked" : "unstaged"));
        if (o.Stashes.Count > 0)
        {
            stack.Children.Add(SectionHeader(L("贮藏"), o.Stashes.Count));
            foreach (var s in o.Stashes.Take(5)) stack.Children.Add(StashRow(s));
        }
        return new ScrollViewer { Content = stack, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
    }

    Control SyncBar(RepoOverview o)
    {
        var sessions = repo.CurrentTree is { } tree ? repo.SessionsInTree(tree.Path) : [];
        var branch = Ui.H(6, Ui.Sym("arrow.triangle.branch", 12, "Accent"), Ui.Text(o.Branch ?? (o.Oid is { } oid ? $"({oid[..Math.Min(8, oid.Length)]})" : L("（无提交）")), 13, FontWeight.SemiBold).Trim().Shrink());
        if (o.Upstream is { } up) branch.Children.Add(Ui.Text("→ " + up, 11, color: "Text2").Trim().Shrink());
        branch.Children.Add(new Spacer());
        if (sessions.Count > 0)
        {
            foreach (var s in sessions.Take(3)) branch.Children.Add(Ui.Dot(7, StateColor(s)));
            branch.Children.Add(Ui.Text(L("%@ 个会话", sessions.Count), 11, color: "Text2"));
        }
        branch.Children.Add(Ui.Sym("chevron.right", 9, "Text3"));
        var top = new Tap(branch.Pad(8, 4), () => { activity = "branches"; DrawActivityBar(); DrawSidebar(); }, 6).Keys("Transparent", "Fill08");
        var row = Ui.H(6);
        if (repo.Busy is { } busy) { row.Children.Add(new Spinner(14)); row.Children.Add(Ui.Text(busy, 12, color: "Text2").Trim()); }
        else
        {
            if (o.Remotes.Count > 0)
            {
                row.Children.Add(Form.Button((o.Behind > 0 ? L("拉取 %@", o.Behind) : L("拉取")), () => _ = repo.Perform("pull", null, L("正在拉取"), L("已拉取"))).Tip(L("拉取")));
                row.Children.Add(Form.Button(o.Ahead > 0 ? L("推送 %@", o.Ahead) : o.Upstream is null ? L("发布分支") : L("推送到远端"),
                    () => _ = repo.Perform("push", null, L("正在推送"), o.Upstream is null ? L("已推送并关联远端分支") : L("已推送"))));
            }
            else row.Children.Add(Ui.Text(L("未配置远端仓库"), 11.5, color: "Text2"));
            row.Children.Add(new Spacer());
            var more = IconButton("ellipsis.circle", L("更多"), () => { });
            more.Menu(() => SyncMenu(o));
            more.Click = () => more.ContextMenu?.Open(more);
            row.Children.Add(more);
        }
        return Ui.VFill(6, top, row.Pad(8, 0)).Pad(6, 8, 6, 4);
    }

    IEnumerable<Control> SyncMenu(RepoOverview o)
    {
        var items = new List<Control>();
        if (o.Remotes.Count > 0)
        {
            items.Add(Ui.Item(L("获取"), () => _ = repo.Perform("fetch", null, L("正在获取"), L("已获取远端更新"))));
            items.Add(Ui.Item(L("拉取（合并）"), () => _ = repo.Perform("pull", new JsonObject { ["rebase"] = false }, L("正在拉取"), L("已拉取"))));
            items.Add(Ui.Item(L("拉取（变基）"), () => _ = repo.Perform("pull", new JsonObject { ["rebase"] = true }, L("正在拉取"), L("已拉取"))));
            items.Add(Ui.Item(L("强制推送"), async () =>
            {
                if (!await Dialogs.Confirm(L("强制推送会用本地的「%@」覆盖远端分支（使用 --force-with-lease：远端有别人新推的提交时会拒绝）。确定吗？", o.Branch ?? ""), L("强制推送"), destructive: true)) return;
                await repo.Perform("push", new JsonObject { ["force"] = true }, L("正在推送"), L("已强制推送"));
            }));
            items.Add(Ui.Divider());
        }
        items.Add(Ui.Item(L("贮藏更改"), () => _ = repo.Perform("stash_save", null, L("正在贮藏"), L("已贮藏更改"))));
        items.Add(Ui.Item(L("贮藏（含未跟踪的文件）"), () => _ = repo.Perform("stash_save", new JsonObject { ["untracked"] = true }, L("正在贮藏"), L("已贮藏更改"))));
        if (o.Stashes.Count > 0) items.Add(Ui.Item(L("恢复最近的贮藏"), () => _ = repo.Perform("stash_pop", new JsonObject { ["ref"] = "stash@{0}" }, L("正在恢复"), L("已恢复最近的贮藏"))));
        items.Add(Ui.Divider());
        items.Add(Ui.Item(L("新建分支…"), () => NewBranch(null)));
        items.Add(Ui.Item(L("分支与会话"), () => { activity = "branches"; DrawActivityBar(); DrawSidebar(); }));
        items.Add(Ui.Item(L("提交历史"), () => OpenTab(new Tab("history"))));
        items.Add(Ui.Divider());
        items.Add(Ui.Item(L("刷新"), () => _ = repo.Refresh()));
        return items;
    }

    Control StateBanner(string state, RepoOverview o)
    {
        var title = state switch { "rebase" => L("正在变基"), "cherry-pick" => L("正在拣选"), "revert" => L("正在还原"), _ => L("正在合并") };
        var text = Ui.Text(title + (o.Conflicts.Count == 0 ? L("：冲突已全部解决，可以继续") : L("：还有 %@ 个冲突", o.Conflicts.Count)), 12.5, FontWeight.SemiBold,
            o.Conflicts.Count == 0 ? "Added" : "Orange", lines: 0).Wrap();
        var buttons = Ui.H(8);
        if (o.Conflicts.Count == 0) buttons.Children.Add(Form.Button(L("继续"), () => _ = repo.Perform("continue", null, L("正在继续"), L("已完成")), prominent: true));
        if (state != "merge") buttons.Children.Add(Form.Button(L("跳过此提交"), () => _ = repo.Perform("skip", null, L("正在跳过"))));
        buttons.Children.Add(Form.Button(L("中止"), async () =>
        {
            if (await Dialogs.Confirm(L("放弃这次操作？仓库会回到开始之前的状态。"), L("中止"), destructive: true)) await repo.Perform("abort", null, L("正在放弃"), L("已放弃"));
        }));
        return new Border { Child = Ui.VFill(8, text, buttons).Pad(10), CornerRadius = new CornerRadius(8), Margin = new Thickness(10, 4, 10, 4) }.Res(Border.BackgroundProperty, "OrangeFill13");
    }

    Control CommitBox(RepoOverview o)
    {
        var box = new TextBox
        {
            Watermark = L("提交信息（在「%@」上提交）", o.Branch ?? "HEAD"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 56, MaxHeight = 160,
            FontSize = Look.Pt(12.5), Padding = new Thickness(8, 6), Text = commitDraft,
        };
        box.TextChanged += (_, _) => commitDraft = box.Text ?? "";
        void Commit(bool push = false, bool all = false, bool amend = false)
        {
            var message = (box.Text ?? "").Trim();
            if (message.Length == 0 && !amend) { AppModel.Shared.Flash(L("请先填写提交信息")); box.Focus(); return; }
            _ = Run();
            async Task Run()
            {
                var body = new JsonObject { ["message"] = message };
                if (all || (o.Staged.Count == 0 && !amend)) body["all"] = true;
                if (amend) body["amend"] = true;
                if (await repo.Perform("commit", body, L("正在提交"), push ? null : amend ? L("已修改上一次提交") : L("已提交")) is null) return;
                commitDraft = "";
                DrawSidebar();
                if (push) await repo.Perform("push", null, L("正在推送"), L("已提交并推送"));
            }
        }
        var command = OperatingSystem.IsMacOS() ? KeyModifiers.Meta : KeyModifiers.Control;
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter && e.KeyModifiers == command) { Commit(); e.Handled = true; } };
        var label = o.Staged.Count == 0 && o.Changes.Any() ? L("提交全部") : L("提交改动");
        var commit = new Tap(Ui.H(6, Ui.Sym("checkmark", 12, "White"), Ui.Text(label, 13, FontWeight.SemiBold, "White")).HAlign(HorizontalAlignment.Center), () => Commit(), 6) { Height = 28 }
            .Keys("Accent", "Accent");
        var more = IconButton("chevron.down", L("更多"), () => { });
        more.Menu(() =>
        {
            var items = new List<Control>
            {
                Ui.Item(L("提交并推送"), () => Commit(push: true)),
                Ui.Item(L("提交全部更改（含未暂存）"), () => Commit(all: true)),
                Ui.Item(L("修改上一次提交"), () => Commit(amend: true)),
            };
            if (AppModel.Shared.Session(key)?.CanReply == true)
            {
                items.Add(Ui.Divider());
                items.Add(Ui.Item(L("让 Claude 写提交信息并提交"), () =>
                {
                    AppModel.Shared.Send(key, L("请把当前的改动提交到 git：先看 git status 和 git diff，只提交和这次任务相关的文件，写一条简洁的中文提交信息，然后 git commit。先不要推送，提交完告诉我提交号和改了哪些文件。"), []);
                    AppModel.Shared.Flash(L("已发送给 Claude"));
                }));
            }
            return items;
        });
        more.Click = () => more.ContextMenu?.Open(more);
        var buttons = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 6 };
        Grid.SetColumn(more, 1);
        buttons.Children.Add(commit);
        buttons.Children.Add(more);
        return Ui.VFill(8, box, buttons).Pad(12, 6, 12, 6);
    }

    string commitDraft = "";

    Control ChangeRow(RepoChange c, string mode)
    {
        var name = Ui.Text(c.Name, 12.5, color: c.Status == "D" ? "Text2" : "Text").Trim();
        if (c.Status == "D") name.TextDecorations = TextDecorations.Strikethrough;
        var left = Ui.VFill(0, name, c.Folder.Length > 0 || c.OldPath is not null ? Ui.Text(c.OldPath is { } old ? L("由 %@ 重命名", old) : c.Folder, 10.5, color: "Text2").Trim() : null).Shrink();
        var row = Ui.H(6, left, new Spacer());
        // 鼠标移上去出按钮（同 VS Code）
        var actions = Ui.H(0);
        actions.IsVisible = false;
        if (c.Status == "U")
        {
            actions.Children.Add(IconButton("doc.text", L("打开文件解决冲突"), () => OpenFile(c.Path)));
            actions.Children.Add(IconButton("checkmark", L("标记为已解决（暂存）"), () => _ = repo.Perform("resolve", new JsonObject { ["path"] = c.Path }, L("正在解决"), L("已标记为已解决"))));
        }
        else if (mode == "staged")
        {
            actions.Children.Add(IconButton("doc.text", L("打开文件"), () => OpenFile(c.Path)));
            actions.Children.Add(IconButton("minus", L("取消暂存"), () => _ = repo.Perform("unstage", new JsonObject { ["paths"] = new JsonArray(c.Path) }, L("正在取消暂存"))));
        }
        else
        {
            if (c.Status != "D") actions.Children.Add(IconButton("doc.text", L("打开文件"), () => OpenFile(c.Path)));
            actions.Children.Add(IconButton("arrow.uturn.backward", L("丢弃更改"), () => Discard(c)));
            actions.Children.Add(IconButton("plus", L("暂存"), () => _ = repo.Perform("stage", new JsonObject { ["paths"] = new JsonArray(c.Path) }, L("正在暂存"))));
        }
        row.Children.Add(actions);
        if (c.Add + c.Del > 0)
        {
            var counts = new TextBlock { FontSize = Look.Pt(10.5), Inlines = [] };
            var a = new Avalonia.Controls.Documents.Run($"+{c.Add}");
            a.Bind(Avalonia.Controls.Documents.Run.ForegroundProperty, counts.GetResourceObservable("Added"));
            var d = new Avalonia.Controls.Documents.Run($" −{c.Del}");
            d.Bind(Avalonia.Controls.Documents.Run.ForegroundProperty, counts.GetResourceObservable("Removed"));
            counts.Inlines.Add(a);
            counts.Inlines.Add(d);
            row.Children.Add(counts);
        }
        row.Children.Add(StatusLetter(c.Status));
        var tap = new Tap(row.Pad(14, 3, 10, 3), () => { if (c.Status == "U") OpenFile(c.Path); else OpenDiff(c, mode); }, 0).Keys("Transparent", "Fill08");
        tap.PointerEntered += (_, _) => actions.IsVisible = true;
        tap.PointerExited += (_, _) => actions.IsVisible = false;
        tap.Menu(() =>
        {
            var items = new List<Control>();
            if (c.Status == "U")
            {
                items.Add(Ui.Item(L("打开文件解决冲突"), () => OpenFile(c.Path)));
                items.Add(Ui.Item(L("使用当前分支的版本"), () => _ = repo.Perform("resolve", new JsonObject { ["path"] = c.Path, ["side"] = "ours" }, L("正在解决"), L("已使用当前分支的版本"))));
                items.Add(Ui.Item(L("使用传入的版本"), () => _ = repo.Perform("resolve", new JsonObject { ["path"] = c.Path, ["side"] = "theirs" }, L("正在解决"), L("已使用传入的版本"))));
                items.Add(Ui.Item(L("标记为已解决（暂存）"), () => _ = repo.Perform("resolve", new JsonObject { ["path"] = c.Path }, L("正在解决"), L("已标记为已解决"))));
            }
            else
            {
                items.Add(Ui.Item(L("打开文件"), () => OpenFile(c.Path), c.Status != "D"));
                if (mode == "staged") items.Add(Ui.Item(L("取消暂存"), () => _ = repo.Perform("unstage", new JsonObject { ["paths"] = new JsonArray(c.Path) }, L("正在取消暂存"))));
                else
                {
                    items.Add(Ui.Item(L("暂存"), () => _ = repo.Perform("stage", new JsonObject { ["paths"] = new JsonArray(c.Path) }, L("正在暂存"))));
                    items.Add(Ui.Item(L("丢弃更改"), () => Discard(c)));
                }
            }
            items.Add(Ui.Divider());
            items.Add(Ui.Item(L("拷贝相对路径"), () => Copy(c.Path)));
            items.Add(Ui.Item(L("在对话中引用"), () => Quote(c.Path), AppModel.Shared.Session(key)?.CanReply == true));
            return items;
        });
        return tap;
    }

    async void Discard(RepoChange c)
    {
        var message = c.Status == "?" ? L("删除未跟踪的文件「%@」？文件会移到废纸篓。", c.Name) : L("丢弃「%@」的更改？文件会恢复到暂存区（或上一次提交）的样子，此操作无法撤销。", c.Name);
        if (!await Dialogs.Confirm(message, c.Status == "?" ? L("移到废纸篓") : L("丢弃更改"), destructive: true)) return;
        await repo.Perform("discard", new JsonObject { ["paths"] = new JsonArray(c.Path) }, L("正在丢弃"), L("已丢弃更改"));
    }

    Control StashRow(RepoStash s)
    {
        var row = Ui.H(8, Ui.Sym("archivebox", 12, "Text2"), Ui.VFill(0, Ui.Text(s.Title, 12.5).Trim(), Ui.Text(s.Ref + (s.Ts is { } ts ? " · " + Relative(ts) : ""), 10.5, color: "Text2").Trim()).Shrink());
        var tap = new Tap(row.Pad(14, 3, 10, 3), null, 0).Keys("Transparent", "Fill08");
        tap.Menu(() =>
        [
            Ui.Item(L("应用"), () => _ = repo.Perform("stash_apply", new JsonObject { ["ref"] = s.Ref }, L("正在应用"), L("已应用贮藏"))),
            Ui.Item(L("恢复并删除"), () => _ = repo.Perform("stash_pop", new JsonObject { ["ref"] = s.Ref }, L("正在恢复"), L("已恢复并删除贮藏"))),
            Ui.Item(L("查看提交"), () => OpenTab(new Tab("commit", Commit: s.Hash))),
            Ui.Divider(),
            Ui.Item(L("删除"), async () =>
            {
                if (await Dialogs.Confirm(L("删除贮藏「%@」？此操作无法撤销。", s.Title), L("删除"), destructive: true))
                    await repo.Perform("stash_drop", new JsonObject { ["ref"] = s.Ref }, L("正在删除"), L("已删除贮藏"));
            }),
        ]);
        return tap;
    }

    /// 会话状态点的颜色（资源名）：待确认橙、运行中强调色、空闲灰
    static string StateColor(SessionInfo s) => s.IsWaiting ? "Orange" : s.IsBusy ? "Accent" : "Text3";

    // MARK: 对比工具条

    Control DiffBar(Tab tab, DiffPayload payload)
    {
        var mode = payload.Mode switch { "staged" => L("已暂存"), "untracked" => L("新文件"), "commit" => L("提交中的改动"), _ => L("工作区") };
        var bar = Ui.H(8, new Border { Child = Ui.Text(mode, 11, FontWeight.SemiBold, "Text2"), Padding = new Thickness(7, 1), CornerRadius = new CornerRadius(8) }.Res(Border.BackgroundProperty, "Fill08"),
            Ui.Text(tab.Path, 12, color: "Text2").Trim().Shrink(), new Spacer());
        bar.Children.Add(IconButton(split ? "square.split.2x1" : "square.split.1x2", split ? L("改为行内对比") : L("改为并排对比"), () => { split = !split; diff.Show(payload, split, Palette.IsDark); DrawHeader(); }));
        if (payload.Mode != "commit")
        {
            bar.Children.Add(IconButton("doc.text", L("打开文件"), () => OpenFile(payload.Path)));
            var menu = IconButton(payload.Mode == "staged" ? "minus.circle" : "plus.circle", payload.Mode == "staged" ? L("取消暂存") : L("暂存"), () => { });
            menu.Menu(() => HunkMenu(tab, payload));
            menu.Click = () => menu.ContextMenu?.Open(menu);
            bar.Children.Add(menu);
        }
        return new Border { Child = bar.Pad(12, 0), Height = 30, BorderThickness = new Thickness(0, 0, 0, 1) }.Res(Border.BackgroundProperty, "Fill03").Res(Border.BorderBrushProperty, "Separator");
    }

    IEnumerable<Control> HunkMenu(Tab tab, DiffPayload payload)
    {
        async Task Do(string op, JsonObject body, string done)
        {
            if (await repo.Perform(op, body, L("正在处理"), done) is null) return;
            diffs.Remove(tab.Id);
            await LoadDiff(tab);
        }
        var items = new List<Control>();
        if (payload.Mode == "staged") items.Add(Ui.Item(L("取消暂存整个文件"), () => _ = Do("unstage", new JsonObject { ["paths"] = new JsonArray(payload.Path) }, L("已取消暂存"))));
        else
        {
            items.Add(Ui.Item(L("暂存整个文件"), () => _ = Do("stage", new JsonObject { ["paths"] = new JsonArray(payload.Path) }, L("已暂存"))));
            items.Add(Ui.Item(L("丢弃整个文件的更改"), async () =>
            {
                if (await Dialogs.Confirm(L("丢弃「%@」的全部更改？", CodePaths.Name(payload.Path)), L("丢弃更改"), destructive: true))
                    await Do("discard", new JsonObject { ["paths"] = new JsonArray(payload.Path) }, L("已丢弃更改"));
            }));
        }
        if (payload.Hunks.Count > 0 && payload.Mode != "untracked")
        {
            items.Add(Ui.Divider());
            for (var i = 0; i < payload.Hunks.Count; i++)
            {
                var index = i;
                var header = payload.Hunks[i];
                var sub = new List<Control>();
                if (payload.Mode == "staged")
                    sub.Add(Ui.Item(L("取消暂存此区块"), () => _ = Do("unstage_hunk", new JsonObject { ["path"] = payload.Path, ["hunk"] = index, ["header"] = header }, L("已取消暂存此区块"))));
                else
                {
                    sub.Add(Ui.Item(L("暂存此区块"), () => _ = Do("stage_hunk", new JsonObject { ["path"] = payload.Path, ["hunk"] = index, ["header"] = header }, L("已暂存此区块"))));
                    sub.Add(Ui.Item(L("丢弃此区块"), async () =>
                    {
                        if (await Dialogs.Confirm(L("丢弃这一块改动？此操作无法撤销。"), L("丢弃"), destructive: true))
                            await Do("discard_hunk", new JsonObject { ["path"] = payload.Path, ["hunk"] = index, ["header"] = header }, L("已丢弃此区块"));
                    }));
                }
                items.Add(Ui.Submenu(L("区块 %@：%@", index + 1, HunkLabel(header)), sub));
            }
        }
        return items;
    }

    /// 「@@ -12,7 +12,9 @@ func foo()」→「第 12 行 func foo()」
    static string HunkLabel(string header)
    {
        var m = System.Text.RegularExpressions.Regex.Match(header, @"\+(\d+)");
        var context = header.Split("@@").Length > 2 ? header.Split("@@")[2].Trim() : "";
        return L("第 %@ 行", m.Success ? m.Groups[1].Value : "?") + (context.Length > 0 ? " " + context[..Math.Min(30, context.Length)] : "");
    }
}
