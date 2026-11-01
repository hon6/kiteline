using System.Globalization;
using System.Text;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Input.TextInput;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Threading;
using Kiteline.UI;
using XtermSharp;
using static Kiteline.Lang;

namespace Kiteline.Terminal;

/// 一个终端的画面：终端引擎是 XtermSharp（同 iPhone / Mac 用的 SwiftTerm 一家），画面、按键自己做。
/// 按键交给 TerminalStore 发到电脑，电脑上的输出经 TerminalStore 喂回来。
/// 键盘和中文输入法：画布自己拿焦点、当输入法的客户端（ImeClient：拼音组字画在光标处，候选窗贴着光标，上屏的字从 TextInput 进来）。
/// Windows 上组字、上屏、候选窗位置走 UI/WinIme（Avalonia 自己那套在换过输入控件后收不到字，见那里的说明），画布实现它的 ITarget
public sealed class TermView : Panel, ITermSink, ITerminalDelegate
{
    readonly string key, id;
    readonly XtermSharp.Terminal terminal;
    readonly Screen screen;
    double fontSize;
    bool redrawQueued;

    public TermView(string key, string id, double fontSize)
    {
        this.key = key;
        this.id = id;
        this.fontSize = fontSize;
        terminal = new XtermSharp.Terminal(this, new TerminalOptions { Cols = 80, Rows = 24, ConvertEol = false });
        screen = new Screen(this);
        Children.Add(screen);
        Focusable = false;
        ClipToBounds = true;
        Cursor = new Cursor(StandardCursorType.Ibeam);
        ActualThemeVariantChanged += (_, _) => screen.InvalidateVisual();
    }

    /// 拿键盘焦点。已经有焦点也先放掉再拿：输入法客户端只在焦点变化时挂上
    public void FocusInput() => screen.TakeFocus();

    public double FontSize
    {
        get => fontSize;
        set { if (Math.Abs(fontSize - value) > 0.01) { fontSize = value; screen.Metrics(); Fit(); screen.InvalidateVisual(); } }
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        TerminalStore.Shared.Attach(key, id, this);
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        TerminalStore.Shared.Detach(id, this);
    }

    protected override void OnSizeChanged(SizeChangedEventArgs e)
    {
        base.OnSizeChanged(e);
        Fit();
    }

    /// 按大小算行列数，变了就告诉引擎和电脑
    void Fit()
    {
        if (Bounds.Width < 1 || Bounds.Height < 1) return;
        var (cell, line) = screen.Cell;
        var cols = Math.Max(20, (int)((Bounds.Width - Screen.Pad) / cell));
        var rows = Math.Max(5, (int)(Bounds.Height / line));
        if (cols == terminal.Cols && rows == terminal.Rows) return;
        terminal.Resize(cols, rows);
        TerminalStore.Shared.Resize(key, id, cols, rows);
        Redraw();
    }

    /// 按面板大小估行列数（新开终端时用：一开始就是这个大小）
    public static (int Cols, int Rows) Grid(Size size, double fontSize)
    {
        var (cell, line) = Screen.Measure(fontSize);
        return (Math.Max(20, (int)((size.Width - Screen.Pad) / cell)), Math.Max(5, (int)(size.Height / line)));
    }

    // MARK: ITermSink

    public void Feed(byte[] bytes, int offset)
    {
        if (offset >= bytes.Length) return;
        var data = offset == 0 ? bytes : bytes[offset..];
        // 引擎碰到处理不了的序列抛异常：这一段跳过，别让整条输出卡住（接不上会一遍遍重放）
        try { terminal.Feed(data, data.Length); }
        catch (Exception e) { Console.Error.WriteLine($"[终端] 引擎处理输出出错：{e.Message}"); }
        Redraw();
    }

    /// 清屏重来：ESC c（终端的完全复位）
    public void Restart() => Feed([0x1B, 0x63], 0);

    void Redraw()
    {
        if (redrawQueued) return;
        redrawQueued = true;
        Dispatcher.UIThread.Post(() =>
        {
            redrawQueued = false;
            screen.InvalidateVisual();
            screen.CursorMoved();   // 输入法的候选窗跟着光标
        }, DispatcherPriority.Render);
    }

    // MARK: ITerminalDelegate（引擎要回给程序的话，比如光标位置查询的应答，也当按键发过去）

