using Avalonia.Controls;
using Avalonia.Input.Platform;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 会话的操作：对话页收到后去做（打开面板、确认后中断……），同 Mac 版 KitelineKit.Action
public enum SessionAction { Files, Changes, Tests, Agents, Search, Stop, Mode, Model, Compact, Info, NewTask, Bottom, Terminal }

/// 左边栏、标签栏按钮、菜单要对话页做的事，交给开着这个会话的对话页（同 Mac 版 KitelineKit.perform）
public static class ChatActions
{
    public static event Action<string, SessionAction>? Requested;
    public static void Perform(string key, SessionAction action)
    {
        ChatPanes.Shared.Show(key);
        MainModel.Shared.Selection = key;
        Requested?.Invoke(key, action);
    }
}

/// 会话的右键菜单（同 Mac 版 SessionMenu）
public static class SessionMenu
{
    public static IEnumerable<Control> Items(AppModel model, MainModel main, string key)
    {
        if (model.Session(key) is not SessionInfo item) yield break;
        yield return Ui.Item(L("在 VS Code 中打开"), () => Jump(key));
        if (!ChatPanes.Shared.Keys.Contains(key))
        {
            // 把右边当前那块一分为二放这个会话（同把它拖到右边那块的右边 / 下边）
            yield return Ui.Item(L("在右侧分屏打开"), () => OpenSplit(key, false));
            yield return Ui.Item(L("在下方分屏打开"), () => OpenSplit(key, true));
        }
        yield return Ui.Item(model.IsMarked(key) ? L("取消标记") : L("标记"), () => model.SetMarked(key, !model.IsMarked(key)));
        yield return Ui.Item(model.IsPinned(key) ? L("取消置顶") : L("置顶"), () => model.SetPinned(key, !model.IsPinned(key)));
        yield return Ui.Item(L("在此项目中新建会话…"), () => main.NewTask(item));
        // 会话群：和别的设备、别的项目里的会话互相发消息（后台支持才有）
        if (GroupState.Shared.Supported && item.CanReply) yield return Ui.Item(L("拉群协作…"), () => GroupPicker.Open([key], null));
        var muted = model.IsMuted(key);
        yield return Ui.Item(muted ? L("取消静音") : L("静音（仅在需要确认时提醒）"), () => model.SetMuted(key, !muted));
        // 权限模式、换模型、压缩：后台说这个 agent 有才给（caps）
        if (item.CanReply)
        {
            if (item.Can("mode")) yield return Ui.Item(L("权限模式…"), () => ChatActions.Perform(key, SessionAction.Mode));
            var tune = Tune(item);
            if (item.Can("model"))
                yield return Ui.Item(tune.Length == 0 ? L("模型和思考等级…") : L("模型和思考等级（%@）…", tune), () => ChatActions.Perform(key, SessionAction.Model));
            if (item.Can("compact"))
                yield return Ui.Item(L("压缩上下文（/compact）") + (item.Usage?.Percent is int p ? L(" · 已用 %@%", p) : "") + "…", () => ChatActions.Perform(key, SessionAction.Compact));
        }
        if (item.IsBusy) yield return Ui.Item(L("中断 %@", item.Speaker), () => _ = model.Press(key, "esc", L("已中断")));
        // 关闭会话（后台给 close 才有，目前是 Claude Code）：关掉 VS Code 里的标签页 / 终端里 /exit
        if (item.CanReply && item.Can("close")) yield return Ui.Item(L("关闭会话…"), () => Close(model, key));
        yield return Ui.Divider();
        if (item.Can("subagents"))
            yield return Ui.Item(item.Subagents > 0 ? L("子 agent（已派出 %@ 个）…", item.Subagents) : L("子 agent…"), () => ChatActions.Perform(key, SessionAction.Agents));
        yield return Ui.Item(L("在对话里搜索…"), () => ChatActions.Perform(key, SessionAction.Search));
        yield return Ui.Item(L("会话信息"), () => ChatActions.Perform(key, SessionAction.Info));
        if (item.Can("term")) yield return Ui.Item(L("切换终端"), () => ChatActions.Perform(key, SessionAction.Terminal));
        yield return Ui.Item(L("Agent 详情…"), () => AgentDetails.Open(key));
        yield return Ui.Divider();
        yield return Ui.Item(L("复制工作目录"), () => Copy(item.Cwd ?? ""));
        yield return Ui.Item(L("复制会话名"), () => Copy(item.Title));
    }

    /// 关闭会话（先确认）：会话越开越多、VS Code 里标签越开越多时用（同 Mac 版 KitelineModel.close）
    public static async void Close(AppModel model, string key)
    {
        var s = model.Session(key);
        var message = s is null || s.IsClaude
            ? L("关闭会话将关闭它在 VS Code 中的标签页（终端中的会话发送 /exit），Claude 随之结束此会话，正在进行的工作会中断。之后可在「历史会话」中恢复")
            : L("关闭会话将结束此 %@ 会话，并关闭或归档它在电脑上的窗口，正在进行的工作会中断。之后可在 %@ 中找回", s.Speaker, s.Speaker);
        if (await Dialogs.Confirm(message, L("关闭会话"), destructive: true))
            await model.CloseSession(key);
    }

    /// 「Opus 5.5 · 高」：模型和思考等级（同 Mac 版 SessionItem.tune）
    public static string Tune(SessionInfo s)
    {
        var parts = new List<string>();
        if (Tools.ModelName(s.Usage?.Model) is { Length: > 0 } m) parts.Add(m);
        if (s.Effort is { Length: > 0 } e && e != "auto") parts.Add(Effort.Name(e));
        return string.Join(" · ", parts);
    }

    public static void OpenSplit(string key, bool down)
    {
        if (ChatPanes.Shared.Keys.Contains(key)) ChatPanes.Shared.Show(key);
        else if (!ChatPanes.Shared.SplitFocused(key, down))
        {
            AppModel.Shared.Flash(L("右侧空间不足，无法继续分屏：请先关闭一个分屏，或放大窗口"));
            return;
        }
        MainModel.Shared.Selection = key;
    }

    /// 切到这个会话所在的 VS Code 窗口
    public static async void Jump(string key)
    {
        try { await AppModel.Shared.Api.Post("/api/desktop/jump", new Dictionary<string, object> { ["key"] = key }); }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
    }

    public static async void Copy(string text)
    {
        if (MainWindow.Current?.Clipboard is IClipboard clipboard)
        {
            await clipboard.SetTextAsync(text);
            AppModel.Shared.Flash(L("已复制"));
        }
    }
}

/// 思考等级（同 iOS 版 EffortLevel）
public static class Effort
{
    public static readonly (string Id, string Name)[] Levels = [("auto", "自动"), ("low", "低"), ("medium", "中"), ("high", "高"), ("xhigh", "超高"), ("max", "最高")];
    public static string Name(string id) => L(Levels.FirstOrDefault(l => l.Id == id).Name ?? id);
}
