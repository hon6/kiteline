using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 对话里弹出的面板（同 Mac 版从对话页弹出的 sheet）：左上角标题（往里点了有「‹」返回），中间内容，右下角「完成」。
/// 文件、改动、测试、Agent map 这几样能一层层点进去
public sealed class NavSheet
{
    readonly Window window;
    readonly ContentControl body = new();
    readonly Tap back;
    /// 返回键那一行（标题在弹窗统一的标题栏里，见 Dialog.TitleBar）：进到下一层才有
    readonly Control header;
    readonly List<(string Title, Func<NavSheet, Control> Build)> stack = [];

    public static NavSheet Open(string title, Func<NavSheet, Control> root, double width = 640, double height = 705)
    {
        var sheet = new NavSheet(width, height);
        sheet.Push(title, root);
        Dialog.Show(sheet.window);
        return sheet;
    }

    NavSheet(double width, double height)
    {
        back = new Tap(Ui.Sym("chevron.left", 13, "Accent").Pad(6, 3), Pop, 6).Keys("Transparent", "Fill08");
        back.Tip(L("返回"));
        header = Ui.H(4, back).Pad(10, 0, 14, 6);
        var done = Form.Button(L("完成"), Close);
        var footer = Ui.H(8, new Spacer(), done).Pad(16, 10, 16, 12);
        var rule = Ui.Rule("Separator", 0.5);
        var dock = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(footer, Dock.Bottom);
        DockPanel.SetDock(rule, Dock.Bottom);
        dock.Children.Add(header);
        dock.Children.Add(footer);
        dock.Children.Add(rule);
        dock.Children.Add(body);
        window = Dialog.Make(dock, width);
        window.SizeToContent = SizeToContent.Manual;
        window.Height = height;
        window.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { if (stack.Count > 1) Pop(); else Close(); e.Handled = true; }
        };
    }

    public void Push(string text, Func<NavSheet, Control> build)
    {
        stack.Add((text, build));
        Show();
    }

    public void Pop()
    {
        if (stack.Count <= 1) return;
        stack.RemoveAt(stack.Count - 1);
        Show();
    }

    /// 当前这一层重画一遍（刷新）
    public void Reload() => Show();

    public void Close() => window.Close();

    void Show()
    {
        var (text, build) = stack[^1];
        window.Title = text;   // 统一标题栏跟着窗口标题变
        back.IsVisible = header.IsVisible = stack.Count > 1;
        body.Content = build(this);
    }

    /// 先转圈，数据回来再画；出错显示原因和「重试」
    public static Control Load(Func<Task<Control>> make)
    {
        var host = new ContentControl();
        async void Run()
        {
            host.Content = new Spinner(18).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center);
            try { host.Content = await make(); }
            catch (Exception e)
            {
                host.Content = Ui.Stack(Orientation.Vertical, 10, Align.Center, [Ui.Text(e.Message, 13, color: "Text2", lines: 3).Wrap(), Form.Button(L("重试"), Run)])
                    .HAlign(HorizontalAlignment.Center).Margin(20, 60, 20, 0);
            }
        }
        Dispatcher.UIThread.Post(Run);
        return host;
    }

    public static ScrollViewer Scroll(Control content) =>
        new() { Content = content, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
}

/// 对话页「⋯」菜单、标签栏按钮里的面板
public static class ChatSheets
{
    static Net.Api Api => AppModel.Shared.Api;
    static Dictionary<string, string> Q(string key, params (string, string)[] more)
    {
        var query = new Dictionary<string, string> { ["key"] = key };
        foreach (var (k, v) in more) query[k] = v;
        return query;
    }

    // MARK: 共用小件

    /// 组头（同 Mac 分组列表的 section header）
    internal static TextBlock Header(string text) => Ui.Text(text, 12, FontWeight.SemiBold, "Text2").Margin(4, 14, 4, 6);

    /// 一组行：浅底圆角卡片、行间细线（同 Mac 的 SheetSection）
    internal static Control Group(IEnumerable<Control> rows, double inset = 0)
    {
        var stack = Lines(rows, inset);
        return new Border { CornerRadius = new CornerRadius(10), Child = stack, ClipToBounds = true }.Res(Border.BackgroundProperty, "Fill05");
    }

    /// 普通列表（同 Mac 的 List：没有卡片底，行间细线，最上面也一道）：文件、改动、测试这几页
    static Control Plain(IEnumerable<Control> rows, double inset = 0)
    {
        var stack = Lines(rows, inset);
        stack.Children.Insert(0, Ui.Rule("Separator", 0.5));
        return stack;
    }

    static StackPanel Lines(IEnumerable<Control> rows, double inset)
    {
        var stack = new StackPanel();
        var list = rows.ToList();
        for (var i = 0; i < list.Count; i++)
        {
            stack.Children.Add(list[i]);
            if (i < list.Count - 1) stack.Children.Add(Ui.Rule("Separator", 0.5).Margin(inset, 0, 0, 0));
        }
        return stack;
    }

    static Tap Row(Control content, Action? action) =>
        (Tap)new Tap(content.Pad(12, 8), action, 0) { Cursor = action is null ? Cursor.Default : new Cursor(StandardCursorType.Hand) }.Keys("Transparent", action is null ? "Transparent" : "Fill05");

    internal static Control Note(string text, string color = "Text2") => Ui.Text(text, 12.5, color: color, lines: 0).Wrap().Margin(4, 8, 4, 8);

    static Control Empty(string symbol, string title, string detail) => EmptyHint.Make(symbol, title, detail).Margin(0, 40, 0, 0);

    static string Relative(double? ms)
    {
        if (ms is not double t || t <= 0) return "";
        var span = DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeMilliseconds((long)t);
        if (span.TotalSeconds < 60) return L("刚刚");
        if (span.TotalMinutes < 60) return L("%@ 分钟前", (int)span.TotalMinutes);
        if (span.TotalHours < 24) return L("%@ 小时前", (int)span.TotalHours);
        return Format.Short(t);
    }

    static string Size(double bytes) => bytes switch
    {
        < 1024 => $"{bytes:0} B",
        < 1024 * 1024 => (bytes / 1024).ToString("0.#", CultureInfo.InvariantCulture) + " KB",
        _ => (bytes / 1048576).ToString("0.#", CultureInfo.InvariantCulture) + " MB",
    };

    static Control Chip(string title, string symbol, Action action) =>
        new Tap(Ui.H(5, Ui.Sym(symbol, 11, "Accent"), Ui.Text(title, 12, FontWeight.Medium, "Accent")).Pad(10, 4), action, 13) { Height = 26 }.Keys("AccentFill10", "AccentFill16");

