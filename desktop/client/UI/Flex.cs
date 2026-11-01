using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace Kiteline.UI;

/// 仿 SwiftUI 的 HStack / VStack：按顺序排、子项之间留 Spacing；
/// Grow > 0 的子项（Spacer、撑满的）分剩下的地方；Shrink 的子项（单行截短的文字）在放不下时让出地方。
/// 交叉方向按 Align 对齐（Stretch = 撑满）
public class Flex : Panel
{
    public static readonly StyledProperty<Orientation> OrientationProperty = AvaloniaProperty.Register<Flex, Orientation>(nameof(Orientation));
    public static readonly StyledProperty<double> SpacingProperty = AvaloniaProperty.Register<Flex, double>(nameof(Spacing));
    public static readonly StyledProperty<Align> AlignProperty = AvaloniaProperty.Register<Flex, Align>(nameof(Align), Align.Center);

    public static readonly AttachedProperty<double> GrowProperty = AvaloniaProperty.RegisterAttached<Flex, Control, double>("Grow");
    public static readonly AttachedProperty<bool> ShrinkProperty = AvaloniaProperty.RegisterAttached<Flex, Control, bool>("Shrink");
    /// 这个子项自己的交叉对齐（不填跟着面板）
    public static readonly AttachedProperty<Align?> SelfProperty = AvaloniaProperty.RegisterAttached<Flex, Control, Align?>("Self");

    public static double GetGrow(Control c) => c.GetValue(GrowProperty);
    public static void SetGrow(Control c, double v) => c.SetValue(GrowProperty, v);
    public static bool GetShrink(Control c) => c.GetValue(ShrinkProperty);
    public static void SetShrink(Control c, bool v) => c.SetValue(ShrinkProperty, v);
    public static Align? GetSelf(Control c) => c.GetValue(SelfProperty);
    public static void SetSelf(Control c, Align? v) => c.SetValue(SelfProperty, v);

    static Flex()
    {
        AffectsMeasure<Flex>(OrientationProperty, SpacingProperty);
        AffectsArrange<Flex>(AlignProperty);
        AffectsParentMeasure<Flex>(GrowProperty, ShrinkProperty);
    }

    public Orientation Orientation { get => GetValue(OrientationProperty); set => SetValue(OrientationProperty, value); }
    public double Spacing { get => GetValue(SpacingProperty); set => SetValue(SpacingProperty, value); }
    public Align Align { get => GetValue(AlignProperty); set => SetValue(AlignProperty, value); }

    bool H => Orientation == Orientation.Horizontal;
    double Main(Size s) => H ? s.Width : s.Height;
    double Cross(Size s) => H ? s.Height : s.Width;
    Size Make(double main, double cross) => H ? new Size(main, cross) : new Size(cross, main);

    double[] mains = [];

    protected override Size MeasureOverride(Size available)
    {
        var kids = Children.Where(c => c.IsVisible).ToList();
        mains = new double[kids.Count];
        var spacing = Spacing * Math.Max(0, kids.Count - 1);
        var availMain = Main(available);
        var availCross = Cross(available);
        double used = spacing, cross = 0;
        // 先排定长的
        for (var i = 0; i < kids.Count; i++)
        {
            var c = kids[i];
            if (GetGrow(c) > 0 || GetShrink(c)) continue;
            c.Measure(Make(double.PositiveInfinity, availCross));
            mains[i] = Main(c.DesiredSize);
            used += mains[i];
            cross = Math.Max(cross, Cross(c.DesiredSize));
        }
        // 再排会让的（截短的文字）：分剩下的
        var shrinkers = Enumerable.Range(0, kids.Count).Where(i => GetShrink(kids[i]) && GetGrow(kids[i]) <= 0).ToList();
        foreach (var i in shrinkers)
        {
            var c = kids[i];
            c.Measure(Make(double.PositiveInfinity, availCross));
            mains[i] = Main(c.DesiredSize);
        }
        var shrinkTotal = shrinkers.Sum(i => mains[i]);
        if (!double.IsInfinity(availMain) && used + shrinkTotal > availMain && shrinkTotal > 0)
        {
            var room = Math.Max(0, availMain - used);
            // 从最宽的开始让，尽量都留一点
            var order = shrinkers.OrderByDescending(i => mains[i]).ToList();
            var share = shrinkers.ToDictionary(i => i, i => mains[i]);
            var excess = shrinkTotal - room;
            foreach (var i in order)
            {
                if (excess <= 0) break;
                var cut = Math.Min(excess, share[i]);
                share[i] -= cut;
                excess -= cut;
            }
            foreach (var i in shrinkers)
            {
                kids[i].Measure(Make(share[i], availCross));
                mains[i] = Math.Min(share[i], Main(kids[i].DesiredSize));
            }
        }
        foreach (var i in shrinkers) { used += mains[i]; cross = Math.Max(cross, Cross(kids[i].DesiredSize)); }
        // 最后分撑开的
        var growers = Enumerable.Range(0, kids.Count).Where(i => GetGrow(kids[i]) > 0).ToList();
        var totalGrow = growers.Sum(i => GetGrow(kids[i]));
        var free = double.IsInfinity(availMain) ? 0 : Math.Max(0, availMain - used);
        foreach (var i in growers)
        {
            var c = kids[i];
            var share = double.IsInfinity(availMain) ? double.PositiveInfinity : free * GetGrow(c) / totalGrow;
            c.Measure(Make(share, availCross));
            mains[i] = double.IsInfinity(share) ? Main(c.DesiredSize) : share;
            if (double.IsInfinity(availMain)) used += mains[i];
            cross = Math.Max(cross, Cross(c.DesiredSize));
        }
        if (growers.Count > 0 && !double.IsInfinity(availMain)) used = Math.Max(used, availMain);
        // 只在需要撑满交叉方向时才报满
        return Make(used, cross);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var kids = Children.Where(c => c.IsVisible).ToList();
        if (mains.Length != kids.Count) return final;
        var finalMain = Main(final);
        var finalCross = Cross(final);
        // 撑开的子项按实际给的地方重新分
        var spacing = Spacing * Math.Max(0, kids.Count - 1);
        var fixedTotal = Enumerable.Range(0, kids.Count).Where(i => GetGrow(kids[i]) <= 0).Sum(i => mains[i]);
        var growers = Enumerable.Range(0, kids.Count).Where(i => GetGrow(kids[i]) > 0).ToList();
        var totalGrow = growers.Sum(i => GetGrow(kids[i]));
        var free = Math.Max(0, finalMain - spacing - fixedTotal);
        double pos = 0;
        for (var i = 0; i < kids.Count; i++)
        {
            var c = kids[i];
            var main = GetGrow(c) > 0 ? free * GetGrow(c) / totalGrow : mains[i];
            var align = GetSelf(c) ?? Align;
            var crossSize = align == Align.Stretch ? finalCross : Math.Min(finalCross, Cross(c.DesiredSize));
            var crossPos = align switch
            {
                Align.Start or Align.Stretch => 0,
                Align.End => finalCross - crossSize,
                _ => (finalCross - crossSize) / 2,
            };
            var rect = H ? new Rect(pos, crossPos, main, crossSize) : new Rect(crossPos, pos, crossSize, main);
            c.Arrange(rect);
            pos += main + Spacing;
        }
        return final;
    }
}

public enum Align { Start, Center, End, Stretch }

/// SwiftUI 的 Spacer：在 Flex 里撑开剩下的地方
public sealed class Spacer : Control
{
    public Spacer(double min = 0)
    {
        Flex.SetGrow(this, 1);
        MinWidth = min;
    }
}
