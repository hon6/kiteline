using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;
using Kiteline.UI;

namespace Kiteline.Views;

/// 跨段选字（同 VS Code、同 Mac 版 RichText）：Avalonia 的 SelectableTextBlock 只能在自己那一段里选，一换行（换段、列表下一项）就断。
/// 挂在一个气泡上，接管鼠标拖动：从按下的那段到松开的那段，中间每段全选、两头按鼠标位置选；
/// 双击选词、三击选整段；Ctrl+C 复制选中的文字（段与段之间换行），右键菜单里也有「拷贝选中的文字」。
/// 点链接（按下松开没挪动）照样打开。代码块、表格里的字也一起算（它们也是 SelectableTextBlock）。
public sealed class SelectScope
{
    /// 最近一次在哪个气泡里选的：点到别的气泡时把这里的选中清掉（同网页，只留一块选区）
    static SelectScope? current;

    readonly Control host;
    SelectableTextBlock? anchor;
    int anchorIndex;
    Point downAt;
    bool dragging;

    SelectScope(Control host)
    {
        this.host = host;
        host.Focusable = true;
        host.AddHandler(InputElement.PointerPressedEvent, OnPressed, RoutingStrategies.Tunnel);
        host.AddHandler(InputElement.PointerMovedEvent, OnMoved, RoutingStrategies.Tunnel);
        host.AddHandler(InputElement.PointerReleasedEvent, OnReleased, RoutingStrategies.Tunnel);
        host.AddHandler(InputElement.KeyDownEvent, OnKey, RoutingStrategies.Tunnel);
    }

    public static SelectScope Attach(Control host) => new(host);

    /// 现在选中的文字（没选中是 null）
    public string? Selected
    {
        get
        {
            var parts = new List<string>();
            double? lastTop = null;
            foreach (var block in Blocks())
            {
                var start = Math.Min(block.SelectionStart, block.SelectionEnd);
                var end = Math.Max(block.SelectionStart, block.SelectionEnd);
                if (end <= start) continue;
                var text = TextOf(block);
                var piece = text.Substring(Math.Clamp(start, 0, text.Length), Math.Clamp(end, 0, text.Length) - Math.Clamp(start, 0, text.Length));
                var top = block.TranslatePoint(new Point(0, 0), host)?.Y ?? 0;
                // 列表的序号和那一项的字在同一行：接在一起（中间一个空格），别的段落之间换行
                if (parts.Count > 0) parts.Add(lastTop is double t && Math.Abs(t - top) < 1 ? " " : "\n");
                parts.Add(piece);
                lastTop = top;
            }
            var joined = string.Concat(parts);
            return joined.Length == 0 ? null : joined;
        }
    }

    public void Clear()
    {
        foreach (var block in Blocks()) { block.SelectionStart = 0; block.SelectionEnd = 0; }
    }

    List<SelectableTextBlock> Blocks() =>
        host.GetVisualDescendants().OfType<SelectableTextBlock>().Where(b => b.IsEffectivelyVisible).ToList();

    static string TextOf(SelectableTextBlock block)
    {
        if (block.Inlines is { Count: > 0 } inlines) return string.Concat(inlines.OfType<Run>().Select(r => r.Text ?? ""));
        return block.Text ?? "";
    }

    static int IndexAt(SelectableTextBlock block, Point point)
    {
        var length = TextOf(block).Length;
        if (point.Y < 0) return 0;
        if (point.Y > block.Bounds.Height) return length;
        if (block.TextLayout is not { } layout) return 0;
        var hit = layout.HitTestPoint(point);
        return Math.Clamp(hit.CharacterHit.FirstCharacterIndex + hit.CharacterHit.TrailingLength, 0, length);
    }

    /// 按下的地方在哪一段字里：只认真的点在字上（点到代码块右上角的复制钮、图片、文件卡片不算）
    static SelectableTextBlock? BlockOf(object? source)
    {
        for (var v = source as Visual; v is not null; v = v.GetVisualParent())
        {
            if (v is SelectableTextBlock block) return block;
            if (v is Tap or Button) return null;
        }
        return null;
    }