    static Control Mark(string status)
    {
        var mark = status switch { "M" => L("改"), "A" => L("增"), "D" => L("删"), "R" => L("名"), "C" => L("复"), "U" => L("冲"), "??" or "?" => L("新"), _ => status };
        var (color, fill) = status == "D" ? ("Removed", "OrangeFill13") : status is "??" or "?" or "A" ? ("Added", "GreenFill13") : ("Orange", "OrangeFill13");
        return new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(5), Child = Ui.Text(mark, 10.5, FontWeight.Bold, color).HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center) }
            .Res(Border.BackgroundProperty, fill);
    }

    static TextBlock PathText(string path)
    {
        var name = System.IO.Path.GetFileName(path);
        var dir = path[..^name.Length];
        var block = new TextBlock { FontFamily = Look.Mono, FontSize = Look.Pt(12), TextTrimming = TextTrimming.PrefixCharacterEllipsis };
        block.Inlines = [];
        var d = new Run(dir);
        d.Bind(Run.ForegroundProperty, block.GetResourceObservable("Text2"));
        var n = new Run(name);
        n.Bind(Run.ForegroundProperty, block.GetResourceObservable("Text"));
        block.Inlines.Add(d);
        block.Inlines.Add(n);
        return block;
    }

    // MARK: 项目文件（只读）

    /// 「文件」：代码 IDE（资源管理器 + 编辑器 + 源代码管理，见 Views/Code）
    public static void Files(string key, string path = "") => Code.CodeWindow.Open(key, "explorer");

    static Control FilesPage(NavSheet sheet, string key, string start)
    {
        var path = start;
        var search = new TextBox { Watermark = L("按文件名搜索（多个关键词以空格分隔）"), FontSize = Look.Pt(13), Padding = new Thickness(10, 5), Margin = new Thickness(14, 0, 14, 6) };
        search.Classes.Add("search");
        var content = new ContentControl();
        DispatcherTimer? debounce = null;
        void Browse() => content.Content = NavSheet.Load(async () =>
        {
            var list = await Api.Get("/api/files", Q(key, ("path", path)));
            var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
            // 当前路径当组头：根目录名 / 子目录 / …，点哪层回哪层
            var crumbs = Ui.H(4);
            void Crumb(string label, string target)
            {
                var on = target == path;
                crumbs.Children.Add(new Tap(Ui.Text(label, 12, on ? FontWeight.SemiBold : FontWeight.Normal, on ? "Text" : "Accent").Pad(2, 1), () => { path = target; Browse(); }, 4).Keys("Transparent", "Fill05"));
            }
            var root = System.IO.Path.GetFileName((list.Str("root") ?? "").TrimEnd('/', '\\'));
            Crumb(root.Length > 0 ? root : L("项目"), "");
            var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
            for (var i = 0; i < parts.Length; i++)
            {
                crumbs.Children.Add(Ui.Text("/", 12, color: "Text3"));
                Crumb(parts[i], string.Join("/", parts.Take(i + 1)));
            }
            stack.Children.Add(new ScrollViewer { Content = crumbs, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled }.Margin(2, 4, 2, 6));
            var entries = list.Arr("entries").Items().ToList();
            if (entries.Count == 0) stack.Children.Add(Note(L("空目录")));
            else stack.Children.Add(Plain(entries.Select(e =>
            {
                var name = e.Str("name") ?? "";
                var dir = e.Str("type") == "dir";
                var rel = path.Length == 0 ? name : $"{path}/{name}";
                var sub = (dir ? "" : Size(e.Num("size") ?? 0) + " · ") + Relative(e.Num("mtime"));
                var label = FileLabel(name + (e.Truthy("link") ? " ↪︎" : ""), sub, dir, e.Str("git"));
                label.Opacity = name.StartsWith('.') ? 0.55 : 1;
                return (Control)Row(label, () => { if (dir) { path = rel; Browse(); } else sheet.Push(name, s => FilePage(s, key, rel)); });
            }), 52));
            if (list.Truthy("truncated")) stack.Children.Add(Note(L("此目录文件过多，仅列出前 2000 个。")));
            return NavSheet.Scroll(stack);
        });
        void Find()
        {
            var q = (search.Text ?? "").Trim();
            if (q.Length == 0) { Browse(); return; }
            content.Content = NavSheet.Load(async () =>
            {
                var found = await Api.Get("/api/files/find", Q(key, ("q", q)));
                var results = found.Strings("results").ToList();
                var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
                stack.Children.Add(Header(results.Count == 0 ? L("未找到文件名包含「%@」的文件", q) : L("找到 %@ 个文件", results.Count) + (found.Truthy("truncated") ? L("（仅列出部分结果）") : "")));
                if (results.Count > 0)
                    stack.Children.Add(Plain(results.Select(rel =>
                    {
                        var name = System.IO.Path.GetFileName(rel);
                        var folder = rel.Length > name.Length ? rel[..^(name.Length + 1)] : "./";
                        return (Control)Row(FileLabel(name, folder, false, null), () => sheet.Push(name, s => FilePage(s, key, rel)));
                    }), 52));
                return NavSheet.Scroll(stack);
            });
        }
        search.TextChanged += (_, _) =>
        {
            debounce?.Stop();
            debounce = new DispatcherTimer(TimeSpan.FromMilliseconds(400), DispatcherPriority.Background, (_, _) => { debounce?.Stop(); Find(); });
            debounce.Start();
        };
        Browse();
        var dock = new DockPanel();
        DockPanel.SetDock(search, Dock.Top);
        dock.Children.Add(search);
        dock.Children.Add(content);
        return dock;
    }

    /// 文件一行：目录是文件夹图标，文件是扩展名写在淡强调色底上；右边 Git 状态（改 / 新 / •）、目录带「›」
    static Control FileLabel(string name, string sub, bool dir, string? git)
    {
        Control icon = dir ? new DuoIcon("folder.fill", 30)
            : new Border
            {
                Width = 30, Height = 30, CornerRadius = new CornerRadius(8),
                Child = Ui.Text(new string((System.IO.Path.GetExtension(name).TrimStart('.') is { Length: > 0 } ext ? ext : "·").Take(4).ToArray()), 9, FontWeight.Bold, "Accent").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center),
            }.Res(Border.BackgroundProperty, "IconTile");
        Control? mark = git switch
        {
            "M" => Ui.Text(L("改"), 10.5, FontWeight.Bold, "Orange"), "A" => Ui.Text(L("增"), 10.5, FontWeight.Bold, "Added"),
            "D" => Ui.Text(L("删"), 10.5, FontWeight.Bold, "Removed"), "R" => Ui.Text(L("名"), 10.5, FontWeight.Bold, "Orange"),
            "?" => Ui.Text(L("新"), 10.5, FontWeight.Bold, "Added"), "•" => Ui.Text("•", 12, FontWeight.Bold, "Orange"), _ => null,
        };
        return Ui.H(10, icon, Ui.VFill(2, Ui.Text(name, 13).Trim(), sub.Length > 0 ? Ui.Text(sub, 11.5, color: "Text2").Trim() : null).Shrink(), new Spacer(), mark,
            dir ? Ui.Sym("chevron.right", 10, "Text3") : null);
    }

    // MARK: 单个文件

    public static void File(string key, string path) => Code.CodeWindow.Open(key, "explorer", path);

    static Control FilePage(NavSheet sheet, string key, string path, bool reveal = false)
    {
        var name = System.IO.Path.GetFileName(path);
        var ext = System.IO.Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        var showSource = false;
        return NavSheet.Load(async () =>
        {
            var query = Q(key, ("path", path));
            if (reveal) query["reveal"] = "1";
            var c = await Api.Get("/api/file", query);
            var stack = new StackPanel { Spacing = 10, Margin = new Thickness(14, 0, 14, 16) };
            stack.Children.Add(Ui.Text(path, 11.5, color: "Text2").Mono().Trim());
            var meta = new[] { Size(c.Num("size") ?? 0), (c.Int("lines") ?? 0) > 0 ? L("%@ 行", c.Int("lines") ?? 0) : "", Relative(c.Num("mtime")) }.Where(s => s.Length > 0);
            stack.Children.Add(Ui.Text(string.Join(" · ", meta), 11.5, color: "Text2"));
            var body = new ContentControl();
            var actions = Ui.H(10);
            void DrawContent()
            {
                actions.Children.Clear();
                if (AppModel.Shared.Session(key)?.CanReply == true)
                    actions.Children.Add(Chip(L("在对话中引用"), "quote.opening", () =>
                    {
                        // Claude Code 认 @路径：把文件加进上下文
                        var draft = (AppModel.Shared.Draft(key) ?? "").Trim();
                        AppModel.Shared.SetDraft(key, (draft.Length > 0 ? draft + " " : "") + "@" + path + " ");
                        AppModel.Shared.Flash(L("已填入对话输入框"));
                    }));
                if (c.Str("text") is string copyText)
                    actions.Children.Add(Chip(L("复制内容"), "doc.on.doc", () => { _ = MainWindow.Current?.Clipboard?.SetTextAsync(copyText); AppModel.Shared.Flash(L("已复制")); }));
                if (ext == "md" && c.Str("text") is not null)
                    actions.Children.Add(Chip(showSource ? L("查看预览") : L("查看源码"), "chevron.left.forwardslash.chevron.right", () => { showSource = !showSource; DrawContent(); }));
                body.Content = Content(c, ext, name, showSource, () => sheet.Push(name, s => FilePage(s, key, path, reveal: true)));
            }
            var tabs = new LookSegmented([("content", L("内容")), ("changes", L("改动记录"))], "content", id =>
            {
                if (id == "changes") { actions.IsVisible = false; body.Content = DiffBody(key, path, null); }
                else { actions.IsVisible = true; DrawContent(); }
            });
            stack.Children.Add(tabs);
            stack.Children.Add(actions);
            stack.Children.Add(body);
            DrawContent();
            return NavSheet.Scroll(stack);
        });
    }

    static Control Content(JsonNode? c, string ext, string name, bool showSource, Action reveal)
    {
        if (c.Truthy("secret"))
            return new StackPanel { Spacing = 8, Children = { Note(L("此文件可能包含密钥或密码（.env、证书、私钥等），默认不显示。"), "Orange"), Form.Button(L("仍然查看"), reveal).HAlign(HorizontalAlignment.Left) } };
        if (c.Truthy("image") && c.Str("data") is string data)
        {
            try
            {
                var bytes = Convert.FromBase64String(data);
                using var stream = new MemoryStream(bytes);
                // 点开能放大缩小、拖着看
                return new Image { Source = new Bitmap(stream), Stretch = Stretch.Uniform, MaxHeight = 900 }.Clip(10)
                    .ZoomOnClick(() => [bytes], () => 0, name);
            }
            catch { return Note(L("图片无法显示")); }
        }
        if (c.Truthy("binary") || c.Truthy("tooLarge")) return Note(c.Truthy("binary") ? L("二进制文件，无法直接查看。") : L("文件过大，无法查看。"));
        if (c.Str("text") is not string text) return Note(L("（无内容）"));
        var stack = new StackPanel { Spacing = 8 };
        if (ext == "md" && !showSource) stack.Children.Add(new MarkdownView(text, fill: true, Links.Open));
        else stack.Children.Add(new CodeView(text, new[] { "py", "sh", "bash", "zsh", "rb", "yml", "yaml", "toml", "conf", "ini", "r", "pl", "ps1" }.Contains(ext) || name is "Dockerfile" or "Makefile"));
        if (c.Truthy("truncated")) stack.Children.Add(Note(L("文件超过 512KB，仅读取了前面部分")));
        return stack;
    }

    // MARK: 改动报告

    /// 「改动」：代码 IDE 的源代码管理
    public static void Changes(string key) => Code.CodeWindow.Open(key, "scm");

    static Control ChangesPage(NavSheet sheet, string key) => NavSheet.Load(async () =>
    {
        var r = await Api.Get("/api/git", Q(key));
        var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
        if (r.Str("repo") is not string repo)
        {
            stack.Children.Add(Note(r.Str("reason") ?? L("此会话的目录不是 Git 仓库")));
            return NavSheet.Scroll(stack);
        }
        var files = r.Arr("files").Items().ToList();
        var untracked = r.Strings("untracked").ToList();
        var ahead = r.Int("ahead") ?? 0;
        var behind = r.Int("behind") ?? 0;
        var branch = $"⎇ {r.Str("branch") ?? L("(无分支)")}" + (r.Str("upstream") is string up ? $" → {up}" : "") + (ahead > 0 ? $" · ↑{ahead}" : "") + (behind > 0 ? $" · ↓{behind}" : "");
        var summary = new List<Control>
        {
            Ui.H(8, Ui.Text(branch, 12).Mono().Trim().Shrink(), new Spacer(), Ui.Text(System.IO.Path.GetFileName(repo.TrimEnd('/', '\\')), 12, color: "Text2")).Pad(12, 8),
        };
        if (files.Count == 0) summary.Add(Ui.Text(L("工作区干净，无未提交的改动"), 13).Pad(12, 8));
        else
        {
            var line = new TextBlock { FontSize = Look.Pt(13) };
            line.Inlines = [];
            line.Inlines.Add(new Run(L("%@ 个文件改动 · ", files.Count)));
            var add = new Run($"+{r.Int("totalAdd") ?? 0}");
            add.Bind(Run.ForegroundProperty, line.GetResourceObservable("Added"));
            var del = new Run($" −{r.Int("totalDel") ?? 0}");
            del.Bind(Run.ForegroundProperty, line.GetResourceObservable("Removed"));
            line.Inlines.Add(add);
            line.Inlines.Add(del);
            line.Res(TextBlock.ForegroundProperty, "Text");
            summary.Add(line.Pad(12, 8));
        }
        if ((r.Int("untrackedCount") ?? 0) > 0) summary.Add(Ui.Text(L("%@ 个新文件", r.Int("untrackedCount") ?? 0), 13).Pad(12, 8));
        if (AppModel.Shared.Session(key)?.CanReply == true && (files.Count > 0 || untracked.Count > 0 || ahead > 0))
        {
            var chips = Ui.H(10);
            if (files.Count > 0 || untracked.Count > 0) chips.Children.Add(Chip(L("让 Claude 提交"), "checkmark.circle", () => AskGit(key, commit: true)));
            if (ahead > 0) chips.Children.Add(Chip(L("让 Claude 推送（↑%@）", ahead), "arrow.up.circle", () => AskGit(key, commit: false)));
            summary.Add(chips.Pad(12, 8));
        }
        stack.Children.Add(Plain(summary, 12).Margin(0, 4, 0, 0));
        if (files.Count > 0 || untracked.Count > 0)
        {
            stack.Children.Add(Header(L("未提交的改动")));
            var rows = files.Select(f => FileChange(sheet, key, f.Str("path") ?? "", f.Str("status") ?? "M", f.Int("add") ?? 0, f.Int("del") ?? 0))
                .Concat(untracked.Select(p => FileChange(sheet, key, p, "??", 0, 0)));
            stack.Children.Add(Plain(rows, 12));
        }
        var commits = r.Arr("commits").Items().ToList();
        if (commits.Count > 0)
        {
            stack.Children.Add(Header(L("最近提交")));
            stack.Children.Add(Plain(commits.Select(c =>
            {
                var hash = c.Str("hash") ?? "";
                var subject = c.Str("subject") ?? "";
                return (Control)Row(Ui.H(8, Ui.Text(hash, 11.5, color: "Text2").Mono(), Ui.Text(subject, 13).Trim().Shrink(), new Spacer(), Ui.Text(Relative(c.Num("ts")), 11.5, color: "Text3")),
                    () => sheet.Push(subject, s => NavSheet.Scroll(DiffBody(key, null, hash))));
            }), 12));
        }
        return NavSheet.Scroll(stack);
    });

    static Control FileChange(NavSheet sheet, string key, string path, string status, int add, int del)
    {
        var name = System.IO.Path.GetFileName(path);
        Control? counts = null;
        if (add + del > 0)
        {
            var text = new TextBlock { FontSize = Look.Pt(11.5) };
            text.Inlines = [];
            var a = new Run($"+{add}");
            a.Bind(Run.ForegroundProperty, text.GetResourceObservable("Added"));
            var d = new Run($" −{del}");
            d.Bind(Run.ForegroundProperty, text.GetResourceObservable("Removed"));
            text.Inlines.Add(a);
            text.Inlines.Add(d);
            counts = text;
        }
        return Row(Ui.H(8, Mark(status), PathText(path).Shrink(), new Spacer(), counts), () => sheet.Push(name, s => NavSheet.Scroll(DiffBody(key, path, null))));
    }

    /// 交给 Claude 去提交 / 推送（它会看 diff、写提交信息），这边不直接动仓库
    static async void AskGit(string key, bool commit)
    {
        var confirm = commit ? L("让 Claude 把当前改动提交到 Git（只提交，不推送）") : L("让 Claude 把已提交的改动推送到远端（不会强推）");
        if (!await Dialogs.Confirm(confirm, commit ? L("让 Claude 提交") : L("让 Claude 推送"))) return;
        var text = commit
            ? L("请把当前的改动提交到 git：先看 git status 和 git diff，只提交和这次任务相关的文件，写一条简洁的中文提交信息，然后 git commit。先不要推送，提交完告诉我提交号和改了哪些文件。")
            : L("请把已经提交的改动推送到远端：先用 git status -sb 确认当前分支和要推的远端，然后 git push。推送失败或需要强推时先停下来告诉我，不要自行使用 --force。");
        AppModel.Shared.Send(key, text, []);
        AppModel.Shared.Flash(L("已发送给 Claude"));
    }

    /// 一段 git diff：加的行淡绿底、删的行淡红底、块头灰底
    static Control DiffBody(string key, string? path, string? commit) => NavSheet.Load(async () =>
    {
        var query = Q(key);
        if (path is not null) query["path"] = path;
        if (commit is not null) query["commit"] = commit;
        var reply = await Api.Get("/api/git/diff", query);
        var lines = (reply.Str("diff") ?? "").Split('\n').Take(4000).ToList();
        if (lines.All(l => l.Trim().Length == 0)) return Note(L("无差异"));
        var stack = new StackPanel { Margin = new Thickness(0, 8, 0, 8) };
        foreach (var line in lines)
        {
            var (fg, bg) = line.StartsWith("+++") || line.StartsWith("---") || line.StartsWith("diff --git") || line.StartsWith("index ") || line.StartsWith("new file")
                ? ("Text2", (string?)null)
                : line.StartsWith("@@") ? ("Text2", "Fill05") : line.StartsWith('+') ? ("Text", "AddedFill") : line.StartsWith('-') ? ("Text", "RemovedFill") : ("Text", null);
            var text = Ui.Text(line.Length == 0 ? " " : line, 12, color: fg, lines: 0).Mono().Wrap();
            var row = new Border { Child = text, Padding = new Thickness(10, 1) };
            if (bg is not null) row.Res(Border.BackgroundProperty, bg);
            stack.Children.Add(row);
        }
        return stack;
    });

    // MARK: 测试报告

    public static void Tests(string key) => NavSheet.Open(L("测试报告"), s => TestsPage(s, key));

    static Control TestsPage(NavSheet sheet, string key) => NavSheet.Load(async () =>
    {
        var runs = (await Api.Get("/api/tests", Q(key))).Arr("runs").Items().ToList();
        if (runs.Count == 0)
            return Empty("checkmark.seal", L("尚未运行测试"), L("Claude 在此会话中运行 pytest、jest、vitest、go test、cargo test、npm test 等命令后，结果会显示在这里。"));
        var ok = runs.Count(r => r.Bool("ok") == true);
        var bad = runs.Count(r => r.Bool("ok") == false);
        var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
        stack.Children.Add(Header(L("最近 %@ 次 · %@ 次通过", runs.Count, ok) + (bad > 0 ? L(" · %@ 次失败", bad) : "")));
        stack.Children.Add(Plain(runs.Select(run =>
        {
            var title = run.Str("description") is { Length: > 0 } d ? d : run.Str("command") ?? "";
            Control icon = run.Truthy("running") ? Ui.Sym("hourglass", 13, "Accent")
                : Ui.Text(run.Bool("ok") == true ? "✓" : run.Bool("ok") == false ? "✗" : "•", 15, FontWeight.Bold, run.Bool("ok") == true ? "Added" : run.Bool("ok") == false ? "Removed" : "Text2");
            var counts = run.Int("passed") is int passed ? L("%@ 通过", passed) + ((run.Int("failed") ?? 0) > 0 ? L(" · %@ 失败", run.Int("failed") ?? 0) : "") : run.Str("summary") ?? "";
            var sub = string.Join(" · ", new[] { Relative(run.Num("ts")), counts }.Where(s => s.Length > 0));
            return (Control)Row(Ui.H(10, icon.Width(22), Ui.VFill(2, Ui.Text(title, 13).Trim(), Ui.Text(sub, 11.5, color: "Text2").Trim()).Shrink()),
                () => sheet.Push(title.Length > 40 ? title[..40] : title, s => TestDetail(run)));
        }), 44));
        return NavSheet.Scroll(stack);
    });

    static Control TestDetail(JsonNode run)
    {
        var stack = new StackPanel { Spacing = 8, Margin = new Thickness(14, 0, 14, 16) };
        stack.Children.Add(Header(L("命令")));
        stack.Children.Add(ToolDetail.MonoBlock(run.Str("command") ?? ""));
        if (run.Str("summary") is { Length: > 0 } summary) { stack.Children.Add(Header(L("结果"))); stack.Children.Add(Note(summary)); }
        stack.Children.Add(Header(L("输出（末尾）")));
        stack.Children.Add(ToolDetail.MonoBlock(run.Str("output") is { Length: > 0 } output ? output : L("（无输出）"), run.Bool("ok") == false));
        return NavSheet.Scroll(stack);
    }

    // MARK: Agent map

    public static void Agents(string key) => NavSheet.Open("Agent map", s => AgentsPage(s, key));

    /// 自测截图：直接打开某个子 agent 的详情；full = 再点进完整记录
    public static void OpenAgent(string key, string agentId, bool full) => NavSheet.Open("Agent map", sheet => NavSheet.Load(async () =>
    {
        var agents = (await Api.Get("/api/agents", Q(key))).Arr("agents").Items().ToList();
        var agent = agents.First(a => a.Str("id") == agentId);
        if (full) Dispatcher.UIThread.Post(() => sheet.Push(agent.Str("description") ?? "", _ => Transcript(key, agent)), DispatcherPriority.Background);
        return AgentDetail(sheet, key, agent, agents);
    }));

    static Control AgentsPage(NavSheet sheet, string key) => NavSheet.Load(async () =>
    {
        var reply = await Api.Get("/api/agents", Q(key));
        var agents = reply.Arr("agents").Items().ToList();
        var tasks = reply.Arr("tasks").Items().ToList();
        var stack = new StackPanel { Spacing = 8, Margin = new Thickness(14, 0, 14, 16) };
        stack.Children.Add(Ui.Text(agents.Count == 0 ? L("尚未派出子 agent") : L("%@ 个子 agent · 轻点查看详情", agents.Count), 12, color: "Text2"));
        var session = AppModel.Shared.Session(key);
        var context = session?.Usage?.Context is int ctx ? $" · {Tokens(ctx)} tokens in context" : "";
        stack.Children.Add(Node(session?.Title ?? L("主 agent"), Tools.ModelName(session?.Usage?.Model) + context, session?.IsBusy == true, session?.Error is not null, null));
        void Children(string parent, int depth)
        {
            foreach (var agent in agents.Where(a => (a.Str("parent") ?? "main") == parent).OrderBy(a => a.Num("startedAt") ?? 0))
            {
                var meta = string.Join(" · ", new[] { agent.Str("agentType"), Tools.ModelName(agent.Str("model")), (agent.Int("tokens") ?? 0) > 0 ? $"{Tokens(agent.Int("tokens") ?? 0)} tokens" : null }.Where(s => !string.IsNullOrEmpty(s)));
                var picked = agent;
                stack.Children.Add(Node(agent.Str("description") ?? L("子 agent"), meta, !agent.Truthy("finished"), false, () => sheet.Push(picked.Str("description") ?? L("子 agent"), s => AgentDetail(s, key, picked, agents)))
                    .Margin(22 * depth, 0, 0, 0));
                Children(agent.Str("id") ?? "", depth + 1);
            }
        }
        Children("main", 1);
        if (tasks.Count > 0)
        {
            var running = tasks.Count(t => (t.Str("status") ?? "running") == "running");
            stack.Children.Add(Ui.Text(L("%lld 个后台任务", tasks.Count) + (running > 0 ? L("（%@ 个运行中）", running) : "") + L(" · 轻点查看详情"), 12, color: "Text2").Margin(0, 6, 0, 0));
            foreach (var task in tasks)
            {
                var status = task.Str("status") ?? "running";
                var statusText = status switch { "running" => L("运行中"), "completed" => L("已完成"), "failed" => L("失败"), "killed" => L("已停止"), _ => status };
                var picked = task;
                stack.Children.Add(Node(task.Str("description") ?? L("后台命令"), "shell · " + statusText, status == "running", status == "failed",
                    () => sheet.Push(picked.Str("description") ?? L("后台命令"), s => TaskDetail(key, picked))));
            }
        }
        return NavSheet.Scroll(stack);
    });

    static string Tokens(int n) => n >= 1000 ? (n / 1000.0).ToString("0.#", CultureInfo.InvariantCulture) + "k" : n.ToString();

    static Control Node(string title, string sub, bool running, bool failed, Action? open)
    {
        var dot = Ui.Dot(7, failed ? "Red" : running ? "Accent" : "Green");
        var content = Ui.H(10, dot, Ui.VFill(2, Ui.Text(title, 13, FontWeight.SemiBold).Trim(), sub.Length > 0 ? Ui.Text(sub, 11.5, color: "Text2").Trim() : null).Shrink(), new Spacer(),
            open is null ? null : Ui.Sym("chevron.right", 10, "Text3"));
        var tap = new Tap(content.Pad(12, 9), open, 10) { BorderThickness = new Thickness(0.5) }.Keys("Fill05", open is null ? "Fill05" : "Fill08").Res(Border.BorderBrushProperty, "Fill08");
        if (open is null) tap.Cursor = Cursor.Default;
        return tap;
    }

    /// 子 agent 详情（同 Mac / iPhone 版 SubagentDetailView）：状态、谁派的、用时和 token、交回的结果；分配的任务、调用的工具点开看；底下「查看完整记录」
    static Control AgentDetail(NavSheet sheet, string key, JsonNode agent, List<JsonNode> all)
    {
        var finished = agent.Truthy("finished");
        var stack = new StackPanel { Spacing = 10, Margin = new Thickness(14, 0, 14, 16) };
        stack.Children.Add(Ui.H(8, Ui.Dot(8, finished ? "Green" : "Accent"), Ui.Text(agent.Str("description") ?? "", 16, FontWeight.SemiBold, lines: 2).Wrap().Shrink()));
        var parent = agent.Str("parent") ?? "main";
        var start = agent.Num("startedAt");
        var span = start is double s0 ? Format.Duration((int)Math.Max(0, ((finished ? agent.Num("endedAt") : null) ?? Format.NowMs) - s0) / 1000) : null;
        var tokens = agent.Int("tokens") ?? 0;
        stack.Children.Add(Ui.VFill(3,
            Ui.Text(string.Join(" · ", new[] { finished ? L("已完成") : L("进行中"), agent.Str("agentType"), Tools.ModelName(agent.Str("model")), agent.Str("requestShape") == "background" ? L("后台") : null }
                .Where(t => !string.IsNullOrEmpty(t))), 12, color: "Text2"),
            Ui.Text(parent == "main" ? L("由主 agent 派出") : L("由「%@」派出", all.FirstOrDefault(a => a.Str("id") == parent)?.Str("description") ?? L("另一个子 agent")), 12, color: "Text2"),
            span is null && tokens == 0 ? null : Ui.Text(string.Join(" · ", new[] { span, tokens > 0 ? $"{Tokens(tokens)} tokens" : null }.Where(t => !string.IsNullOrEmpty(t))), 12, color: "Text2")));
        if (agent.Str("report") is { Length: > 0 } report)
            stack.Children.Add(new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(12), Child = new MarkdownView(report, fill: true, Links.Open) }
                .Res(Border.BackgroundProperty, "Fill05"));
        else if (!finished)
            stack.Children.Add(Note(L("正在执行，完成后返回的结果将显示在此处。")));
        stack.Children.Add(Disclosure(L("分配的任务"), () => Ui.Text(agent.Str("prompt") is { Length: > 0 } p ? p : L("（无记录）"), 12.5, lines: 0).Wrap()));
        var tools = agent.Arr("tools").Items().ToList();
        stack.Children.Add(Disclosure(L("调用的工具（%@）", tools.Count), () =>
        {
            var list = new StackPanel { Spacing = 6 };
            foreach (var tool in tools)
                list.Children.Add(Ui.HTop(6, Ui.Text(tool.Str("name") ?? "", 11.5, FontWeight.SemiBold).Mono(),
                    Ui.Text((tool.Str("brief") ?? "").Replace((tool.Str("name") ?? "") + ": ", ""), 11.5, color: "Text2", lines: 2).Mono().Wrap().Shrink()));
            return list;
        }));
        var title = agent.Str("description") ?? L("子 agent");
        var full = new Tap(Ui.Text(L("查看完整记录"), 13, FontWeight.Medium).HAlign(HorizontalAlignment.Center).Pad(0, 11), () => sheet.Push(title, _ => Transcript(key, agent)), 12)
            .Keys("Fill05", "Fill10");
        stack.Children.Add(full);
        return NavSheet.Scroll(stack);
    }

    /// 点开收起的一节（同 SwiftUI 的 DisclosureGroup）：标题右边一个小箭头，内容第一次点开时才建
    static Control Disclosure(string title, Func<Control> content)
    {
        var holder = new ContentControl { IsVisible = false, Margin = new Thickness(0, 6, 0, 0) };
        var chevron = Ui.Sym("chevron.right", 10, "Text2");
        var header = new Tap(Ui.H(6, Ui.Text(title, 13, FontWeight.Medium), new Spacer(), chevron).Pad(0, 4), () =>
        {
            holder.Content ??= content();
            holder.IsVisible = !holder.IsVisible;
            chevron.RenderTransform = holder.IsVisible ? new RotateTransform(90) : null;
        }, 6).Keys("Transparent", "Transparent");
        return Ui.VFill(0, header, holder);
    }

    /// 子 agent 的完整记录（同 iPhone 版 SubagentTranscriptView）：和对话页一样的排版，只读
    static Control Transcript(string key, JsonNode agent) => NavSheet.Load(async () =>
    {
        var id = agent.Str("id") ?? "";
        var chatKey = $"{key}|agent:{id}";
        var chat = AppModel.Shared.Chat(chatKey);
        var page = await Api.Get("/api/history", Q(key, ("agent", id), ("limit", "400")));
        chat.Reset();
        chat.Add(page.Arr("items").Items().Select(ChatItem.Parse).OfType<ChatItem>());
        chat.Loaded = true;
        var speaker = AppModel.Shared.Session(key)?.Agent ?? Kiteline.Model.Agents.DefaultId;
        var list = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        void Draw()
        {
            list.Children.Clear();
            foreach (var row in chat.Rows(null)) list.Children.Add(ChatView.RowView(chatKey, row, speaker, 600, Links.Open));
            if (list.Children.Count == 0) list.Children.Add(Note(L("（无记录）")).Margin(14, 0, 14, 0));
        }
        Draw();
        // 点开、收起一串步骤时重画
        void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs e) { if (e.PropertyName == nameof(ChatStore.Revision)) Draw(); }
        chat.PropertyChanged += Changed;
        list.DetachedFromVisualTree += (_, _) => chat.PropertyChanged -= Changed;
        var box = new Border { Child = list }.Res(Border.BackgroundProperty, "ChatBackground");
        var scroll = NavSheet.Scroll(box);
        if (scroll is ScrollViewer viewer) Dispatcher.UIThread.Post(() => viewer.ScrollToEnd(), DispatcherPriority.Background);
        return scroll;
    });

    static Control TaskDetail(string key, JsonNode task) => NavSheet.Load(async () =>
    {
        var reply = await Api.Get("/api/task-output", Q(key, ("task", task.Str("id") ?? "")));
        var stack = new StackPanel { Spacing = 8, Margin = new Thickness(14, 0, 14, 16) };
        stack.Children.Add(Header(L("命令")));
        stack.Children.Add(ToolDetail.MonoBlock(task.Str("command") ?? ""));
        stack.Children.Add(Header(L("输出")));
        stack.Children.Add(ToolDetail.MonoBlock(reply.Str("output") is { Length: > 0 } o ? o : L("（无输出）"), task.Str("status") == "failed"));
        return NavSheet.Scroll(stack);
    });

    // MARK: 对话内搜索

    public static void Search(string key, Action<string> jump)
    {
        var speaker = AppModel.Shared.Session(key)?.Speaker ?? "Claude";
        NavSheet? sheet = null;
        sheet = NavSheet.Open(L("在对话里搜索"), s =>
        {
            var box = new TextBox { Watermark = L("你的消息与 %@ 的回复", speaker), FontSize = Look.Pt(13), Padding = new Thickness(10, 5), Margin = new Thickness(14, 0, 14, 6) };
            box.Classes.Add("search");
            var results = new ContentControl();
            DispatcherTimer? debounce = null;
            void Run()
            {
                var q = (box.Text ?? "").Trim();
                if (q.Length == 0) { results.Content = null; return; }
                results.Content = NavSheet.Load(async () =>
                {
                    var reply = await Api.Get("/api/search", Q(key, ("q", q)));
                    var hits = reply.Arr("results").Items().FirstOrDefault().Arr("hits").Items().Reverse().ToList();   // 新的在前
                    var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
                    stack.Children.Add(Header(hits.Count == 0 ? L("此对话中未找到「%@」", q) : L("找到 %@ 处", hits.Count) + (reply.Truthy("truncated") ? L("（仅列出部分）") : "")));
                    if (hits.Count > 0)
                        stack.Children.Add(Plain(hits.Select(h =>
                        {
                            var mine = h.Str("t") == "user";
                            var who = Ui.Text(mine ? AppModel.Shared.Me?.Name ?? L("我") : speaker, 11.5, FontWeight.SemiBold, mine ? "WechatGreen" : "Accent");
                            var id = h.Str("id") ?? "";
                            var body = Ui.VFill(4, Ui.H(8, who, new Spacer(), Ui.Text(h.Num("ts") is double ts ? Format.MessageTime(ts) : "", 11, color: "Text3")), Highlighted(h.Str("snippet") ?? "", q));
                            return (Control)Row(body, () => { sheet?.Close(); jump(id); });
                        })));
                    return NavSheet.Scroll(stack);
                });
            }
            box.TextChanged += (_, _) =>
            {
                debounce?.Stop();
                debounce = new DispatcherTimer(TimeSpan.FromMilliseconds(450), DispatcherPriority.Background, (_, _) => { debounce?.Stop(); Run(); });
                debounce.Start();
            };
            box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { debounce?.Stop(); Run(); } };
            box.AttachedToVisualTree += (_, _) => Dispatcher.UIThread.Post(() => box.Focus());
            var dock = new DockPanel();
            DockPanel.SetDock(box, Dock.Top);
            dock.Children.Add(box);
            dock.Children.Add(results);
            return dock;
        }, 560, 560);
    }

    static TextBlock Highlighted(string text, string q)
    {
        var block = new TextBlock { FontSize = Look.Pt(13), TextWrapping = TextWrapping.Wrap, MaxLines = 4, TextTrimming = TextTrimming.CharacterEllipsis };
        block.Res(TextBlock.ForegroundProperty, "Text");
        block.Inlines = [];
        var at = text.IndexOf(q, StringComparison.OrdinalIgnoreCase);
        if (at < 0) { block.Inlines.Add(new Run(text)); return block; }
        block.Inlines.Add(new Run(text[..at]));
        var mark = new Run(text.Substring(at, q.Length)) { FontWeight = FontWeight.Bold };
        mark.Bind(Run.ForegroundProperty, block.GetResourceObservable("Accent"));
        block.Inlines.Add(mark);
        block.Inlines.Add(new Run(text[(at + q.Length)..]));
        return block;
    }

    // MARK: 会话信息

    public static void Info(string key)
    {
        NavSheet.Open(L("会话信息"), s => NavSheet.Load(async () =>
        {
            var session = AppModel.Shared.Session(key);
            JsonNode? meta = null;
            try { meta = (await Api.Get("/api/session-meta", Q(key))).Obj("session"); } catch { }
            Control Value(string label, string value, bool mono = false)
            {
                var text = Ui.Text(value, 13, color: "Text2").Trim();
                if (mono) { text.FontFamily = Look.Mono; text.FontSize = Look.Pt(12); text.TextTrimming = TextTrimming.PrefixCharacterEllipsis; }
                return Ui.H(12, Ui.Text(label, 13), new Spacer(), text.Shrink()).Pad(12, 9);
            }
            var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
            stack.Children.Add(Group([
                Value(L("标题"), session?.Title ?? meta.Str("title") ?? ""),
                Value(L("所在机器"), session?.SourceName ?? Lang.Machine(meta.Str("sourceName") ?? "")),
                Value(L("目录"), session?.Cwd ?? meta.Str("cwd") ?? "", mono: true),
                Value(L("开始于"), Format.Short(session?.StartedAt ?? meta.Num("startedAt") ?? meta.Num("lastActive"))),
            ], 12));
            if (session?.Usage is { } usage)
            {
                stack.Children.Add(Header(L("用量")));
                var rows = new List<Control> { Value(L("模型"), Tools.ModelName(usage.Model)) };
                if (usage.Context is int ctx && usage.Window is int window && window > 0)
                {
                    var percent = (int)Math.Round(ctx * 100.0 / window);
                    var bar = new Grid { Width = 100, Height = 5, ColumnDefinitions = new ColumnDefinitions($"{Math.Min(100, percent)}*,{Math.Max(0, 100 - percent)}*") };
                    var track = new Border { CornerRadius = new CornerRadius(2.5) }.Res(Border.BackgroundProperty, "Fill10");
                    Grid.SetColumnSpan(track, 2);
                    bar.Children.Add(track);
                    bar.Children.Add(new Border { CornerRadius = new CornerRadius(2.5) }.Res(Border.BackgroundProperty, percent >= 90 ? "Red" : percent >= 70 ? "Orange" : "Text2"));
                    rows.Add(Ui.H(12, Ui.Text(L("上下文"), 13), new Spacer(), Ui.VFill(4, Ui.Text($"{percent}% · {Tokens(ctx)} / {Tokens(window)}", 13, color: "Text2").HAlign(HorizontalAlignment.Right), bar.HAlign(HorizontalAlignment.Right))).Pad(12, 9));
                }
                stack.Children.Add(Group(rows, 12));
            }
            return NavSheet.Scroll(stack);
        }), 520, 430);
    }

    // MARK: 权限模式

    public static void Mode(string key)
    {
        NavSheet.Open(L("权限模式"), s =>
        {
            var session = AppModel.Shared.Session(key);
            var current = PermissionMode.Current(key);
            var rows = PermissionMode.Cycle.Select(mode =>
            {
                var content = Ui.HTop(12, new DuoIcon(mode.Symbol, 30), Ui.VFill(2, Ui.Text(mode.Name, 14, FontWeight.Medium), Ui.Text(L(mode.Detail), 11.5, color: "Text2").Trim()).Shrink(), new Spacer(),
                    mode == current ? Ui.Sym("checkmark", 14, "WechatGreen") : null);
                return (Control)Row(content, session?.CanReply == true ? async () => { await SetMode(key, mode); s.Close(); } : null);
            });
            var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
            stack.Children.Add(Group(rows, 54));
            stack.Children.Add(Note(current is null ? L("此会话当前为「跳过所有确认」模式，不在 ⇧Tab 的切换范围内，需在电脑上修改。")
                : L("切换操作等同于在 Claude Code 中按 ⇧Tab 切换到该模式。下一条消息发出后，记录中将显示新模式。")));
            return stack;
        }, 520, 400);
    }

    /// 按几下 ⇧Tab 切到这个模式（同 iOS 版 setPermissionMode）
    static async Task SetMode(string key, PermissionMode target)
    {
        var model = AppModel.Shared;
        if (PermissionMode.Current(key) is not { } current) { model.Flash(L("此会话当前为「跳过所有确认」模式，需在电脑上切换")); return; }
        var from = Array.IndexOf(PermissionMode.Cycle, current);
        var to = Array.IndexOf(PermissionMode.Cycle, target);
        var presses = (to - from + PermissionMode.Cycle.Length) % PermissionMode.Cycle.Length;
        if (presses == 0) return;
        try
        {
            await Api.Post("/api/key", new JsonObject { ["key"] = "shift+tab", ["times"] = presses }, new Dictionary<string, string> { ["key"] = key });
            model.Chat(key).ModeOverride = (target.Id, model.Session(key)?.PermissionMode);
            model.Chat(key).Touch();
            model.Flash(L("已切换至「%@」", target.Name));
        }
        catch (Exception e) { model.Flash(e.Message); }
    }

    // MARK: 模型和思考等级

    static readonly (string Id, string Name)[] Models = [("claude-fable-5-1", "Fable 5.1"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-haiku-5-5", "Haiku 5.5")];

    public static void Model(string key)
    {
        NavSheet.Open(L("模型和思考等级"), s =>
        {
            var model = AppModel.Shared;
            var session = model.Session(key);
            var enabled = session?.CanReply == true;
            var (current, _) = ModelLabel.Parts(key);
            var chat = model.Chat(key);
            var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
            stack.Children.Add(Header(L("模型")));
            stack.Children.Add(Group(Models.Select(choice => (Control)Row(Ui.H(8, Ui.Text(choice.Name, 14, FontWeight.Medium), new Spacer(), choice.Name == current ? Ui.Sym("checkmark", 14, "WechatGreen") : null),
                enabled ? () =>
                {
                    if (choice.Name != current)
                    {
                        var sent = model.Send(key, "/model " + choice.Id, []);
                        chat.ModelOverride = (choice.Id, session?.Usage?.Model, sent);
                        model.Flash(L("已发送 /model：切换为 %@", choice.Name));
                    }
                    s.Close();
                } : null)), 12));
            stack.Children.Add(Note(current == L("模型") ? L("Claude 尚未回复，暂无法确定当前使用的模型。") : L("切换模型将在此会话中发送 /model 命令，自下一条消息起生效。")));
            stack.Children.Add(Header(L("思考等级")));
            var effort = chat.EffortOverride is { } e && e.Baseline == session?.Effort ? e.Effort : session?.Effort ?? "auto";
            var dots = new Grid();
            for (var i = 0; i < Effort.Levels.Length; i++)
            {
                dots.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
                var (id, name) = Effort.Levels[i];
                var on = id == effort;
                var dot = new Border { Width = on ? 16 : 9, Height = on ? 16 : 9, CornerRadius = new CornerRadius(8), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
                    .Res(Border.BackgroundProperty, on ? "WechatGreen" : "Fill15");
                var cell = Ui.Stack(Orientation.Vertical, 5, Align.Center, [new Panel { Height = 16, Children = { dot } }, Ui.Text(L(name), 11, color: on ? "Text" : "Text2")]);
                var level = id;
                var tap = new Tap(cell.Pad(0, 4), enabled && !on ? () =>
                {
                    var sent = model.Send(key, "/effort " + level, []);
                    chat.EffortOverride = (level, session?.Effort, sent);
                    model.Flash(L("已发送 /effort：%@", L(name)));
                    s.Reload();
                } : null, 6).Keys("Transparent", "Transparent");
                Grid.SetColumn(tap, i);
                dots.Children.Add(tap);
            }
            var ultra = chat.UltracodeOverride is { } u && u.Baseline == (session?.Ultracode ?? false) ? u.On : session?.Ultracode ?? false;
            var ultracode = new MacSwitch(ultra, on =>
            {
                var sent = model.Send(key, "/effort ultracode " + (on ? "on" : "off"), []);
                chat.UltracodeOverride = (on, session?.Ultracode ?? false, sent);
                model.Flash(on ? L("Ultracode 已开") : L("Ultracode 已关"));
            }) { IsEnabled = enabled };
            stack.Children.Add(Group([
                Ui.VFill(10, Ui.H(6, Ui.Sym("gauge.with.dots.needle.50percent", 13, "Text"), Ui.Text(L("思考等级"), 13), new Spacer(), Ui.Text(Effort.Name(effort), 13, color: "Text2")), dots).Pad(12, 10),
                Ui.H(10, Ui.VFill(2, Ui.H(6, Ui.Sym("bolt.horizontal", 13, "Text"), Ui.Text("Ultracode", 13)), Ui.Text(L("大型任务多代理并行"), 11.5, color: "Text2")).Shrink(), new Spacer(), ultracode).Pad(12, 10),
            ], 12));
            stack.Children.Add(Note(L("思考等级和 Ultracode 仅作用于此会话（发送 /effort 命令）。")));
            return NavSheet.Scroll(stack);
        }, 520, 560);
    }
}

/// 带行号、简单着色的代码（关键字、字符串、注释、数字；同 Mac 版 CodeView）
public sealed class CodeView : Border
{
    static readonly HashSet<string> Keywords = [.. ("const let var function return if else for while do switch case break continue new class extends import from export default async await try catch finally throw typeof instanceof in of null undefined true false this super static public private protected interface type enum implements def lambda None True False self elif pass raise with as yield func guard struct protocol extension init nil package go defer chan range fn mut impl pub use mod match where crate then end local fi esac done echo").Split(' ')];
    static readonly Regex HashTokens = new(@"(#.*$|""(?:\\.|[^""\\])*""|'(?:\\.|[^'\\])*'|\b\d+(?:\.\d+)?\b|\b[A-Za-z_]\w*\b)", RegexOptions.Compiled);
    static readonly Regex SlashTokens = new(@"(//.*$|/\*.*?\*/|""(?:\\.|[^""\\])*""|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b|\b[A-Za-z_]\w*\b)", RegexOptions.Compiled);

    public CodeView(string text, bool hashComments)
    {
        CornerRadius = new CornerRadius(10);
        Padding = new Thickness(10);
        this.Res(BackgroundProperty, "Code");
        var lines = text.Split('\n');
        var shown = lines.Take(3000).ToList();
        var numbers = new TextBlock { FontFamily = Look.Mono, FontSize = Look.Pt(12), TextAlignment = TextAlignment.Right, MinWidth = 28, LineHeight = Look.Pt(12) * 1.45 };
        numbers.Res(TextBlock.ForegroundProperty, "Text3");
        numbers.Text = string.Join("\n", Enumerable.Range(1, shown.Count));
        var code = new SelectableTextBlock { FontFamily = Look.Mono, FontSize = Look.Pt(12), TextWrapping = TextWrapping.NoWrap, LineHeight = Look.Pt(12) * 1.45 };
        code.Res(TextBlock.ForegroundProperty, "Text");
        code.Inlines = [];
        var regex = hashComments ? HashTokens : SlashTokens;
        for (var i = 0; i < shown.Count; i++)
        {
            var line = shown[i].TrimEnd('\r');
            var pos = 0;
            foreach (Match m in regex.Matches(line))
            {
                if (m.Index > pos) code.Inlines.Add(new Run(line[pos..m.Index]));
                var token = m.Value;
                var color = token.StartsWith("//") || token.StartsWith("/*") || token.StartsWith('#') ? "Text2"
                    : token[0] is '"' or '\'' or '`' ? "CodeString" : char.IsDigit(token[0]) ? "CodeNumber" : Keywords.Contains(token) ? "CodeKeyword" : null;
                var run = new Run(token);
                if (color is not null) run.Bind(Run.ForegroundProperty, code.GetResourceObservable(color));
                code.Inlines.Add(run);
                pos = m.Index + m.Length;
            }
            if (pos < line.Length) code.Inlines.Add(new Run(line[pos..]));
            if (i < shown.Count - 1) code.Inlines.Add(new LineBreak());
        }
        // 不折行、长行横着滚：行号和代码一行对一行
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };
        var scroller = new ScrollViewer { Content = code, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled, Margin = new Thickness(10, 0, 0, 0) };
        Grid.SetColumn(scroller, 1);
        grid.Children.Add(numbers);
        grid.Children.Add(scroller);
        var stack = new StackPanel { Children = { grid } };
        if (lines.Length > shown.Count) stack.Children.Add(Ui.Text(L("仅显示前 3000 行（共 %@ 行）", lines.Length), 12, color: "Text2").Margin(0, 8, 0, 0));
        Child = stack;
    }
}
