using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;

namespace Kiteline.Views;

/// 对话内容的排版（同 Mac 版 ChatType，照 VS Code 里的 Claude Code）：正文 13、行高 1.5；代码 0.9em 等宽；
/// 气泡上下 8、左右 12、圆角 10。跟着设置里的字号等比放大
public static class ChatType
{
    public static double Size => 13 * Look.TextScale;
    public static double Px(double value) => value * Size / 13;
    public static double LineHeight(double fontSize) => fontSize * 1.5;
    public static double CodeSize => Size * 0.9;
    public static double DetailSize => Size * 0.85;
    public static double PadV => Px(8);
    public static double PadH => Px(12);
    public static double Radius => Px(10);
}

/// 一段带格式的文字（粗体、斜体、删除线、行内代码、链接）：能用鼠标选字，点链接打开
public sealed class RichText : SelectableTextBlock
{
    readonly List<(int Start, int End, string Url)> links = [];
    Point? down;

    public Action<string>? OpenLink { get; set; }

    public RichText(IEnumerable<MdSpan> spans, double size, FontWeight weight = FontWeight.Normal, string color = "Text", bool mono = false)
    {
        FontSize = size;
        FontWeight = weight;
        LineHeight = ChatType.LineHeight(size);
        TextWrapping = TextWrapping.Wrap;
        if (mono) FontFamily = Look.Mono;
        this.Res(ForegroundProperty, color);
        this.Res(SelectionBrushProperty, "AccentFill20");
        Inlines = [];
        var offset = 0;
        foreach (var span in spans)
        {
            var run = new Run(span.Text);
            if (span.Bold) run.FontWeight = FontWeight.Bold;
            if (span.Italic) run.FontStyle = FontStyle.Italic;
            if (span.Strike) run.TextDecorations = Avalonia.Media.TextDecorations.Strikethrough;
            if (span.Code)
            {
                // 照 VS Code：0.9em 的编辑器字体，淡淡的底
                run.FontFamily = Look.Mono;
                run.FontSize = size * 0.9;
                run.Bind(Run.BackgroundProperty, run.GetResourceObservable("Fill08"));
            }
            if (span.Link is string url)
            {
                run.Bind(Run.ForegroundProperty, run.GetResourceObservable("Accent"));
                run.TextDecorations = Avalonia.Media.TextDecorations.Underline;
                links.Add((offset, offset + span.Text.Length, url));
            }
            Inlines.Add(run);
            offset += span.Text.Length;
        }
    }

    public RichText(string text, double size, FontWeight weight = FontWeight.Normal, string color = "Text") : this([new MdSpan(text)], size, weight, color) { }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        down = e.GetPosition(this);
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (links.Count == 0) return;
        var hit = LinkAt(e.GetPosition(this));
        Cursor = hit is null ? new Cursor(StandardCursorType.Ibeam) : new Cursor(StandardCursorType.Hand);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (down is not Point from) return;
        down = null;
        var at = e.GetPosition(this);
        if (Math.Abs(at.X - from.X) + Math.Abs(at.Y - from.Y) > 4) return;   // 是在选字
        if (LinkAt(at) is string url) { e.Handled = true; (OpenLink ?? Links.Open)(url); }
    }

    /// 点链接：跨段选字（SelectScope）接管了鼠标，点了没拖动时由它来开
    public void Open(string url) => (OpenLink ?? Links.Open)(url);

    public string? LinkAt(Point point)
    {
        if (links.Count == 0 || TextLayout is not { } layout) return null;
        var hit = layout.HitTestPoint(point);
        if (!hit.IsInside) return null;
        var index = hit.TextPosition;
        foreach (var (start, end, url) in links) if (index >= start && index < end) return url;
        return null;
    }
}

/// 链接：网址用浏览器开
public static class Links
{
    public static void Open(string url)
    {
        try
        {
            if (!url.Contains("://") || Markdown.BlockedLink(url)) return;   // claude.ai 的链接不打开（Markdown.Inline 里已经摘掉，这里兜底）
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception) { }
    }
}

/// 把 Claude 的 Markdown 画成原生排版（同 Mac 版 MarkdownView）。表格和代码都自动换行，不出现横向滚动
public sealed class MarkdownView : StackPanel
{
    /// fill = 撑满给的宽度；对话气泡里传 false：宽度贴着最长的一行（有代码块、分隔线、表格的照样撑满）
    public MarkdownView(string text, bool fill = true, Action<string>? openLink = null) : this(Markdown.Blocks(text), fill, openLink)
    {
        // 富文本段落的标点按整段内容排（见 Punctuation）
        Punctuation.Fit(this, text);
    }

