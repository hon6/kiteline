import SwiftUI
import QuartzCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Kiteline 的纸鸢在界面里的三种用法（形状本身在 KitelineKit/Shared/PaperKite.swift，和 App 图标同一份）：
// - KiteMark：静态标志（启动页、引导页、订阅页、思考步骤的小图标）
// - KiteSpinner：Claude 正在思考 / 干活时的小纸鸢，随风晃、时远时近（代替原来的 ✻）
// - KiteFlight：首页（iPhone）和主窗口（Mac）顶上一直在飞的那只，上下浮动、随风偏、燕尾摆、风筝线跟着摆
// （另有 PulseDot：运行中步骤的呼吸圆点，同样交给 Core Animation）
// 动的两种都是「纸鸢只画一次存成图片 + Core Animation 关键帧」：动画在系统的渲染进程里跑，App 主线程不逐帧重画，几乎不占 CPU。

/// 品牌橙：标志、图标、顶上飞的纸鸢都用它，不跟主题色走
public enum KiteColor {
    public static let brand = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}

/// 在 Canvas 里按 384 格子画一只纸鸢：origin 是格子左上角在画布里的位置，unit 是每格多少点
private func drawKite(_ context: GraphicsContext, color: Color, origin: CGPoint, unit: CGFloat, detail: PaperKite.Detail,
                      pose: PaperKite.Pose = PaperKite.Pose(), bridle: CGFloat? = nil) {
    let cgColor = color.resolve(in: context.environment).cgColor
    context.withCGContext { cg in
        cg.translateBy(x: origin.x, y: origin.y)
        cg.scaleBy(x: unit, y: unit)
        PaperKite.draw(cg, color: cgColor, detail: detail, pose: pose, unit: unit, bridle: bridle)
    }
}

