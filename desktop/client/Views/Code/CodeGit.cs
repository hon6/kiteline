using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views.Code;

// 分支与会话、提交历史（提交图）、提交详情（同 iOS 版 GitBranchesView / GitHistoryView）
public sealed partial class CodeWindow
{
    // MARK: 分支与会话

    Control BranchesPanel()
    {
        var o = repo.Overview;
        if (o is null) return Centered(new Spinner(16));
        if (o.Repo is null) return Centered(Ui.Text(o.Reason ?? L("不是 Git 仓库"), 12.5, color: "Text2"));
        var stack = new StackPanel();
        var groups = repo.SessionGroups();
        var count = groups.Sum(g => g.Sessions.Count);
        var branchCount = groups.Where(g => g.Sessions.Count > 0).Select(g => g.Branch ?? "").Distinct().Count();
        stack.Children.Add(Ui.H(8, Ui.Text(L("会话与分支"), 11.5, FontWeight.SemiBold, "Text2"), new Spacer(),
            Ui.Text(count == 0 ? L("此仓库暂无运行中的会话") : L("%@ 个会话", count) + L("分布在 %@ 个分支上", branchCount), 11, color: "Text2")).Pad(12, 12, 12, 6));
        foreach (var g in groups) stack.Children.Add(TreeCard(g.Tree, g.Branch, g.Sessions, o));
        if (o.Worktrees.Count > 1 || count > 0)
            stack.Children.Add(Ui.Text(L("每个工作树是一个独立目录，可以同时检出不同的分支；在不同分支上并行工作的会话互不干扰。"), 11, color: "Text3", lines: 0).Wrap().Margin(14, 2, 14, 4));
        stack.Children.Add(SectionHeader(L("本地分支"), o.Branches.Count, IconButton("plus", L("新建分支"), () => NewBranch(null))));
        foreach (var b in o.Branches) stack.Children.Add(BranchRow(b, o));
        foreach (var remote in o.RemoteBranches.GroupBy(r => r.Remote).OrderBy(r => r.Key))
        {
            stack.Children.Add(SectionHeader(L("远端 %@", remote.Key), remote.Count(), IconButton("arrow.clockwise", L("获取"), () => _ = repo.Perform("fetch", null, L("正在获取"), L("已获取远端更新")))));
            foreach (var r in remote) stack.Children.Add(RemoteRow(r, o));
        }
        if (o.Tags.Count > 0)
        {
            stack.Children.Add(SectionHeader(L("标签"), o.Tags.Count));
            foreach (var t in o.Tags.Take(30)) stack.Children.Add(TagRow(t));
        }
        if (o.Stashes.Count > 0)
        {
            stack.Children.Add(SectionHeader(L("贮藏"), o.Stashes.Count));
            foreach (var s in o.Stashes) stack.Children.Add(StashRow(s));
        }
        return new ScrollViewer { Content = stack, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
    }

    static Control Chip(string text) =>
        new Border { Child = Ui.Text(text, 10, color: "Text2").Trim(), Padding = new Thickness(6, 1), CornerRadius = new CornerRadius(8) }.Res(Border.BackgroundProperty, "Fill08");

    Control TreeCard(RepoWorktree? tree, string? branch, List<SessionInfo> sessions, RepoOverview o)
    {
        var local = branch is null ? null : o.Branches.FirstOrDefault(b => b.Name == branch);
        var here = tree is not null && RepoState.Normalize(tree.Path) == RepoState.Normalize(o.Repo ?? "");
        var head = Ui.H(6, Ui.Sym("arrow.triangle.branch", 12, "Accent"), Ui.Text(branch ?? L("（未知分支）"), 13, FontWeight.SemiBold).Trim().Shrink());
        if (local is { } l && l.Ahead + l.Behind > 0)
            head.Children.Add(Ui.Text(string.Join(" ", new[] { l.Ahead > 0 ? $"↑{l.Ahead}" : null, l.Behind > 0 ? $"↓{l.Behind}" : null }.OfType<string>()), 11, color: "Text2"));
        head.Children.Add(new Spacer());
        if (here) head.Children.Add(Chip(L("此目录")));
        if (tree is not null) head.Children.Add(Chip(tree.Main ? L("主工作树") : L("工作树 %@", tree.Name)));
        var stack = new StackPanel { Spacing = 2, Children = { head } };
        if (sessions.Count == 0) stack.Children.Add(Ui.Text(L("暂无会话"), 11.5, color: "Text3").Margin(20, 2, 0, 2));
        foreach (var s in sessions)
        {
            // 标题优先：状态文字（正在跑的命令）长了先截它
            var state = Ui.Text(s.IsWaiting ? L("待确认") : s.IsBusy ? (s.ActivityText ?? L("运行中")) : L("空闲"), 11, color: s.IsWaiting ? "Orange" : "Text2").Trim().MaxW(120);
            var row = Ui.H(8, Ui.Dot(7, StateColor(s)), Ui.Text(s.Title, 12.5).Trim().MinW(Math.Min(140, 13 * s.Title.Length)).Shrink(), new Spacer(), state.Shrink(),
                Ui.Sym("chevron.right", 9, "Text3"));
            stack.Children.Add(new Tap(row.Pad(20, 3, 4, 3), () => { MainModel.Shared.Selection = s.Key; MainWindow.Current?.Activate(); }, 5).Keys("Transparent", "Fill08")
                .Tip(L("切到这个会话")));
        }
        if (tree is { Main: false } && sessions.Count == 0) stack.Children.Add(Ui.Text(tree.Path, 10.5, color: "Text3").Trim().Margin(20, 0, 0, 0));
        var card = new Border { Child = stack.Pad(10, 8), CornerRadius = new CornerRadius(8), Margin = new Thickness(10, 3, 10, 3) }.Res(Border.BackgroundProperty, "Fill05");
        if (tree is { Main: false } t2)
            card.Menu(() =>
            [
                Ui.Item(L("拷贝工作树路径"), () => Copy(t2.Path)),
                Ui.Item(L("移除工作树"), async () =>
                {
                    if (sessions.Count > 0) { AppModel.Shared.Flash(L("这个工作树里还有会话在运行，请先结束它们")); return; }
                    if (await Dialogs.Confirm(L("移除工作树「%@」？目录会被删除（分支保留）。有未提交的更改时会拒绝。", t2.Name), L("移除"), destructive: true))
                        await repo.Perform("worktree_remove", new JsonObject { ["path"] = t2.Path }, L("正在移除"), L("已移除工作树"));
                }),
            ]);
        return card;
    }

    Control BranchRow(RepoBranch b, RepoOverview o)
    {
        var sessions = repo.SessionsOnBranch(b.Name);
        var elsewhere = b.Worktree is { } w && RepoState.Normalize(w) != RepoState.Normalize(o.Repo ?? "");
        var title = Ui.H(5, Ui.Text(b.Name, 12.5, b.Current ? FontWeight.SemiBold : FontWeight.Normal).Trim().Shrink());
        if (b.Ahead > 0) title.Children.Add(Ui.Text($"↑{b.Ahead}", 10.5, color: "Accent"));
        if (b.Behind > 0) title.Children.Add(Ui.Text($"↓{b.Behind}", 10.5, color: "Orange"));
        var sub = string.Join(" · ", new[] { b.Upstream is { } u ? (b.Gone ? L("%@（远端已删除）", u) : u) : null, Relative(b.Ts), b.Subject }.Where(x => !string.IsNullOrEmpty(x)));
        var row = Ui.H(8, Ui.Sym(b.Current ? "checkmark.circle" : "arrow.triangle.branch", 12, b.Current ? "Accent" : "Text2").Width(16),
            Ui.VFill(1, title, Ui.Text(sub, 10.5, color: "Text2").Trim()).Shrink(), new Spacer());
        if (sessions.Count > 0)
        {
            foreach (var s in sessions.Take(3)) row.Children.Add(Ui.Dot(7, StateColor(s)));
            row.Children.Add(Ui.Text(sessions.Count.ToString(), 10.5, color: "Text2"));
        }
        if (elsewhere) row.Children.Add(Ui.Sym("folder.badge.gearshape", 11, "Text2").Tip(L("已在另一个工作树中检出")));
        var tap = new Tap(row.Pad(12, 4, 10, 4), null, 0).Keys("Transparent", "Fill08");
        tap.DoubleTapped += (_, _) => { if (!b.Current && !elsewhere) Checkout(b.Name); };
        tap.Menu(() =>
        {
            var items = new List<Control>();
            if (!b.Current && !elsewhere) items.Add(Ui.Item(L("切换到此分支"), () => Checkout(b.Name)));
            items.Add(Ui.Item(L("查看最新提交"), () => OpenTab(new Tab("commit", Commit: b.Hash))));
            if (!b.Current)
            {
                items.Add(Ui.Item(L("合并到当前分支"), async () =>
                {
                    if (await Dialogs.Confirm(L("把「%@」合并到当前分支「%@」？", b.Name, o.Branch ?? "HEAD"), L("合并")))
                        await repo.Perform("merge", new JsonObject { ["ref"] = b.Name }, L("正在合并"), L("已合并「%@」", b.Name));
                }));
                items.Add(Ui.Item(L("将当前分支变基到此"), async () =>
                {
                    if (await Dialogs.Confirm(L("把当前分支「%@」变基到「%@」上？当前分支的提交会被改写。", o.Branch ?? "HEAD", b.Name), L("变基")))
                        await repo.Perform("rebase", new JsonObject { ["ref"] = b.Name }, L("正在变基"), L("已变基到「%@」", b.Name));
                }));
            }
            items.Add(Ui.Divider());
            items.Add(Ui.Item(L("从此新建分支…"), () => NewBranch(b.Name)));
            if (!elsewhere && !b.Current)
                items.Add(Ui.Item(L("在新工作树中检出"), async () =>
                {
                    if (await Dialogs.Confirm(L("为「%@」新建一个工作树？会在仓库旁的「-worktrees」目录里检出这个分支，方便另开会话并行工作。", b.Name), L("新建工作树")))
                        await repo.Perform("worktree_add", new JsonObject { ["branch"] = b.Name }, L("正在新建工作树"), L("已新建工作树"));
                }));
            items.Add(Ui.Item(L("重命名…"), async () =>
            {
                if (await Prompt(L("重命名分支"), null, b.Name, b.Name, L("重命名")) is { } name && name != b.Name)
                    await repo.Perform("branch_rename", new JsonObject { ["name"] = b.Name, ["to"] = name }, L("正在重命名"), L("已重命名为「%@」", name));
            }));
            if (b.Current && o.Remotes.Count > 0) items.Add(Ui.Item(L("推送到远端"), () => _ = repo.Perform("push", null, L("正在推送"), L("已推送"))));
            items.Add(Ui.Item(L("拷贝分支名"), () => Copy(b.Name)));
            if (!b.Current && !elsewhere)
            {
                items.Add(Ui.Divider());
                items.Add(Ui.Item(L("删除分支…"), () => DeleteBranch(b)));
            }
            return items;
        });
        return tap;
    }

    async void Checkout(string name)
    {
        var here = repo.CurrentTree is { } tree ? repo.SessionsInTree(tree.Path) : [];
        if (here.Count > 0)
        {
            var running = here.Where(s => s.IsBusy || s.IsWaiting).ToList();
            var names = string.Join("、", here.Take(3).Select(s => $"「{s.Title}」"));
            var lead = running.Count == 0 ? L("此目录中有 %@ 个会话", here.Count) : L("此目录中有 %@ 个会话正在运行", running.Count);
            if (!await Dialogs.Confirm(lead + L("（%@）。", names) + L("切换分支会改变它们看到的文件。如需并行工作，建议「在新工作树中检出」。仍要切换吗？"),
                    L("仍然切换"), destructive: running.Count > 0)) return;
        }
        await repo.Perform("checkout", new JsonObject { ["ref"] = name }, L("正在切换"), L("已切换到「%@」", name));
    }

    async void DeleteBranch(RepoBranch b)
    {
        if (!await Dialogs.Confirm(L("删除分支「%@」？", b.Name), L("删除"), destructive: true)) return;
        try { await CodeApi.Run(key, "branch_delete", new JsonObject { ["name"] = b.Name }); AppModel.Shared.Flash(L("已删除分支「%@」", b.Name)); }
        catch (GitError e) when (e.Detail?.Contains("not fully merged") == true)
        {
            if (await Dialogs.Confirm(L("「%@」还有未合并到其他分支的提交，删除后这些提交将难以找回。仍要强制删除吗？", b.Name), L("强制删除"), destructive: true))
                await repo.Perform("branch_delete", new JsonObject { ["name"] = b.Name, ["force"] = true }, L("正在删除"), L("已删除分支「%@」", b.Name));
        }
        catch (GitError e) { await RepoState.ShowError(e.Message, e.Detail); }
        await repo.Refresh();
    }

    async void NewBranch(string? from)
    {
        var name = await Prompt(from is null ? L("新建分支") : L("从「%@」新建分支", from), from is null ? L("从当前位置新建并切换过去") : null, "", "feature/name", L("创建并切换"));
        if (name is null) return;
        var body = new JsonObject { ["name"] = name };
        if (from is not null) body["from"] = from;
        await repo.Perform("branch_create", body, L("正在创建分支"), L("已切换到新分支「%@」", name));
    }

    Control RemoteRow(RepoRemoteBranch r, RepoOverview o)
    {
        var sessions = repo.SessionsOnBranch(r.Branch);
        var row = Ui.H(8, Ui.Sym("cloud", 12, "Text2").Width(16),
            Ui.VFill(1, Ui.Text(r.Branch, 12.5).Trim(), Ui.Text(string.Join(" · ", new[] { Relative(r.Ts), r.Subject }.Where(x => x.Length > 0)), 10.5, color: "Text2").Trim()).Shrink(),
            new Spacer(), sessions.Count > 0 ? Ui.Text(L("%@ 个会话", sessions.Count), 10.5, color: "Text2") : null);
        var tap = new Tap(row.Pad(12, 4, 10, 4), null, 0).Keys("Transparent", "Fill08");
        tap.Menu(() =>
        [
            Ui.Item(L("检出（建立本地跟踪分支）"), () => _ = repo.Perform("checkout", new JsonObject { ["ref"] = r.Name, ["remote"] = true }, L("正在检出"), L("已切换到「%@」", r.Branch))),
            Ui.Item(L("查看最新提交"), () => OpenTab(new Tab("commit", Commit: r.Hash))),
            Ui.Item(L("合并到当前分支"), async () =>
            {
                if (await Dialogs.Confirm(L("把「%@」合并到当前分支「%@」？", r.Name, o.Branch ?? "HEAD"), L("合并")))
                    await repo.Perform("merge", new JsonObject { ["ref"] = r.Name }, L("正在合并"), L("已合并「%@」", r.Name));
            }),
            Ui.Item(L("拷贝分支名"), () => Copy(r.Name)),
            Ui.Divider(),
            Ui.Item(L("删除远端分支…"), async () =>
            {
                if (await Dialogs.Confirm(L("从远端「%@」上删除分支「%@」？其他人也将看不到这个分支。", r.Remote, r.Branch), L("删除远端分支"), destructive: true))
                    await repo.Perform("remote_branch_delete", new JsonObject { ["remote"] = r.Remote, ["branch"] = r.Branch }, L("正在删除"), L("已删除远端分支"));
            }),
        ]);
        return tap;
    }

    Control TagRow(RepoTag t)
    {
        var row = Ui.H(8, Ui.Sym("tag", 12, "Orange").Width(16),
            Ui.VFill(1, Ui.Text(t.Name, 12.5).Trim(), Ui.Text(string.Join(" · ", new[] { Relative(t.Ts), t.Subject }.Where(x => x.Length > 0)), 10.5, color: "Text2").Trim()).Shrink());
        var tap = new Tap(row.Pad(12, 4, 10, 4), () => OpenTab(new Tab("commit", Commit: t.Hash)), 0).Keys("Transparent", "Fill08");
        tap.Menu(() =>
        [
            Ui.Item(L("查看提交"), () => OpenTab(new Tab("commit", Commit: t.Hash))),
            Ui.Item(L("检出"), () => _ = repo.Perform("checkout", new JsonObject { ["ref"] = t.Name, ["detach"] = true }, L("正在检出"), L("已检出标签「%@」", t.Name))),
            Ui.Item(L("拷贝标签名"), () => Copy(t.Name)),
            Ui.Divider(),
            Ui.Item(L("删除标签"), async () =>
            {
                if (await Dialogs.Confirm(L("删除本地标签「%@」？", t.Name), L("删除"), destructive: true))
                    await repo.Perform("tag_delete", new JsonObject { ["name"] = t.Name }, L("正在删除"), L("已删除标签"));
            }),
        ]);
        return tap;
    }

    // MARK: 提交历史（提交图）

    Control HistoryView(string? path)
    {
        var rows = new StackPanel();
        var search = new TextBox { Watermark = L("搜索提交信息或提交号"), FontSize = Look.Pt(12.5), Padding = new Thickness(10, 4), Width = 360 };
        search.Classes.Add("search");
        var scope = new ComboBox { ItemsSource = new[] { L("全部分支"), L("当前分支") }, SelectedIndex = 0, IsVisible = path is null };
        var more = Form.Button(L("加载更多"), () => { });
        more.IsVisible = false;
        var commits = new List<CommitRow>();
        var width = 0;
        async Task Load(bool next)
        {
            try
            {
                var (list, w, hasMore) = await CodeApi.Log(key, next ? commits.Count : 0, 200, path, search.Text?.Trim(), scope.SelectedIndex == 1 ? "HEAD" : null);
                if (!next) { commits.Clear(); rows.Children.Clear(); width = w; }
                width = Math.Max(width, w);
                commits.AddRange(list);
                foreach (var c in list) rows.Children.Add(CommitLine(c, width));
                if (commits.Count == 0) rows.Children.Add(Ui.Text(string.IsNullOrEmpty(search.Text) ? L("还没有任何提交") : L("没有匹配的提交"), 12.5, color: "Text2").Margin(20, 20, 20, 20));
                more.IsVisible = hasMore;
            }
            catch (Exception e) { rows.Children.Clear(); rows.Children.Add(Ui.Text(e.Message, 12.5, color: "Text2", lines: 0).Wrap().Margin(20, 20, 20, 20)); }
        }
        more.Click = () => _ = Load(true);
        DispatcherTimer? debounce = null;
        search.TextChanged += (_, _) =>
        {
            debounce?.Stop();
            debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
            debounce.Tick += (_, _) => { debounce?.Stop(); _ = Load(false); };
            debounce.Start();
        };
        scope.SelectionChanged += (_, _) => _ = Load(false);
        _ = Load(false);
        var top = Ui.H(10, search, scope, new Spacer()).Pad(12, 8);
        var dock = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        dock.Children.Add(top);
        dock.Children.Add(new ScrollViewer { Content = new StackPanel { Children = { rows, more.HAlign(HorizontalAlignment.Center).Margin(0, 10, 0, 20) } } });
        return new Border { Child = dock }.Res(Border.BackgroundProperty, "Window");
    }

    Control CommitLine(CommitRow c, int width)
    {
        const double lane = 13, height = 28;
        var graph = c.Graph is { } g ? new GraphCell(g, lane, height, c.Refs.Any(r => r.Current), c.Parents.Count > 1) { Width = Math.Max(1, width) * lane + 6, Height = height } : null;
        var refs = Ui.H(3);
        foreach (var r in c.Refs.Take(4)) refs.Children.Add(RefChip(r, r.Type == "branch" ? repo.SessionsOnBranch(r.Name).Count : 0));
        var row = Ui.H(6, graph, refs, Ui.Text(c.Subject, 12.5).Trim().Shrink(), new Spacer(8),
            Ui.Text(c.Author, 11.5, color: "Text2").Trim().Width(110), Ui.Text(Relative(c.Ts), 11.5, color: "Text2").Trim().Width(80),
            Ui.Text(c.Short, 11, color: "Text3").Mono().Width(64));
        var tap = new Tap(row.Pad(6, 0, 10, 0), () => OpenTab(new Tab("commit", Commit: c.Hash)), 0) { Height = height }.Keys("Transparent", "Fill05");
        tap.Menu(() => CommitMenu(c.Hash, c.Short, c.Subject));
        return tap;
    }

    Control RefChip(RefLabel r, int sessions)
    {
        var (symbol, color) = r.Type switch { "tag" => ("tag", "Orange"), "remote" => ("cloud", "Text2"), _ => ("arrow.triangle.branch", "Accent") };
        var row = Ui.H(3, Ui.Sym(symbol, 9, r.Current ? "White" : color), Ui.Text(r.Name, 10.5, FontWeight.SemiBold, r.Current ? "White" : color).Trim());
        if (sessions > 0) row.Children.Add(new Border { Child = Ui.Text(sessions.ToString(), 9, FontWeight.Bold, r.Current ? "White" : "Accent"), Padding = new Thickness(4, 0), CornerRadius = new CornerRadius(6) }
            .Res(Border.BackgroundProperty, r.Current ? "Fill15" : "AccentFill14").Tip(L("%@ 个会话在此分支上", sessions)));
        var chip = new Border { Child = row, Padding = new Thickness(6, 1), CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(r.Current ? 0 : 0.7) }
            .Res(Border.BackgroundProperty, r.Current ? "Accent" : r.Type == "tag" ? "OrangeFill13" : r.Type == "remote" ? "Fill05" : "AccentFill10");
        chip.Res(Border.BorderBrushProperty, r.Type == "remote" ? "Separator" : "AccentEdge32");
        return chip.MaxW(180);
    }

    IEnumerable<Control> CommitMenu(string hash, string shortHash, string subject) =>
    [
        Ui.Item(L("拷贝提交号"), () => Copy(hash)),
        Ui.Item(L("拷贝提交信息"), () => Copy(subject)),
        Ui.Divider(),
        Ui.Item(L("新建分支…"), async () =>
        {
            if (await Prompt(L("从此提交新建分支"), shortHash, "", "feature/name", L("创建并切换")) is { } name)
                await repo.Perform("branch_create", new JsonObject { ["name"] = name, ["from"] = hash }, L("正在创建分支"), L("已切换到新分支「%@」", name));
        }),
        Ui.Item(L("新建标签…"), async () =>
        {
            if (await Prompt(L("新建标签"), shortHash, "", "v1.0.0", L("创建")) is { } name)
                await repo.Perform("tag_create", new JsonObject { ["name"] = name, ["ref"] = hash }, L("正在创建标签"), L("已创建标签「%@」", name));
        }),
        Ui.Item(L("检出此提交"), async () =>
        {
            if (await Dialogs.Confirm(L("检出提交 %@？会进入「游离 HEAD」状态，在这里的新提交不属于任何分支（可以随后新建分支保存）。", shortHash), L("检出")))
                await repo.Perform("checkout", new JsonObject { ["ref"] = hash, ["detach"] = true }, L("正在检出"), L("已检出 %@", shortHash));
        }),
        Ui.Divider(),
        Ui.Item(L("拣选到当前分支"), () => _ = repo.Perform("cherry_pick", new JsonObject { ["ref"] = hash }, L("正在拣选"), L("已拣选到当前分支"))),
        Ui.Item(L("还原此提交"), async () =>
        {
            if (await Dialogs.Confirm(L("新建一个提交来撤销 %@ 的改动？", shortHash), L("还原")))
                await repo.Perform("revert", new JsonObject { ["ref"] = hash }, L("正在还原"), L("已还原"));
        }),
        Ui.Submenu(L("将当前分支重置到这里"), [
            Ui.Item(L("软重置（保留改动并暂存）"), () => Reset(hash, shortHash, "soft")),
            Ui.Item(L("混合重置（保留改动，不暂存）"), () => Reset(hash, shortHash, "mixed")),
            Ui.Item(L("硬重置（丢弃所有改动）"), () => Reset(hash, shortHash, "hard")),
        ]),
    ];

    async void Reset(string hash, string shortHash, string mode)
    {
        var branch = repo.Overview?.Branch ?? "HEAD";
        var message = mode == "hard"
            ? L("把「%@」硬重置到 %@？之后的提交和所有未提交的更改都会丢失，此操作无法撤销。", branch, shortHash)
            : L("把「%@」重置到 %@？之后的提交会被撤出分支，文件改动保留在工作区。", branch, shortHash);
        if (await Dialogs.Confirm(message, L("重置"), destructive: mode == "hard"))
            await repo.Perform("reset", new JsonObject { ["ref"] = hash, ["mode"] = mode }, L("正在重置"), L("已重置到 %@", shortHash));
    }

    // MARK: 提交详情

    Control CommitView(string hash)
    {
        var host = new ContentControl { Content = Centered(new Spinner(18)) };
        async void Load()
        {
            try
            {
                var info = await CodeApi.Commit(key, hash);
                var message = info.Str("fullMessage") ?? "";
                var subject = message.Split('\n')[0];
                var body = string.Join("\n", message.Split('\n').Skip(1)).Trim();
                var stack = new StackPanel { Spacing = 6, Margin = new Thickness(20, 16, 20, 20) };
                var title = new SelectableTextBlock { Text = subject, FontSize = Look.Pt(16), FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap };
                title.Res(SelectableTextBlock.ForegroundProperty, "Text");
                stack.Children.Add(title);
                if (body.Length > 0)
                {
                    var b = new SelectableTextBlock { Text = body, FontSize = Look.Pt(12.5), TextWrapping = TextWrapping.Wrap };
                    b.Res(SelectableTextBlock.ForegroundProperty, "Text2");
                    stack.Children.Add(b);
                }
                var refs = Ui.H(4);
                foreach (var r in info.Arr("refs").Items().Select(RefLabel.Parse)) refs.Children.Add(RefChip(r, 0));
                if (refs.Children.Count > 0) stack.Children.Add(refs);
                Control Field(string label, Control value) => Ui.H(10, Ui.Text(label, 12, color: "Text2").Width(90), value.Shrink());
                stack.Children.Add(Field(L("作者"), Ui.Text($"{info.Str("author")} <{info.Str("email")}>", 12)));
                if (info.Num("ts") is double ts) stack.Children.Add(Field(L("时间"), Ui.Text(DateTimeOffset.FromUnixTimeMilliseconds((long)ts).ToLocalTime().ToString("yyyy-MM-dd HH:mm"), 12)));
                stack.Children.Add(Field(L("提交号"), new Tap(Ui.Text(hash[..Math.Min(12, hash.Length)], 12, color: "Accent").Mono(), () => Copy(hash), 3).Keys("Transparent", "Fill08")));
                var parents = info.Strings("parents");
                if (parents.Count > 0)
                {
                    var p = Ui.H(6);
                    foreach (var parent in parents) p.Children.Add(new Tap(Ui.Text(parent[..Math.Min(8, parent.Length)], 12, color: "Accent").Mono(), () => OpenTab(new Tab("commit", Commit: parent)), 3).Keys("Transparent", "Fill08"));
                    stack.Children.Add(Field(parents.Count > 1 ? L("父提交（合并）") : L("父提交"), p));
                }
                if (info.Strings("branches") is { Count: > 0 } branches) stack.Children.Add(Field(L("所在分支"), Ui.Text(string.Join(", ", branches.Take(6)), 12).Trim()));
                var filesList = info.Arr("files").Items().Select(RepoChange.Parse).ToList();
                stack.Children.Add(Ui.Text(L("%@ 个文件", filesList.Count) + $" · +{filesList.Sum(f => f.Add)} −{filesList.Sum(f => f.Del)}", 11.5, FontWeight.SemiBold, "Text2").Margin(0, 12, 0, 2));
                foreach (var f in filesList)
                {
                    var row = Ui.H(8, Ui.VFill(0, Ui.Text(f.Name, 12.5).Trim(), f.Folder.Length > 0 ? Ui.Text(f.Folder, 10.5, color: "Text2").Trim() : null).Shrink(), new Spacer(),
                        f.Add + f.Del > 0 ? Ui.Text($"+{f.Add} −{f.Del}", 10.5, color: "Text2") : null, StatusLetter(f.Status));
                    stack.Children.Add(new Tap(row.Pad(8, 3), () => OpenDiff(f, "commit", hash), 5).Keys("Transparent", "Fill08"));
                }
                var actions = IconButton("ellipsis.circle", L("更多"), () => { });
                actions.Menu(() => CommitMenu(hash, hash[..Math.Min(8, hash.Length)], subject));
                actions.Click = () => actions.ContextMenu?.Open(actions);
                var dock = new DockPanel();
                var bar = Ui.H(8, new Spacer(), actions).Pad(12, 6, 12, 0);
                DockPanel.SetDock(bar, Dock.Top);
                dock.Children.Add(bar);
                dock.Children.Add(new ScrollViewer { Content = stack });
                host.Content = dock;
            }
            catch (Exception e) { host.Content = Centered(Ui.Text(e.Message, 12.5, color: "Text2", lines: 0).Wrap()); }
        }
        Load();
        return new Border { Child = host }.Res(Border.BackgroundProperty, "Window");
    }
}

/// 提交图的一格（同 iOS 版 GraphCell）：竖线直画，换列的画成平滑的 S 形；合并提交空心圆，当前位置外面一圈
public sealed class GraphCell(GraphRow graph, double lane, double height, bool head, bool merge) : Control
{
    static readonly uint[] Colors = [0, 0x5B8DEF, 0x3FA77A, 0xA178DF, 0xD9A13B, 0xD9668F, 0x3BA9B6, 0x8E8E93];

