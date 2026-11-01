using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

// 会话之间的消息的几样界面（数据见 Model/Peers.cs），同 iOS / Mac 版 Views/PeerViews.swift：
// - PeerCard：对话里的一封信（致 / 来自某会话、纸鸢邮戳、折痕、主题、正文、落款、状态），轻点抬头跳到对方会话
// - PeerOverlay：盖在侧栏会话列表上的一层：头像两侧朝消息方向滚动的虚线（风筝线），纸鸢从发信会话飞到收信会话
// - PeerViews.SettingsSection：设置里的三个开关

/// 对话里的一封信
public sealed class PeerCard : Border
{
    readonly string key;
    readonly ChatItem item;
    readonly PeerInfo peer;
    readonly Flex statusRow = Ui.H(10);
    bool expanded;
    RichText? body;
    Control? expandLink;

    /// 信纸的底色：比普通气泡暖一点、浅一点，一眼看出是一封信
    static IBrush Paper => Palette.Brush(Palette.IsDark ? 0x262422u : 0xFBF8F2u);

    public static Control Make(string key, ChatItem item) => new PeerCard(key, item);

    PeerCard(string key, ChatItem item)
    {
        this.key = key;
        this.item = item;
        peer = item.Peer ?? new PeerInfo(null, null, null, null, null, null, null, null);
        var model = AppModel.Shared;
        var otherKey = OtherKey();
        var other = otherKey is not null && model.Session(otherKey) is SessionInfo s ? s.Title : peer.Name ?? L("其他会话");
        var me = model.Session(key)?.Title ?? L("本会话");

        // 抬头：「致 / 来自 某会话 ›」（能跳过去就可以点），右上角邮戳
        var heading = Ui.H(5,
            Ui.Text(peer.Outgoing ? L("致") : L("来自"), ChatType.Size, color: "Text2"),
            Ui.Text(other, ChatType.Size, FontWeight.SemiBold).Trim().Shrink(),
            otherKey is not null ? Ui.Sym("chevron.right", ChatType.Size * 0.75, "Text3") : null);
        Control head = heading;
        if (otherKey is not null)
        {
            head = new Tap(heading, () => MainModel.Shared.Selection = otherKey, 4).Keys("Transparent", "Transparent")
                .Tip(peer.Outgoing ? L("发给 %@", other) : L("来自 %@", other));
        }
        var top = new DockPanel { LastChildFill = true };
        var stamp = new PeerPostmark(item.Ts) { VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(8, 0, 0, 0) };
        DockPanel.SetDock(stamp, Dock.Right);
        top.Children.Add(stamp);
        top.Children.Add(head.VAlign(VerticalAlignment.Top));

        // 信纸上的一道折痕
        var fold = new Line { StartPoint = new Point(0, 0), EndPoint = new Point(1, 0), Stretch = Stretch.Fill, StrokeThickness = 0.6, StrokeDashArray = [5, 5], Height = 1 };
        fold.Res(Shape.StrokeProperty, "Fill12");

        var stack = new StackPanel { Spacing = ChatType.Px(8) };
        stack.Children.Add(top);
        stack.Children.Add(fold);
        if (Subject() is string subject && subject.Length > 0)
            stack.Children.Add(Ui.Text(subject, ChatType.Size, FontWeight.SemiBold, lines: 0).Wrap());
        var text = BodyText();
        body = new RichText(text, ChatType.Size) { MaxLines = 5 };
        stack.Children.Add(body);
        if (peer.Outgoing)
            stack.Children.Add(Ui.Text("—— " + me, ChatType.Size * 0.9, color: "Text2").Trim().HAlign(HorizontalAlignment.Right));
        if (text.Length > 170 || text.Count(c => c == '\n') > 4)
        {
            var link = Ui.Text(L("展开全文"), ChatType.Size * 0.85, color: "Accent");
            expandLink = new Tap(link, () =>
            {
                expanded = !expanded;
                body.MaxLines = expanded ? 0 : 5;
                link.Text = expanded ? L("收起") : L("展开全文");
            }, 4).Keys("Transparent", "Transparent");
        }
        stack.Children.Add(statusRow);
        UpdateStatus();

        Child = stack;
        Padding = new Thickness(ChatType.PadH + ChatType.Px(2), ChatType.PadV + ChatType.Px(4));
        CornerRadius = new CornerRadius(ChatType.Radius);
        Background = Paper;
        BorderThickness = new Thickness(0.7);
        this.Res(BorderBrushProperty, "Fill10");
        MaxWidth = ChatType.Px(380);
        HorizontalAlignment = HorizontalAlignment.Left;

        // 对方读到、回信了：状态那行跟着变（只在显示着的时候听）；分屏里登记给信绳（同一封信两张信件连起来）
        AttachedToVisualTree += (_, _) => { PeerBoard.Shared.Changed += UpdateStatus; Register(); };
        DetachedFromVisualTree += (_, _) => { PeerBoard.Shared.Changed -= UpdateStatus; PeerRopeBoard.Remove(this); };
        PointerEntered += (_, _) => { if (RopeId() is string id) PeerRopeBoard.Hover(id, true); };
        PointerExited += (_, _) => { if (RopeId() is string id) PeerRopeBoard.Hover(id, false); };
    }

