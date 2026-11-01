import CryptoKit
import Foundation

/// 网页推送（Web Push）：手机把网页 App 添加到主屏幕并允许通知后，
/// 即使 App 没打开，「需要你确认」「有结论了」也能推到锁屏。
///
/// 协议：RFC 8030（投递）、RFC 8291（aes128gcm 内容加密）、RFC 8292（VAPID 身份）。
/// iOS 16.4+ 支持，前提是网页走 HTTPS（本机证书或 Tailscale 的 https 地址）。
///
/// iPhone 上的 Kiteline App 也走这里：App 像浏览器一样生成一对密钥来订阅，地址写成 `apns:<环境>:<推送令牌>`。
/// 内容照样按 RFC 8291 加密，只是不发给浏览器的推送服务，而是交给 Kiteline 推送网关（relay/push/）转苹果推送服务；
/// 网关和苹果都只看到密文，App 的通知扩展解开后显示。
final class WebPush {
    struct Subscription: Codable, Equatable {
        var endpoint: String
        var p256dh: String
        var auth: String
        var createdAt: Double
        var label: String?
        /// 哪台已配对设备订阅的（停用设备时一起删）
        var deviceId: String?

        /// iPhone 上的 Kiteline App（apns:<环境>:<推送令牌>），不是网页
        var isApp: Bool { endpoint.hasPrefix("apns:") }

        /// 日志里显示的去处（不写推送令牌）
        var host: String { isApp ? "Kiteline App" : URL(string: endpoint)?.host ?? "?" }
    }

    private(set) var subscriptions: [Subscription] = []
    private let signingKey: P256.Signing.PrivateKey
    private let queue = DispatchQueue(label: "ccpulse.push")
    /// VAPID 的联系方式（推送服务出问题时联系谁）；Apple 要求是 mailto: 或 https:
    var contact = "mailto:ccpulse@users.noreply.github.com"

    /// Kiteline 推送网关（转苹果推送服务）；自测时用环境变量换成本机的假网关
    static var gateway: URL {
        URL(string: ProcessInfo.processInfo.environment["CCPULSE_APNS_GATEWAY"] ?? "https://tars.betac.cn/push")!
    }

    private static var keyURL: URL { AppConfig.directoryURL.appendingPathComponent("push-vapid.key") }
    private static var subscriptionsURL: URL { AppConfig.directoryURL.appendingPathComponent("push-subscriptions.json") }

