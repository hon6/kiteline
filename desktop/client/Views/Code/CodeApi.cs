using System.Text.Json.Nodes;
using Kiteline.Model;
using static Kiteline.Lang;

namespace Kiteline.Views.Code;

// 代码 IDE 的数据和接口（同 iOS 版 KitelineKit/Code/CodeModels.swift、RepoStore.swift）：/api/repo、/api/fs、/api/files、/api/file

/// Git 报错：一句能看懂的话 + git 的原话（冲突的文件、钩子的输出）
public sealed class GitError(string message, string? detail) : Exception(message)
{
    public string? Detail { get; } = detail;
}

public static class CodePaths
{
    public static string Name(string path) => path[(path.LastIndexOf('/') + 1)..];
    public static string Folder(string path) => path.LastIndexOf('/') is var i and >= 0 ? path[..i] : "";
    public static string Join(string folder, string name) => folder.Length == 0 ? name : folder + "/" + name;
    public static string Ext(string path) => Name(path).LastIndexOf('.') is var i and > 0 ? Name(path)[(i + 1)..].ToLowerInvariant() : "";
}

public sealed record RepoChange(string Path, string Status, string? OldPath, int Add, int Del, bool Binary)
{
    public string Name => CodePaths.Name(Path);
    public string Folder => CodePaths.Folder(Path);
    public static RepoChange Parse(JsonNode n) =>
        new(n.Str("path") ?? "", n.Str("status") ?? "M", n.Str("oldPath") is { Length: > 0 } o ? o : null, n.Int("add") ?? 0, n.Int("del") ?? 0, n.Truthy("binary"));
    public static RepoChange Simple(string path) => new(path, "M", null, 0, 0, false);
}

public sealed record RepoBranch(string Name, string Hash, string? Upstream, int Ahead, int Behind, bool Gone, double? Ts, string Subject, bool Current, string? Worktree);
public sealed record RepoRemoteBranch(string Name, string Remote, string Branch, string Hash, double? Ts, string Subject);
public sealed record RepoTag(string Name, string Hash, double? Ts, string Subject);
public sealed record RepoStash(string Ref, string Hash, double? Ts, string Title);
public sealed record RepoWorktree(string Path, string Head, string? Branch, bool Detached, bool Main)
{
    public string Name => CodePaths.Name(Path.Replace('\\', '/').TrimEnd('/'));
}
public sealed record RepoSessionLink(string SessionId, string Worktree, string? Branch, string? Detached);

public sealed class RepoOverview
{
    public string? Repo, Reason, Branch, Oid, Upstream, State, MergeMessage;
    public string Name = "";
    public int Ahead, Behind, UntrackedCount;
    public bool IdentityMissing;
    public List<RepoChange> Staged = [], Unstaged = [], Untracked = [], Conflicts = [];
    public List<(string Name, string Url)> Remotes = [];
    public List<RepoBranch> Branches = [];
    public List<RepoRemoteBranch> RemoteBranches = [];
    public List<RepoTag> Tags = [];
    public List<RepoStash> Stashes = [];
    public List<RepoWorktree> Worktrees = [];
    public List<RepoSessionLink> Sessions = [];

    public IEnumerable<RepoChange> Changes => Unstaged.Concat(Untracked);
    public int ChangeCount => Staged.Count + Unstaged.Count + UntrackedCount + Conflicts.Count;