    /// 这封信（往来）的 id：发出的那张、收到的那张一样
    string? RopeId()
    {
        if (!peer.Outgoing) return peer.MsgId;
        var result = item.ToolId is string tool ? AppModel.Shared.Chat(key).Results.GetValueOrDefault(tool) : null;
        return PeerBoard.Shared.LinkFor(item.ToolId, result?.MsgId)?.Id;
    }

    void Register()
    {
        PeerRopeBoard.Remove(this);
        if (RopeId() is string id) PeerRopeBoard.Add(new PeerRopeBoard.Card(this, id, peer.Outgoing, OtherKey()));
    }

    /// 对话项里的「对方会话 id」换成会话 key：往来只在同一台电脑上，来源和当前会话一样
    string? OtherKey()
    {
        var hash = key.IndexOf('#');
        return string.IsNullOrEmpty(peer.Session) || hash < 0 ? null : key[..hash] + "#" + peer.Session;
    }

    /// 主题：发出的用 SendMessage 的摘要；收到的从往来里找（发信那边写的摘要）
    string? Subject() => peer.Outgoing ? peer.Summary
        : peer.MsgId is string id && PeerBoard.Shared.Links.TryGetValue(id, out var link) ? link.Summary : null;

    /// 发出的全文在工具调用的 input.message；收到的全文在 peer.body
    string BodyText() => (peer.Outgoing ? item.Input.Str("message") ?? peer.Text : peer.Body ?? peer.Text ?? item.Text)?.Trim() ?? "";

    /// 发出的：已发出 → 对方已读 → 已回复；没送到标红。收到的：回过没有
    void UpdateStatus()
    {
        if (peer.Outgoing && this.IsAttachedToVisualTree() && !PeerRopeBoard.Cards.Any(c => c.View == this)) Register();
        statusRow.Children.Clear();
        var board = PeerBoard.Shared;
        (string Symbol, string Text, string Color)? status = null;
        if (peer.Outgoing)
        {
            var result = item.ToolId is string tool ? AppModel.Shared.Chat(key).Results.GetValueOrDefault(tool) : null;
            var link = board.LinkFor(item.ToolId, result?.MsgId);
            if (result?.IsError == true || link?.Ok == false) status = ("exclamationmark.circle", L("未送达"), "Removed");
            else if (link is not null && board.Reply(link) is not null) status = ("arrowshape.turn.up.backward", L("对方已回复"), "Text2");
            else if (link?.ReadAt is not null) status = ("checkmark.circle", L("对方已读"), "Text2");
            else if (result is not null || link is not null) status = ("envelope", L("已送达，等待对方处理"), "Text2");
            else status = ("paperplane", L("正在发送…"), "Text3");
        }
        else if (peer.MsgId is string id && board.Links.TryGetValue(id, out var link) && board.Reply(link) is not null)
        {
            status = ("arrowshape.turn.up.backward", L("已回复"), "Text2");
        }
        if (status is var (symbol, text, color))
            statusRow.Children.Add(Ui.H(5, Ui.Sym(symbol, ChatType.Size * 0.85, color), Ui.Text(text, ChatType.Size * 0.85, color: color)));
        statusRow.Children.Add(new Spacer());
        if (expandLink is not null) statusRow.Children.Add(expandLink);
    }
}

