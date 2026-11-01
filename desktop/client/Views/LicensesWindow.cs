using System.Diagnostics;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 开源许可窗口（同 Mac 版 LicensesWindow）：设置 → 关于 →「开源许可」打开，左边可搜索的组件列表、右边许可原文。
/// 读程序里打包的 Assets/ThirdPartyNotices.json（tools/licenses.py 生成：Windows / Linux 版用到的 Python 包、.NET、Avalonia、点对点库……；
/// 同一份原文多个组件共用，按下标引用）
public sealed class LicensesWindow : Window
{
    static LicensesWindow? shown;
    /// 自测截图用
    public static Window? Current => shown;

    sealed record Component(string Name, string Summary, string Url, string? Note, int[] Texts);

    readonly List<Component> components = [];
    readonly List<string> texts = [];
    readonly StackPanel list = new() { Spacing = 1 };
    readonly ContentControl detail = new();
    readonly TextBox search = new() { FontSize = Look.Pt(13), Padding = new Thickness(10, 5) };
    Component? selected;

    public static void Open()
    {
        if (shown is null)
        {
            shown = new LicensesWindow();
            shown.Closed += (_, _) => shown = null;
            WindowChrome.FitToScreen(shown);
            shown.Show();
        }
        shown.Activate();
    }

    /// 自测截图用：选中名字是这个的组件（找不到就不选）
    public static void Select(string name)
    {
        if (shown?.components.FirstOrDefault(c => c.Name == name) is { } item) shown.Pick(item);
    }

    LicensesWindow()
    {
        Width = 900;
        Height = 660;
        MinWidth = 620;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Look.Family;
        Title = L("开源许可");
        this.Res(BackgroundProperty, "Window");
        Load();
        search.Watermark = L("搜索组件");
        search.TextChanged += (_, _) => Fill();
        var left = new DockPanel();
        DockPanel.SetDock(search, Dock.Top);
        left.Children.Add(search.Margin(10, 10, 10, 6));
        left.Children.Add(new ScrollViewer { Content = list.Margin(6, 0, 6, 10), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("290,1,*") };
        var rule = Ui.VRule();
        Grid.SetColumn(rule, 1);
        Grid.SetColumn(detail, 2);
        grid.Children.Add(left);
        grid.Children.Add(rule);
        grid.Children.Add(detail);
        Content = grid;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        // 开着窗口时换了界面语言：标题、搜索框和说明跟着换（许可原文本来就是英文）
        void Relabel() { Title = L("开源许可"); search.Watermark = L("搜索组件"); FontFamily = Look.Family; Fill(); Show(selected); }
        Lang.Changed += Relabel;
        Closed += (_, _) => Lang.Changed -= Relabel;
        Fill();
        Show(null);
    }

    void Load()
    {
        try
        {
            using var stream = Avalonia.Platform.AssetLoader.Open(new Uri("avares://KitelineApp/Assets/ThirdPartyNotices.json"));
            var root = JsonNode.Parse(stream);
            texts.AddRange(root.Arr("texts").Items().Select(n => n.GetValue<string>()));
            foreach (var row in root.Arr("components").Items())
            {
                var summary = string.Join(" · ", new[] { row.Str("version"), row.Str("license") }.Where(s => !string.IsNullOrEmpty(s)));
                components.Add(new Component(row.Str("name") ?? "", summary, row.Str("url") ?? "", row.Str("note"),
                    row.Arr("texts").Items().Select(n => n.GetValue<int>()).ToArray()));
            }
        }
        catch (Exception e) { Console.Error.WriteLine("读开源许可清单失败：" + e.Message); }
    }

    /// 左边的列表：按搜索框过滤；选中的那一行淡色底 + 细边
    void Fill()
    {
        list.Children.Clear();
        var query = search.Text?.Trim() ?? "";
        foreach (var item in components.Where(c => query.Length == 0 || c.Name.Contains(query, StringComparison.OrdinalIgnoreCase)))
        {
            var lines = new StackPanel { Spacing = 1 };
            lines.Children.Add(Ui.Text(item.Name, 13, FontWeight.Medium).Trim());
            if (item.Summary.Length > 0) lines.Children.Add(Ui.Text(item.Summary, 11.5, color: "Text2").Trim());
            var mine = item == selected;
            var row = new Tap(lines.Pad(10, 6), () => Pick(item), 6).Keys(mine ? "AccentFill10" : "Transparent", mine ? "AccentFill14" : "Fill08");
            if (mine) row.Res(Border.BorderBrushProperty, "AccentEdge40").BorderThickness = new Thickness(1);
            list.Children.Add(row);
        }
        if (components.Count == 0) list.Children.Add(Ui.Text(L("此版本未包含开源许可清单"), 12, color: "Text2", lines: 0).Wrap().Pad(10, 12));
    }

    void Pick(Component item)
    {
        selected = item;
        Fill();
        Show(item);
    }

    /// 右边：没选时是说明，选了是名字、版本 · 许可、出处和许可原文（照原样等宽显示、能选中复制）
    void Show(Component? item)
    {
        if (item is null)
        {
            detail.Content = Ui.Stack(Orientation.Vertical, 10, Align.Center, [
                Ui.Text(L("Kiteline 使用了下列开源软件，感谢这些项目的作者与贡献者。"), 14, lines: 0).Wrap(),
                Ui.Text(L("选择左侧的组件查看许可原文"), 13, color: "Text2", lines: 0).Wrap(),
            ]).HAlign(HorizontalAlignment.Center).Margin(40, 120, 40, 0);
            return;
        }
        var stack = new StackPanel { Spacing = 12 };
        var head = new StackPanel { Spacing = 4 };
        head.Children.Add(Ui.Text(item.Name, 18, FontWeight.SemiBold, lines: 0).Wrap());
        if (item.Summary.Length > 0) head.Children.Add(Ui.Text(item.Summary, 12, color: "Text2").Trim());
        if (item.Note is { Length: > 0 } note) head.Children.Add(Ui.Text(L(note), 12, color: "Text2", lines: 0).Wrap());
        if (item.Url.Length > 0)
        {
            var link = new Tap(Ui.Text(item.Url, 12, color: "Accent").Trim().Pad(4, 2), () =>
            {
                try { Process.Start(new ProcessStartInfo(item.Url) { UseShellExecute = true }); } catch { }
            }, 4).Keys("Transparent", "Fill08");
            link.HorizontalAlignment = HorizontalAlignment.Left;
            head.Children.Add(link.Margin(-4, 0, 0, 0));
        }
        stack.Children.Add(head);
        foreach (var index in item.Texts.Where(i => i >= 0 && i < texts.Count))
        {
            var text = new SelectableTextBlock { Text = texts[index], FontFamily = Look.Mono, FontSize = Look.Pt(11.5), TextWrapping = TextWrapping.Wrap };
            text.Res(TextBlock.ForegroundProperty, "Text").Res(SelectableTextBlock.SelectionBrushProperty, "AccentFill20");
            stack.Children.Add(new Border { Padding = new Thickness(12), CornerRadius = new CornerRadius(8), Child = text }.Res(Border.BackgroundProperty, "Fill03"));
        }
        detail.Content = new ScrollViewer { Content = stack.Margin(20, 20, 20, 20), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
}
