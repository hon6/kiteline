import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers
import SwiftUI
import KitelineKit
import WebKit

// AR 模式：主窗口收起，换成一块完全透明的窗口——默认就铺在软件窗口那一块（主窗口在哪、多大就在哪，11-21 反馈：默认不要全屏），
// 拖顶边移动、拖边缘改大小，按钮 / M / ⌃⌘F / 双击顶边切到全屏；桌面照常看得见，所有会话（和它们在用的浏览器）是漂在空中的窗口（Resources/world/ar.html，three.js CSS3D）。
// 左上角一个玻璃小球就是收起来的侧栏：指上去展开成平时的会话列表（真的侧栏，右键菜单、筛选都在），移开收回；点一下钉住。
// 「穿透」打开后只有窗口和小球接鼠标，其余地方的点击落到桌面和别的 App 上，窗口浮在最上面——一边干活一边看着它们。
// 进出：侧栏顶上数据流旁边的按钮、⇧⌘A、菜单「文件 → AR 模式」；离开：小球展开后的「离开」、再按 ⇧⌘A、连按两次 Esc。

@MainActor
final class ARMode: NSObject, NSWindowDelegate {
    static let shared = ARMode()
    let dock = ARDock()
    private(set) var window: ARWindow?
    private var bag: Set<AnyCancellable> = []
    private var mouseTimer: Timer?
    /// 按键先在这里接住（WASD 等）：不然中文输入法会把字母当拼音截走，弹出组字条，镜头不动（11-21 截图）
    private var keyMonitor: Any?
    /// 网页里的输入框正在打字（漂浮窗口的输入框）：按键原样交给网页，走输入法
    var webTyping = false
    /// 穿透模式下网页报来的窗口范围（左上角为原点，点）
    private var rects: [CGRect] = []

    var isOn: Bool { window != nil }

    /// 测试实例在按步骤截图（TARS_CAPTURE_STEPS）
    static var capturing: Bool { AppConfig.isolated && ProcessInfo.processInfo.environment["TARS_CAPTURE_STEPS"] != nil }

    func toggle() { isOn ? exit() : enter() }

