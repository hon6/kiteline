using System.Text.RegularExpressions;

namespace Kiteline.Model;

/// 会话目录在 worktree 里时归到原项目（同 watcher 的 project_root）：
/// <父>/<仓库>-worktrees/<名>[/子] → <父>/<仓库>[/子]；Claude Code 的 <仓库>/.claude/worktrees/<名>[/子] → <仓库>[/子]。纯字符串变换
public static class ProjectRoot
{
    static readonly Regex Sibling = new(@"^(.*[\\/])([^\\/]+)-worktrees[\\/][^\\/]+(?=$|[\\/])", RegexOptions.Compiled);
    static readonly Regex Claude = new(@"^(.+?)[\\/]\.claude[\\/]worktrees[\\/][^\\/]+(?=$|[\\/])", RegexOptions.Compiled);

    public static string? Of(string? cwd)
    {
        if (string.IsNullOrEmpty(cwd)) return cwd;
        var m = Sibling.Match(cwd);
        if (m.Success) return m.Groups[1].Value + m.Groups[2].Value + cwd[(m.Index + m.Length)..];
        m = Claude.Match(cwd);
        if (m.Success) return m.Groups[1].Value + cwd[(m.Index + m.Length)..];
        return cwd;
    }

    /// 在 worktree 里时 worktree 的名字，不在就是 null
    public static string? Worktree(string? cwd)
    {
        if (string.IsNullOrEmpty(cwd) || Of(cwd) == cwd) return null;
        var m = Sibling.Match(cwd);
        if (!m.Success) m = Claude.Match(cwd);
        var hit = m.Value.TrimEnd('/', '\\');
        return hit[(hit.LastIndexOfAny(new[] { '/', '\\' }) + 1)..];
    }
}
