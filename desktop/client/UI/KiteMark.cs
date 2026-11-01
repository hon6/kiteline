using Avalonia;
using Avalonia.Media;

namespace Kiteline.UI;

/// Kiteline 的纸鸢（北京沙燕），形状同 KitelineKit/Shared/PaperKite.swift（384×384 的格子，y 朝下）。
/// 苹果上镂空（扇骨、眼睛、部件之间的细缝）是用「清除」混合模式挖的，这里用几何相减、合并算出同样的形状，按尺寸缓存
public static class KiteMark
{
    public const double Grid = 384;
    /// 纸鸢的「重心」：摇摆、缩放绕这里转
    public static readonly Point Center = new(222, 108);
    public static readonly Point Knot = new(246, 196);

    static readonly Dictionary<(bool Full, int Unit), Geometry> Cache = new();

    static Geometry Svg(string d) => Geometry.Parse(d);

    static readonly Geometry TailLeft = Svg("M174 142 C140 164 80 204 4 238 C70 216 136 186 184 158 Z");
    static readonly Geometry TailDown = Svg("M178 151 C175 220 162 290 147 347 C170 292 188 226 194 155 Z");
    static readonly Geometry FarFan = Svg("M207 63 L100 10 C95 12 94 20 97 30 C104 56 124 88 150 112 C166 127 180 134 194 137 Z");
    static readonly Geometry FarBand = Svg("M212 58 L100 9 C95 10 93 17 96 27 L103 33 C136 51 170 69 206 85 Z");
    static readonly Geometry FarStripe = Svg("M198 72 C180 60 166 62 150 50 C138 42 126 38 114 26");
    static readonly Geometry NearFan = Svg("M256 104 L378 166 C384 170 383 179 375 184 C335 191 292 188 252 174 C232 166 216 157 206 149 Z");
    static readonly Geometry NearBand = Svg("M262 92 L379 165 C385 169 384 178 376 183 L368 186 C330 166 290 146 248 124 Z");
    static readonly Geometry NearStripe = Svg("M262 108 C282 116 296 128 318 136 C334 142 350 152 368 168");
    static readonly Geometry Body = Svg("M236 40 C252 28 278 31 287 49 C290 66 284 84 270 104 C256 124 230 146 200 156 C186 160 174 158 170 150 C164 138 172 112 186 92 C200 70 218 50 236 40 Z");
    /// 黑顶和白脸的分界（挖一道线）
    static readonly Geometry CapEdge = Svg("M287 58 C281 62 274 63 268 60 C262 57 256 53 248 52 C241 51 234 47 236 40");
    static readonly Geometry Beak = Svg("M284 45 C290 41 296 38 302 36 C298 42 294 48 288 56 Z");
    static readonly Geometry FarRibs = Ribs(new Point(200, 82), new Point(106, 34), [(192, 135), (170, 125), (147, 108), (125, 84), (108, 58), (99, 33)], 11);
    static readonly Geometry NearRibs = Ribs(new Point(250, 124), new Point(366, 186), [(210, 150), (236, 165), (266, 178), (300, 187), (336, 189), (366, 186)], 12);

