using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Kiteline.Model;
using Kiteline.UI;
using SkiaSharp;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 要发的图：长边缩到 2048 以内（不放大）转成 JPEG 0.85，缩略图 240（同 Mac 版 ImagePrep）
public static class ImagePrep
{
    public static (byte[] Jpeg, byte[] Preview)? Prepare(byte[] data)
    {
        try
        {
            using var bitmap = SKBitmap.Decode(data);
            if (bitmap is null) return null;
            return (Encode(bitmap, 2048, 85), Encode(bitmap, 240, 80));
        }
        catch (Exception) { return null; }
    }

    static byte[] Encode(SKBitmap source, int side, int quality)
    {
        var longest = Math.Max(source.Width, source.Height);
        var scale = longest > side ? (double)side / longest : 1;
        using var resized = scale < 1 ? source.Resize(new SKImageInfo((int)(source.Width * scale), (int)(source.Height * scale)), SKFilterQuality.High) : source.Copy();
        using var image = SKImage.FromBitmap(resized);
        using var encoded = image.Encode(SKEncodedImageFormat.Jpeg, quality);
        return encoded.ToArray();
    }
}

/// 弹出的面板（同 Mac 的面板）：标题、内容（能滚）、右下角「完成」；能拖动、改大小，在会话里弹的对着那一块会话正中打开。
/// scroll = false：内容自己管滚动（看大图）
public static class Sheets
{
    public static Window Show(string title, Control content, double width = 560, double height = 520, IEnumerable<Control>? buttons = null, bool scroll = true)
    {
        var owner = Dialog.Owner() ?? MainWindow.Current;
        var window = new Window
        {
            Title = title, Width = width, Height = height, MinWidth = 360, MinHeight = 240, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false, CanResize = true, FontFamily = Look.Family,
        };
        window.Res(Window.BackgroundProperty, "Sheet");
        var done = new GlassButton(L("完成"), null, window.Close, prominent: true, height: 30);
        var footer = Ui.H(8, new Spacer(), buttons is null ? null : Ui.Stack(Orientation.Horizontal, 8, Align.Center, buttons), done).Pad(16, 12);
        var header = Ui.Text(title, 15, FontWeight.SemiBold).Pad(20, 16, 20, 8);
        var dock = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(footer, Dock.Bottom);
        dock.Children.Add(header);
        dock.Children.Add(footer);
        dock.Children.Add(scroll ? new ScrollViewer { Content = content.Pad(20, 4, 20, 8) } : content);
        window.Content = dock;
        window.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Escape) window.Close(); };
        Dialog.ShowPlaced(window, owner);
        return window;
    }

    public static Window Text(string title, string text) => Show(title, ToolDetail.MonoBlock(text));
}

/// 朗读（Mac 版在每条回复下面有个小喇叭）：交给后台合成（/api/tts），本机播放
public static class Speaker
{
    static Speaker()
    {
        Audio.Failed += () => AppModel.Shared.Flash(L("无法播放声音，请检查这台电脑的扬声器或耳机"));
    }

    /// 朗读一条回复：再点一下停；正在放别的就换成这条。声音由后台合成（微软语音 / Windows 自带语音），设置里可选声音和语速
    public static async void Toggle(string text, string id)
    {
        var tag = "tts:" + id;
        if (Audio.Playing == tag) { Audio.Stop(); return; }
        var plain = Markdown.Plain(text).Trim();
        if (plain.Length == 0) return;
        if (plain.Length > 1500) plain = plain[..1500];
        try
        {
            var body = new System.Text.Json.Nodes.JsonObject { ["text"] = plain, ["rate"] = Prefs.Number("ttsRate") ?? 1 };
            if (Prefs.String("ttsVoice") is { Length: > 0 } voice) body["voice"] = voice;
            var data = await AppModel.Shared.Api.PostData("/api/tts", body);
            Audio.Play(tag, data, Extension(data));
        }
        catch (Exception e) { AppModel.Shared.Flash(L("朗读失败：%@", e.Message)); }
    }

    /// 放手机发来的语音（再点一下停）
    public static async void PlayVoice(string id)
    {
        var tag = "voice:" + id;
        if (Audio.Playing == tag) { Audio.Stop(); return; }
        try
        {
            var data = await AppModel.Shared.Api.MediaData("/api/voice-audio", new Dictionary<string, string> { ["id"] = id });
            Audio.Play(tag, data, Extension(data));
        }
        catch (Exception e) { AppModel.Shared.Flash(L("无法播放语音：%@", e.Message)); }
    }

    /// 按文件头认格式（播放器靠扩展名选解码）
    static string Extension(byte[] d) =>
        d.Length > 12 && d[0] == 'R' && d[1] == 'I' && d[2] == 'F' && d[3] == 'F' ? ".wav"
        : d.Length > 12 && d[4] == 'f' && d[5] == 't' && d[6] == 'y' && d[7] == 'p' ? ".m4a"
        : d.Length > 4 && d[0] == 'O' && d[1] == 'g' && d[2] == 'g' && d[3] == 'S' ? ".ogg"
        : d.Length > 4 && d[0] == 0x1A && d[1] == 0x45 ? ".webm"
        : ".mp3";
}

