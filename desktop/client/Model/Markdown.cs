using System.Text;
using System.Text.RegularExpressions;

namespace Kiteline.Model;

/// Claude 回复里的 Markdown，按块拆开（同 iOS / Mac 版 Markdown.swift 的规则）
public abstract record MdBlock;
public sealed record MdParagraph(string Text) : MdBlock;
public sealed record MdHeading(int Level, string Text) : MdBlock;
public sealed record MdCode(string Text) : MdBlock;
public sealed record MdQuote(IReadOnlyList<MdBlock> Blocks) : MdBlock;
public sealed record MdList(bool Ordered, IReadOnlyList<MdListItem> Items) : MdBlock;
public sealed record MdTable(IReadOnlyList<string> Header, IReadOnlyList<IReadOnlyList<string>> Rows) : MdBlock;
public sealed record MdRule : MdBlock;
public sealed record MdListItem(string Marker, string Text, int Indent);

/// 行内的一段：粗体、斜体、删除线、行内代码、链接
public sealed record MdSpan(string Text, bool Bold = false, bool Italic = false, bool Strike = false, bool Code = false, string? Link = null);

public static partial class Markdown
{
    static readonly Dictionary<string, List<MdBlock>> Cache = new();

    public static List<MdBlock> Blocks(string source)
    {
        if (Cache.TryGetValue(source, out var hit)) return hit;
        var blocks = Parse(source);
        if (Cache.Count > 400) Cache.Clear();
        Cache[source] = blocks;
        return blocks;
    }

    [GeneratedRegex(@"^(\s*)([-*+]|\d+[.)])\s+(.*)$")] private static partial Regex ListPattern();
    [GeneratedRegex(@"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")] private static partial Regex TableSeparator();
    [GeneratedRegex(@"^\s*([-*_])(\s*\1){2,}\s*$")] private static partial Regex RulePattern();
    [GeneratedRegex(@"^(#{1,6})\s+(.*)$")] private static partial Regex HeadingPattern();
    [GeneratedRegex(@"^\s*(```|~~~)\s*([\w+#.-]*)\s*$")] private static partial Regex FencePattern();

    static bool IsQuote(string line) => line.TrimStart(' ', '\t').StartsWith('>');
    static bool IsTableStart(List<string> lines, int i) => lines[i].Contains('|') && i + 1 < lines.Count && TableSeparator().IsMatch(lines[i + 1]);

    static bool StartsBlock(string line)
    {
        var trimmed = line.Trim();
        return trimmed.StartsWith("```") || trimmed.StartsWith("~~~") || HeadingPattern().IsMatch(line) || ListPattern().IsMatch(line) || IsQuote(line);
    }

