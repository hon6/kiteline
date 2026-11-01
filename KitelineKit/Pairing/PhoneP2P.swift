import Foundation
import Observation
#if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import TarsP2P
#endif

/// Mac 给的远程访问信息：Mac 的点对点公钥、它用的中继、局域网直连地址
struct RemoteInfo: Codable, Equatable {
    var macId: String
    var relay: String
    var addrs: [String]
}

extension RemoteInfo {
    /// /api/p2p/join 的回应
    init?(_ reply: [String: Any]) {
        guard let id = reply["id"] as? String, !id.isEmpty else { return nil }
        self.init(macId: id, relay: reply["relay"] as? String ?? "", addrs: reply["addrs"] as? [String] ?? [])
    }
}

/// 远程访问（手机）：按 Mac 的公钥连过去——同一个 Wi-Fi 里走局域网直连，不在同一个 Wi-Fi 时能打洞直连就直连，打不通走中继，端到端加密。
/// 在手机本机开一个端口转发到 Mac，App 照常用 HTTPS 访问 127.0.0.1:端口（Mac 的证书里本来就有 127.0.0.1）。
/// 端口开一次就不变；p2p/ 里常驻一条到 Mac 的连接，换网络时在这条连接里换路（不断开），断了自己重连。
/// 内核是 p2p/（iroh）；模拟器、Mac 截图版里没有。
@MainActor
@Observable
final class PhoneP2P {
    static let shared = PhoneP2P()

    enum State: Equatable {
        case off
        case starting
        case ready(port: Int)
        case failed(String)
    }

    /// 常驻连接现在怎么样：连没连着、走的哪条路
    struct Link: Equatable {
        enum Path: String { case direct, relay, none = "" }
        var up = false
        var path = Path.none
        /// 直连时是 Mac 的地址（ip:端口），走中继时是中继地址
        var addr = ""
        /// 连续连不上几次了
        var fails = 0
        /// 中继连着没有（不管现在走不走它）
        var relayOnline = false

        /// 直连且对方是局域网地址：和 Mac 在同一个网里（addr 是「ip:端口」，IPv6 带方括号）
        var onLAN: Bool {
            guard up, path == .direct, let colon = addr.lastIndex(of: ":") else { return false }
            let host = addr[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return MacAPI.AddressKind.of(host: host) == .lan
        }
    }

    private(set) var state: State = .off
    /// 每秒读一次（App 在前台、远程访问开着时）
    private(set) var link = Link()
    /// 现在连的是哪台 Mac、哪个中继
    private var current: RemoteInfo?
    /// 端点是用哪个中继开的（换了中继要重开端点；只换 Mac 的地址不用）
    private var startedRelay: String?

    var localURL: URL? {
        if case .ready(let port) = state { return URL(string: "https://127.0.0.1:\(port)") }
        return nil
    }

