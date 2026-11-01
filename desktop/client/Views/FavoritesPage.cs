using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 我的收藏（同 Mac 版 FavoritesView）：收藏的消息一条一张卡片，新的在上；顶上搜索（内容、会话名）；
/// 卡片底下「原消息」跳回那条消息，右键复制、取消收藏。内容存在电脑上，手机上收藏的这里也有
public sealed class FavoritesPage : Panel
{
    readonly StackPanel list = new() { Spacing = 10, Margin = new Thickness(20, 0, 20, 24) };
    readonly ContentControl empty = new();
    readonly PageBar bar;
    readonly TextBox box;
    string query = "";

    public FavoritesPage()
    {
        bar = new PageBar(L("收藏"), null, null, [PageBar.Button("arrow.clockwise", L("刷新"), () => _ = FavoriteState.Shared.Refresh())]);
        box = new TextBox
        {
            Watermark = L("搜索收藏的内容、会话"), Classes = { "plain" },
            FontSize = Look.Pt(13), VerticalContentAlignment = VerticalAlignment.Center, Padding = new Thickness(0),
        };
        box.TextChanged += (_, _) => { query = box.Text ?? ""; Rebuild(); };
        var search = new Border
        {
            Child = Ui.H(8, Ui.Sym("magnifyingglass", 13, "Text2"), box.Grow()), Padding = new Thickness(12, 9),
            CornerRadius = new CornerRadius(12), Margin = new Thickness(20, 14, 20, 10), BorderThickness = new Thickness(0.5),
        };
        search.Res(Border.BackgroundProperty, "Glass").Res(Border.BorderBrushProperty, "GlassEdge");
        var scroll = new ScrollViewer { Content = list, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        var dock = new DockPanel();
        DockPanel.SetDock(search, Dock.Top);
        dock.Children.Add(search);
        dock.Children.Add(new Panel { Children = { scroll, empty } });
        Children.Add(PageBar.Page(bar, dock));
        var state = FavoriteState.Shared;
        void Changed(object? s, PropertyChangedEventArgs e) => Dispatcher.UIThread.Post(Rebuild);
        AttachedToVisualTree += (_, _) => { state.PropertyChanged += Changed; Rebuild(); _ = state.Refresh(); };
        DetachedFromVisualTree += (_, _) => state.PropertyChanged -= Changed;
        Rebuild();
    }

    void Rebuild()
    {
        var all = FavoriteState.Shared.Items.OrderByDescending(i => i.At).ToList();
        var words = query.ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var shown = words.Length == 0 ? all : all.Where(i =>
        {
            var haystack = string.Join("\n", i.Text ?? "", i.Title, i.Speaker ?? "", i.Machine ?? "").ToLowerInvariant();
            return words.All(haystack.Contains);
        }).ToList();
        list.Children.Clear();
        foreach (var item in shown) list.Children.Add(Row(item));
        empty.Content = all.Count == 0
            ? EmptyHint.Make("star", L("暂无收藏"), L("在对话中右键点击一条消息，选择「加入收藏」即可收藏。收藏的内容保存在电脑上，手机和电脑都能查看。")).VAlign(VerticalAlignment.Center)
            : shown.Count == 0 ? EmptyHint.Make("magnifyingglass", L("无匹配的收藏"), L("换个关键词试试。")).VAlign(VerticalAlignment.Center) : null;
    }

    const int PreviewLength = 400;

    /// 一条收藏：图（一张大一点，几张排九宫格）、文字（长的先显示开头，「展开全文」看全部），底下谁说的 · 会话 · 时间 · 原消息
    static Control Row(FavoriteItem item)
    {
        var stack = new StackPanel { Spacing = 8 };
        if (item.Images.Count > 0) stack.Children.Add(Images(item));
        if (item.Text is { Length: > 0 } text)
        {
            var holder = new ContentControl();
            var expanded = false;
            void Draw() => holder.Content = new MarkdownView(text.Length > PreviewLength && !expanded ? text[..PreviewLength] + "…" : text);
            Draw();
            stack.Children.Add(holder);
            if (text.Length > PreviewLength)
            {
                var label = Ui.Text(L("展开全文"), 12, color: "Accent");
                stack.Children.Add(new Tap(label.Pad(2, 2), () => { expanded = !expanded; label.Text = expanded ? L("收起") : L("展开全文"); Draw(); }, 4)
                    .Keys("Transparent", "Fill05").HAlign(HorizontalAlignment.Left));
            }
        }
        var speaker = item.Mine ? AppModel.Shared.Me?.Name ?? L("我") : item.Speaker ?? Agents.Info(item.Agent ?? Agents.DefaultId).Speaker;
        var line = string.Join(" · ", new[] { speaker, item.Title, item.Ts is double ts ? Format.ListTime(ts) : "" }.Where(s => s.Length > 0));
        var jump = new Tap(Ui.H(3, Ui.Text(L("原消息"), 12, color: "Text2"), Ui.Sym("chevron.right", 10, "Text2")).Pad(4, 2),
            () => TodoState.OpenSource(item.Key, item.ItemId), 4).Keys("Transparent", "Fill05").Tip(L("跳转到原消息"));
        stack.Children.Add(Ui.H(6, Ui.Sym("star.fill", 11, "Accent"), Ui.Text(line, 12, color: "Text2").Trim().Shrink(), new Spacer(8), jump));
        var card = Card.Make(stack, 14, 12);
        card.Menu(() => Menu(item));
        return card;
    }

    static IEnumerable<Control> Menu(FavoriteItem item)
    {
        yield return Ui.Item(L("跳转到原消息"), () => TodoState.OpenSource(item.Key, item.ItemId));
        if (item.Text is { Length: > 0 } text)
            yield return Ui.Item(L("复制"), () => { _ = MainWindow.Current?.Clipboard?.SetTextAsync(text); AppModel.Shared.Flash(L("已复制")); });
        yield return Ui.Divider();
        yield return Ui.Item(L("取消收藏"), () => FavoriteState.Shared.Delete(item.Id));
    }

    /// 一张：160 的正方形；几张：九宫格。点开看大图（能缩放、左右翻）
    static Control Images(FavoriteItem item)
    {
        if (item.Images.Count == 1) return Thumb(item, 0, 160).HAlign(HorizontalAlignment.Left);
        var grid = new Avalonia.Controls.Primitives.UniformGrid { Columns = 3, MaxWidth = 320, HorizontalAlignment = HorizontalAlignment.Left };
        for (var i = 0; i < item.Images.Count; i++) grid.Children.Add(Thumb(item, i, double.NaN).Margin(0, 0, 4, 4));
        return grid;
    }

    static Control Thumb(FavoriteItem item, int index, double size)
    {
        var image = new Image { Stretch = Stretch.UniformToFill };
        var box = new Border { CornerRadius = new CornerRadius(8), ClipToBounds = true, Child = image }.Res(Border.BackgroundProperty, "Fill06");
        if (!double.IsNaN(size)) { box.Width = size; box.Height = size; }
        else box.SizeChanged += (_, e) => { if (Math.Abs(box.Height - e.NewSize.Width) > 0.5) box.Height = e.NewSize.Width; };
        var query = FavoriteItem.MediaQuery(item.Images[index].Ref);
        query["thumb"] = "320";
        ImageCache.Load(FavoriteItem.MediaPath, query, b => image.Source = b);
        box.Cursor = new Cursor(StandardCursorType.Hand);
        box.PointerReleased += (_, e) =>
        {
            if (e.InitialPressMouseButton != MouseButton.Left) return;
            ImageViewer.Show("favorites", item.Images, index, FavoriteItem.MediaPath);
            e.Handled = true;
        };
        return box;
    }
}
