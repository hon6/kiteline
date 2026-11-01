using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Kiteline;

/// 界面文字：代码里一律写中文原文，L() 按界面语言取译文（同 iOS / Mac 版的 L）。
/// 英文表是 Assets/i18n_en.json，由 tools/i18n.py build 从 i18n/en.json 生成（和手机、Mac、电脑端后台同一张表）。
/// 界面语言和电脑端后台（托盘、控制台）是同一个设置，存在后台的配置里：跟随系统（中文系统用中文，其余用英文）/ 简体中文 / English，
/// 改了马上换，不用重启（Changed 通知主窗口、设置窗口重新搭，实时连接按新语言重连）。
/// 格式占位照 Swift 的写法：%@、%lld、%d 按顺序填，译文里可以用 %2$@ 换顺序；
/// 带数量的句子表里写 one / other，按第一个数字参数挑（「1 session」「3 sessions」）
public static partial class Lang
{
    /// 设置里选的：system / zh / en
    public static string Choice { get; private set; } = "system";

    /// 现在用的："zh" / "en"
    public static string Current { get; private set; } = "zh";

    public static bool IsEnglish => Current == "en";

    public static event Action? Changed;

    static readonly Dictionary<string, string> English = new();
    /// 占位符统一成 %@ 后的键 → 译文（C# 里有的写 %@、表里写 %lld，都能对上）
    static readonly Dictionary<string, string> Loose = new();
    static readonly Dictionary<string, (string? One, string Other)> Plurals = new();
    static bool loaded;

    /// 命令行 --lang 指定的（自测、截图）：不跟后台的设置走
    static bool pinned;

    /// 固定用某种语言（命令行 --lang）
    public static void Pin(string choice)
    {
        pinned = false;
        Use(choice);
        pinned = true;
    }

    /// 换界面语言（choice = system / zh / en）
    public static void Use(string? choice)
    {
        if (pinned) return;
        Choice = choice is "zh" or "en" ? choice : "system";
        var current = Choice == "system" ? (SystemChinese() ? "zh" : "en") : Choice;
        if (current == "en") Load();
        if (current == Current) return;
        Current = current;
        Changed?.Invoke();
    }

    /// 后台配置里存的界面语言（config.json 的 mobile.uiLanguage）
    public static string? Saved(string configDir)
    {
        try
        {
            return JsonNode.Parse(File.ReadAllText(Path.Combine(configDir, "config.json")))?["mobile"]?["uiLanguage"]?.GetValue<string>();
        }
        catch (Exception) { return null; }
    }

    /// 系统界面语言是不是中文（同电脑端后台 i18n.system_chinese）：Windows 看用户界面语言，Linux 看 LANGUAGE / LC_* / LANG
    static bool SystemChinese()
    {
        if (OperatingSystem.IsWindows()) return CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
        foreach (var name in new[] { "LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG" })
            if (Environment.GetEnvironmentVariable(name) is { Length: > 0 } value) return value.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
        return true;
    }

    static void Load()
    {
        if (loaded) return;
        loaded = true;
        try
        {
            using var stream = Avalonia.Platform.AssetLoader.Open(new Uri("avares://KitelineApp/Assets/i18n_en.json"));
            if (JsonNode.Parse(stream) is not JsonObject table) return;
            foreach (var (key, value) in table)
            {
                if (value is JsonObject forms && forms["other"]?.GetValue<string>() is string other)
                {
                    var one = forms["one"]?.GetValue<string>();
                    Plurals[Placeholders(key)] = (one, other);
                    English.TryAdd(key, other);
                    Loose.TryAdd(Placeholders(key), other);
                }
                else if (value?.GetValue<string>() is string text)
                {
                    English[key] = text;
                    Loose.TryAdd(Placeholders(key), text);
                }
            }
        }
        catch (Exception) { }
    }

    /// 占位符都记成 %@、%% 记成 %（表里照 Swift 写「上下文 %lld%%」，C# 里写「上下文 %@%」）
    static string Placeholders(string text) => Placeholder().Replace(text.Replace("%%", "%"), "%@");

    public static string L(string text, params object?[] args)
    {
        var format = Current == "en" ? Translate(text, args) : text;
        if (args.Length == 0) return format.Replace("%%", "%");
        var index = 0;
        return Placeholder().Replace(format.Replace("%%", "\u0001"), m =>
        {
            var at = m.Groups[1].Success ? int.Parse(m.Groups[1].Value) - 1 : index++;
            return at >= 0 && at < args.Length ? Convert.ToString(args[at], CultureInfo.InvariantCulture) ?? "" : "";
        }).Replace('\u0001', '%');
    }

    static string Translate(string text, object?[] args)
    {
        var loose = Placeholders(text);
        // 带数量：按第一个数字挑单数 / 复数
        if (Plurals.TryGetValue(loose, out var forms) && args.FirstOrDefault(IsNumber) is { } count)
            return Convert.ToDouble(count, CultureInfo.InvariantCulture) == 1 && forms.One is not null ? forms.One : forms.Other;
        return English.TryGetValue(text, out var exact) ? exact : Loose.TryGetValue(loose, out var found) ? found : text;
    }

    /// 机器名：后台默认的「本机」按界面语言换，用户自己起的名字不动（同后台 i18n.py）
    public static string Machine(string name) => name == "本机" ? L("本机") : name;

    static bool IsNumber(object? value) => value is int or long or double or float or decimal or short;

    [GeneratedRegex(@"%(?:(\d+)\$)?(?:@|lld|ld|d|s)")]
    private static partial Regex Placeholder();
}
