#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// 只在调试版里：对话页每滑一次（手指按下到滑动停下），记下每帧间隔、主线程忙的时间、内存，
/// 追加一行到 App 的 Documents/scroll-perf.jsonl。真机经 Wi-Fi 连着时 Instruments 录不了，
/// 用 `xcrun devicectl device copy from … --source Documents/scroll-perf.jsonl` 取回来看卡在哪（上架版没有这段代码）
@MainActor
final class ScrollPerf: NSObject {
    static let shared = ScrollPerf()

    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var busy: Double = 0
    private var wokeAt: CFAbsoluteTime = 0
    private var rows = 0
    private var startedAt = Date()

    func begin(rows: Int) {
        guard link == nil else { return }
        self.rows = rows
        gaps.removeAll(keepingCapacity: true)
        busy = 0
        last = 0
        startedAt = Date()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting { self.wokeAt = now } else if self.wokeAt > 0 { self.busy += now - self.wokeAt; self.wokeAt = 0 }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func end() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        guard gaps.count >= 10 else { return }
        let frame = 1.0 / Double(max(30, UIScreen.main.maximumFramesPerSecond))
        let total = gaps.reduce(0, +)
        let hitches = gaps.filter { $0 > frame * 1.5 }
        let sorted = gaps.sorted()
        var record: [String: Any] = ["at": ISO8601DateFormatter().string(from: startedAt), "rows": rows, "frames": gaps.count]
        record["seconds"] = (total * 100).rounded() / 100
        record["hitchFrames"] = hitches.count
        record["hitchMsPerSecond"] = ((hitches.reduce(0) { $0 + $1 - frame }) * 10_000 / total).rounded() / 10
        record["worstFrameMs"] = ((sorted.last ?? 0) * 10_000).rounded() / 10
        record["p95FrameMs"] = (sorted[Int(Double(sorted.count - 1) * 0.95)] * 10_000).rounded() / 10
        record["mainBusyMsPerFrame"] = (busy * 10_000 / Double(gaps.count)).rounded() / 10
        record["hitchesMs"] = hitches.prefix(40).map { ($0 * 1000).rounded() }
        record["memoryMB"] = Self.footprintMB()
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = folder.appendingPathComponent("scroll-perf.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }

    /// 比屏幕宽的行（会把整页撑宽、能左右拖）：行的种类、id、宽度追加到 Documents/wide-rows.jsonl，每行只记一次
    private var wideSeen: Set<String> = []
    func noteWidth(_ row: ChatRow, _ width: CGFloat) {
        let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.width ?? 0
        guard screen > 0, width > screen + 0.5, !wideSeen.contains(row.id) else { return }
        wideSeen.insert(row.id)
        let kind = String(String(describing: row).prefix(600))
        let record: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "id": row.id, "width": Int(width), "screen": Int(screen), "row": kind]
        Self.append(record, to: "wide-rows.jsonl")
    }

    /// 钉宽之前整列消息的宽（ChatView 里量）
    var stackWidth: CGFloat = 0
    /// 对话页底下的系统滚动区（VerticalOnlyScroll 找到的）
    weak var chatScroll: UIScrollView?
    private var scrollWidthSeen: Set<String> = []

    /// 对话页的滚动区比可视区宽、或者横向挪开了：记到 wide-rows.jsonl（同一种情况只记一次）
    func noteScrollWidth(content: CGFloat, container: CGFloat, offsetX: CGFloat) {
        guard container > 0, content > container + 0.5 || abs(offsetX) > 0.5 else { return }
        let key = "\(Int(content))|\(Int(container))|\(abs(offsetX) > 0.5)"
        guard !scrollWidthSeen.contains(key) else { return }
        scrollWidthSeen.insert(key)
        var record: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "kind": "scroll", "contentWidth": Double(content),
                                     "containerWidth": Double(container), "offsetX": Double(offsetX), "stackWidth": Double(stackWidth)]
        // 底下系统滚动区此刻的实际设置（VerticalOnlyScroll 关了横向回弹以后还会不会动）
        if let scroll = chatScroll {
            record["uikitContentWidth"] = Double(scroll.contentSize.width)
            record["uikitBoundsWidth"] = Double(scroll.bounds.width)
            record["uikitOffsetX"] = Double(scroll.contentOffset.x)
            record["uikitInsetLeft"] = Double(scroll.adjustedContentInset.left)
            record["alwaysBounceHorizontal"] = scroll.alwaysBounceHorizontal
            if #available(iOS 17.4, *) { record["bouncesHorizontally"] = scroll.bouncesHorizontally }
            record["directionalLock"] = scroll.isDirectionalLockEnabled
        }
        Self.append(record, to: "wide-rows.jsonl")
    }

    static func append(_ record: [String: Any], to name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { gaps.append(link.timestamp - last) }
        last = link.timestamp
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576).rounded() : -1
    }
}
#endif