/// 信上的邮戳：一圈虚线圆里一只小纸鸢，下面是寄出的时间，略微歪着盖
public sealed class PeerPostmark : Control
{
    readonly double? time;

    public PeerPostmark(double? time)
    {
        this.time = time;
        Width = 38;
        Height = 38;
        RenderTransform = new RotateTransform(-12);
        IsHitTestVisible = false;
    }

    public override void Render(DrawingContext context)
    {
        var accent = Palette.GetColor("Accent");
        var ring = new Pen(new SolidColorBrush(accent, 0.45), 0.9, new DashStyle([2.8, 2.2], 0));
        context.DrawEllipse(null, ring, new Rect(0.5, 0.5, Width - 1, Height - 1));
        KiteMark.DrawStill(context, new Rect(11.5, 6, 15, 15), new SolidColorBrush(accent, 0.8));
        if (time is double ms)
        {
            var label = new FormattedText(Format.Clock(ms), CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                                          new Typeface(Look.Family, FontStyle.Normal, FontWeight.Medium), 8.5, new SolidColorBrush(accent, 0.75));
            context.DrawText(label, new Point((Width - label.Width) / 2, 22));
        }
    }
}

/// 盖在侧栏会话列表上的一层（同 iOS / Mac 版 PeerStage）：
/// - 风筝线：最近 15 分钟里互发过消息、两头都显示在列表里的会话之间连一条虚线，一直朝消息的方向滚动；
///   发给上面会话的线走头像左边，发给下面会话的走右边，箭头指向收信的一方，越久越淡
/// - 纸鸢传信：一只纸鸢从发信会话的头像飞到收信会话的头像，拖着一根线，落下时头像泛起一圈涟漪
/// 只有要画的时候才每秒刷 30 帧，其余时候不动
public sealed class PeerOverlay : Control
{
    /// 列表里显示着的会话：key → 头像（侧栏每次重排后给）
    public Func<IEnumerable<(string Key, Control Avatar)>> Rows { get; set; } = () => [];
    /// 会话列表这块的可见范围（滚动区域）：线只画在这里面
    public Control? Viewport { get; set; }

    const double LaneWindow = 15 * 60_000;
    readonly DispatcherTimer timer;

