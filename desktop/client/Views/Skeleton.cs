using Avalonia;
using Avalonia.Animation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 骨架的形状：按页面挑，和真实布局对上（同 Mac / iPhone 的 SkeletonStyle，KitelineKit/Views/Skeleton.swift）
public enum SkeletonKind
{
    /// 列表：头像（圆角方块）+ 两行 + 右边时间
    Rows,
    /// 列表，不带头像
    PlainRows,
    /// 列表：小图标 + 一行（文件、分支、记录）
    IconRows,
    /// 历史会话：状态胶囊 + 设备 / 项目两排胶囊 + 按日期分组的会话行
    History,
    /// 今日动态：一排统计块 + 几张会话摘要卡片
    Today,
    /// 用量：额度卡 + 统计块 + 每天花费柱状图
    Usage,
    /// 用量，额度卡已经显示着：只要统计块 + 柱状图
    UsageStats,
    /// 项目：头像 + 三行 + 右边状态胶囊、箭头
    Projects,
    /// 待办：勾选圈 + 两行
    Todos,
    /// 收藏：一张张卡片
    Favorites,
    /// 会话群：分组标题 + 头像行
    Groups,
    /// 改动：图标 + 路径 + 右边 +/- 数
    Changes,
    /// 代码 / 差异：行号 + 带缩进的代码行
    Code,
    /// 一段文字（更新记录）：小标题 + 几行
    Text,
    /// 设置表单：一组组圆角卡片，每行左标题右控件
    Form,
    /// 对话：右边我说的一块、左边回复几行
    Messages,
    /// 一排统计 / 信息卡片
    Cards,
}

/// 骨架屏：页面、弹窗头一回读数据时先画出和真实页面一样的布局，一道光从左往右扫过（11-16 起：要有动态效果、和实际布局一致）。
/// 自己画（不用合成器动画），挂共用节拍（见 Beat），窗口收起来就不画；只在骨架显示的那一会儿动
public sealed class SkeletonView : Control
{
    readonly SkeletonKind kind;
    readonly int count;
    double since;
    static readonly double[] Widths = [0.42, 0.28, 0.5, 0.35, 0.46, 0.3, 0.4, 0.25, 0.48, 0.33];
    static double W(int i) => Widths[((i % Widths.Length) + Widths.Length) % Widths.Length];