    public MarkdownView(IReadOnlyList<MdBlock> blocks, bool fill = true, Action<string>? openLink = null)
    {
        Spacing = 0;
        var wide = fill || blocks.Any(b => b is MdCode or MdRule or MdTable);
        HorizontalAlignment = wide ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
        for (var i = 0; i < blocks.Count; i++)
        {
            var view = View(blocks[i], openLink);
            // 块与块之间的空照浏览器的外边距合并：取上一块的下边距和这一块的上边距里大的那个（第一块顶上不留）
            var top = i == 0 ? 0 : Math.Max(BlockSpacing(blocks[i - 1]).Bottom, BlockSpacing(blocks[i]).Top);
            view.Margin = new Thickness(view.Margin.Left, top, view.Margin.Right, 0);
            Children.Add(view);
        }
    }

    static double HeadingSize(int level) => ChatType.Size * new[] { 2, 1.5, 1.17, 1, 0.83, 0.67 }[Math.Clamp(level, 1, 6) - 1];

    static (double Top, double Bottom) BlockSpacing(MdBlock block)
    {
        var em = ChatType.Size;
        return block switch
        {
            MdParagraph => (0.1 * em, 0.7 * em),
            MdHeading h => (HeadingSize(h.Level) * new[] { 0.67, 0.83, 1, 1.33, 1.67, 2.33 }[Math.Clamp(h.Level, 1, 6) - 1],
                            HeadingSize(h.Level) * new[] { 0.67, 0.83, 1, 1.33, 1.67, 2.33 }[Math.Clamp(h.Level, 1, 6) - 1]),
            MdCode => (ChatType.Px(10), ChatType.Px(10)),
            MdQuote or MdList => (em, em),
            MdTable => (0.4 * em, 0.7 * em),
            MdRule => (0.5 * em, 0.5 * em),
            _ => (0, 0),
        };
    }

    static Control View(MdBlock block, Action<string>? openLink)
    {
        var em = ChatType.Size;
        switch (block)
        {
            case MdParagraph p:
                return new RichText(Markdown.Inline(p.Text), em) { OpenLink = openLink };
            case MdHeading h:
                return new RichText(Markdown.Inline(h.Text), HeadingSize(h.Level), FontWeight.Bold) { OpenLink = openLink };
            case MdCode c:
                var code = new SelectableTextBlock
                {
                    Text = c.Text, FontFamily = Look.Mono, FontSize = ChatType.CodeSize, LineHeight = ChatType.LineHeight(ChatType.CodeSize),
                    TextWrapping = TextWrapping.Wrap,
                };
                code.Res(TextBlock.ForegroundProperty, "Text").Res(SelectableTextBlock.SelectionBrushProperty, "AccentFill20");
                return CopyCorner.Wrap(Ui.Box(code, new Thickness(ChatType.Px(12), ChatType.Px(10)), "Code", ChatType.Px(6)).HAlign(HorizontalAlignment.Stretch), c.Text, ChatType.Px(5));
            case MdQuote q:
                // 浏览器默认的引用：左边缩进 40，不画竖线
                return new MarkdownView(q.Blocks, false, openLink) { Margin = new Thickness(40, 0, 0, 0) };
            case MdList l:
                // 缩进 2em：序号 / 圆点放在这 2em 里靠右，正文从 2em 处开始；项与项之间空 0.3em
                var list = new StackPanel { Spacing = 0.3 * em };
                foreach (var item in l.Items)
                {
                    // 序号也能选（跨段选字时连同序号一起拷，同 VS Code）
                    var marker = new SelectableTextBlock { Text = item.Marker, FontSize = em, LineHeight = ChatType.LineHeight(em), TextAlignment = TextAlignment.Right, Width = 2 * em - 6 }
                        .Res(TextBlock.ForegroundProperty, "Text2").Res(SelectableTextBlock.SelectionBrushProperty, "AccentFill20");
                    var text = new RichText(Markdown.Inline(item.Text), em) { OpenLink = openLink };
                    var row = new DockPanel { Margin = new Thickness(item.Indent * 2 * em, 0, 0, 0) };
                    marker.Margin = new Thickness(0, 0, 6, 0);
                    DockPanel.SetDock(marker, Dock.Left);
                    row.Children.Add(marker);
                    row.Children.Add(text);
                    list.Children.Add(row);
                }
                return list;
            case MdTable t:
                return Ui.Box(new TableView(t, openLink), new Thickness(ChatType.Px(8)), "CodeSoft", ChatType.Px(6));
            case MdRule:
                return Ui.Rule("Separator");
        }
        return new Panel();
    }
}