    void ITerminalDelegate.Send(byte[] data) => Send(data);
    void ITerminalDelegate.ShowCursor(XtermSharp.Terminal source) { }
    void ITerminalDelegate.SetTerminalTitle(XtermSharp.Terminal source, string title) { }
    void ITerminalDelegate.SetTerminalIconTitle(XtermSharp.Terminal source, string title) { }
    void ITerminalDelegate.SizeChanged(XtermSharp.Terminal source) { }
    string ITerminalDelegate.WindowCommand(XtermSharp.Terminal source, WindowManipulationCommand command, params int[] args) => null!;
    bool ITerminalDelegate.IsProcessTrusted() => true;

    void Send(byte[] bytes)
    {
        if (bytes.Length == 0) return;
        if (terminal.Buffer.YDisp != terminal.Buffer.YBase) terminal.ScrollLines(terminal.Buffer.YBase - terminal.Buffer.YDisp);   // 翻上去看的时候一打字回到底
        screen.ClearSelection();
        TerminalStore.Shared.Send(key, id, bytes);
    }

    void Send(string text) => Send(Encoding.UTF8.GetBytes(text));

    // MARK: 按键

    void OnKey(KeyEventArgs e)
    {
        // 输入法正在组字：按键（字母、空格选字、回车上屏、退格）都归输入法
        if (e.Key == Key.ImeProcessed || screen.Composing) return;
        var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        var shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        var alt = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        // 复制、粘贴：Ctrl+Shift+C / V；Ctrl+C 有选中时复制、没选中时是 ^C；Ctrl+V 粘贴（同 Windows Terminal）
        if (ctrl && (e.Key == Key.C && (shift || screen.HasSelection))) { _ = Copy(); e.Handled = true; return; }
        if (ctrl && e.Key == Key.V) { _ = Paste(); e.Handled = true; return; }
        if (ctrl && shift && e.Key is Key.OemPlus or Key.Add) return;   // 交给面板（放大字号）
        var app = terminal.ApplicationCursor;
        string? seq = e.Key switch
        {
            Key.Enter => "\r",
            Key.Back => alt ? "\x1b\x7f" : "\x7f",
            Key.Tab => shift ? "\x1b[Z" : "\t",
            Key.Escape => "\x1b",
            Key.Up => Arrow('A'), Key.Down => Arrow('B'), Key.Right => Arrow('C'), Key.Left => Arrow('D'),
            Key.Home => app ? "\x1bOH" : "\x1b[H", Key.End => app ? "\x1bOF" : "\x1b[F",
            Key.PageUp when shift => Scroll(-terminal.Rows), Key.PageDown when shift => Scroll(terminal.Rows),
            Key.PageUp => "\x1b[5~", Key.PageDown => "\x1b[6~",
            Key.Insert => "\x1b[2~", Key.Delete => "\x1b[3~",
            Key.F1 => "\x1bOP", Key.F2 => "\x1bOQ", Key.F3 => "\x1bOR", Key.F4 => "\x1bOS",
            Key.F5 => "\x1b[15~", Key.F6 => "\x1b[17~", Key.F7 => "\x1b[18~", Key.F8 => "\x1b[19~",
            Key.F9 => "\x1b[20~", Key.F10 => "\x1b[21~", Key.F11 => "\x1b[23~", Key.F12 => "\x1b[24~",
            _ => null,
        };
        if (seq is null && ctrl && !alt)
        {
            // Ctrl+字母 = 控制字符（^C ^D ^Z ^L ^R……）
            if (e.Key is >= Key.A and <= Key.Z) seq = ((char)(e.Key - Key.A + 1)).ToString();
            else if (e.Key == Key.Space || e.Key == Key.D2) seq = "\0";
            else if (e.Key == Key.OemOpenBrackets) seq = "\x1b";
            else if (e.Key == Key.OemPipe || e.Key == Key.OemBackslash) seq = "\x1c";
            else if (e.Key == Key.OemCloseBrackets) seq = "\x1d";
        }
        if (seq is null && alt && !ctrl && e.Key is >= Key.A and <= Key.Z)
        {
            // Alt+字母 = ESC + 字母（bash 里 Alt+B / Alt+F 按词移动）
            var c = (char)('a' + (e.Key - Key.A));
            seq = "\x1b" + (shift ? char.ToUpperInvariant(c) : c);
        }
        if (seq is null) return;
        e.Handled = true;
        if (seq.Length > 0) Send(seq);

        string Arrow(char c) => ctrl ? $"\x1b[1;5{c}" : shift ? $"\x1b[1;2{c}" : alt ? $"\x1b[1;3{c}" : app ? $"\x1bO{c}" : $"\x1b[{c}";
        string Scroll(int lines) { terminal.ScrollLines(lines); screen.InvalidateVisual(); return ""; }
    }