    public static List<MdBlock> Parse(string source)
    {
        var lines = source.Replace("\r", "").Split('\n').ToList();
        var output = new List<MdBlock>();
        var i = 0;
        while (i < lines.Count)
        {
            var line = lines[i];
            if (FencePattern().Match(line) is { Success: true } fence)
            {
                var buffer = new List<string>();
                i++;
                while (i < lines.Count && !lines[i].Trim().StartsWith(fence.Groups[1].Value)) { buffer.Add(lines[i]); i++; }
                i++;
                output.Add(new MdCode(string.Join("\n", buffer)));
                continue;
            }
            if (IsTableStart(lines, i))
            {
                static List<string> Cells(string l)
                {
                    var t = l.Trim();
                    if (t.StartsWith('|')) t = t[1..];
                    if (t.EndsWith('|')) t = t[..^1];
                    return t.Split('|').Select(c => c.Trim()).ToList();
                }
                var header = Cells(line);
                var rows = new List<IReadOnlyList<string>>();
                i += 2;
                while (i < lines.Count && lines[i].Contains('|') && lines[i].Trim().Length > 0) { rows.Add(Cells(lines[i])); i++; }
                output.Add(new MdTable(header, rows));
                continue;
            }
            if (HeadingPattern().Match(line) is { Success: true } h)
            {
                output.Add(new MdHeading(Math.Min(h.Groups[1].Value.Length, 4), h.Groups[2].Value));
                i++;
                continue;
            }
            if (RulePattern().IsMatch(line)) { output.Add(new MdRule()); i++; continue; }
            if (IsQuote(line))
            {
                var buffer = new List<string>();
                while (i < lines.Count && IsQuote(lines[i]))
                {
                    var text = lines[i].TrimStart(' ', '\t')[1..];
                    if (text.StartsWith(' ')) text = text[1..];
                    buffer.Add(text);
                    i++;
                }
                output.Add(new MdQuote(Parse(string.Join("\n", buffer))));
                continue;
            }
            if (ListPattern().Match(line) is { Success: true } first)
            {
                var ordered = char.IsDigit(first.Groups[2].Value[0]);
                var items = new List<MdListItem>();
                var number = 0;
                while (i < lines.Count)
                {
                    if (ListPattern().Match(lines[i]) is { Success: true } m)
                    {
                        var text = m.Groups[3].Value;
                        var marker = ordered ? (int.TryParse(m.Groups[2].Value[..^1], out var n) ? n : number + 1) + "." : "•";
                        if (text.StartsWith("[ ] ")) { marker = "☐"; text = text[4..]; }
                        else if (text.StartsWith("[x] ") || text.StartsWith("[X] ")) { marker = "☑"; text = text[4..]; }
                        number++;
                        var indent = m.Groups[1].Value.Replace("\t", "  ").Length / 2;
                        items.Add(new MdListItem(marker, text, indent));
                        i++;
                    }
                    else if (lines[i].StartsWith("  ") && lines[i].Trim().Length > 0 && items.Count > 0)
                    {
                        // 列表项的续行
                        items[^1] = items[^1] with { Text = items[^1].Text + "\n" + lines[i].Trim() };
                        i++;
                    }
                    else break;
                }
                output.Add(new MdList(ordered, items));
                continue;
            }
            if (line.Trim().Length == 0) { i++; continue; }
            var para = new List<string>();
            while (i < lines.Count && lines[i].Trim().Length > 0 && !(para.Count > 0 && StartsBlock(lines[i])) && !IsTableStart(lines, i))
            {
                para.Add(lines[i]);
                i++;
            }
            output.Add(new MdParagraph(string.Join("\n", para)));
        }
        return output;
    }

    // MARK: 行内

    /// 粗体、斜体、删除线、`代码`、[文字](网址)；裸网址也变成可点的链接（到第一个非 ASCII 字符为止：「…/a.dmg。Apple」后面的中文不算进网址）
    public static List<MdSpan> Inline(string text)
    {
        var spans = new List<MdSpan>();
        var sb = new StringBuilder();
        bool bold = false, italic = false, strike = false;
        void Flush()
        {
            if (sb.Length == 0) return;
            spans.AddRange(Autolink(sb.ToString(), bold, italic, strike));
            sb.Clear();
        }
        var i = 0;
        while (i < text.Length)
        {
            var c = text[i];
            if (c == '\\' && i + 1 < text.Length && "\\`*_~[]()#".Contains(text[i + 1])) { sb.Append(text[i + 1]); i += 2; continue; }
            if (c == '`')
            {
                var ticks = 1;
                while (i + ticks < text.Length && text[i + ticks] == '`') ticks++;
                var fence = new string('`', ticks);
                var end = text.IndexOf(fence, i + ticks, StringComparison.Ordinal);
                if (end > i)
                {
                    Flush();
                    var code = text[(i + ticks)..end];
                    if (ticks > 1) code = code.Trim();
                    // 整段是电脑上的文件路径（`~/Desktop/报价单.xlsx`）：点了打开（见 FileLinks）
                    spans.Add(new MdSpan(code, bold, italic, strike, Code: true, Link: FileLinks.Candidate(code) is string path ? FileLinks.Url(path) : null));
                    i = end + ticks;
                    continue;
                }
            }
            if (c == '[' && LinkAt(text, i) is (string label, string url, int length))
            {
                Flush();
                foreach (var s in Inline(label)) spans.Add(s with { Link = url, Bold = s.Bold || bold, Italic = s.Italic || italic, Strike = s.Strike || strike });
                i += length;
                continue;
            }
            var next = i + 1 < text.Length ? text[i + 1] : '\0';
            // **粗体** / __粗体__：打开时后面要有配对的，关上时直接关
            if ((c == '*' || c == '_') && next == c && (bold || Closes(text, i + 2, new string(c, 2))))
            {
                Flush(); bold = !bold; i += 2; continue;
            }
            if (c == '~' && next == '~' && (strike || Closes(text, i + 2, "~~")))
            {
                Flush(); strike = !strike; i += 2; continue;
            }
            // *斜体* / _斜体_（下划线要在词的边上：snake_case 里的不算）；打开时后面不能紧跟空格
            var boundary = c == '*' || i == 0 || !char.IsLetterOrDigit(text[i - 1]);
            if ((c == '*' || c == '_') && boundary && (italic || (!char.IsWhiteSpace(next) && next != '\0' && Closes(text, i + 1, c.ToString()))))
            {
                Flush(); italic = !italic; i += 1; continue;
            }
            sb.Append(c);
            i++;
        }
        Flush();
        // claude.ai 的链接（Artifact 预览、用量页……）只显示文字、不让点：在手机或别的网络里打开，IP 和平时用 Claude 的不一样，账号容易被风控
        return spans.Select(s => s.Link is string url && BlockedLink(url) ? s with { Link = null } : s).ToList();
    }