/// 静态的纸鸢标志。line 给了颜色就连提线、再从结往下拉一段主线（拉到框外为止）
struct KiteMark: View {
    var color: Color = KiteColor.brand
    var line: Color?

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / PaperKite.size
            let detail: PaperKite.Detail = unit * PaperKite.size >= 48 ? .full : .glyph
            if let line {
                var path = Path()
                path.move(to: PaperKite.knot)
                path.addCurve(to: CGPoint(x: 276, y: 440), control1: CGPoint(x: 252, y: 260), control2: CGPoint(x: 262, y: 330))
                context.stroke(path.applying(CGAffineTransform(scaleX: unit, y: unit)), with: .color(line),
                               style: StrokeStyle(lineWidth: max(1.2 * unit, 0.6), lineCap: .round))
            }
            drawKite(context, color: color, origin: .zero, unit: unit, detail: detail, bridle: line == nil ? nil : 1.2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - 预渲染的纸鸢图片

/// 把纸鸢（或其中几部分）画成一张正方形图片，按参数缓存：动画里只挪图片，不重画
@MainActor
enum KiteArt {
    private static var cache: [String: CGImage] = [:]

    /// side：图片边长（点）；scale：屏幕倍数
    static func image(side: CGFloat, scale: CGFloat, color: CGColor, detail: PaperKite.Detail,
                      parts: PaperKite.Parts = .all, bridle: CGFloat? = nil) -> CGImage? {
        let comps = (color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [])
            .map { String(Int($0 * 255)) }.joined(separator: ",")
        let key = "\(Int(side * scale))|\(comps)|\(detail)|\(parts.rawValue)|\(bridle ?? 0)"
        if let hit = cache[key] { return hit }
        let pixels = Int((side * scale).rounded(.up))
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 翻成 y 朝下，和 PaperKite 的格子一致：画出来的图是正的
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: 1, y: -1)
        let unitPixels = CGFloat(pixels) / PaperKite.size
        ctx.scaleBy(x: unitPixels, y: unitPixels)
        PaperKite.draw(ctx, color: color, detail: detail, unit: side / PaperKite.size, bridle: bridle, parts: parts)
        let image = ctx.makeImage()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

#if canImport(UIKit)
public typealias KitePlatformView = UIView
#else
public typealias KitePlatformView = NSView
#endif

/// 平台差异：iOS 的图层 y 朝下；Mac 的图层 y 朝上（换算 y、锚点、转向）
@MainActor
private struct KiteSpace {
    let height: CGFloat
    #if canImport(UIKit)
    func point(_ p: CGPoint) -> CGPoint { p }
    func anchor(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    func angle(_ a: CGFloat) -> CGFloat { a }
    func dy(_ v: CGFloat) -> CGFloat { v }
    #else
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }
    func anchor(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: 1 - y) }
    func angle(_ a: CGFloat) -> CGFloat { -a }
    func dy(_ v: CGFloat) -> CGFloat { -v }
    #endif
}

private func screenScale(_ view: KitePlatformView) -> CGFloat {
    #if canImport(UIKit)
    return view.window?.screen.scale ?? view.traitCollection.displayScale
    #else
    return view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    #endif
}

private func repeating(_ keyPath: String, from: CGFloat, to: CGFloat, duration: Double, additive: Bool = false) -> CABasicAnimation {
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.fromValue = from
    animation.toValue = to
    animation.duration = duration
    animation.autoreverses = true
    animation.repeatCount = .infinity
    animation.isAdditive = additive
    animation.isRemovedOnCompletion = false
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    return animation
}

// MARK: - 思考中：随风飘的小纸鸢

/// 小纸鸢的图层视图：一张剪影图，绕提线点左右晃、上下起伏、一会儿飞远（变小）一会儿飞近（变大）、左右飘。
/// 几个动作周期互相错开，像被风吹，不像钟摆。它是「正在工作」的指示器，和系统的转圈一样，开了「减弱动态效果」也照常动
public final class KiteSpinnerView: KitePlatformView {
    private let kite = CALayer()
    private var size: CGFloat = 16
    private var color: CGColor = CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(kite)
        NotificationCenter.default.addObserver(self, selector: #selector(restart), name: UIApplication.willEnterForegroundNotification, object: nil)
        #else
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(kite)
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    #if !canImport(UIKit)
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    func configure(size: CGFloat, color: CGColor) {
        guard size != self.size || color != self.color || kite.contents == nil else { return }
        self.size = size
        self.color = color
        rebuild()
    }

    #if canImport(UIKit)
    public override func didMoveToWindow() { super.didMoveToWindow(); rebuild() }
    public override func layoutSubviews() { super.layoutSubviews(); place() }
    #else
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); rebuild() }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); place() }
    #endif

    @objc private func restart() { rebuild() }

    private func place() {
        let space = KiteSpace(height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        kite.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        kite.anchorPoint = space.anchor(PaperKite.center.x / PaperKite.size, PaperKite.center.y / PaperKite.size)
        let origin = CGPoint(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2)
        kite.position = space.point(CGPoint(x: origin.x + size * PaperKite.center.x / PaperKite.size,
                                            y: origin.y + size * PaperKite.center.y / PaperKite.size))
        CATransaction.commit()
    }

    private func rebuild() {
        guard window != nil else { return }
        let scale = screenScale(self)
        kite.contents = KiteArt.image(side: size, scale: scale, color: color, detail: .glyph)
        kite.contentsScale = scale
        kite.contentsGravity = .resize
        place()
        let space = KiteSpace(height: bounds.height)
        kite.removeAllAnimations()
        kite.add(repeating("transform.rotation.z", from: space.angle(-10 * .pi / 180), to: space.angle(9 * .pi / 180), duration: 0.9), forKey: "sway")
        kite.add(repeating("transform.scale", from: 0.74, to: 1.06, duration: 2.3), forKey: "depth")
        kite.add(repeating("position.x", from: -size * 0.07, to: size * 0.08, duration: 1.7, additive: true), forKey: "drift")
        kite.add(repeating("position.y", from: space.dy(size * 0.06), to: space.dy(-size * 0.09), duration: 1.3, additive: true), forKey: "bob")
    }
}

/// SwiftUI 里用的小纸鸢（颜色跟着传进来的 Color，主题色变了会重新出图）
public struct KiteSpinner: View {
    var size: CGFloat
    var color: Color

