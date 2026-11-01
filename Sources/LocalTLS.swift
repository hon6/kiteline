import CryptoKit
import Foundation
import Security

/// 本机 HTTPS：iOS 的网页推送与 Service Worker 只在 HTTPS 下可用。
///
/// 做法：首次启动生成一张本机专用的根证书（CA），再用它签一张包含本机所有 IP 与 .local 名的
/// 服务器证书。手机装一次根证书描述文件并「完全信任」后，https://<Mac 的 IP>:8766 就是受信任的。
/// IP 变了只重签服务器证书，根证书不变，手机不用重装。
///
/// 证书用系统自带的 /usr/bin/openssl（LibreSSL）生成，不引入第三方依赖。
/// iOS 对用户信任的根证书签发的服务器证书有要求：RSA ≥ 2048、SHA-256、有效期 ≤ 825 天、
/// 必须带 SAN 与 serverAuth。
enum LocalTLS {
    static var directory: URL { AppConfig.directoryURL.appendingPathComponent("tls", isDirectory: true) }
    private static var caKey: URL { directory.appendingPathComponent("ca.key") }
    private static var caCert: URL { directory.appendingPathComponent("ca.pem") }
    private static var leafKey: URL { directory.appendingPathComponent("server.key") }
    private static var leafCert: URL { directory.appendingPathComponent("server.pem") }
    private static var leafP12: URL { directory.appendingPathComponent("server.p12") }
    private static var leafSANs: URL { directory.appendingPathComponent("server.sans") }
    private static let p12Password = "ccpulse"