    async Task Copy()
    {
        var text = screen.SelectedText();
        if (string.IsNullOrEmpty(text) || TopLevel.GetTopLevel(this)?.Clipboard is not IClipboard clipboard) return;
        await clipboard.SetTextAsync(text);
        screen.ClearSelection();
    }

    async Task Paste()
    {
        if (TopLevel.GetTopLevel(this)?.Clipboard is not IClipboard clipboard) return;
        var text = await clipboard.GetTextAsync();
        if (string.IsNullOrEmpty(text)) return;
        text = text.Replace("\r\n", "\r").Replace("\n", "\r");
        // 程序开了「括号粘贴」（bash、zsh、vim 都会）：前后包上标记，多行粘进去不会一行一行地执行
        Send(terminal.BracketedPasteMode ? "\x1b[200~" + text + "\x1b[201~" : text);
    }

    public ContextMenu Menu() => new()
    {
        ItemsSource = new Control[]
        {
            Ui.Item(L("复制"), () => _ = Copy(), screen.HasSelection),
            Ui.Item(L("粘贴"), () => _ = Paste()),
            Ui.Item(L("全选"), screen.SelectAll),
            Ui.Item(L("清屏"), () => Send("\x0c")),
        },
    };

    /// 画终端：一行行按属性分段画字、底色、光标、选中
    sealed class Screen : Control, WinIme.ITarget
    {
        public const double Pad = 8;
        readonly TermView owner;
        Typeface typeface;
        (double Cell, double Line) cell;
        GlyphCache glyphs = new();
        (int Col, int Row)? anchor, focus;   // 选中：Row 是整条输出里的行号（含翻上去的）
        bool selecting;

        readonly ImeClient ime;
        /// 输入法正在组的字（拼音），画在光标处；上屏后清空
        string preedit = "";

        public Screen(TermView owner)
        {
            this.owner = owner;
            typeface = new Typeface(FontFamily.Parse(MonoFonts));
            Metrics();
            Focusable = true;
            FocusAdorner = null;
            ime = new ImeClient(this);
            InputMethod.SetIsInputMethodEnabled(this, true);
            TextInputMethodClientRequested += (_, e) => e.Client = ime;
            ContextRequested += (_, e) => { owner.Menu().Open(this); e.Handled = true; };
            GotFocus += (_, _) => InvalidateVisual();
            LostFocus += (_, _) => { preedit = ""; InvalidateVisual(); };
        }

        public bool Composing => preedit.Length > 0;

        public void TakeFocus()
        {
            if (TopLevel.GetTopLevel(this) is not TopLevel top) return;
            if (IsFocused) top.FocusManager?.ClearFocus();
            Focus();
        }

        public void CursorMoved() => ime.Moved();

        public void SetPreedit(string? text)
        {
            text ??= "";
            if (text == preedit) return;
            preedit = text;
            InvalidateVisual();
        }

        Rect WinIme.ITarget.CaretRect => CursorRect;
        Visual WinIme.ITarget.Visual => this;
        void WinIme.ITarget.Preedit(string text) => SetPreedit(text);

        /// 上屏的字（Windows 上由 WinIme 直接给）
        public void Commit(string text)
        {
            preedit = "";
            InvalidateVisual();
            if (!string.IsNullOrEmpty(text)) owner.Send(text);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            owner.OnKey(e);
            if (!e.Handled) base.OnKeyDown(e);
        }

        /// 打的字、输入法上屏的字（回车、退格、Ctrl 组合这些控制字符走 OnKeyDown，这里滤掉，免得发两遍）
        protected override void OnTextInput(TextInputEventArgs e)
        {
            base.OnTextInput(e);
            var text = e.Text;
            preedit = "";
            if (string.IsNullOrEmpty(text) || text.All(c => c < 0x20 || c == 0x7f)) return;
            owner.Send(text);
            e.Handled = true;
        }