    public init(size: CGFloat = 16, color: Color = KiteColor.brand) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        KiteSpinnerRepresentable(size: size, color: color)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if canImport(UIKit)
private struct KiteSpinnerRepresentable: UIViewRepresentable {
    let size: CGFloat
    let color: Color
    func makeUIView(context: Context) -> KiteSpinnerView { KiteSpinnerView(frame: CGRect(x: 0, y: 0, width: size, height: size)) }
    func updateUIView(_ view: KiteSpinnerView, context: Context) {
        view.configure(size: size, color: color.resolve(in: context.environment).cgColor)
    }
}
#else
private struct KiteSpinnerRepresentable: NSViewRepresentable {
    let size: CGFloat
    let color: Color
    func makeNSView(context: Context) -> KiteSpinnerView { KiteSpinnerView(frame: CGRect(x: 0, y: 0, width: size, height: size)) }
    func updateNSView(_ view: KiteSpinnerView, context: Context) {
        view.configure(size: size, color: color.resolve(in: context.environment).cgColor)
    }
}
#endif

// MARK: - 会呼吸的圆点（运行中的步骤、子 agent）

/// 一闪一闪的小圆点：和小纸鸢一样交给 Core Animation。原来用 SwiftUI 的 repeatForever，
/// 每闪一下整个窗口都要重新排版渲染，Claude 跑工具时 Mac 版 CPU 多占十几个点
public final class PulseDotView: KitePlatformView {
    private let dot = CALayer()
    private var color = CGColor(gray: 0.5, alpha: 1)
    private var low: CGFloat = 0.25
    private var period: Double = 0.7

    public override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(dot)
        NotificationCenter.default.addObserver(self, selector: #selector(restart), name: UIApplication.willEnterForegroundNotification, object: nil)
        #else
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(dot)
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    #if !canImport(UIKit)
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restart() }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); place() }
    #else
    public override func didMoveToWindow() { super.didMoveToWindow(); restart() }
    public override func layoutSubviews() { super.layoutSubviews(); place() }
    #endif

    func configure(color: CGColor, low: CGFloat, period: Double) {
        guard color != self.color || low != self.low || period != self.period else { return }
        self.color = color
        self.low = low
        self.period = period
        restart()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    @objc private func restart() {
        place()
        dot.backgroundColor = color
        dot.removeAllAnimations()
        guard window != nil else { return }
        dot.add(repeating("opacity", from: 1, to: low, duration: period), forKey: "pulse")
    }
}

/// SwiftUI 里用的呼吸圆点
public struct PulseDot: View {
    var color: Color
    var size: CGFloat
    var low: CGFloat
    var period: Double

    public init(color: Color, size: CGFloat = 7, low: CGFloat = 0.25, period: Double = 0.7) {
        self.color = color
        self.size = size
        self.low = low
        self.period = period
    }

    public var body: some View {
        PulseDotRepresentable(color: color, low: low, period: period)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}

#if canImport(UIKit)
private struct PulseDotRepresentable: UIViewRepresentable {
    let color: Color
    let low: CGFloat
    let period: Double
    func makeUIView(context: Context) -> PulseDotView { PulseDotView(frame: .zero) }
    func updateUIView(_ view: PulseDotView, context: Context) {
        view.configure(color: color.resolve(in: context.environment).cgColor, low: low, period: period)
    }
}
#else
private struct PulseDotRepresentable: NSViewRepresentable {
    let color: Color
    let low: CGFloat
    let period: Double
    func makeNSView(context: Context) -> PulseDotView { PulseDotView(frame: .zero) }
    func updateNSView(_ view: PulseDotView, context: Context) {
        view.configure(color: color.resolve(in: context.environment).cgColor, low: low, period: period)
    }
}
#endif

// MARK: - 顶上一直在飞的纸鸢

/// 飞行参数（坐标都是视图里左上角为原点、y 朝下的点）
public struct KiteFlightSpec: Equatable {
    /// 纸鸢重心停在哪
    public var home: CGPoint
    /// 风筝线拉到哪（可以在视图外）
    public var anchor: CGPoint
    /// 整个 384 格子画出来多大（点），纸鸢本身约占它的四分之三宽
    public var span: CGFloat
    /// 飞远（setLift 到 1）时重心去哪；nil = 不飞远
    public var away: CGPoint?
    /// 线越往 anchor 越淡（像钻进了界面后面）
    public var fadeLine: Bool
    /// 很淡的投影（Mac 上纸鸢浮在桌面上）
    public var shadow: Bool

