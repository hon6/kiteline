import AppKit

/// 显示器关掉再打开（息屏、拔插、换分辨率）之后，把对话里的文字重画一遍。
///
/// 对话里的文字（尤其气泡里能选中复制的那种）SwiftUI 是用 CGDrawingLayer 一块块画进位图的。
/// 屏幕重新配置那一刻系统让这些层重画，会画成每行字上下颠倒（10-25 实际遇到：显示器关了一夜，
/// 早上打开后整页气泡的字都是倒的，最小化再打开才好）。屏幕变化平息一秒后再让它们重画一遍，
/// 效果和最小化再打开一样；那时窗口还被挡着（显示器还黑着）就等它露出来再画一次
@MainActor
enum ScreenRedraw {
    private static var pending: DispatchWorkItem?
    private static var observers: [NSObjectProtocol] = []
    /// 屏幕变了以后重画时正被挡着的窗口（显示器还黑着、被别的程序盖着）：露出来时再补画一次，补完就不管了
    private static var stale: Set<ObjectIdentifier> = []

    static func start() {
        guard observers.isEmpty else { return }
        // 自测对照：测试实例里 TARS_SCREEN_REDRAW=0 关掉，看不补画时字会不会倒
        if AppConfig.isolated, ProcessInfo.processInfo.environment["TARS_SCREEN_REDRAW"] == "0" { return }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        // 不听 didChangeScreen：小提示、悬停说明这些小窗一出现也会发，每次都整页重画太浪费
        let changes: [(NotificationCenter, Notification.Name, String)] = [
            (center, NSApplication.didChangeScreenParametersNotification, "显示器配置变化"),
            (workspace, NSWorkspace.screensDidWakeNotification, "显示器唤醒"), (workspace, NSWorkspace.didWakeNotification, "电脑唤醒"),
        ]
        for (source, name, cause) in changes {
            observers.append(source.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { schedule(cause) }
            })
        }
        // 窗口换到倍数或色彩不同的屏幕：只重画这一个窗口。菜单栏在各个屏幕上的小窗之类也会发这个通知（倍数、色彩其实没变），
        // 一律整页重画的话隔几分钟就白画一千多处文字（3.49.5 装上后实测），所以只认真的变了、窗口里又有对话文字的
        observers.append(center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                let oldScale = (note.userInfo?[NSWindow.oldScaleFactorUserInfoKey] as? NSNumber).map { CGFloat($0.doubleValue) }
                let oldSpace = note.userInfo?[NSWindow.oldColorSpaceUserInfoKey] as? NSColorSpace
                let changed = (oldScale.map { $0 != window.backingScaleFactor } ?? false) || (oldSpace.map { $0 != window.colorSpace } ?? false)
                guard changed else { return }
                let count = redraw(window)
                if count > 0 { Log.write("窗口「\(window.title)」换了显示倍数或色彩，重画了 \(count) 处文字") }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.occlusionState.contains(.visible),
                      stale.remove(ObjectIdentifier(window)) != nil else { return }
                Log.write("窗口露出来了，补画 \(redraw(window)) 处文字")
            }
        })
    }

    /// 屏幕变化常常一连串（几台显示器挨个接上、虚拟屏幕挪位置），等最后一次过去一秒再画
    private static func schedule(_ cause: String) {
        pending?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                var count = 0
                for window in NSApp.windows {
                    let marked = redraw(window)
                    count += marked
                    if marked > 0, window.isVisible, !window.occlusionState.contains(.visible) { stale.insert(ObjectIdentifier(window)) }
                }
                Log.write("\(cause)，重画了 \(count) 处文字\(stale.isEmpty ? "" : "（\(stale.count) 个窗口被挡着，露出来时再补画）")")
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// 所有窗口里的 CGDrawingLayer 都标成要重画；返回标了几个（自测用）
    static func redrawAll() -> Int { NSApp.windows.reduce(0) { $0 + redraw($1) } }

    private static func redraw(_ window: NSWindow) -> Int {
        guard let root = (window.contentView?.superview ?? window.contentView)?.layer else { return 0 }
        return mark(root)
    }

    /// 只碰 SwiftUI 自己画的层：别的层有的是直接塞的图片，标了重画反而会把图片清掉
    private static func mark(_ layer: CALayer) -> Int {
        var count = 0
        if NSStringFromClass(type(of: layer)).contains("CGDrawingLayer") {
            layer.setNeedsDisplay()
            count += 1
        }
        for sublayer in layer.sublayers ?? [] { count += mark(sublayer) }
        return count
    }
}