/// Markdown 表格（同 Mac 版 TableLayout）：列宽放得下就按内容宽；放不下时先把列距从 12 收到 5，还放不下，内容窄的列保持原宽，
/// 其余列平分剩下的宽度。表头加粗，下面一道线
public sealed class TableView : Panel
{
    readonly int columns;
    readonly int rows;
    readonly Control divider;
    double gap;
    double[] widths = [];
    double[] heights = [];
    double hSpacing => ChatType.Px(12);
    double minHSpacing => ChatType.Px(5);
    double vSpacing => ChatType.Px(6);

    public TableView(MdTable table, Action<string>? openLink)
    {
        columns = Math.Max(table.Header.Count, table.Rows.Select(r => r.Count).DefaultIfEmpty(0).Max());
        rows = table.Rows.Count + 1;
        for (var c = 0; c < columns; c++)
            Children.Add(new RichText(Markdown.Inline(c < table.Header.Count ? table.Header[c] : ""), ChatType.Size, FontWeight.Bold) { OpenLink = openLink });
        divider = Ui.Rule("Separator");
        Children.Add(divider);
        foreach (var row in table.Rows)
            for (var c = 0; c < columns; c++)
                Children.Add(new RichText(Markdown.Inline(c < row.Count ? row[c] : ""), ChatType.Size) { OpenLink = openLink });
        HorizontalAlignment = HorizontalAlignment.Left;
    }

    Control Cell(int r, int c) => Children[r == 0 ? c : columns + 1 + (r - 1) * columns + c];

    protected override Size MeasureOverride(Size available)
    {
        if (columns == 0) return default;
        widths = new double[columns];
        for (var r = 0; r < rows; r++)
            for (var c = 0; c < columns; c++)
            {
                Cell(r, c).Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                widths[c] = Math.Max(widths[c], Cell(r, c).DesiredSize.Width);
            }
        var width = available.Width;
        gap = hSpacing;
        if (!double.IsInfinity(width) && columns > 1 && widths.Sum() + gap * (columns - 1) > width + 0.5)
            gap = Math.Max(minHSpacing, Math.Min(hSpacing, (width - widths.Sum()) / (columns - 1)));
        var spacing = gap * (columns - 1);
        if (!double.IsInfinity(width) && widths.Sum() + spacing > width + 0.5)
        {
            var ideal = widths.ToArray();
            var open = Enumerable.Range(0, columns).ToHashSet();
            var remaining = Math.Max(0, width - spacing);
            while (open.Count > 0)
            {
                var share = remaining / open.Count;
                var narrow = open.Where(c => ideal[c] <= share).ToList();
                if (narrow.Count == 0) { foreach (var c in open) widths[c] = share; break; }
                foreach (var c in narrow) { remaining -= ideal[c]; open.Remove(c); }
            }
        }
        heights = new double[rows];
        for (var r = 0; r < rows; r++)
            for (var c = 0; c < columns; c++)
            {
                Cell(r, c).Measure(new Size(widths[c], double.PositiveInfinity));
                heights[r] = Math.Max(heights[r], Cell(r, c).DesiredSize.Height);
            }
        var tableWidth = widths.Sum() + spacing;
        divider.Measure(new Size(tableWidth, 1));
        return new Size(tableWidth, heights.Sum() + divider.DesiredSize.Height + vSpacing * rows);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double y = 0;
        for (var r = 0; r < rows; r++)
        {
            double x = 0;
            for (var c = 0; c < columns; c++)
            {
                var cell = Cell(r, c);
                // 格子靠左、在这一行里上下居中
                cell.Arrange(new Rect(x, y + (heights[r] - cell.DesiredSize.Height) / 2, widths[c], cell.DesiredSize.Height));
                x += widths[c] + gap;
            }
            y += heights[r] + vSpacing;
            if (r == 0)
            {
                divider.Arrange(new Rect(0, y, final.Width, divider.DesiredSize.Height));
                y += divider.DesiredSize.Height + vSpacing;
            }
        }
        return final;
    }
}
