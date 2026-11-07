using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Avalonia.Threading;
using static Kiteline.Lang;

namespace Kiteline.Model;

/// 消息翻译（同 Mac / iPhone 版 Translator.swift）：消息下面的「翻译」点一下把这条换成目标语言，再点「原文」换回来。
/// 第一次点先弹设置（从什么语言翻成什么语言、用哪个服务），之后直接翻；设置 → 通用 →「翻译」里随时改。
/// 服务都不要 Key：Google 翻译（免费网页接口，大陆网络可能连不上）、MyMemory（公开免费接口，每天约 5000 字）；
/// 「自动」先 Google、不行换 MyMemory（Windows / Linux 没有苹果的系统翻译）。
/// 只翻文字：代码块原样保留，行内代码、链接换成占位符翻完放回，列表、标题、引用的前缀不动
public static class Translator
{
    public sealed record Language(string Code, string Name);

    public static readonly (string Id, string Title, string Note)[] Engines =
    [
        ("auto", "自动", "先交给连着的电脑翻译，再依次尝试 Google 翻译、MyMemory"),
        ("computer", "电脑翻译", "交给连着的电脑翻译：Mac 使用系统翻译在电脑上完成，其他电脑联网翻译"),
        ("google", "Google 翻译", "翻译质量较好；部分网络环境下无法连接，连不上时自动改用其他服务"),
        ("mymemory", "MyMemory", "公开免费接口，每天可翻译约 5000 字"),
    ];

    public static Language Auto => new("auto", L("自动检测"));
    public static IReadOnlyList<Language> Languages =>
    [
        new("zh-Hans", L("简体中文")), new("zh-Hant", L("繁体中文")), new("en", L("英语")), new("ja", L("日语")), new("ko", L("韩语")),
        new("fr", L("法语")), new("de", L("德语")), new("es", L("西班牙语")), new("pt", L("葡萄牙语")), new("it", L("意大利语")),
        new("ru", L("俄语")), new("ar", L("阿拉伯语")), new("vi", L("越南语")), new("th", L("泰语")), new("id", L("印尼语")),
        new("tr", L("土耳其语")), new("nl", L("荷兰语")), new("pl", L("波兰语")), new("uk", L("乌克兰语")), new("hi", L("印地语")),
    ];

    public static string LanguageName(string code) =>
        code == "auto" ? Auto.Name : Languages.FirstOrDefault(l => l.Code == code)?.Name ?? code;

    // MARK: 设置（存在客户端自己的 app-prefs.json，键和 Mac / iPhone 的 UserDefaults 同名）

    public static string Source { get => Prefs.String("translate.source") ?? "auto"; set { Prefs.Set("translate.source", value); cache.Clear(); } }
    public static string Target { get => Prefs.String("translate.target") ?? (IsEnglish ? "en" : "zh-Hans"); set { Prefs.Set("translate.target", value); cache.Clear(); } }
    public static string Engine
    {
        get => Prefs.String("translate.engine") is { } e && Engines.Any(x => x.Id == e) ? e : "auto";
        set { Prefs.Set("translate.engine", value); cache.Clear(); }
    }
    public static bool Configured { get => Prefs.Bool("translate.configured"); set => Prefs.Set("translate.configured", value); }
    /// 每条消息下面显示「翻译」（关了右键菜单里照样有）
    public static bool ShowBadge { get => Prefs.Bool("translate.badge", true); set { Prefs.Set("translate.badge", value); Changed?.Invoke(null); } }
    /// 自动翻译：助手的回复出现在屏幕上时自动翻（和目标语言相同的不翻；点过「原文」的、翻失败的不再自动翻）
    public static bool AutoTranslateOn
    {
        get => Prefs.Bool("translate.auto");
        set { Prefs.Set("translate.auto", value); if (value) Configured = true; Changed?.Invoke(null); }
    }

