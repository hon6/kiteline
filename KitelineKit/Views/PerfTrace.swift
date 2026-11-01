import Foundation
import QuartzCore

/// 只在调试版里、并且启动时带 TARS_PERF_TRACE=1 才工作：主线程一轮忙超过 30 ms（滑动时就是掉帧），
/// 把这一轮里做过的事（处理了哪个推送事件、各花多少毫秒、哪些页面重算了几次）打到控制台。
/// 真机经 Wi-Fi 时 Instruments 连不上，用 `xcrun devicectl device process launch --console` 收这些打印来查卡在哪
enum PerfTrace {
    #if DEBUG
    @MainActor static let enabled = ProcessInfo.processInfo.environment["TARS_PERF_TRACE"] == "1"
    @MainActor private static var trail: [String] = []
    @MainActor private static var bodies: [String: Int] = [:]
    @MainActor private static var observer: CFRunLoopObserver?
    #endif

    /// 记一件事（只有这一轮卡了才打印）
    @MainActor static func mark(_ text: @autoclosure () -> String) {
        #if DEBUG
        guard enabled else { return }
        trail.append(text())
        if trail.count > 60 { trail.removeFirst(trail.count - 60) }
        #endif
    }

    /// 量一段代码花了多久，超过 0.5 ms 才记
    @MainActor static func measure<T>(_ name: @autoclosure () -> String, _ work: () -> T) -> T {
        #if DEBUG
        guard enabled else { return work() }
        let start = CACurrentMediaTime()
        let result = work()
        let ms = (CACurrentMediaTime() - start) * 1000
        if ms > 0.5 { mark(String(format: "%@ %.1fms", name(), ms)) }
        return result
        #else
        return work()
        #endif
    }

    /// 某个页面的 body 又算了一次
    @MainActor static func body(_ name: String) {
        #if DEBUG
        guard enabled else { return }
        bodies[name, default: 0] += 1
        #endif
    }

    @MainActor static func start() {
        #if DEBUG
        guard enabled, observer == nil else { return }
        var wokeAt: CFTimeInterval = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, Int.max) { _, activity in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    wokeAt = now
                    trail.removeAll(keepingCapacity: true)
                    bodies.removeAll(keepingCapacity: true)
                } else if wokeAt > 0 {
                    let ms = (now - wokeAt) * 1000
                    if ms > 30 {
                        let counts = bodies.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                        print("[卡 \(Int(ms))ms] \(trail.joined(separator: " | "))  ‖ body: \(counts)")
                    }
                    wokeAt = 0
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        print("[PerfTrace] 开始记录")
        #endif
    }
}
