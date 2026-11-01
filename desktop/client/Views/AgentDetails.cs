using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

// Agent 详情、设备详情、助手头像（同 Mac / iPhone 版 KitelineKit/Views/AgentDetails.swift）：
// 对话里点助手头像弹出 Agent 详情，头像和昵称放最上面能改（存在电脑上，手机、iPad、电脑都一样），下面只读：哪家 agent、版本、跑在哪、插件、会话、所在设备；
// 设备详情（设置 → 来源、侧栏按来源分组的组头 CPU / 内存）：网络、系统、硬件、装了哪些 agent、Kiteline 组件

/// 头像的底色：几种压低了饱和度的颜色（界面少颜色、不花哨），paper 是浅底深字
public enum FaceTone { Brand, Ink, Slate, Sky, Sage, Sand, Rust, Plum, Paper }

public static class FaceTones
{
    public static readonly FaceTone[] All = Enum.GetValues<FaceTone>();

    public static string Raw(FaceTone tone) => tone.ToString().ToLowerInvariant();

    public static FaceTone Parse(string? raw) => All.FirstOrDefault(t => Raw(t) == raw, FaceTone.Ink);

    public static IBrush Fill(FaceTone tone) => tone switch
    {
        FaceTone.Brand => Palette.Get("Accent"),
        FaceTone.Ink => Palette.Brush(0x383838),
        FaceTone.Slate => Palette.Brush(0x5B6878),
        FaceTone.Sky => Palette.Brush(0x4C7FA8),
        FaceTone.Sage => Palette.Brush(0x6A8A70),
        FaceTone.Sand => Palette.Brush(0xA8875A),
        FaceTone.Rust => Palette.Brush(0xA9614A),
        FaceTone.Plum => Palette.Brush(0x7A6488),
        _ => Palette.Brush(Palette.IsDark ? 0x3A3A3Cu : 0xECE9E3u),
    };

    /// 底上的标志、首字：宣纸底用正文色（淡一点），其余白色
    public static bool Light(FaceTone tone) => tone == FaceTone.Paper;

    public static string Title(FaceTone tone) => tone switch
    {
        FaceTone.Brand => L("主题色"), FaceTone.Ink => L("石墨"), FaceTone.Slate => L("岩灰"), FaceTone.Sky => L("雾蓝"),
        FaceTone.Sage => L("青苔"), FaceTone.Sand => L("沙金"), FaceTone.Rust => L("赭石"), FaceTone.Plum => L("暮紫"), _ => L("宣纸"),
    };
}

/// avatar 字符串解出来的样子：standard（没设，agent 自己的标志）/ mark（某家 agent 的标志或纸鸢，放在某种底色上）/ emoji / text（昵称首字）/ image（上传的图）
public sealed record FaceSpec(string Kind, string Value = "", FaceTone Tone = FaceTone.Ink)
{
    public static readonly FaceSpec Standard = new("standard");

    public static FaceSpec Parse(string? raw)
    {
        var parts = (raw ?? "").Split(':');
        FaceTone Tone(int i) => parts.Length > i ? FaceTones.Parse(parts[i]) : FaceTone.Ink;
        return parts[0] switch
        {
            "mark" when parts.Length >= 2 && parts[1].Length > 0 => new("mark", parts[1], Tone(2)),
            "emoji" when parts.Length >= 2 && parts[1].Length > 0 => new("emoji", parts[1], Tone(2)),
            "text" => new("text", "", Tone(1)),
            "image" when parts.Length >= 2 && parts[1].Length > 0 => new("image", parts[1]),
            _ => Standard,
        };
    }

    public string Raw => Kind switch
    {
        "mark" => $"mark:{Value}:{FaceTones.Raw(Tone)}",
        "emoji" => $"emoji:{Value}:{FaceTones.Raw(Tone)}",
        "text" => $"text:{FaceTones.Raw(Tone)}",
        "image" => $"image:{Value}",
        _ => "",
    };

    public bool HasTone => Kind is "mark" or "emoji" or "text";

    /// 换底色（图片和默认样子没有底色，原样）
    public FaceSpec With(FaceTone tone) => HasTone ? this with { Tone = tone } : this;
}

/// 助手的头像：用户设过就按设的画（标志 / 表情 / 昵称首字 / 上传的图），没设过是 agent 自己的样子（AgentAvatar）。corner 是圆角占边长的比例
public static class AgentFaceView
{
    static readonly FontFamily EmojiFont = new("Segoe UI Emoji, Noto Color Emoji, Apple Color Emoji, sans-serif");