    public static string EngineTitle(string id) => L(Engines.FirstOrDefault(e => e.Id == id).Title ?? id);
    public static string EngineNote(string id) => L(Engines.FirstOrDefault(e => e.Id == id).Note ?? "");
    public static string Summary => $"{LanguageName(Source)} → {LanguageName(Target)} · {EngineTitle(Engine)}";

    // MARK: 每条消息的状态

    public enum Phase { Working, Done, Failed }
    public sealed record State(Phase Phase, string? Text = null, string? Error = null);

    static readonly Dictionary<string, State> states = new();
    static readonly HashSet<string> original = new();
    static readonly Dictionary<string, string> cache = new();
    static readonly Dictionary<string, CancellationTokenSource> running = new();
    /// 哪条消息变了（null = 全部，比如关了角标）：气泡、角标收到后各自换内容
    public static event Action<string?>? Changed;
    /// 第一次点「翻译」：由界面弹设置，确认后翻这一条
    public static Action<string, string>? AskSetup;

    public static State? StateOf(string id) => states.GetValueOrDefault(id);
    /// 气泡里该显示的：翻好且没切回原文时是译文，否则 null
    public static string? Shown(string id) =>
        states.TryGetValue(id, out var s) && s.Phase == Phase.Done && !original.Contains(id) ? s.Text : null;
    public static bool IsTranslated(string id) => Shown(id) is not null;

    public static void Tap(string id, string text)
    {
        if (!Configured && AskSetup is { } ask) { ask(id, text); return; }
        if (states.TryGetValue(id, out var s))
        {
            if (s.Phase == Phase.Done) { if (!original.Remove(id)) original.Add(id); Changed?.Invoke(id); return; }
            if (s.Phase == Phase.Working) return;
        }
        Translate(id, text);
    }

    public static void Restore(string id)
    {
        if (states.TryGetValue(id, out var s) && s.Phase == Phase.Done) { original.Add(id); Changed?.Invoke(id); }
        else Cancel(id);
    }

    public static void Cancel(string id)
    {
        if (running.Remove(id, out var cts)) cts.Cancel();
        states.Remove(id);
        Changed?.Invoke(id);
    }

    public static void Retranslate(string id, string text)
    {
        if (running.Remove(id, out var cts)) cts.Cancel();
        states.Remove(id); original.Remove(id);
        Translate(id, text);
    }

    static readonly HashSet<string> sameAsTarget = new();
    /// 自动翻译同时最多跑 3 条（一屏十几条同时请求会被限流）
    static readonly SemaphoreSlim autoGate = new(3);

    /// 自动翻译：消息出现在屏幕上时调用。只翻和目标语言不同的；翻过、正在翻、点过「原文」、失败过的都不动
    public static void AutoTranslate(string id, string text)
    {
        if (!AutoTranslateOn || !Configured || states.ContainsKey(id) || original.Contains(id) || sameAsTarget.Contains(id)) return;
        var sample = string.Join("\n", new TranslateDoc(text).Pieces);
        if (sample.Length == 0) return;
        if (Source != "auto" ? SameLanguage(Source, Target) : LooksLike(sample, Target)) { sameAsTarget.Add(id); return; }
        Translate(id, text, gated: true);
    }

    static bool SameLanguage(string a, string b) =>
        a.StartsWith("zh") || b.StartsWith("zh") ? a == b : a.Split('-')[0] == b.Split('-')[0];