    func enter() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let main = MainWindowController.shared.window
        guard let screen = main?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let fullscreen = dock.fullscreen || main?.styleMask.contains(.fullScreen) == true
        var frame = fullscreen ? screen.frame : Self.windowedFrame(main: main, screen: screen)
        savedFrame = fullscreen ? Self.windowedFrame(main: main, screen: screen) : nil
        // 测试实例按步骤截图时：窗口放到屏幕外、全透明、鼠标穿透，不抢前台（用户看不见、也点不到）；KITELINE_AR_SIZE=1512x982 模拟别的屏幕尺寸
        let capture = Self.capturing
        if capture {
            let wh = (ProcessInfo.processInfo.environment["KITELINE_AR_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
            frame = NSRect(x: -20000, y: -20000, width: wh.first ?? frame.width, height: wh.count > 1 ? wh[1] : frame.height)
        }
        let window = ARWindow(contentRect: frame, styleMask: fullscreen ? [.borderless] : [.borderless, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 420)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.title = "Kiteline AR"
        window.delegate = self
        // 透明的地方也要接鼠标（拖动转头、滚轮前后）：明确设成 false，不让系统按透明度放过去
        window.ignoresMouseEvents = false
        let root = ARRootView(frame: NSRect(origin: .zero, size: frame.size), dock: dock)
        root.setWindowed(!fullscreen)
        window.contentView = root
        window.setFrame(frame, display: false)
        self.window = window

        let host = WorldHost.ar
        root.attach(host.webView)
        host.window = window
        host.setShown(true)
        if capture {
            // 屏幕外的窗口 WebKit 当成被挡住、不画也不跑动画：截图时关掉它的遮挡检测，照常画（只在测试实例里）
            if host.webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
                host.webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
            }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            window.setFrameOrigin(frame.origin)
            KitelineModel.shared.arMode = true
            return
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host.webView)
        NSApp.activate(ignoringOtherApps: true)
        main?.orderOut(nil)
        KitelineModel.shared.arMode = true
        applyPassthrough()
        applyBackground()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            MainActor.assumeIsolated { ARMode.shared.route(event) ? nil : event }
        }

        // 换了显示器分辨率 / 接拔屏幕：全屏时重新铺满，窗口模式时挪回屏幕里
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refit() } }
            .store(in: &bag)
    }

    /// 离开 AR：透明窗口收起、网页 30 秒后放掉，主窗口回来
    func exit(showMain: Bool = true) {
        guard let window else { return }
        webTyping = false
        bag.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        mouseTimer?.invalidate()
        mouseTimer = nil
        TarsWorldChat.stopBrowsers()
        WorldHost.ar.setShown(false)
        window.delegate = nil
        window.orderOut(nil)
        WorldHost.ar.webView.removeFromSuperview()
        (window.contentView as? ARRootView)?.setBackground(nil)
        self.window = nil
        dock.expanded = false
        KitelineModel.shared.arMode = false
        // 主窗口回到 AR 窗口所在的地方（在 AR 里挪过、改过大小的，主窗口跟着；全屏时回到进来前的位置）
        let frame = dock.fullscreen ? savedFrame : window.frame
        savedFrame = nil
        if !Self.capturing, let frame, let main = MainWindowController.shared.window, !main.styleMask.contains(.fullScreen),
           frame.width >= main.minSize.width, frame.height >= main.minSize.height {
            main.setFrame(frame, display: false)
        }
        if showMain && !Self.capturing { MainWindowController.shared.show() }
    }

    /// AR 窗口里点了「在主窗口中打开」
    func openInMain(_ key: String) {
        exit(showMain: false)
        KitelineModel.shared.setWorld(false)
        MainWindowController.shared.show(select: key)
    }

    /// 侧栏里点了会话：镜头运过去、打开它
    func focus(_ key: String) {
        guard isOn else { return }
        WorldHost.ar.focus(key)
        if !dock.pinned { withAnimation(.klSnappy(duration: 0.3)) { dock.expanded = false } }
        returnKeys()
    }

    /// 背景视频 / 图片（选了「视频」时）：原生播放器铺在网页下面，首尾衔接循环；穿透时藏起来（要看得见桌面）
    func applyBackground() {
        guard let window, let root = window.contentView as? ARRootView else { return }
        let path = dock.backgroundFile
        let on = dock.background == "video" && !dock.passthrough && !path.isEmpty && FileManager.default.fileExists(atPath: path)
        root.setBackground(on ? URL(fileURLWithPath: path) : nil)
    }

    /// 选背景视频 / 图片
    func pickBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .image]
        panel.allowsMultipleSelection = false
        panel.message = L("选择一段视频（会循环播放）或一张图片作为 AR 背景")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self else { return }
                self.dock.backgroundFile = url.path
                self.dock.background = "video"
                self.applyBackground()
                self.returnKeys()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// AR 窗口里的按键：光标不在输入框（会话页的输入框、侧栏搜索）里时，场景用的键直接交给网页，不经过输入法；
    /// 带 ⌘ / ⌃ / ⌥ 的照常走菜单。返回 true = 已处理（吃掉这个事件）
    private func route(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        if webTyping && window.firstResponder === WorldHost.ar.webView { return false }
        if event.type == .flagsChanged {
            guard event.keyCode == 56 || event.keyCode == 60 else { return false }   // 左右 Shift
            sendKey(event.modifierFlags.contains(.shift) ? "keydown" : "keyup", "Shift")
            return false
        }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        let special: [UInt16: String] = [123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp", 53: "Escape", 48: "Tab", 36: "Enter", 76: "Enter"]
        var key = special[event.keyCode]
        if key == nil, let c = event.charactersIgnoringModifiers?.lowercased(), c.count == 1, "wasdqerlfpmhb?".contains(c) { key = c }
        guard let key else { return false }
        sendKey(event.type == .keyDown ? "keydown" : "keyup", key, shift: event.modifierFlags.contains(.shift))
        return true
    }

    private func sendKey(_ type: String, _ key: String, shift: Bool = false) {
        let js = "dispatchEvent(new KeyboardEvent('\(type)',{key:'\(key)',shiftKey:\(shift)}))"
        WorldHost.ar.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 键盘交回网页（在侧栏里点过、打过字之后 WASD 才能接着走）
    func returnKeys() {
        guard let window, !Self.capturing, dock.detail == nil else { return }
        window.makeFirstResponder(WorldHost.ar.webView)
    }

    /// 网页说镜头运到了哪个会话、那块窗口在屏幕上的位置：原生会话页浮上来（key 为空 = 收起）
    func showDetail(_ key: String?, rect: [Double]) {
        withAnimation(.easeOut(duration: 0.22)) {
            if let key, rect.count == 4 {
                dock.detailRect = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
                dock.detail = key
            } else {
                dock.detail = nil
            }
        }
        if key == nil { returnKeys(); return }
        // 光标直接放进输入框：运镜过去就能打字
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated { self?.focusComposer() }
        }
    }

    /// 会话页收起（× / Esc）：网页里的镜头也退回去
    func closeDetail() {
        withAnimation(.easeOut(duration: 0.18)) { dock.detail = nil }
        WorldHost.ar.post(["type": "cmd", "name": "unfocus"])
        returnKeys()
    }

    private func focusComposer() {
        guard let window, let root = window.contentView as? ARRootView else { return }
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable, !text.isHidden { return text }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        if let text = find(root.dockHost) { window.makeFirstResponder(text) }
    }

    func windowWillClose(_ notification: Notification) {
        exit()
    }

    private func refit() {
        guard let window, !Self.capturing, let screen = window.screen ?? NSScreen.main else { return }
        if dock.fullscreen {
            window.setFrame(screen.frame, display: true)
        } else if !screen.visibleFrame.intersects(window.frame) {
            window.setFrame(Self.windowedFrame(main: nil, screen: screen), display: true)
        }
    }

    /// 全屏之前的窗口位置（切回窗口模式时回到这里）
    private var savedFrame: NSRect?

    /// 窗口模式铺在哪：主窗口所在的那一块；主窗口没有或在系统全屏里时，屏幕正中一块
    private static func windowedFrame(main: NSWindow?, screen: NSScreen) -> NSRect {
        if let main, !main.styleMask.contains(.fullScreen), main.frame.width >= 400, main.frame.height >= 300 { return main.frame }
        let area = screen.visibleFrame
        let size = NSSize(width: min(1280, area.width - 80), height: min(820, area.height - 80))
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 窗口模式 ↔ 全屏：全屏时铺满这块屏（菜单栏、Dock 照常在上面），回来时回到原来的位置和大小
    func applyFullscreen() {
        guard let window, !Self.capturing, let root = window.contentView as? ARRootView else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        if dock.fullscreen {
            if window.styleMask.contains(.resizable) { savedFrame = window.frame }
            window.styleMask = [.borderless]
            root.setWindowed(false)
            window.setFrame(screen.frame, display: true, animate: true)
        } else {
            let frame = savedFrame ?? Self.windowedFrame(main: MainWindowController.shared.window, screen: screen)
            window.styleMask = [.borderless, .resizable]
            root.setWindowed(true)
            window.setFrame(frame, display: true, animate: true)
        }
        returnKeys()
    }

    /// 自测截图：窗口服务器真正合成出来的样子（自己的窗口，不用屏幕录制权限；窗口在屏幕外，截的时候临时不透明，用户看不见），
    /// 叠在 backdrop（当桌面）上。WKWebView 自己的 takeSnapshot 画不对 3D 变换的层（窗口全挤在左上角），只作退路
    func snapshot(to path: String, backdrop: String?) {
        guard let window, let root = window.contentView as? ARRootView else { Log.write("[capture] AR 没开着"); return }
        let alpha = window.alphaValue
        window.alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                let live = Self.windowImage(window)
                window.alphaValue = alpha
                let size = root.bounds.size
                let draw: (NSImage?) -> Void = { top in
                    let out = NSImage(size: size)
                    out.lockFocus()
                    if let path = backdrop, let desk = NSImage(contentsOfFile: path) {
                        desk.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
                    } else {
                        NSGradient(starting: NSColor(white: 0.32, alpha: 1), ending: NSColor(white: 0.12, alpha: 1))?.draw(in: NSRect(origin: .zero, size: size), angle: -60)
                    }
                    top?.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
                    out.unlockFocus()
                    guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: URL(fileURLWithPath: path))
                    Log.write("[capture] AR 截图 \(path) \(Int(size.width))x\(Int(size.height))\(live == nil ? "（网页截图）" : "（真实合成）")")
                }
                if let live { draw(NSImage(cgImage: live, size: size)); return }
                let config = WKSnapshotConfiguration()
                config.afterScreenUpdates = true
                WorldHost.ar.webView.takeSnapshot(with: config) { image, _ in MainActor.assumeIsolated { draw(image) } }
            }
        }
    }

    private static func windowImage(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        // kCGWindowListOptionIncludingWindow = 8，kCGWindowImageBoundsIgnoreFraming = 1
        return unsafeBitCast(symbol, to: Capture.self)(.null, 8, CGWindowID(window.windowNumber), 1)?.takeRetainedValue()
    }

    // MARK: 穿透

    /// 穿透：窗口浮在别的 App 上面，只在 AR 窗口、小球上接鼠标；关掉时和普通窗口一样（点别的 App 它就退到后面）
    func applyPassthrough() {
        guard let window, !Self.capturing else { return }
        let on = dock.passthrough
        window.level = on ? .floating : .normal
        mouseTimer?.invalidate()
        mouseTimer = nil
        applyBackground()
        if on {
            mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackMouse() }
            }
        } else {
            window.ignoresMouseEvents = false
        }
    }

    func setRects(_ list: [[Double]]) {
        rects = list.compactMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
    }

    /// 鼠标在不在 AR 的东西上：在就接鼠标，不在就让点击落到下面（每秒 30 次，只在穿透时）
    private func trackMouse() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        let point = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        // 按着鼠标（拖动中）时不切，免得拖到一半松手的事件落到别处
        if NSEvent.pressedMouseButtons != 0 && !window.ignoresMouseEvents { return }
        let over = dock.hitRect.insetBy(dx: -8, dy: -8).contains(point) || rects.contains { $0.insetBy(dx: -6, dy: -6).contains(point) }
            || (dock.detail != nil && dock.detailRect.insetBy(dx: -16, dy: -16).contains(point))
        if window.ignoresMouseEvents == over { window.ignoresMouseEvents = !over }
    }
}

