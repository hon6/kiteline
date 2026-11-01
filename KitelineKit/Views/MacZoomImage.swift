#if os(macOS)
import AppKit
import SwiftUI

/// Mac 看大图能放大缩小、拖着看（同「预览」）：触控板双指捏合；⌘ 或 ⌥ 加滚轮；双击在「适合窗口」和「实际大小」之间切换；
/// 放大后按住拖动、双指滑动移着看；横向放得下时双指左右划、或按住左右拖，翻上一张 / 下一张（同「预览」）。
/// 按钮和快捷键（⌘+ ⌘- ⌘0 ⌘9）经 ZoomControl 调
@MainActor
final class ZoomControl: ObservableObject {
    /// 现在的倍数（1 = 原图的点大小）
    @Published fileprivate(set) var scale: CGFloat = 1
    /// 跟着窗口适合大小（没手动缩放过；窗口改大小时继续适合）
    @Published fileprivate(set) var fitting = true
    fileprivate weak var view: ZoomScrollView? {
        didSet { if view != nil { Self.current = self } }
    }
    /// 自测用：最近打开的看大图
    static weak var current: ZoomControl?

    var percent: String { "\(Int((scale * 100).rounded()))%" }

    func set(_ scale: CGFloat) { view?.setScale(scale, at: nil) }

    func zoomIn() { view?.zoom(by: 1.25) }
    func zoomOut() { view?.zoom(by: 1 / 1.25) }
    func actualSize() { view?.setScale(1, at: nil) }
    func fit() { view?.fitToWindow() }
}

struct ZoomImageView: NSViewRepresentable {
    let image: NSImage
    let control: ZoomControl
    /// 左右滑翻页：-1 上一张、1 下一张；只有一张时不给
    var onSwipe: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.control = control
        view.onSwipe = onSwipe
        control.view = view
        view.show(image)
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        control.view = view
        view.onSwipe = onSwipe
        if view.image !== image { view.show(image) }
    }
}

