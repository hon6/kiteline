using System.Text.Json;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 一串连续的步骤（思考、工具调用），装在一张卡片里；很多步时前面的折成一行（同 Mac 版 StepsCard）
public static class StepsCard
{
    public static Control Make(string key, StepsRow row)
    {
        var stack = new StackPanel();
        if (row.Hidden > 0)
        {
            var expand = Ui.H(6, Ui.Sym("ellipsis", ChatType.Size, "Text2").Width(16), Ui.Text(L("展开前 %@ 步", row.Hidden), ChatType.Size, color: "Text2"),
                new Spacer(), Ui.Sym("chevron.down", ChatType.Size * 0.75, "Text2"));
            stack.Children.Add(new Tap(expand.Pad(ChatType.PadH, ChatType.Px(4)), () =>
            {
                var chat = AppModel.Shared.Chat(key);
                chat.Expanded.Add(row.HeadId);
                chat.Touch();
            }, 0).Keys("Transparent", "Fill05"));
        }
        // 结果带图的（读图片、截图）图直接显示在那一步下面；点开看大图时，这张卡片里所有步骤的图左右滑着连着看
        var gallery = row.Steps.SelectMany(s => s.Result?.Images ?? []).ToList();
        foreach (var step in row.Steps.Skip(row.Hidden)) stack.Children.Add(new StepRow(key, step, gallery));
        var card = Ui.Box(stack, new Thickness(0, ChatType.Px(4)), "BotBubble", ChatType.Radius);
        card.HorizontalAlignment = HorizontalAlignment.Stretch;
        return card;
    }
}

/// 一步：照 VS Code，工具名粗体、和正文一样大；后面的参数 0.85em 等宽；思考是灰色斜体，点一下展开原文
public sealed class StepRow : StackPanel
{
    readonly Step step;
    bool expanded;
    readonly Control? detail;

    public StepRow(string key, Step step, IReadOnlyList<ChatImage>? gallery = null)
    {
        this.step = step;
        var item = step.Item;
        var name = item.T switch { "thinking" => L("思考"), "result" => L("结果"), _ => Tools.DisplayName(item.Name) };
        var brief = item.T == "tool" ? Tools.Brief(item) : (item.Text ?? "").Trim().Split('\n')[0];
        var briefText = Ui.Text(brief, item.T == "tool" ? ChatType.DetailSize : ChatType.Size, color: "Text2").Shrink();
        if (item.T == "tool") briefText.FontFamily = Look.Mono; else briefText.FontStyle = FontStyle.Italic;
        var stat = item.T == "tool" ? Tools.DiffStat(item) : null;
        var chevron = Ui.Sym(item.T == "thinking" ? "chevron.right" : "chevron.right", ChatType.Size * 0.75, "Text3");
        chevron.FontWeight = FontWeight.SemiBold;
        var line = Ui.H(6,
            new StateIcon(step).Width(16),
            Ui.Text(name, ChatType.Size, FontWeight.Bold),
            briefText,
            new Spacer(4),
            stat is { } s ? Ui.H(3, Ui.Text($"+{s.Added}", ChatType.DetailSize, color: "Added").Mono(), Ui.Text($"−{s.Removed}", ChatType.DetailSize, color: "Removed").Mono()) : null,
            chevron);
        var tap = new Tap(line.Pad(ChatType.PadH, ChatType.Px(4)), null, 0).Keys("Transparent", "Fill05");
        Children.Add(tap);
        if (item.T == "thinking" && item.Text is string text)
        {
            // 展开的思考内容和正文一样大、灰色；左边和标题文字对齐（图标 16 + 间隔 6）
            detail = new RichText(text, ChatType.Size, color: "Text2") { Margin = new Thickness(ChatType.PadH + 22, ChatType.Px(2), ChatType.PadH, ChatType.Px(6)), IsVisible = false };
            Children.Add(detail);
            tap.Click = () =>
            {
                expanded = !expanded;
                detail.IsVisible = expanded;
                chevron.Symbol = expanded ? "chevron.down" : "chevron.right";
            };
        }
        else tap.Click = () => ToolDetail.Show(key, step);
        if (item.T == "tool" && step.Result?.Images is { Count: > 0 } images)
        {
            // 读图片、截图这类工具：结果里的图直接显示，不用点开这一步才看得到；左边和标题文字对齐
            Children.Add(new MessageImages(key, images, gallery)
            {
                Margin = new Thickness(ChatType.PadH + 22, ChatType.Px(2), ChatType.PadH, ChatType.Px(6)), HorizontalAlignment = HorizontalAlignment.Left,
            });
        }
    }
}

