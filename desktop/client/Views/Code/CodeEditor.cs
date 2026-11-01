using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using AvaloniaEdit;
using AvaloniaEdit.Document;
using AvaloniaEdit.Editing;
using AvaloniaEdit.Rendering;
using AvaloniaEdit.Search;
using AvaloniaEdit.TextMate;
using Kiteline.UI;
using TextMateSharp.Grammars;

namespace Kiteline.Views.Code;

/// 代码编辑器（同 Mac / iPhone 的 CodeMirror 编辑器）：AvaloniaEdit + VS Code 的 TextMate 语法和配色（深色 Dark+、浅色 Light+）。
/// 每个标签一份文档：切标签不丢撤销历史；行号右边的竖条标出和暂存区相比改了哪些行
public sealed class CodeEditor
{
    public TextEditor Editor { get; }
    readonly RegistryOptions registry;
    readonly TextMate.Installation textMate;
    readonly GitMargin gutter = new();
    readonly Dictionary<string, Doc> docs = [];
    string? active;
    bool dark;

    sealed class Doc(TextDocument document, string path)
    {
        public TextDocument Document { get; } = document;
        public string Path { get; set; } = path;
        public string? Scope;
        public string[]? Baseline;
        public bool ReadOnly;
        public string Language = "";
    }

    /// 标签改没改（id）、光标位置变了
    public event Action<string, bool>? DirtyChanged;
    public event Action? CursorChanged;
    /// Ctrl+S
    public Action<string>? Save { get; set; }

    public CodeEditor()
    {
        dark = Palette.IsDark;
        Editor = new TextEditor
        {
            ShowLineNumbers = true, FontFamily = Look.Mono, FontSize = 13, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        };
        Editor.Options.HighlightCurrentLine = true;
        Editor.WordWrap = Model.Prefs.Bool("codeWrap");
        // 代码和行号之间留点空（同 VS Code）
        Editor.TextArea.TextView.Margin = new Thickness(10, 0, 0, 0);
        Editor.Options.EnableHyperlinks = false;
        Editor.Options.EnableEmailHyperlinks = false;
        Editor.Options.ShowBoxForControlCharacters = true;
        Editor.TextArea.LeftMargins.Insert(Math.Min(1, Editor.TextArea.LeftMargins.Count), gutter);
        registry = new RegistryOptions(dark ? ThemeName.DarkPlus : ThemeName.LightPlus);
        textMate = Editor.InstallTextMate(registry);
        ApplyColors();
        Editor.TextArea.Caret.PositionChanged += (_, _) => CursorChanged?.Invoke();
        Editor.KeyDown += (_, e) =>
        {
            var command = OperatingSystem.IsMacOS() ? Avalonia.Input.KeyModifiers.Meta : Avalonia.Input.KeyModifiers.Control;
            if (e.Key == Avalonia.Input.Key.S && e.KeyModifiers == command && active is not null) { Save?.Invoke(active); e.Handled = true; }
        };
        Editor.ActualThemeVariantChanged += (_, _) => SetDark(Palette.IsDark);
    }

    public string? Active => active;
    public int Line => Editor.TextArea.Caret.Line;
    public int Column => Editor.TextArea.Caret.Column;
    public int Selected => Editor.SelectionLength;
    public string Language => active is not null && docs.TryGetValue(active, out var d) ? d.Language : "";
    public bool IsDirty(string id) => docs.TryGetValue(id, out var d) && !d.Document.UndoStack.IsOriginalFile;
    public bool Has(string id) => docs.ContainsKey(id);

    public void SetDark(bool value)
    {
        if (dark == value) return;
        dark = value;
        textMate.SetTheme(registry.LoadTheme(dark ? ThemeName.DarkPlus : ThemeName.LightPlus));
        ApplyColors();
    }

