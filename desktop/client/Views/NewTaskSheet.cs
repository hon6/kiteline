using System.Globalization;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Kiteline.Model;
using Kiteline.Net;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 「新任务」（同 Mac 版 NewTaskSheet）：选项目 + 写要求（可附截图），在这个项目的 VS Code 窗口里新建一个 Claude Code 会话；
/// 也可以定成每天 / 工作日 / 某一次的定时任务，或在独立分支（git worktree）里做
public sealed class NewTaskSheet
{
    sealed record Project(string SourceId, string SourceName, string Kind, string Cwd, string Name, string? Title, int Live, bool Open, double LastActive)
    {
        public string Id => $"{SourceId}\n{Cwd}";

        public static Project? Parse(JsonNode? n) =>
            n.Str("sourceId") is string sourceId && n.Str("cwd") is string cwd && n.Bool("exists") != false
                ? new Project(sourceId, Lang.Machine(n.Str("sourceName") ?? ""), n.Str("kind") ?? "local", cwd, n.Str("name") ?? System.IO.Path.GetFileName(cwd.TrimEnd('/', '\\')),
                              n.Str("title"), n.Int("live") ?? 0, n.Truthy("open"), n.Num("lastActive") ?? 0)
                : null;
    }

    const int MaxImages = 6;
    static NewTaskSheet? shown;

    readonly Window window;
    readonly TextBox search;
    readonly StackPanel rows = new();
    /// 设备、项目两排胶囊（同侧栏会话列表）
    readonly StackPanel scopes = new() { Spacing = 8 };
    readonly ContentControl listOverlay = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBox input;
    readonly WrapPanel images = new();
    readonly LookSegmented timing;
    readonly DatePicker datePicker = new() { VerticalAlignment = VerticalAlignment.Center };
    readonly TimePicker timePicker = new() { VerticalAlignment = VerticalAlignment.Center, ClockIdentifier = "24HourClock", MinuteIncrement = 5 };
    readonly CheckBox isolated;
    readonly TextBlock status = Ui.Text("", 11.5, color: "Text2", lines: 2).Wrap();
    readonly Icon warning = Ui.Sym("exclamationmark.triangle", 11.5, "Orange");
    readonly Tap startButton;
    readonly TextBlock startLabel = Ui.Text("", 13, FontWeight.SemiBold, "White").HAlign(HorizontalAlignment.Center);

    List<Project> projects = [];
    string? selection;
    /// 设备（来源 id）、项目（项目名 = 目录最后一级）筛选，空 = 全部：打开时带入侧栏会话列表正筛着的，在这里改不影响侧栏
    string sourceFilter = "", projectFilter = "";
    bool loading = true, sending, capConfirmed;
    readonly List<ComposeAttachment> attached = [];

    /// text：任务内容先填好（待办「创建会话」带进来的，用户看过、改好再开始）
    public static void Open((string SourceId, string Cwd)? preset = null, string? text = null)
    {
        if (shown is not null)
        {
            if (!string.IsNullOrEmpty(text) && string.IsNullOrWhiteSpace(shown.input.Text)) shown.input.Text = text;
            shown.window.Activate();
            return;
        }
        shown = new NewTaskSheet(preset);
        if (!string.IsNullOrEmpty(text)) shown.input.Text = text;
    }

