using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Kiteline.UI;

/// 录一段话（听写用）：16 kHz 单声道 WAV，交给本机 Kiteline 后台转文字（Fun-ASR-Nano）。
/// Windows 用系统自带的 MCI 录音；Linux 用 PipeWire 的 pw-record，没有就 arecord（Ctrl+C 一样的信号停，文件头才写得完整）
public sealed class Recorder
{
    readonly string file = Path.Combine(Path.GetTempPath(), $"kiteline-dictate-{Environment.ProcessId}.wav");
    Process? process;
    DateTime started;

    public bool Recording { get; private set; }
    public double Elapsed => Recording ? (DateTime.Now - started).TotalSeconds : 0;

    public bool Start()
    {
        try { File.Delete(file); } catch { }
        if (OperatingSystem.IsWindows())
        {
            Mci("close klrec");
            if (Mci("open new type waveaudio alias klrec") != 0) return false;
            Mci("set klrec bitspersample 16 channels 1 samplespersec 16000 alignment 2 bytespersec 32000");
            if (Mci("record klrec") != 0) { Mci("close klrec"); return false; }
        }
        else
        {
            var tools = new (string Tool, string[] Args)[]
            {
                ("pw-record", ["--rate", "16000", "--channels", "1", "--format", "s16", file]),
                ("arecord", ["-q", "-f", "S16_LE", "-r", "16000", "-c", "1", file]),
            };
            // 客户端被强制结束时录音程序不会跟着停：套一层 timeout，最长录 70 秒（界面上限 60 秒）自己收尾退出
            var limit = Which("timeout");
            foreach (var (tool, args) in tools)
            {
                if (Which(tool) is not string exe) continue;
                try
                {
                    var info = new ProcessStartInfo(limit ?? exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
                    if (limit is not null) foreach (var a in new[] { "--signal=INT", "70", exe }) info.ArgumentList.Add(a);
                    foreach (var a in args) info.ArgumentList.Add(a);
                    process = Process.Start(info);
                    if (process is not null) break;
                }
                catch { process = null; }
            }
            if (process is null) return false;
        }
        started = DateTime.Now;
        Recording = true;
        return true;
    }

    /// 停下：cancel = 不要这段；返回录好的 WAV
    public byte[]? Stop(bool cancel)
    {
        if (!Recording) return null;
        Recording = false;
        if (OperatingSystem.IsWindows())
        {
            Mci("stop klrec");
            if (!cancel) Mci($"save klrec \"{file}\"");
            Mci("close klrec");
        }
        else if (process is not null)
        {
            try
            {
                if (!process.HasExited) kill(process.Id, 2);   // SIGINT：录音程序收尾、写好文件头再退
                if (!process.WaitForExit(1500)) process.Kill();
            }
            catch { }
            process = null;
        }
        if (cancel) return null;
        try { return File.ReadAllBytes(file); } catch { return null; }
        finally { try { File.Delete(file); } catch { } }
    }

    /// 现在的音量（0～1，画声波用）：Windows 读 MCI 的电平，Linux 没有就返回 -1（界面改成一起跳动）
    public double Level()
    {
        if (!Recording || !OperatingSystem.IsWindows()) return -1;
        var buffer = new StringBuilder(32);
        return mciSendString("status klrec level", buffer, buffer.Capacity, IntPtr.Zero) == 0 && int.TryParse(buffer.ToString(), out var v)
            ? Math.Min(1, v / 64.0) : -1;
    }

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    static extern int mciSendString(string command, StringBuilder? buffer, int size, IntPtr callback);

    [DllImport("winmm.dll")]
    static extern uint waveInGetNumDevs();

    /// Windows 上有没有录音设备（没有 = 没接麦克风；有却录不了多半是隐私设置没允许）
    public static bool HasMicrophone()
    {
        if (!OperatingSystem.IsWindows()) return true;
        try { return waveInGetNumDevs() > 0; } catch { return true; }
    }

    [DllImport("libc", SetLastError = true)]
    static extern int kill(int pid, int signal);

    static int Mci(string command) { try { return mciSendString(command, null, 0, IntPtr.Zero); } catch { return -1; } }

    static string? Which(string tool) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "/usr/bin").Split(':').Select(dir => Path.Combine(dir, tool)).FirstOrDefault(File.Exists);
}