    public static RepoOverview Parse(JsonNode? n)
    {
        static List<RepoChange> Changes(JsonNode? n, string key) => n.Arr(key).Items().Select(RepoChange.Parse).ToList();
        var o = new RepoOverview
        {
            Repo = n.Str("repo"), Reason = n.Str("reason"), Branch = n.Str("branch"), Oid = n.Str("oid"), Upstream = n.Str("upstream"),
            State = n.Str("state"), MergeMessage = n.Str("mergeMessage"), Ahead = n.Int("ahead") ?? 0, Behind = n.Int("behind") ?? 0,
            UntrackedCount = n.Int("untrackedCount") ?? 0,
            Staged = Changes(n, "staged"), Unstaged = Changes(n, "unstaged"), Untracked = Changes(n, "untracked"), Conflicts = Changes(n, "conflicts"),
        };
        o.Name = n.Str("name") ?? CodePaths.Name((o.Repo ?? "").Replace('\\', '/'));
        o.Remotes = n.Arr("remotes").Items().Select(r => (r.Str("name") ?? "", r.Str("url") ?? "")).ToList();
        o.Branches = n.Arr("branches").Items().Select(b => new RepoBranch(b.Str("name") ?? "", b.Str("hash") ?? "", b.Str("upstream"), b.Int("ahead") ?? 0,
            b.Int("behind") ?? 0, b.Truthy("gone"), b.Num("ts"), b.Str("subject") ?? "", b.Truthy("current"), b.Str("worktree") is { Length: > 0 } w ? w : null)).ToList();
        o.RemoteBranches = n.Arr("remoteBranches").Items().Select(b => new RepoRemoteBranch(b.Str("name") ?? "", b.Str("remote") ?? "", b.Str("branch") ?? "",
            b.Str("hash") ?? "", b.Num("ts"), b.Str("subject") ?? "")).ToList();
        o.Tags = n.Arr("tags").Items().Select(t => new RepoTag(t.Str("name") ?? "", t.Str("hash") ?? "", t.Num("ts"), t.Str("subject") ?? "")).ToList();
        o.Stashes = n.Arr("stashes").Items().Select(s => new RepoStash(s.Str("ref") ?? "", s.Str("hash") ?? "", s.Num("ts"), s.Str("title") ?? "")).ToList();
        o.Worktrees = n.Arr("worktrees").Items().Select(t => new RepoWorktree(t.Str("path") ?? "", t.Str("head") ?? "", t.Str("branch"), t.Truthy("detached"), t.Truthy("main"))).ToList();
        o.Sessions = n.Arr("sessions").Items().Select(s => new RepoSessionLink(s.Str("sessionId") ?? "", s.Str("worktree") ?? "", s.Str("branch"), s.Str("detached"))).ToList();
        var identity = n.Obj("identity");
        o.IdentityMissing = o.Repo is not null && (string.IsNullOrEmpty(identity.Str("name")) || string.IsNullOrEmpty(identity.Str("email")));
        return o;
    }
}

public sealed record RefLabel(string Type, string Name, bool Current)
{
    public static RefLabel Parse(JsonNode n) => new(n.Str("type") ?? "branch", n.Str("name") ?? "", n.Truthy("current"));
}

/// 提交图的一行：圆点在第几列、什么颜色；线段 [x1, y1, x2, y2, 颜色]（y：0 上沿 / 1 圆点 / 2 下沿），服务端算好
public sealed record GraphRow(int Col, int Color, List<int[]> Segs);

public sealed record CommitRow(string Hash, string Short, List<string> Parents, string Author, double? Ts, List<RefLabel> Refs, string Subject, GraphRow? Graph)
{
    public static CommitRow Parse(JsonNode n)
    {
        var g = n.Obj("graph");
        GraphRow? graph = g is null ? null : new GraphRow(g.Int("col") ?? 0, g.Int("color") ?? 0,
            g.Arr("segs").Items().Select(s => (s as JsonArray).Items().Select(x => (int)(J.AsNumber(x) ?? 0)).ToArray()).ToList());
        var hash = n.Str("hash") ?? "";
        return new CommitRow(hash, n.Str("short") ?? hash[..Math.Min(8, hash.Length)], n.Strings("parents"), n.Str("author") ?? "", n.Num("ts"),
            n.Arr("refs").Items().Select(RefLabel.Parse).ToList(), n.Str("subject") ?? "", graph);
    }
}

public sealed record DiffPayload(string Diff, string Path, string Mode, List<string> Hunks, bool Binary, string? Original, string? Modified)
{
    public static DiffPayload Parse(JsonNode? n) => new(n.Str("diff") ?? "", n.Str("path") ?? "", n.Str("mode") ?? "unstaged", n.Strings("hunks"),
        n.Truthy("binary"), n.Get("original") is null ? null : n.Str("original"), n.Get("modified") is null ? null : n.Str("modified"));
}