    public init(home: CGPoint, anchor: CGPoint, span: CGFloat, away: CGPoint? = nil, fadeLine: Bool = true, shadow: Bool = false) {
        self.home = home
        self.anchor = anchor
        self.span = span
        self.away = away
        self.fadeLine = fadeLine
        self.shadow = shadow
    }
}

/// 周期 period 秒、初相 phase 的正弦波在第 t 秒的值
private func kiteWave(_ t: Double, _ period: Double, _ phase: Double = 0) -> CGFloat { CGFloat(sin(2 * .pi * t / period + phase)) }

/// 顶上飞的纸鸢的图层视图。纸鸢分三层（两条燕尾 + 其余），线是一条描边路径（要渐隐时拿它当渐变层的蒙版）。
/// 所有动作都按 120 秒一圈预先算好关键帧（每秒 15 帧，三次插值），各个周期都取 120 的约数，首尾无缝衔接：
/// 左右飘、上下浮（两组周期叠加），身子随风偏、往飘的方向侧一点，远近微缩放，燕尾各自摆，线的角度跟着纸鸢变、中段横着轻晃。
/// 起飞和飞远（缩小、挪向 away）只动纸鸢，线头一直钉在 anchor：这两段里线按纸鸢当下的位置逐帧现算（跟着放长、拉长），
/// 纸鸢回到原位再换回关键帧，平时照样不占主线程。
/// 开了「减弱动态效果」时照样浮动、摆动（慢而小），只省掉起飞和远近缩放
public final class KiteFlightView: KitePlatformView {
    private let root = CALayer()
    private let lineGradient = CAGradientLayer()
    private let line = CAShapeLayer()
    /// 包着纸鸢：起飞的位移、飞远的缩放和挪动都加在这一层，线不跟着动
    private let flyer = CALayer()
    private let kite = CALayer()
    private let tailLeft = CALayer()
    private let tailDown = CALayer()
    private let bodyLayer = CALayer()
    private var spec: KiteFlightSpec?
    private var color = CGColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
    private var lineAlpha: CGFloat = 0.75
    private var reduceMotion = false
    private var builtSize: CGSize = .zero
    private var builtScale: CGFloat = 0
    private var pendingTakeoff = false
    public private(set) var paused = false
    private var lift: CGFloat = 0
    /// 关键帧从 root 时间轴上的哪一刻起算（线现算时按它对上纸鸢当下的姿态）
    private var loopStart: CFTimeInterval = 0
    /// 起飞在 root 时间轴上什么时候结束
    private var takeoffEnd: CFTimeInterval = 0
    /// 预先算好的线的摆动：线现算时摘下来，纸鸢回到原位再挂回去
    private var swing: CAKeyframeAnimation?
    /// 纸鸢在原位时渐变的起点（提线结）
    private var restStart: CGPoint = .zero
    /// 线现算时逐帧刷新（只在起飞、飞远的那一段里开着）
    private var link: CADisplayLink?

    static let loop: Double = 120
    static let fps: Double = 15
    /// 飞远到头时缩到多大
    static let farScale: CGFloat = 0.3

    public override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(root)
        NotificationCenter.default.addObserver(self, selector: #selector(restart), name: UIApplication.willEnterForegroundNotification, object: nil)
        #else
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(root)
        #endif
        line.fillColor = nil
        line.lineCap = .round
        line.lineJoin = .round
        kite.addSublayer(tailLeft)
        kite.addSublayer(tailDown)
        kite.addSublayer(bodyLayer)
        flyer.addSublayer(kite)
        root.addSublayer(lineGradient)
        root.addSublayer(flyer)
    }

    required init?(coder: NSCoder) { fatalError() }

    #if !canImport(UIKit)
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    /// 换参数（一样的不重建）
    public func configure(_ spec: KiteFlightSpec, color: CGColor? = nil, lineAlpha: CGFloat = 0.75, reduceMotion: Bool = false) {
        let changed = spec != self.spec || reduceMotion != self.reduceMotion || (color != nil && color != self.color) || lineAlpha != self.lineAlpha
        self.spec = spec
        if let color { self.color = color }
        self.lineAlpha = lineAlpha
        self.reduceMotion = reduceMotion
        if changed { rebuild() }
    }