    void ApplyColors()
    {
        // VS Code 的 Dark Modern / Light Modern：编辑器底、字、行号、当前行
        Editor.Background = new SolidColorBrush(Color.Parse(dark ? "#1F1F1F" : "#FFFFFF"));
        Editor.Foreground = new SolidColorBrush(Color.Parse(dark ? "#CCCCCC" : "#3B3B3B"));
        Editor.LineNumbersForeground = new SolidColorBrush(Color.Parse("#6E7681"));
        Editor.TextArea.TextView.CurrentLineBackground = new SolidColorBrush(Color.Parse(dark ? "#0AFFFFFF" : "#08000000"));
        Editor.TextArea.TextView.CurrentLineBorder = new Pen(new SolidColorBrush(Color.Parse(dark ? "#282828" : "#EEEEEE")), 1);
        Editor.TextArea.SelectionBrush = new SolidColorBrush(Color.Parse(dark ? "#264F78" : "#ADD6FF"));
        Editor.TextArea.SelectionForeground = null;
        gutter.Dark = dark;
        gutter.InvalidateVisual();
    }

    /// 打开（或重新载入同 id 的）标签
    public void Open(string id, string path, string text, bool readOnly, string? baseline = null)
    {
        var document = new TextDocument(text);
        var doc = new Doc(document, path) { ReadOnly = readOnly };
        document.UndoStack.MarkAsOriginalFile();
        document.UndoStack.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(UndoStack.IsOriginalFile)) DirtyChanged?.Invoke(id, !document.UndoStack.IsOriginalFile);
        };
        document.TextChanged += (_, _) => { if (active == id) gutter.Schedule(); };
        var language = registry.GetLanguageByExtension("." + CodePaths.Ext(path)) ?? ByName(CodePaths.Name(path));
        doc.Scope = language is null ? null : registry.GetScopeByLanguageId(language.Id);
        doc.Language = language?.Aliases?.FirstOrDefault() ?? language?.Id ?? "Plain Text";
        if (baseline is not null) doc.Baseline = baseline.Replace("\r\n", "\n").Split('\n');
        docs[id] = doc;
        active = null;
        Show(id);
    }

    Language? ByName(string name) => name switch
    {
        "Dockerfile" or "Containerfile" => registry.GetLanguageByExtension(".dockerfile"),
        "Makefile" or "makefile" or "GNUmakefile" => registry.GetLanguageByExtension(".mk"),
        "Podfile" or "Gemfile" or "Rakefile" or "Fastfile" => registry.GetLanguageByExtension(".rb"),
        _ when name.StartsWith(".env") || name is ".gitignore" or ".editorconfig" => registry.GetLanguageByExtension(".ini"),
        _ => null,
    };

    public void Show(string id)
    {
        if (!docs.TryGetValue(id, out var doc) || active == id) return;
        active = id;
        Editor.Document = doc.Document;
        Editor.IsReadOnly = doc.ReadOnly;
        try { textMate.SetGrammar(doc.Scope!); } catch (Exception) { /* 认不出语言的按纯文本 */ }
        gutter.Baseline = doc.Baseline;
        gutter.Schedule(0);
        CursorChanged?.Invoke();
    }

    public void Close(string id)
    {
        docs.Remove(id);
        if (active == id) active = null;
    }

    public string? Text(string id) => docs.TryGetValue(id, out var d) ? d.Document.Text : null;

    public void MarkSaved(string id)
    {
        if (docs.TryGetValue(id, out var d)) d.Document.UndoStack.MarkAsOriginalFile();
    }

    /// 换成磁盘上的最新内容（放弃这边的修改）
    public void Replace(string id, string text)
    {
        if (!docs.TryGetValue(id, out var d)) return;
        d.Document.Text = text;
        d.Document.UndoStack.ClearAll();
        d.Document.UndoStack.MarkAsOriginalFile();
    }

    public void SetBaseline(string id, string? text)
    {
        if (!docs.TryGetValue(id, out var d)) return;
        d.Baseline = text?.Replace("\r\n", "\n").Split('\n');
        if (active == id) { gutter.Baseline = d.Baseline; gutter.Schedule(0); }
    }

    public void SetWrap(bool wrap) => Editor.WordWrap = wrap;
    public void SetFontSize(double size) => Editor.FontSize = size;
    public void Find() => Editor.SearchPanel.Open();

    public void GotoLine(int line)
    {
        var n = Math.Clamp(line, 1, Math.Max(1, Editor.Document.LineCount));
        var l = Editor.Document.GetLineByNumber(n);
        Editor.Select(l.Offset, l.Length);
        Editor.ScrollToLine(n);
        Editor.Focus();
    }

    /// 一段代码用同一套配色上色（对比页用）
    public RegistryOptions Registry => registry;
}