public static class CodeApi
{
    static Net.Api Api => AppModel.Shared.Api;
    /// 慢的操作（要连远端、要跑提交钩子）：先拿任务号，再隔一会儿问一次结果（同 iOS 版）
    static readonly HashSet<string> SlowOps = ["push", "pull", "fetch", "remote_branch_delete", "commit", "merge", "rebase", "cherry_pick",
        "revert", "continue", "skip", "worktree_add"];

    static Dictionary<string, string> Q(string key, params (string, string?)[] more)
    {
        var q = new Dictionary<string, string> { ["key"] = key };
        foreach (var (k, v) in more) if (v is not null) q[k] = v;
        return q;
    }

    public static async Task<RepoOverview> Overview(string key) => RepoOverview.Parse(await Api.Get("/api/repo", Q(key, ("op", "overview"))));

    public static async Task<(List<CommitRow> Commits, int Width, bool More)> Log(string key, int skip, int limit, string? path = null, string? query = null, string? refName = null)
    {
        var n = await Api.Get("/api/repo", Q(key, ("op", "log"), ("skip", skip.ToString()), ("limit", limit.ToString()), ("path", path),
            ("q", string.IsNullOrEmpty(query) ? null : query), ("ref", refName)));
        return (n.Arr("commits").Items().Select(CommitRow.Parse).ToList(), n.Int("width") ?? 0, n.Truthy("more"));
    }

    public static Task<JsonNode?> Commit(string key, string hash) => Api.Get("/api/repo", Q(key, ("op", "commit_info"), ("commit", hash)));

    public static async Task<DiffPayload> Diff(string key, string path, string mode, string? commit = null, string? oldPath = null) =>
        DiffPayload.Parse(await Api.Get("/api/repo", Q(key, ("op", "diff"), ("path", path), ("mode", mode), ("commit", commit), ("oldPath", oldPath))));

    /// 会改仓库的操作；Git 报错抛 GitError
    public static async Task<JsonNode?> Run(string key, string op, JsonObject? body = null)
    {
        body ??= [];
        body["op"] = op;
        if (SlowOps.Contains(op))
        {
            body["job"] = true;
            var started = await Api.Post("/api/repo", body, Q(key));
            if (started.Str("job") is not { } job) return Check(started);
            var deadline = DateTime.UtcNow.AddSeconds(330);
            while (DateTime.UtcNow < deadline)
            {
                await Task.Delay(700);
                var state = await Api.Get("/api/repo", Q(key, ("op", "job"), ("job", job)));
                if (!state.Truthy("done")) continue;
                if (state.Truthy("failed")) throw new GitError(state.Str("error") ?? L("操作失败"), state.Str("detail"));
                return state.Get("result");
            }
            throw new GitError(L("操作超时：电脑上的 Git 仍在运行，请稍后刷新查看"), null);
        }
        return Check(await Api.Post("/api/repo", body, Q(key)));
    }

    static JsonNode? Check(JsonNode? reply) =>
        reply.Truthy("failed") ? throw new GitError(reply.Str("error") ?? L("操作失败"), reply.Str("detail")) : reply;

    public static Task<JsonNode?> Fs(string key, string op, JsonObject body)
    {
        body["op"] = op;
        return Api.Post("/api/fs", body, Q(key));
    }

    public static Task<JsonNode?> List(string key, string path) => Api.Get("/api/files", Q(key, ("path", path)));
    public static Task<JsonNode?> Open(string key, string path, bool reveal = false) =>
        Api.Get("/api/file", Q(key, ("path", path), ("edit", "1"), ("reveal", reveal ? "1" : null)));
}

/// 一个仓库在界面上的状态（同 iOS 版 RepoStore）：概览、正在做的操作；做完操作统一刷新、通知各页重画
public sealed class RepoState(string key)
{
    public string Key { get; } = key;
    public RepoOverview? Overview { get; private set; }
    public string? LoadError { get; private set; }
    public string? Busy { get; private set; }
    public event Action? Changed;