/// 透明的无边框窗口：要能成为主窗口、接键盘（WASD）
final class ARWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// ⌃⌘F、菜单「进入全屏幕」：不进系统的全屏空间（透明窗口进去是一整块黑），换成 AR 自己的全屏 / 窗口切换
    override func toggleFullScreen(_ sender: Any?) {
        MainActor.assumeIsolated { ARMode.shared.dock.fullscreen.toggle() }
    }
}

/// 窗口内容：下面是网页（整屏），上面是小球 / 侧栏（只在它自己那块接鼠标，其余透给网页）
final class ARRootView: NSView {
    let dockHost: ARDockHost
    private let strip = ARDragStrip()
    /// 背景视频 / 图片（在最下面）
    private let backdrop = NSView()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var backdropURL: URL?

    init(frame: NSRect, dock: ARDock) {
        dockHost = ARDockHost(rootView: ARDockView(dock: dock))
        dockHost.dock = dock
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.isHidden = true
        addSubview(backdrop)
        dockHost.frame = bounds
        dockHost.autoresizingMask = [.width, .height]
        addSubview(dockHost)
        strip.frame = NSRect(x: 0, y: bounds.height - ARDragStrip.height, width: bounds.width, height: ARDragStrip.height)
        strip.autoresizingMask = [.width, .minYMargin]
        addSubview(strip)
    }

