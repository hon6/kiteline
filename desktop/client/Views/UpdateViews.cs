using System.ComponentModel;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 侧栏底栏里的绿色向上箭头（同 Mac 版，手机数和右边几个图标中间）：只在有新版本、下载中、装好待重启时出现，没有更新时不占地方；
/// 下载中外圈一道进度；点开更新弹窗
public sealed class UpdateButton : Tap
{
    readonly Ring ring;

    public UpdateButton(double size = 28) : base(null, UpdateDialog.Open, size / 2)
    {
        Width = size;
        Height = size;
        // 和底栏其他按钮一样，点的范围至少 32×32
        Margin = new Thickness(Math.Max(0, (32 - size) / 2));
        ring = new Ring(size);
        var arrow = Ui.Sym("arrow.up", size * 0.46, "White");
        arrow.FontWeight = FontWeight.Bold;
        arrow.HorizontalAlignment = HorizontalAlignment.Center;
        Child = new Panel { Children = { arrow, ring } };
        Keys("Green", "GreenHover", "GreenPressed");
        var state = UpdateState.Shared;
        AttachedToVisualTree += (_, _) => { state.PropertyChanged += Changed; Update(state); };
        DetachedFromVisualTree += (_, _) => state.PropertyChanged -= Changed;
        Update(state);
    }

    void Changed(object? sender, PropertyChangedEventArgs e) => Update(UpdateState.Shared);

    void Update(UpdateState state)
    {
        IsVisible = state.Visible;
        ring.Value = state.Phase == "downloading" ? state.Progress : -1;
        ToolTip.SetTip(this, state.Phase switch
        {
            "ready" => L("新版本已安装，轻点重启以完成更新"),
            "downloading" => L("正在下载 Kiteline %@（%@）", state.Version, $"{(int)(state.Progress * 100)}%"),
            "installing" => L("正在安装 Kiteline %@…", state.Version),
            _ => L("有新版本：Kiteline %@", state.Version),
        });
    }

    /// 下载进度：按钮外圈一道白弧
    sealed class Ring(double size) : Control
    {
        double value = -1;
        public double Value { set { if (this.value == value) return; this.value = value; InvalidateVisual(); } }

        public override void Render(DrawingContext context)
        {
            if (value < 0) return;
            var r = size / 2 - 2;
            var center = new Point(size / 2, size / 2);
            context.DrawEllipse(null, new Pen(new SolidColorBrush(Colors.White, 0.3), 2), center, r, r);
            if (value <= 0) return;
            var sweep = Math.Min(359.9, value * 360);
            var end = sweep * Math.PI / 180 - Math.PI / 2;
            var geometry = new StreamGeometry();
            using (var g = geometry.Open())
            {
                g.BeginFigure(new Point(center.X, center.Y - r), false);
                g.ArcTo(new Point(center.X + r * Math.Cos(end), center.Y + r * Math.Sin(end)), new Avalonia.Size(r, r), 0, sweep > 180, SweepDirection.Clockwise);
            }
            context.DrawGeometry(null, new Pen(Brushes.White, 2, lineCap: PenLineCap.Round), geometry);
        }
    }
}

/// 更新弹窗（同 Mac 版的更新确认框）：新版本号、大小、更新说明 → 下载并安装（进度条）→ 装好后「立即重启 / 稍后」。
/// 一个窗口跟着状态变，不会叠好几个
public sealed class UpdateDialog : Window
{
    static UpdateDialog? shown;
    /// 自测截图用
    public static Window? Current => shown;

    readonly TextBlock title = Ui.Text("", 15, FontWeight.Bold).HAlign(HorizontalAlignment.Center);
    readonly TextBlock detail = Ui.Text("", 12.5, color: "Text2", lines: 0).Wrap();
    readonly TextBlock notesText = Ui.Text("", 12.5, lines: 0).Wrap();
    readonly Border notes;
    readonly ProgressBar bar = new() { Height = 6, Minimum = 0, Maximum = 1, CornerRadius = new CornerRadius(3) };
    readonly ContentControl buttons = new();

    public static void Open()
    {
        if (shown is not null) { shown.Activate(); return; }
        shown = new UpdateDialog();
        shown.Closed += (_, _) => shown = null;
        Dialog.ShowPlaced(shown, Dialog.Owner());
    }

