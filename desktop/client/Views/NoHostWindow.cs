using Avalonia.Controls;
using Kiteline.Net;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 找不到本机的 Kiteline 后台（没装、没运行过）：说明一下
public sealed class NoHostWindow : Window
{
    public NoHostWindow()
    {
        Title = "Kiteline";
        Width = 520;
        Height = 320;
        this.Res(BackgroundProperty, "Window");
        Content = Empty.State("exclamationmark.triangle", L("未找到 Kiteline 后台"),
            L("请先运行一次 Kiteline（会在托盘里常驻），再打开主窗口。配置目录：%@", LocalHost.ConfigDirectory()));
    }
}