    func setBackground(_ url: URL?) {
        guard url != backdropURL else { backdrop.isHidden = url == nil; return }
        backdropURL = url
        player?.pause()
        player = nil
        looper = nil
        backdrop.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        backdrop.layer?.contents = nil
        guard let url else { backdrop.isHidden = true; return }
        backdrop.isHidden = false
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            backdrop.layer?.contents = NSImage(contentsOf: url)
            backdrop.layer?.contentsGravity = .resizeAspectFill
            return
        }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        let layer = AVPlayerLayer(player: queue)
        layer.videoGravity = .resizeAspectFill
        layer.frame = backdrop.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backdrop.layer?.addSublayer(layer)
        queue.play()
        player = queue
    }

    /// 窗口模式：一圈圆角细边标出 AR 的范围（透明窗口没有边框，不然看不出它在哪），顶上一条可以拖着挪窗口；全屏时都不要
    func setWindowed(_ on: Bool) {
        layer?.cornerRadius = on ? 14 : 0
        layer?.masksToBounds = on
        layer?.borderWidth = on ? 1 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        strip.isHidden = !on
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(_ web: WKWebView) {
        web.removeFromSuperview()
        web.frame = bounds
        web.autoresizingMask = [.width, .height]
        addSubview(web, positioned: .above, relativeTo: backdrop)
    }
}