    public PeerOverlay()
    {
        IsHitTestVisible = false;
        ClipToBounds = true;
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(33), DispatcherPriority.Render, (_, _) => Tick());
        AttachedToVisualTree += (_, _) => { PeerBoard.Shared.Changed += Refresh; PeerPrefs.Changed += Refresh; Refresh(); };
        DetachedFromVisualTree += (_, _) => { PeerBoard.Shared.Changed -= Refresh; PeerPrefs.Changed -= Refresh; timer.Stop(); };
    }

    /// 侧栏重排、往来有变化：看要不要开始动
    public void Refresh()
    {
        if (Busy()) { if (!timer.IsEnabled) timer.Start(); }
        else timer.Stop();
        InvalidateVisual();
    }

    void Tick()
    {
        if (!Busy()) timer.Stop();
        InvalidateVisual();
    }

    bool Busy() =>
        (PeerPrefs.Lanes && Lanes().Count > 0) || (PeerPrefs.Flights && PeerBoard.Shared.Flights.Count > 0) || PeerBoard.Shared.Pulses.Count > 0;

    /// 头像在这一层里的位置（只要还在可见范围里的）
    Dictionary<string, Rect> Frames()
    {
        var frames = new Dictionary<string, Rect>();
        var view = Viewport is not null && Viewport.TranslatePoint(new Point(0, 0), this) is Point vp
            ? new Rect(vp, Viewport.Bounds.Size) : new Rect(Bounds.Size);
        foreach (var (key, avatar) in Rows())
        {
            if (avatar.TranslatePoint(new Point(0, 0), this) is not Point p) continue;
            var rect = new Rect(p, avatar.Bounds.Size);
            if (rect.Bottom > view.Top && rect.Top < view.Bottom) frames[key] = rect;
        }
        return frames;
    }

    List<PeerDirection> Lanes()
    {
        var rows = Rows().Select(r => r.Key).ToHashSet();
        return PeerBoard.Shared.RecentDirections(LaneWindow).Where(d => rows.Contains(d.From) && rows.Contains(d.To)).ToList();
    }

    public override void Render(DrawingContext context)
    {
        var frames = Frames();
        var accent = Palette.GetColor("Accent");
        var seconds = DateTime.UtcNow.TimeOfDay.TotalSeconds;
        if (PeerPrefs.Lanes) DrawLanes(context, frames, accent, seconds);
        foreach (var (key, at) in PeerBoard.Shared.Pulses)
        {
            if (!frames.TryGetValue(key, out var frame)) continue;
            var t = Math.Clamp((DateTime.UtcNow - at).TotalSeconds / 0.9, 0, 1);
            Ring(context, frame.Center, frame.Width / 2 + 2 + 8 * t, 1 - t, accent);
        }
        if (PeerPrefs.Flights)
            foreach (var flight in PeerBoard.Shared.Flights) DrawFlight(context, flight, frames, accent);
    }

    // MARK: 风筝线

    void DrawLanes(DrawingContext context, Dictionary<string, Rect> frames, Color accent, double seconds)
    {
        int up = 0, down = 0;
        foreach (var direction in Lanes())
        {
            if (!frames.TryGetValue(direction.From, out var sender) || !frames.TryGetValue(direction.To, out var receiver)) continue;
            // 收信的在上面 = 上行（走左边），在下面 = 下行（走右边）
            var isUp = receiver.Center.Y < sender.Center.Y;
            var lane = isUp ? up : down;
            if (isUp) { if (up >= 3) continue; up++; } else { if (down >= 2) continue; down++; }
            var x = isUp ? Math.Min(sender.Left, receiver.Left) - 3.5 - lane * 4 : Math.Max(sender.Right, receiver.Right) + 3.5 + lane * 4;
            double EdgeX(Rect r) => isUp ? r.Left - 0.5 : r.Right + 0.5;
            var start = new Point(EdgeX(sender), sender.Center.Y);
            var end = new Point(EdgeX(receiver), receiver.Center.Y);
            var turn = isUp ? -8 : 8;
            var path = new StreamGeometry();
            using (var g = path.Open())
            {
                g.BeginFigure(start, false);
                g.QuadraticBezierTo(new Point(x, start.Y), new Point(x, start.Y + turn));
                g.LineTo(new Point(x, end.Y - turn));
                g.QuadraticBezierTo(new Point(x, end.Y), end);
                g.EndFigure(false);
            }
            var alpha = 0.9 * Math.Max(0.35, 1 - (Format.NowMs - direction.Last) / LaneWindow);
            // 虚线（以线宽为单位：画 2.5、空 2.5，线宽 1.6 → 4 点一段）往收信那头滚：偏移变小 = 往终点走
            const double width = 1.6;
            var offset = -(seconds * 14.5 / width % 5);
            var pen = new Pen(new SolidColorBrush(accent, alpha), width, new DashStyle([2.5, 2.5], offset), PenLineCap.Round);
            context.DrawGeometry(null, pen, path);
            // 箭头：在收信头像旁边，朝着头像
            var back = isUp ? -4.5 : 4.5;
            var head = new StreamGeometry();
            using (var g = head.Open())
            {
                g.BeginFigure(end, true);
                g.LineTo(new Point(end.X + back, end.Y - 3.2));
                g.LineTo(new Point(end.X + back, end.Y + 3.2));
                g.EndFigure(true);
            }
            context.DrawGeometry(new SolidColorBrush(accent, alpha), null, head);
        }
    }

    // MARK: 纸鸢

    void DrawFlight(DrawingContext context, PeerFlight flight, Dictionary<string, Rect> frames, Color accent)
    {
        var raw = PeerBoard.Frozen ?? (DateTime.UtcNow - flight.Start).TotalSeconds / PeerFlight.Duration;
        if (raw is < 0 or > 1.45 || flight.From is null || !frames.TryGetValue(flight.From, out var fromRect)) return;
        var from = fromRect.Center;
        // 对方不在列表可见范围里：飞向下沿
        var to = flight.To is string key && frames.TryGetValue(key, out var toRect) ? toRect.Center : new Point(Bounds.Width / 2, Bounds.Height - 8);
        var t = Math.Min(raw, 1);
        var eased = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;
        // 弧线往右鼓（往内容那边飞，看得见）；距离越远鼓得越多
        var distance = Math.Sqrt(Math.Pow(to.X - from.X, 2) + Math.Pow(to.Y - from.Y, 2));
        var bulge = Math.Clamp(distance * 0.45, 70, 160);
        var c1 = new Point(from.X + bulge, from.Y + (to.Y - from.Y) * 0.15 - 20);
        var c2 = new Point(to.X + bulge, to.Y - (to.Y - from.Y) * 0.15 - 20);
        Point Bezier(double s)
        {
            var u = 1 - s;
            return new Point(u * u * u * from.X + 3 * u * u * s * c1.X + 3 * u * s * s * c2.X + s * s * s * to.X,
                             u * u * u * from.Y + 3 * u * u * s * c1.Y + 3 * u * s * s * c2.Y + s * s * s * to.Y);
        }
        var fade = raw > 1 ? Math.Max(0, 1 - (raw - 1) / 0.45) : 1;
        // 风筝线：从发信那头拖到纸鸢，跟着飞过的路
        var steps = Math.Max((int)(eased * 24), 1);
        var line = new StreamGeometry();
        using (var g = line.Open())
        {
            g.BeginFigure(from, false);
            for (var i = 1; i <= steps; i++) g.LineTo(Bezier(eased * i / steps));
            g.EndFigure(false);
        }
        context.DrawGeometry(null, new Pen(new SolidColorBrush(accent, 0.55 * fade), 1, lineCap: PenLineCap.Round), line);
        if (raw <= 1)
        {
            var here = Bezier(eased);
            var ahead = Bezier(Math.Min(eased + 0.02, 1));
            var angle = Math.Atan2(ahead.Y - here.Y, ahead.X - here.X) + Math.PI / 4;
            var size = 26 * (0.8 + 0.45 * Math.Sin(eased * Math.PI));
            var matrix = Matrix.CreateTranslation(-size / 2, -size / 2) * Matrix.CreateRotation(angle) * Matrix.CreateTranslation(here.X, here.Y);
            using (context.PushTransform(matrix)) KiteMark.DrawStill(context, new Rect(0, 0, size, size), new SolidColorBrush(accent));
        }
        // 落下：收信头像上一圈涟漪
        if (raw > 0.9)
        {
            var s = Math.Min((raw - 0.9) / 0.55, 1);
            var radius = (flight.To is string k && frames.TryGetValue(k, out var r) ? r.Width / 2 : 14) + 3 + 10 * s;
            Ring(context, to, radius, 1 - s, accent);
        }
    }

    static void Ring(DrawingContext context, Point center, double radius, double alpha, Color color) =>
        context.DrawEllipse(null, new Pen(new SolidColorBrush(color, 0.8 * alpha), 1.6), center, radius, radius);

    /// 这个会话的头像现在显示在列表的可见范围里
    public bool Shows(string key) => Frames().ContainsKey(key);
}

