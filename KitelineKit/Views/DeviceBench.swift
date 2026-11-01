#if (DEBUG || DEVICEBENCH) && os(iOS) && !SNAPSHOT
import SwiftUI
import UIKit

/// 只在调试版（或带 -D DEVICEBENCH 编的正式配置）里：在真机上自动量对话页滑动卡不卡。
/// 从 Mac 上 `xcrun devicectl device process launch --environment-variables '{…}'` 启动：
///   TARS_DEVICE_BENCH=标签  TARS_BENCH_TITLE=会话标题  TARS_BENCH_PAGES=先加载几页更早的消息  TARS_BENCH_SPEED=点/秒
///   TARS_CHAT_MODE=plain（全画）/ opacity（远处透明，默认）/ gone（远处换占位）/ lazy（懒加载）
/// 打开会话、加载更早的消息、匀速上下滚，每段记下每帧间隔、主线程忙的时间、内存，写到 Documents/bench-标签.json 就退出。
/// 正常打开 App 时什么都不做
enum DeviceBench {
    enum Mode: String { case plain, opacity, gone, lazy }

    private static let env = ProcessInfo.processInfo.environment
    static let label = env["TARS_DEVICE_BENCH"]
    static var active: Bool { label != nil }
    static let title = env["TARS_BENCH_TITLE"]
    static let pages = Int(env["TARS_BENCH_PAGES"] ?? "") ?? 3
    static let speed = Double(env["TARS_BENCH_SPEED"] ?? "") ?? 2000
    static let mode = Mode(rawValue: env["TARS_CHAT_MODE"] ?? "") ?? .opacity
    /// 程序在滚时也冻住内容（同手指在滑），TARS_BENCH_FREEZE=0 时不冻
    static let freeze = env["TARS_BENCH_FREEZE"] != "0"
    @MainActor static var ready = false
    @MainActor static var scrolling = false
    static let idle = Notification.Name("TARSDeviceBenchIdle")
    @MainActor private static var started = false

    @MainActor static func start() {
        guard let label, !started else { return }
        started = true
        Task { await run(label) }
    }

    @MainActor private static func run(_ label: String) async {
        for _ in 0..<240 where !ready { try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .seconds(3))
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 100 { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).forEach(walk)
        var report: [String: Any] = ["label": label, "mode": mode.rawValue, "ready": ready, "freeze": freeze]
        #if DEBUG
        report["build"] = "debug"
        #else
        report["build"] = "release"
        #endif
        if let scroll = found.max(by: { $0.contentSize.height < $1.contentSize.height }) {
            report["contentHeight"] = Int(scroll.contentSize.height)
            report["memoryBeforeMB"] = footprintMB()
            scrolling = true
            var phases: [[String: Any]] = []
            for (name, up) in [(L("向上"), true), (L("向下"), false), (L("再向上"), true), (L("再向下"), false)] {
                phases.append(await Driver(scroll: scroll, up: up, speed: CGFloat(speed)).run(name: name))
                scrolling = false
                NotificationCenter.default.post(name: idle, object: nil)
                try? await Task.sleep(for: .milliseconds(800))
                scrolling = true
            }
            scrolling = false
            report["phases"] = phases
            report["memoryAfterMB"] = footprintMB()
        } else {
            report["error"] = L("没找到对话的滚动区")
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: folder.appendingPathComponent("bench-\(label).json"))
        }
        exit(0)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576).rounded() : -1
    }

    /// 按屏幕刷新匀速滚一段，记每帧间隔和主线程忙的时间
    @MainActor
    private final class Driver: NSObject {
        private let scroll: UIScrollView
        private let up: Bool
        private let speed: CGFloat
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private var gaps: [Double] = []
        private var started = Date()
        private var finished: CheckedContinuation<Void, Never>?

        init(scroll: UIScrollView, up: Bool, speed: CGFloat) {
            self.scroll = scroll
            self.up = up
            self.speed = speed
        }

        func run(name: String) async -> [String: Any] {
            started = Date()
            var busy: Double = 0
            var wokeAt: CFAbsoluteTime = 0
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                              true, 0) { _, activity in
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting { wokeAt = now } else if wokeAt > 0 { busy += now - wokeAt; wokeAt = 0 }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            await withCheckedContinuation { continuation in
                finished = continuation
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let frame: Double = 1.0 / Double(max(30, UIScreen.main.maximumFramesPerSecond))
            let total: Double = gaps.reduce(0, +)
            let hitches: [Double] = gaps.filter { $0 > frame * 1.5 }
            let sorted: [Double] = gaps.sorted()
            let late: Double = hitches.reduce(0) { $0 + $1 - frame }
            var report: [String: Any] = ["name": name, "frames": gaps.count, "seconds": (total * 100).rounded() / 100]
            report["fps"] = total > 0 ? (Double(gaps.count) / total).rounded() : 0
            report["hitchFrames"] = hitches.count
            report["hitchMsPerSecond"] = total > 0 ? (late * 10_000 / total).rounded() / 10 : 0
            report["worstFrameMs"] = ((sorted.last ?? 0) * 10_000).rounded() / 10
            report["p95FrameMs"] = sorted.isEmpty ? 0 : (sorted[Int(Double(sorted.count - 1) * 0.95)] * 10_000).rounded() / 10
            report["mainBusyMsPerFrame"] = gaps.isEmpty ? 0 : (busy * 10_000 / Double(gaps.count)).rounded() / 10
            return report
        }

        @objc private func tick(_ link: CADisplayLink) {
            let dt = last > 0 ? link.timestamp - last : 0
            if last > 0 { gaps.append(dt) }
            last = link.timestamp
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let target = up ? top : bottom
            var y = scroll.contentOffset.y + (up ? -1 : 1) * speed * CGFloat(dt)
            y = up ? max(y, target) : min(y, target)
            scroll.contentOffset = CGPoint(x: scroll.contentOffset.x, y: y)
            if abs(y - target) < 1 || Date().timeIntervalSince(started) > 40 {
                link.invalidate()
                self.link = nil
                finished?.resume()
                finished = nil
            }
        }
    }
}
#endif
