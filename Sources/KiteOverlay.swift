import AppKit
import Observation
import SwiftUI
import KitelineKit

/// 主窗口顶上飞的纸鸢（主题色）：一块透明、鼠标穿透的子窗口挂在主窗口上沿，纸鸢的头和翅尖探出窗口上沿，
/// 胸口两根提线汇成一根，垂进侧栏顶部、渐渐隐去（像拴在 App 里）。纸鸢随主窗口移动，主窗口最小化、全屏、关闭时跟着收起。
/// - 窗口上方空间不够（贴着菜单栏）时，纸鸢再往下落一点，头不被切掉
/// - 侧栏收起时不显示（标题栏那一段会被会话标题占住）
/// - 主窗口被完全挡住、App 隐藏时暂停动画，不耗电；系统开了「减弱动态效果」就停着不动
/// - 设置 → 通用 → 外观里可以关掉
@MainActor
final class KiteOverlay {
    static let shared = KiteOverlay()

    /// 偏好开关（默认开）
    static var enabled: Bool {
        get { AppConfig.defaults.object(forKey: "kiteFlight") as? Bool ?? true }
        set {
            AppConfig.defaults.set(newValue, forKey: "kiteFlight")
            shared.refresh()
        }
    }

    /// 侧栏的宽度（侧栏自己量了报过来；0 = 收起了）。拖侧栏边缘时会连着变，停下来再重排（重排要重算一圈关键帧）
    var sidebarWidth: CGFloat = 0 {
        didSet {
            guard abs(oldValue - sidebarWidth) > 0.5 else { return }
            pendingLayout?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.layout() } }
            pendingLayout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }
    private var pendingLayout: DispatchWorkItem?

    private weak var host: NSWindow?
    private var panel: NSPanel?
    /// 纸鸢本身（图层动画，见 KitelineKit/Views/KiteMark.swift 的 KiteFlightView）
    private let flight = KiteFlightView(frame: .zero)
    private var observers: [NSObjectProtocol] = []
    private var fullScreen = false
    /// 主窗口的浅色 / 深色变了要重新上色
    private var appearanceObservation: NSKeyValueObservation?

    /// 纸鸢整体（384 格子）画多大
    private static let span: CGFloat = 124
    /// 窗口上沿往上留多高：只让头和翅尖探出去（再加上飘动的余量）
    private static let sky: CGFloat = 52
    /// 子窗口往下盖住窗口顶部多少：标题栏 + 搜索框（燕尾、风筝线垂到这里）
    private static let below: CGFloat = 104
    /// 纸鸢重心在窗口上沿下面多少点（10-22 觉得飞出去太多，往下收了约 1.7 厘米）
    private static let sink: CGFloat = 12

    private init() {}

    /// 主窗口建好后调一次：之后窗口每次出现都会自动挂上
    func attach(to window: NSWindow) {
        guard host !== window else { return }
        detach()
        host = window
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                          NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didDeminiaturizeNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        })
        observers.append(center.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        })
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fullScreen = true; self?.hide() }
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fullScreen = false; self?.refresh() }
        })
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout() } }
        }
        trackTheme()
        refresh()
    }

    /// 主题色变了（设置 → 通用 → 外观）重新上色：Look 是 @Observable，用一次观察一次
    private func trackTheme() {
        withObservationTracking {
            _ = Look.shared.palette
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout(); self?.trackTheme() } }
        }
    }

    /// 纸鸢颜色：主题色，按主窗口当前是浅色还是深色取
    private func tint(for window: NSWindow) -> CGColor {
        var environment = EnvironmentValues()
        environment.colorScheme = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        return Color.tarsBrand.resolve(in: environment).cgColor
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        appearanceObservation = nil
        hide()
        host = nil
    }

    /// 该显示就挂上并重新排位置，不该显示就收起
    func refresh() {
        guard let host else { return }
        let visible = host.isVisible && !host.isMiniaturized && !fullScreen && Self.enabled
        guard visible else { hide(); return }
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let appearing = panel.parent !== host
        if appearing { host.addChildWindow(panel, ordered: .above) }
        layout()
        // 每次重新出现都从下面飞上来；窗口完全被挡住时暂停
        if appearing { flight.takeoff() }
        flight.setPaused(!host.occlusionState.contains(.visible))
    }

    /// 自测截图：截图是按图层的静止状态画的，不认蒙版——线改成不渐隐的实线，纸鸢停在原位
    func settleForCapture() {
        refresh()
        capturing = true
        layout()
    }
    private var capturing = false

    private func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        panel.contentView = flight
        return panel
    }

    /// 排位置：子窗口贴着主窗口左上角，往上伸出 headroom、往下盖住标题栏。坐标都按子窗口里左上角为原点、y 朝下
    private func layout() {
        guard let host, let panel, panel.parent === host else { return }
        let frame = host.frame
        let screenTop = (host.screen ?? NSScreen.main)?.visibleFrame.maxY ?? frame.maxY
        let headroom = max(0, min(Self.sky, screenTop - frame.maxY))
        let width: CGFloat = 480
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - Self.below, width: width, height: headroom + Self.below), display: false)
        // 重心在窗口上沿下面一点：头和翅尖探出窗口，身子落在标题栏里。窗口贴着菜单栏（上面没地方）时再往下挪，头不被切掉
        let sink = Self.sink + max(0, 18 - headroom)
        let sidebar = sidebarWidth > 0 ? sidebarWidth : 0
        flight.isHidden = sidebar < 220
        // 别压住侧栏顶上那排按钮（新建、世界、数据流，最右边在 x≈214；纸鸢左翅展开约 45 点）：至少放在 262（11-04 截图）
        let homeX = min(width - 70, max(262, sidebar - 40))
        // 线从结往下垂，在搜索框上渐渐隐去
        let spec = KiteFlightSpec(home: CGPoint(x: homeX, y: headroom + sink),
                                  anchor: CGPoint(x: homeX + 24, y: headroom + 74),
                                  span: Self.span, fadeLine: !capturing, shadow: true)
        flight.configure(spec, color: tint(for: host), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}
