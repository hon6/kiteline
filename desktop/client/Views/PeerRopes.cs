using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Rendering;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Kiteline.Model;
using Kiteline.UI;

namespace Kiteline.Views;

// 分屏里的信绳（同 Mac / iPad 版 Views/PeerRopes.swift）：同一封信在发信那列（致…）和收信那列（来自…）各有一张信件，用一根绳子连起来；
// 另一张滚出了那一列时，绳子钉在那一列消息区的上沿 / 下沿，提示它在上面还是下面。
// 绳子是一串小点（Verlet 积分）：受重力自然垂着，两列各自滚动时两头跟着走、先绷着再慢慢放松；按住绳子能拖长，松手弹回去、晃几下停下。
// 平时细而淡、不挡字，鼠标停在信件或绳子上时才显眼。只有贴着绳子的地方接鼠标，别处照常穿透。

/// 对话里登记着的信件（PeerCard 显示时登记、移走时注销）
public static class PeerRopeBoard
{
    public sealed record Card(PeerCard View, string Id, bool Outgoing, string? Peer);

    public static readonly List<Card> Cards = [];
    /// 鼠标停在哪封信的信件上
    public static string? Hovered { get; private set; }
    public static event Action? Changed;

    public static void Add(Card card) { Cards.Add(card); Changed?.Invoke(); }
    public static void Remove(PeerCard view) { Cards.RemoveAll(c => c.View == view); Changed?.Invoke(); }

    public static void Hover(string id, bool inside)
    {
        var next = inside ? id : (Hovered == id ? null : Hovered);
        if (next == Hovered) return;
        Hovered = next;
        Changed?.Invoke();
    }
}

/// 盖在整个分屏上的一层（ChatPanesView 挂的）：对照信件的位置增删绳子、走物理、画
public sealed class PeerRopeLayer : Control, ICustomHitTest
{
    sealed class Rope
    {
        public const int Count = 22;
        public Point[] Points;
        public Point[] Previous;
        public (Point A, Point B) Ends;
        public double Length;
        public int? Grabbed;
        public Point Grab;
        public double Opacity;
        public double Emphasis;
        public bool Gone;

        public Rope((Point, Point) ends)
        {
            Ends = ends;
            Points = new Point[Count];
            for (var i = 0; i < Count; i++)
            {
                var t = i / (double)(Count - 1);
                Points[i] = new Point(ends.Item1.X + (ends.Item2.X - ends.Item1.X) * t, ends.Item1.Y + (ends.Item2.Y - ends.Item1.Y) * t);
            }
            Previous = (Point[])Points.Clone();
            Length = RestLength(ends);
        }

        public static double RestLength((Point A, Point B) ends) => Distance(ends.A, ends.B) * 1.05 + 18;

        /// 走一小步（Verlet）：惯性 + 重力，再按段长约束几遍。返回这一步里动得最多的点挪了多少
        public double Step(double dt)
        {
            Length += (RestLength(Ends) - Length) * Math.Min(1, dt * 3);
            var segment = Length / (Count - 1);
            var fall = 1400 * dt * dt;
            double moved = 0;
            for (var i = 1; i < Count - 1; i++)
            {
                if (i == Grabbed) continue;
                var p = Points[i];
                var vx = (p.X - Previous[i].X) * 0.975;
                var vy = (p.Y - Previous[i].Y) * 0.975;
                Previous[i] = p;
                Points[i] = new Point(p.X + vx, p.Y + vy + fall);
                moved = Math.Max(moved, Math.Abs(vx) + Math.Abs(vy));
            }
            Points[0] = Ends.A;
            Points[Count - 1] = Ends.B;
            if (Grabbed is int g)
            {
                Previous[g] = Points[g];
                Points[g] = Grab;
                moved = Math.Max(moved, 1);
            }
            // 绳子只怕拉、不怕挤：比段长短不管（能弯），长了往回拉
            for (var round = 0; round < 12; round++)
            {
                for (var i = 0; i < Count - 1; i++)
                {
                    var a = Points[i];
                    var b = Points[i + 1];
                    var dx = b.X - a.X;
                    var dy = b.Y - a.Y;
                    var distance = Math.Sqrt(dx * dx + dy * dy);
                    if (distance <= segment) continue;
                    var pinA = i == 0 || i == Grabbed;
                    var pinB = i + 1 == Count - 1 || i + 1 == Grabbed;
                    if (pinA && pinB) continue;
                    var k = (distance - segment) / distance * 0.9;
                    if (pinA) Points[i + 1] = new Point(b.X - dx * k, b.Y - dy * k);
                    else if (pinB) Points[i] = new Point(a.X + dx * k, a.Y + dy * k);
                    else
                    {
                        Points[i] = new Point(a.X + dx * k / 2, a.Y + dy * k / 2);
                        Points[i + 1] = new Point(b.X - dx * k / 2, b.Y - dy * k / 2);
                    }
                }
            }
            return moved;
        }

