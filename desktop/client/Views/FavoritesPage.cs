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
        AttachedToVisualTree += (_, _) => { state.PropertyChanged += Changed; Rebuild(); Fetch(); };
        DetachedFromVisualTree += (_, _) => state.PropertyChanged -= Changed;
        Rebuild();
    }

    /// 这次打开从电脑读过一回（之前空着是「正在读取」，画骨架，不说「暂无」）
    bool fetched;

    async void Fetch()
    {
        try { await FavoriteState.Shared.Refresh(); } catch { /* 读不到也收起骨架，显示空状态 */ }
        // 骨架换成内容时列表淡入
        if (empty.Content is StackPanel { Children: [_, SkeletonView] }) list.FadeIn();
        fetched = true;
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
        empty.Content = all.Count == 0 && !fetched
            ? Skeleton.Page(SkeletonKind.Favorites, count: 4).Margin(20, 0, 20, 0).VAlign(VerticalAlignment.Top)
            : all.Count == 0
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
        // 编辑：收藏下来的内容有错、想补一句时改（11-20 用户；原来只能取消收藏重来）
        var edit = FavoriteState.CanEdit
            ? new Tap(Ui.Sym("pencil", 11.5, "Text2"), () => FavoriteEditor.Open(item), 4) { Width = 24, Height = 22 }.Keys("Transparent", "Fill05").Tip(L("编辑"))
            : null;
        stack.Children.Add(Ui.H(6, Ui.Sym("star.fill", 11, "Accent"), Ui.Text(line, 12, color: "Text2").Trim().Shrink(), new Spacer(8), edit, jump));
        var card = Card.Make(stack, 14, 12);
        card.Menu(() => Menu(item));
        return card;
    }

    static IEnumerable<Control> Menu(FavoriteItem item)
    {
        yield return Ui.Item(L("跳转到原消息"), () => TodoState.OpenSource(item.Key, item.ItemId));
        if (FavoriteState.CanEdit) yield return Ui.Item(L("编辑"), () => FavoriteEditor.Open(item));
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

/// 改一条收藏的文字（同 Mac 版 FavoriteEditor，11-20）：只改收藏里存的这一份，原对话不动，图不动。
/// 一个大文字框，回车换行，Ctrl+Enter 保存，Esc 取消（改过了先问一句）
public sealed class FavoriteEditor
{
    readonly FavoriteItem item;
    readonly Window window;
    readonly TextBox input;
    readonly Tap confirm;

    public static void Open(FavoriteItem item) => new FavoriteEditor(item);

    string Trimmed => (input.Text ?? "").Trim();
    bool Dirty => Trimmed != (item.Text ?? "").Trim();
    /// 没有图的收藏不能改成空的（那就是取消收藏了）
    bool CanSave => Dirty && (Trimmed.Length > 0 || item.Images.Count > 0);

    FavoriteEditor(FavoriteItem item)
    {
        this.item = item;
        var source = L("出自「%@」", item.Title) + (item.Ts is double ts ? " · " + Format.ListTime(ts) : "");
        var header = new StackPanel { Spacing = 5, Margin = new Thickness(0, 0, 0, 14) };
        header.Children.Add(Ui.Text(L("编辑收藏"), 16, FontWeight.SemiBold));
        header.Children.Add(Ui.H(5, Ui.Sym("text.bubble", 11, "Text2"), Ui.Text(source, 12, color: "Text2").Trim().Shrink()));

        input = new TextBox
        {
            Text = item.Text ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 200, MaxHeight = 460, FontSize = Look.Pt(14),
            Watermark = L("收藏的内容"), Padding = new Thickness(10, 8), Background = Brushes.Transparent, BorderThickness = new Thickness(0),
        };
        input.Classes.Add("plain");
        input.AddHandler(InputElement.KeyDownEvent, (_, e) =>
        {
            if (e.Key == Key.Enter && e.KeyModifiers.HasFlag(KeyModifiers.Control)) { e.Handled = true; Save(); }
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        var field = new Border { CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(0.5), Child = input }
            .Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");
        var note = Ui.Text(L("只修改收藏中保存的这一份，原对话不受影响；图片保持不变。"), 11.5, color: "Text3").Wrap().Margin(0, 8, 0, 0);
        var top = new StackPanel { Children = { header, field, note } }.Pad(20, 18, 20, 16);

        confirm = new Tap(Ui.Text(L("保存"), 13, FontWeight.SemiBold, "White").HAlign(HorizontalAlignment.Center).Pad(18, 0), Save, 7) { Height = 30, MinWidth = 72 }
            .Keys("Accent", "Accent");
        var cancel = new Tap(Ui.Text(L("取消"), 13).HAlign(HorizontalAlignment.Center).Pad(18, 0), Cancel, 7) { Height = 30, MinWidth = 72, BorderThickness = new Thickness(0.5) }
            .Keys("Fill10", "Fill15").Res(Border.BorderBrushProperty, "Fill12");
        var footer = Ui.H(10, Ui.Text(L("Ctrl+Enter %@", L("保存")), 11.5, color: "Text3"), new Spacer(), cancel, confirm).Pad(20, 14);
        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        var rule = Ui.Rule("Separator", 0.5);
        DockPanel.SetDock(rule, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(rule);
        root.Children.Add(top);

        window = Dialog.Make(root, 600, L("编辑收藏"));
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) Cancel(); };
        window.Opened += (_, _) => { input.Focus(); input.CaretIndex = input.Text?.Length ?? 0; };
        input.TextChanged += (_, _) => UpdateConfirm();
        UpdateConfirm();
        Dialog.Show(window);
    }

    void UpdateConfirm()
    {
        confirm.Opacity = CanSave ? 1 : 0.45;
        confirm.IsHitTestVisible = CanSave;
    }

    async void Cancel()
    {
        if (Dirty && !await Dialogs.Confirm(L("放弃所做的修改？"), L("放弃修改"), destructive: true)) return;
        window.Close();
    }

    void Save()
    {
        if (!CanSave) return;
        FavoriteState.Shared.Update(item.Id, Trimmed);
        window.Close();
    }
}
