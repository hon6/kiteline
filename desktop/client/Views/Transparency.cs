using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

// 过程透明化（同 Mac / iPhone 的 Views/Transparency.swift）：工具调用的风险标签和改动预览、上下文构成、撤回某一轮起的改动、网页报错。
// 数据都由电脑端的 watcher 算好（tool_risk / session_context / rewind_plan / BrowserLink.devlog），这里只负责显示。

/// 风险标签：watcher 的 tool_risk 给的代号 → 文字、级别。2 级（不易撤回、影响外部）橙色，1 级（值得知道）灰色
public static class RiskTag
{
    public static string Label(string code) => code switch
    {
        "delete" or "delete_ask" => L("删除文件"),
        "rewrite" or "rewrite_ask" => L("改写 Git 历史"),
        "remote_exec" => L("执行下载的脚本"),
        "db" => L("改动数据库"),
        "disk" => L("磁盘操作"),
        "secret_write" => L("改动密钥文件"),
        "system" => L("改动系统配置"),
        "deploy" => L("改动线上资源"),
        "perm" => L("修改权限"),
        "os" => L("系统服务"),
        "push" => L("推送"),
        "install" => L("安装软件"),
        "kill" => L("结束进程"),
        "sudo" => L("管理员权限"),
        "secret" => L("读取密钥"),
        _ => code,
    };

    public static string Explain(string code) => code switch
    {
        "delete" => L("递归删除受保护的位置（主目录、系统目录、.git 等），删除后难以恢复"),
        "delete_ask" => L("递归删除项目之外或无法确定的位置"),
        "rewrite" => L("强制推送或删除主分支，会改写共享的 Git 历史"),
        "rewrite_ask" => L("丢弃本地改动或改写分支历史（reset --hard、强制推送到其他分支等）"),
        "remote_exec" => L("下载内容后直接交给 shell 执行"),
        "db" => L("删除数据库对象或清空数据"),
        "disk" => L("格式化、覆盖磁盘或彻底擦除文件"),
        "secret_write" => L("修改存放密钥、令牌的文件"),
        "system" => L("修改系统目录或登录配置（如 /etc、~/.zshrc、~/.ssh）"),
        "deploy" => L("删除或变更云服务、集群上的资源"),
        "perm" => L("放宽文件权限（777、setuid）"),
        "os" => L("改动注册表、系统服务、计划任务或关机"),
        "push" => L("把提交推送到远端仓库或发布出去"),
        "install" => L("在这台电脑上全局安装软件"),
        "kill" => L("结束其他进程"),
        "sudo" => L("以管理员身份运行"),
        "secret" => L("读取存放密钥、令牌的文件"),
        _ => "",
    };

    public static bool High(string code) => code is "delete" or "rewrite" or "remote_exec" or "db" or "disk" or "secret_write" or "system";

    /// 同一件事的两个级别只显示一个、最多 limit 个
    public static List<string> Shown(IEnumerable<string>? codes, int limit = 2)
    {
        var seen = new HashSet<string>();
        return (codes ?? []).Where(c => seen.Add(Label(c))).Take(limit).ToList();
    }

    /// 一串风险小标签（步骤行右侧、确认卡片上）
    public static Control Chips(IEnumerable<string> codes, double size = 0)
    {
        if (size <= 0) size = ChatType.Size * 0.72;
        var row = Ui.H(4);
        foreach (var code in codes)
        {
            var high = High(code);
            var chip = Ui.H(3, high ? Ui.Sym("exclamationmark.triangle.fill", size * 0.85, "Orange") : null,
                Ui.Text(Label(code), size, FontWeight.Medium, high ? "Orange" : "Text2"));
            row.Children.Add(Ui.Box(chip, new Thickness(6, 1.5), high ? "OrangeFill13" : "Fill06", 99));
        }
        return row;
    }
}

