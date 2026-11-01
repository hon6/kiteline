import AppKit
import Network

/// macOS「本地网络」权限。没开时 Kiteline 连局域网里的任何设备都会失败：Remote-SSH 主机报「No route to host」，
/// 同一个 Wi-Fi 下的手机也连不进来（走中继的远程访问不受影响）。
/// 系统没有直接查询的接口：在局域网上找一下 Bonjour 服务，被拒时会明确报「策略拒绝」（PolicyDenied）。
/// 第一次查也会让系统弹出「允许 Kiteline 查找本地网络上的设备」
enum LocalNetwork {
    enum Status: String { case granted, denied, unknown }

    /// 最近一次查到的结果（主线程读写）
    private(set) static var status: Status = .unknown
    private static var browser: NWBrowser?
    private static var timer: Timer?

    /// 测试实例（自测、截图用）不碰局域网：不查权限、不宣告 Bonjour。拷出来改了 bundle id 的副本系统当成新 App，
    /// 一碰就弹「允许“TARS”查找本地网络中的设备」，每起一个副本弹一次（10-31 反馈为什么老弹 TARS 的授权框）；
    /// 宣告了还会让手机在局域网里搜到测试实例。要测本地网络时设 CCPULSE_LOCAL_NETWORK=1
    static var offInTestInstance: Bool {
        AppConfig.isolated && ProcessInfo.processInfo.environment["CCPULSE_LOCAL_NETWORK"] != "1"
    }

    /// 启动时查一次，之后每 30 秒查一次；变了写日志
    static func startMonitoring() {
        guard !offInTestInstance else { return }
        check()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in check() }
    }

    /// 查一次：被拒马上有结论；2 秒内没被拒就算有权限
    static func check(_ done: ((Status) -> Void)? = nil) {
        guard !offInTestInstance else { done?(status); return }
        browser?.cancel()
        let next = NWBrowser(for: .bonjour(type: "_tars._tcp", domain: nil), using: .tcp)
        browser = next
        var finished = false
        func finish(_ result: Status) {
            guard !finished else { return }
            finished = true
            next.cancel()
            if browser === next { browser = nil }
            if result != status {
                if result == .denied {
                    Log.write("没有「本地网络」权限：连不了局域网里的手机和 Remote-SSH 主机（系统设置 → 隐私与安全性 → 本地网络，打开 Kiteline）")
                } else if status == .denied {
                    Log.write("「本地网络」权限已打开")
                }
            }
            status = result
            done?(result)
        }
        next.stateUpdateHandler = { state in
            switch state {
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { finish(.denied) }
            default:
                break
            }
        }
        next.browseResultsChangedHandler = { results, _ in
            if !results.isEmpty { finish(.granted) }
        }
        next.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(.granted) }
    }

    /// 打开系统设置里的「本地网络」
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 连局域网主机失败的说明：没权限时直接说清楚，别只给一句「No route to host」
    static func explain(_ message: String) -> String {
        guard status == .denied, message.contains("No route to host") else { return message }
        return "Mac 未授予 Kiteline「本地网络」权限，无法连接局域网中的机器（系统设置 → 隐私与安全性 → 本地网络，开启 Kiteline）"
    }
}
