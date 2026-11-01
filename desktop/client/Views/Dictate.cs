using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 听写按钮（同 Mac 版 MacDictateButton）：点一下开始录音，说完点「完成」转成文字交给 done（最长 60 秒，到点自动结束）；
/// 录音时显示红点、声波、计时、「完成」和放弃的 ×；转写时显示「正在转写…」。compact = 只画一个麦克风圆圈（单行输入框旁边）
public sealed class DictateButton : ContentControl
{
    const double MaxSeconds = 60;
    readonly bool compact;
    readonly Action<string> done;
    readonly Recorder recorder = new();
    readonly List<double> levels = [];
    DispatcherTimer? timer;
    bool converting;

    public DictateButton(Action<string> done, bool compact = false)
    {
        this.done = done;
        this.compact = compact;
        VerticalAlignment = VerticalAlignment.Center;
        DetachedFromVisualTree += (_, _) => { if (recorder.Recording) { recorder.Stop(cancel: true); timer?.Stop(); } };
        Draw();
    }

    static Tap Chip(Control content, Action action, bool active, bool circle = false)
    {
        var tap = new Tap(content, action, circle ? 11 : 12) { Height = circle ? 22 : 24, Padding = new Thickness(circle ? 0 : 10, 0), BorderThickness = new Thickness(0.5) };
        if (circle) tap.Width = 22;
        tap.Keys(active ? "AccentFill14" : "Fill06", active ? "AccentFill20" : "Fill10").Res(Border.BorderBrushProperty, active ? "AccentEdge32" : "Fill10");
        return tap;
    }

    /// 录音时的声波、计时：界面只搭一次，之后每 0.1 秒只改这两样（整个重搭的话，按下和松开落在不同的按钮上，「完成」点不中）
    Flex? bars;
    TextBlock? clock;

    void Draw()
    {
        if (converting)
        {
            bars = null;
            Content = new Border { Height = 24, Padding = new Thickness(10, 0), CornerRadius = new CornerRadius(12), Child = Ui.H(6, new Spinner(11), Ui.Text(L("正在转写…"), 12, color: "Text2")) }
                .Res(Border.BackgroundProperty, "Fill06");
            return;
        }
        if (recorder.Recording)
        {
            if (bars is null || clock is null)
            {
                bars = Ui.H(2);
                bars.Height = 14;
                for (var i = 0; i < 10; i++)
                    bars.Children.Add(new Border { Width = 2, Height = 3, CornerRadius = new CornerRadius(1), VerticalAlignment = VerticalAlignment.Center }.Res(Border.BackgroundProperty, "Text2"));
                clock = Ui.Text("0:00", 12, color: "Text2").Digits();
                var finish = Chip(Ui.H(6, Ui.Dot(6, "Red"), bars, clock, Ui.Text(L("完成"), 12, FontWeight.Medium)), Finish, active: true)
                    .Tip(L("结束录音并转写为文字"));
                var cancel = Chip(Ui.Sym("xmark", 9, "Text2").HAlign(HorizontalAlignment.Center), Cancel, active: false, circle: true).Tip(L("放弃这段录音"));
                Content = Ui.H(4, finish, cancel);
            }
            var elapsed = (int)recorder.Elapsed;
            clock.Text = $"{elapsed / 60}:{elapsed % 60:00}";
            var shown = levels.TakeLast(10).ToList();
            while (shown.Count < 10) shown.Insert(0, 0);
            for (var i = 0; i < 10; i++) bars.Children[i].Height = 3 + 11 * shown[i];
            return;
        }
        bars = null;
        clock = null;
        Content = compact
            ? Chip(Ui.Sym("mic", 12, "Text").HAlign(HorizontalAlignment.Center), Start, active: false, circle: true).Tip(L("听写：点击开始录音，说完再次点击转写为文字（最长 %@ 秒）", (int)MaxSeconds))
            : Chip(Ui.H(5, Ui.Sym("mic", 12, "Text"), Ui.Text(L("听写"), 12)), Start, active: false).Tip(L("点击开始录音，说完再次点击转写为文字（最长 %@ 秒）", (int)MaxSeconds));
    }

    void Start()
    {
        if (!recorder.Start())
        {
            AppModel.Shared.Flash(OperatingSystem.IsWindows() && Recorder.HasMicrophone()
                ? L("录音未能开始：请在「设置 → 隐私和安全性 → 麦克风」中允许桌面应用使用麦克风") : L("录音未能开始：请确认已连接麦克风"));
            return;
        }
        levels.Clear();
        var tick = 0;
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Normal, (_, _) =>
        {
            tick++;
            var level = recorder.Level();
            // Linux 读不到电平：几根一起轻轻起伏，表示正在录
            levels.Add(level >= 0 ? level : 0.25 + 0.2 * Math.Sin(tick * 0.9));
            if (recorder.Elapsed >= MaxSeconds) Finish();
            else Draw();
        });
        timer.Start();
        Draw();
    }

    async void Finish()
    {
        if (!recorder.Recording) return;
        timer?.Stop();
        var elapsed = recorder.Elapsed;
        var audio = recorder.Stop(cancel: false);
        if (audio is null) { Draw(); AppModel.Shared.Flash(L("录音未能完成，请重试")); return; }
        if (elapsed < 0.8) { Draw(); AppModel.Shared.Flash(L("说话时间太短")); return; }
        converting = true;
        Draw();
        var text = await AppModel.Shared.Transcribe(audio);
        converting = false;
        Draw();
        if (!string.IsNullOrWhiteSpace(text)) done(text.Trim());
        else if (text is not null) AppModel.Shared.Flash(L("未能识别，请重新说一遍"));
    }

    void Cancel()
    {
        timer?.Stop();
        recorder.Stop(cancel: true);
        Draw();
    }

    /// 说出来的话接在已经写的字后面（中间空一格；已经以标点或空白结尾就直接接）
    public static string Append(string said, string? text)
    {
        var current = text ?? "";
        if (current.Trim().Length == 0) return said;
        return char.IsWhiteSpace(current[^1]) || "，。！？、；：,.!?;:".Contains(current[^1]) ? current + said : current + " " + said;
    }
}
