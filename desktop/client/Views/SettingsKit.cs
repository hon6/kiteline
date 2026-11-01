using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.UI;

namespace Kiteline.Views;

/// 设置窗口用的分组表单（同 Mac 的 Form.formStyle(.grouped)）：节标题 → 一张圆角卡片里一行一项（左边文字、右边控件，行间细线）→ 节脚注
public static class Form
{
    /// 一页：上下留白，节之间空一段
    public static StackPanel Page() => new() { Margin = new Thickness(24, 8, 24, 28) };

    public static Control Section(string? header, IEnumerable<Control?> rows, string? footer = null)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        if (header is not null) stack.Children.Add(Ui.Text(header, 13, FontWeight.SemiBold).Margin(10, 0, 10, 8));
        var list = rows.OfType<Control>().ToList();
        if (list.Count > 0)
        {
            var card = new StackPanel();
            for (var i = 0; i < list.Count; i++)
            {
                card.Children.Add(list[i]);
                if (i < list.Count - 1) card.Children.Add(Ui.Rule("Separator", 0.5).Margin(10, 0, 10, 0));
            }
            stack.Children.Add(new Border { CornerRadius = new CornerRadius(10), Child = card }.Res(Border.BackgroundProperty, "Fill05"));
        }
        if (footer is not null) stack.Children.Add(Ui.Text(footer, 12, color: "Text2", lines: 0).Wrap().Margin(10, 8, 10, 0));
        return stack;
    }

    /// 一行：左边文字（可带一行小字），右边控件
    public static Control Row(string label, Control? trailing = null, string? detail = null)
    {
        Control left = detail is null ? Ui.Text(label, 13).Trim()
            : Ui.VFill(2, Ui.Text(label, 13).Trim(), Ui.Text(detail, 11.5, color: "Text2", lines: 3).Wrap());
        var row = Ui.H(12, left.Shrink(), new Spacer(), trailing);
        row.MinHeight = 40;
        return row.Pad(10, 6);
    }

    /// 一整行自定义内容（比如头像 + 名字、主题色网格）
    public static Control Block(Control content) => content.Pad(10, 10);

    public static Control Toggle(string label, bool value, Action<bool> changed, string? detail = null, bool enabled = true)
    {
        var toggle = new MacSwitch(value, changed) { IsEnabled = enabled };
        return Row(label, toggle, detail);
    }

    /// 右边的值（灰字）
    public static Control Value(string label, string value) => Row(label, Ui.Text(value, 13, color: "Text2").Trim());

    /// 小按钮（同 Mac 表单里的 Button：浅灰底）
    public static Tap Button(string title, Action action, bool prominent = false)
    {
        var tap = new Tap(Ui.Text(title, 13, FontWeight.Medium, prominent ? "White" : "Text").HAlign(HorizontalAlignment.Center).Pad(12, 0), action, 6)
        {
            Height = 26, MinWidth = 60,
        };
        if (prominent) tap.Keys("Action", "Action"); else tap.Keys("Fill10", "Fill15");
        return tap;
    }

    /// 文字框（同 Mac 表单的 TextField：右对齐的灰底框）
    public static TextBox Field(string? text, string? watermark = null, double width = 240)
    {
        var box = new TextBox { Text = text, Watermark = watermark, Width = width, FontSize = Look.Pt(13), Padding = new Thickness(8, 4) };
        box.Classes.Add("search");
        return box;
    }
}

/// 开关（同 Mac 的 Toggle.switch）：胶囊底，开着是强调色、关着是灰；白色圆钮
public sealed class MacSwitch : Control
{
    const double W = 36, H = 20;
    bool on;
    readonly Action<bool> changed;

    public MacSwitch(bool on, Action<bool> changed)
    {
        this.on = on;
        this.changed = changed;
        Width = W;
        Height = H;
        Cursor = new Cursor(StandardCursorType.Hand);
        VerticalAlignment = VerticalAlignment.Center;
        PropertyChanged += (_, e) => { if (e.Property == IsEnabledProperty) InvalidateVisual(); };
        ActualThemeVariantChanged += (_, _) => InvalidateVisual();
    }

    public bool IsOn { get => on; set { if (on == value) return; on = value; InvalidateVisual(); } }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (!IsEnabled || e.InitialPressMouseButton != MouseButton.Left) return;
        on = !on;
        InvalidateVisual();
        changed(on);
        e.Handled = true;
    }

    public override void Render(DrawingContext context)
    {
        var track = new Rect(0, 0, W, H);
        context.DrawRectangle(Palette.Get(on ? "Accent" : "Fill15"), null, track, H / 2, H / 2);
        var r = H / 2 - 2;
        var center = new Point(on ? W - H / 2 : H / 2, H / 2);
        context.DrawEllipse(new SolidColorBrush(Colors.Black, 0.18), null, center + new Vector(0, 0.5), r + 0.5, r + 0.5);
        context.DrawEllipse(Brushes.White, null, center, r, r);
        if (!IsEnabled) context.DrawRectangle(new SolidColorBrush(Colors.Gray, 0.35), null, track, H / 2, H / 2);
    }
}
