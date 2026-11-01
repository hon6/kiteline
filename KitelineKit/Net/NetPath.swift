import Foundation
import Network

/// 手机现在走的网络：连着 Wi-Fi（或有线）才去试 Mac 的局域网地址；网络一变就通知重新探路
final class NetPath: @unchecked Sendable {
    static let shared = NetPath()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var lan = true
    private var signature = ""
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    /// 连着 Wi-Fi / 有线（只用流量时为 false）
    var onLAN: Bool { lock.withLock { lan } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: DispatchQueue(label: "tars.netpath"))
    }

    /// 网络变了（Wi-Fi ↔ 5G、开关 VPN）时叫一声；返回的令牌用来取消
    @discardableResult
    func onChange(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return id
    }

    func cancel(_ id: UUID) {
        lock.withLock { _ = handlers.removeValue(forKey: id) }
    }

    private func update(_ path: NWPath) {
        let lan = path.status == .satisfied && path.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
        // 同一张网上信号强弱也会报，只认接口真的变了
        let signature = "\(path.status)|" + path.availableInterfaces.map { "\($0.type)-\($0.name)" }.sorted().joined(separator: ",")
        let (first, changed, list): (Bool, Bool, [@Sendable () -> Void]) = lock.withLock {
            let first = self.signature.isEmpty
            let changed = !first && signature != self.signature
            self.signature = signature
            self.lan = lan
            return (first, changed, Array(handlers.values))
        }
        if first || changed { NetLog.note("path", ["status": "\(path.status)", "ifs": signature, "lan": lan]) }
        if changed { list.forEach { $0() } }
    }
}

/// 手机发往某个地址的包从哪张网卡出去：直接走 Wi-Fi / 有线，还是进了 VPN 隧道。
/// Tailscale、ZeroTier、WireGuard 这类组网在手机上都是 utun 隧道：在外面经它连家里的 192.168.x.x，地址看着像局域网，其实是远程访问。
/// 只查系统路由表（UDP 的 connect 不发包），不联网、很快
enum LocalRoute {
    /// 这几个地址里，手机直接经 Wi-Fi / 有线 / 个人热点（en*、bridge*）出去的；进隧道、走蜂窝的不算
    static func direct(_ urls: [URL]) -> [URL] {
        guard !urls.isEmpty else { return [] }
        let names = interfaceNames()
        return urls.filter { url in
            guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
            if host == "127.0.0.1" || host == "localhost" {
                #if targetEnvironment(simulator) || KITELINE_MAC
                return true   // 模拟器、Mac 主窗口连本机的服务
                #else
                return false   // 手机上的 127.0.0.1 只会是别的 App 开的转发
                #endif
            }
            if host.hasSuffix(".local") { return true }   // Bonjour 名字只在同一个局域网里解析得到
            guard let name = interface(toward: host, names) else { return false }
            return name.hasPrefix("en") || name.hasPrefix("bridge")
        }
    }

    /// 有没有哪个地址要经 VPN 隧道才到得了（给「经 VPN 连接属于远程访问」的提示用）
    static func tunneled(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let names = interfaceNames()
        return urls.contains { url in
            guard let host = url.host(percentEncoded: false)?.lowercased(),
                  let name = interface(toward: host, names) else { return false }
            return name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
        }
    }

    #if DEBUG || SNAPSHOT
    /// 调试：「10.168.1.190→en0 直连」这样一个个列出来，后面附上本机的隧道网卡地址（DebugRemote 的 route 命令用）
    static func explain(_ hosts: [String]) -> String {
        let names = interfaceNames()
        let lines = hosts.map { host -> String in
            let url = URL(string: host.contains(":") ? "https://[\(host)]" : "https://\(host)")!
            let kind = !direct([url]).isEmpty ? "直连" : tunneled([url]) ? "隧道" : "-"
            return "\(host)→\(interface(toward: host, names) ?? "nil") \(kind)"
        }
        let tunnels = names.filter { $0.value.hasPrefix("utun") || $0.value.hasPrefix("ipsec") }.map { "\($0.value)=\($0.key)" }.sorted()
        return lines.joined(separator: " | ") + " || 隧道网卡：" + tunnels.joined(separator: " ")
    }
    #endif

    /// 系统发往 host（IP）时用哪张网卡：UDP connect 让系统按路由表选好本机地址，再查这个地址属于哪张网卡
    private static func interface(toward host: String, _ names: [String: String]) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_DGRAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "9", &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(first) }
        let fd = socket(first.pointee.ai_family, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else { return nil }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let source: String? = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 ? numeric($0, length) : nil }
        }
        return source.flatMap { names[$0] }
    }

    /// 本机每个地址 → 网卡名（en0、utun3、pdp_ip0……）
    private static func interfaceNames() -> [String: String] {
        var names: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return names }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) || addr.pointee.sa_family == UInt8(AF_INET6),
                  let ip = numeric(addr, socklen_t(addr.pointee.sa_len)) else { continue }
            names[ip] = String(cString: entry.pointee.ifa_name)
        }
        return names
    }

    private static func numeric(_ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }
}