    init() {
        if let data = try? Data(contentsOf: WebPush.keyURL),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            signingKey = key
        } else {
            signingKey = P256.Signing.PrivateKey()
            try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            try? signingKey.rawRepresentation.write(to: WebPush.keyURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: WebPush.keyURL.path)
        }
        if let data = try? Data(contentsOf: WebPush.subscriptionsURL),
           let list = try? JSONDecoder().decode([Subscription].self, from: data) {
            subscriptions = list
        }
    }

    /// 给浏览器 pushManager.subscribe 用的 applicationServerKey
    var publicKey: String { WebPush.base64URL(signingKey.publicKey.x963Representation) }

    // MARK: - 订阅

    func add(_ subscription: Subscription) {
        // 同一个订阅又报一次（iPhone App 每次连上都会对一下）：什么都不用做
        let known = queue.sync {
            subscriptions.contains { $0.endpoint == subscription.endpoint && $0.p256dh == subscription.p256dh
                && $0.auth == subscription.auth && $0.deviceId == subscription.deviceId }
        }
        if known { return }
        queue.sync {
            subscriptions.removeAll { $0.endpoint == subscription.endpoint }
            // iPhone App 换了推送令牌（重装、换环境）：这台设备之前的 App 订阅作废
            if subscription.isApp, let device = subscription.deviceId {
                subscriptions.removeAll { $0.isApp && $0.deviceId == device }
            }
            subscriptions.append(subscription)
            if let device = subscription.deviceId {
                let mine = subscriptions.filter { $0.deviceId == device }
                let drop = Set(mine.dropLast(WebPush.perDevice).map(\.endpoint))
                subscriptions.removeAll { drop.contains($0.endpoint) }
            }
            if subscriptions.count > WebPush.maxTotal { subscriptions.removeFirst(subscriptions.count - WebPush.maxTotal) }
            save()
        }
        Log.write("新增推送订阅（共 \(subscriptions.count) 个）：\(subscription.host)")
    }

    /// 一台设备最多留几个订阅、总共最多几个：别让一台设备塞进成百上千个地址，每条通知都要挨个发一遍
    static let perDevice = 3
    static let maxTotal = 64

    /// 订阅地址只收两种：iPhone App 的 apns:<环境>:<推送令牌>、浏览器推送服务的 https 地址。
    /// 已配对设备也不能让 Mac 往本机、内网地址发请求（SSRF）：不收 http、IP 地址、本机 / 局域网域名
    static func acceptable(endpoint: String, p256dh: String, auth: String) -> Bool {
        guard endpoint.utf8.count <= 2048,
              decodeBase64URL(p256dh)?.count == 65, decodeBase64URL(auth)?.count == 16 else { return false }
        if endpoint.hasPrefix("apns:") {
            let parts = endpoint.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return parts.count == 3 && ["production", "development"].contains(parts[1])
                && (1...200).contains(parts[2].count) && parts[2].allSatisfy(\.isHexDigit)
        }
        guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              var host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        // 最后一段是纯字母才算域名：挡掉 127.0.0.1、0x7f.1、[::1] 这类写法
        guard let tld = host.split(separator: ".").last, host.contains("."),
              tld.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return host != "localhost"
            && ![".localhost", ".local", ".internal", ".lan", ".home.arpa"].contains { host.hasSuffix($0) }
    }

    func remove(deviceId: String) {
        queue.sync {
            subscriptions.removeAll { $0.deviceId == deviceId }
            save()
        }
    }

    func remove(endpoint: String) {
        queue.sync {
            subscriptions.removeAll { $0.endpoint == endpoint }
            save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(subscriptions) {
            try? data.write(to: WebPush.subscriptionsURL, options: .atomic)
            // 里面有每个订阅的加密密钥（auth）：拿到就能冒充 Mac 给手机发通知，只许自己读
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: WebPush.subscriptionsURL.path)
        }
    }

    // MARK: - 发送

    /// 有推送订阅、而且不在 skip 里的设备（正开着 Kiteline 的设备不发系统推送）
    func deviceIds(except skip: Set<String>) -> Set<String> {
        Set(queue.sync { subscriptions }.compactMap(\.deviceId).filter { !skip.contains($0) })
    }

    /// 发给所有订阅（except 里的设备跳过）。payload 由网页里的 service worker 解析展示。
    /// only：只发这几台设备（英文设备单独发一份英文的；没登记设备的旧订阅不算在内）
    func send(_ payload: [String: Any], urgency: String = "high", except skip: Set<String> = [], only: Set<String>? = nil,
              completion: ((Int, [String]) -> Void)? = nil) {
        let targets = queue.sync { subscriptions }.filter { sub in
            if let only { return sub.deviceId.map(only.contains) ?? false }
            return sub.deviceId.map { !skip.contains($0) } ?? true
        }
        guard !targets.isEmpty, let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion?(0, []); return
        }
        let group = DispatchGroup()
        var delivered = 0
        var errors: [String] = []
        let lock = NSLock()
        for subscription in targets {
            group.enter()
            deliver(body, to: subscription, urgency: urgency) { [weak self] status, detail in
                lock.lock()
                if (200..<300).contains(status) {
                    delivered += 1
                } else {
                    errors.append("\(status) \(detail)")
                }
                lock.unlock()
                // 订阅已失效（App 被删、权限被关）：清掉。iPhone App 只认推送网关明确回的 410（苹果说令牌失效）：
                // 404 多半是网关没部署好、nginx 没转过去，删了订阅手机要等下次打开 App 才会重新订阅
                if status == 410 || (status == 404 && !subscription.isApp) {
                    self?.remove(endpoint: subscription.endpoint)
                    Log.write("推送订阅已失效，已移除：\(subscription.host)")
                } else if !(200..<300).contains(status) {
                    Log.write("推送失败 \(status)：\(detail.prefix(200))")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion?(delivered, errors) }
    }

    private func deliver(_ payload: Data, to subscription: Subscription, urgency: String,
                         completion: @escaping (Int, String) -> Void) {
        if subscription.isApp { deliverToApp(payload, to: subscription, urgency: urgency, completion: completion); return }
        guard let url = URL(string: subscription.endpoint),
              let p256dh = WebPush.decodeBase64URL(subscription.p256dh),
              let auth = WebPush.decodeBase64URL(subscription.auth) else {
            completion(410, "订阅数据损坏"); return
        }
        do {
            let body = try WebPush.encrypt(payload: payload, p256dh: p256dh, auth: auth)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 20
            request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("86400", forHTTPHeaderField: "TTL")
            request.setValue(urgency, forHTTPHeaderField: "Urgency")
            request.setValue(try vapidAuthorization(for: url), forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error { completion(0, error.localizedDescription); return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(status, data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            }.resume()
        } catch {
            completion(0, "加密失败：\(error)")
        }
    }

    /// iPhone App：加密好的内容交给推送网关。网关回 410 = 推送令牌失效（App 删了），调用方会删掉这个订阅
    private func deliverToApp(_ payload: Data, to subscription: Subscription, urgency: String,
                              completion: @escaping (Int, String) -> Void) {
        let parts = subscription.endpoint.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, ["production", "development"].contains(parts[1]), !parts[2].isEmpty,
              let p256dh = WebPush.decodeBase64URL(subscription.p256dh),
              let auth = WebPush.decodeBase64URL(subscription.auth) else {
            completion(410, "订阅数据损坏"); return
        }
        do {
            let body = try WebPush.encrypt(payload: payload, p256dh: p256dh, auth: auth)
            var request = URLRequest(url: WebPush.gateway)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "token": parts[2], "env": parts[1], "data": body.base64EncodedString(), "urgency": urgency, "ttl": 86400,
            ])
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error { completion(0, "推送网关：\(error.localizedDescription)"); return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                completion(status, reply?["error"] as? String ?? "")
            }.resume()
        } catch {
            completion(0, "加密失败：\(error)")
        }
    }

    // MARK: - VAPID（RFC 8292）

    func vapidAuthorization(for endpoint: URL, now: Date = Date()) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host else { throw RemoteError("推送地址不合法") }
        let audience = endpoint.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        let header = WebPush.base64URL(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8))
        let claims: [String: Any] = ["aud": audience, "exp": Int(now.timeIntervalSince1970) + 12 * 3600, "sub": contact]
        let claimsData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let input = "\(header).\(WebPush.base64URL(claimsData))"
        let signature = try signingKey.signature(for: Data(input.utf8))
        return "vapid t=\(input).\(WebPush.base64URL(signature.rawRepresentation)), k=\(publicKey)"
    }

    // MARK: - 内容加密（RFC 8291，aes128gcm）

    static func encrypt(payload: Data, p256dh: Data, auth: Data,
                        salt fixedSalt: Data? = nil,
                        ephemeral: P256.KeyAgreement.PrivateKey? = nil) throws -> Data {
        let userAgentKey = try P256.KeyAgreement.PublicKey(x963Representation: p256dh)
        let serverKey = ephemeral ?? P256.KeyAgreement.PrivateKey()
        let serverPublic = serverKey.publicKey.x963Representation
        let shared = try serverKey.sharedSecretFromKeyAgreement(with: userAgentKey)
        let ecdhSecret = shared.withUnsafeBytes { Data($0) }

        // IKM = HKDF(salt=auth, ikm=ecdh, info="WebPush: info\0" || ua_public || as_public, L=32)
        let prkKey = hmac(key: auth, data: ecdhSecret)
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(p256dh)
        keyInfo.append(serverPublic)
        keyInfo.append(1)
        let ikm = hmac(key: prkKey, data: keyInfo)

        let salt = fixedSalt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let prk = hmac(key: salt, data: ikm)
        let cek = hmac(key: prk, data: Data("Content-Encoding: aes128gcm".utf8) + Data([0, 1])).prefix(16)
        let nonce = hmac(key: prk, data: Data("Content-Encoding: nonce".utf8) + Data([0, 1])).prefix(12)

        var plaintext = payload
        plaintext.append(0x02)   // 最后一条记录的分隔符
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: cek), nonce: AES.GCM.Nonce(data: nonce))

        var body = Data()
        body.append(salt)
        var recordSize = UInt32(4096).bigEndian
        body.append(Data(bytes: &recordSize, count: 4))
        body.append(UInt8(serverPublic.count))
        body.append(serverPublic)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    // MARK: - base64url

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}