/// 纸鸢传信时收信会话不在列表可见范围里（滚出去了、被筛掉了、在别的机器）：纸鸢飞到列表下沿后，
/// 留一个小胶囊「发给 某会话」，轻点打开它（同 iOS / Mac 版 PeerChip）。纸鸢收起时它也收起
public sealed class PeerChipHost : ContentControl
{
    readonly PeerOverlay overlay;
    string? shown;

    public PeerChipHost(PeerOverlay overlay)
    {
        this.overlay = overlay;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Bottom;
        void Changed() => Dispatcher.UIThread.Post(Update);
        AttachedToVisualTree += (_, _) => { PeerBoard.Shared.Changed += Changed; Update(); };
        DetachedFromVisualTree += (_, _) => PeerBoard.Shared.Changed -= Changed;
    }

    public void Update()
    {
        var flight = PeerPrefs.Flights ? PeerBoard.Shared.Flights.LastOrDefault(f => f.To is not string to || !overlay.Shows(to)) : null;
        if (flight?.Id == shown) return;
        shown = flight?.Id;
        Content = flight is null ? null : Chip(flight);
    }

    static Control Chip(PeerFlight flight)
    {
        var label = Ui.H(5, new KiteGlyph(14) { VerticalAlignment = VerticalAlignment.Center }, Ui.Text(L("发给 %@", flight.ToLabel), 12, FontWeight.Medium).Trim());
        var chip = new Tap(label, () => { if (flight.To is string key) MainModel.Shared.Selection = key; }, 14)
        {
            Padding = new Thickness(10, 6), MaxWidth = 260, BorderThickness = new Thickness(0.8),
            BorderBrush = new SolidColorBrush(Palette.GetColor("Accent"), 0.35), IsEnabled = flight.To is not null,
        };
        chip.Keys("GlassSolid", "Fill10");
        return chip;
    }
}