    IBrush Brush(int index)
    {
        if (index % 8 == 0) return this.FindResource("Accent") switch { IBrush b => b, Color accent => new SolidColorBrush(accent), _ => Brushes.Orange };
        var c = Colors[index % 8];
        return new SolidColorBrush(Color.FromRgb((byte)(c >> 16), (byte)(c >> 8), (byte)c));
    }

    double X(int col) => col * lane + lane / 2 + 3;

    public override void Render(DrawingContext context)
    {
        double[] ys = [0, height / 2, height];
        foreach (var seg in graph.Segs.Where(s => s.Length >= 5))
        {
            var start = new Point(X(seg[0]), ys[Math.Clamp(seg[1], 0, 2)]);
            var end = new Point(X(seg[2]), ys[Math.Clamp(seg[3], 0, 2)]);
            var pen = new Pen(Brush(seg[4]), 1.6, lineCap: PenLineCap.Round);
            if (Math.Abs(start.X - end.X) < 0.1) { context.DrawLine(pen, start, end); continue; }
            var mid = (start.Y + end.Y) / 2;
            var geometry = new StreamGeometry();
            using (var g = geometry.Open())
            {
                g.BeginFigure(start, false);
                g.CubicBezierTo(new Point(start.X, mid), new Point(end.X, mid), end);
                g.EndFigure(false);
            }
            context.DrawGeometry(null, pen, geometry);
        }
        var center = new Point(X(graph.Col), height / 2);
        var r = head ? 5 : 4;
        var color = Brush(graph.Color);
        if (merge) context.DrawEllipse(Brushes.Transparent, new Pen(color, 1.8), center, r, r);
        else context.DrawEllipse(color, null, center, r, r);
        if (head) context.DrawEllipse(null, new Pen(color is ISolidColorBrush solid ? new SolidColorBrush(solid.Color, 0.45) : color, 1.4), center, r + 2.5, r + 2.5);
    }
}