    public static Control Make(string agent, AgentFace? face, double size, double corner = 0.27)
    {
        var spec = FaceSpec.Parse(face?.Avatar);
        Border Tile(IBrush fill, Control content)
        {
            content.HorizontalAlignment = HorizontalAlignment.Center;
            content.VerticalAlignment = VerticalAlignment.Center;
            return new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size * corner), Background = fill, Child = content, ClipToBounds = true };
        }
        Control Glyph(string id, double scale, FaceTone tone)
        {
            var light = FaceTones.Light(tone);
            return new AgentGlyph(id, size * scale, light ? "Text" : "White") { Opacity = light ? 0.78 : 1 };
        }
        switch (spec.Kind)
        {
            case "mark":
                IBrush ink = FaceTones.Light(spec.Tone) ? new SolidColorBrush(Palette.GetColor("Text"), 0.78) : Brushes.White;
                return Tile(FaceTones.Fill(spec.Tone), spec.Value == "kite" ? new KiteGlyph(size * 0.66, ink) : Glyph(spec.Value, 0.56, spec.Tone));
            case "emoji":
                return Tile(FaceTones.Fill(spec.Tone), new TextBlock { Text = spec.Value, FontSize = size * 0.5, FontFamily = EmojiFont });
            case "text":
                var name = (face?.Name ?? "").Trim();
                var initials = new TextBlock { Text = Format.Initials(name.Length > 0 ? name : Agents.Info(agent).Speaker), FontSize = size * 0.4, FontWeight = FontWeight.SemiBold };
                if (FaceTones.Light(spec.Tone)) { initials.Res(TextBlock.ForegroundProperty, "Text"); initials.Opacity = 0.78; }
                else initials.Foreground = Brushes.White;
                return Tile(FaceTones.Fill(spec.Tone), initials);
            case "image":
                var tile = Tile(Palette.Get("Fill08"), new Border());
                ImageCache.Load("/api/agent-avatar", new Dictionary<string, string> { ["id"] = spec.Value },
                    bitmap => tile.Child = new Image { Source = bitmap, Stretch = Stretch.UniformToFill, Width = size, Height = size });
                return tile;
            default:
                return AgentAvatar.Make(agent, size);
        }
    }
}

/// 对话里助手的头像（每段第一条）：在 Agent 详情里改了头像就跟着换；点了打开 Agent 详情
public sealed class ChatAgentAvatar : Tap
{
    public ChatAgentAvatar(string key, string agent, double size) : base(null, () => AgentDetails.Open(key), size * 0.27)
    {
        Keys("Transparent", "Transparent");
        this.Tip(L("Agent 详情"));
        void Draw() => Child = AgentFaceView.Make(agent, AppModel.Shared.Face(key), size);
        void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs e) { if (e.PropertyName == nameof(AppModel.Faces)) Draw(); }
        AttachedToVisualTree += (_, _) => { AppModel.Shared.PropertyChanged += Changed; Draw(); };
        DetachedFromVisualTree += (_, _) => AppModel.Shared.PropertyChanged -= Changed;
        Draw();
    }
}

/// 侧栏会话卡片的头像：这个会话自己设了头像就画它（agent 默认的不影响列表），没设画 fallback（标题首字）
public static class SessionFace
{
    public static Control? Make(string key, double size, double corner) =>
        AppModel.Shared.Faces.Sessions.GetValueOrDefault(key) is { Avatar.Length: > 0 } face
            ? AgentFaceView.Make(AppModel.Shared.Session(key)?.Agent ?? Agents.DefaultId, face, size, corner) : null;
}

/// 详情里各种代号换成给人看的字（同 Mac 版 DetailText）
static class DetailText
{
    public static string Frontend(string entry, bool tmux) => entry switch
    {
        "claude-vscode" or "codex-vscode" => L("VS Code 扩展"),
        "cli" or "codex" or "opencode" or "qwen-code" => tmux ? L("终端（tmux）") : L("终端"),
        "codex-desktop" or "claude-desktop" or "dsh" or "proma" => L("桌面版"),
        _ when entry.StartsWith("sdk") => "SDK",
        "" => tmux ? L("终端（tmux）") : "—",
        _ => entry,
    };

    static string Form(string form) => form switch { "cli" => L("终端"), "vscode" => L("VS Code 扩展"), "desktop" => L("桌面版"), _ => form };