    public async Task Refresh()
    {
        try { Overview = await CodeApi.Overview(Key); LoadError = null; }
        catch (Exception e) { if (Overview is null) LoadError = e.Message; }
        Changed?.Invoke();
    }

    /// 做一个会改仓库的操作：成功提示一句、刷新；冲突了提示去解决；Git 报错弹窗（原话可拷贝）
    public async Task<JsonNode?> Perform(string op, JsonObject? body, string label, string? done = null)
    {
        if (Busy is not null) return null;
        Busy = label;
        Changed?.Invoke();
        try
        {
            var result = await CodeApi.Run(Key, op, body) ?? new JsonObject();
            if (result.Truthy("conflict")) AppModel.Shared.Flash(L("有冲突需要解决：在「源代码管理」里处理后选择继续"));
            else if (done is not null) AppModel.Shared.Flash(done);
            return result;
        }
        catch (GitError e) { _ = ShowError(e.Message, e.Detail); return null; }
        catch (Exception e) { _ = ShowError(e.Message, null); return null; }
        finally
        {
            Busy = null;
            await Refresh();
        }
    }

    public static async Task ShowError(string message, string? detail)
    {
        if (string.IsNullOrEmpty(detail)) { await Dialogs.Confirm(message, L("好")); return; }
        if (await Dialogs.Confirm(detail.Length > 600 ? "…" + detail[^600..] : detail, L("拷贝 Git 输出"), title: message))
            _ = MainWindow.Current?.Clipboard?.SetTextAsync(detail);
    }

    /// 这个仓库里正在跑的会话，按工作树分组（主工作树在前）
    public List<(RepoWorktree? Tree, string? Branch, List<SessionInfo> Sessions)> SessionGroups()
    {
        var o = Overview;
        if (o is null) return [];
        var source = AppModel.Shared.Session(Key)?.SourceId;
        var byTree = new Dictionary<string, List<SessionInfo>>();
        var branchOf = new Dictionary<string, string?>();
        foreach (var link in o.Sessions)
        {
            var session = AppModel.Shared.Sessions.FirstOrDefault(s => s.SessionId == link.SessionId && (source is null || s.SourceId == source));
            if (session is null) continue;
            var tree = Normalize(link.Worktree);
            if (!byTree.TryGetValue(tree, out var list)) byTree[tree] = list = [];
            list.Add(session);
            branchOf[tree] = link.Branch ?? (link.Detached is { } d ? $"({d})" : null);
        }
        var groups = new List<(RepoWorktree?, string?, List<SessionInfo>)>();
        foreach (var tree in o.Worktrees)
        {
            var path = Normalize(tree.Path);
            byTree.Remove(path, out var sessions);
            groups.Add((tree, tree.Branch ?? (tree.Detached ? $"({tree.Head[..Math.Min(8, tree.Head.Length)]})" : null), sessions ?? []));
        }
        foreach (var (path, sessions) in byTree) groups.Add((null, branchOf.GetValueOrDefault(path), sessions));
        return groups;
    }

    public List<SessionInfo> SessionsOnBranch(string name) => SessionGroups().Where(g => g.Branch == name).SelectMany(g => g.Sessions).ToList();

    public RepoWorktree? CurrentTree => Overview is { Repo: { } repo } o ? o.Worktrees.FirstOrDefault(t => Normalize(t.Path) == Normalize(repo)) : null;

    public List<SessionInfo> SessionsInTree(string path) => SessionGroups().FirstOrDefault(g => g.Tree is { } t && Normalize(t.Path) == Normalize(path)).Sessions ?? [];

    public static string Normalize(string path)
    {
        var p = path.Replace('\\', '/');
        while (p.Length > 1 && p.EndsWith('/')) p = p[..^1];
        if (p.StartsWith("/private/", StringComparison.OrdinalIgnoreCase)) p = p[8..];
        return OperatingSystem.IsWindows() ? p.ToLowerInvariant() : p;
    }
}

/// 同一个会话的仓库状态在几个窗口之间共用一份
public static class RepoStates
{
    static readonly Dictionary<string, RepoState> All = [];
    public static RepoState Get(string key) => All.TryGetValue(key, out var s) ? s : All[key] = new RepoState(key);
}