    public SkeletonView(SkeletonKind kind, int count = 0)
    {
        this.kind = kind;
        this.count = count > 0 ? count : kind switch
        {
            SkeletonKind.Cards or SkeletonKind.Favorites or SkeletonKind.Messages => 4,
            SkeletonKind.Code => 18, SkeletonKind.Text => 15, SkeletonKind.IconRows => 10,
            _ => 7,
        };
        IsHitTestVisible = false;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        ClipToBounds = true;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        since = Beat.Now;
        Beat.Add(this);
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        Beat.Remove(this);
    }

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 600 : available.Width;
        return new Size(width, new Painter(null, width, 0, Colors.Gray).Run(kind, count));
    }

    public override void Render(DrawingContext context)
    {
        // 扫光：一条亮带 1.4 秒从左扫到右（只亮在灰块上：每块先铺底色、再叠一层随时间平移的渐变）
        var phase = (Beat.Now - since) / 1.4 % 1;
        new Painter(context, Bounds.Width, phase, Palette.GetColor("Text")).Run(kind, count);
    }

    /// 按页面排灰块；context 为空时只量高度
    sealed class Painter(DrawingContext? ctx, double w, double phase, Color text)
    {
        readonly IBrush strong = new SolidColorBrush(Color.FromArgb(28, text.R, text.G, text.B));
        readonly IBrush weak = new SolidColorBrush(Color.FromArgb(18, text.R, text.G, text.B));
        readonly IBrush card = new SolidColorBrush(Color.FromArgb(10, text.R, text.G, text.B));
        IBrush? shine;

        IBrush Shine()
        {
            if (shine is not null) return shine;
            var band = Math.Max(160, w * 0.4);
            var x = -band + phase * (w + band);
            var hi = Color.FromArgb(34, text.R, text.G, text.B);
            return shine = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(x, 0, RelativeUnit.Absolute),
                EndPoint = new RelativePoint(x + band, 0, RelativeUnit.Absolute),
                GradientStops = { new GradientStop(Colors.Transparent, 0), new GradientStop(hi, 0.5), new GradientStop(Colors.Transparent, 1) },
            };
        }

        void Box(double x, double y, double width, double height, IBrush brush, double radius = 3, bool shimmer = true)
        {
            if (ctx is null || width <= 0) return;
            var r = new RoundedRect(new Rect(x, y, width, height), radius);
            ctx.DrawRectangle(brush, null, r);
            if (shimmer) ctx.DrawRectangle(Shine(), null, r);
        }

        void Bar(double x, double y, double width, double height, bool dim = false) => Box(x, y, width, height, dim ? weak : strong);
        void Card(double x, double y, double width, double height, double radius = 14) => Box(x, y, width, height, card, radius, shimmer: false);
        void Circle(double x, double y, double size)
        {
            if (ctx is null) return;
            ctx.DrawEllipse(null, new Pen(strong, 2), new Rect(x + 1, y + 1, size - 2, size - 2));
        }

        public double Run(SkeletonKind kind, int count) => kind switch
        {
            SkeletonKind.Rows => List(0, count, Lead.Avatar, 2, Trail.Time, false),
            SkeletonKind.PlainRows => List(0, count, Lead.None, 2, Trail.Time, false),
            SkeletonKind.IconRows => List(0, count, Lead.Icon, 1, Trail.Time, false),
            SkeletonKind.Groups => List(0, count, Lead.Avatar, 2, Trail.Time, true),
            SkeletonKind.Todos => List(0, count, Lead.Check, 2, Trail.None, true),
            SkeletonKind.Projects => List(0, count, Lead.Avatar, 3, Trail.Chevron, false),
            SkeletonKind.History => History(),
            SkeletonKind.Today => Today(),
            SkeletonKind.Usage => Usage(true),
            SkeletonKind.UsageStats => Usage(false),
            SkeletonKind.Favorites => Favorites(count),
            SkeletonKind.Changes => Changes(count),
            SkeletonKind.Code => Code(count),
            SkeletonKind.Text => TextBlock(count),
            SkeletonKind.Form => Form(count),
            SkeletonKind.Messages => Messages(count),
            _ => Tiles(0, count, 150, 110),
        };

        enum Lead { None, Avatar, Icon, Check }
        enum Trail { None, Time, Badge, Chevron }

        double Header(double y, int i)
        {
            y += i == 0 ? 2 : 16;
            Bar(0, y, 36 + W(i) * 40, 9, dim: true);
            return y + 17;
        }

        double Row(double y, int i, Lead lead, int lines, Trail trail, bool badge = false)
        {
            var h = lines >= 3 ? 70.0 : lines == 2 ? 50 : 38;
            var x = 0.0;
            var mid = y + h / 2;
            switch (lead)
            {
                case Lead.Avatar: Box(0, lines >= 3 ? y + 6 : mid - 15, 30, 30, strong, 8); x = 40; break;
                case Lead.Icon: Box(0, mid - 9, 18, 18, strong, 4); x = 28; break;
                case Lead.Check: Circle(0, mid - 10, 20); x = 30; break;
            }
            var right = w;
            switch (trail)
            {
                case Trail.Time: Bar(w - 30, mid - 4.5, 30, 9, dim: true); right -= 40; break;
                case Trail.Badge: Bar(w - 30, mid - 4.5, 30, 9, dim: true); Box(w - 84, mid - 9, 44, 18, strong, 9); right -= 94; break;
                case Trail.Chevron:
                    Bar(w - 7, mid - 6, 7, 12, dim: true); Bar(w - 37, mid - 4.5, 20, 9, dim: true); right -= 47;
                    if (badge) { Box(right - 80, mid - 9, 80, 18, strong, 9); right -= 90; }
                    break;
            }
            var room = Math.Max(40, right - x);
            var top = lines >= 3 ? y + 8 : mid - (lines == 2 ? 13.5 : 5.5);
            Bar(x, top, room * (0.25 + W(i) * 0.8), 11);
            if (lines >= 2) Bar(x, top + 18, room * Math.Min(0.9, 0.4 + W(i + 3) * 1.1), 9, dim: true);
            if (lines >= 3) Bar(x, top + 34, room * (0.2 + W(i + 5) * 0.5), 9, dim: true);
            return y + h;
        }

        double List(double y, int count, Lead lead, int lines, Trail trail, bool sections)
        {
            for (var i = 0; i < count; i++)
            {
                if (sections && i % 4 == 0) y = Header(y, i);
                y = Row(y, i, lead, lines, trail, badge: lines >= 3 && i % 3 == 0);
            }
            return y;
        }

        double Chips(double y, params double[] widths)
        {
            var x = 0.0;
            foreach (var cw in widths) { Box(x, y, cw, 26, strong, 13); x += cw + 8; }
            return y + 36;
        }

        double History()
        {
            var y = Chips(0, 56, 78, 78);
            Box(w - 104, 0, 104, 26, strong, 13);
            y = Chips(y, 100, 60, 72);
            y = Chips(y, 100, 84, 64, 96) + 4;
            for (var i = 0; i < 9; i++)
            {
                if (i is 0 or 3 or 7) y = Header(y, i);
                y = Row(y, i, Lead.Avatar, 2, i == 0 ? Trail.Badge : Trail.Time);
            }
            return y;
        }

        /// 一排统计块：图标、大数字、说明、小字
        double Tiles(double y, int count, double min, double height)
        {
            var cols = Math.Max(1, Math.Min(count, (int)((w + 12) / (min + 12))));
            var tw = (w - 12 * (cols - 1)) / cols;
            for (var i = 0; i < count; i++)
            {
                var x = i % cols * (tw + 12);
                var ty = y + i / cols * (height + 12);
                Card(x, ty, tw, height);
                Box(x + 14, ty + 14, 22, 22, strong, 6);
                Bar(x + 14, ty + 45, 40 + W(i) * 50, 20);
                Bar(x + 14, ty + 74, 60 + W(i + 1) * 30, 10);
                Bar(x + 14, ty + 92, 50, 8, dim: true);
            }
            return y + Math.Ceiling(count / (double)cols) * (height + 12) - 12;
        }

        double Today()
        {
            var y = Tiles(0, 5, 140, 110) + 18;
            for (var i = 0; i < 3; i++)
            {
                Card(0, y, w, 110);
                Box(14, y + 14, 30, 30, strong, 8);
                Bar(54, y + 16, 140 + W(i) * 120, 11);
                Bar(54, y + 34, 120, 9, dim: true);
                Bar(w - 48, y + 24, 34, 9, dim: true);
                Bar(14, y + 56, (w - 28) * 0.92, 10);
                Bar(14, y + 74, (w - 28) * (0.55 + W(i + 2) * 0.6), 10);
                Bar(14, y + 92, (w - 28) * 0.38, 10, dim: true);
                y += 128;
            }
            return y - 18;
        }

        double Usage(bool limits)
        {
            var y = 0.0;
            if (limits)
            {
                Bar(0, 0, 64, 11);
                y = 27;
                var cols = w >= 560 ? 2 : 1;
                var cw = (w - 28 - 20 * (cols - 1)) / cols;
                var rows = (int)Math.Ceiling(4.0 / cols);
                var h = 28 + rows * 64.0;
                Card(0, y, w, h);
                for (var i = 0; i < 4; i++)
                {
                    var x = 14 + i % cols * (cw + 20);
                    var cy = y + 14 + i / cols * 64;
                    Bar(x, cy, 50, 11);
                    Bar(x + cw - (70 + W(i) * 60), cy, 70 + W(i) * 60, 11);
                    var half = (cw - 16) / 2;
                    for (var j = 0; j < 2; j++)
                    {
                        var bx = x + j * (half + 16);
                        Bar(bx, cy + 24, 70, 8, dim: true);
                        Bar(bx + half - 26, cy + 22, 26, 10);
                        Box(bx, cy + 38, half, 5, strong, 2.5);
                    }
                }
                y += h + 16;
            }
            y = Tiles(y, 4, 150, 110) + 16;
            // 每天花费：标题 + 七根高低不一的柱子 + 日期
            Card(0, y, w, 220);
            Bar(14, y + 14, 70, 11);
            var slot = (w - 28) / 7;
            for (var i = 0; i < 7; i++)
            {
                var bh = 30 + W(i * 3 + 1) * 220;
                var cx = 14 + slot * i + slot / 2;
                Box(cx - 13, y + 187 - bh * 0.6, 26, bh * 0.6, strong, 4);
                Bar(cx - 15, y + 197, 30, 8, dim: true);
            }
            return y + 220;
        }

        double Favorites(int count)
        {
            var y = 0.0;
            for (var i = 0; i < count; i++)
            {
                var lines = i % 2 == 0 ? 3 : 2;
                var h = 28 + lines * 18 + 20;
                Card(0, y, w, h);
                for (var l = 0; l < lines; l++)
                    Bar(14, y + 14 + l * 18, (w - 28) * (l == lines - 1 ? 0.45 : 0.9 - W(i + l) * 0.2), 10);
                var fy = y + 14 + lines * 18 + 6;
                Bar(14, fy, 40, 8, dim: true); Bar(60, fy, 90, 8, dim: true); Bar(w - 48, fy, 34, 8, dim: true);
                y += h + 12;
            }
            return y - 12;
        }

        double Changes(int count)
        {
            for (var i = 0; i < count; i++)
            {
                var y = i * 34.0;
                Box(0, y + 9, 16, 16, strong, 4);
                Bar(26, y + 12, (w - 90) * (0.35 + W(i) * 0.6), 10);
                Bar(w - 54, y + 12.5, 22, 9, dim: true);
                Bar(w - 22, y + 12.5, 22, 9, dim: true);
            }
            return count * 34.0;
        }

        double Code(int count)
        {
            int[] indents = [0, 1, 2, 2, 1, 2, 3, 1, 0, 1];
            for (var i = 0; i < count; i++)
            {
                var y = i * 18.0;
                Bar(0, y, 16, 9, dim: true);
                if (i % 7 == 6) continue;
                var indent = indents[i % 10] * 18.0;
                Bar(30 + indent, y, Math.Max(30, (w - 40 - indent) * Math.Min(0.9, 0.25 + W(i) * 1.1)), 9);
            }
            return count * 18.0;
        }

        double TextBlock(int count)
        {
            var y = 0.0;
            for (var i = 0; i < count; i++)
            {
                if (i % 5 == 0) { if (i > 0) y += 8; Bar(0, y, w * 0.3, 13); y += 23; }
                else { Bar(0, y, w * (i % 5 == 4 ? 0.5 : Math.Min(0.95, 0.6 + W(i) * 0.7)), 10, dim: i % 5 == 4); y += 20; }
            }
            return y;
        }

        double Form(int count)
        {
            var y = 0.0;
            for (var section = 0; section * 3 < Math.Max(1, count); section++)
            {
                Bar(4, y, 60 + W(section) * 60, 9, dim: true);
                y += 17;
                var rows = Math.Max(1, Math.Min(3, count - section * 3));
                Card(0, y, w, rows * 42, 12);
                for (var r = 0; r < rows; r++)
                {
                    var i = section * 3 + r;
                    var ry = y + r * 42;
                    Bar(14, ry + 15.5, 70 + W(i) * 120, 11);
                    if (i % 3 == 0) Box(w - 52, ry + 10, 38, 22, strong, 11); else Bar(w - 84, ry + 16, 70, 10, dim: true);
                }
                y += rows * 42 + 18;
            }
            return y - 18;
        }

        double Messages(int count)
        {
            for (var i = 0; i < count; i++)
            {
                var y = i * 120.0;
                var mine = w * (0.3 + W(i) * 0.5);
                Box(w - mine, y, mine, 34, strong, 14);
                Bar(0, y + 50, w * 0.86, 10);
                Bar(0, y + 68, w * Math.Min(0.95, 0.6 + W(i + 2) * 0.5), 10);
                Bar(0, y + 86, w * 0.4, 10, dim: true);
            }
            return count * 120.0 - 22;
        }
    }
}