    /// claude.ai 及其子域名的网址（同 iOS / Mac 版 Markdown.blockedLink）
    public static bool BlockedLink(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return false;
        var host = uri.Host.ToLowerInvariant();
        return host == "claude.ai" || host.EndsWith(".claude.ai");
    }

    /// 后面还有没有配对的结束符（没有就当普通字符）
    static bool Closes(string text, int from, string marker) => from < text.Length && text.IndexOf(marker, from, StringComparison.Ordinal) > from;

    static (string Label, string Url, int Length)? LinkAt(string text, int i)
    {
        var close = text.IndexOf("](", i + 1, StringComparison.Ordinal);
        if (close < 0) return null;
        var depth = 0;
        for (var j = i + 1; j < close; j++) if (text[j] == '\n') return null;
        var end = -1;
        for (var j = close + 2; j < text.Length; j++)
        {
            if (text[j] == '(') depth++;
            else if (text[j] == ')') { if (depth == 0) { end = j; break; } depth--; }
            else if (text[j] == ' ' || text[j] == '\n') break;
        }
        if (end < 0) return null;
        return (text[(i + 1)..close], text[(close + 2)..end], end + 1 - i);
    }

    [GeneratedRegex(@"(https?://|www\.)[^\s<>""'，。；：！？、）】」』]+")] private static partial Regex UrlPattern();

    static IEnumerable<MdSpan> Autolink(string text, bool bold, bool italic, bool strike)
    {
        var last = 0;
        foreach (Match m in UrlPattern().Matches(text))
        {
            var value = m.Value;
            // 网址到第一个非 ASCII 字符为止；结尾的英文标点不算
            var cut = value.TakeWhile(ch => ch < 128).Count();
            value = value[..cut].TrimEnd('.', ',', ';', ':', '!', '?', ')', ']', '"', '\'');
            if (value.Length < 5) continue;
            if (m.Index > last) foreach (var s in PathLinks(text[last..m.Index], bold, italic, strike)) yield return s;
            yield return new MdSpan(value, bold, italic, strike, Link: value.Contains("://") ? value : "http://" + value);
            last = m.Index + value.Length;
        }
        if (last < text.Length) foreach (var s in PathLinks(text[last..], bold, italic, strike)) yield return s;
    }

    /// 正文里的绝对路径（/Users/…/a.pdf、C:\…\b.xlsx）也变成文件链接
    static IEnumerable<MdSpan> PathLinks(string text, bool bold, bool italic, bool strike)
    {
        var last = 0;
        foreach (Match m in FileLinks.PlainPattern().Matches(text))
        {
            if (m.Index > last) yield return new MdSpan(text[last..m.Index], bold, italic, strike);
            yield return new MdSpan(m.Value, bold, italic, strike, Link: FileLinks.Url(m.Value));
            last = m.Index + m.Length;
        }
        if (last < text.Length) yield return new MdSpan(text[last..], bold, italic, strike);
    }

    /// 纯文本（复制、引用、朗读用）
    public static string Plain(string text) => string.Concat(Inline(text).Select(s => s.Text));
}