/// 步骤行下面的预览：改代码的前几行改动、命令出错时的最后两行输出
public static class StepPreview
{
    public static List<(string Text, string Color)> Lines(Step step)
    {
        var item = step.Item;
        var outLines = new List<(string, string)>();
        if (item.T != "tool") return outLines;
        string F(JsonNode? n, string k) => n.Str(k) ?? "";
        static bool Blank(string s) => s.Trim().Length == 0;
        switch (item.Name ?? "")
        {
            case "Edit":
            case "MultiEdit":
                var pairs = item.Name == "Edit"
                    ? [(F(item.Input, "old_string"), F(item.Input, "new_string"))]
                    : item.Input.Arr("edits").Items().Select(e => (F(e, "old_string"), F(e, "new_string"))).ToList();
                foreach (var (old, @new) in pairs)
                {
                    var oldLines = old.Split('\n');
                    var newLines = @new.Split('\n');
                    var kept = oldLines.Intersect(newLines).ToHashSet();
                    outLines.AddRange(oldLines.Where(l => !kept.Contains(l) && !Blank(l)).Take(1).Select(l => ("- " + l.Trim(), "Removed")));
                    outLines.AddRange(newLines.Where(l => !kept.Contains(l) && !Blank(l)).Take(2).Select(l => ("+ " + l.Trim(), "Added")));
                    if (outLines.Count >= 3) break;
                }
                return outLines.Take(3).ToList();
            case "Write":
                return F(item.Input, "content").Split('\n').Where(l => !Blank(l)).Take(2).Select(l => ("+ " + l.Trim(), "Added")).ToList();
            default:
                if ((step.State != StepState.Failed && step.Result?.IsError != true) || step.Result?.Text is not string text) return outLines;
                return text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).TakeLast(2).Select(l => (l, "Removed")).ToList();
        }
    }

    public static Control? Make(Step step)
    {
        var lines = Lines(step);
        if (lines.Count == 0) return null;
        var stack = new StackPanel();
        foreach (var (text, color) in lines)
            stack.Children.Add(Ui.Text(text, ChatType.Size * 0.78, color: color).Mono().Trim());
        return Ui.Box(stack, new Thickness(8, 4), "Fill05", 6);
    }
}

/// 上下文构成：点对话页的上下文百分比打开（同 Mac 版 ContextSheet）；底部按钮压缩上下文
public static class ContextSheet
{
    public static string KindName(string k) => k switch
    {
        "system" => L("系统提示、工具定义与记忆"),
        "summary" => L("压缩后的摘要"),
        "you" => L("你的消息"),
        "reminder" => L("提醒与通知"),
        "reply" => L("回复"),
        "thinking" => L("思考"),
        "edit" => L("改代码"),
        "read" => L("读文件"),
        "bash" => L("命令与输出"),
        "search" => L("搜索"),
        "web" => L("网页"),
        "agent" => L("子 agent"),
        "mcp" => L("MCP 工具"),
        "image" => L("图片"),
        _ => L("其他工具"),
    };

    public static void Show(string key)
    {
        var model = AppModel.Shared;
        var body = new StackPanel { Spacing = 16 };
        body.Children.Add(new Spinner().HAlign(HorizontalAlignment.Center).Margin(0, 30, 0, 30));
        var buttons = new List<Control>();
        if (model.Session(key)?.Can("compact") == true)
        {
            Window? window = null;
            buttons.Add(new GlassButton(L("压缩上下文"), "arrow.down.right.and.arrow.up.left", () => { model.Send(key, "/compact", []); window?.Close(); })
                .Tip(L("等同于在 Claude Code 中输入 /compact：将此前的对话总结为摘要以释放空间，部分细节可能丢失")));
            window = Sheets.Show(L("上下文构成"), body, 560, 640, buttons);
        }
        else Sheets.Show(L("上下文构成"), body, 560, 640);
        _ = Load(key, body);
    }