    /// 从左下方升起来、慢慢停到原位（窗口出现、回到首页顶部时）：只升纸鸢，线头留在原处，线跟着一点点放长
    public func takeoff() {
        guard !reduceMotion else { return }
        guard window != nil, spec != nil, kite.animationKeys() != nil else { pendingTakeoff = true; return }
        pendingTakeoff = false
        guard let spec else { return }
        let space = KiteSpace(height: bounds.height)
        let rise = CABasicAnimation(keyPath: "position")
        rise.fromValue = NSValue(point: CGPoint(x: -spec.span * 0.35, y: space.dy(spec.span * 0.55)))
        rise.toValue = NSValue(point: CGPoint.zero)
        rise.isAdditive = true
        rise.duration = 1.6
        rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        flyer.add(rise, forKey: "takeoff")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.55
        root.add(fade, forKey: "takeoffFade")
        takeoffEnd = rootTime + rise.duration
        updateLine()
    }

    /// 飞远的进度（0 = 原位，1 = 重心到了 spec.away、缩到三成）：只动纸鸢，线头钉在 anchor 不动、线跟着拉长，
    /// 像纸鸢飞远了、线还牵在原处。spec 没给 away 时不动
    public func setLift(_ progress: CGFloat) {
        let progress = min(max(progress, 0), 1)
        guard progress != lift else { return }
        lift = progress
        applyLift()
    }

    /// 暂停 / 继续（看不见的时候停住，不耗电）
    public func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if paused {
            let now = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
            root.timeOffset = now
            stopLink()
        } else {
            let pausedAt = root.timeOffset
            root.speed = 1
            root.timeOffset = 0
            root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
            updateLine()
        }
    }