/// 步骤左边的图标（同 Mac 版 StateIcon）：没状态时是工具图标（思考是小纸鸢）；在跑一闪一闪的点、等你确认橙点、成功绿点、出错红点
public sealed class StateIcon : Panel
{
    public StateIcon(Step step)
    {
        Height = ChatType.Size * 1.5;
        Control icon = step.State switch
        {
            StepState.Running => new PulseDot("Accent", 7),
            StepState.Waiting => Ui.Dot(7, "Orange"),
            StepState.Ok => Ui.Dot(7, "Added"),
            StepState.Failed => Ui.Dot(7, "Removed"),
            _ when step.Item.T == "thinking" => new KiteGlyph(ChatType.Size * 1.15),
            _ => Ui.Sym(Tools.Symbol(step.Item.Name), ChatType.Size * 0.85, "Text2"),
        };
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(icon);
    }
}

/// 一闪一闪的小圆点（运行中的步骤、子 agent）
public sealed class PulseDot : Control
{
    readonly string color;
    readonly double size;
    double t;
    DispatcherTimer? timer;

    public PulseDot(string color, double size)
    {
        this.color = color;
        this.size = size;
        Width = size;
        Height = size;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(50), DispatcherPriority.Render, (_, _) => { t += 0.05; InvalidateVisual(); });
        timer.Start();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e) { base.OnDetachedFromVisualTree(e); timer?.Stop(); }

    public override void Render(DrawingContext context)
    {
        // 0.7 秒一来回，最暗 0.25
        var phase = t / 0.7 % 2;
        var x = phase < 1 ? phase : 2 - phase;
        var alpha = 0.25 + 0.75 * (1 - x);
        var c = Palette.GetColor(color);
        context.DrawEllipse(new SolidColorBrush(Color.FromArgb((byte)(alpha * c.A), c.R, c.G, c.B)), null, new Rect(0, 0, size, size));
    }
}

/// 静止的小纸鸢（思考那一步的图标；头像里的纸鸢给 brush 换颜色）
public sealed class KiteGlyph : Control
{
    readonly double size;
    readonly IBrush? brush;
    public KiteGlyph(double size, IBrush? brush = null) { this.size = size; this.brush = brush; Width = size; Height = size; }
    public override void Render(DrawingContext context) => KiteMark.DrawStill(context, new Rect(0, 0, size, size), brush ?? Palette.Get("Accent"));
}

/// 点开一步：参数（命令、改动、计划……）+ 结果（同 Mac 版 ToolDetailView）
public static class ToolDetail
{
    public static void Show(string key, Step step)
    {
        var item = step.Item;
        var title = item.T == "result" ? L("工具结果") : item.T == "thinking" ? L("思考")
            : Tools.DisplayName(item.Name) + (Tools.Brief(item) is { Length: > 0 } b ? " · " + b : "");
        var stack = new StackPanel { Spacing = 16 };
        if (item.T == "tool") stack.Children.Add(Input(item));
        if (item.T == "thinking") stack.Children.Add(Section(L("思考"), MonoBlock(item.Text ?? "")));
        else stack.Children.Add(Result(key, step.Result));
        Sheets.Show(title, stack, 640, 560);
    }

    public static Control Section(string title, Control content) =>
        new StackPanel { Spacing = 6, Children = { Ui.Text(title.ToUpperInvariant(), 12, color: "Text2"), content } };

    /// 等宽文字块（命令、输出、思考原文）
    public static Control MonoBlock(string text, bool error = false)
    {
        var t = new SelectableTextBlock { Text = text.Length == 0 ? " " : text, FontFamily = Look.Mono, FontSize = Look.Pt(12.5), TextWrapping = TextWrapping.Wrap };
        t.Res(TextBlock.ForegroundProperty, error ? "Removed" : "Text").Res(SelectableTextBlock.SelectionBrushProperty, "AccentFill20");
        return CopyCorner.Wrap(Ui.Box(t, new Thickness(10), "Code", 9).HAlign(HorizontalAlignment.Stretch), text, 5);
    }