    static async Task Load(string key, StackPanel body)
    {
        JsonNode? reply;
        try { reply = await AppModel.Shared.Api.Get("/api/context", new Dictionary<string, string> { ["key"] = key }); }
        catch (Exception e) { reply = null; body.Children.Clear(); body.Children.Add(Ui.Text(L("读取失败：%@", e.Message), 13, color: "Text2").Wrap()); return; }
        body.Children.Clear();
        if (reply is null || reply.Truthy("unsupported"))
        {
            body.Children.Add(Ui.Text(L("这个会话不支持查看上下文构成"), 13, color: "Text2"));
            return;
        }
        var used = reply.Int("context") ?? 0;
        var window = Math.Max(1, reply.Int("window") ?? 1);
        var head = Ui.H(6, Ui.Text(Format.Tokens(used), 26, FontWeight.SemiBold).Digits(), Ui.Text(L("/ %@ token", Format.Tokens(window)), 13, color: "Text2"),
            new Spacer(), Ui.Text($"{Math.Min(100, used * 100 / window)}%", 18, color: "Text2").Digits());
        body.Children.Add(head);
        body.Children.Add(Bar((double)used / window, "Accent", 6));
        var notes = new List<string>();
        if ((reply.Int("calls") ?? 0) > 0) notes.Add(L("这段上下文已请求 %lld 次", reply.Int("calls") ?? 0));
        if (reply.Num("costUSD") is double cost) notes.Add(L("累计约 %@（估算）", $"${cost:0.00}"));
        if (notes.Count > 0) body.Children.Add(Ui.Text(string.Join(" · ", notes), 12, color: "Text2"));
        var parts = new StackPanel { Spacing = 10 };
        foreach (var part in reply.Arr("parts").Items())
        {
            var k = part.Str("k") ?? "";
            var tokens = part.Int("tokens") ?? 0;
            var count = part.Int("count") ?? 0;
            var row = Ui.H(6, Ui.Text(KindName(k), 13), k != "system" && count > 1 ? Ui.Text(L("%lld 次", count), 11, color: "Text3") : null, new Spacer(),
                Ui.Text(Format.Tokens(tokens), 13).Digits(),
                Ui.Text(L("花费 %lld%%", (int)Math.Round((part.Num("share") ?? 0) * 100)), 11.5, color: "Text2").Digits().MinW(64));
            parts.Children.Add(new StackPanel { Spacing = 4, Children = { row, Bar((double)tokens / Math.Max(1, used), "Accent", 4, 0.55) } });
        }
        body.Children.Add(ToolDetail.Section(L("各部分"), parts));
        var top = new StackPanel { Spacing = 8 };
        foreach (var item in reply.Arr("top").Items().Take(8))
            top.Children.Add(Ui.H(8, Ui.Text(item.Str("label"), ChatType.DetailSize).Mono().Trim().Shrink(), new Spacer(),
                Ui.Text(Format.Tokens(item.Int("tokens") ?? 0), 12, color: "Text2").Digits()));
        if (top.Children.Count > 0) body.Children.Add(ToolDetail.Section(L("占得最多的几项"), top));
        body.Children.Add(Ui.Text(L("数字为估算：总量是 Claude 报的实际用量，各部分按内容字数估算后按比例分配。花费占比按「进入上下文后每次请求都要再读一遍」计算，越早进来、越大的内容越费钱。只统计最近一次压缩之后的部分。"), 12, color: "Text2").Wrap());
    }

    /// 细长条：fraction 占满的比例
    static Control Bar(double fraction, string color, double height, double opacity = 1)
    {
        fraction = Math.Clamp(fraction, 0.003, 1);
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        var grid = new Grid { Height = height, ColumnDefinitions = new ColumnDefinitions(fraction.ToString("0.####", inv) + "*," + Math.Max(0.0001, 1 - fraction).ToString("0.####", inv) + "*") };
        grid.Children.Add(Ui.Box(null, new Thickness(0), color, height / 2).Opacity(opacity));
        var track = Ui.Box(null, new Thickness(0), "Fill08", height / 2);
        Grid.SetColumnSpan(track, 2);
        grid.Children.Insert(0, track);
        return grid;
    }
}

/// 撤回某一轮起的改动（同 Mac 版 RewindSheet）：先列出会动哪些文件，确认后撤回；撤回后能还原
public static class RewindSheet
{
    public static void Show(string key, int offset)
    {
        var body = new StackPanel { Spacing = 14 };
        body.Children.Add(new Spinner().HAlign(HorizontalAlignment.Center).Margin(0, 30, 0, 30));
        var host = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        Sheets.Show(L("撤回改动"), body, 560, 520, [host]);
        _ = Load(key, offset, body, host);
    }