        /// 离 p 最近的点（只看中间的，两头钉着不让拖）和距离
        public (double Distance, int Index) Nearest(Point p)
        {
            var best = (double.MaxValue, 0);
            for (var i = 2; i < Count - 3; i++)
            {
                var a = Points[i];
                var b = Points[i + 1];
                var dx = b.X - a.X;
                var dy = b.Y - a.Y;
                var t = Math.Clamp(((p.X - a.X) * dx + (p.Y - a.Y) * dy) / Math.Max(dx * dx + dy * dy, 0.0001), 0, 1);
                var d = Distance(p, new Point(a.X + dx * t, a.Y + dy * t));
                if (d < best.Item1) best = (d, t < 0.5 ? i : i + 1);
            }
            return best;
        }
    }

    static double Distance(Point a, Point b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    const double Reach = 6;
    readonly Dictionary<string, Rope> ropes = new();
    readonly DispatcherTimer timer;
    string? hoverRope;
    string? dragging;
    int still;

    public PeerRopeLayer()
    {
        ClipToBounds = true;
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => Tick());
        AttachedToVisualTree += (_, _) => { PeerRopeBoard.Changed += Wake; PeerPrefs.Changed += Wake; Wake(); };
        DetachedFromVisualTree += (_, _) => { PeerRopeBoard.Changed -= Wake; PeerPrefs.Changed -= Wake; timer.Stop(); };
    }

    /// 信件动了、换了悬停、滚动了：醒过来跟上（静止一阵后自己停）
    public void Wake()
    {
        still = 0;
        timer.Interval = TimeSpan.FromMilliseconds(16);
        if (!timer.IsEnabled) timer.Start();
    }

    /// 信件、它所在那一列消息区（滚动区）在这一层里的位置
    (Rect Frame, Rect Clip, Guid Pane)? Place(PeerCard view)
    {
        if (view.GetVisualRoot() is null || view.TranslatePoint(new Point(0, 0), this) is not Point p) return null;
        var chat = view.FindAncestorOfType<ChatView>();
        var scroll = view.FindAncestorOfType<ScrollViewer>();
        if (chat is null || scroll is null || scroll.TranslatePoint(new Point(0, 0), this) is not Point s) return null;
        return (new Rect(p, view.Bounds.Size), new Rect(s, scroll.Bounds.Size), chat.Pane);
    }

    /// 钉在信件朝着对方的那条边上、抬头那一行的高度；信件滚出去一半时沿边滑到还看得见的地方
    static Point Anchor(Rect frame, Rect clip, bool right)
    {
        var x = right ? frame.Right - 1 : frame.Left + 1;
        var top = Math.Max(frame.Top + 8, clip.Top + 8);
        var bottom = Math.Min(frame.Bottom - 8, clip.Bottom - 8);
        return new Point(x, Math.Min(Math.Max(frame.Top + 26, top), Math.Max(top, bottom)));
    }

    /// 露出一部分的信 → 两头钉在哪：另一张也露着就钉在它上面；另一张滚出去了，钉在它那一列消息区的上沿 / 下沿
    Dictionary<string, (Point, Point)> Wanted()
    {
        var wanted = new Dictionary<string, (Point, Point)>();
        if (!PeerPrefs.Ropes || !PeerPrefs.Cards || ChatPanes.Shared.Count < 2) return wanted;
        foreach (var group in PeerRopeBoard.Cards.GroupBy(c => c.Id))
        {
            var from = group.FirstOrDefault(c => c.Outgoing) is { } o ? Place(o.View) : null;
            var to = group.FirstOrDefault(c => !c.Outgoing) is { } i ? Place(i.View) : null;
            if (from is not { } f || to is not { } t || f.Pane == t.Pane) continue;
            var fromShown = f.Frame.Intersects(f.Clip);
            var toShown = t.Frame.Intersects(t.Clip);
            if (!fromShown && !toShown) continue;
            var rightward = t.Clip.Center.X > f.Clip.Center.X;
            Point Edge((Rect Frame, Rect Clip, Guid Pane) hidden, bool facingRight)
            {
                var lower = hidden.Frame.Top > hidden.Clip.Center.Y;
                var x = facingRight ? hidden.Clip.Right - 14 : hidden.Clip.Left + 14;
                return new Point(x, lower ? hidden.Clip.Bottom - 2 : hidden.Clip.Top + 2);
            }
            var a = fromShown ? Anchor(f.Frame, f.Clip, rightward) : Edge(f, rightward);
            var b = toShown ? Anchor(t.Frame, t.Clip, !rightward) : Edge(t, !rightward);
            wanted[group.Key] = (a, b);
        }
        return wanted;
    }

