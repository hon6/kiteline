using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Media;

namespace Kiteline.UI;

/// Linux 的界面字体是 Noto Sans CJK：’ “ ” … 这些标点它按中文的习惯排成全角（「Today’  s Usage」「Change Avatar···」）。
/// 按每段文字的内容定：有汉字照中文排，没有汉字开比例宽度（OpenType pwid）。和界面语言无关：中文界面里 Claude 的英文回复也排对。
/// Windows 的微软雅黑这几个标点本来就是西文宽度，不用管
public static partial class Punctuation
{
    static readonly FontFeatureCollection Proportional = [FontFeature.Parse("+pwid")];
    static readonly FontFeatureCollection Plain = [];

    /// 启动时调一次：所有文字块改了文字就按内容重新定
    public static void Install()
    {
        if (!OperatingSystem.IsLinux()) return;
        TextBlock.TextProperty.Changed.AddClassHandler<TextBlock>((block, _) => Fit(block, block.Text));
    }

    /// 给一块内容（文字块，或者一整段富文本的外框）定排法；text 为空 = 跟外面的走
    public static void Fit(Control target, string? text)
    {
        if (!OperatingSystem.IsLinux()) return;
        if (string.IsNullOrEmpty(text)) target.ClearValue(TextElement.FontFeaturesProperty);
        else TextElement.SetFontFeatures(target, Han().IsMatch(text) ? Plain : Proportional);
    }

    [System.Text.RegularExpressions.GeneratedRegex(@"[㐀-鿿豈-﫿　-〿＀-￯]")]
    private static partial System.Text.RegularExpressions.Regex Han();
}
