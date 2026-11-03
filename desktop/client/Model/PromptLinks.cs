using System.Diagnostics;

namespace Kiteline.Model;

/// 提示词链接（同 iOS / Mac 版 PromptLink）：https://tars.betac.cn/new#p=<提示词>&project=<项目名或路径>，或 kiteline://new#…
/// （官网 /new 页上的「在 Kiteline 中打开」）。打开后弹「新任务」：提示词填好、能认出项目就选中，用户看过、改好再开始，不会自己执行。
/// 提示词放在 # 后面：浏览器不会把它发到服务器
public static class PromptLinks
{
    public const string Site = "tars.betac.cn";
    /// 冷启动时命令行带来的：主窗口出来以后再弹
    public static string? Pending;

    /// 命令行里的提示词链接（系统按 kiteline:// 协议把它传给我们）
    public static string? FromArgs(string[] args) =>
        args.FirstOrDefault(a => a.StartsWith("kiteline:", StringComparison.OrdinalIgnoreCase) || a.StartsWith($"https://{Site}/new", StringComparison.OrdinalIgnoreCase));

    public static (string Prompt, string? Project)? Parse(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return null;
        url = url.Trim();
        var lower = url.ToLowerInvariant();
        if (!lower.StartsWith("kiteline://new") && !lower.StartsWith($"https://{Site}/new")) return null;
        var fields = new Dictionary<string, string>();
        foreach (var mark in new[] { '?', '#' })
        {
            var at = url.IndexOf(mark);
            if (at < 0) continue;
            var raw = url[(at + 1)..];
            if (mark == '?' && raw.IndexOf('#') is var hash and >= 0) raw = raw[..hash];
            foreach (var pair in raw.Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var kv = pair.Split('=', 2);
                // 别的工具生成的链接可能把空格写成 +；我们自己生成的会把 + 编成 %2B
                static string Decode(string s) { try { return Uri.UnescapeDataString(s.Replace('+', ' ')); } catch { return s; } }
                fields[Decode(kv[0])] = kv.Length > 1 ? Decode(kv[1]) : "";
            }
        }
        var prompt = (fields.GetValueOrDefault("p") ?? fields.GetValueOrDefault("prompt") ?? "").Trim();
        if (prompt.Length == 0) return null;
        var project = (fields.GetValueOrDefault("project") ?? "").Trim();
        return (prompt.Length > 20000 ? prompt[..20000] : prompt, project.Length == 0 ? null : project);
    }

    /// 做一条链接（复制给别人、放进 PR 评论）
    public static string Make(string prompt, string? project) =>
        $"https://{Site}/new#p={Uri.EscapeDataString(prompt)}" + (string.IsNullOrEmpty(project) ? "" : "&project=" + Uri.EscapeDataString(project));

    /// 链接里的项目对得上这个项目吗（目录名、整条路径、owner/repo 的最后一级，不分大小写）
    public static bool Matches(string hint, string cwd, string name)
    {
        var trimmed = hint.Trim('/', '\\').Replace('\\', '/');
        var last = trimmed.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? trimmed;
        var dir = cwd.Replace('\\', '/').Trim('/');
        return string.Equals(dir, trimmed, StringComparison.OrdinalIgnoreCase) || string.Equals(name, last, StringComparison.OrdinalIgnoreCase);
    }

    /// 弹「新任务」：提示词填好，链接里的项目对得上就选中
    public static void Handle(string url)
    {
        if (Parse(url) is not { } link) return;
        Views.NewTaskSheet.Open(text: link.Prompt, hint: link.Project);
    }

    /// 注册 kiteline:// 网址协议，指向正在运行的这份程序。每次启动都对一遍：程序换了位置、更新以后照样指向这一份
    public static void Register()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe)) return;
            if (OperatingSystem.IsWindows())
            {
                using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Classes\kiteline");
                key.SetValue("", "URL:Kiteline");
                key.SetValue("URL Protocol", "");
                using (var icon = key.CreateSubKey("DefaultIcon")) icon.SetValue("", $"\"{exe}\",0");
                using var command = key.CreateSubKey(@"shell\open\command");
                command.SetValue("", $"\"{exe}\" \"%1\"");
            }
            else if (OperatingSystem.IsLinux())
            {
                // 单独一个不在菜单里显示的 .desktop 接 x-scheme-handler/kiteline（菜单里的 kiteline.desktop 是安装脚本写的，起的是后台）
                var data = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
                if (string.IsNullOrEmpty(data)) data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
                var apps = Path.Combine(data, "applications");
                Directory.CreateDirectory(apps);
                var file = Path.Combine(apps, "kiteline-link.desktop");
                var content = "[Desktop Entry]\nType=Application\nName=Kiteline\nComment=Kiteline prompt links\n" +
                              $"Exec=\"{exe}\" %u\nNoDisplay=true\nTerminal=false\nStartupWMClass=kiteline\nMimeType=x-scheme-handler/kiteline;\n";
                if (File.Exists(file) && File.ReadAllText(file) == content) return;
                File.WriteAllText(file, content);
                Run("xdg-mime", "default", "kiteline-link.desktop", "x-scheme-handler/kiteline");
                Run("update-desktop-database", apps);
            }
        }
        catch { }
    }

    static void Run(string file, params string[] args)
    {
        try
        {
            var info = new ProcessStartInfo(file) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var arg in args) info.ArgumentList.Add(arg);
            Process.Start(info)?.WaitForExit(3000);
        }
        catch { }
    }
}