    static var available: Bool {
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// 这台手机的点对点公钥（没有就生成密钥），配对时报给 Mac
    static func publicId() -> String? {
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        guard let p = tars_p2p_id(keyPath) else { return nil }
        defer { tars_p2p_free(p) }
        return String(cString: p)
        #else
        return nil
        #endif
    }

    /// 正在开的那一次：别处同时来要（App、诊断、手表）就等它的结果，不再各开一次、也不白白拿到 nil
    private var inflight: Task<URL?, Never>?

    /// 连上 Mac：返回 App 该用的地址（https://127.0.0.1:端口），失败返回 nil。
    /// 端点已经开着、中继没变时只换目标，端口不变、马上返回；上次失败了再调就重开，不用等 App 重启
    func connect(_ info: RemoteInfo) async -> URL? {
        if info == current, let url = localURL { return url }
        if let running = inflight {
            let url = await running.value
            if info == current, let url { return url }
            // 等的那次失败了、别人已经又开了一次：等那一次，不再并排开第三次
            if let next = inflight, next != running { return await next.value }
        }
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if localURL == nil { state = .starting }
        let restart = startedRelay != info.relay || localURL == nil
        current = info
        let key = Self.keyPath
        let task = Task { () -> URL? in
            let result = await Task.detached { () -> Result<Int, Failure> in
                if restart, let p = tars_p2p_start(key, info.relay) {
                    defer { tars_p2p_free(p) }
                    return .failure(Failure(String(cString: p)))
                }
                let port = tars_p2p_forward(info.macId, info.relay, info.addrs.joined(separator: ","))
                return port > 0 ? .success(Int(port)) : .failure(Failure(Self.lastError() ?? L("远程访问未能启动")))
            }.value
            switch result {
            case .success(let port):
                startedRelay = info.relay
                state = .ready(port: port)
                return localURL
            case .failure(let failure):
                state = .failed(failure.message)
                startedRelay = nil
                current = nil
                return nil
            }
        }
        inflight = task
        let url = await task.value
        if inflight == task { inflight = nil }
        return url
        #else
        return nil
        #endif
    }

    /// 回到前台（或在后台被手表叫醒）时调：App 被挂起期间 iOS 会回收监听端口（苹果 TN2277），
    /// 之后连本机端口直接被拒、到 Mac 的连接却还好好的，App 就只剩局域网可走。每次都关掉重开（一般还是同一个端口）
    func resume() {
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        guard case .ready(let port) = state else { return }
        let next = Int(tars_p2p_resume())
        if next > 0, next != port {
            NetLog.note("forward_port", ["from": port, "to": next])
            state = .ready(port: next)
        }
        #endif
    }

    /// 断开现在的连接马上重连（端口不变）：切到后台很久回来时，旧连接多半已被系统掐断，不等它超时
    func reconnect() {
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if localURL != nil { tars_p2p_reconnect() }
        #endif
    }

    /// 网络变了（Wi-Fi ↔ 5G、从后台回来）：让它重新探路；正连不上的马上重试
    func networkChanged() {
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if localURL != nil { tars_p2p_network_changed() }
        #endif
    }

    /// 读一次常驻连接的状态（设置里的线路灯、「当前使用」靠它）
    @discardableResult
    func refreshLink() -> Link {
        let next = Self.readLink()
        if next != link {
            if next.up != link.up || next.path != link.path || next.addr != link.addr {
                NetLog.note("link", ["up": next.up, "path": next.path.rawValue, "addr": next.addr, "fails": next.fails, "relay": next.relayOnline])
                NetLog.saveP2PLogs()
            }
            link = next
        }
        return next
    }

    /// 常驻连接的状态，任何线程都能调（MacAPI 选路时用）
    nonisolated static func readLink() -> Link {
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        var link = Link()
        if let object = json(tars_p2p_link()) {
            link.up = object["up"] as? Bool ?? false
            link.path = Link.Path(rawValue: object["path"] as? String ?? "") ?? .none
            link.addr = object["addr"] as? String ?? ""
            link.fails = object["fails"] as? Int ?? 0
        }
        if let status = json(tars_p2p_status()) { link.relayOnline = status["state"] as? String == "online" }
        return link
        #else
        return Link()
        #endif
    }

    /// 停掉（没订阅时不占中继），密钥留着，订阅了再开
    func stop() {
        guard state != .off else { return }
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        tars_p2p_stop()
        #endif
        state = .off
        current = nil
        startedRelay = nil
        link = Link()
    }

    /// 断开配对：停掉，换一把新密钥（旧公钥在 Mac 那边也作废了）
    func reset() {
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        tars_p2p_stop()
        #endif
        try? FileManager.default.removeItem(atPath: Self.keyPath)
        state = .off
        current = nil
        startedRelay = nil
        link = Link()
    }

    /// 点对点日志（诊断里「拷贝报告」带上）
    static var logs: String {
        #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        guard let p = tars_p2p_logs() else { return "" }
        defer { tars_p2p_free(p) }
        return String(cString: p)
        #else
        return ""
        #endif
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    #if canImport(TarsP2P) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
    nonisolated private static func json(_ p: UnsafeMutablePointer<CChar>?) -> [String: Any]? {
        guard let p else { return nil }
        defer { tars_p2p_free(p) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8))) as? [String: Any]
    }

    nonisolated private static func lastError() -> String? {
        json(tars_p2p_status())?["error"] as? String
    }
    #endif

    /// 密钥放 Application Support，不进 iCloud 备份：换手机恢复备份时不该冒充成这台
    nonisolated private static var keyPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("p2p", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir.appendingPathComponent("key").path
    }
}
