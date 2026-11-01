using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Kiteline.UI;

/// 图标：Mac 版写的是 SF Symbols 的名字（folder、checkmark.seal……），这里查表换成 Fluent UI 图标（Icons.g.cs）。
/// 名字以 .fill 结尾的用实心版
public static partial class Icons
{
    public static readonly FontFamily Regular = new("avares://KitelineApp/Assets/Fonts#FluentSystemIcons-Regular");
    public static readonly FontFamily Filled = new("avares://KitelineApp/Assets/Fonts#FluentSystemIcons-Filled");

    /// 按 SF 名和字号挑字形：小字号用 20 号的版本（笔画更清楚），大的用 24 号
    public static (FontFamily Font, string Glyph) Glyph(string symbol, double size)
    {
        var filled = symbol.EndsWith(".fill");
        var name = filled ? symbol[..^5] : symbol;
        if (!Table.TryGetValue(name, out var entry) && !Table.TryGetValue(symbol, out entry))
            return (Regular, "");
        var small = size <= 20;
        int code;
        if (filled) code = small ? (entry.F20 != 0 ? entry.F20 : entry.F24) : (entry.F24 != 0 ? entry.F24 : entry.F20);
        else code = small ? (entry.R20 != 0 ? entry.R20 : entry.R24) : (entry.R24 != 0 ? entry.R24 : entry.R20);
        if (code == 0) { filled = !filled; code = entry.R20 != 0 ? entry.R20 : entry.F20; }
        return (filled ? Filled : Regular, char.ConvertFromUtf32(code));
    }

    public static bool Has(string symbol) => Table.ContainsKey(symbol.EndsWith(".fill") ? symbol[..^5] : symbol);
}

/// 一个图标。Size 照 Mac 版 .font(.system(size:)) 的点数写；SF 图标比字号小一圈，Fluent 字形撑满方框，放大一点对上
public sealed class Icon : TextBlock
{
    public static readonly StyledProperty<string> SymbolProperty = AvaloniaProperty.Register<Icon, string>(nameof(Symbol), "");
    public static readonly StyledProperty<double> SizeProperty = AvaloniaProperty.Register<Icon, double>(nameof(Size), 13);

    public string Symbol { get => GetValue(SymbolProperty); set => SetValue(SymbolProperty, value); }
    public double Size { get => GetValue(SizeProperty); set => SetValue(SizeProperty, value); }

    public Icon() { VerticalAlignment = VerticalAlignment.Center; TextAlignment = TextAlignment.Center; }

    public Icon(string symbol, double size = 13) : this()
    {
        Symbol = symbol;
        Size = size;
        Update();
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == SymbolProperty || change.Property == SizeProperty) Update();
    }

    void Update()
    {
        var px = Size * 1.22;
        var (font, glyph) = Icons.Glyph(Symbol, px);
        FontFamily = font;
        FontSize = px;
        Text = glyph;
        LineHeight = px;
    }
}
