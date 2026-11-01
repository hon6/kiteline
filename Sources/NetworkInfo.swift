import Foundation
import SystemConfiguration

/// 本机的网络地址：给配对二维码和 HTTPS 证书用
struct NetworkInfo {
    var tailscale: [String] = []
    var lan: [String] = []
    /// Bonjour 名称（xxx.local），手机在同一局域网里可以直接解析
    var names: [String] = []

    var allIPs: [String] { tailscale + lan }

    static func current() -> NetworkInfo {
        var info = NetworkInfo()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
                let flags = Int32(entry.pointee.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                let parts = ip.split(separator: ".").compactMap { Int($0) }
                guard parts.count == 4 else { continue }
                if parts[0] == 100 && (64...127).contains(parts[1]) {
                    info.tailscale.append(ip)       // 100.64.0.0/10：Tailscale / CGNAT
                } else if parts[0] != 169 {
                    info.lan.append(ip)             // 跳过 169.254 自分配地址
                }
            }
            freeifaddrs(first)
        }
        info.tailscale = Array(Set(info.tailscale)).sorted()
        info.lan = Array(Set(info.lan)).sorted()
        // 直接读本机 Bonjour 名称（不走 DNS，不会卡住）
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty {
            info.names = ["\(local).local"]
        }
        return info
    }
}
