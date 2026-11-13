using System.Globalization;
using System.Text.Json.Nodes;
using Avalonia.Controls;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 在后台运行 Claude Code（同 iOS / Mac 版 HostedViews.swift）：远端电脑按设备开、默认不开；这台电脑自己（本机）默认开，Windows 上不支持。
/// 每台先「检测出口 IP」——照后台运行时的那套网络设置查出口，看过结果点「确认开启」才开这一台；
/// 从对话页提示进来的，开了以后还能把当前会话转到后台。设置 → 来源、对话页提示都打开它
public static class HostedSetup
{
    static AppModel Model => AppModel.Shared;

    /// sourceId：只看这一台（来源页某一行、对话页提示进来的）；key：从哪个会话的提示进来的；changed：开关改了（来源页跟着刷新）
    public static void Open(string? sourceId = null, string? key = null, Action? changed = null)
    {
        var probes = new Dictionary<string, JsonNode>();
        NavSheet.Open(L("后台运行 Claude Code"), sheet =>
        {
            var box = new StackPanel { Spacing = 14, Margin = new Avalonia.Thickness(18, 4, 18, 18) };
            Draw(sheet, box, sourceId, key, probes, changed);
            return NavSheet.Scroll(box);
        }, 520, 600);
    }

    static void Draw(NavSheet sheet, StackPanel box, string? sourceId, string? key, Dictionary<string, JsonNode> probes, Action? changed)
    {
        box.Children.Clear();
        box.Children.Add(Ui.Text(L("开启后，这台电脑上的新建任务和恢复的会话不再打开 VS Code，由 Kiteline 在那台电脑上后台运行 Claude Code，可减少 VS Code 的内存占用；发送消息、确认均不切换前台，电脑锁屏时也能操作。"), 13, lines: 6));
        box.Children.Add(Ui.Text(L("后台运行的 Claude Code 就在项目所在的电脑上运行，使用与 VS Code 中的 Claude Code 相同的网络设置（代理、证书、接口地址），每次启动前核对一致才运行。开启前请先检测出口。"), 12, color: "Text2", lines: 5));
        var machines = Model.Sources.Where(s => s.Hosted is not null && (sourceId is null || s.Id == sourceId)).ToList();
        if (machines.Count == 0)
            box.Children.Add(Ui.Text(L("没有可在后台运行 Claude Code 的电脑（Windows 电脑暂不支持）。"), 12, color: "Text2", lines: 3));
        var status = Ui.Text("", 12, color: "Red", lines: 3);
        void Redraw() => Draw(sheet, box, sourceId, key, probes, changed);
        foreach (var machine in machines) box.Children.Add(Card(machine, probes, status, Redraw, changed));
        box.Children.Add(status);
        if (key is not null && Model.Session(key) is { Hostable: true } session && Model.Sources.FirstOrDefault(s => s.Id == session.SourceId)?.Hosted == "on")
        {
            var busy = session.IsBusy || session.IsWaiting;
            GlassButton? move = null;
            move = new GlassButton(L("把当前会话转到后台运行"), null, async () =>
            {
                move!.IsEnabled = false;
                status.Text = L("正在转到后台…");
                try
                {
                    var reply = await Model.Api.Post("/api/hosted/move", new Dictionary<string, object>(), new Dictionary<string, string> { ["key"] = session.Key });
                    Model.Flash(reply.Str("message") ?? L("已转到后台运行"));
                    sheet.Close();
                }
                catch (Exception e) { status.Text = e.Message; move.IsEnabled = true; }
            }, prominent: true, height: 32) { IsEnabled = !busy };
            box.Children.Add(Ui.V(6, move, Ui.Text(busy ? L("Claude 正在处理这个会话，请在这一轮完成后再转到后台。")
                                                        : L("将关闭这个会话在 VS Code 中的标签页，并在后台接着这段对话。"), 11, color: "Text2", lines: 3)));
        }
        if (probes.Count > 0)
            box.Children.Add(Ui.Text(L("检测通过查询 IP 的公共网址（如 ipinfo.io）进行，不连接 Claude。若代理按域名分流（例如仅让 Claude 的域名走专线），Claude 实际使用的出口可能与此处显示的不同，但与 VS Code 中的 Claude Code 使用同一套网络设置。"), 11, color: "Text2", lines: 6));
    }

