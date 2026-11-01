using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using static Kiteline.Lang;

namespace Kiteline.Model;

/// 「VS Code 在虚拟屏幕中运行」（同 Mac 版 VirtualScreen）：开关和窗口在本机后台管（/api/desktop/vscreen，见 kiteline/vscreen.py），
/// 这里是客户端看到的状态：侧栏底栏的显示器按钮、设置 → 通用里的开关都看它
public sealed partial class VirtualScreenState : ObservableObject
{
    public static VirtualScreenState Shared { get; } = new();

    [ObservableProperty] bool supported;
    [ObservableProperty] bool on;
    [ObservableProperty] int windows;
    /// Linux：Kiteline 的 GNOME 扩展还没装好 / 还没生效（点开关会先装，注销重新登录一次后自动打开）
    [ObservableProperty] string note = "";

    /// 后台的状态（/api/desktop/status 里的 virtualScreen，或开关的结果）
    public void Apply(JsonNode? state)
    {
        if (state?["supported"] is null) return;
        Supported = state.Truthy("supported");
        On = state.Truthy("on");
        Windows = state.Int("windows") ?? 0;
        Note = state.Str("note") ?? "";
    }

    /// 按钮的说明（鼠标停上去显示）
    public string Help => On ? L("VS Code 正在虚拟屏幕中运行（%@ 个窗口）：点击移回主屏幕", Windows)
        : L("将 VS Code 移到虚拟屏幕：Kiteline 发送消息时，VS Code 不会出现在你面前") + (Note.Length > 0 ? "\n" + L(Note) : "");

    /// 开着就移回主屏幕，关着就移过去（on 指定就照它）；结果浮一条提示
    public async void Toggle(bool? on = null)
    {
        try
        {
            var body = new JsonObject();
            if (on is bool value) body["on"] = value;
            var result = await AppModel.Shared.Api.Post("/api/desktop/vscreen", body);
            Apply(result);
            AppModel.Shared.Flash(Message(result));
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
    }

    static string Message(JsonNode? r)
    {
        if (!r.Truthy("ok")) return L(r.Str("error") ?? "无法移到虚拟屏幕");
        if (r?["restored"] is not null)
            return (r.Int("restored") ?? 0) is var restored and > 0 ? L("已将 %@ 个 VS Code 窗口移回主屏幕", restored) : L("已关闭虚拟屏幕");
        if (!r.Truthy("editorRunning")) return L("已创建虚拟屏幕。VS Code 尚未运行，由 Kiteline 打开的 VS Code 窗口将放到虚拟屏幕上");
        var moved = r.Int("moved") ?? 0;
        var message = moved > 0 ? L("已将 %@ 个 VS Code 窗口移到虚拟屏幕", moved) : L("VS Code 窗口已在虚拟屏幕上");
        if ((r.Int("skipped") ?? 0) is var skipped and > 0) message += L("（%@ 个全屏窗口未移动，请先退出全屏）", skipped);
        return message;
    }
}
