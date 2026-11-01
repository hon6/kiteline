using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Kiteline.Model;

/// 读后台送来的 JSON：字段一律可选、类型不对就当没有（同 iOS 版的 decoder.fields()）。
/// 后台和客户端版本不一定同步，多一个少一个字段都不能让整份数据解析失败
public static class J
{
    public static JsonNode? Get(this JsonNode? node, string key) => node is JsonObject o && o.TryGetPropertyValue(key, out var v) ? v : null;

    public static string? Str(this JsonNode? node, string key) => AsString(node.Get(key));

    public static string? AsString(JsonNode? value)
    {
        if (value is not JsonValue v) return null;
        if (v.TryGetValue<string>(out var s)) return s;
        if (v.TryGetValue<JsonElement>(out var e))
        {
            return e.ValueKind switch
            {
                JsonValueKind.String => e.GetString(),
                JsonValueKind.Number => e.GetRawText(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                _ => null,
            };
        }
        if (v.TryGetValue<double>(out var d)) return d.ToString(CultureInfo.InvariantCulture);
        if (v.TryGetValue<bool>(out var b)) return b ? "true" : "false";
        return null;
    }

    public static double? Num(this JsonNode? node, string key) => AsNumber(node.Get(key));

    public static double? AsNumber(JsonNode? value)
    {
        if (value is not JsonValue v) return null;
        if (v.TryGetValue<double>(out var d)) return d;
        if (v.TryGetValue<long>(out var l)) return l;
        if (v.TryGetValue<int>(out var i)) return i;
        if (v.TryGetValue<JsonElement>(out var e))
        {
            if (e.ValueKind == JsonValueKind.Number && e.TryGetDouble(out var n)) return n;
            if (e.ValueKind == JsonValueKind.String && double.TryParse(e.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var p)) return p;
        }
        if (v.TryGetValue<string>(out var s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var q)) return q;
        return null;
    }

    public static int? Int(this JsonNode? node, string key) => node.Num(key) is double d ? (int)Math.Round(d) : null;

    public static bool? Bool(this JsonNode? node, string key)
    {
        if (node.Get(key) is not JsonValue v) return null;
        if (v.TryGetValue<bool>(out var b)) return b;
        if (v.TryGetValue<JsonElement>(out var e))
        {
            if (e.ValueKind == JsonValueKind.True) return true;
            if (e.ValueKind == JsonValueKind.False) return false;
            if (e.ValueKind == JsonValueKind.Number) return e.GetDouble() != 0;
        }
        return AsNumber(v) is double d ? d != 0 : null;
    }

    /// 有就是真（字符串非空、数非零、true）
    public static bool Truthy(this JsonNode? node, string key)
    {
        var value = node.Get(key);
        if (value is null) return false;
        if (node.Bool(key) is bool b) return b;
        return !string.IsNullOrEmpty(AsString(value));
    }

    public static JsonArray? Arr(this JsonNode? node, string key) => node.Get(key) as JsonArray;
    public static JsonObject? Obj(this JsonNode? node, string key) => node.Get(key) as JsonObject;

    public static IEnumerable<JsonNode> Items(this JsonArray? array) => array is null ? [] : array.OfType<JsonNode>();

    public static List<string> Strings(this JsonNode? node, string key) =>
        node.Arr(key).Items().Select(AsString).Where(s => s is not null).Select(s => s!).ToList();

    public static JsonNode? Parse(string text)
    {
        try { return JsonNode.Parse(text); }
        catch (JsonException) { return null; }
    }

    public static JsonNode? Parse(byte[] data)
    {
        // 记事本、PowerShell 存的 UTF-8 开头带 BOM，System.Text.Json 不认
        if (data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) data = data[3..];
        try { return JsonNode.Parse(data); }
        catch (JsonException) { return null; }
    }
}