    /// 扇骨：翅带下沿上均匀取点，连到扇面外沿折线上对应的位置
    static Geometry Ribs(Point a, Point b, (double X, double Y)[] edge, int count)
    {
        static Point Lerp(Point p, Point q, double t) => new(p.X + (q.X - p.X) * t, p.Y + (q.Y - p.Y) * t);
        var points = edge.Select(e => new Point(e.X, e.Y)).ToArray();
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            for (var i = 0; i < count; i++)
            {
                var t = (i + 0.5) / count;
                var f = t * (points.Length - 1);
                var index = Math.Min((int)f, points.Length - 2);
                ctx.BeginFigure(Lerp(a, b, t), false);
                ctx.LineTo(Lerp(points[index], points[index + 1], f - index));
                ctx.EndFigure(false);
            }
        }
        return g;
    }

    static Geometry Union(Geometry a, Geometry b) => new CombinedGeometry(GeometryCombineMode.Union, a, b);
    static Geometry Minus(Geometry a, Geometry b) => new CombinedGeometry(GeometryCombineMode.Exclude, a, b);

    static Geometry Stroke(Geometry g, double width) =>
        g.GetWidenedGeometry(new Pen(Brushes.Black, width, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round));

    static Geometry Circle(double x, double y, double r) => new EllipseGeometry(new Rect(x - r, y - r, r * 2, r * 2));

    /// 一整只纸鸢的形状（384 格子）。full = 全部镂空细节（大图标、顶上飞的）；否则只留身子轮廓和眼睛（小图标）。
    /// pixels = 画出来多大：小尺寸时镂空线按它加粗，保证至少看得见
    public static Geometry Shape(bool full, double pixels)
    {
        var unit = Math.Max(1, (int)Math.Round(pixels));
        if (Cache.TryGetValue((full, unit), out var cached)) return cached;
        var acc = Build(Union(TailLeft, TailDown), full, unit / Grid);
        Cache[(full, unit)] = acc;
        return acc;
    }

    /// 燕尾根（摆动绕这里转）、两根提线的上下端
    public static readonly Point TailLeftRoot = new(179, 150), TailDownRoot = new(186, 153);
    static readonly Point BridleTop = new(232, 84), BridleBottom = new(200, 138);
    static readonly Dictionary<int, (Geometry, Geometry, Geometry)> LayerCache = new();

    /// 顶上飞的纸鸢分三层（同 Mac 版 KiteFlightView）：两条燕尾各自摆，其余一层。
    /// 燕尾根上先挖出身子、近翅压在上面的那圈细缝，叠上去和整只画的一样；bridle = 提线粗细（格子单位）：
    /// 两根提线连到结，压在纸鸢身上的那段挖空、身外画成线的颜色（异或）
    public static (Geometry TailLeft, Geometry TailDown, Geometry Others) Layers(double bridle)
    {
        var key = (int)Math.Round(bridle * 100);
        if (LayerCache.TryGetValue(key, out var cached)) return cached;
        var gaps = Union(Stroke(Body, 4.5), Stroke(NearFan, 3.6));
        var rest = Build(null, true, 1);
        var bridleLine = new StreamGeometry();
        using (var ctx = bridleLine.Open())
        {
            ctx.BeginFigure(BridleTop, false);
            ctx.LineTo(Knot);
            ctx.LineTo(BridleBottom);
            ctx.EndFigure(false);
        }
        var line = Union(Stroke(bridleLine, bridle), Circle(Knot.X, Knot.Y, bridle * 1.2));
        var layers = ((Geometry)Minus(TailLeft, gaps), (Geometry)Minus(TailDown, gaps), (Geometry)new CombinedGeometry(GeometryCombineMode.Xor, rest, line));
        LayerCache[key] = layers;
        return layers;
    }

    /// 从 tails（可以没有）开始叠上各部件、挖出镂空；u = 一个格子单位多少像素
    static Geometry Build(Geometry? tails, bool full, double u)
    {
        var minCut = 0.9 / Math.Max(u, 0.001);
        double Cut(double nominal) => full ? nominal : Math.Max(nominal, minCut);
        Geometry Add(Geometry? a, Geometry b) => a is null ? b : Union(a, b);
        Geometry Piece(Geometry baseShape, Geometry part, double gap) => Union(Minus(baseShape, Stroke(part, Cut(gap))), part);
        Geometry acc;
        if (full)
        {
            acc = Add(tails, FarFan);
            acc = Minus(acc, Stroke(FarRibs, Cut(2.6)));
            acc = Piece(acc, FarBand, 3.2);
            acc = Minus(acc, Stroke(FarStripe, Cut(2.4)));
            acc = Piece(acc, NearFan, 3.6);
            acc = Minus(acc, Stroke(NearRibs, Cut(2.8)));
            acc = Piece(acc, NearBand, 3.6);
            acc = Minus(acc, Stroke(NearStripe, Cut(2.6)));
            acc = Piece(acc, Body, 4.5);
            acc = Minus(acc, Stroke(CapEdge, Cut(2.6)));
        }
        else
        {
            acc = Union(Union(Union(Add(tails, FarFan), FarBand), NearFan), NearBand);
            acc = Piece(acc, Body, 4.5);
        }
        acc = Union(acc, Beak);
        // 眼睛：挖一个圆，中间留眼珠
        var eye = full ? 4.8 : Math.Max(4.8, 1.3 / Math.Max(u, 0.001));
        acc = Minus(acc, Circle(270, 48, eye));
        if (full || eye * u >= 2.2) acc = Union(acc, Circle(271, 48, eye * 0.46));
        return acc;
    }

    /// 在 box 里画一只静止的纸鸢
    public static void DrawStill(DrawingContext ctx, Rect box, IBrush brush, bool full = false)
    {
        var side = Math.Min(box.Width, box.Height);
        var scale = side / Grid;
        var matrix = Matrix.CreateScale(scale, scale) * Matrix.CreateTranslation(box.X + (box.Width - side) / 2, box.Y + (box.Height - side) / 2);
        using (ctx.PushTransform(matrix)) ctx.DrawGeometry(brush, null, Shape(full, side));
    }

    /// 工作中的小纸鸢（同 Mac 版 KiteSpinnerView）：绕重心左右晃 -10°～9°（0.9 秒）、一会儿飞远一会儿飞近 0.74～1.06 倍（2.3 秒）、
    /// 左右飘（1.7 秒）、上下浮（1.3 秒），都是来回缓动。t = 秒
    public static void Draw(DrawingContext ctx, Rect box, IBrush brush, double t)
    {
        static double Wave(double t, double duration)
        {
            var phase = t / duration % 2;
            var x = phase < 1 ? phase : 2 - phase;
            return x < 0.5 ? 2 * x * x : 1 - Math.Pow(-2 * x + 2, 2) / 2;   // easeInEaseOut
        }
        static double Lerp(double a, double b, double f) => a + (b - a) * f;
        var size = Math.Min(box.Width, box.Height);
        var angle = Lerp(-10, 9, Wave(t, 0.9)) * Math.PI / 180;
        var depth = Lerp(0.74, 1.06, Wave(t, 2.3));
        var dx = Lerp(-0.07, 0.08, Wave(t, 1.7)) * size;
        var dy = Lerp(0.06, -0.09, Wave(t, 1.3)) * size;
        var unit = size / Grid;
        var cx = box.X + (box.Width - size) / 2 + Center.X * unit;
        var cy = box.Y + (box.Height - size) / 2 + Center.Y * unit;
        var matrix = Matrix.CreateTranslation(-Center.X, -Center.Y) * Matrix.CreateScale(unit * depth, unit * depth)
                     * Matrix.CreateRotation(angle) * Matrix.CreateTranslation(cx + dx, cy + dy);
        using (ctx.PushTransform(matrix)) ctx.DrawGeometry(brush, null, Shape(false, size));
    }
}