    /// 拖动时指针落在哪一段：在某段里就是它；在两段之间的空白里取上面那段的末尾
    (SelectableTextBlock Block, int Index)? Target(PointerEventArgs e, List<SelectableTextBlock> blocks)
    {
        SelectableTextBlock? above = null;
        foreach (var block in blocks)
        {
            var p = e.GetPosition(block);
            if (p.Y >= 0 && p.Y <= block.Bounds.Height && p.X >= -4 && p.X <= block.Bounds.Width + 4) return (block, IndexAt(block, p));
            if (p.Y >= 0) above = block;   // 这段在指针上面
        }
        // 都没碰到：按上下位置算（同一行左右两段时取上面那段末尾）
        foreach (var block in blocks)
        {
            var p = e.GetPosition(block);
            if (p.Y < block.Bounds.Height && p.Y >= 0) return (block, IndexAt(block, p));
        }
        if (above is not null) return (above, TextOf(above).Length);
        return blocks.Count > 0 ? (blocks[0], 0) : null;
    }

    void OnPressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(host).Properties.IsLeftButtonPressed) return;
        if (current is not null && current != this) current.Clear();
        current = this;
        var block = BlockOf(e.Source);
        if (block is null) { Clear(); return; }
        var index = IndexAt(block, e.GetPosition(block));
        Clear();
        if (e.ClickCount >= 3)
        {
            block.SelectionStart = 0;
            block.SelectionEnd = TextOf(block).Length;
        }
        else if (e.ClickCount == 2)
        {
            var text = TextOf(block);
            var (start, end) = Word(text, index);
            block.SelectionStart = start;
            block.SelectionEnd = end;
        }
        else
        {
            anchor = block;
            anchorIndex = index;
            downAt = e.GetPosition(host);
            dragging = false;
            block.SelectionStart = index;
            block.SelectionEnd = index;
            e.Pointer.Capture(host);
        }
        host.Focus();
        e.Handled = true;
    }

    /// 双击选词：字母数字（含汉字）连成一串的那一段；点在标点、空格上只选这一个字
    static (int, int) Word(string text, int index)
    {
        if (text.Length == 0) return (0, 0);
        index = Math.Clamp(index, 0, text.Length - 1);
        if (!char.IsLetterOrDigit(text[index])) return (index, index + 1);
        var start = index;
        var end = index;
        while (start > 0 && char.IsLetterOrDigit(text[start - 1])) start--;
        while (end < text.Length && char.IsLetterOrDigit(text[end])) end++;
        return (start, end);
    }

    void OnMoved(object? sender, PointerEventArgs e)
    {
        if (anchor is null || !e.GetCurrentPoint(host).Properties.IsLeftButtonPressed) return;
        var at = e.GetPosition(host);
        if (!dragging && Math.Abs(at.X - downAt.X) + Math.Abs(at.Y - downAt.Y) < 3) return;
        dragging = true;
        var blocks = Blocks();
        if (Target(e, blocks) is not { } target) return;
        var from = blocks.IndexOf(anchor);
        var to = blocks.IndexOf(target.Block);
        if (from < 0 || to < 0) return;
        for (var i = 0; i < blocks.Count; i++)
        {
            var block = blocks[i];
            var length = TextOf(block).Length;
            int start, end;
            if (i == from && i == to) { start = Math.Min(anchorIndex, target.Index); end = Math.Max(anchorIndex, target.Index); }
            else if (i == from) { (start, end) = from < to ? (anchorIndex, length) : (0, anchorIndex); }
            else if (i == to) { (start, end) = from < to ? (0, target.Index) : (target.Index, length); }
            else if (i > Math.Min(from, to) && i < Math.Max(from, to)) { start = 0; end = length; }
            else { start = 0; end = 0; }
            if (block.SelectionStart != start) block.SelectionStart = start;
            if (block.SelectionEnd != end) block.SelectionEnd = end;
        }
        e.Handled = true;
    }

    void OnReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (anchor is null) return;
        var block = anchor;
        anchor = null;
        e.Pointer.Capture(null);
        // 没拖动 = 点了一下：点在链接上就打开
        if (!dragging && block is RichText rich && rich.LinkAt(e.GetPosition(block)) is string url)
        {
            Clear();
            rich.Open(url);
        }
        e.Handled = true;
    }

    void OnKey(object? sender, KeyEventArgs e)
    {
        var command = e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.KeyModifiers.HasFlag(KeyModifiers.Meta);
        if (command && e.Key == Key.C && Selected is string text)
        {
            _ = MainWindow.Current?.Clipboard?.SetTextAsync(text);
            e.Handled = true;
        }
        else if (command && e.Key == Key.A)
        {
            foreach (var block in Blocks()) { block.SelectionStart = 0; block.SelectionEnd = TextOf(block).Length; }
            e.Handled = true;
        }
    }
}