    UpdateDialog()
    {
        Title = "Kiteline";
        Width = 420;
        SizeToContent = SizeToContent.Height;
        CanResize = true;
        MinWidth = 360;
        MinHeight = 160;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = Look.Family;
        this.Res(BackgroundProperty, "Sheet");
        Dialog.Chromeless(this);
        detail.TextAlignment = TextAlignment.Center;
        notes = new Border
        {
            CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 10), MaxHeight = 220,
            Child = new ScrollViewer { Content = notesText, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled },
        }.Res(Border.BackgroundProperty, "Fill05");
        bar.Res(ProgressBar.ForegroundProperty, "Green").Res(ProgressBar.BackgroundProperty, "Fill10");
        var stack = new StackPanel
        {
            Spacing = 12,
            Children = { new KiteIcon(64).HAlign(HorizontalAlignment.Center), title, detail, notes, bar, buttons },
        };
        Content = stack.Pad(22, 20, 22, 20);
        KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Escape) Close(); };
        var state = UpdateState.Shared;
        void Changed(object? s, PropertyChangedEventArgs e) => Draw();
        state.PropertyChanged += Changed;
        Closed += (_, _) => state.PropertyChanged -= Changed;
        Draw();
    }

    string? drawn;

    void Draw()
    {
        var s = UpdateState.Shared;
        notes.IsVisible = false;
        bar.IsVisible = false;
        bar.IsIndeterminate = false;
        var key = $"{s.Phase}|{s.Supported}";
        Control? Buttons(string secondary, Action secondaryAction, string? primary = null, Action? primaryAction = null) =>
            primary is null
                ? PromptCard.CardButton(secondary, true, secondaryAction)
                : new ButtonPair(PromptCard.CardButton(secondary, false, secondaryAction), PromptCard.CardButton(primary, true, primaryAction!));
        if (!s.Supported && s.Phase == "available")
        {
            title.Text = L("Kiteline %@ 可用", s.Version);
            detail.Text = L("%@，请到官网下载新版本。", L(s.Reason));
            ShowNotes(s.Notes);
            if (key != drawn) buttons.Content = Buttons(L("以后再说"), Close, L("打开下载页"), () => { s.OpenPage(); Close(); });
        }
        else switch (s.Phase)
        {
            case "available":
                title.Text = L("Kiteline %@ 可用", s.Version);
                detail.Text = L("当前版本 %@", s.Current) + (s.Size > 0 ? " · " + Megabytes(s.Size) : "") + "\n" + L("下载后在后台自动安装，装好后重启即可。");
                ShowNotes(s.Notes);
                if (key != drawn) buttons.Content = Buttons(L("以后再说"), () => { _ = s.Later(); Close(); }, L("下载并安装"), () => _ = s.Begin());
                break;
            case "downloading":
                title.Text = L("正在下载 Kiteline %@", s.Version);
                detail.Text = s.Size > 0 ? $"{Megabytes(s.Received)} / {Megabytes(s.Size)}" : Megabytes(s.Received);
                bar.IsVisible = true;
                bar.Value = s.Progress;
                if (key != drawn) buttons.Content = Buttons(L("取消下载"), () => _ = s.Cancel(), L("在后台下载"), Close);
                break;
            case "installing":
                title.Text = L("正在安装 Kiteline %@", s.Version);
                detail.Text = L("安装在后台进行，不影响使用。");
                bar.IsVisible = true;
                bar.IsIndeterminate = true;
                if (key != drawn) buttons.Content = Buttons(L("隐藏"), Close);
                break;
            case "ready":
                title.Text = L("新版本已安装");
                detail.Text = L("重启 Kiteline 后生效，正在进行的会话不受影响。");
                if (key != drawn) buttons.Content = Buttons(L("稍后"), Close, L("立即重启"), () => _ = s.Restart());
                break;
            case "restarting":
                title.Text = L("正在重启 Kiteline…");
                detail.Text = L("新版本启动后会自动打开。");
                bar.IsVisible = true;
                bar.IsIndeterminate = true;
                buttons.Content = null;
                break;
            case "error":
                title.Text = L("更新失败");
                detail.Text = L(s.Error.Length > 0 ? s.Error : "更新失败");
                if (key != drawn) buttons.Content = Buttons(L("关闭"), Close, L("重试"), () => _ = s.Begin());
                break;
            case "checking":
                title.Text = L("正在检查更新…");
                detail.Text = "";
                bar.IsVisible = true;
                bar.IsIndeterminate = true;
                buttons.Content = null;
                break;
            default:
                title.Text = L("已是最新版本");
                detail.Text = L("当前版本 %@", s.Current);
                if (key != drawn) buttons.Content = Buttons(L("好"), Close);
                break;
        }
        drawn = key;
    }

    void ShowNotes(string text)
    {
        notesText.Text = text.Trim();
        notes.IsVisible = notesText.Text.Length > 0;
    }

    static string Megabytes(long bytes) =>
        bytes >= 1 << 20 ? (bytes / 1048576.0).ToString("0.0", CultureInfo.InvariantCulture) + " MB" : Math.Max(1, bytes / 1024) + " KB";
}