    /// 没有系统的语言识别：按文字类别粗判「已经是目标语言」（汉字 / 假名 / 韩文 / 西里尔 / 阿拉伯 / 泰文 / 拉丁）。
    /// 拉丁字母的几种语言分不清：目标是英语时拉丁字母当英语，其它拉丁语言照翻
    static bool LooksLike(string text, string target)
    {
        int han = 0, kana = 0, hangul = 0, cyr = 0, arab = 0, thai = 0, latin = 0;
        foreach (var c in text)
        {
            if (c >= 0x4E00 && c <= 0x9FFF) han++;
            else if (c >= 0x3040 && c <= 0x30FF) kana++;
            else if (c >= 0xAC00 && c <= 0xD7AF) hangul++;
            else if (c >= 0x0400 && c <= 0x04FF) cyr++;
            else if (c >= 0x0600 && c <= 0x06FF) arab++;
            else if (c >= 0x0E00 && c <= 0x0E7F) thai++;
            else if (char.IsAsciiLetter(c)) latin++;
        }
        // 中日韩一个字顶几个拉丁字母
        var scores = new Dictionary<string, double> { ["han"] = han * 3, ["kana"] = kana * 3, ["hangul"] = hangul * 3, ["cyr"] = cyr, ["arab"] = arab, ["thai"] = thai, ["latin"] = latin };
        var top = scores.MaxBy(kv => kv.Value);
        if (top.Value == 0) return true;
        if (kana > 0 && top.Key == "han") top = new("kana", 0);   // 有假名的汉字文本是日语
        return target switch
        {
            "zh-Hans" or "zh-Hant" => top.Key == "han",
            "ja" => top.Key == "kana",
            "ko" => top.Key == "hangul",
            "ru" or "uk" => top.Key == "cyr",
            "ar" => top.Key == "arab",
            "th" => top.Key == "thai",
            "en" => top.Key == "latin",
            _ => false,
        };
    }

    public static void Translate(string id, string text, bool gated = false)
    {
        var engine = Engine; var source = Source; var target = Target;
        var cacheKey = $"{engine}|{source}|{target}|{text}";
        original.Remove(id);
        if (cache.TryGetValue(cacheKey, out var hit)) { states[id] = new State(Phase.Done, hit); Changed?.Invoke(id); return; }
        var doc = new TranslateDoc(text);
        if (doc.Pieces.Count == 0) { states[id] = new State(Phase.Done, text); Changed?.Invoke(id); return; }
        states[id] = new State(Phase.Working);
        Changed?.Invoke(id);
        var cts = new CancellationTokenSource();
        running[id] = cts;
        // 选的联网服务连不上 / 被限流 / 额度用完就换另一个（11-07 手机端选 Google 在大陆条条失败；这里 .NET 请求 Google 会被 429）；
        // 最近不可用的先跳过，全被跳过时照常都试
        // 11-07 起先交给连着的电脑翻（Mac 用系统翻译在电脑上完成；本机这台电脑的后台用 Python 联网，不会像 .NET 请求那样被 Google 限流）
        var host = HostTranslate;
        string[] order = engine switch
        {
            "mymemory" => host != null ? ["mymemory", "computer", "google"] : ["mymemory", "google"],
            "google" => host != null ? ["google", "computer", "mymemory"] : ["google", "mymemory"],
            _ => host != null ? ["computer", "google", "mymemory"] : ["google", "mymemory"],
        };
        string[] live;
        lock (downUntil) live = order.Where(e => !(downUntil.TryGetValue(e, out var until) && until > DateTime.UtcNow)).ToArray();
        if (live.Length > 0) order = live;
        _ = Task.Run(async () =>
        {
            if (gated) await autoGate.WaitAsync();
            try { await Run(); } finally { if (gated) autoGate.Release(); }
        });

        async Task Run()
        {
            var error = L("翻译失败");
            foreach (var e in order)
            {
                if (cts.IsCancellationRequested) return;
                try
                {
                    var result = e == "computer" && host != null ? await host(text, source, target, cts.Token)
                        : doc.Rebuild(e == "google" ? await Google(doc.Pieces, source, target, cts.Token) : await MyMemory(doc.Pieces, source, target, cts.Token));
                    Dispatcher.UIThread.Post(() =>
                    {
                        if (cts.IsCancellationRequested) return;
                        cache[cacheKey] = result;
                        states[id] = new State(Phase.Done, result);
                        running.Remove(id);
                        Changed?.Invoke(id);
                    });
                    return;
                }
                catch (OperationCanceledException) when (cts.IsCancellationRequested) { return; }
                catch (TranslateException ex)
                {
                    error = ex.Message;
                    if (ex.Pause is { } pause) lock (downUntil) downUntil[e] = DateTime.UtcNow.AddSeconds(pause);
                }
                catch (Exception ex) { error = ex.Message; }
            }
            Dispatcher.UIThread.Post(() =>
            {
                if (cts.IsCancellationRequested) return;
                states[id] = new State(Phase.Failed, Error: error);
                running.Remove(id);
                Changed?.Invoke(id);
            });
        }
    }