/// 行号右边的改动竖条（同 VS Code）：绿 = 新增、蓝 = 修改、红三角 = 这里删了几行。和暂存区里的版本比
public sealed class GitMargin : AbstractMargin
{
    public string[]? Baseline;
    public bool Dark = true;
    Dictionary<int, char> marks = [];
    DispatcherTimer? timer;

    protected override Size MeasureOverride(Size availableSize) => new(5, 0);

    protected override void OnTextViewChanged(TextView? oldTextView, TextView? newTextView)
    {
        if (oldTextView is not null) oldTextView.VisualLinesChanged -= Redraw;
        base.OnTextViewChanged(oldTextView, newTextView);
        if (newTextView is not null) newTextView.VisualLinesChanged += Redraw;
    }

    void Redraw(object? sender, EventArgs e) => InvalidateVisual();

    public void Schedule(int delay = 350)
    {
        timer?.Stop();
        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(Math.Max(1, delay)) };
        timer.Tick += (_, _) => { timer?.Stop(); Compute(); };
        timer.Start();
    }

    void Compute()
    {
        marks = Baseline is null || TextView?.Document is null ? [] : LineDiff.Marks(Baseline, TextView.Document.Text.Replace("\r\n", "\n").Split('\n'));
        InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        if (TextView is null || !TextView.VisualLinesValid || marks.Count == 0) return;
        var add = new SolidColorBrush(Color.Parse("#2EA043"));
        var mod = new SolidColorBrush(Color.Parse(Dark ? "#0078D4" : "#005FB8"));
        var del = new SolidColorBrush(Color.Parse("#F85149"));
        foreach (var line in TextView.VisualLines)
        {
            var number = line.FirstDocumentLine.LineNumber;
            if (!marks.TryGetValue(number, out var kind)) continue;
            var top = line.VisualTop - TextView.VerticalOffset;
            if (kind == 'd')
            {
                var geometry = new StreamGeometry();
                using (var g = geometry.Open())
                {
                    g.BeginFigure(new Point(0, top - 4), true);
                    g.LineTo(new Point(5, top));
                    g.LineTo(new Point(0, top + 4));
                    g.EndFigure(true);
                }
                context.DrawGeometry(del, null, geometry);
            }
            else context.FillRectangle(kind == 'a' ? add : mod, new Rect(1, top, 3, line.Height));
        }
    }
}

/// 行级对比：先去掉两头相同的行，中间用最长公共子序列对齐（够用、不依赖第三方）
public static class LineDiff
{
    /// 行号（从 1 起）→ 'a' 新增 / 'm' 修改 / 'd' 这一行上面删过
    public static Dictionary<int, char> Marks(string[] a, string[] b)
    {
        var marks = new Dictionary<int, char>();
        int start = 0, endA = a.Length, endB = b.Length;
        while (start < endA && start < endB && a[start] == b[start]) start++;
        while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) { endA--; endB--; }
        int n = endA - start, m = endB - start;
        if (n == 0 && m == 0) return marks;
        if ((long)n * m > 6_000_000) { for (var j = start; j < endB; j++) marks[j + 1] = 'm'; return marks; }
        var lcs = new int[n + 1, m + 1];
        for (var i = n - 1; i >= 0; i--)
            for (var j = m - 1; j >= 0; j--)
                lcs[i, j] = a[start + i] == b[start + j] ? lcs[i + 1, j + 1] + 1 : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);
        int x = 0, y = 0;
        while (x < n || y < m)
        {
            if (x < n && y < m && a[start + x] == b[start + y]) { x++; y++; continue; }
            // 一段对不上的：沿着公共子序列走，删的往下、加的往右
            int delStart = x, addStart = y;
            while (x < n || y < m)
            {
                if (x < n && y < m && a[start + x] == b[start + y]) break;
                if (y >= m || (x < n && lcs[x + 1, y] >= lcs[x, y + 1])) x++; else y++;
            }
            int deleted = x - delStart, added = y - addStart;
            if (added == 0) marks[Math.Min(start + addStart + 1, Math.Max(1, b.Length))] = 'd';
            else for (var k = 0; k < added; k++) marks[start + addStart + k + 1] = deleted > 0 ? 'm' : 'a';
        }
        return marks;
    }
}

/// 对比视图（同 VS Code 的 diff 编辑器）：上下合在一起（行内）或左右并排，增删的行铺底色，代码照样上色
public sealed class DiffView : Panel
{
    readonly CodeEditor colors;