    void Tick()
    {
        var wanted = Wanted();
        foreach (var (id, ends) in wanted)
        {
            if (ropes.TryGetValue(id, out var rope)) { rope.Gone = false; rope.Ends = ends; }
            else ropes[id] = new Rope(ends);
        }
        var busy = false;
        foreach (var (id, rope) in ropes.ToList())
        {
            if (!wanted.ContainsKey(id) && rope.Grabbed is null) rope.Gone = true;
            rope.Opacity = Approach(rope.Opacity, rope.Gone ? 0 : 1, 0.1);
            var lit = PeerRopeBoard.Hovered == id || hoverRope == id || dragging == id;
            rope.Emphasis = Approach(rope.Emphasis, lit ? 1 : 0, 0.13);
            if (rope.Gone && rope.Opacity <= 0) { ropes.Remove(id); continue; }
            var moved = rope.Step(1 / 60.0);
            busy = busy || moved > 0.04 || rope.Grabbed is not null || rope.Opacity is > 0 and < 1 || rope.Emphasis is > 0 and < 1;
        }
        InvalidateVisual();
        // 停下来了：慢慢看（两列滚动时信件位置变了，要跟上），没有绳子时更慢
        still = busy ? 0 : still + 1;
        var interval = still < 12 ? 16 : ropes.Count > 0 ? 66 : 250;
        if ((int)timer.Interval.TotalMilliseconds != interval) timer.Interval = TimeSpan.FromMilliseconds(interval);
        if (still > 12 && ropes.Count == 0 && PeerRopeBoard.Cards.Count == 0) timer.Stop();
    }

    static double Approach(double value, double target, double amount) =>
        value < target ? Math.Min(target, value + amount) : Math.Max(target, value - amount);

    public override void Render(DrawingContext context)
    {
        var accent = Palette.GetColor("Accent");
        foreach (var rope in ropes.Values)
        {
            if (rope.Opacity <= 0) continue;
            var e = rope.Emphasis;
            var width = 1.3 + 1.0 * e;
            var line = (0.22 + 0.63 * e) * rope.Opacity;
            var geometry = new StreamGeometry();
            using (var g = geometry.Open())
            {
                // 过中点的二次曲线，不是一段段折线
                g.BeginFigure(rope.Points[0], false);
                for (var i = 1; i < Rope.Count - 1; i++)
                {
                    var p = rope.Points[i];
                    var next = rope.Points[i + 1];
                    g.QuadraticBezierTo(p, new Point((p.X + next.X) / 2, (p.Y + next.Y) / 2));
                }
                g.LineTo(rope.Points[Rope.Count - 1]);
                g.EndFigure(false);
            }
            var pen = new Pen(new SolidColorBrush(accent, line), width, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
            context.DrawGeometry(null, pen, geometry);
            // 两头的小结：绳子系在信件边上
            var knot = new SolidColorBrush(accent, (0.35 + 0.6 * e) * rope.Opacity);
            var r = 2 + 0.6 * e;
            context.DrawEllipse(knot, null, rope.Points[0], r, r);
            context.DrawEllipse(knot, null, rope.Points[Rope.Count - 1], r, r);
        }
    }

    // MARK: 鼠标：只有贴着绳子的地方接，别处穿透

    string? RopeAt(Point p) =>
        ropes.Where(r => r.Value.Opacity > 0.5).Select(r => (r.Key, r.Value.Nearest(p).Distance)).Where(r => r.Distance < Reach)
            .OrderBy(r => r.Distance).Select(r => r.Key).FirstOrDefault();

    public bool HitTest(Point point) => dragging is not null || RopeAt(point) is not null;

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var p = e.GetPosition(this);
        if (dragging is not null && ropes.TryGetValue(dragging, out var rope))
        {
            rope.Grab = new Point(Math.Clamp(p.X, 0, Bounds.Width), Math.Clamp(p.Y, 0, Bounds.Height));
            Wake();
            return;
        }
        var hit = RopeAt(p);
        if (hit != hoverRope) { hoverRope = hit; Cursor = hit is null ? null : new Cursor(StandardCursorType.Hand); Wake(); }
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        if (dragging is null && hoverRope is not null) { hoverRope = null; Wake(); }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        var p = e.GetPosition(this);
        if (RopeAt(p) is not string id || !ropes.TryGetValue(id, out var rope)) return;
        rope.Grabbed = rope.Nearest(p).Index;
        rope.Grab = p;
        dragging = id;
        e.Pointer.Capture(this);
        e.Handled = true;
        Wake();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (dragging is not null && ropes.TryGetValue(dragging, out var rope)) rope.Grabbed = null;
        dragging = null;
        e.Pointer.Capture(null);
        Wake();
    }
}
