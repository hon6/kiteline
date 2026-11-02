using System.Diagnostics;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 设置 → 插件（同 Mac 版 PluginsPane；规范见 docs/agent-plugins.md）：我们做好的 Agent 插件，每家一行——标志、名字、版本、
/// 本机装没装这家 agent、能做什么、开关；有新版本、要先更新 Kiteline、出错时右边给对应的按钮。
/// 检测到本机装了对应的 agent 自动启用，插件有新版本自动更新：这一页主要是看状态、手动开关
public static class PluginsPage
{
    static Kiteline.Net.Api Api => AppModel.Shared.Api;
    /// 自测截图用：兼容表全部展开
    public static bool ExpandAll;

    public static Control Build()
    {
        var host = new ContentControl { Content = new Spinner(18).HAlign(HorizontalAlignment.Center).Margin(0, 60, 0, 0) };
        async void Load(bool check)
        {
            try
            {
                var state = check ? await Api.Post("/api/desktop/plugins/check", new JsonObject()) : await Api.Get("/api/desktop/plugins");
                host.Content = Page(state, () => Load(false), () => Load(true));
            }
            catch (Exception e) { host.Content = Form.Section(null, [], e.Message); }
        }
        Load(false);
        return host;
    }

    static async void Post(string path, JsonObject body, Action reload, string? done = null)
    {
        try
        {
            var reply = await Api.Post(path, body);
            if (reply.Str("error") is { Length: > 0 } error) AppModel.Shared.Flash(L(error));
            else if (done is not null) AppModel.Shared.Flash(done);
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
        reload();
    }

    static Control Page(JsonNode? state, Action reload, Action check)
    {
        var page = Form.Page();
        page.Children.Add(Ui.Text(L("每个插件把一家编程 agent 接进 Kiteline，在手机和电脑上查看它的会话、回复和审批。检测到本机装了对应的 agent 会自动启用（标明需手动开启的除外），插件有新版本时自动更新。"),
            12, color: "Text2", lines: 0).Wrap().Margin(0, 12, 0, 10));
        var list = new StackPanel();
        var rows = state.Arr("plugins").Items().ToList();
        for (var i = 0; i < rows.Count; i++)
        {
            list.Children.Add(Row(rows[i], reload));
            if (i < rows.Count - 1) list.Children.Add(Ui.Rule("Separator", 0.5).Margin(46, 0, 0, 0));
        }
        if (rows.Count == 0) list.Children.Add(Ui.Text(L("本机 Kiteline 还没连上，稍后再看"), 12, color: "Text2").Pad(10, 12));
        page.Children.Add(Card.Make(list, 6, 6));

        var note = state.Str("error") is { Length: > 0 } error ? L(error)
            : state.Num("checkedAt") is double ms && ms > 0 ? L("上次检查：%@", DateTimeOffset.FromUnixTimeMilliseconds((long)ms).LocalDateTime.ToString("HH:mm"))
            : L("尚未检查更新");
        var checking = state.Truthy("checking");
        var button = Form.Button(checking ? L("正在检查…") : L("检查更新"), () => { });
        button.Click = () => { if (button.Child is TextBlock t) t.Text = L("正在检查…"); check(); };
        page.Children.Add(Ui.H(10, Ui.Text(note, 11.5, color: "Text2").Trim().Shrink(), new Spacer(), button).Margin(4, 12, 0, 0));
        page.Children.Add(Ui.Text(L("兼容情况里，读：查看会话和对话记录；写：发消息、插话；执行：审批命令、回答提问、中断；✓ 表示已在该平台实测，「无」表示那家 agent 在该平台没有这种形态。"),
            11.5, color: "Text3", lines: 0).Wrap().Margin(4, 14, 4, 0));
        page.Children.Add(Ui.Text(L("插件由 Kiteline 官方提供并签名，只安装校验通过的版本。新版本出错时会自动退回上一个能用的版本，并询问是否发送出错报告。"),
            11.5, color: "Text3", lines: 0).Wrap().Margin(4, 6, 4, 0));
        return page;
    }

    /// 一个插件：标志、名字和版本、本机的 agent、能做什么、状态；右边操作按钮和开关
    static Control Row(JsonNode plugin, Action reload)
    {
        var id = plugin.Str("id") ?? "";
        var name = plugin.Str("name") ?? id;
        var version = plugin.Str("version");
        var enabled = plugin.Truthy("enabled");
        var optIn = OptIn(plugin);
        var lines = new StackPanel { Spacing = 2 };
        lines.Children.Add(Ui.H(6, Ui.Text(name, 13, FontWeight.SemiBold).Trim(),
            version is null ? null : Ui.Text(plugin.Str("source") == "external" ? version : L("%@（内置）", version), 11, color: "Text3").Trim()));
        lines.Children.Add(Ui.Text(AgentLine(plugin, name), 11.5, color: "Text2", lines: 2).Wrap());
        if (version is not null && Abilities(plugin) is { Length: > 0 } abilities) lines.Children.Add(Ui.Text(abilities, 11, color: "Text3", lines: 2).Wrap());
        // 额度、余额能不能显示、为什么没有（每个插件一句）
        if (plugin.Str("limitsNote") is { Length: > 0 } limits)
            lines.Children.Add(Ui.Text(L("额度：%@", Lang.IsEnglish && plugin.Str("limitsNoteEn") is { Length: > 0 } en ? en : L(limits)), 11, color: "Text3", lines: 0).Wrap());
        var (status, warn) = Status(plugin);
        if (status is not null) lines.Children.Add(Ui.Text(status, 11.5, color: warn ? "Red" : "Text2", lines: 3).Wrap());
        // 接入方式（默认不接的插件）、各平台兼容情况：点开才显示，免得列表太长
        var disclosures = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
        Control? note = null, table = null;
        if (optIn is not null)
        {
            note = new Border { Padding = new Thickness(10, 8), CornerRadius = new CornerRadius(8), IsVisible = ExpandAll,
                Child = Ui.Text(optIn, 11.5, color: "Text2", lines: 0).Wrap() }.Res(Border.BackgroundProperty, "Fill03");
            disclosures.Children.Add(Disclosure(L("接入方式"), note));
        }
        if (plugin.Get("support") is JsonObject support && support.Count > 0)
        {
            table = SupportGrid(support);
            table.IsVisible = ExpandAll;
            disclosures.Children.Add(Disclosure(L("各平台兼容情况"), table));
        }
        if (disclosures.Children.Count > 0) lines.Children.Add(disclosures.Margin(0, 2, 0, 0));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var target = plugin.Get("target");
        if (plugin.Str("busy") is { Length: > 0 })
            actions.Children.Add(Ui.Text(L("正在安装…"), 12, color: "Text2").Trim());
        else if (plugin.Str("action") is "install" or "update")
        {
            var label = plugin.Str("action") == "install" ? L("安装") : L("更新到 %@", target.Str("version") ?? "");
            actions.Children.Add(Form.Button(label, () => Post("/api/desktop/plugins/install", new JsonObject { ["id"] = id }, reload, L("已安装 %@ 插件", name))));
        }
        else if (plugin.Str("action") == "needsApp" && !plugin.Truthy("pending"))
            actions.Children.Add(Form.Button(L("更新并安装"), () => Post("/api/desktop/plugins/update-install", new JsonObject { ["id"] = id }, reload,
                L("正在更新 Kiteline，完成后会自动安装这个插件")), prominent: true));
        if (plugin.Str("status") is "error" or "retired")
            actions.Children.Add(Form.Button(L("报告问题"), () => PluginReport.Send(null, id)));
        if (plugin.Truthy("canRemove"))
        {
            var more = new Tap(Ui.Sym("ellipsis.circle", 15, "Text2").Pad(4), null, 6).Keys("Transparent", "Fill08");
            more.Click = () =>
            {
                var menu = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedRight };
                menu.Items.Add(Ui.Item(L("恢复内置版本"), () => Post("/api/desktop/plugins/remove", new JsonObject { ["id"] = id }, reload)));
                menu.ShowAt(more);
            };
            actions.Children.Add(more);
        }
        if (version is not null)
            actions.Children.Add(new MacSwitch(enabled, async on =>
                {
                    // 默认不接的：打开前先说明接入方式，用户确认了才开；取消了重画一遍，开关弹回去
                    if (on && optIn is not null && !await ConfirmOptIn(name, optIn)) { reload(); return; }
                    Post("/api/desktop/plugins/enable", new JsonObject { ["id"] = id, ["enabled"] = on }, reload);
                })
                .Tip(enabled ? L("关闭后不再接入这家 agent，并删除装进它里面的 Kiteline 组件") : L("启用")));

        var icon = new Border
        {
            Width = 28, Height = 28, CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Top,
            Child = new AgentGlyph(id, 16, "Text") { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        }.Res(Border.BackgroundProperty, "Fill06");
        actions.VerticalAlignment = VerticalAlignment.Top;
        // 接入方式、兼容表放在整行下面、占满宽度（和文字左对齐），不跟右边的按钮挤
        // 关着的调暗；接入方式是开启前要读的，不调暗
        var dim = version is not null && !enabled ? 0.55 : 1;
        var row = new StackPanel();
        var head = Ui.HTop(12, icon, lines.Grow(), actions);
        head.Opacity = dim;
        row.Children.Add(head);
        if (note is not null) row.Children.Add(note.Margin(40, 6, 0, 0));
        if (table is not null)
        {
            table.Opacity = dim;
            row.Children.Add(table.Margin(40, 6, 0, 0));
        }
        // 单项开关（默认关、要读那家凭证的那几项，如 Cursor 的「显示本月用量」）：插件开着才给
        if (version is not null && enabled)
            foreach (var option in plugin.Arr("options").Items())
                row.Children.Add(OptionLine(id, option, reload).Margin(40, 6, 0, 0));
        row.Margin = new Thickness(8, 10);
        return row;
    }

    /// 一项单项开关：名字和一句说明，右边小开关；打开前弹出完整说明（读哪份凭证、查什么）确认（同 Mac 版 PluginOptionLine）
    static Control OptionLine(string pluginId, JsonNode option, Action reload)
    {
        string Text(string key) => option.Str(key) is { Length: > 0 } zh ? (Lang.IsEnglish && option.Str(key + "En") is { Length: > 0 } en ? en : L(zh)) : "";
        var optionId = option.Str("id") ?? "";
        var on = option.Truthy("on");
        var lines = new StackPanel { Spacing = 2 };
        lines.Children.Add(Ui.Text(Text("name"), 12, FontWeight.Medium).Trim());
        if (Text("note") is { Length: > 0 } note) lines.Children.Add(Ui.Text(note, 11, color: "Text2", lines: 0).Wrap());
        var toggle = new MacSwitch(on, async value =>
        {
            if (value && Text("optIn") is { Length: > 0 } detail && !await Dialogs.Confirm(detail, L("开启"), title: L("开启「%@」？", Text("name")))) { reload(); return; }
            Post("/api/desktop/plugins/option", new JsonObject { ["id"] = pluginId, ["option"] = optionId, ["enabled"] = value }, reload);
        });
        toggle.VerticalAlignment = VerticalAlignment.Top;
        return new Border { Padding = new Thickness(10, 8), CornerRadius = new CornerRadius(8), Child = Ui.HTop(10, lines.Grow(), toggle) }
            .Res(Border.BackgroundProperty, "Fill03");
    }

    static readonly (string Key, string Title)[] Forms = [("cli", "命令行"), ("vscode", "VS Code 扩展"), ("desktop", "桌面版")];

    /// 点开 / 收起下面那一块的小标题
    static Control Disclosure(string title, Control body)
    {
        Control Label() => Ui.H(3, Ui.Text(title, 11, color: "Text2").Trim(), Ui.Sym(body.IsVisible ? "chevron.down" : "chevron.right", 8, "Text2"));
        var toggle = new Tap(Label(), null, 4).Keys("Transparent", "Fill05");
        toggle.Click = () => { body.IsVisible = !body.IsVisible; toggle.Child = Label(); };
        toggle.HorizontalAlignment = HorizontalAlignment.Left;
        return toggle;
    }

    public static Task<bool> ConfirmOptIn(string name, string text) => Dialogs.Confirm(text, L("开启"), title: L("开启「%@」接入？", name));

    /// 不是那家 agent 开放的接入方式：默认不接，打开前给用户看的说明。英文界面用插件给的英文，没给就查表
    public static string? OptIn(JsonNode plugin) => plugin.Str("optIn") is { Length: > 0 } text
        ? Lang.IsEnglish && plugin.Str("optInEn") is { Length: > 0 } english ? english : L(text)
        : null;

    /// 本机装没装这家 agent，装了哪些形态、什么版本
    static string AgentLine(JsonNode plugin, string name)
    {
        if (!plugin.Truthy("detected")) return L("本机未检测到 %@", name);
        // 装在哪：local 是本机，其余是 Remote-SSH 远端的名字
        var on = plugin.Arr("detectedOn").Items().Select(n => n.GetValue<string>()).ToList();
        var others = string.Join(L("、"), on.Where(x => x != "local").Select(Lang.Machine));
        if (on.Count > 0 && !on.Contains("local")) return L("%@ 上已安装 %@", others, name);
        var forms = plugin.Get("detect").Get("forms");
        var parts = Forms.Where(f => forms.Get(f.Key) is not null)
            .Select(f => forms.Str(f.Key) is { Length: > 0 } v ? L(f.Title) + " " + v : L(f.Title)).ToList();
        var here = parts.Count == 0 ? L("本机已安装 %@", name) : L("本机已安装：%@", string.Join(L("、"), parts));
        return others.Length > 0 ? here + L("；%@ 上也有", others) : here;
    }

    static string Abilities(JsonNode plugin)
    {
        var list = plugin.Arr("abilities").Items().Select(n => n.GetValue<string>()).ToList();
        if (list.Count == 1 && list[0] == "view") return L("只读：回复和确认需在 %@ 中操作", plugin.Str("name") ?? "");
        return list.Count == 0 ? "" : L("能做到：%@", Levels(list));
    }

    /// 能力 → 读 / 写 / 执行的说法（同 Mac 版 PluginStore.levels）
    static string Levels(IReadOnlyCollection<string> abilities)
    {
        var read = abilities.Contains("view");
        var write = abilities.Contains("reply");
        var execute = abilities.Any(a => a is "approve" or "answer" or "interrupt");
        if (read && !write && !execute) return L("只读");
        return string.Join(" · ", new[] { read ? L("读") : null, write ? L("写") : null, execute ? L("执行") : null }.OfType<string>());
    }

    static readonly (string Key, string Name)[] Platforms = [("mac", "Mac"), ("windows", "Windows"), ("linux", "Linux")];

    /// 兼容表（同 Mac 版 SupportGrid）：行是形态，列是平台（本机那一列加粗）；每格写读 / 写 / 执行或只读，
    /// ✓ 是我们在那个平台实测过，「无」是那家 agent 在这个平台没有这个形态
    static Control SupportGrid(JsonObject support)
    {
        var here = OperatingSystem.IsWindows() ? "windows" : "linux";
        JsonNode? Cell(string platform, string form) => support.Get(platform).Get(form);
        var forms = Forms.Where(f => Platforms.Any(p => Cell(p.Key, f.Key) is not null)).ToList();
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,*,*"), RowDefinitions = new RowDefinitions(string.Join(",", Enumerable.Repeat("Auto", forms.Count + 1))) };
        void Put(Control control, int row, int column)
        {
            Grid.SetRow(control, row);
            Grid.SetColumn(control, column);
            grid.Children.Add(control.Margin(0, 2, 14, 2));
        }
        for (var c = 0; c < Platforms.Length; c++)
        {
            var mine = Platforms[c].Key == here;
            Put(Ui.Text(Platforms[c].Name, 11, mine ? FontWeight.SemiBold : FontWeight.Normal, mine ? "Text" : "Text2").Trim(), 0, c + 1);
        }
        for (var r = 0; r < forms.Count; r++)
        {
            Put(Ui.Text(L(forms[r].Title), 11, color: "Text2").Trim(), r + 1, 0);
            for (var c = 0; c < Platforms.Length; c++)
            {
                var cell = Cell(Platforms[c].Key, forms[r].Key);
                var abilities = cell.Arr("abilities").Items().Select(n => n.GetValue<string>()).ToList();
                Control label = cell is null ? Ui.Text("—", 11, color: "Text3").Trim()
                    : abilities.Count == 0 ? Ui.Text(L("无"), 11, color: "Text3").Trim().Tip(L(cell.Str("note") ?? ""))
                    : Ui.Text(Levels(abilities) + (cell.Truthy("verified") ? " ✓" : ""), 11).Trim().Tip(cell.Truthy("verified") ? L("已实测") : L("未实测"));
                Put(label, r + 1, c + 1);
            }
        }
        return new Border { Padding = new Thickness(10, 8), CornerRadius = new CornerRadius(8), Child = grid }.Res(Border.BackgroundProperty, "Fill03");
    }

    static (string?, bool) Status(JsonNode plugin)
    {
        var target = plugin.Get("target");
        var wanted = plugin.Str("wanted") ?? target.Str("version") ?? "";
        switch (plugin.Str("status"))
        {
            case "retired": return (L("新版本 %@ 出错，已退回上一个能用的版本", wanted), true);
            case "error": return (L("插件加载失败：%@", plugin.Str("error") ?? ""), true);
            case "incompatible":
                return (plugin.Str("version") is null ? L("需要更新 Kiteline 才能使用") : L("新版本 %@ 需要更新 Kiteline，暂用当前版本", wanted), false);
        }
        if (OptIn(plugin) is not null && !plugin.Truthy("enabled") && plugin.Str("version") is not null) return (L("需手动开启：开启前请先了解接入方式"), false);
        if (plugin.Truthy("pending")) return (L("Kiteline 更新完成后会自动安装"), false);
        if (plugin.Truthy("held") && plugin.Str("action") is not null) return (L("已关闭自动安装：之前手动移除过此插件，需要时可手动安装"), false);
        return plugin.Str("action") switch
        {
            "update" => (L("有新版本 %@", target.Str("version") ?? ""), false),
            "needsApp" => (L("新版本 %@ 需要 Kiteline %@ 或更新版本", target.Str("version") ?? "", target.Get("minApp").Str("desktop") ?? ""), false),
            _ => (null, false),
        };
    }
}

/// 插件出错（同 Mac 版 PluginErrorPanel）：后台推来 plugin_error 时弹窗问要不要发报告。报告用用户自己的邮件程序发，
/// 只含插件和 agent 的版本、系统、出错位置，不含对话内容，发之前能看到；不往我们的服务器写任何数据
public static class PluginReport
{
    static Kiteline.Net.Api Api => AppModel.Shared.Api;