public static class PeerViews
{
    /// 设置窗口「通用」页里的一节：三个开关（存客户端偏好，键和 iOS / Mac 一样）
    public static Control SettingsSection()
    {
        Control Toggle(string title, string key, Func<bool> get)
        {
            var toggle = new ToggleSwitch { IsChecked = get(), OnContent = "", OffContent = "" };
            toggle.IsCheckedChanged += (_, _) => PeerPrefs.Set(key, toggle.IsChecked == true);
            return Ui.H(8, Ui.Text(title, 13).Shrink(), new Spacer(), toggle);
        }
        var footer = Ui.Text(L("会话之间用 SendMessage 互发消息时：纸鸢从发信会话飞到收信会话；最近 15 分钟有往来的会话之间用流动的虚线连起，发给上方会话的在头像左侧、发给下方的在右侧；对话中显示为「致 / 来自」某会话的信件，轻点抬头可跳转。"),
                             11, color: "Text2", lines: 0).Wrap();
        return Ui.VFill(8,
            Ui.Text(L("会话之间的消息"), 12, FontWeight.SemiBold, "Text2"),
            Toggle(L("纸鸢传信"), PeerPrefs.FlightsKey, () => PeerPrefs.Flights),
            Toggle(L("风筝线"), PeerPrefs.LanesKey, () => PeerPrefs.Lanes),
            Toggle(L("对话中的信件"), PeerPrefs.CardsKey, () => PeerPrefs.Cards),
            footer);
    }
}