    static Dictionary<string, string> Q(string key) => new() { ["key"] = key };

    static async Task Load(string key, int offset, StackPanel body, StackPanel host)
    {
        JsonNode? plan;
        try { plan = await AppModel.Shared.Api.Post("/api/rewind", new { op = "plan", offset }, Q(key)); }
        catch (Exception e) { Fill(body, Ui.Text(L("读取失败：%@", e.Message), 13, color: "Text2").Wrap()); return; }
        if (plan?.Str("error") is string error) { Fill(body, Ui.Text(error, 13, color: "Text2").Wrap()); return; }
        var changes = plan.Arr("files").Items().Where(f => f.Str("action") is "restore" or "delete").ToList();
        if (plan.Truthy("nothing") || changes.Count == 0)
        {
            Fill(body, Ui.Text(plan?.Str("note") ?? L("这一轮之后的文件已经和改动前一样，不需要撤回"), 13, color: "Text2").Wrap());
            return;
        }
        var turn = plan.Int("turnIndex") ?? 0;
        var list = new StackPanel { Spacing = 8 };
        foreach (var file in changes)
        {
            var delete = file.Str("action") == "delete";
            Control right = delete ? Ui.Text(L("删除（这一轮新建的）"), 11.5, color: "Text2")
                : Ui.H(3, Ui.Text($"+{file.Int("added") ?? 0}", ChatType.DetailSize, color: "Added").Mono(), Ui.Text($"−{file.Int("removed") ?? 0}", ChatType.DetailSize, color: "Removed").Mono());
            list.Children.Add(Ui.H(8, Ui.Sym(delete ? "trash" : "arrow.uturn.backward", 12, delete ? "Removed" : "Text2").Width(16),
                Ui.Text(file.Str("rel") ?? file.Str("path"), ChatType.DetailSize).Mono().Trim().Shrink(), new Spacer(6), right));
        }
        var tell = new CheckBox { Content = Ui.Text(L("撤回后告诉 Claude"), 13), IsChecked = true };
        var busy = plan.Truthy("busy");
        Fill(body,
            Ui.Text(L("把第 %lld 轮开始后 Claude 改动的文件恢复到这一轮开始前的样子：", turn), 13).Wrap(),
            Ui.Box(list, new Thickness(12), "Fill05", 10),
            Ui.Text(L("只包括 Claude 用编辑工具改动的文件；在命令行中改动的（脚本生成、sed、Git 操作等）不在其中。撤回前会把这些文件现在的样子另存一份，可以还原。"), 12, color: "Text2").Wrap(),
            tell,
            busy ? Ui.Text(L("Claude 正在工作或在等你确认：请等它停下来，或先处理确认卡片、中断，再撤回"), 12, color: "Orange").Wrap() : null);
        GlassButton? apply = null;
        apply = new GlassButton(L("撤回 %lld 个文件", changes.Count), "arrow.uturn.backward", async () =>
        {
            apply!.IsEnabled = false;
            try
            {
                var reply = await AppModel.Shared.Api.Post("/api/rewind", new { op = "apply", offset }, Q(key));
                if (reply?.Str("error") is string err) { Fill(body, Ui.Text(err, 13, color: "Removed").Wrap()); host.Children.Clear(); return; }
                var count = reply.Int("done") ?? 0;
                var stamp = reply?.Str("undo") ?? "";
                var failed = reply.Arr("failed").Items().Count();
                if (tell.IsChecked == true && count > 0)
                    AppModel.Shared.Send(key, L("我已把第 %lld 轮开始后你用编辑工具改动的 %lld 个文件撤回到那一轮开始前的样子，请以磁盘上现在的内容为准。", turn, count), []);
                Fill(body, Ui.H(8, Ui.Sym("checkmark.circle.fill", 16, "Added"), Ui.Text(L("已撤回 %lld 个文件", count), 15, FontWeight.SemiBold, "Added")),
                    failed > 0 ? Ui.Text(L("%lld 个文件没能恢复，请在电脑上检查", failed), 12, color: "Removed") : null,
                    Ui.Text(L("撤回前的样子已另存一份，点下面的按钮可以还原。"), 12, color: "Text2").Wrap());
                host.Children.Clear();
                host.Children.Add(new GlassButton(L("还原撤回"), "arrow.uturn.forward", async () =>
                {
                    try
                    {
                        var undo = await AppModel.Shared.Api.Post("/api/rewind", new { op = "undo", undo = stamp }, Q(key));
                        if (undo?.Str("error") is string e2) { Fill(body, Ui.Text(e2, 13, color: "Removed").Wrap()); }
                        else
                        {
                            if (tell.IsChecked == true) AppModel.Shared.Send(key, L("刚才撤回的文件已还原到撤回之前的样子。"), []);
                            Fill(body, Ui.H(8, Ui.Sym("arrow.uturn.forward.circle.fill", 16, "Added"), Ui.Text(L("已还原到撤回之前"), 15, FontWeight.SemiBold, "Added")));
                        }
                    }
                    catch (Exception e) { Fill(body, Ui.Text(L("还原失败：%@", e.Message), 13, color: "Removed").Wrap()); }
                    host.Children.Clear();
                }, height: 30));
            }
            catch (Exception e) { Fill(body, Ui.Text(L("撤回失败：%@", e.Message), 13, color: "Removed").Wrap()); host.Children.Clear(); }
        }, prominent: true, height: 30) { IsEnabled = !busy, Opacity = busy ? 0.45 : 1 };
        host.Children.Add(apply);
    }