    public static void Ask(JsonNode? error)
    {
        var key = error.Str("key") ?? "";
        var name = error.Str("name") ?? error.Str("id") ?? "";
        Window? window = null;
        var stack = new StackPanel { Spacing = 12 };
        stack.Children.Add(Ui.H(10, new AgentGlyph(error.Str("id"), 18, "Text"), Ui.Text(L("「%@」插件出错", name), 15, FontWeight.SemiBold).Trim().Shrink()));
        stack.Children.Add(Ui.Text(error.Str("error") ?? "", 12, color: "Text2", lines: 4).Wrap());
        stack.Children.Add(Ui.Text(L("来自 %@ · 插件 %@", Lang.Machine(error.Str("host") ?? ""), error.Str("version") ?? ""), 11.5, color: "Text3").Trim());
        stack.Children.Add(Ui.Text(L("可以把出错信息发给我们，帮助尽快修复。报告只包含插件和 agent 的版本、系统和出错位置，不含对话内容；会用你自己的邮件程序发送，发送前可以查看。"),
            12, color: "Text2", lines: 0).Wrap());
        async void Close(string? action)
        {
            window?.Close();
            if (action is not null) try { await Api.Post("/api/desktop/plugins/" + action, new JsonObject { ["key"] = key }); } catch { }
        }
        stack.Children.Add(Ui.H(8,
            Form.Button(L("不再询问"), () => Close("mute")), Form.Button(L("暂不"), () => Close("dismiss")), new Spacer(),
            Form.Button(L("发送报告…"), () => { Send(key, null); Close("dismiss"); }, prominent: true)).Margin(0, 4, 0, 0));
        window = Dialog.Make(stack.Pad(20), 440, L("插件出错"));
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) Close("dismiss"); };
        Dialog.Show(window);
    }

    /// 打开邮件程序、带好收件人、标题和正文；正文同时复制一份（没设默认邮件程序时可以自己粘贴）
    public static async void Send(string? key, string? id)
    {
        try
        {
            var reply = await Api.Post("/api/desktop/plugins/report", new JsonObject { ["key"] = key, ["id"] = id });
            var text = (reply.Str("subject") ?? "") + "\n\n" + (reply.Str("body") ?? "");
            _ = (Dialog.Owner() ?? MainWindow.Current)?.Clipboard?.SetTextAsync(text);
            try { Process.Start(new ProcessStartInfo(reply.Str("url") ?? "") { UseShellExecute = true }); } catch { }
            AppModel.Shared.Flash(L("已打开邮件，报告内容也已复制，可发送到 %@", reply.Str("to") ?? ""));
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); }
    }
}