    public DiffView(CodeEditor colors) => this.colors = colors;

    public void Show(DiffPayload payload, bool split, bool dark)
    {
        Children.Clear();
        var hunks = Parse(payload.Diff);
        var scope = colors.Registry.GetLanguageByExtension("." + CodePaths.Ext(payload.Path)) is { } lang ? colors.Registry.GetScopeByLanguageId(lang.Id) : null;
        if (!split)
        {
            var lines = new List<(string Text, char Kind, int? Old, int? New)>();
            foreach (var h in hunks)
            {
                lines.Add((h.Header, 'h', null, null));
                lines.AddRange(h.Lines);
            }
            Children.Add(Make(lines.Select(l => (l.Text, l.Kind)).ToList(), scope, dark, lines.Select(l => l.New ?? l.Old).ToList()));
            return;
        }
        var left = new List<(string, char)>();
        var right = new List<(string, char)>();
        var leftNo = new List<int?>();
        var rightNo = new List<int?>();
        foreach (var h in hunks)
        {
            left.Add((h.Header, 'h')); right.Add((h.Header, 'h')); leftNo.Add(null); rightNo.Add(null);
            var i = 0;
            while (i < h.Lines.Count)
            {
                if (h.Lines[i].Kind == ' ')
                {
                    left.Add((h.Lines[i].Text, ' ')); right.Add((h.Lines[i].Text, ' '));
                    leftNo.Add(h.Lines[i].Old); rightNo.Add(h.Lines[i].New);
                    i++;
                    continue;
                }
                var dels = new List<(string, int?)>();
                var adds = new List<(string, int?)>();
                while (i < h.Lines.Count && h.Lines[i].Kind == '-') { dels.Add((h.Lines[i].Text, h.Lines[i].Old)); i++; }
                while (i < h.Lines.Count && h.Lines[i].Kind == '+') { adds.Add((h.Lines[i].Text, h.Lines[i].New)); i++; }
                for (var k = 0; k < Math.Max(dels.Count, adds.Count); k++)
                {
                    if (k < dels.Count) { left.Add((dels[k].Item1, '-')); leftNo.Add(dels[k].Item2); } else { left.Add(("", 'f')); leftNo.Add(null); }
                    if (k < adds.Count) { right.Add((adds[k].Item1, '+')); rightNo.Add(adds[k].Item2); } else { right.Add(("", 'f')); rightNo.Add(null); }
                }
            }
        }
        var a = Make(left, scope, dark, leftNo);
        var b = Make(right, scope, dark, rightNo);
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,1,*") };
        Grid.SetColumn(b, 2);
        var rule = Ui.VRule("Separator");
        Grid.SetColumn(rule, 1);
        grid.Children.Add(a);
        grid.Children.Add(rule);
        grid.Children.Add(b);
        // 两边一起滚
        var syncing = false;
        void Sync(TextEditor from, TextEditor to)
        {
            from.TextArea.TextView.ScrollOffsetChanged += (_, _) =>
            {
                if (syncing) return;
                syncing = true;
                to.ScrollToVerticalOffset(from.TextArea.TextView.VerticalOffset);
                syncing = false;
            };
        }
        Sync(a, b);
        Sync(b, a);
        Children.Add(grid);
    }

    public sealed record Hunk(string Header, List<(string Text, char Kind, int? Old, int? New)> Lines);

    /// 统一格式的 diff → 区块（行的种类：' ' 未变、'+' 新增、'-' 删除，带新旧行号）
    public static List<Hunk> Parse(string diff)
    {
        var hunks = new List<Hunk>();
        Hunk? current = null;
        int oldNo = 0, newNo = 0;
        foreach (var raw in diff.Replace("\r\n", "\n").Split('\n'))
        {
            if (raw.StartsWith("@@"))
            {
                var m = System.Text.RegularExpressions.Regex.Match(raw, @"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@");
                oldNo = m.Success ? int.Parse(m.Groups[1].Value) : 0;
                newNo = m.Success ? int.Parse(m.Groups[2].Value) : 0;
                current = new Hunk(raw, []);
                hunks.Add(current);
                continue;
            }
            if (current is null || raw.StartsWith("\\")) continue;
            if (raw.StartsWith('+')) current.Lines.Add((raw[1..], '+', null, newNo++));
            else if (raw.StartsWith('-')) current.Lines.Add((raw[1..], '-', oldNo++, null));
            else if (raw.Length > 0 || current.Lines.Count > 0) current.Lines.Add((raw.Length > 0 ? raw[1..] : "", ' ', oldNo++, newNo++));
        }
        foreach (var h in hunks) while (h.Lines.Count > 0 && h.Lines[^1].Kind == ' ' && h.Lines[^1].Text.Length == 0 && h.Lines[^1].Old is null) h.Lines.RemoveAt(h.Lines.Count - 1);
        return hunks;
    }

