import Foundation

/// 和 Mac 上 Kiteline 说话的底层：一个 URLSession + 证书校验（见 TrustPolicy）
final class MacClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let ca: Data?
    private let expected: String?
    private let capturing: Bool
    private let lock = NSLock()
    private var capturedDER: Data?
    /// 已配对但当初没记下根证书（配对时系统已经信任了 Mac 的证书）：这次连上时补记下来，交给 MacStore 存
    var onRootCaptured: (@Sendable (Data) -> Void)?
    private var backfilled = false
    private var session: URLSession!

    /// 配对用：从握手里记下 Mac 的根证书（扫码链接带了指纹就必须对上）。
    /// timeout：经中继用验证码配对时要等 Mac 上点「允许」，放长
    init(expecting fingerprint: String?, timeout: TimeInterval = 8) {
        ca = nil
        expected = fingerprint
        capturing = true
        super.init()
        session = Self.makeSession(delegate: self, timeout: timeout)
    }

    /// 已配对：只认配对时记下的根证书。timeout 是两次收到数据之间最多等多久（实时事件流要长一些）
    init(mac: PairedMac, timeout: TimeInterval = 10) {
        ca = mac.caCertificate
        expected = nil
        capturing = false
        super.init()
        session = Self.makeSession(delegate: self, timeout: timeout, demo: Self.isDemo(mac))
    }

    private static func isDemo(_ mac: PairedMac) -> Bool {
        #if KITELINE_MAC
        return false
        #else
        return Demo.isDemo(mac)
        #endif
    }

    var captured: Data? { lock.withLock { capturedDER } }

    private static func makeSession(delegate: URLSessionDelegate, timeout: TimeInterval, demo: Bool = false) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        #if !KITELINE_MAC
        // 演示模式：请求不出手机，由 DemoServer 应答
        if demo { config.protocolClasses = [DemoProtocol.self] }
        #endif
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }

    /// 原样返回网络错误（URLError），由调用方决定换地址还是报错
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    func bytes(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (bytes, http)
    }

    /// 配对时用：一次请求，错误翻成人话
    func json(_ url: URL, method: String = "GET", token: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
        let request = try MacClient.request(url, method: method, token: token, body: body)
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await send(request)
        } catch {
            throw Self.explain(error, host: url.host ?? L("电脑"))
        }
        return try APIError.check(data, http)
    }

    /// 形如「ios/1.1 (iPhone13,2; iOS 18.7.8)」；模拟器报它模拟的机型
    static let clientInfo: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        #if KITELINE_MAC || targetEnvironment(macCatalyst)
        return "mac/\(app) (\(model); macOS \(version))"
        #else
        return "ios/\(app) (\(model); iOS \(version))"
        #endif
    }()

    static func request(_ url: URL, method: String = "GET", token: String?, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue(token, forHTTPHeaderField: "X-CCP-Token") }
        // 这台设备的界面语言（zh / en）：电脑生成的提醒、日报、出错原因、就绪检查按它出
        request.setValue(Lang.shared.code, forHTTPHeaderField: "X-Kiteline-Lang")
        // 这台设备的机型、系统、App 版本：电脑的「设备」页和使用统计用
        request.setValue(clientInfo, forHTTPHeaderField: "X-Kiteline-Client")
        #if !KITELINE_MAC
        // 订阅了没有：电脑的使用统计里看谁是付费用户
        if let pro = ProGate.reported { request.setValue(pro ? "1" : "0", forHTTPHeaderField: "X-Kiteline-Pro") }
        #endif
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func explain(_ error: Error, host: String) -> Error {
        guard let error = error as? URLError else { return error }
        // 地址、主机名（字母数字）照中文排版习惯和汉字之间空一格；传进来的是「电脑」这种中文词就不空
        let gap = host.unicodeScalars.contains { $0.isASCII && CharacterSet.alphanumerics.contains($0) } ? " " : ""
        // 127.0.0.1 是远程访问在手机本机开的转发：断在这里多半是 Mac 那头不收（停用了这台手机、没开机、没开远程访问）
        if host == "127.0.0.1" {
            return PairingError(L("无法远程连接电脑：电脑可能未开机、未开启远程访问，或已在电脑上停用此手机。"))
        }
        switch error.code {
        case .cancelled, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            return PairingError(L("%@%@的证书不匹配：扫描的可能不是这台电脑的二维码，或电脑已重置证书。", "\(host)", "\(gap)"))
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
            return PairingError(L("无法连接%@%@。首次配对时，手机与电脑需连接同一 Wi-Fi，且电脑上的 Kiteline 需保持运行；", "\(gap)", "\(host)")
                                + L("若此前未允许 Kiteline 访问本地网络，请前往 iPhone「设置 → Kiteline」开启「本地网络」。"))
        default:
            return PairingError(L("无法连接%@%@：%@", "\(gap)", "\(host)", "\(error.localizedDescription)"))
        }
    }

    // 证书校验要两处都接：普通请求走会话级的回调，流式请求（bytes(for:)，实时事件用的）只走任务级的
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        decide(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        decide(challenge)
    }

    private func decide(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let host = challenge.protectionSpace.host
        // 配对：不管系统信不信任，都先把 Mac 的根证书记下来（扫码链接带了指纹就必须对上）。
        // 手机装过网页版的描述文件时系统已经信任它，以前就没记——之后描述文件一删，App 就连不上 Mac 了
        if capturing, captured == nil {
            let trusted = TrustPolicy.accept(trust, host: host, ca: nil)   // 顺带把证书链建出来
            guard let der = TrustPolicy.capture(trust, expected: expected),
                  trusted || TrustPolicy.accept(trust, host: host, ca: der) else { return (.cancelAuthenticationChallenge, nil) }
            lock.withLock { capturedDER = der }
            return (.useCredential, URLCredential(trust: trust))
        }
        guard TrustPolicy.accept(trust, host: host, ca: ca ?? captured) else { return (.cancelAuthenticationChallenge, nil) }
        // 老配对没记根证书、这次靠系统信任连上的：补记一份，以后系统不信了（删了描述文件）也认得这台 Mac
        if ca == nil, !capturing, let onRootCaptured, let der = TrustPolicy.capture(trust, expected: nil) {
            let first: Bool = lock.withLock {
                defer { backfilled = true }
                return !backfilled
            }
            if first { onRootCaptured(der) }
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Mac 回的错误：message 是给人看的；data 是整个回应（比如 capExceeded 要据此问一句「仍然发送吗」）
struct APIError: LocalizedError {
    var message: String
    var status: Int
    var data: [String: Any] = [:]

    var errorDescription: String? { message }
    var unauthorized: Bool { status == 401 }

    static func check(_ data: Data, _ http: HTTPURLResponse) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 401 {
            throw APIError(message: L("电脑已不再信任此手机：可能已在电脑上停用，或配对已重置。请重新扫码配对。"), status: 401, data: object)
        }
        if http.statusCode >= 400 || object["ok"] as? Bool == false {
            let text = object["error"] as? String ?? object["message"] as? String ?? L("电脑返回错误（%@）", "\(http.statusCode)")
            throw APIError(message: text, status: http.statusCode, data: object)
        }
        return object
    }
}