    /// 「终端 · VS Code 扩展 1.2.3 · 桌面版 26.1」
    public static string Forms(JsonObject? forms)
    {
        if (forms is null) return "";
        string[] order = ["cli", "vscode", "desktop"];
        return string.Join(" · ", forms.Select(p => (p.Key, Value: p.Value?.ToString() ?? ""))
            .OrderBy(p => Array.IndexOf(order, p.Key) is var i && i >= 0 ? i : 9).ThenBy(p => p.Key)
            .Select(p => p.Value.Length == 0 ? Form(p.Key) : $"{Form(p.Key)} {p.Value}"));
    }

    public static string Abilities(IEnumerable<string> list)
    {
        var names = new Dictionary<string, string> { ["view"] = L("查看"), ["reply"] = L("回复"), ["approve"] = L("审批"), ["answer"] = L("回答提问") };
        return string.Join(" · ", list.Where(names.ContainsKey).Select(a => names[a]));
    }

    /// 插件：内置 2.24.0 / 单独安装 1.0.1
    public static string Plugin(JsonNode? agent) =>
        string.Join(" ", new[] { agent.Str("source") == "external" ? L("单独安装") : L("内置"), agent.Str("plugin") ?? "" }.Where(s => s.Length > 0));

    /// 开机多久：3 天 4 小时 / 5 小时 12 分钟 / 8 分钟
    public static string Uptime(double seconds)
    {
        var minutes = (int)(seconds / 60);
        var hours = minutes / 60;
        var days = hours / 24;
        if (days > 0) return L("%lld 天", days) + " " + L("%lld 小时", hours % 24);
        if (hours > 0) return L("%lld 小时", hours) + " " + L("%lld 分钟", minutes % 60);
        return L("%lld 分钟", Math.Max(minutes, 1));
    }

    public static string MachineKind(JsonNode? detail) => detail.Str("kind") == "ssh" ? "Remote-SSH" : L("本机");

    /// 「Mac Studio（本机）」「gpu-server · Remote-SSH」：本机的来源名多半就叫「本机」，换成电脑名
    public static string MachineName(JsonNode? detail)
    {
        var name = detail.Str("name") ?? "";
        if (detail.Str("kind") == "ssh") return name + " · Remote-SSH";
        var computer = detail.Str("computer") is { Length: > 0 } c ? c : name;
        return computer == L("本机") || computer == "本机" ? computer : L("%@（本机）", computer);
    }
}

public static class AgentDetails
{
    static Net.Api Api => AppModel.Shared.Api;

    // MARK: 共用的行

    /// 一行：名字、值（能拷贝的右键「复制」，等宽的用编辑器字体）
    static Control Row(string title, string value, bool copy = false, bool mono = false)
    {
        var text = Ui.Text(value, 13, color: "Text2").Trim();
        if (mono) { text.FontFamily = Look.Mono; text.FontSize = Look.Pt(12); text.TextTrimming = TextTrimming.PrefixCharacterEllipsis; }
        var row = Ui.H(12, Ui.Text(title, 13), new Spacer(), text.Shrink()).Pad(12, 9);
        if (copy)
        {
            row.Tip(value);
            row.ContextMenu = new ContextMenu { ItemsSource = new Control[] { Ui.Item(L("复制"), () => SessionMenu.Copy(value)) } };
        }
        return row;
    }

    static Control Rows(IEnumerable<Control?> rows) => ChatSheets.Group(rows.OfType<Control>(), 12);

    // MARK: Agent 详情

    /// 自测截图：打开 Agent 详情时把头像选择展开
    public static bool DemoPick;

    public static void Open(string key)
    {
        var agent = AppModel.Shared.Session(key)?.Agent ?? Agents.DefaultId;
        NavSheet.Open(L("Agent 详情"), _ => new AgentInfoView(key, agent), 560, 760);
    }

    /// Agent 详情的内容：顶上头像 + 昵称（能改），下面只读的几块
    sealed class AgentInfoView : ContentControl
    {
        readonly string key;
        string agent;
        JsonNode? detail;
        string? error;
        string scope = "session";
        bool picking;
        string name = "";
        string savedName = "";
        readonly TextBox nameBox;
        readonly ContentControl faceHost = new();
        readonly ContentControl body = new();
        readonly ContentControl pickerHost = new();
        readonly TextBlock subtitle = Ui.Text("", 12.5, color: "Text2").Trim();

        AgentInfo Info => Agents.Info(detail.Str("agent") is { Length: > 0 } id ? id : agent);
        string AgentId => detail.Str("agent") is { Length: > 0 } id ? id : agent;
        AgentFace? Face => AppModel.Shared.Faces.Face(key, AgentId);