final class ZoomScrollView: NSScrollView {
    fileprivate weak var control: ZoomControl?
    fileprivate var onSwipe: ((Int) -> Void)?
    private(set) var image: NSImage?
    private let canvas = ZoomCanvas()
    private var fitting = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = canvas
        drawsBackground = false
        contentView.drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 16
        canvas.owner = self
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: NSImage) {
        self.image = image
        canvas.setImage(image)
        fitting = true
        fitToWindow()
    }

    /// 适合窗口：整张放得下；小图不放大（最多原大小）
    private var fitScale: CGFloat {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return 1 }
        let area = contentSize
        return min(area.width / size.width, area.height / size.height, 1)
    }

    func fitToWindow() {
        fitting = true
        let scale = max(fitScale, minMagnification)
        magnification = scale
        centerContent()
        report()
    }

    /// 以 point（文档坐标）为中心缩放；不给就以可见区域中心
    func setScale(_ scale: CGFloat, at point: NSPoint?) {
        fitting = false
        let target = min(max(scale, minMagnification), maxMagnification)
        let center = point ?? NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(target, centeredAt: center)
        report()
    }

    func zoom(by factor: CGFloat) { setScale(magnification * factor, at: nil) }

    /// 双击：适合窗口 ⇄ 实际大小（对着双击的那一点放大）
    fileprivate func toggle(at point: NSPoint) {
        if fitting || abs(magnification - fitScale) < 0.01 {
            setScale(fitScale >= 1 ? 2 : 1, at: point)
        } else {
            fitToWindow()
        }
    }

    private func centerContent() {
        let clip = contentView.bounds.size
        let doc = canvas.frame.size
        contentView.scroll(to: NSPoint(x: (doc.width - clip.width) / 2, y: (doc.height - clip.height) / 2))
        reflectScrolledClipView(contentView)
    }

    private func report() {
        control?.scale = magnification
        control?.fitting = fitting
    }

    @objc private func magnified() {
        fitting = false
        report()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        fitting = false
        report()
    }

    /// 横向放得下（没放大到要横着移）：这时左右滑是翻页，不是移着看
    fileprivate var fitsHorizontally: Bool { canvas.frame.width * magnification <= contentSize.width + 1 }

    /// 这次触控板手势横向、纵向各划了多少，翻过页没有（一次手势只翻一张）
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    private var swiped = false

    override func scrollWheel(with event: NSEvent) {
        // ⌘ / ⌥ + 滚轮：以鼠标所在的点缩放；不按就是平常的滚动（放大后移着看）
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) else {
            if !swipe(event) { super.scrollWheel(with: event) }
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0 else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        setScale(magnification * pow(1.01, delta), at: point)
    }

    /// 左右滑翻页，返回这个事件是不是被翻页用掉了。触控板按手势算：划过 60 点翻一张，松手后的惯性不再翻；
    /// 鼠标的横向滚轮（或按住 Shift 滚）一格翻一张
    private func swipe(_ event: NSEvent) -> Bool {
        guard let onSwipe, fitsHorizontally else { return false }
        // 换算成手指方向（「自然滚动」开着时内容跟手指走）：手指往右划 = 看上一张，同「预览」「照片」
        let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        guard event.hasPreciseScrollingDeltas else {
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
            onSwipe(fingerX > 0 ? -1 : 1)
            return true
        }
        if event.phase == .began {
            swipeX = 0
            swipeY = 0
            swiped = false
        }
        if !event.momentumPhase.isEmpty { return swiped || abs(swipeX) > abs(swipeY) }
        swipeX += fingerX
        swipeY += event.scrollingDeltaY
        guard abs(swipeX) > abs(swipeY) else { return false }
        if !swiped, abs(swipeX) > 60 {
            swiped = true
            onSwipe(swipeX > 0 ? -1 : 1)
        }
        return true
    }

    /// 按住左右拖（横向放得下时）松手翻页：拖过 80 点、横向为主
    fileprivate func dragEnded(dx: CGFloat, dy: CGFloat) {
        guard let onSwipe, fitsHorizontally, abs(dx) > 80, abs(dx) > abs(dy) * 1.5 else { return }
        onSwipe(dx > 0 ? -1 : 1)
    }

    private var laidOut: NSSize = .zero

    override func layout() {
        super.layout()
        // 窗口改大小：没手动缩放过的继续适合窗口
        guard contentSize != laidOut else { return }
        laidOut = contentSize
        if fitting { fitToWindow() }
    }
}

/// 居中：图比可见区域小时放在正中，不贴左下角
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// 图本身：用图层画（缩放交给显卡，大图也流畅）；按住拖动移着看，双击切换适合 / 实际大小
private final class ZoomCanvas: NSView {
    weak var owner: ZoomScrollView?
    private var dragStart: NSPoint?
    private var originStart: NSPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setImage(_ image: NSImage) {
        wantsLayer = true
        layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? image
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
        setFrameSize(image.size)
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: dragStart == nil ? .openHand : .closedHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            owner?.toggle(at: convert(event.locationInWindow, from: nil))
            return
        }
        dragStart = event.locationInWindow
        originStart = owner?.contentView.bounds.origin ?? .zero
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let owner else { return }
        let scale = owner.magnification
        let dx = (event.locationInWindow.x - start.x) / scale
        let dy = (event.locationInWindow.y - start.y) / scale
        // 窗口坐标 y 朝上、图是翻转坐标（y 朝下）：往下拖看上面
        owner.contentView.scroll(to: NSPoint(x: originStart.x - dx, y: originStart.y + dy))
        owner.reflectScrolledClipView(owner.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if let start = dragStart {
            owner?.dragEnded(dx: event.locationInWindow.x - start.x, dy: event.locationInWindow.y - start.y)
        }
        dragStart = nil
        NSCursor.openHand.set()
        window?.invalidateCursorRects(for: self)
    }
}

#endif