    static TextEditor Make(List<(string Text, char Kind)> lines, string? scope, bool dark, List<int?> numbers)
    {
        var editor = new TextEditor
        {
            IsReadOnly = true, ShowLineNumbers = false, FontFamily = Look.Mono, FontSize = 12.5,
            Document = new TextDocument(string.Join("\n", lines.Select(l => l.Text))),
            Background = new SolidColorBrush(Color.Parse(dark ? "#1F1F1F" : "#FFFFFF")),
            Foreground = new SolidColorBrush(Color.Parse(dark ? "#CCCCCC" : "#3B3B3B")),
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        };
        editor.TextArea.LeftMargins.Add(new NumberMargin(numbers));
        editor.TextArea.TextView.BackgroundRenderers.Add(new LineShading(lines.Select(l => l.Kind).ToList(), dark));
        if (scope is not null)
        {
            var registry = new RegistryOptions(dark ? ThemeName.DarkPlus : ThemeName.LightPlus);
            editor.InstallTextMate(registry).SetGrammar(scope);
        }
        return editor;
    }

    /// 对比里的行号（新增的行写新文件的行号，删除的写旧文件的）
    sealed class NumberMargin(List<int?> numbers) : AbstractMargin
    {
        protected override Size MeasureOverride(Size availableSize) => new(44, 0);

        protected override void OnTextViewChanged(TextView? oldTextView, TextView? newTextView)
        {
            if (oldTextView is not null) oldTextView.VisualLinesChanged -= Redraw;
            base.OnTextViewChanged(oldTextView, newTextView);
            if (newTextView is not null) newTextView.VisualLinesChanged += Redraw;
        }

        void Redraw(object? sender, EventArgs e) => InvalidateVisual();

        public override void Render(DrawingContext context)
        {
            if (TextView is null || !TextView.VisualLinesValid) return;
            var brush = new SolidColorBrush(Color.Parse("#6E7681"));
            foreach (var line in TextView.VisualLines)
            {
                var index = line.FirstDocumentLine.LineNumber - 1;
                if (index >= numbers.Count || numbers[index] is not int n) continue;
                var text = new FormattedText(n.ToString(), System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                    new Typeface(Look.Mono), 11, brush);
                context.DrawText(text, new Point(36 - text.Width, line.VisualTop - TextView.VerticalOffset + (line.Height - text.Height) / 2));
            }
        }
    }

    /// 增删行的底色（同 VS Code：绿 / 红，区块头灰底）
    sealed class LineShading(List<char> kinds, bool dark) : IBackgroundRenderer
    {
        public KnownLayer Layer => KnownLayer.Background;

        public void Draw(TextView textView, DrawingContext context)
        {
            var added = new SolidColorBrush(Color.Parse(dark ? "#2E2EA043" : "#242EA043"));
            var removed = new SolidColorBrush(Color.Parse(dark ? "#2EF85149" : "#22F85149"));
            var header = new SolidColorBrush(Color.Parse(dark ? "#18FFFFFF" : "#0C000000"));
            var filler = new SolidColorBrush(Color.Parse(dark ? "#0AFFFFFF" : "#06000000"));
            foreach (var line in textView.VisualLines)
            {
                var index = line.FirstDocumentLine.LineNumber - 1;
                if (index >= kinds.Count) continue;
                IBrush? brush = kinds[index] switch { '+' => added, '-' => removed, 'h' => header, 'f' => filler, _ => null };
                if (brush is null) continue;
                context.FillRectangle(brush, new Rect(0, line.VisualTop - textView.VerticalOffset, textView.Bounds.Width + textView.HorizontalOffset, line.Height));
            }
        }
    }
}