        /// 光标那一格（输入法候选窗贴着它出）
        public Rect CursorRect
        {
            get
            {
                var buffer = owner.terminal.Buffer;
                return new Rect(Pad + buffer.X * cell.Cell, (buffer.Y + buffer.YBase - buffer.YDisp) * cell.Line, cell.Cell, cell.Line);
            }
        }

        public static string MonoFonts => OperatingSystem.IsWindows()
            ? "Cascadia Mono, Consolas, Microsoft YaHei UI, monospace"
            : "DejaVu Sans Mono, Noto Sans Mono, Liberation Mono, Noto Sans Mono CJK SC, monospace";

        public (double Cell, double Line) Cell => cell;

        public void Metrics()
        {
            cell = Measure(owner.fontSize);
            glyphs = new GlyphCache();
        }

        public static (double Cell, double Line) Measure(double size)
        {
            var face = new Typeface(FontFamily.Parse(MonoFonts));
            var text = new FormattedText("W", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, face, size, Brushes.Black);
            return (Math.Max(1, text.WidthIncludingTrailingWhitespace), Math.Max(1, Math.Ceiling(text.Height)));
        }

        public override void Render(DrawingContext context)
        {
            var dark = Palette.IsDark;
            var colors = TermColors.For(dark);
            context.FillRectangle(colors.Background, new Rect(Bounds.Size));
            var term = owner.terminal;
            var buffer = term.Buffer;
            var (cw, lh) = cell;
            var (selStart, selEnd) = Ordered();
            for (var row = 0; row < term.Rows; row++)
            {
                var abs = buffer.YDisp + row;
                if (abs >= buffer.Lines.Length) break;
                var line = buffer.Lines[abs];
                var y = row * lh;
                var col = 0;
                while (col < Math.Min(line.Length, term.Cols))
                {
                    var data = line[col];
                    var width = Math.Max(1, data.Width);
                    var (fg, bg) = colors.Resolve(data.Attribute);
                    var selected = selStart is not null && InSelection(col, abs, selStart.Value, selEnd!.Value);
                    if (selected) bg = colors.Selection;
                    var x = Pad + col * cw;
                    if (bg is not null) context.FillRectangle(bg, new Rect(x, y, cw * width, lh));
                    var code = data.Code;
                    var flags = (FLAGS)(data.Attribute >> 18);
                    if (code > 32 && !flags.HasFlag(FLAGS.INVISIBLE))
                    {
                        var text = glyphs.Get(char.ConvertFromUtf32(code), typeface, owner.fontSize, flags, fg);
                        // 宽字符（中文）占两格：画在两格正中
                        var dx = width == 2 ? Math.Max(0, (cw * 2 - text.WidthIncludingTrailingWhitespace) / 2) : 0;
                        context.DrawText(text, new Point(x + dx, y + (lh - text.Height) / 2));
                    }
                    if (flags.HasFlag(FLAGS.UNDERLINE)) context.FillRectangle(fg, new Rect(x, y + lh - 1.5, cw * width, 1));
                    if (flags.HasFlag(FLAGS.CrossedOut)) context.FillRectangle(fg, new Rect(x, y + lh / 2, cw * width, 1));
                    col += width;
                }
            }
            // 光标：在最底下（没翻上去看）、程序没藏光标时画；有焦点实心，没焦点空心
            if (buffer.YDisp == buffer.YBase && !term.CursorHidden)
            {
                var rect = new Rect(Pad + buffer.X * cw, buffer.Y * lh, cw, lh);
                if (IsFocused)
                {
                    context.FillRectangle(colors.Cursor, rect);
                    var under = buffer.Lines[buffer.YBase + buffer.Y];
                    if (buffer.X < under.Length && under[buffer.X].Code > 32)
                        context.DrawText(glyphs.Get(char.ConvertFromUtf32(under[buffer.X].Code), typeface, owner.fontSize, 0, colors.Background), new Point(rect.X, rect.Y));
                }
                else context.DrawRectangle(new Pen(colors.Cursor, 1), rect.Deflate(0.5));
            }
            // 输入法正在组的字：盖在光标处、带下划线（同系统输入框里的样子）
            if (preedit.Length > 0)
            {
                var at = CursorRect;
                var text = new FormattedText(preedit, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, typeface, owner.fontSize, colors.Foreground);
                var box = new Rect(at.X, at.Y, Math.Max(text.WidthIncludingTrailingWhitespace, cw), lh);
                context.FillRectangle(colors.Background, box.Inflate(new Thickness(0, 0, 2, 0)));
                context.DrawText(text, new Point(at.X, at.Y + (lh - text.Height) / 2));
                context.FillRectangle(colors.Foreground, new Rect(at.X, at.Y + lh - 1.5, box.Width, 1));
            }
        }

