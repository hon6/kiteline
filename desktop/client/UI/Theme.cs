using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Styling;
using Kiteline.Model;
using static Kiteline.Lang;

namespace Kiteline.UI;

/// 一套主题色：强调色、主按钮、我发的气泡和气泡上的字；浅色、深色各一份（同 KitelineKit/Views/Look.swift，id 不能变）
public sealed record LookTheme(string Id, string Name, uint Accent, uint AccentDark, uint Action, uint ActionDark,
                               uint Bubble, uint BubbleDark, uint BubbleText, uint BubbleTextDark)
{
    public static readonly LookTheme[] All =
    [
        new("classic", "经典", 0xD97757, 0xD97757, 0x07C160, 0x07C160, 0x95EC69, 0x3EB575, 0x111111, 0x08180E),
        new("clay", "赤陶", 0xD97757, 0xE08B6E, 0xD97757, 0xD97757, 0xF7E0D6, 0x8E4B36, 0x2B1911, 0xFFF5F0),
        new("ocean", "海蓝", 0x007AFF, 0x0A84FF, 0x007AFF, 0x0A84FF, 0xDCEBFF, 0x1F4E8C, 0x0A2140, 0xF2F7FF),
        new("pine", "松绿", 0x2E8B6A, 0x3FB28A, 0x2E8B6A, 0x2F9C76, 0xD9F0E5, 0x235E48, 0x0E2A1F, 0xEFFAF5),
        new("violet", "暮紫", 0x6E56CF, 0x9E8CFC, 0x6E56CF, 0x7B64DD, 0xE9E4FB, 0x45388A, 0x1D1440, 0xF5F2FF),
        new("graphite", "石墨", 0x3A3A3C, 0xD1D1D6, 0x1C1C1E, 0x636366, 0xE5E5EA, 0x3A3A3C, 0x111111, 0xF2F2F7),
        new("rose", "樱粉", 0xC8506E, 0xE07A93, 0xC8506E, 0xD2607C, 0xFBE3EA, 0x7A2E43, 0x3A0F1D, 0xFFF2F5),
        new("amber", "琥珀", 0xB7791F, 0xE3A645, 0xB7791F, 0xC98A2C, 0xFBEFD9, 0x6E4A12, 0x3A2706, 0xFFF7E8),
        new("teal", "青碧", 0x0F8B8D, 0x34B5B7, 0x0F8B8D, 0x1A9C9E, 0xD5F1F1, 0x145A5C, 0x06302F, 0xEDFBFB),
        new("indigo", "靛青", 0x3F51B5, 0x7C8CF0, 0x3F51B5, 0x5466D0, 0xE3E7FA, 0x2E3A85, 0x141A45, 0xF2F4FF),
        new("wine", "酒红", 0x9B2D4A, 0xD4637F, 0x9B2D4A, 0xB03A58, 0xF5DDE4, 0x5E1E30, 0x3A0A17, 0xFFF0F4),
        new("olive", "橄榄", 0x6B7A2E, 0xA3B556, 0x6B7A2E, 0x7D8D38, 0xEDF1D9, 0x44501C, 0x23290B, 0xF8FBEC),
        new("mocha", "咖啡", 0x8B6247, 0xC2967A, 0x8B6247, 0x9C7155, 0xF2E6DC, 0x5A3F2D, 0x2E1E14, 0xFFF6EF),
        new("navy", "墨蓝", 0x1F3A5F, 0x8AA6CF, 0x1F3A5F, 0x3D5A85, 0xDFE6F0, 0x24364F, 0x0E1B2C, 0xEEF3FA),
    ];

    public static LookTheme Named(string? id) => All.FirstOrDefault(t => t.Id == id) ?? All[0];

    /// 自定义：从一个颜色配出整套（同 iOS / Mac 版 LookTheme.custom）
    public static LookTheme Custom(uint hex)
    {
        var lum = Luminance(hex);
        var accentDark = lum < 0.12 ? Mix(hex, 0xFFFFFF, 0.45) : hex;
        var action = lum > 0.45 ? Mix(hex, 0x000000, 0.35) : hex;
        var actionDark = Luminance(action) < 0.05 ? Mix(action, 0xFFFFFF, 0.3) : action;
        return new("custom", "自定义", hex, accentDark, action, actionDark, Mix(hex, 0xFFFFFF, 0.84), Mix(hex, 0x000000, 0.55),
                   Mix(hex, 0x000000, 0.8), Mix(hex, 0xFFFFFF, 0.92));
    }

    public static uint Mix(uint a, uint b, double t)
    {
        uint Channel(int shift)
        {
            double x = (a >> shift) & 0xFF, y = (b >> shift) & 0xFF;
            return (uint)Math.Round(x + (y - x) * t) << shift;
        }
        return Channel(16) | Channel(8) | Channel(0);
    }

    public static double Luminance(uint hex)
    {
        double Linear(int shift)
        {
            var c = ((hex >> shift) & 0xFF) / 255.0;
            return c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Linear(16) + 0.7152 * Linear(8) + 0.0722 * Linear(0);
    }
}

/// 字号档位（同 iOS / Mac 版 LookSize）
public sealed record LookSize(string Id, string Name, double Scale)
{
    public static readonly LookSize[] All =
    [
        new("xs", "特小", 0.82), new("s", "小", 0.88), new("m", "较小", 0.94), new("l", "标准", 1),
        new("xl", "较大", 1.12), new("xxl", "大", 1.24), new("xxxl", "特大", 1.35),
    ];

    public static LookSize Named(string? id) => All.FirstOrDefault(s => s.Id == id) ?? All[3];
}

/// 一种字体（同 Mac 版 LookFont 的 id；苹果的中文字体这里没有，换成这台电脑上有的同风格字体；没装的不列出来）
/// Detail 是 Windows 上的说明，LinuxDetail 给了就是 Linux 上的（两边用的字体不一样）
public sealed record LookFont(string Id, string Name, string Detail, string Group, string[] Windows, string[] Linux, string? LinuxDetail = null)
{
    public static readonly LookFont[] All =
    [
        // 一种字体从头到尾（中文字体自带的西文字形）：Avalonia 在西文字体、中文字体之间来回回退时，同一句话量出来和画出来会不一样宽，
        // 标签、按钮里的字被截掉一截（10-23 实测）。微软雅黑 UI 的西文就是照 Segoe UI 设计的，观感还是 Windows 的样子
        new("system", "系统", "微软雅黑 UI", "正文", ["Microsoft YaHei UI", "Segoe UI Variable Text", "Segoe UI"], ["Noto Sans CJK SC", "Ubuntu Sans", "DejaVu Sans"], "Noto Sans CJK"),
        new("rounded", "圆体", "笔画圆润", "正文", ["Microsoft YaHei UI Light", "Segoe UI Variable Display"], ["M PLUS Rounded 1c", "Zen Maru Gothic"]),
        new("mono", "等宽", "Cascadia Mono + 微软雅黑", "正文", ["Cascadia Mono", "Consolas", "Microsoft YaHei UI"], ["Noto Sans Mono CJK SC", "Ubuntu Mono", "DejaVu Sans Mono"], "Noto Sans Mono CJK"),
        new("serif", "宋体", "适合长篇阅读", "书卷", ["SimSun", "NSimSun", "Songti SC"], ["Noto Serif CJK SC", "AR PL UMing CN"]),
        new("kai", "楷体", "端正的手写感", "书卷", ["KaiTi", "STKaiti"], ["AR PL UKai CN", "AR PL KaitiM GB"]),
        new("fangsong", "仿宋", "清秀的印刷体", "书卷", ["FangSong", "STFangsong"], []),
        new("lishu", "隶书", "隶书", "手写与艺术", ["LiSu", "STLiti"], []),
        new("youyuan", "幼圆", "圆润的黑体", "手写与艺术", ["YouYuan"], []),
    ];

    public static LookFont Named(string? id) => All.FirstOrDefault(f => f.Id == id) ?? All[0];

    public string[] Families => OperatingSystem.IsWindows() ? Windows : Linux;

    /// 设置里字体名下面那行小字
    public string Note => OperatingSystem.IsLinux() ? LinuxDetail ?? Detail : Detail;

    public bool Available => Id == "system" || Families.Any(f => FontManager.Current.SystemFonts.Any(s => s.Name == f));
}

/// 这台电脑上的外观设置（同 Mac 版 Look）：主题色、字体、字号；界面读这里的颜色资源，换了自动重画
public static class Look
{
    public static LookTheme Theme { get; private set; } = LookTheme.All[0];
    public static LookFont Font { get; private set; } = LookFont.All[0];
    public static LookSize Size { get; private set; } = LookSize.All[3];
    public static double TextScale => Size.Scale;
    public static event Action? Changed;

    public static FontFamily Family { get; private set; } = new("Segoe UI");
    public static FontFamily Mono { get; private set; } = new("Consolas");

    public static void Load()
    {
        var themeId = Prefs.String("lookTheme");
        Theme = themeId == "custom" && Prefs.String("lookCustom") is string hex && uint.TryParse(hex.TrimStart('#'), System.Globalization.NumberStyles.HexNumber, null, out var c)
            ? LookTheme.Custom(c) : LookTheme.Named(themeId);
        Font = LookFont.Named(Prefs.String("lookFont"));
        if (!Font.Available) Font = LookFont.All[0];
        Size = LookSize.Named(Prefs.String("lookSize"));
        Apply();
    }

    public static void SetTheme(LookTheme theme)
    {
        Theme = theme;
        Prefs.Set("lookTheme", theme.Id);
        if (theme.Id == "custom") Prefs.Set("lookCustom", $"#{theme.Accent:X6}");
        Apply();
    }

    public static void SetFont(LookFont font) { Font = font; Prefs.Set("lookFont", font.Id); Apply(); }
    public static void SetSize(LookSize size) { Size = size; Prefs.Set("lookSize", size.Id); Apply(); }

    /// 字号：按 Mac 版的点数写，乘设置里的字号倍数
    public static double Pt(double size) => Math.Round(size * TextScale * 2) / 2;

    static FontFamily Join(IEnumerable<string> names) => new(string.Join(", ", names));

    static void Apply()
    {
        var system = LookFont.All[0].Families;
        Family = Join(Font.Families.Concat(system).Distinct());
        Mono = Join((OperatingSystem.IsWindows() ? new[] { "Cascadia Mono", "Consolas", "Microsoft YaHei UI" } : ["Ubuntu Mono", "DejaVu Sans Mono", "Noto Sans Mono CJK SC"]));
        Palette.ApplyTheme(Theme);
        if (Application.Current is { } app) app.Resources["AppFont"] = Family;
        Changed?.Invoke();
    }
}

/// 颜色：浅色、深色各一份，放进界面资源（ThemeDictionaries），跟着系统深浅色自动切换（同 Mac 版 Theme / MacPalette）
public static class Palette
{
    // 和主题无关的颜色：(浅色, 深色)，十六进制 + 不透明度
    static readonly (string Key, uint Light, double LightAlpha, uint Dark, double DarkAlpha)[] Fixed =
    [
        // 文字：同 macOS 的 labelColor / secondaryLabelColor / tertiaryLabelColor / quaternaryLabelColor
        ("Text", 0x000000, 0.85, 0xFFFFFF, 0.85),
        ("Text2", 0x000000, 0.50, 0xFFFFFF, 0.55),
        ("Text3", 0x000000, 0.26, 0xFFFFFF, 0.25),
        ("Text4", 0x000000, 0.10, 0xFFFFFF, 0.10),
        // 「Color.primary.opacity(x)」：悬停、浅底
        ("Fill03", 0x000000, 0.03, 0xFFFFFF, 0.03),
        ("Fill045", 0x000000, 0.045, 0xFFFFFF, 0.045),
        ("Fill05", 0x000000, 0.05, 0xFFFFFF, 0.05),
        ("Fill06", 0x000000, 0.06, 0xFFFFFF, 0.06),
        ("Fill08", 0x000000, 0.08, 0xFFFFFF, 0.08),
        ("Fill10", 0x000000, 0.10, 0xFFFFFF, 0.10),
        ("Fill12", 0x000000, 0.12, 0xFFFFFF, 0.12),
        ("Fill15", 0x000000, 0.15, 0xFFFFFF, 0.15),
        // 窗口、对话区的底色（同 NSColor.windowBackgroundColor）
        ("Window", 0xF5F5F5, 1, 0x1E1E1E, 1),
        ("ChatBackground", 0xF5F5F5, 1, 0x1E1E1E, 1),
        // 侧栏（Mac 上是液态玻璃）
        ("Sidebar", 0xEAEAEC, 1, 0x2A2A2C, 1),
        // 侧栏玻璃：系统模糊之上的底色 / 模糊壁纸之上的底色（壁纸那层没有系统的材质，盖得厚一点）
        ("SidebarTint", 0xEAEAEC, 0.45, 0x2A2A2C, 0.45),
        ("SidebarWallpaperTint", 0xEAEAEC, 0.72, 0x2A2A2C, 0.74),
        ("WindowEdge", 0x000000, 0.14, 0xFFFFFF, 0.10),
        ("SidebarEdge", 0x000000, 0.08, 0xFFFFFF, 0.08),
        // Claude 的气泡、工具卡片：半透明灰
        ("BotBubble", 0x787880, 0.12, 0xFFFFFF, 0.08),
        ("Code", 0x000000, 0.05, 0xFFFFFF, 0.09),
        // 表格底色：代码底色的六成
        ("CodeSoft", 0x000000, 0.03, 0xFFFFFF, 0.054),
        ("Card", 0xFFFFFF, 1, 0x1C1C1E, 1),
        ("Surface", 0xFFFFFF, 1, 0x1C1C1E, 1),
        ("Surface2", 0xF7F7F8, 1, 0x2C2C2E, 1),
        // 弹出面板的底色（同 Mac 的 sheet / 面板窗口：比里面的输入框、列表亮一档）
        ("Sheet", 0xECECEC, 1, 0x2B2B2D, 1),
        ("Separator", 0x3C3C43, 0.18, 0x545458, 0.6),
        // 分屏的标签栏：压在对话底色上的一层暗色
        ("TabStrip", 0x000000, 0.055, 0x000000, 0.32),
        ("Field", 0xFFFFFF, 1, 0x2C2C2C, 1),
        ("InputBar", 0xF7F7F7, 1, 0x1E1E1E, 1),
        ("PageBackground", 0xF2F2F7, 1, 0x000000, 1),
        ("Tile", 0xF4F4F6, 1, 0x1C1C1E, 1),
        // 玻璃（底栏、按钮）：浅色压一层白、深色压一层亮灰
        ("Glass", 0xFFFFFF, 0.72, 0x3A3A3C, 0.72),
        // 分段切换里选中的那段
        ("SegmentOn", 0xFFFFFF, 1, 0xFFFFFF, 0.16),
        ("GlassEdge", 0x000000, 0.08, 0xFFFFFF, 0.12),
        // 压在列表上的玻璃（侧栏底栏）：这里没有窗口内模糊，几乎不透明，不然下面的字透上来很乱
        ("GlassSolid", 0xF7F7F8, 0.97, 0x3A3A3C, 0.97),
        ("Menu", 0xFFFFFF, 0.98, 0x2B2B2D, 0.98),
        ("Shadow", 0x000000, 0.18, 0x000000, 0.45),
        ("Orange", 0xFF9F0A, 1, 0xFF9F0A, 1),
        ("Red", 0xFF3B30, 1, 0xFF453A, 1),
        ("Green", 0x34C759, 1, 0x30D158, 1),
        ("Added", 0x219A4D, 1, 0x219A4D, 1),
        ("Removed", 0xD94040, 1, 0xD94040, 1),
        ("AddedFill", 0x219A4D, 0.14, 0x219A4D, 0.18),
        ("RemovedFill", 0xD94040, 0.12, 0xD94040, 0.16),
        // 代码高亮：深色模式用亮一档的颜色（同 Mac 版 CodeView）
        ("CodeString", 0xC2410C, 1, 0xFB923C, 1),
        ("CodeNumber", 0x7C3AED, 1, 0xA78BFA, 1),
        ("CodeKeyword", 0xBE185D, 1, 0xF472B6, 1),
        ("Blue", 0x007AFF, 1, 0x0A84FF, 1),
        ("OrangeFill13", 0xFF9F0A, 0.13, 0xFF9F0A, 0.13),
        // 目标的小标识：停下了橙、达成绿、做不到红（淡底 + 细边，同选中态）
        ("OrangeEdge40", 0xFF9F0A, 0.40, 0xFF9F0A, 0.40),
        ("AddedEdge40", 0x219A4D, 0.40, 0x219A4D, 0.40),
        ("RemovedEdge40", 0xD94040, 0.40, 0xD94040, 0.40),
        ("GreenFill13", 0x34C759, 0.13, 0x30D158, 0.13),
        ("GreenHover", 0x2FB350, 1, 0x2BBE4F, 1),
        // 待办的打勾、「加入」按钮（同 Mac 版 Theme.wechatGreen）
        ("WechatGreen", 0x07C160, 1, 0x07C160, 1),
        ("GreenPressed", 0x28A046, 1, 0x26A845, 1),
        ("ControlBackground", 0xFFFFFF, 1, 0x1E1E1E, 1),
        ("White", 0xFFFFFF, 1, 0xFFFFFF, 1),
    ];

    static readonly ResourceDictionary LightDict = new();
    static readonly ResourceDictionary DarkDict = new();

    public static void Install(Application app)
    {
        foreach (var (key, light, la, dark, da) in Fixed)
        {
            LightDict[key] = Brush(light, la);
            DarkDict[key] = Brush(dark, da);
            LightDict[key + "Color"] = Color(light, la);
            DarkDict[key + "Color"] = Color(dark, da);
        }
        app.Resources.ThemeDictionaries[ThemeVariant.Light] = LightDict;
        app.Resources.ThemeDictionaries[ThemeVariant.Dark] = DarkDict;
        ApplyTheme(Look.Theme);
    }

    public static void ApplyTheme(LookTheme t)
    {
        void Set(string key, uint light, double la, uint dark, double da)
        {
            LightDict[key] = Brush(light, la);
            DarkDict[key] = Brush(dark, da);
            LightDict[key + "Color"] = Color(light, la);
            DarkDict[key + "Color"] = Color(dark, da);
        }
        Set("Accent", t.Accent, 1, t.AccentDark, 1);
        Set("Action", t.Action, 1, t.ActionDark, 1);
        Set("Bubble", t.Bubble, 1, t.BubbleDark, 1);
        Set("BubbleText", t.BubbleText, 1, t.BubbleTextDark, 1);
        // 图标、首字头像的底：淡淡的强调色
        Set("IconTile", t.Accent, 0.13, t.AccentDark, 0.16);
        // 侧栏选中：淡品牌色底 + 细边（同 Mac 版 SidebarRowHighlight / SidebarTile）
        Set("AccentFill14", t.Accent, 0.14, t.AccentDark, 0.14);
        Set("AccentFill16", t.Accent, 0.16, t.AccentDark, 0.16);
        Set("AccentEdge25", t.Accent, 0.25, t.AccentDark, 0.25);
        Set("AccentEdge32", t.Accent, 0.32, t.AccentDark, 0.32);
        Set("AccentEdge40", t.Accent, 0.40, t.AccentDark, 0.40);
        Set("AccentFill10", t.Accent, 0.10, t.AccentDark, 0.10);
        Set("AccentFill20", t.Accent, 0.20, t.AccentDark, 0.20);
        Set("ActionFill10", t.Action, 0.10, t.ActionDark, 0.10);
        // Fluent 自带控件（开关、滑块、选中）也用主题色
        Set("SystemAccent", t.Action, 1, t.ActionDark, 1);   // Fluent 读 SystemAccentColor（颜色）
    }

    public static Color Color(uint hex, double alpha = 1) =>
        Avalonia.Media.Color.FromArgb((byte)Math.Round(alpha * 255), (byte)((hex >> 16) & 0xFF), (byte)((hex >> 8) & 0xFF), (byte)(hex & 0xFF));

    public static IBrush Brush(uint hex, double alpha = 1) => new ImmutableSolidColorBrush(Color(hex, alpha));

    /// 现在是不是深色
    public static bool IsDark => Application.Current?.ActualThemeVariant == ThemeVariant.Dark;

    /// 直接取当前深浅色下的颜色（画图、算颜色时用；界面元素用 Res 绑定，深浅色切换自动跟着变）
    public static IBrush Get(string key)
    {
        var dict = IsDark ? DarkDict : LightDict;
        return dict.TryGetValue(key, out var v) && v is IBrush b ? b : Brushes.Transparent;
    }

    public static Color GetColor(string key)
    {
        var dict = IsDark ? DarkDict : LightDict;
        return dict.TryGetValue(key + "Color", out var v) && v is Color c ? c : Colors.Transparent;
    }
}
