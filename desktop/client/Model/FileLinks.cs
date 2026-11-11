using System.Text.RegularExpressions;

namespace Kiteline.Model;

/// 消息里的电脑文件路径（同 iOS / Mac 版 FileLink）：Claude 说「已生成 ~/Desktop/报价单.xlsx」、手机发过去的附件（[附件] 行）。
/// 认出来变成可点的链接，点了用默认的程序打开（见 Views/FileOpen.cs）
public static partial class FileLinks
{
    public const string Scheme = "kiteline-file:";
    /// 手机发过去的文件在消息里是这一行（同电脑端 delivery.compose）
    public const string AttachPrefix = "[附件] ";

    public static string Url(string path) => Scheme + Uri.EscapeDataString(path);

    public static string? PathOf(string url) => url.StartsWith(Scheme, StringComparison.Ordinal) ? Uri.UnescapeDataString(url[Scheme.Length..]) : null;

    /// 办公文档、图片、音视频、压缩包：用默认的程序打开；代码、文本在项目目录里的还是进文件面板看
    public static readonly HashSet<string> DocumentExtensions =
    [
        "pdf", "xlsx", "xls", "xlsm", "csv", "numbers", "docx", "doc", "pages", "rtf", "pptx", "ppt", "key", "epub",
        "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff",
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp", "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "aiff", "amr", "zip", "rar", "7z", "gz", "tgz", "dmg", "apk", "ipa",
    ];

    [GeneratedRegex(@":\d+(-\d+)?$")] private static partial Regex LineSuffix();
    [GeneratedRegex(@"^[A-Za-z][A-Za-z0-9]{0,7}$")] private static partial Regex ExtPattern();
    [GeneratedRegex(@"^[A-Za-z]:[\\/]")] private static partial Regex DrivePattern();
    /// 正文里的绝对路径（/…、~/…、C:\…），到空白、引号、括号、中文标点为止，要带扩展名；前面紧挨着字母、斜杠的不算（网址里那段）
    [GeneratedRegex(@"(?<![\w/.~:\\-])(?:~/|/|[A-Za-z]:[\\/])[^\s`'""<>()（）【】「」『』，。；：！？、*|]+\.[A-Za-z][A-Za-z0-9]{0,7}(?![A-Za-z0-9_])")]
    public static partial Regex PlainPattern();
    [GeneratedRegex(@"^\d{6}-[0-9a-f]{6}-")] private static partial Regex InboxPrefix();
    const string NotPath = "()[]{}<>=,;\"'`*?|$&!@#^+";

    public static string StripLine(string text) => LineSuffix().Replace(text, "");

    public static bool IsAbsolute(string path) => path.StartsWith('/') || path.StartsWith("~/") || DrivePattern().IsMatch(path);

    public static string LastComponent(string path) => path.Split('/', '\\').LastOrDefault(p => p.Length > 0) ?? path;

    public static string Ext(string path)
    {
        var name = LastComponent(path);
        var dot = name.LastIndexOf('.');
        return dot > 0 ? name[(dot + 1)..].ToLowerInvariant() : "";
    }

    /// `代码` 整段像不像一个文件路径：绝对路径、~/ 开头、带目录的相对路径都要有扩展名；光秃秃的文件名只认办公文档这类
    public static string? Candidate(string raw)
    {
        var text = StripLine(raw.Trim());
        if (text.Length < 3 || text.Length > 400 || text.Contains('\n') || text.Contains("://")) return null;
        var ext = Ext(text);
        if (ext.Length == 0 || !ExtPattern().IsMatch(ext)) return null;
        if (IsAbsolute(text)) return text.IndexOfAny(NotPath.ToCharArray()) < 0 ? text : null;
        if (text.Contains(' ') || text.IndexOfAny(NotPath.ToCharArray()) >= 0 || text.StartsWith('-')) return null;
        if (text.StartsWith('.') && !text.StartsWith("./") && !text.StartsWith("../")) return null;
        if (text.Contains('/')) return text;
        return DocumentExtensions.Contains(ext) ? text : null;
    }

    /// 我发的消息里「[附件] 路径」那几行拆出来（画成文件卡片），剩下的是正文
    public static (string Text, List<string> Files) SplitAttached(string text)
    {
        var files = new List<string>();
        if (!text.Contains(AttachPrefix)) return (text, files);
        var keep = new List<string>();
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith(AttachPrefix) && trimmed[AttachPrefix.Length..].Trim() is { Length: > 0 } path) { files.Add(path); continue; }
            keep.Add(line);
        }
        return (string.Join('\n', keep).Trim(), files);
    }

    /// 显示用的文件名：手机发过去的落在电脑的收件箱（…/inbox/日期/）里，名字前面带「时分秒-随机串-」，去掉
    public static string DisplayName(string path)
    {
        var name = LastComponent(path);
        if (!path.Contains("/inbox/") && !path.Contains("\\inbox\\")) return name;
        var m = InboxPrefix().Match(name);
        return m.Success ? name[m.Length..] : name;
    }
}