        public AgentInfoView(string key, string agent)
        {
            this.key = key;
            this.agent = agent;
            picking = DemoPick;
            nameBox = new TextBox
            {
                Watermark = Agents.Info(agent).Speaker, FontSize = 18, FontWeight = FontWeight.SemiBold, TextAlignment = TextAlignment.Center,
                MaxWidth = 280, MinWidth = 160, HorizontalAlignment = HorizontalAlignment.Center, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
            };
            nameBox.TextChanged += (_, _) => { name = nameBox.Text ?? ""; DrawFace(); if (picking) DrawPicker(); };
            nameBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) { _ = Save(null, null); e.Handled = true; } };
            nameBox.LostFocus += (_, _) => { if (name != savedName) _ = Save(null, null); };
            var faceTap = new Tap(faceHost, () => { picking = !picking; DrawPicker(); DrawFace(); }, 20).Keys("Transparent", "Transparent");
            faceTap.HorizontalAlignment = HorizontalAlignment.Center;
            var header = new StackPanel { Spacing = 8, Margin = new Thickness(0, 6, 0, 14) };
            header.Children.Add(faceTap);
            header.Children.Add(nameBox);
            header.Children.Add(subtitle.HAlign(HorizontalAlignment.Center));
            var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
            stack.Children.Add(header);
            stack.Children.Add(pickerHost);
            stack.Children.Add(body);
            Content = NavSheet.Scroll(stack);
            AppModel.Shared.PropertyChanged += Changed;
            // 关面板时昵称改了还没存：存上
            DetachedFromVisualTree += (_, _) =>
            {
                AppModel.Shared.PropertyChanged -= Changed;
                if (name != savedName) _ = Save(null, null);
            };
            DrawFace();
            DrawPicker();
            Draw();
            _ = Load();
        }

        void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(AppModel.Faces)) { DrawFace(); DrawPicker(); Draw(); }
        }

        void DrawFace()
        {
            var face = AgentFaceView.Make(AgentId, new AgentFace(name, Face?.Avatar ?? ""), 76, 0.25);
            // 头像 76 放左上，右下角伸出 6 点放小圆标（整块 82，别用负边距：外面的点按区域会把伸出去的裁掉）
            face.HorizontalAlignment = HorizontalAlignment.Left;
            face.VerticalAlignment = VerticalAlignment.Top;
            var badge = new Border
            {
                Width = 24, Height = 24, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(2),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
                Child = Ui.Sym(picking ? "chevron.up" : "pencil", 11, "White").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center),
            }.Res(Border.BackgroundProperty, "WechatGreen").Res(Border.BorderBrushProperty, "Sheet");
            faceHost.Content = new Panel { Width = 82, Height = 82, Children = { face, badge } }.Tip(picking ? L("收起头像选择") : L("更换头像"));
            var parts = new List<string> { Info.Name };
            if (detail is not null) parts.Add(DetailText.Frontend(detail.Str("entrypoint") ?? "", detail.Bool("tmux") == true));
            if (detail.Obj("machine").Str("name") is { Length: > 0 } machine) parts.Add(machine);
            subtitle.Text = string.Join(" · ", parts.Where(p => p != "—"));
        }

        void DrawPicker() => pickerHost.Content = picking ? FacePicker.Make(AgentId, FaceSpec.Parse(Face?.Avatar), ShownName, (spec, image) => _ = Save(spec?.Raw, image)) : null;

        string ShownName => name.Trim() is { Length: > 0 } n ? n : Info.Speaker;

        void Draw()
        {
            var stack = new StackPanel();
            var info = Info;
            stack.Children.Add(Rows([
                Form.Toggle(L("用于所有 %@ 会话", info.Name), scope == "agent", on => _ = SetScope(on ? "agent" : "session")),
                Face is { IsEmpty: false }
                    ? new Tap(Ui.Text(L("恢复默认头像和昵称"), 13, color: "Removed").Pad(12, 9), () => _ = Reset(), 0).Keys("Transparent", "Fill05")
                    : null,
            ]));
            stack.Children.Add(ChatSheets.Note(scope == "agent"
                ? L("此电脑上所有 %@ 会话（包括之后的新会话）都使用这个头像和昵称；单独设置过的会话除外。", info.Name)
                : L("头像和昵称保存在电脑上，连接这台电脑的手机、iPad 和电脑上都会同步显示。")));
            if (detail is not null)
            {
                var plugin = detail.Obj("plugin");
                var abilities = plugin.Arr("abilities")?.Select(a => a?.ToString() ?? "").ToList() ?? [];
                var forms = plugin.Obj("forms");
                stack.Children.Add(ChatSheets.Header("Agent"));
                stack.Children.Add(Rows([
                    Row(L("类型"), info.Name),
                    detail.Str("version") is { } version ? Row(L("版本"), version) : null,
                    Row(L("运行于"), DetailText.Frontend(detail.Str("entrypoint") ?? "", detail.Bool("tmux") == true) + (detail.Obj("machine").Str("kind") == "ssh" ? " · Remote-SSH" : "")),
                    plugin is not null ? Row(L("Kiteline 插件"), DetailText.Plugin(plugin)) : null,
                    abilities.Count > 0 ? Row(L("可远程"), DetailText.Abilities(abilities)) : null,
                    forms is { Count: > 0 } ? Row(L("已安装"), DetailText.Forms(forms)) : null,
                ]));
                if (detail.Bool("live") == true)
                {
                    stack.Children.Add(ChatSheets.Header(L("会话")));
                    stack.Children.Add(Rows([
                        Row(L("标题"), detail.Str("title") ?? "—"),
                        detail.Str("model") is { } model ? Row(L("模型"), model) : null,
                        detail.Num("startedAt") is double started ? Row(L("开始于"), Format.MessageTime(started)) : null,
                        detail.Num("pid") is double pid ? Row(L("进程"), ((long)pid).ToString(), copy: true) : null,
                        detail.Str("sessionId") is { } id ? Row(L("会话 ID"), id, copy: true, mono: true) : null,
                        detail.Str("cwd") is { Length: > 0 } cwd ? Row(L("目录"), cwd, copy: true, mono: true) : null,
                    ]));
                }
                if (detail.Obj("machine") is JsonObject machine)
                    foreach (var part in MachineSections(machine, compact: true)) stack.Children.Add(part);
            }
            else if (error is not null)
            {
                stack.Children.Add(Ui.Stack(Orientation.Vertical, 10, Align.Center, [Ui.Text(error, 13, color: "Text2", lines: 3).Wrap(), Form.Button(L("重试"), () => _ = Load())])
                    .HAlign(HorizontalAlignment.Center).Margin(20, 20, 20, 0));
            }
            else
            {
                stack.Children.Add(new Spinner(18).HAlign(HorizontalAlignment.Center).Margin(0, 30, 0, 0));
            }
            body.Content = stack;
        }

        async Task Load()
        {
            try
            {
                var loaded = await Api.Get("/api/agent-info", new Dictionary<string, string> { ["key"] = key, ["agent"] = agent });
                detail = loaded;
                error = null;
                if (loaded.Str("agent") is { Length: > 0 } id) agent = id;
                // 会话自己设过就是改会话的；只有默认的（或都没有、但默认的设过）就是改默认的
                var own = AgentFace.Parse(loaded.Get("face"));
                var shared = AgentFace.Parse(loaded.Get("agentFace"));
                scope = own is null && shared is not null ? "agent" : "session";
                if (!nameBox.IsFocused)
                {
                    name = (own ?? shared)?.Name ?? "";
                    savedName = name;
                    nameBox.Text = name;
                }
                DrawPicker();
            }
            catch (Exception e)
            {
                if (detail is null) error = e.Message;
            }
            DrawFace();
            Draw();
        }

        /// 存一次：avatar 为 null = 头像不变（只改了昵称）；image = 上传的图（JPEG）
        async Task Save(string? avatar, byte[]? image, string? target = null, string? nameOverride = null)
        {
            var clean = (nameOverride ?? name).Trim();
            var body = new JsonObject
            {
                ["key"] = key, ["agent"] = AgentId, ["scope"] = target ?? scope, ["name"] = clean, ["avatar"] = avatar ?? Face?.Avatar ?? "",
            };
            if (image is not null) body["image"] = Convert.ToBase64String(image);
            try
            {
                var reply = await Api.Post("/api/agent-face", body);
                savedName = clean;
                AppModel.Shared.SetFaces(reply);
            }
            catch (Exception e) { AppModel.Shared.Show(e); }
        }

        /// 「用于所有会话」开关：开 = 现在的头像昵称变成这家 agent 的默认（会话自己的那份不再留）；关 = 这个会话自己留一份，默认的清掉
        async Task SetScope(string next)
        {
            if (next == scope) return;
            var avatar = Face?.Avatar ?? "";
            scope = next;
            if (next == "agent")
            {
                await Save(avatar, null, "agent");
            }
            else
            {
                await Save(avatar, null, "session");
                await Save("", null, "agent", "");
            }
            AppModel.Shared.Flash(next == "agent" ? L("已用于所有 %@ 会话", Info.Name) : L("仅用于此会话"));
            Draw();
        }

        async Task Reset()
        {
            name = "";
            nameBox.Text = "";
            await Save("", null, nameOverride: "");
            picking = false;
            DrawPicker();
            AppModel.Shared.Flash(L("已恢复默认"));
        }
    }

    // MARK: 选头像

    /// 头像选择：上传图片、agent 自己的标志、纸鸢、昵称首字、表情，下面一排底色。点了马上存
    static class FacePicker
    {
        static readonly string[] Emojis = ["🦊", "🐱", "🐼", "🐨", "🦉", "🐙", "🐳", "🐧", "🦁", "🐯", "🐶", "🐰",
                                           "🐢", "🐝", "🦄", "🐲", "🤖", "👾", "🚀", "⚡️", "🌙", "🔥", "🍀", "☕️"];

        public static Control Make(string agent, FaceSpec current, string name, Action<FaceSpec?, byte[]?> choose)
        {
            var tone = current.HasTone ? current.Tone : agent == Agents.DefaultId ? FaceTone.Brand : FaceTone.Ink;
            var grid = new WrapPanel { ItemWidth = 72, ItemHeight = 78 };
            var tones = new UniformGrid { Rows = 1, Margin = new Thickness(0, 4, 0, 0) };
            var host = new StackPanel { Spacing = 8 };
            void Build()
            {
                grid.Children.Clear();
                grid.Children.Add(Upload(agent, choose));
                Option(FaceSpec.Standard, L("默认"));
                Option(new FaceSpec("mark", agent, tone), L("标志"));
                Option(new FaceSpec("mark", "kite", tone), L("纸鸢"));
                Option(new FaceSpec("text", "", tone), L("首字"));
                if (current.Kind == "image") Option(current, L("照片"));
                foreach (var emoji in Emojis) Option(new FaceSpec("emoji", emoji, tone), null);
                tones.Children.Clear();
                foreach (var item in FaceTones.All)
                {
                    var dot = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(13), Background = FaceTones.Fill(item), BorderThickness = new Thickness(item is FaceTone.Paper or FaceTone.Ink ? 1 : 0) }
                        .Res(Border.BorderBrushProperty, "Fill15");
                    var ring = new Border { Padding = new Thickness(3), CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(2), Child = dot, BorderBrush = Brushes.Transparent };
                    if (item == tone) ring.Res(Border.BorderBrushProperty, "WechatGreen");
                    var picked = item;
                    tones.Children.Add(new Tap(ring, () =>
                    {
                        tone = picked;
                        // 现在用的是有底色的样子：换底色直接存
                        if (current.HasTone) choose(current.With(picked), null);
                        Build();
                    }, 16) { HorizontalAlignment = HorizontalAlignment.Center }.Keys("Transparent", "Transparent").Tip(FaceTones.Title(item)));
                }
            }
            void Option(FaceSpec spec, string? label)
            {
                var selected = spec == current || (spec.HasTone && spec.With(FaceTone.Ink) == current.With(FaceTone.Ink) && current.Tone == tone);
                var face = AgentFaceView.Make(agent, new AgentFace(name, spec.Raw), 44, 0.25);
                var frame = new Border { Padding = new Thickness(3), CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(2.5), Child = face, BorderBrush = Brushes.Transparent };
                if (selected) frame.Res(Border.BorderBrushProperty, "WechatGreen");
                var cell = new StackPanel { Spacing = 3, HorizontalAlignment = HorizontalAlignment.Center };
                cell.Children.Add(frame);
                if (label is not null) cell.Children.Add(Ui.Text(label, 11, color: "Text2").HAlign(HorizontalAlignment.Center));
                grid.Children.Add(new Tap(cell, () => choose(spec, null), 8).Keys("Transparent", "Fill05"));
            }
            Build();
            host.Children.Add(grid);
            host.Children.Add(Ui.Text(L("底色"), 12, color: "Text2").Margin(2, 6, 0, 0));
            host.Children.Add(tones);
            return new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 14), Child = host }
                .Res(Border.BackgroundProperty, "Fill05");
        }

        static Control Upload(string agent, Action<FaceSpec?, byte[]?> choose)
        {
            var tile = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(11), Child = Ui.Sym("photo.badge.plus", 17, "Text2").HAlign(HorizontalAlignment.Center).VAlign(VerticalAlignment.Center) }
                .Res(Border.BackgroundProperty, "Fill08");
            var cell = new StackPanel { Spacing = 3, HorizontalAlignment = HorizontalAlignment.Center };
            cell.Children.Add(new Border { Padding = new Thickness(5), Child = tile });
            cell.Children.Add(Ui.Text(L("上传"), 11, color: "Text2").HAlign(HorizontalAlignment.Center));
            return new Tap(cell, async () =>
            {
                var window = Dialog.Owner() ?? MainWindow.Current;
                if (window is null) return;
                var files = await window.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { Title = L("选择头像"), FileTypeFilter = [FilePickerFileTypes.ImageAll] });
                if (files.FirstOrDefault()?.TryGetLocalPath() is string path && ImagePrep.Prepare(File.ReadAllBytes(path)) is { } prepared) choose(null, prepared.Jpeg);
            }, 8).Keys("Transparent", "Fill05").Tip(L("选择一张图片（将居中裁剪为正方形）"));
        }
    }

    // MARK: 设备详情

    public static void OpenMachine(string sourceId, string name = "")
    {
        NavSheet.Open(name.Length > 0 ? name : L("设备详情"), _ => NavSheet.Load(async () =>
        {
            var detail = await Api.Get("/api/machine", new Dictionary<string, string> { ["source"] = sourceId });
            var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
            stack.Children.Add(MachineHeader(detail));
            foreach (var part in MachineSections(detail, compact: false)) stack.Children.Add(part);
            return NavSheet.Scroll(stack);
        }), 560, 720);
    }

    static Control MachineHeader(JsonNode? detail)
    {
        var ssh = detail.Str("kind") == "ssh";
        var name = detail.Str("name") ?? "";
        var computer = detail.Str("computer") is { Length: > 0 } c && c != name ? c : name;
        var online = detail.Bool("online") == true;
        var sessions = (int)(detail.Num("sessions") ?? 0);
        var status = string.Join(" · ", new[] { DetailText.MachineKind(detail), online ? L("在线") : L("离线"), sessions > 0 ? L("%lld 个会话", sessions) : null }.OfType<string>());
        var dot = new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), VerticalAlignment = VerticalAlignment.Center }.Res(Border.BackgroundProperty, online ? "Added" : "Text3");
        return Ui.H(14, new DuoIcon(ssh ? "server.rack" : "desktopcomputer", 52),
            Ui.VFill(4, Ui.Text(computer, 15, FontWeight.SemiBold).Trim(), Ui.H(5, dot, Ui.Text(status, 12.5, color: "Text2").Trim()))).Margin(2, 4, 2, 6);
    }

    /// 设备详情的几块（Agent 详情里也用：compact 时只放一块「设备」，是网络、系统、硬件里最常看的几行）
    static IEnumerable<Control> MachineSections(JsonNode? detail, bool compact)
    {
        var info = detail.Obj("info");
        var id = detail.Str("id") ?? "";
        var live = AppModel.Shared.LiveStats(id) is not null ? Ui.H(12, Ui.Text(L("当前占用"), 13), new Spacer(), new MachineStatsRow(AppModel.Shared, id)).Pad(12, 9) : null;
        if (compact)
        {
            yield return ChatSheets.Header(L("设备"));
            var os = info.Str("os") is { } o ? o + (info.Str("arch") is { } a ? " · " + a : "") : null;
            yield return Rows(new[] { Row(L("名称"), DetailText.MachineName(detail)) }
                .Concat(Addresses(detail, info, all: false))
                .Append(os is null ? null : Row(L("系统"), os))
                .Append(CpuText(info) is { } cpu ? Row(L("处理器"), cpu) : null)
                .Append(live));
            if (Note(detail) is { } note) yield return note;
            yield break;
        }
        yield return ChatSheets.Header(L("网络"));
        var network = new List<Control?>
        {
            detail.Str("sshHost") is { } host ? Row(L("SSH 地址"), host, copy: true) : null,
            info.Str("hostname") is { } hostname ? Row(L("主机名"), hostname, copy: true) : null,
        };
        network.AddRange(Addresses(detail, info, all: true));
        yield return Rows(network.Any(r => r is not null) ? network : [Row(L("IP 地址"), "—")]);
        yield return ChatSheets.Header(L("系统"));
        yield return Rows([
            Row(L("系统"), info.Str("os") ?? "—"),
            info.Str("arch") is { } arch ? Row(L("架构"), arch) : null,
            info.Str("user") is { } user ? Row(L("用户"), user) : null,
            info.Num("uptime") is double uptime ? Row(L("已运行"), DetailText.Uptime(uptime)) : null,
        ]);
        yield return ChatSheets.Header(L("硬件"));
        var cores = info.Num("cores") ?? (double?)AppModel.Shared.LiveStats(id)?.Cores;
        yield return Rows([
            Row(L("处理器"), info.Str("cpuModel") is { Length: > 0 } model ? model : "—"),
            cores is double n ? Row(L("核心数"), ((int)n).ToString()) : null,
            info.Num("memTotal") is double mem ? Row(L("内存"), MachineFormat.Gigabytes(mem)) : null,
            info.Num("diskTotal") is double total && info.Num("diskFree") is double free
                ? Row(L("磁盘"), L("可用 %@，共 %@", MachineFormat.Gigabytes(free), MachineFormat.Gigabytes(total))) : null,
            live,
        ]);
        if (Note(detail) is { } why) yield return why;
        var agents = detail.Arr("agents")?.Where(a => a.Bool("installed") == true).ToList() ?? [];
        if (agents.Count > 0)
        {
            yield return ChatSheets.Header("Agent");
            yield return Rows(agents.Select(a =>
            {
                var lines = new List<Control?> { Ui.Text(a.Str("name") ?? a.Str("id") ?? "", 13) };
                if (a.Obj("forms") is { Count: > 0 } forms) lines.Add(Ui.Text(DetailText.Forms(forms), 11.5, color: "Text2").Trim());
                lines.Add(Ui.Text(L("Kiteline 插件：%@", DetailText.Plugin(a)), 11.5, color: "Text2").Trim());
                return (Control)Ui.HTop(10, new AgentGlyph(a.Str("id"), 16, "Text2") { Width = 20, Margin = new Thickness(0, 1, 0, 0) },
                    Ui.VFill(2, lines.OfType<Control>().ToArray()).Shrink()).Pad(12, 10);
            }));
        }
        var busy = (int)(detail.Num("busy") ?? 0);
        var count = (int)(detail.Num("sessions") ?? 0);
        yield return ChatSheets.Header("Kiteline");
        yield return Rows([
            Row(L("连接"), detail.Str("status") ?? (detail.Bool("online") == true ? L("在线") : L("离线"))),
            (info.Str("watcher") ?? detail.Str("watcher")) is { } watcher ? Row(L("组件版本"), watcher) : null,
            info.Str("python") is { } python ? Row("Python", python) : null,
            Row(L("会话"), busy > 0 ? L("%@ 个，%@ 个运行中", count, busy) : L("%lld 个会话", count)),
        ]);
    }

    /// IP：主 IP（去外网用的那块网卡）排第一，all 时其余网卡的跟在后面；没有系统信息时简版给 SSH 地址
    static IEnumerable<Control?> Addresses(JsonNode? detail, JsonNode? info, bool all)
    {
        if (info is null)
        {
            if (!all && detail.Str("sshHost") is { } host) yield return Row(L("SSH 地址"), host, copy: true);
            yield break;
        }
        var ips = info.Arr("ips")?.Select(i => (Name: i.Str("name") ?? "", Ip: i.Str("ip") ?? "")).Where(i => i.Ip.Length > 0).ToList() ?? [];
        // Remote-SSH 的机器：SSH 连的就是它的某个 IP 时，那个最有用，排第一
        var sshIp = detail.Str("sshHost") is { } ssh ? ssh.Split('@')[^1].Split(':')[0] : null;
        var primary = ips.FirstOrDefault(i => i.Ip == sshIp).Ip ?? info.Str("primaryIp") ?? ips.FirstOrDefault().Ip;
        if (string.IsNullOrEmpty(primary)) yield break;
        var card = ips.FirstOrDefault(i => i.Ip == primary).Name ?? "";
        yield return Row(L("IP 地址"), primary + (card.Length == 0 ? "" : $"（{card}）"), copy: true);
        if (!all) yield break;
        foreach (var other in ips.Where(i => i.Ip != primary)) yield return Row(other.Name.Length == 0 ? L("其他地址") : other.Name, other.Ip, copy: true);
    }

    static string? CpuText(JsonNode? info)
    {
        var parts = new[] { info.Str("cpuModel") is { Length: > 0 } name ? name : null, info.Num("cores") is double cores ? L("%lld 核", (int)cores) : null }.OfType<string>().ToList();
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    /// 读不到系统信息时说一句为什么
    static Control? Note(JsonNode? detail)
    {
        if (detail.Obj("info") is not null) return null;
        return ChatSheets.Note(detail.Bool("online") != true ? L("设备离线，暂时无法读取系统信息。")
            : detail.Str("infoError") == "outdated" ? L("该设备上的 Kiteline 组件版本较旧，更新后可查看系统信息（IP、处理器、内存等）。")
            : L("暂时无法读取系统信息：%@", detail.Str("detail") ?? ""));
    }
}