    #if canImport(UIKit)
    public override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stopLink() }; rebuild() }
    public override func layoutSubviews() { super.layoutSubviews(); if bounds.size != builtSize { rebuild() } }
    #else
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stopLink() }; rebuild() }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); if bounds.size != builtSize { rebuild() } }
    #endif

    @objc private func restart() { rebuild() }

    private func rebuild() {
        guard let spec, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let scale = screenScale(self)
        let space = KiteSpace(height: bounds.height)
        builtSize = bounds.size
        builtScale = scale
        let span = spec.span
        let unit = span / PaperKite.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 先恢复正常走时（暂停是靠 root 的 speed = 0），挂完新动画再按需暂停
        let wasPaused = paused
        root.speed = 1
        root.timeOffset = 0
        root.beginTime = 0
        paused = false
        root.frame = bounds
        root.removeAllAnimations()
        ([flyer, kite, tailLeft, tailDown, bodyLayer, line, lineGradient] as [CALayer]).forEach { $0.removeAllAnimations() }
        takeoffEnd = 0
        // flyer 和 root 一样大，以纸鸢重心为锚点（缩放就以它为中心）
        flyer.bounds = CGRect(origin: .zero, size: bounds.size)
        flyer.anchorPoint = space.anchor(spec.home.x / bounds.width, spec.home.y / bounds.height)
        flyer.position = space.point(spec.home)

        // 纸鸢三层：按「最远飞近时」的大小出图，缩放时不糊
        let side = span * 1.04
        let detail: PaperKite.Detail = span >= 48 ? .full : .glyph
        kite.bounds = CGRect(x: 0, y: 0, width: span, height: span)
        kite.anchorPoint = space.anchor(PaperKite.center.x / PaperKite.size, PaperKite.center.y / PaperKite.size)
        kite.position = space.point(spec.home)
        for (layer, parts) in [(tailLeft, PaperKite.Parts.tailLeft), (tailDown, .tailDown), (bodyLayer, .rest)] {
            layer.contents = KiteArt.image(side: side, scale: scale, color: color, detail: detail, parts: parts, bridle: parts == .rest ? 1.2 : nil)
            layer.contentsScale = scale * side / span
            layer.contentsGravity = .resize
            layer.bounds = kite.bounds
        }
        bodyLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        bodyLayer.position = CGPoint(x: span / 2, y: span / 2)
        for (layer, pivot) in [(tailLeft, PaperKite.tailLeftRoot), (tailDown, PaperKite.tailDownRoot)] {
            layer.anchorPoint = space.anchor(pivot.x / PaperKite.size, pivot.y / PaperKite.size)
            layer.position = KiteSpace(height: span).point(CGPoint(x: pivot.x * unit, y: pivot.y * unit))
        }
        if spec.shadow {
            kite.shadowColor = CGColor(gray: 0, alpha: 1)
            kite.shadowOpacity = 0.22
            kite.shadowRadius = 6
            kite.shadowOffset = CGSize(width: 0, height: space.dy(4))
        } else {
            kite.shadowOpacity = 0
        }

        // 线：渐隐时描边路径当渐变层的蒙版（渐变从提线结到 anchor 由实到虚）；不渐隐就直接描边
        line.lineWidth = max(1.2 * unit, 0.6)
        line.frame = root.bounds
        let lineColor = color.copy(alpha: lineAlpha) ?? color
        line.removeFromSuperlayer()
        if spec.fadeLine {
            line.strokeColor = CGColor(gray: 0, alpha: 1)
            lineGradient.isHidden = false
            lineGradient.frame = root.bounds
            lineGradient.colors = [lineColor, lineColor, color.copy(alpha: 0) ?? color]
            lineGradient.locations = [0, 0.4, 1]
            let knot = CGPoint(x: spec.home.x + (PaperKite.knot.x - PaperKite.center.x) * unit,
                               y: spec.home.y + (PaperKite.knot.y - PaperKite.center.y) * unit)
            restStart = unitPoint(knot, space)
            lineGradient.startPoint = restStart
            lineGradient.endPoint = unitPoint(spec.anchor, space)
            lineGradient.mask = line
        } else {
            lineGradient.mask = nil
            lineGradient.isHidden = true
            line.strokeColor = lineColor
            root.insertSublayer(line, below: flyer)
        }
        CATransaction.commit()

        animate(spec, space: space)
        applyLift()
        if pendingTakeoff { takeoff() }
        if wasPaused { setPaused(true) }
    }

    /// 渐变层的单位坐标跟着图层的坐标系走（Mac 原点在左下），用换算后的点算
    private func unitPoint(_ p: CGPoint, _ space: KiteSpace) -> CGPoint {
        let q = space.point(p)
        return CGPoint(x: q.x / max(bounds.width, 1), y: q.y / max(bounds.height, 1))
    }

    private var rootTime: CFTimeInterval { root.convertTime(CACurrentMediaTime(), from: nil) }

    /// 一圈里第 t 秒纸鸢的姿态（y 朝下的视图坐标）：重心、身子偏的角度、远近缩放、提线结在哪
    private func pose(_ spec: KiteFlightSpec, at t: Double) -> (center: CGPoint, angle: CGFloat, depth: CGFloat, knot: CGPoint) {
        let k = spec.span / 100
        let unit = spec.span / PaperKite.size
        let dx = (7 * kiteWave(t, 10) + 2.5 * kiteWave(t, 4, 1.1)) * k
        let dy = (6 * kiteWave(t, 6, 0.5) + 2 * kiteWave(t, 3)) * k
        let angle = (4 * kiteWave(t, 5, 0.3) + 1.5 * kiteWave(t, 2, 0.7) + 2 * kiteWave(t, 10, .pi / 2)) * .pi / 180
        let depth: CGFloat = reduceMotion ? 1 : 1 + 0.03 * kiteWave(t, 8)
        let center = CGPoint(x: spec.home.x + dx, y: spec.home.y + dy)
        // 提线结跟着纸鸢转：结相对重心的偏移转过 angle、缩放 depth
        let ox = (PaperKite.knot.x - PaperKite.center.x) * unit * depth, oy = (PaperKite.knot.y - PaperKite.center.y) * unit * depth
        let knot = CGPoint(x: center.x + ox * cos(angle) - oy * sin(angle), y: center.y + ox * sin(angle) + oy * cos(angle))
        return (center, angle, depth, knot)
    }

    /// 第 t 秒从提线结拉到 anchor 的线：中段往下坠一点、横着轻晃（线越长坠得越多）
    private func linePath(_ spec: KiteFlightSpec, from knot: CGPoint, at t: Double, space: KiteSpace) -> CGPath {
        let chord = CGPoint(x: spec.anchor.x - knot.x, y: spec.anchor.y - knot.y)
        let length = hypot(chord.x, chord.y)
        let sag = length * (0.07 + 0.02 * kiteWave(t, 3))
        let swing = length * 0.05 * kiteWave(t, 2.4, 0.9)
        let path = CGMutablePath()
        path.move(to: space.point(knot))
        path.addCurve(to: space.point(spec.anchor),
                      control1: space.point(CGPoint(x: knot.x + chord.x * 0.3 + swing, y: knot.y + chord.y * 0.3 + sag)),
                      control2: space.point(CGPoint(x: knot.x + chord.x * 0.7 + swing * 0.5, y: knot.y + chord.y * 0.7 + sag * 0.8)))
        return path
    }

    /// 算一圈（120 秒）的关键帧挂上去
    private func animate(_ spec: KiteFlightSpec, space: KiteSpace) {
        let count = Int(Self.loop * Self.fps)
        var positions: [NSValue] = [], angles: [CGFloat] = [], depths: [CGFloat] = []
        var tailsLeft: [CGFloat] = [], tailsDown: [CGFloat] = [], paths: [CGPath] = []
        positions.reserveCapacity(count + 1)
        for i in 0...count {
            let t = Double(i) / Self.fps
            let now = pose(spec, at: t)
            positions.append(NSValue(point: space.point(now.center)))
            angles.append(space.angle(now.angle))
            depths.append(now.depth)
            tailsLeft.append(space.angle(3.5 * kiteWave(t, 1.5) * .pi / 180))
            tailsDown.append(space.angle(3 * kiteWave(t, 2, 1.3) * .pi / 180))
            paths.append(linePath(spec, from: now.knot, at: t, space: space))
        }
        // 各层的关键帧都从同一刻起算：线现算、再挂回去时按它对齐
        loopStart = rootTime
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = Self.loop
            animation.repeatCount = .infinity
            animation.calculationMode = .cubic
            animation.isRemovedOnCompletion = false
            animation.beginTime = loopStart
            return animation
        }
        kite.position = positions[0].pointValue
        kite.add(keyframes("position", positions), forKey: "drift")
        kite.add(keyframes("transform.rotation.z", angles), forKey: "lean")
        if !reduceMotion { kite.add(keyframes("transform.scale", depths), forKey: "depth") }
        tailLeft.add(keyframes("transform.rotation.z", tailsLeft), forKey: "flutter")
        tailDown.add(keyframes("transform.rotation.z", tailsDown), forKey: "flutter")
        line.path = paths[0]
        let swing = keyframes("path", paths)
        swing.calculationMode = .linear
        self.swing = swing
        line.add(swing, forKey: "swing")
    }

    /// 飞远这一段纸鸢以重心为中心缩到多大、整体挪多少（y 朝下）
    private func liftMotion(_ spec: KiteFlightSpec) -> (scale: CGFloat, move: CGPoint) {
        guard let away = spec.away, lift > 0 else { return (1, .zero) }
        return (1 - (1 - Self.farScale) * lift, CGPoint(x: (away.x - spec.home.x) * lift, y: (away.y - spec.home.y) * lift))
    }

    private func applyLift() {
        guard let spec else { return }
        let motion = liftMotion(spec)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flyer.transform = CATransform3DConcat(CATransform3DMakeScale(motion.scale, motion.scale, 1),
                                              CATransform3DMakeTranslation(motion.move.x, KiteSpace(height: bounds.height).dy(motion.move.y), 0))
        CATransaction.commit()
        updateLine()
    }

    /// 让线跟上纸鸢：纸鸢在原位用预先算好的关键帧；起飞、飞远时按纸鸢当下的位置现算，并逐帧刷新（暂停时不刷）
    private func updateLine() {
        guard let spec, let swing, window != nil else { stopLink(); return }
        let space = KiteSpace(height: bounds.height)
        let now = rootTime
        let motion = liftMotion(spec)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard motion.scale != 1 || now < takeoffEnd else {
            stopLink()
            if line.animation(forKey: "swing") == nil {
                line.add(swing, forKey: "swing")
                lineGradient.startPoint = restStart
            }
            return
        }
        line.removeAnimation(forKey: "swing")
        let t = (now - loopStart).truncatingRemainder(dividingBy: Self.loop)
        let at = pose(spec, at: t).knot
        // 提线结跟着 flyer 走：以重心为中心缩放、挪动，再加上起飞的位移（叠加动画，从呈现层读）
        var knot = CGPoint(x: spec.home.x + (at.x - spec.home.x) * motion.scale + motion.move.x,
                           y: spec.home.y + (at.y - spec.home.y) * motion.scale + motion.move.y)
        if let shown = flyer.presentation() {
            knot.x += shown.position.x - flyer.position.x
            knot.y += space.dy(shown.position.y - flyer.position.y)
        }
        line.path = linePath(spec, from: knot, at: t, space: space)
        if spec.fadeLine { lineGradient.startPoint = unitPoint(knot, space) }
        if !paused { startLink() }
    }

    private func startLink() {
        guard link == nil else { return }
        #if canImport(UIKit)
        let link = CADisplayLink(target: self, selector: #selector(step))
        #else
        let link = displayLink(target: self, selector: #selector(step))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() { updateLine() }
}

#if canImport(UIKit)
private extension NSValue {
    convenience init(point: CGPoint) { self.init(cgPoint: point) }
    var pointValue: CGPoint { cgPointValue }
}
#endif

/// SwiftUI 里用的顶上纸鸢（iPhone 首页用；Mac 主窗口直接用 KiteFlightView）。
/// 颜色跟着传进来的 Color 走（一般是主题色），浅色 / 深色、换主题时 SwiftUI 会重新调 update，重新上色
public struct KiteFlight: View {
    var spec: KiteFlightSpec
    var color: Color
    /// 飞远的进度（见 KiteFlightView.setLift）
    var lift: CGFloat
    var paused: Bool
    /// 变了就起飞一次
    var takeoff: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(spec: KiteFlightSpec, color: Color = KiteColor.brand, lift: CGFloat = 0, paused: Bool = false, takeoff: Date? = nil) {
        self.spec = spec
        self.color = color
        self.lift = lift
        self.paused = paused
        self.takeoff = takeoff
    }

    public var body: some View {
        KiteFlightRepresentable(spec: spec, color: color, lift: lift, paused: paused, takeoff: takeoff, reduceMotion: reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if canImport(UIKit)
private struct KiteFlightRepresentable: UIViewRepresentable {
    let spec: KiteFlightSpec
    let color: Color
    let lift: CGFloat
    let paused: Bool
    let takeoff: Date?
    let reduceMotion: Bool
    final class Coordinator { var takeoff: Date? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> KiteFlightView { KiteFlightView(frame: .zero) }
    func updateUIView(_ view: KiteFlightView, context: Context) {
        view.configure(spec, color: color.resolve(in: context.environment).cgColor, reduceMotion: reduceMotion)
        view.setLift(lift)
        if takeoff != context.coordinator.takeoff {
            context.coordinator.takeoff = takeoff
            if takeoff != nil { view.takeoff() }
        }
        view.setPaused(paused)
    }
}
#else
private struct KiteFlightRepresentable: NSViewRepresentable {
    let spec: KiteFlightSpec
    let color: Color
    let lift: CGFloat
    let paused: Bool
    let takeoff: Date?
    let reduceMotion: Bool
    final class Coordinator { var takeoff: Date? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> KiteFlightView { KiteFlightView(frame: .zero) }
    func updateNSView(_ view: KiteFlightView, context: Context) {
        view.configure(spec, color: color.resolve(in: context.environment).cgColor, reduceMotion: reduceMotion)
        view.setLift(lift)
        if takeoff != context.coordinator.takeoff {
            context.coordinator.takeoff = takeoff
            if takeoff != nil { view.takeoff() }
        }
        view.setPaused(paused)
    }
}
#endif