        // MARK: 鼠标：点一下拿到焦点，拖动选中，滚轮翻看

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            base.OnPointerPressed(e);
            TakeFocus();
            var point = e.GetCurrentPoint(this);
            if (!point.Properties.IsLeftButtonPressed) return;
            if (e.ClickCount == 2) { SelectWord(At(point.Position)); e.Handled = true; return; }
            anchor = focus = At(point.Position);
            selecting = true;
            e.Pointer.Capture(this);
            InvalidateVisual();
            e.Handled = true;
        }

        protected override void OnPointerMoved(PointerEventArgs e)
        {
            base.OnPointerMoved(e);
            if (!selecting) return;
            focus = At(e.GetPosition(this));
            InvalidateVisual();
        }

        protected override void OnPointerReleased(PointerReleasedEventArgs e)
        {
            base.OnPointerReleased(e);
            if (!selecting) return;
            selecting = false;
            e.Pointer.Capture(null);
            if (anchor == focus) { anchor = focus = null; InvalidateVisual(); }
        }

        protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
        {
            base.OnPointerWheelChanged(e);
            owner.terminal.ScrollLines((int)Math.Round(-e.Delta.Y * 3));
            InvalidateVisual();
            e.Handled = true;
        }

        (int Col, int Row) At(Point p)
        {
            var buffer = owner.terminal.Buffer;
            var col = Math.Clamp((int)((p.X - Pad) / cell.Cell), 0, owner.terminal.Cols - 1);
            var row = Math.Clamp((int)(p.Y / cell.Line), 0, owner.terminal.Rows - 1);
            return (col, buffer.YDisp + row);
        }

        public bool HasSelection => anchor is not null && focus is not null && anchor != focus;

        public void ClearSelection()
        {
            if (anchor is null) return;
            anchor = focus = null;
            InvalidateVisual();
        }

        public void SelectAll()
        {
            var buffer = owner.terminal.Buffer;
            anchor = (0, 0);
            focus = (owner.terminal.Cols - 1, buffer.YBase + owner.terminal.Rows - 1);
            InvalidateVisual();
        }

        void SelectWord((int Col, int Row) at)
        {
            var line = owner.terminal.Buffer.Lines[at.Row];
            bool Word(int c) => c >= 0 && c < line.Length && line[c].Code > 32 && !" \"'`()[]{}<>|;".Contains((char)line[c].Code);
            if (!Word(at.Col)) return;
            var start = at.Col;
            var end = at.Col;
            while (Word(start - 1)) start--;
            while (Word(end + 1)) end++;
            anchor = (start, at.Row);
            focus = (end, at.Row);
            InvalidateVisual();
        }

        ((int Col, int Row)? Start, (int Col, int Row)? End) Ordered()
        {
            if (!HasSelection) return (null, null);
            var (a, b) = (anchor!.Value, focus!.Value);
            return a.Row < b.Row || (a.Row == b.Row && a.Col <= b.Col) ? (a, b) : (b, a);
        }

        static bool InSelection(int col, int row, (int Col, int Row) start, (int Col, int Row) end) =>
            (row > start.Row || (row == start.Row && col >= start.Col)) && (row < end.Row || (row == end.Row && col <= end.Col));