    static Control Input(ChatItem item)
    {
        var input = item.Input;
        string Field(string k) => input.Str(k) ?? "";
        switch (item.Name ?? "")
        {
            case "Bash": return Section(Field("description").Length == 0 ? L("命令") : Field("description"), MonoBlock(Field("command")));
            case "Edit": return Section(L("修改"), new DiffView(Field("file_path"), Field("old_string"), Field("new_string")));
            case "MultiEdit":
                var edits = new StackPanel { Spacing = 8 };
                var first = true;
                foreach (var e in input.Arr("edits").Items())
                {
                    edits.Children.Add(new DiffView(first ? Field("file_path") : "", e.Str("old_string") ?? "", e.Str("new_string") ?? ""));
                    first = false;
                }
                return Section(L("修改"), edits);
            case "Write": return Section(L("写入文件"), new DiffView(Field("file_path"), "", Field("content"), 300));
            case "Read":
                var offset = Field("offset"); var limit = Field("limit");
                return Section(L("读取"), MonoBlock(Field("file_path") + (offset.Length == 0 ? "" : L("\n从第 %@ 行", offset) + (limit.Length == 0 ? "" : L("起 %@ 行", limit)))));
            case "Grep" or "Glob":
                var lines = new[] { Field("pattern").Length == 0 ? null : L("模式：%@", Field("pattern")), Field("path").Length == 0 ? null : L("位置：%@", Field("path")),
                                    Field("glob").Length == 0 ? null : L("文件：%@", Field("glob")) }.Where(x => x is not null);
                return Section(L("搜索"), MonoBlock(string.Join("\n", lines)));
            case "WebFetch" or "WebSearch":
                return Section(L("网络"), MonoBlock(string.Join("\n\n", new[] { Field("url"), Field("query"), Field("prompt") }.Where(x => x.Length > 0))));
            case "Task" or "Agent": return Section(Field("description").Length == 0 ? L("子任务") : Field("description"), new MarkdownView(Field("prompt")));
            case "AskUserQuestion":
                var qs = new StackPanel { Spacing = 12 };
                foreach (var q in input.Arr("questions").Items())
                {
                    var block = new StackPanel { Spacing = 6 };
                    block.Children.Add(Ui.Text(q.Str("question") ?? "", 14, FontWeight.SemiBold, lines: 0).Wrap());
                    var n = 0;
                    foreach (var o in q.Arr("options").Items())
                    {
                        n++;
                        block.Children.Add(Ui.Text($"{n}. {o.Str("label")}", 14, lines: 0).Wrap());
                        if (o.Str("description") is { Length: > 0 } d) block.Children.Add(Ui.Text(d, 12, color: "Text2", lines: 0).Wrap());
                    }
                    qs.Children.Add(Section(q.Str("header") ?? L("提问"), block));
                }
                return qs;
            case "ExitPlanMode": return Section(L("计划"), new MarkdownView(Field("plan")));
            case "TodoWrite": return Section(L("任务清单"), TodoCard.Make(input.Arr("todos").Items().ToList()));
            default: return Section(L("参数"), MonoBlock(input?.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) ?? ""));
        }
    }

    static Control Result(string key, ChatItem? result)
    {
        if (result is null) return Section(L("结果"), Ui.Text(L("暂无结果"), 12, color: "Text2"));
        var stack = new StackPanel { Spacing = 8 };
        if (result.Text is { Length: > 0 } text) stack.Children.Add(MonoBlock(text, result.IsError == true));
        if (result.Images is { Count: > 0 } images) stack.Children.Add(new MessageImages(key, images));
        if ((result.Text ?? "").Length == 0 && (result.Images?.Count ?? 0) == 0) stack.Children.Add(Ui.Text(L("（无输出）"), 12, color: "Text2"));
        if (result.Truncated == true) stack.Children.Add(Ui.Text(L("仅显示部分内容，完整输出共 %@ 字", result.FullLength?.ToString() ?? "?"), 12, color: "Text2"));
        return Section(result.IsError == true ? L("出错") : L("结果"), stack);
    }
}

/// 改动：删的红、加的绿（同 Mac 版 DiffView）
public sealed class DiffView : Border
{
    public DiffView(string path, string old, string @new, int limit = 2000)
    {
        CornerRadius = new CornerRadius(9);
        ClipToBounds = true;
        BorderThickness = new Thickness(1);
        this.Res(BorderBrushProperty, "Fill08");
        var stack = new StackPanel();
        if (path.Length > 0)
            stack.Children.Add(Ui.Box(Ui.Text(path, 11.5, color: "Text2").Mono(), new Thickness(10, 6), "Fill05").HAlign(HorizontalAlignment.Stretch));
        var oldLines = old.Length == 0 ? [] : old.Split('\n');
        var newLines = @new.Length == 0 ? [] : @new.Split('\n');
        foreach (var line in oldLines.Take(limit)) stack.Children.Add(Line(line, "-", "Removed"));
        foreach (var line in newLines.Take(limit)) stack.Children.Add(Line(line, "+", "Added"));
        if (newLines.Length > limit) stack.Children.Add(Ui.Text(L("…共 %@ 行", newLines.Length), 11.5, color: "Text2").Pad(8));
        Child = stack;
    }

    static Control Line(string text, string sign, string color)
    {
        var t = new TextBlock { Text = $"{sign} {text}", FontFamily = Look.Mono, FontSize = Look.Pt(12), TextWrapping = TextWrapping.Wrap };
        t.Res(TextBlock.ForegroundProperty, color);
        var box = new Border { Child = t, Padding = new Thickness(10, 1) };
        box.Background = new SolidColorBrush(Palette.GetColor(color), 0.1);
        return box;
    }
}