/// 窗口模式的顶边：按住拖动挪窗口，双击切全屏；中间一条小横杠，指上去变亮
final class ARDragStrip: NSView {
    static let height: CGFloat = 22
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolTip = L("拖动移动窗口，双击切换全屏")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: bounds.midX - 22, y: bounds.midY - 2.5, width: 44, height: 5)
        NSColor.white.withAlphaComponent(hovering ? 0.62 : 0.26).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 2.5, yRadius: 2.5).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            MainActor.assumeIsolated { ARMode.shared.dock.fullscreen.toggle() }
        } else {
            window?.performDrag(with: event)
        }
    }
}

final class ARDockHost: NSHostingView<ARDockView> {
    weak var dock: ARDock?

    required init(rootView: ARDockView) {
        super.init(rootView: rootView)
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let dock else { return nil }
        let local = convert(point, from: superview)
        let y = isFlipped ? local.y : bounds.height - local.y
        let point = CGPoint(x: local.x, y: y)
        let onCard = dock.detail != nil && dock.detailRect.insetBy(dx: -16, dy: -16).contains(point)
        guard onCard || dock.hitRect.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - 小球和侧栏

@MainActor
final class ARDock: ObservableObject {
    @Published var expanded = false
    /// 点了小球：展开后不因为鼠标移开而收回
    @Published var pinned = false
    @Published var passthrough = AppConfig.defaults.bool(forKey: "arPassthrough") {
        didSet {
            AppConfig.defaults.set(passthrough, forKey: "arPassthrough")
            ARMode.shared.applyPassthrough()
            pushPrefs()
        }
    }
    @Published var layout = AppConfig.defaults.string(forKey: "arLayout") ?? "arc" {
        didSet { AppConfig.defaults.set(layout, forKey: "arLayout"); pushPrefs() }
    }
    @Published var follow = AppConfig.defaults.bool(forKey: "arFollow") {
        didSet { AppConfig.defaults.set(follow, forKey: "arFollow"); pushPrefs() }
    }
    /// 背景：none 透明（看到桌面）/ space 宇宙 / sky 天空 / sea 海面 / forest 森林 / aurora 极光（网页里代码画的）/ video 自己选的视频或图片（原生播放）
    @Published var background = AppConfig.defaults.string(forKey: "arBackground") ?? "none" {
        didSet {
            guard background != oldValue else { return }
            AppConfig.defaults.set(background, forKey: "arBackground")
            ARMode.shared.applyBackground()
            pushPrefs()
        }
    }
    /// 自己选的背景视频 / 图片
    @Published var backgroundFile = AppConfig.defaults.string(forKey: "arBackgroundFile") ?? "" {
        didSet { AppConfig.defaults.set(backgroundFile, forKey: "arBackgroundFile"); ARMode.shared.applyBackground() }
    }

    /// 全屏（铺满整块屏）还是只在软件窗口那一块（默认，11-21 反馈：默认不要全屏）
    @Published var fullscreen = AppConfig.defaults.bool(forKey: "arFullscreen") {
        didSet {
            guard fullscreen != oldValue else { return }
            AppConfig.defaults.set(fullscreen, forKey: "arFullscreen")
            ARMode.shared.applyFullscreen()
            pushPrefs()
        }
    }
    /// 小球在哪（左上角为原点）：拖到哪记到哪
    @Published var origin: CGPoint = {
        if let pair = AppConfig.defaults.array(forKey: "arBallOrigin") as? [Double], pair.count == 2 { return CGPoint(x: pair[0], y: pair[1]) }
        return CGPoint(x: 28, y: 96)
    }() {
        didSet { AppConfig.defaults.set([origin.x, origin.y], forKey: "arBallOrigin") }
    }
    /// 小球 / 展开的侧栏现在占的范围（只在这里接鼠标）
    var hitRect: CGRect = .zero
    /// 镜头运到某个会话后，浮在那块窗口位置上的原生会话页（和普通模式完全一样：直接输入、点图看大图、浏览器小窗）；rect 左上角为原点
    @Published var detail: String?
    @Published var detailRect: CGRect = .zero

    var prefs: [String: Any] { ["layout": layout, "passthrough": passthrough, "follow": follow, "fullscreen": fullscreen, "background": background] }

    private var pushing = false
    private func pushPrefs() {
        guard !pushing else { return }
        var message = prefs
        message["type"] = "prefs"
        WorldHost.ar.post(message)
    }

    /// 网页里按了 L / F / P、点了右下角的按钮：记下来（再推回去让两边一致）
    func apply(_ body: [String: Any]) {
        pushing = true
        if let value = body["layout"] as? String, ["arc", "ring", "flat"].contains(value) { layout = value }
        if let value = body["follow"] as? Bool { follow = value }
        pushing = false
        if let value = body["passthrough"] as? Bool { passthrough = value }   // 要推回去：网页按 P 只是请求切换
        if let value = body["fullscreen"] as? Bool { fullscreen = value }     // 同上（M）
        if let value = body["background"] as? String {                         // B 键 / 右下按钮轮换；轮到「视频」但没选过文件就跳过
            background = value == "video" && backgroundFile.isEmpty ? "none" : value
        }
    }
}

struct ARDockView: KLView {
    @ObservedObject var dock: ARDock
    @ObservedObject private var model = KitelineModel.shared
    @State private var drag: CGSize = .zero
    @State private var collapse: DispatchWorkItem?

    var klBody: some View {
        GeometryReader { geometry in
            // 运镜到会话上之后：原生会话页盖在那块窗口的位置上
            if let key = dock.detail {
                ARSessionCard(key: key, dock: dock)
                    .frame(width: dock.detailRect.width, height: dock.detailRect.height)
                    .position(x: dock.detailRect.midX, y: dock.detailRect.midY)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            let height = min(780, max(260, geometry.size.height - min(dock.origin.y, geometry.size.height - 70) - 40))
            Group {
                if dock.expanded {
                    ARSidebarPanel(dock: dock, model: model)
                        .frame(width: 340, height: height)
                        .transition(.asymmetric(insertion: .scale(scale: 0.16, anchor: .topLeading).combined(with: .opacity),
                                                removal: .scale(scale: 0.16, anchor: .topLeading).combined(with: .opacity)))
                } else {
                    ARBall(dock: dock, model: model)
                        .gesture(DragGesture(minimumDistance: 4)
                            .onChanged { drag = $0.translation }
                            .onEnded { value in
                                let x = min(max(8, dock.origin.x + value.translation.width), geometry.size.width - 70)
                                let y = min(max(30, dock.origin.y + value.translation.height), geometry.size.height - 70)
                                dock.origin = CGPoint(x: x, y: y)
                                drag = .zero
                            })
                        .transition(.scale(scale: 0.5, anchor: .topLeading).combined(with: .opacity))
                }
            }
            .klOnGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dock.hitRect = $0 }
            .onHover { inside in hover(inside) }
            .padding(.leading, min(max(8, dock.origin.x), max(8, geometry.size.width - 70)) + drag.width)
            .padding(.top, min(max(30, dock.origin.y), max(30, geometry.size.height - 70)) + drag.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.colorScheme, .dark)
        .tarsLook()
    }

    /// 指上去展开；移开 0.45 秒后收回（钉住了不收）
    private func hover(_ inside: Bool) {
        collapse?.cancel()
        if inside {
            if !dock.expanded, drag == .zero { withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { dock.expanded = true } }
        } else if dock.expanded, !dock.pinned {
            let work = DispatchWorkItem {
                withAnimation(.klSnappy(duration: 0.28)) { dock.expanded = false }
                ARMode.shared.returnKeys()
            }
            collapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }
}

/// 运镜到会话上之后浮出来的会话页：和主窗口里的会话页同一个（TarsSessionCard，自己一份单块分屏），
/// 标题条、按钮、对话排版、输入框、看大图、浏览器小窗都一样；左上角外面一个 ×（Esc），「更多」菜单最上面是「在主窗口中打开」
private struct ARSessionCard: KLView {
    let key: String
    @ObservedObject var dock: ARDock

    private static let accessory = TarsPaneAccessory(
        buttons: { key in AnyView(PaneButtons(model: KitelineModel.shared, key: key)) },
        menu: { key, folded in
            AnyView(Group {
                Button(L("在主窗口中打开")) { ARMode.shared.openInMain(key) }
                Divider()
                PaneMenu(model: KitelineModel.shared, key: key, folded: folded)
            })
        })

    var klBody: some View {
        TarsSessionCard(key: key, accessory: Self.accessory)
            .id(key)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.tarsBrand.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .overlay(alignment: .topLeading) {
                Button { ARMode.shared.closeDetail() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(L("返回（Esc）"))
                .offset(x: -11, y: -11)
            }
    }
}

/// 收起来的侧栏：玻璃小球，中间是纸鸢；有会话在工作时外圈一道光在转，有等你确认的右上角一个数字
private struct ARBall: KLView {
    @ObservedObject var dock: ARDock
    @ObservedObject var model: KitelineModel
    @State private var spin = false

    var klBody: some View {
        let waiting = model.sessions.filter { $0.activity == .waiting }.count
        let busy = model.sessions.contains { $0.activity == .busy }
        ZStack {
            ARGlass(cornerRadius: 28)
            Image(nsImage: ARKiteImage.make(side: 26))
                .resizable()
                .frame(width: 26, height: 26)
            if busy {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Color.tarsBrand, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(2)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
        }
        .frame(width: 56, height: 56)
        .overlay(alignment: .topTrailing) {
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Color.tarsOrange))
                    .offset(x: 4, y: -4)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .contentShape(Circle())
        .onTapGesture {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                dock.pinned = true
                dock.expanded = true
            }
        }
        .help(L("会话列表（悬停展开，点击固定）"))
    }
}

/// 展开的侧栏：顶上一排 AR 的按钮，下面就是平时的会话列表（同新版界面里那一栏，右键菜单、筛选、分组都在）
private struct ARSidebarPanel: KLView {
    @ObservedObject var dock: ARDock
    @ObservedObject var model: KitelineModel

    var klBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: ARKiteImage.make(side: 18)).resizable().frame(width: 18, height: 18)
                Text("Kiteline").font(.app(size: 14, weight: .semibold))
                Text("AR").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.tarsBrand)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Color.tarsBrand.opacity(0.6), lineWidth: 1))
                Spacer(minLength: 4)
                ARIconButton(symbol: dock.pinned ? "pin.fill" : "pin", on: dock.pinned, help: dock.pinned ? L("取消固定（指针移开后自动收起）") : L("固定侧栏")) {
                    dock.pinned.toggle()
                    if !dock.pinned { withAnimation(.klSnappy(duration: 0.28)) { dock.expanded = false } }
                }
                ARIconButton(symbol: dock.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", on: false,
                             help: dock.fullscreen ? L("退出全屏，回到软件窗口大小（M）") : L("全屏（M）")) { dock.fullscreen.toggle() }
                ARIconButton(symbol: "rectangle.portrait.and.arrow.right", on: false, help: L("离开 AR 模式（⇧⌘A）")) { ARMode.shared.exit() }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            // 场景：复位、排列、跟随、穿透
            HStack(spacing: 6) {
                ARChip(title: L("复位"), symbol: "scope", on: false) { WorldHost.ar.post(["type": "cmd", "name": "home"]) }
                Menu {
                    Picker(L("排列"), selection: $dock.layout) {
                        Text(L("弧形")).tag("arc")
                        Text(L("环绕")).tag("ring")
                        Text(L("平面")).tag("flat")
                    }
                    .pickerStyle(.inline)
                } label: {
                    ARChipLabel(title: [ "arc": L("弧形"), "ring": L("环绕"), "flat": L("平面") ][dock.layout] ?? L("弧形"), symbol: "rectangle.3.group", on: false)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Menu {
                    Picker(L("背景"), selection: $dock.background) {
                        Text(L("透明（看到桌面）")).tag("none")
                        Text(L("宇宙")).tag("space")
                        Text(L("天空")).tag("sky")
                        Text(L("海面")).tag("sea")
                        Text(L("森林")).tag("forest")
                        Text(L("极光")).tag("aurora")
                        if !dock.backgroundFile.isEmpty {
                            Text((dock.backgroundFile as NSString).lastPathComponent).tag("video")
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button(L("选择视频或图片…")) { ARMode.shared.pickBackground() }
                } label: {
                    ARChipLabel(title: L("背景"), symbol: "photo.on.rectangle.angled", on: dock.background != "none")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                ARChip(title: L("跟随"), symbol: "dot.radiowaves.left.and.right", on: dock.follow) { dock.follow.toggle() }
                    .help(L("收到新消息时，对应窗口移到眼前停留几秒（F）"))
                ARChip(title: L("穿透"), symbol: "cursorarrow.motionlines", on: dock.passthrough) { dock.passthrough.toggle() }
                    .help(L("穿透：窗口保持在最上层，点击空白处会落到桌面和其他 App 上（P）"))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField(L("搜索会话"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.app(size: 13))
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            SidebarView(model: model, embedded: true)
                .klScrollContentBackground(.hidden)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            Text(L("WASD 移动 · 拖动转向 · 悬停放大 · 点击打开 · Tab 切到下一个待处理的会话"))
                .font(.app(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .background(ARGlass(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }
}

private struct ARIconButton: KLView {
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var klBody: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.tarsBrand : hovering ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(hovering ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct ARChip: KLView {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void

    var klBody: some View {
        Button(action: action) { ARChipLabel(title: title, symbol: symbol, on: on) }
            .buttonStyle(.plain)
    }
}

private struct ARChipLabel: KLView {
    let title: String
    let symbol: String
    let on: Bool

    var klBody: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            Text(title).lineLimit(1)
        }
        .font(.app(size: 12, weight: .medium))
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(on ? Color.tarsBrand.opacity(0.18) : Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(on ? Color.tarsBrand.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(Capsule())
        .fixedSize()
    }
}

/// 透出桌面的磨砂玻璃（窗口本身透明，系统材质要用「窗口后面」的混合才看得到桌面）+ 一层石墨色 + 细边
private struct ARGlass: KLView {
    let cornerRadius: CGFloat

    var klBody: some View {
        ZStack {
            ARVisualEffect()
            Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.42)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

private struct ARVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 白色纸鸢（小球中间、侧栏标题前）
private enum ARKiteImage {
    private static var cache: [CGFloat: NSImage] = [:]

    static func make(side: CGFloat) -> NSImage {
        if let image = cache[side] { return image }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let unit = side / PaperKite.size
            ctx.scaleBy(x: unit, y: unit)
            PaperKite.draw(ctx, color: NSColor.white.cgColor, detail: .glyph, unit: unit)
            return true
        }
        cache[side] = image
        return image
    }
}