    /// 确保证书齐全（必要时重签），返回可用于 TLS 的身份
    static func identity(ips: [String], names: [String]) -> SecIdentity? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ensureCA()
            try ensureLeaf(ips: ips, names: names)
            return try loadIdentity()
        } catch {
            Log.write("本机 HTTPS 证书准备失败：\(error)")
            return nil
        }
    }

    /// 根证书（DER），给手机装描述文件用
    static var caDER: Data? {
        guard let pem = try? String(contentsOf: caCert, encoding: .utf8) else { return nil }
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)
    }

    static var caCertificate: SecCertificate? {
        caDER.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    /// 根证书指纹（SHA-256 十六进制）：写进配对二维码，Kiteline iOS App 据此确认连的确实是这台 Mac
    static var caFingerprint: String? {
        caDER.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    /// 根证书在 iPhone「证书信任设置」里显示的名字（就是证书本身的名字，老版本生成的叫 CC Pulse Local CA）
    static var caName: String? {
        guard let der = caDER, let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return SecCertificateCopySubjectSummary(cert) as String?
    }

    /// 新生成的根证书带名称约束：只能给私网 / Tailscale / 本机的 IP 和 .local、localhost 这类名字签证书。
    /// 网页版要在手机上装描述文件、完全信任这张根证书：万一这台 Mac 上的根证书私钥泄露，也冒充不了外面的网站（银行、邮箱……）。
    /// iOS / macOS 的证书校验认这个约束（2026-10-22 实测：私网地址的证书通过，evil.com、8.8.8.8 的被拒）。
    /// 以前生成的根证书没有约束，照常用（换掉它所有配过的手机都要重新配对）
    private static let nameConstraints = ["IP:10.0.0.0/255.0.0.0", "IP:172.16.0.0/255.240.0.0", "IP:192.168.0.0/255.255.0.0",
                                          "IP:100.64.0.0/255.192.0.0", "IP:127.0.0.0/255.0.0.0",
                                          "DNS:local", "DNS:localhost", "DNS:ts.net", "DNS:home.arpa"]
        .map { "permitted;" + $0 }.joined(separator: ", ")

    /// 根证书带不带名称约束（带的话，服务器证书里只能签约束范围内的地址：有一个超出，整张证书都会被拒）
    private static var caConstrained: Bool {
        (try? String(contentsOf: directory.appendingPathComponent("ca.cnf"), encoding: .utf8))?.contains("nameConstraints") ?? false
    }

    /// 地址 / 名字在不在名称约束允许的范围里
    static func permitted(ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
            || (p[0] == 100 && (64...127).contains(p[1]))
    }

    static func permitted(name: String) -> Bool {
        let n = name.lowercased()
        return n == "localhost" || ["local", "ts.net", "home.arpa"].contains { n == $0 || n.hasSuffix("." + $0) }
    }

    private static func ensureCA() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: caKey.path), fm.fileExists(atPath: caCert.path) { return }
        let host = (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "/", with: "-")
        let config = directory.appendingPathComponent("ca.cnf")
        try """
        [req]
        distinguished_name = dn
        prompt = no
        x509_extensions = v3_ca
        [dn]
        CN = Kiteline Local CA (\(host))
        O = Kiteline
        [v3_ca]
        basicConstraints = critical, CA:TRUE, pathlen:0
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        nameConstraints = critical, \(nameConstraints)
        """.write(to: config, atomically: true, encoding: .utf8)
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                 "-keyout", caKey.path, "-out", caCert.path, "-config", config.path])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
        try? fm.removeItem(at: leafSANs)   // 新 CA 必须重签服务器证书
        Log.write("已生成本机根证书")
    }

    private static func ensureLeaf(ips: [String], names: [String]) throws {
        var ips = ips, names = names
        if caConstrained {
            ips = ips.filter { permitted(ip: $0) }
            names = names.filter { permitted(name: $0) }
        }
        let sans = (ips.sorted().map { "IP:\($0)" } + names.sorted().map { "DNS:\($0)" }).joined(separator: ",")
        let fm = FileManager.default
        if fm.fileExists(atPath: leafP12.path),
           (try? String(contentsOf: leafSANs, encoding: .utf8)) == sans,
           let attrs = try? fm.attributesOfItem(atPath: leafP12.path),
           let created = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(created) < 700 * 86400 {
            return
        }
        let ext = directory.appendingPathComponent("server.ext")
        try """
        [v3]
        basicConstraints = CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(sans)
        """.write(to: ext, atomically: true, encoding: .utf8)
        let csr = directory.appendingPathComponent("server.csr")
        try run(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-keyout", leafKey.path,
                 "-out", csr.path, "-subj", "/CN=Kiteline/O=Kiteline"])
        try run(["x509", "-req", "-in", csr.path, "-CA", caCert.path, "-CAkey", caKey.path,
                 "-CAcreateserial", "-out", leafCert.path, "-days", "800", "-sha256",
                 "-extfile", ext.path, "-extensions", "v3"])
        try? fm.removeItem(at: leafP12)
        try run(["pkcs12", "-export", "-inkey", leafKey.path, "-in", leafCert.path, "-certfile", caCert.path,
                 "-out", leafP12.path, "-passout", "pass:\(p12Password)", "-name", "TARS"])
        try sans.write(to: leafSANs, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: leafKey.path)
        Log.write("已签发本机 HTTPS 证书：\(sans)")
    }

    private static func loadIdentity() throws -> SecIdentity {
        let data = try Data(contentsOf: leafP12)
        var options: [String: Any] = [kSecImportExportPassphrase as String: p12Password]
        if #available(macOS 15.0, *) {
            // 只在内存里用，不往用户钥匙串里塞东西
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let list = items as? [[String: Any]],
              let first = list.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw RemoteError("证书导入失败（OSStatus \(status)）")
        }
        return identity as! SecIdentity
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw RemoteError("openssl \(arguments.first ?? "") 失败：\(detail.suffix(300))")
        }
    }

    /// iOS 描述文件：装上后到「设置 → 通用 → 关于本机 → 证书信任设置」里打开完全信任
    static func mobileconfig() -> Data? {
        guard let der = caDER else { return nil }
        let host = Host.current().localizedName ?? "Mac"
        // 标识符要稳定：同一张根证书重复安装时 iOS 会当成更新而不是新增
        let stable = SHA256.hash(data: der).prefix(6).map { String(format: "%02x", $0) }.joined()
        let plist: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "local.ccpulse.ca.\(stable)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Kiteline 本机证书（\(host)）",
            "PayloadDescription": "使手机信任 \(host) 上 Kiteline 的 HTTPS 地址，用于接收推送通知。",
            "PayloadContent": [[
                "PayloadType": "com.apple.security.root",
                "PayloadVersion": 1,
                "PayloadIdentifier": "local.ccpulse.ca.cert.\(stable)",
                "PayloadUUID": UUID().uuidString,
                "PayloadDisplayName": "Kiteline Local CA",
                "PayloadContent": der,
            ]],
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
