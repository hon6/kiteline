using System.Diagnostics;
using System.Runtime.InteropServices;
using Avalonia.Threading;

namespace Kiteline.UI;

/// 放一段声音（朗读、手机发来的语音）：一次只放一段，再放别的先停掉上一段。
/// .NET 没有跨平台的播放：Windows 用系统自带的 MCI（mp3、wav 立即能放），它放不了的（手机录的 m4a）交给系统媒体播放器（PowerShell 后台）；
/// Linux 用桌面自带的 gst-play-1.0（各种格式），没有就 pw-play / aplay
public static class Audio
{
    /// 正在放的那段的标识（朗读的消息 id、语音 id）；没在放是 null
    public static string? Playing { get; private set; }
    public static event Action? Changed;
    /// 放不出来（没有音频输出设备、格式打不开……）
    public static event Action? Failed;

    static Process? process;
    static string? file;
    static DispatcherTimer? watch;

    public static void Play(string id, byte[] data, string extension)
    {
        Stop();
        file = Path.Combine(Path.GetTempPath(), $"kiteline-audio-{Environment.ProcessId}{extension}");
        try { File.WriteAllBytes(file, data); }
        catch { return; }
        var ok = OperatingSystem.IsWindows() ? PlayWindows(file) : PlayLinux(file);
        if (!ok) { Failed?.Invoke(); return; }
        Playing = id;
        Changed?.Invoke();
        // 放完了（进程退出 / MCI 报停）就清掉状态；播放程序出错退出的，提示一下
        watch = new DispatcherTimer(TimeSpan.FromMilliseconds(300), DispatcherPriority.Background, (_, _) =>
        {
            if (Busy()) return;
            var failed = process is { HasExited: true, ExitCode: not 0 };
            Stop();
            if (failed) Failed?.Invoke();
        });
        watch.Start();
    }

    public static void Stop()
    {
        watch?.Stop();
        watch = null;
        if (OperatingSystem.IsWindows()) Mci("close kiteline");
        try { if (process is { HasExited: false }) process.Kill(true); } catch { }
        process = null;
        if (Playing is not null) { Playing = null; Changed?.Invoke(); }
    }

    static bool Busy()
    {
        if (process is not null) return !process.HasExited;
        if (!OperatingSystem.IsWindows()) return false;
        var mode = new System.Text.StringBuilder(32);
        return mciSendString("status kiteline mode", mode, mode.Capacity, IntPtr.Zero) == 0 && mode.ToString() == "playing";
    }

    // MARK: Windows

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    static extern int mciSendString(string command, System.Text.StringBuilder? buffer, int size, IntPtr callback);

    static int Mci(string command) { try { return mciSendString(command, null, 0, IntPtr.Zero); } catch { return -1; } }

    static bool PlayWindows(string path)
    {
        var type = path.EndsWith(".wav", StringComparison.OrdinalIgnoreCase) ? "waveaudio" : "mpegvideo";
        if (Mci($"open \"{path}\" type {type} alias kiteline") == 0 && Mci("play kiteline") == 0) return true;
        Mci("close kiteline");
        // MCI 放不了（m4a 等）：系统媒体播放器（Media Foundation）
        // 打不开（没有音频输出设备时一直等不到时长）最多等 5 秒，出错退出
        var script = $"Add-Type -AssemblyName PresentationCore; $p = New-Object System.Windows.Media.MediaPlayer; $p.Open([uri]'{path.Replace("'", "''")}'); " +
                     "Start-Sleep -Milliseconds 400; $p.Play(); $n = 0; while (-not $p.NaturalDuration.HasTimeSpan -and $n -lt 50) { Start-Sleep -Milliseconds 100; $n++ }; " +
                     "if (-not $p.NaturalDuration.HasTimeSpan) { exit 1 }; Start-Sleep -Milliseconds ([int]$p.NaturalDuration.TimeSpan.TotalMilliseconds + 300)";
        return Start("powershell.exe", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", script]);
    }

    // MARK: Linux

    static bool PlayLinux(string path)
    {
        foreach (var (tool, args) in new (string, string[])[] { ("gst-play-1.0", ["--quiet", path]), ("pw-play", [path]), ("aplay", ["-q", path]) })
            if (Which(tool) is string found && Start(found, args)) return true;
        return false;
    }

    static string? Which(string tool) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "/usr/bin").Split(':').Select(dir => Path.Combine(dir, tool)).FirstOrDefault(File.Exists);

    static bool Start(string exe, string[] args)
    {
        try
        {
            var info = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var a in args) info.ArgumentList.Add(a);
            process = Process.Start(info);
            return process is not null;
        }
        catch { process = null; return false; }
    }
}
