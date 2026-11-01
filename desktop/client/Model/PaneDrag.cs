namespace Kiteline.Model;

/// 拖会话（左边栏的一行、分屏里的一个标签）时带的数据：会话 key + 从哪一块拖出来的
public static class PaneDrag
{
    public const string Format = "application/x-kiteline-session";

    public static string Encode(string key, Guid? source) => source is Guid s ? $"{key}\n{s}" : key;

    public static (string Key, Guid? Source)? Decode(object? data)
    {
        if (data is not string text || text.Length == 0) return null;
        var parts = text.Split('\n');
        return (parts[0], parts.Length > 1 && Guid.TryParse(parts[1], out var g) ? g : null);
    }
}