    NewTaskSheet((string SourceId, string Cwd)? preset)
    {
        search = new TextBox { Watermark = L("搜索项目"), Width = 200, FontSize = Look.Pt(13), Padding = new Thickness(10, 5) };
        search.Classes.Add("search");
        search.TextChanged += (_, _) => DrawRows();
        // 「新任务」在弹窗的标题栏里（同别的弹窗）；这一行是说明和搜索
        var intro = Ui.Text(L("选择项目并填写任务内容，可附截图。将在该项目的 VS Code 窗口中新建会话（窗口未打开时将先打开）。"), 12, color: "Text2", lines: 0).Wrap();
        var header = Ui.H(12, intro.Shrink(), search);

        var listBox = new Border
        {
            Height = 220, CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(0.5), ClipToBounds = true,
            Child = new Panel { Children = { new ScrollViewer { Content = rows.Pad(4), HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled }, listOverlay } },
        }.Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");

        input = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 96, MaxHeight = 200, FontSize = Look.Pt(14),
            Padding = new Thickness(10, 8), Background = Brushes.Transparent, BorderThickness = new Thickness(0),
        };
        input.Classes.Add("plain");
        input.AddHandler(InputElement.KeyDownEvent, OnKey, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        input.TextChanged += (_, _) => Update();
        var addImage = new Tap(Ui.H(4, Ui.Sym("photo.badge.plus", 12, "Accent"), Ui.Text(L("添加图片"), 12, color: "Accent")).Pad(4, 2), Pick, 4).Keys("Transparent", "Fill05");
        var field = new Border
        {
            CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(0.5),
            Child = new StackPanel
            {
                Children =
                {
                    input, images,
                    Ui.H(8, new DictateButton(said => { input.Text = DictateButton.Append(said, input.Text); input.Focus(); input.CaretIndex = input.Text?.Length ?? 0; }), addImage,
                        new Spacer(), Ui.Text(L("Ctrl+V 粘贴截图 · Ctrl+Enter 开始"), 11.5, color: "Text3")).Pad(8, 0, 8, 8),
                },
            },
        }.Res(Border.BackgroundProperty, "Surface").Res(Border.BorderBrushProperty, "Separator");
        DragDrop.SetAllowDrop(field, true);
        field.AddHandler(DragDrop.DropEvent, (_, e) => OnDrop(e));

        timing = new LookSegmented([("now", L("现在开始")), ("daily", L("每天")), ("weekdays", L("工作日")), ("once", L("仅一次"))], "now", _ => Update())
        {
            Width = Lang.Current == "en" ? 340 : 280,   // 英文「Start Now」「Weekdays」放不进 280
        };
        var tomorrow = DateTime.Today.AddDays(1);
        datePicker.SelectedDate = tomorrow;
        timePicker.SelectedTime = new TimeSpan(9, 0, 0);
        isolated = new CheckBox { Content = Ui.Text(L("在独立分支中进行（git worktree）"), 12), VerticalAlignment = VerticalAlignment.Center }
            .Tip(L("在仓库旁新建 worktree 及以 tars/ 开头的分支，Claude 仅在其中修改，不影响主目录中正在进行的改动"));
        var options = Ui.H(10, timing, datePicker, timePicker, new Spacer(), isolated);

        startButton = new Tap(startLabel.Pad(18, 0), Start, 7) { Height = 30, MinWidth = 88 }.Keys("Action", "Action");
        var cancel = new Tap(Ui.Text(L("取消"), 13).HAlign(HorizontalAlignment.Center).Pad(18, 0), () => window!.Close(), 7) { Height = 30, MinWidth = 72, BorderThickness = new Thickness(0.5) }
            .Keys("Fill10", "Fill15").Res(Border.BorderBrushProperty, "Fill12");
        var footer = Ui.H(10, warning, status.Shrink(), new Spacer(), cancel, startButton);

        var stack = new StackPanel { Spacing = 12, Children = { header, scopes, listBox, field, options, footer } };
        window = Dialog.Make(stack.Pad(20), 600, L("新任务"));
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) window.Close(); };
        window.Closed += (_, _) => { shown = null; MainModel.Shared.NewTaskPreset = null; };
        window.Opened += (_, _) => input.Focus();
        Update();
        DrawRows();
        Dialog.Show(window);
        Load(preset);
    }

    async void Load((string SourceId, string Cwd)? preset)
    {
        try
        {
            var reply = await AppModel.Shared.Api.Get("/api/projects");
            projects = reply.Arr("projects").Items().Select(Project.Parse).OfType<Project>().ToList();
            // 带入侧栏正筛着的设备、项目（侧栏当没筛的——机器不在了、项目里已没有运行中的会话——这里也不筛）
            var model = AppModel.Shared;
            var main = MainModel.Shared;
            if (model.Sources.Any(s => s.Id == main.SourceFilter) && projects.Any(x => x.SourceId == main.SourceFilter)) sourceFilter = main.SourceFilter;
            if (model.Sessions.Any(s => s.Folder == main.ProjectFilter) && projects.Any(x => x.Name == main.ProjectFilter)) projectFilter = main.ProjectFilter;
            if (preset is { } p && projects.FirstOrDefault(x => x.SourceId == p.SourceId && x.Cwd == p.Cwd) is { } found)
            {
                // 指定了项目（从某个会话、项目页来的）：筛选和它对不上的那一项放开，免得选中的看不见
                if (sourceFilter.Length > 0 && sourceFilter != found.SourceId) sourceFilter = "";
                if (projectFilter.Length > 0 && projectFilter != found.Name) projectFilter = "";
                selection = found.Id;
            }
        }
        catch (Exception e) { status.Text = e.Message; }
        loading = false;
        DrawRows();
        Update();
    }

    Project? Selected => projects.FirstOrDefault(p => p.Id == selection);

    /// 搜索词筛过的（设备、项目两排的个数按它算）
    List<Project> Searched
    {
        get
        {
            var q = (search.Text ?? "").Trim().ToLowerInvariant();
            return q.Length == 0 ? projects : projects.Where(p => $"{p.Name} {p.Cwd} {p.SourceName} {p.Title}".ToLowerInvariant().Contains(q)).ToList();
        }
    }

    List<Project> Shown => Searched.Where(p => (sourceFilter.Length == 0 || p.SourceId == sourceFilter) && (projectFilter.Length == 0 || p.Name == projectFilter)).ToList();

    /// 设备、项目两排胶囊（同侧栏会话列表）：不止一台设备、不止一个项目时才有。
    /// 设备按侧栏的先后、个数跟着项目筛选走；项目按列表里的先后（最近用过的在前）、个数跟着设备筛选走，筛着的那个这台设备上没有也列着
    void DrawScopes()
    {
        // 重画后胶囊条会滚回开头：记下原来滚到哪，排好版再滚回去（点了靠右的胶囊不至于跑没影）
        var offsets = scopes.Children.OfType<FilterBar>().Select(b => b.Offset).ToList();
        scopes.Children.Clear();
        var searched = Searched;
        var rank = AppModel.Shared.Sources.Select((s, i) => (s.Id, i)).GroupBy(x => x.Id).ToDictionary(g => g.Key, g => g.First().i);
        var inProject = searched.Where(p => projectFilter.Length == 0 || p.Name == projectFilter).ToList();
        var sources = projects.GroupBy(p => p.SourceId).Select(g => (Id: g.Key, Title: g.First().SourceName))
            .OrderBy(s => rank.TryGetValue(s.Id, out var i) ? i : int.MaxValue).ThenBy(s => s.Title, StringComparer.Ordinal)
            .Select(s => (s.Id, s.Title, inProject.Count(p => p.SourceId == s.Id))).ToList();
        var names = searched.Where(p => sourceFilter.Length == 0 || p.SourceId == sourceFilter)
            .GroupBy(p => p.Name).Select(g => (g.Key, g.Key, g.Count())).ToList();
        if (projectFilter.Length > 0 && names.All(n => n.Item1 != projectFilter)) names.Insert(0, (projectFilter, projectFilter, 0));
        if (sources.Count > 1 || sourceFilter.Length > 0)
            scopes.Children.Add(ScopeBar.Build("desktopcomputer", L("全部设备"), sources, sourceFilter, id => { sourceFilter = id; DrawRows(); }));
        if (names.Count > 1 || projectFilter.Length > 0)
            scopes.Children.Add(ScopeBar.Build("folder", L("全部项目"), names, projectFilter, name => { projectFilter = name; DrawRows(); }));
        scopes.IsVisible = scopes.Children.Count > 0;
        var bars = scopes.Children.OfType<FilterBar>().ToList();
        if (bars.Count == offsets.Count && offsets.Any(o => o.X > 0))
            Avalonia.Threading.Dispatcher.UIThread.Post(() => { for (var i = 0; i < bars.Count; i++) bars[i].Offset = offsets[i]; }, Avalonia.Threading.DispatcherPriority.Loaded);
    }

    void DrawRows()
    {
        DrawScopes();
        var shownList = Shown;
        // 选中的被筛掉了就不选；筛得只剩一个时直接选上
        var before = selection;
        if (selection is not null && shownList.All(p => p.Id != selection)) selection = null;
        if (selection is null && shownList.Count == 1) selection = shownList[0].Id;
        if (selection != before) Update();
        rows.Children.Clear();
        foreach (var project in shownList)
        {
            var on = project.Id == selection;
            Control? tag = project.Live > 0 ? Tag(L("%lld 个会话", project.Live), "Accent", "IconTile") : project.Open ? Tag(L("已打开"), "Green", "GreenFill13") : null;
            // 机器名 + 路径：路径放不下时截掉前头、留住结尾的项目目录（整句用前缀截断时，中文路径会被截成只剩「虚拟机…」）
            var path = Ui.Text(project.Cwd, 11, color: "Text2");
            path.TextTrimming = TextTrimming.LeadingCharacterEllipsis;
            var sub = Ui.H(0, Ui.Text($"{project.SourceName} · ", 11, color: "Text2"), path.Shrink());
            var line = Ui.H(10, new SessionAvatar(project.Name, "idle", 28),
                Ui.VFill(1, Ui.Text(project.Name, 13, FontWeight.SemiBold).Trim(), sub).Shrink(), new Spacer(6), tag,
                project.LastActive > 0 ? Ui.Text(Format.Short(project.LastActive), 10.5, color: "Text3") : null);
            var id = project.Id;
            var row = new Tap(line.Pad(8, 5), () => { selection = id; DrawRows(); Update(); input.Focus(); }, 6) { BorderThickness = new Thickness(1) };
            // 选中：淡色底 + 一道细边（不用整块饱和色）
            if (on) row.Keys("AccentFill14", "AccentFill14").Res(Border.BorderBrushProperty, "AccentEdge32"); else { row.Keys("Transparent", "Fill05"); row.BorderBrush = Brushes.Transparent; }
            row.Cursor = Cursor.Default;
            rows.Children.Add(row);
        }
        listOverlay.Content = loading ? new Spinner(18)
            : projects.Count == 0 ? Ui.Text(L("暂无使用过 Claude Code 的项目"), 13, color: "Text2")
            : shownList.Count == 0 ? Ui.Text(L("没有匹配的项目"), 13, color: "Text2") : null;
    }

    static Control Tag(string text, string color, string fill) =>
        new Border { Padding = new Thickness(6, 2), CornerRadius = new CornerRadius(9), Child = Ui.Text(text, 10.5, FontWeight.Medium, color) }.Res(Border.BackgroundProperty, fill);

    /// 选了项目、写了字或附了图（只附图时 Claude 收到「请查看我发来的图片」）
    bool CanStart => !sending && Selected is not null && ((input.Text ?? "").Trim().Length > 0 || attached.Count > 0);
    string Timing => timing.Selected;

    void Update()
    {
        var project = Selected;
        input.Watermark = project is null ? L("请先在上方选择项目") : L("请描述需要 Claude 在「%@」中完成的任务", project.Name);
        datePicker.IsVisible = Timing == "once";
        timePicker.IsVisible = Timing != "now";
        isolated.IsEnabled = Timing == "now";
        startLabel.Text = sending ? L("正在新建…") : Timing == "now" ? L("开始") : L("创建定时任务");
        startButton.Opacity = CanStart ? 1 : 0.45;
        startButton.IsHitTestVisible = CanStart;
        var hasMessage = warning.IsVisible && status.Text is { Length: > 0 };
        if (!hasMessage)
        {
            warning.IsVisible = false;
            status.Res(TextBlock.ForegroundProperty, "Text2");
            status.Text = project is null ? "" : project.Open || project.Live > 0 ? L("在已打开的 VS Code 窗口里新建会话")
                : L("将先打开此项目的 VS Code 窗口") + (project.Kind == "ssh" ? L("（Remote-SSH，要十几秒）") : "");
        }
    }

    void ShowMessage(string text)
    {
        warning.IsVisible = true;
        status.Res(TextBlock.ForegroundProperty, "Orange");
        status.Text = text;
    }

    void ClearMessage()
    {
        warning.IsVisible = false;
        status.Text = "";
    }

    // MARK: 图片

    void OnKey(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && e.KeyModifiers.HasFlag(KeyModifiers.Control)) { e.Handled = true; Start(); }
        else if (e.Key == Key.V && e.KeyModifiers.HasFlag(KeyModifiers.Control) && PasteImage()) e.Handled = true;
    }

    bool PasteImage()
    {
        if (window.Clipboard is not { } clipboard) return false;
        var formats = clipboard.GetFormatsAsync().GetAwaiter().GetResult();
        var format = formats.FirstOrDefault(f => f is "image/png" or "PNG" or "image/jpeg" or "Bitmap" or "DeviceIndependentBitmap");
        if (format is null) return false;
        if (clipboard.GetDataAsync(format).GetAwaiter().GetResult() is byte[] data) { Attach([data]); return true; }
        return false;
    }

    void OnDrop(DragEventArgs e)
    {
        if (e.Data.GetFiles() is not { } files) return;
        Attach(files.OfType<IStorageFile>().Select(f => f.TryGetLocalPath()).Where(p => p is not null && IsImage(p)).Select(p => File.ReadAllBytes(p!)).ToList());
    }

    static bool IsImage(string? path) => path is not null && new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic" }.Contains(System.IO.Path.GetExtension(path).ToLowerInvariant());

    async void Pick()
    {
        var files = await window.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = true, Title = L("添加图片"), FileTypeFilter = [FilePickerFileTypes.ImageAll] });
        Attach(files.Select(f => f.TryGetLocalPath()).Where(p => p is not null).Select(p => File.ReadAllBytes(p!)).ToList());
    }

    void Attach(IReadOnlyList<byte[]> list)
    {
        foreach (var data in list)
        {
            if (attached.Count >= MaxImages) break;
            if (ImagePrep.Prepare(data) is { } prepared)
                attached.Add(new ComposeAttachment(Guid.NewGuid().ToString(), $"image-{attached.Count + 1}.jpg", prepared.Jpeg, prepared.Preview));
        }
        DrawImages();
        Update();
    }

    void DrawImages()
    {
        images.Children.Clear();
        images.Margin = attached.Count > 0 ? new Thickness(8, 0, 8, 8) : default;
        foreach (var item in attached.ToList())
        {
            using var stream = new MemoryStream(item.Preview);
            var tile = new Border
            {
                Width = 56, Height = 56, CornerRadius = new CornerRadius(8), ClipToBounds = true,
                Child = new Image { Source = new Bitmap(stream), Stretch = Stretch.UniformToFill }
                    .ZoomOnClick(() => attached.Select(a => a.Data).ToList(), () => Math.Max(0, attached.IndexOf(item))),
            };
            var remove = new Tap(Ui.Sym("xmark", 8, "White").HAlign(HorizontalAlignment.Center), () => { attached.Remove(item); DrawImages(); Update(); }, 8)
            {
                Width = 16, Height = 16, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 3, 3, 0),
            }.Keys("Transparent", "Transparent").Tip(L("移除图片"));
            remove.Background = new SolidColorBrush(Colors.Black, 0.6);
            images.Children.Add(new Panel { Margin = new Thickness(0, 0, 8, 0), Children = { tile, remove } });
        }
    }

    // MARK: 开始

    async void Start()
    {
        if (!CanStart || Selected is not { } project) return;
        sending = true;
        ClearMessage();
        Update();
        var api = AppModel.Shared.Api;
        var text = (input.Text ?? "").Trim();
        try
        {
            if (Timing != "now")
            {
                var time = timePicker.SelectedTime ?? new TimeSpan(9, 0, 0);
                var date = datePicker.SelectedDate?.Date ?? DateTime.Today.AddDays(1);
                var reply = await api.Post("/api/schedules", new JsonObject
                {
                    ["sourceId"] = project.SourceId, ["cwd"] = project.Cwd, ["prompt"] = text, ["repeat"] = Timing,
                    ["time"] = $"{time.Hours:00}:{time.Minutes:00}", ["date"] = date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                });
                AppModel.Shared.Flash(L("已创建：%@", reply.Obj("schedule").Str("label") ?? L("定时任务")));
                window.Close();
                return;
            }
            var started = await api.Post("/api/new-session", new JsonObject
            {
                ["sourceId"] = project.SourceId, ["cwd"] = project.Cwd, ["text"] = text,
                ["images"] = new JsonArray(attached.Select(a => (JsonNode)new JsonObject { ["name"] = a.Name, ["data"] = Convert.ToBase64String(a.Data) }).ToArray()),
                ["override"] = capConfirmed, ["worktree"] = isolated.IsChecked == true,
            });
            AppModel.Shared.AwaitNewSession(project.SourceId, started.Str("cwd") ?? project.Cwd);
            AppModel.Shared.Flash(started.Str("branch") is string branch ? L("已在独立分支 %@ 开始", branch)
                : started.Truthy("submitted") ? L("已开始，等待新会话出现…") : started.Str("message") ?? L("已新建会话"));
            window.Close();
        }
        catch (ApiError e) when (e.Body.Truthy("capExceeded"))
        {
            // 超过每日花费上限：再点一次「开始」才真的开
            capConfirmed = true;
            ShowMessage(L("%@。再次点击「开始」仍将新建。", e.Message));
        }
        catch (Exception e) { ShowMessage(e.Message); }
        finally
        {
            sending = false;
            if (window.IsVisible) Update();
        }
    }
}