    static Control Card(SourceInfo machine, Dictionary<string, JsonNode> probes, TextBlock status, Action redraw, Action? changed)
    {
        var on = machine.Hosted == "on";
        var card = new StackPanel { Spacing = 7 };
        var badge = Ui.Box(Ui.Text(on ? L("已开启") : machine.Online ? L("未开启") : L("离线"), 10.5, FontWeight.SemiBold, on ? "Added" : "Text2"),
                           new Avalonia.Thickness(6, 1), on ? "GreenFill13" : "Fill08", 8);
        card.Children.Add(Ui.H(8, Ui.Text(machine.Name, 13, FontWeight.SemiBold).Shrink(), badge));
        probes.TryGetValue(machine.Id, out var probe);
        var ip = probe?.Obj("egress")?.Str("ip");
        if (probe is not null)
        {
            if (probe.Str("error") is { } error)
                card.Children.Add(Ui.Text(error, 12, color: "Text2", lines: 3));
            else
            {
                var egress = probe.Obj("egress");
                card.Children.Add(Row(L("出口 IP"), ip ?? L("未能查到（网络不通或代理不可用）"), ip is not null));
                var place = new List<string>();
                foreach (var part in new[] { Country(egress?.Str("country")), egress?.Str("region"), egress?.Str("city") })
                    if (!string.IsNullOrEmpty(part) && !place.Contains(part)) place.Add(part);
                if (place.Count > 0) card.Children.Add(Row(L("地区"), string.Join(" · ", place)));
                if (egress?.Str("org") is { Length: > 0 } org) card.Children.Add(Row(L("网络"), org));
                card.Children.Add(Row(L("网络设置"), probe.Str("source") switch
                {
                    "vscode" => L("与 VS Code 中运行的 Claude Code 一致"),
                    "shell" => L("按终端环境（VS Code 中目前没有运行的 Claude Code）"),
                    _ => L("测试环境"),
                }));
                var settings = probe.Obj("settings");
                if (settings is null || settings.Count == 0)
                    card.Children.Add(Row(L("代理"), L("未设置（使用电脑本身的网络）")));
                else
                    foreach (var (name, value) in settings.OrderBy(p => p.Key, StringComparer.Ordinal))
                        card.Children.Add(Row(name, value?.ToString() ?? "", true));
            }
        }
        GlassButton? check = null;
        check = new GlassButton(probe is null ? L("检测出口 IP") : L("重新检测"), "network", async () =>
        {
            check!.IsEnabled = false;
            status.Res(TextBlock.ForegroundProperty, "Text2").Text = L("正在检测「%@」的出口…", machine.Name);
            try
            {
                var reply = await Model.Api.Post("/api/hosted/probe", new Dictionary<string, object> { ["sourceId"] = machine.Id });
                if (reply.Arr("machines")?.Items().FirstOrDefault(m => m.Str("id") == machine.Id) is { } found) probes[machine.Id] = found.DeepClone();
                redraw();
            }
            catch (Exception e) { status.Res(TextBlock.ForegroundProperty, "Red").Text = L("检测未完成：%@", e.Message); check.IsEnabled = true; }
        }, height: 30) { IsEnabled = machine.Online };
        GlassButton? toggle = null;
        toggle = new GlassButton(on ? L("关闭") : L("确认开启"), null, async () =>
        {
            toggle!.IsEnabled = false;
            await Model.SetHosted(machine.Id, !on);
            redraw();
            changed?.Invoke();
        }, prominent: !on, height: 30) { IsEnabled = on || ip is not null };
        card.Children.Add(Ui.H(10, check, new Spacer(), toggle));
        if (!on && ip is null)
            card.Children.Add(Ui.Text(L("检测到出口后才能开启。"), 11, color: "Text2"));
        return Ui.Box(card, new Avalonia.Thickness(12), "Fill04", 12, "Separator", 0.5);
    }

    static Control Row(string title, string value, bool mono = false)
    {
        var text = Ui.Text(value, 12, lines: 3);
        if (mono) text.Mono();
        var label = Ui.Text(title, 12, color: "Text2");
        label.Width = 86;
        return Ui.HTop(10, label, text.Shrink().Grow());
    }

    /// 国家代码 → 按界面语言的名字（美国 / United States）；认不出就原样
    static string? Country(string? code)
    {
        if (string.IsNullOrEmpty(code)) return null;
        try { return new RegionInfo(code).DisplayName; } catch (ArgumentException) { return code; }
    }

    /// 对话页顶上的提示「当前会话支持后台托管 Claude」：所在设备没开后台运行时一直显示，点「不再提示」才不再出现（存在电脑上，各端一起）。
    /// 不该显示时返回 null
    public static Control? Tip(SessionInfo session)
    {
        if (!session.Hostable || !Model.Features.Contains("hostedSetup") || Model.HostedTipOff
            || Model.Sources.FirstOrDefault(s => s.Id == session.SourceId)?.Hosted != "off") return null;
        var open = new Tap(Ui.H(8, Ui.Sym("moon.stars", 13, "Added"),
                                Ui.Text(L("当前会话支持后台托管 Claude，可减少 VS Code 的内存占用"), 12, lines: 2).Shrink(),
                                Ui.Sym("chevron.right", 10, "Text2")), () => Open(session.SourceId, session.Key), 6);
        var never = new Tap(Ui.H(4, Ui.Sym("square", 12, "Text2"), Ui.Text(L("不再提示"), 11, color: "Text2")),
                            async () => await Model.SetHosted(tipOff: true), 6);
        var rule = new Border { Width = 0.5, Height = 18 }.Res(Border.BackgroundProperty, "Separator");
        return Ui.Box(Ui.H(10, open.Shrink(), rule, never), new Avalonia.Thickness(14, 8), "Glass", 14, "Separator", 0.5);
    }
}
