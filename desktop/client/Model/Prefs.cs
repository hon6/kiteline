using System.Text.Json;
using System.Text.Json.Nodes;
using Avalonia.Threading;

namespace Kiteline.Model;

/// 这台电脑上客户端自己的偏好（同 Mac 的 UserDefaults）：草稿、已读位置、分屏布局、列表分组排序、外观……
/// 存在配置目录的 app-prefs.json，改了半秒后写盘
public static class Prefs
{
    static JsonObject data = new();
    static string? path;
    static DispatcherTimer? timer;

    public static void Load(string configDir)
    {
        path = Path.Combine(configDir, "app-prefs.json");
        try
        {
            if (File.Exists(path) && J.Parse(File.ReadAllBytes(path)) is JsonObject o) data = o;
        }
        catch (IOException) { }
    }

    /// 自测、截图：不读不写（几次截图互不影响）
    public static void UseMemory() => path = null;

    public static string? String(string key) => data.Str(key);
    public static double? Number(string key) => data.Num(key);
    public static bool Bool(string key, bool fallback = false) => data.Bool(key) ?? fallback;
    public static JsonNode? Node(string key) => data.Get(key);

    public static Dictionary<string, string> StringMap(string key) =>
        data.Obj(key)?.Where(kv => J.AsString(kv.Value) is not null).ToDictionary(kv => kv.Key, kv => J.AsString(kv.Value)!) ?? new();

    public static Dictionary<string, double> NumberMap(string key) =>
        data.Obj(key)?.Where(kv => J.AsNumber(kv.Value) is not null).ToDictionary(kv => kv.Key, kv => J.AsNumber(kv.Value)!.Value) ?? new();

    public static void Set(string key, object? value)
    {
        data[key] = value switch
        {
            null => null,
            JsonNode node => node,
            _ => JsonSerializer.SerializeToNode(value),
        };
        Schedule();
    }

    public static void Remove(string key)
    {
        data.Remove(key);
        Schedule();
    }

    static void Schedule()
    {
        if (path is null) return;
        if (timer is null)
        {
            timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            timer.Tick += (_, _) => { timer.Stop(); Save(); };
        }
        timer.Stop();
        timer.Start();
    }

    /// 马上写盘（退出前）
    public static void Save()
    {
        if (path is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, data.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
            File.Move(tmp, path, true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