    public sealed class TranslateException(string message, double? pause = null) : Exception(message)
    {
        /// 联网服务暂时不可用：这么多秒内先用别的服务
        public double? Pause { get; } = pause;
    }

    /// 交给连着的电脑翻（POST /api/translate；电脑有 translate 功能时 AppModel 填上）：(原文, 原文语言, 目标语言) → 译文
    public static Func<string, string, string, CancellationToken, Task<string>>? HostTranslate;

    /// 联网服务连不上 / 被限流 / 额度用完后暂停到什么时候（期间先用另一个）
    static readonly Dictionary<string, DateTime> downUntil = [];

    /// 返回的不是 JSON（被拦截、限流时给的是网页）：当作无法识别
    static JsonNode? Parse(string body)
    {
        try { return JsonNode.Parse(body); } catch (System.Text.Json.JsonException) { return null; }
    }

    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(12) };

    static string GoogleCode(string code) => code switch { "zh-Hans" => "zh-CN", "zh-Hant" => "zh-TW", _ => code };
    static string MyMemoryCode(string code) => code switch { "auto" => "autodetect", "zh-Hans" => "zh-CN", "zh-Hant" => "zh-TW", _ => code };

    // MARK: Google 翻译（translate.googleapis.com 的免费网页接口）：多段合一次请求（一段一行），行数对不上就逐段再翻

    static async Task<List<string>> Google(IReadOnlyList<string> pieces, string source, string target, CancellationToken token)
    {
        var output = new List<string>();
        var batch = new List<string>();
        var size = 0;
        async Task Flush()
        {
            if (batch.Count == 0) return;
            var lines = (await GoogleOne(string.Join("\n", batch), source, target, token)).Split('\n');
            if (lines.Length == batch.Count) output.AddRange(lines);
            else foreach (var piece in batch) output.Add(await GoogleOne(piece, source, target, token));
            batch.Clear(); size = 0;
        }
        foreach (var piece in pieces)
        {
            if (size + piece.Length > 3000) await Flush();
            batch.Add(piece.Replace('\n', ' ')); size += piece.Length + 1;
        }
        await Flush();
        return output;
    }

    static async Task<string> GoogleOne(string text, string source, string target, CancellationToken token)
    {
        var url = $"https://translate.googleapis.com/translate_a/single?client=gtx&dt=t&sl={GoogleCode(source)}&tl={GoogleCode(target)}";
        string body;
        int code;
        try
        {
            using var response = await http.PostAsync(url, new FormUrlEncodedContent([new("q", text)]), token);
            code = (int)response.StatusCode;
            body = await response.Content.ReadAsStringAsync(token);
        }
        catch (Exception e) when (e is not OperationCanceledException || !token.IsCancellationRequested) { throw new TranslateException(L("连不上 Google 翻译"), 600); }
        if (Parse(body) is not JsonArray { Count: > 0 } json || json[0] is not JsonArray parts)
            throw new TranslateException(L("Google 翻译返回了无法识别的内容") + $" (HTTP {code})", 600);
        var sb = new StringBuilder();
        foreach (var part in parts) if (part is JsonArray { Count: > 0 } p && p[0]?.GetValueKind() == System.Text.Json.JsonValueKind.String) sb.Append((string?)p[0]);
        return sb.ToString();
    }

    // MARK: MyMemory（api.mymemory.translated.net）：每次最多 500 字节，按句子切

    static async Task<List<string>> MyMemory(IReadOnlyList<string> pieces, string source, string target, CancellationToken token)
    {
        // 每块一个请求，最多同时 4 个（长消息逐个请求要十几秒）
        using var gate = new SemaphoreSlim(4);
        var jobs = pieces.Select(piece => TranslateDoc.Chunks(piece, 450).Select(async chunk =>
        {
            await gate.WaitAsync(token);
            try { return await MyMemoryOne(chunk, source, target, token); } finally { gate.Release(); }
        }).ToList()).ToList();
        var output = new List<string>();
        foreach (var parts in jobs) output.Add(string.Join(" ", await Task.WhenAll(parts)));
        return output;
    }

    static async Task<string> MyMemoryOne(string text, string source, string target, CancellationToken token)
    {
        string body;
        try
        {
            using var response = await http.PostAsync("https://api.mymemory.translated.net/get",
                new FormUrlEncodedContent([new("q", text), new("langpair", $"{MyMemoryCode(source)}|{MyMemoryCode(target)}")]), token);
            body = await response.Content.ReadAsStringAsync(token);
        }
        catch (Exception e) when (e is not OperationCanceledException || !token.IsCancellationRequested) { throw new TranslateException(L("连不上 MyMemory"), 600); }
        if (Parse(body) is not JsonObject json) throw new TranslateException(L("MyMemory 返回了无法识别的内容"));
        if (json["quotaFinished"]?.GetValueKind() == System.Text.Json.JsonValueKind.True) throw new TranslateException(L("MyMemory 今日免费额度已用完"), 3600);
        var status = json["responseStatus"]?.ToString();
        var translated = json["responseData"]?["translatedText"]?.GetValueKind() == System.Text.Json.JsonValueKind.String ? (string?)json["responseData"]!["translatedText"] : null;
        // 自动检测出来和目标语言相同（「16px」这种被认成英文）：原样保留
        if (json["responseDetails"]?.ToString()?.Contains("DISTINCT LANGUAGES", StringComparison.OrdinalIgnoreCase) == true) return text;
        if (translated is null || (status is not null && status != "200"))
            throw new TranslateException(json["responseDetails"]?.ToString() is { Length: > 0 } d ? d : L("MyMemory 翻译失败"));
        return translated;
    }
}