public static class Skeleton
{
    /// 一整块占位：转圈 + 一句「正在读取…」+ 骨架，放在页面 / 弹窗内容的位置（label 传 "" 就不要那句话）
    public static Control Page(SkeletonKind kind, string? label = null, int count = 0)
    {
        var stack = new StackPanel { Spacing = 14, Margin = new Thickness(0, 12, 0, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
        if (label != "") stack.Children.Add(Ui.H(8, new Spinner(14), Ui.Text(label ?? L("正在读取…"), 12.5, FontWeight.Normal, "Text2")));
        stack.Children.Add(new SkeletonView(kind, count));
        return stack;
    }

    /// 数据读回来、骨架换成内容时淡入（一次 0.28 秒，不是循环动画）
    public static T FadeIn<T>(this T control) where T : Control
    {
        control.Opacity = 0;
        control.Transitions = [new DoubleTransition { Property = Visual.OpacityProperty, Duration = TimeSpan.FromMilliseconds(280), Easing = new Avalonia.Animation.Easings.CubicEaseOut() }];
        void Show(object? _, VisualTreeAttachmentEventArgs __)
        {
            control.AttachedToVisualTree -= Show;
            Avalonia.Threading.Dispatcher.UIThread.Post(() => control.Opacity = 1, Avalonia.Threading.DispatcherPriority.Render);
        }
        if (TopLevel.GetTopLevel(control) is not null) Avalonia.Threading.Dispatcher.UIThread.Post(() => control.Opacity = 1, Avalonia.Threading.DispatcherPriority.Render);
        else control.AttachedToVisualTree += Show;
        return control;
    }
}