        public string SelectedText()
        {
            var (start, end) = Ordered();
            if (start is null || end is null) return "";
            var buffer = owner.terminal.Buffer;
            var builder = new StringBuilder();
            for (var row = start.Value.Row; row <= end.Value.Row && row < buffer.Lines.Length; row++)
            {
                var line = buffer.Lines[row];
                var from = row == start.Value.Row ? start.Value.Col : 0;
                var to = row == end.Value.Row ? end.Value.Col + 1 : line.Length;
                builder.Append(line.TranslateToString(true, from, Math.Min(to, line.Length)).ToString());
                // 自动折行的不加换行（复制一条长命令还是一行）
                if (row < end.Value.Row && !(row + 1 < buffer.Lines.Length && buffer.Lines[row + 1].IsWrapped)) builder.Append('\n');
            }
            return builder.ToString();
        }
    }

    /// 输入法客户端：告诉系统光标在哪（候选窗贴着出）、组字时的拼音交给画布画；上屏的字系统会作为 TextInput 发给画布
    sealed class ImeClient(Screen screen) : TextInputMethodClient
    {
        public override Visual TextViewVisual => screen;
        public override bool SupportsPreedit => true;
        public override bool SupportsSurroundingText => false;
        public override string SurroundingText => "";
        public override Rect CursorRectangle => screen.CursorRect;
        public override TextSelection Selection { get => default; set { } }
        public override void SetPreeditText(string? preeditText) => screen.SetPreedit(preeditText);
        public void Moved() => RaiseCursorRectangleChanged();
    }

    /// 画字用的 FormattedText 按（字、样式、颜色）缓存：一屏几千个格子，每次重画都新建太慢
    sealed class GlyphCache
    {
        readonly Dictionary<(string, int, IBrush), FormattedText> cache = new();

        public FormattedText Get(string text, Typeface typeface, double size, FLAGS flags, IBrush brush)
        {
            var style = (int)(flags & (FLAGS.BOLD | FLAGS.ITALIC));
            if (cache.TryGetValue((text, style, brush), out var hit)) return hit;
            if (cache.Count > 4000) cache.Clear();
            var face = new Typeface(typeface.FontFamily, flags.HasFlag(FLAGS.ITALIC) ? FontStyle.Italic : FontStyle.Normal,
                                    flags.HasFlag(FLAGS.BOLD) ? FontWeight.Bold : FontWeight.Normal);
            return cache[(text, style, brush)] = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, face, size, brush);
        }
    }
}

/// 终端的配色：同 VS Code 默认主题（Dark Modern / Light Modern）的终端，和 iPhone / Mac 一样
sealed class TermColors
{
    static TermColors? dark, light;
    public static TermColors For(bool isDark) => isDark ? dark ??= new TermColors(true) : light ??= new TermColors(false);

    public readonly IBrush Background, Foreground, Cursor, Selection;
    readonly IBrush[] palette = new IBrush[256];

    TermColors(bool isDark)
    {
        uint[] ansi = isDark
            ? [0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
               0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5]
            : [0x000000, 0xCD3131, 0x00BC00, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555,
               0x666666, 0xCD3131, 0x14CE14, 0xB5BA00, 0x0451A5, 0xBC05BC, 0x0598BC, 0xA5A5A5];
        for (var i = 0; i < 16; i++) palette[i] = Palette.Brush(ansi[i]);
        // 16～231：6×6×6 色立方；232～255：灰阶（同 xterm）
        int[] steps = [0, 95, 135, 175, 215, 255];
        for (var i = 16; i < 232; i++)
        {
            var n = i - 16;
            palette[i] = Palette.Brush((uint)(steps[n / 36] << 16 | steps[n / 6 % 6] << 8 | steps[n % 6]));
        }
        for (var i = 232; i < 256; i++)
        {
            var v = (uint)(8 + (i - 232) * 10);
            palette[i] = Palette.Brush(v << 16 | v << 8 | v);
        }
        Background = Palette.Brush(isDark ? 0x181818u : 0xFFFFFFu);
        Foreground = Palette.Brush(isDark ? 0xCCCCCCu : 0x3B3B3Bu);
        Cursor = Palette.Brush(isDark ? 0xAEAFADu : 0x000000u);
        Selection = Palette.Brush(isDark ? 0x264F78u : 0xADD6FFu);
    }

    /// 格子属性 → (字色, 底色)；底色是默认的话为空（不画）
    public (IBrush Fg, IBrush? Bg) Resolve(int attribute)
    {
        var flags = (FLAGS)(attribute >> 18);
        var fgIndex = (attribute >> 9) & 0x1FF;
        var bgIndex = attribute & 0x1FF;
        if (flags.HasFlag(FLAGS.BOLD) && fgIndex < 8) fgIndex += 8;   // 粗体用亮色（同 xterm 的老习惯）
        var fg = fgIndex < 256 ? palette[fgIndex] : Foreground;
        IBrush? bg = bgIndex < 256 ? palette[bgIndex] : null;
        if (flags.HasFlag(FLAGS.INVERSE)) (fg, bg) = (bg ?? Background, fg);
        if (flags.HasFlag(FLAGS.DIM) && fg is ISolidColorBrush solid)
            fg = new ImmutableSolidColorBrush(solid.Color, 0.6);
        return (fg, bg);
    }
}