    static void Fill(StackPanel body, params Control?[] kids)
    {
        body.Children.Clear();
        foreach (var kid in kids) if (kid is not null) body.Children.Add(kid);
    }
}

/// 网页报错：控制台报错、网页异常、失败的网络请求（同 Mac 版 DevLogSheet）
public static class DevLogSheet
{
    public static void Show(string key)
    {
        var body = new StackPanel { Spacing = 10 };
        body.Children.Add(new Spinner().HAlign(HorizontalAlignment.Center).Margin(0, 30, 0, 30));
        Sheets.Show(L("网页错误"), body, 620, 560);
        _ = Load(key, body);
    }

    static async Task Load(string key, StackPanel body)
    {
        JsonNode? reply = null;
        try { reply = await AppModel.Shared.Api.Post("/api/browser", new { op = "devlog" }, new Dictionary<string, string> { ["key"] = key }); } catch { }
        body.Children.Clear();
        var entries = reply.Arr("entries").Items().Reverse().ToList();
        if (entries.Count == 0) { body.Children.Add(Ui.Text(L("没有记录到错误"), 13, color: "Text2")); return; }
        foreach (var row in entries)
        {
            var kind = row.Str("kind") ?? "";
            var url = row.Str("url") ?? "";
            if (kind == "nav") { body.Children.Add(Ui.Text(L("打开 %@", url), 11.5, color: "Text3").Trim()); continue; }
            var error = row.Str("level") == "error";
            var head = Ui.H(6, Ui.Sym(error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill", 12, error ? "Removed" : "Orange"),
                Ui.Text(kind == "network" ? L("网络请求") : kind == "exception" ? L("网页异常") : L("控制台"), 11.5, color: "Text2"), new Spacer(),
                row.Num("t") is double t ? Ui.Text(Format.Clock(t), 11.5, color: "Text3") : null);
            var text = new SelectableTextBlock { Text = row.Str("text") ?? "", FontFamily = Look.Mono, FontSize = ChatType.DetailSize, TextWrapping = TextWrapping.Wrap };
            text.Res(TextBlock.ForegroundProperty, "Text");
            body.Children.Add(Ui.Box(new StackPanel { Spacing = 2, Children = { head, text, url.Length > 0 ? Ui.Text(url, 11, color: "Text2").Trim() : new Control() } },
                new Thickness(10), "Fill05", 8));
        }
    }
}
