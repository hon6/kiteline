using System.IO.Pipes;
using Avalonia.Controls;
using Avalonia.Threading;

namespace Kiteline.UI;

/// 客户端只开一个：再打开一次（托盘「打开 Kiteline」、开始菜单、双击）时，把已经开着的窗口叫到前面，新开的这份直接退出。
/// 用本用户的命名管道传话（Linux 上 .NET 用 Unix 套接字实现）
public static class SingleInstance
{
    static string PipeName => "kiteline-client-" + Environment.UserName;

    /// 已经有一份在跑：让它到前面来（带着提示词链接的，让它弹「新任务」），返回 true（这份该退出了）
    public static bool ActivateExisting(string? link = null)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            client.Connect(300);
            using var writer = new StreamWriter(client);
            writer.WriteLine(link is null ? "show" : "open " + link);
            writer.Flush();
            return true;
        }
        catch { return false; }
    }

    /// 等别的实例传话（后台线程）
    public static void Listen()
    {
        var thread = new Thread(() =>
        {
            while (true)
            {
                try
                {
                    using var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.CurrentUserOnly);
                    server.WaitForConnection();
                    using var reader = new StreamReader(server);
                    var line = reader.ReadLine();
                    if (line == "show") Dispatcher.UIThread.Post(Show);
                    else if (line?.StartsWith("open ") == true) Dispatcher.UIThread.Post(() => { Show(); Model.PromptLinks.Handle(line[5..]); });
                }
                catch { Thread.Sleep(1000); }
            }
        }) { IsBackground = true, Name = "single-instance" };
        thread.Start();
    }

    static void Show()
    {
        if (Views.MainWindow.Current is not Window window) return;
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Show();
        window.Activate();
        window.Topmost = true;
        window.Topmost = false;
    }
}