/// 把一条消息拆成「要翻的段」和「原样留着的」（同 Swift 版 TranslateDoc）
public sealed class TranslateDoc
{
    abstract record Line;
    sealed record Keep(string Raw) : Line;
    sealed record Prose(string Prefix, int Piece, List<string> Tokens, string Trail = "") : Line;
    /// 表格的一行：每格单独翻（整行一起翻会把格子挪位、吞掉格子）
    sealed record Cells(List<Line> Parts) : Line;

    readonly List<Line> lines = new();
    public List<string> Pieces { get; } = new();

    static readonly Regex PrefixRx = new(@"^\s*(?:>\s*)*(?:#{1,6}\s+|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)?");
    // 最后一个：数字 + 单位（4px、200ms、1.5GB、80%）原样留着
    static readonly Regex[] Masks = [new(@"`[^`]+`"), new(@"\]\([^)\s]+\)"), new(@"https?://[^\s)>\]]+"),
        new(@"\b\d+(?:\.\d+)?(?:px|pt|em|rem|vh|vw|ms|s|KB|MB|GB|TB|k|K|M|x)\b|\d+(?:\.\d+)?%")];

    public TranslateDoc(string text)
    {
        var fence = false;
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var trimmed = raw.Trim();
            if (trimmed.StartsWith("```") || trimmed.StartsWith("~~~")) { fence = !fence; lines.Add(new Keep(raw)); continue; }
            if (fence || trimmed.Length == 0 || IsTableRule(trimmed) || raw.StartsWith("    ") || raw.StartsWith('\t')) { lines.Add(new Keep(raw)); continue; }
            if (trimmed.StartsWith('|')) { lines.Add(new Cells(raw.Split('|').Select(c => Cell(c, "", c)).ToList())); continue; }
            var prefix = PrefixRx.Match(raw).Value;
            lines.Add(Cell(raw[prefix.Length..], prefix, raw));
        }
    }

    /// 一段（一行或表格的一格）：前后空白留着；只剩占位符和符号（路径、代码、数字）的不翻
    Line Cell(string body, string prefix, string raw)
    {
        var (masked, tokens) = Mask(body.Trim(' '));
        if (!Regex.Replace(masked, @"\{\{\d+\}\}", "").Any(char.IsLetter)) return new Keep(raw);
        var lead = body[..(body.Length - body.TrimStart(' ').Length)];
        var trail = body[body.TrimEnd(' ').Length..];
        Pieces.Add(masked);
        return new Prose(prefix + lead, Pieces.Count - 1, tokens, trail);
    }

    public string Rebuild(IReadOnlyList<string> translated) => string.Join("\n", lines.Select(line => Render(line, translated)));

    string Render(Line line, IReadOnlyList<string> translated)
    {
        if (line is Keep k) return k.Raw;
        if (line is Cells cells) return string.Join("|", cells.Parts.Select(c => Render(c, translated)));
        var p = (Prose)line;
        var text = Tidy(p.Piece < translated.Count ? translated[p.Piece] : Pieces[p.Piece]);
        for (var i = p.Tokens.Count - 1; i >= 0; i--)
        {
            var rx = new Regex(@"\{\s*\{\s*" + i + @"\s*\}\s*\}");
            var m = rx.Match(text);
            text = m.Success ? text[..m.Index] + p.Tokens[i] + text[(m.Index + m.Length)..] : text + " " + p.Tokens[i];
        }
        return p.Prefix + text + p.Trail;
    }

    /// 翻译服务常把 Markdown 符号拆开：「* * 粗体 * *」「** 粗体 **」→「**粗体**」
    static string Tidy(string text)
    {
        text = Regex.Replace(text, @"\*\s+\*", "**");
        text = Regex.Replace(text, @"\*\*\s+([^*]+?)\s+\*\*", "**$1**");
        return text.Trim(' ');
    }

    static bool IsTableRule(string line) => line.StartsWith('|') && line.All(c => "|-: ".Contains(c));

    static (string, List<string>) Mask(string text)
    {
        var tokens = new List<string>();
        foreach (var rx in Masks)
        {
            text = rx.Replace(text, m =>
            {
                if (m.Value.StartsWith("](")) { tokens.Add(m.Value[2..^1]); return "](" + "{{" + (tokens.Count - 1) + "}})"; }
                tokens.Add(m.Value);
                return "{{" + (tokens.Count - 1) + "}}";
            });
        }
        return (text, tokens);
    }

    /// 按句子切成每块不超过 maxBytes（UTF-8）
    public static List<string> Chunks(string text, int maxBytes)
    {
        if (Encoding.UTF8.GetByteCount(text) <= maxBytes) return [text];
        var output = new List<string>();
        var current = new StringBuilder();
        foreach (var sentence in Regex.Split(text, @"(?<=[.!?。！？；;])\s*"))
        {
            if (sentence.Length == 0) continue;
            if (current.Length > 0 && Encoding.UTF8.GetByteCount(current.ToString() + sentence) > maxBytes) { output.Add(current.ToString()); current.Clear(); }
            if (Encoding.UTF8.GetByteCount(sentence) > maxBytes)
            {
                foreach (var ch in sentence)
                {
                    if (Encoding.UTF8.GetByteCount(current.ToString() + ch) > maxBytes) { output.Add(current.ToString()); current.Clear(); }
                    current.Append(ch);
                }
            }
            else current.Append(current.Length > 0 ? " " + sentence : sentence);
        }
        if (current.Length > 0) output.Add(current.ToString());
        return output;
    }
}
