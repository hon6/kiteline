import CryptoKit
import Foundation
import Network

/// 微信小程序的入口：加密隧道。小程序连不了本机的自签 HTTPS，也跑不了点对点库，所以单开一条路：
///   局域网里小程序直连这个 WebSocket 端口（手机服务端口 + 3，默认 8768）；远程时经中继转发（MPRelayLink，见 MPGate+Relay）。
///   握手：双方临时 X25519 + 长期密钥三次 DH → HKDF 出两个方向的 ChaCha20-Poly1305 密钥，之后每帧都是密文。
///   小程序发来的请求原样交给 MobileServer.route（和 HTTPS 进来的同一套鉴权、同一套接口），回复加密送回。
/// 协议和 miniprogram/lib/tunnel.js、desktop/kiteline/mpgate.py 一一对应，见 docs/features/miniprogram.md「加密隧道」。
/// 设备令牌和小程序的长期公钥绑定（mp-bind.json）：经这里来的请求，令牌必须是这把公钥配对时拿到的。
final class MPGate {
    static let proto = Data("kiteline-mp-1".utf8)
    /// 不要设备令牌也能走的路径：配对用
    static let openPaths: Set<String> = ["/pair", "/api/ping", "/api/info", "/api/devices/register"]
    /// 远程（经中继）用小程序：远程访问一律要 Kiteline Pro，小程序还没有开通 Pro 的办法，先关着。测试经中继时设 CCPULSE_MP_REMOTE=1
    static var remoteAllowed: Bool { ProcessInfo.processInfo.environment["CCPULSE_MP_REMOTE"] == "1" }
    static let remoteRefused = "小程序目前只支持手机和电脑在同一个 Wi-Fi 下使用（远程访问属于 Kiteline Pro）"

    let keys = MPKeys()
    let queue = DispatchQueue(label: "kiteline.mpgate")
    private var listener: NWListener?
    /// MobileServer.route
    let route: (HTTPRequest, @escaping (HTTPServer.Reply) -> Void) -> Void
    let hostName: () -> String
    private(set) var status = "未启动"
    private(set) var port: UInt16 = 0
    /// 远程（经中继）；开着远程访问时才有
    var relay: MPRelayLink?

    init(route: @escaping (HTTPRequest, @escaping (HTTPServer.Reply) -> Void) -> Void, hostName: @escaping () -> String) {
        self.route = route
        self.hostName = hostName
    }

    // MARK: 局域网监听

    func start(host: String, port: UInt16) throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 48 * 1024 * 1024
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener: NWListener
        if ["0.0.0.0", "::", ""].contains(host) {
            listener = try NWListener(using: params, on: nwPort)
        } else {
            // 只听某个地址（比如 127.0.0.1）：地址和端口都放在 requiredLocalEndpoint 里，再传端口会报参数无效
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
            listener = try NWListener(using: params)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.status = "启动失败：\(error)"
                Log.write("小程序入口出错：\(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        self.port = port
        status = "监听中 \(host):\(port)"
        Log.write("小程序入口监听 \(host):\(port)（编号 \(keys.id)）")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        relay?.stop()
        relay = nil
        status = "已停止"
    }

    private func accept(_ connection: NWConnection) {
        var remote = "?"
        if case .hostPort(let host, _) = connection.endpoint {
            remote = "\(host)".replacingOccurrences(of: "::ffff:", with: "")
            if let percent = remote.firstIndex(of: "%") { remote = String(remote[..<percent]) }
        }
        let session = MPSession(gate: self, remote: remote, via: "lan",
                                sendBinary: { data in MPGate.send(connection, data, opcode: .binary) },
                                sendText: { text in MPGate.send(connection, Data(text.utf8), opcode: .text) })
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: session.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, session)
    }

    private func receive(_ connection: NWConnection, _ session: MPSession) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil { connection.cancel(); return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            var ok = true
            switch meta?.opcode {
            case .text?: ok = session.onText(String(decoding: content ?? Data(), as: UTF8.self))
            case .binary?: ok = session.onBinary(content ?? Data())
            case .close?: ok = false
            default: break
            }
            if !ok { connection.cancel(); return }
            self.receive(connection, session)
        }
    }

    static func send(_ connection: NWConnection, _ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let meta = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: opcode == .text ? "text" : "binary", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    // MARK: 加解密（和 tunnel.js 的 deriveKeys / seal / open 一样）

    /// 电脑这边：返回（发送密钥, 接收密钥）
    static func deriveKeys(ce: Data, he: Data, cs: Data, hs: Data,
                           ephemeral: Curve25519.KeyAgreement.PrivateKey, statik: Curve25519.KeyAgreement.PrivateKey) throws -> (send: SymmetricKey, recv: SymmetricKey) {
        func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pub: Data) throws -> Data {
            try priv.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)).withUnsafeBytes { Data($0) }
        }
        let ikm = try dh(statik, ce) + dh(ephemeral, cs) + dh(ephemeral, ce)
        let salt = Data(SHA256.hash(data: proto + ce + he + cs + hs))
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: proto + Data(" keys".utf8), outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.suffix(32)), SymmetricKey(data: bytes.prefix(32)))
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)   // 12 字节，不会失败
    }

    static func seal(_ key: SymmetricKey, _ counter: UInt64, _ header: [String: Any], _ body: Data = Data()) -> Data? {
        guard let head = try? JSONSerialization.data(withJSONObject: header) else { return nil }
        var length = UInt32(head.count).bigEndian
        let plain = Data(bytes: &length, count: 4) + head + body
        guard let box = try? ChaChaPoly.seal(plain, using: key, nonce: nonce(counter)) else { return nil }
        return box.ciphertext + box.tag
    }

    static func open(_ key: SymmetricKey, _ counter: UInt64, _ data: Data) -> (header: [String: Any], body: Data)? {
        guard data.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: data.dropLast(16), tag: data.suffix(16)),
              let plain = try? ChaChaPoly.open(box, using: key), plain.count >= 4 else { return nil }
        let length = Int(plain.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard plain.count >= 4 + length,
              let header = (try? JSONSerialization.jsonObject(with: plain.dropFirst(4).prefix(length))) as? [String: Any] else { return nil }
        return (header, Data(plain.dropFirst(4 + length)))
    }

    static func hostId(_ pub: Data) -> String {
        Data(SHA256.hash(data: pub).prefix(12)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// 电脑的小程序长期密钥（mp.key）和设备令牌 ↔ 小程序公钥的绑定（mp-bind.json），都在配置目录、只有自己能读
final class MPKeys {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var publicKey: Data { privateKey.publicKey.rawRepresentation }
    var id: String { MPGate.hostId(publicKey) }
    /// 给二维码用：base64url 不带 =
    var publicB64URL: String {
        publicKey.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private let lock = NSLock()
    private var bindings: [String: String]
    private let keyURL = AppConfig.directoryURL.appendingPathComponent("mp.key")
    private let bindURL = AppConfig.directoryURL.appendingPathComponent("mp-bind.json")

    init() {
        if let raw = try? Data(contentsOf: keyURL), raw.count == 32, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            privateKey = key
        } else {
            privateKey = Curve25519.KeyAgreement.PrivateKey()
            MPKeys.writePrivate(keyURL, privateKey.rawRepresentation)
        }
        bindings = ((try? Data(contentsOf: bindURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]) ?? [:]
    }

    private static func writePrivate(_ url: URL, _ data: Data) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    func boundKey(_ token: String) -> String? { lock.withLock { bindings[MPKeys.hash(token)] } }

    func bind(_ token: String, _ clientKey: Data) {
        let snapshot: [String: String] = lock.withLock {
            bindings[MPKeys.hash(token)] = clientKey.map { String(format: "%02x", $0) }.joined()
            return bindings
        }
        if let data = try? JSONSerialization.data(withJSONObject: snapshot) { MPKeys.writePrivate(bindURL, data) }
    }
}

/// 一条加密会话：局域网的一条 WebSocket，或中继转来的一个客户端。remote 经中继时是 127.0.0.1（和 iPhone 走中继一样：配对码要在电脑上确认）
final class MPSession {
    private unowned let gate: MPGate
    let remote: String
    let via: String
    private let sendBinary: (Data) -> Void
    private let sendText: (String) -> Void
    private var keys: (send: SymmetricKey, recv: SymmetricKey)?
    private var clientKey = Data()
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0
    private let lock = NSLock()
    private var streams: [Int: HTTPStream] = [:]
    private var closed = false

    init(gate: MPGate, remote: String, via: String, sendBinary: @escaping (Data) -> Void, sendText: @escaping (String) -> Void) {
        self.gate = gate
        self.remote = remote
        self.via = via
        self.sendBinary = sendBinary
        self.sendText = sendText
    }

    private static func unb64(_ text: String?) -> Data? {
        guard var t = text?.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") else { return nil }
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    private func error(_ message: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["t": "error", "msg": message]) { sendText(String(decoding: data, as: UTF8.self)) }
    }

    /// 握手（明文的第一帧）。返回 false = 断开
    func onText(_ text: String) -> Bool {
        guard keys == nil else { return true }
        guard let hello = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], hello["t"] as? String == "hello",
              let ce = MPSession.unb64(hello["e"] as? String), let cs = MPSession.unb64(hello["s"] as? String), ce.count == 32, cs.count == 32 else {
            error("握手无效"); return false
        }
        if via == "relay", !MPGate.remoteAllowed { error(MPGate.remoteRefused); return false }
        guard hello["v"] as? Int == 1 else { error("小程序版本过旧，请更新"); return false }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let he = ephemeral.publicKey.rawRepresentation
        guard let derived = try? MPGate.deriveKeys(ce: ce, he: he, cs: cs, hs: gate.keys.publicKey, ephemeral: ephemeral, statik: gate.keys.privateKey) else {
            error("握手无效"); return false
        }
        keys = derived
        clientKey = cs
        let reply: [String: Any] = ["t": "hello", "v": 1, "e": he.base64EncodedString(), "s": gate.keys.publicKey.base64EncodedString(), "name": gate.hostName()]
        if let data = try? JSONSerialization.data(withJSONObject: reply) { sendText(String(decoding: data, as: UTF8.self)) }
        return true
    }

    func onBinary(_ data: Data) -> Bool {
        guard let keys else { return false }
        let counter: UInt64 = lock.withLock { defer { recvCounter += 1 }; return recvCounter }
        guard let (header, body) = MPGate.open(keys.recv, counter, data) else {
            Log.write("小程序连接解密失败，断开（\(remote)）")
            return false
        }
        switch header["t"] as? String {
        case "ping"?: post(["t": "pong"])
        case "req"?: handle(header, body)
        case "cancel"?:
            if let id = header["id"] as? Int, let stream = lock.withLock({ streams.removeValue(forKey: id) }) { stream.close() }
        default: break
        }
        return true
    }

    @discardableResult
    func post(_ header: [String: Any], _ body: Data = Data()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let keys, let frame = MPGate.seal(keys.send, sendCounter, header, body) else { return false }
        sendCounter += 1
        // 加密和交给连接要在同一把锁里：计数器的顺序必须和帧到达的顺序一致
        sendBinary(frame)
        return true
    }

    private func handle(_ header: [String: Any], _ body: Data) {
        let id = header["id"] as? Int ?? 0
        let path = header["p"] as? String ?? "/"
        var query: [String: String] = [:]
        for (k, v) in header["q"] as? [String: Any] ?? [:] { query[k] = (v as? String) ?? "\(v)" }
        var headers: [String: String] = [:]
        for (k, v) in header["h"] as? [String: Any] ?? [:] { headers[k.lowercased()] = (v as? String) ?? "\(v)" }
        // 来源由这里定：不许小程序冒充别的客户端
        headers["x-kiteline-client"] = "miniprogram"
        headers["x-kiteline-via"] = via
        if headers["user-agent"] == nil { headers["user-agent"] = "Kiteline-MiniProgram" }
        let tokens = [headers["x-ccp-token"], query["t"]].compactMap { $0 }.filter { !$0.isEmpty }
        let mine = clientKey.map { String(format: "%02x", $0) }.joined()
        for token in tokens where !(MPGate.openPaths.contains(path) && token.hasPrefix("p")) {
            // 主令牌、iPhone 的令牌、别的小程序的令牌都不认：只认这把公钥自己配对得到的
            if gate.keys.boundKey(token) != mine { reply(id, .error("未配对或令牌已失效", status: 401)); return }
        }
        if tokens.isEmpty, !MPGate.openPaths.contains(path) { reply(id, .error("未配对或令牌已失效", status: 401)); return }
        let request = HTTPRequest(method: header["m"] as? String ?? "GET", path: path, query: query, headers: headers, body: body, remoteAddress: remote)
        gate.route(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .response(let response):
                if ["/pair", "/api/devices/register"].contains(path), response.status == 200,
                   let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any], let token = json["token"] as? String {
                    self.gate.keys.bind(token, self.clientKey)
                    Log.write("小程序配对成功（\(self.via)，\(self.remote)）")
                }
                self.reply(id, response)
            case .stream(let headers, let attach):
                let stream = HTTPStream(queue: self.gate.queue, remoteAddress: self.remote,
                                        sink: { [weak self] data in _ = self?.post(["t": "data", "id": id], data) },
                                        closer: { [weak self] in
                                            guard let self else { return }
                                            self.lock.withLock { _ = self.streams.removeValue(forKey: id) }
                                            self.post(["t": "end", "id": id])
                                        })
                self.lock.withLock { self.streams[id] = stream }
                self.post(["t": "res", "id": id, "s": 200, "h": headers, "stream": 1])
                attach(stream)
            }
        }
    }

    private func reply(_ id: Int, _ response: HTTPResponse) {
        let keep = response.headers.filter { ["content-type", "cache-control"].contains($0.key.lowercased()) }
        post(["t": "res", "id": id, "s": response.status, "h": keep], response.body)
    }

    func close() {
        let all: [HTTPStream] = lock.withLock {
            closed = true
            defer { streams.removeAll() }
            return Array(streams.values)
        }
        all.forEach { $0.close() }
    }
}

/// 远程：电脑这头连中继 wss://<中继>/mp/h/<编号>（relay/push/mp.go）。先回应身份挑战（DH(长期私钥, 中继临时公钥) 做 HMAC 签随机数），
/// 之后中继转来的每个小程序连接是一条 MPSession，来源当作 127.0.0.1（和 iPhone 经中继一样：配对码要在电脑上点「允许」）。
/// 帧格式：[类型 1 字节][连接号 4 字节大端][内容]；类型 1 新连接、2 文本、3 二进制、4 断开
final class MPRelayLink: NSObject, URLSessionWebSocketDelegate {
    private unowned let gate: MPGate
    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var sessions: [UInt32: MPSession] = [:]
    private var stopped = false
    private var delay: TimeInterval = 2
    private var proven = false
    private(set) var status = "未连接"

    init?(gate: MPGate, relay: String) {
        var text = relay.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !text.contains("://") { text = "https://" + text }
        text = text.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
        guard let url = URL(string: text + "/mp/h/" + gate.keys.id) else { return nil }
        self.gate = gate
        self.url = url
    }

    func start() { gate.queue.async { self.connect() } }

    func stop() {
        gate.queue.async {
            self.stopped = true
            self.task?.cancel(with: .goingAway, reason: nil)
            self.closeAll()
        }
    }

    private func connect() {
        guard !stopped else { return }
        let queue = OperationQueue()
        queue.underlyingQueue = gate.queue
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.setValue("Kiteline (mac)", forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 48 * 1024 * 1024
        self.session = session
        self.task = task
        proven = false
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            self?.gate.queue.async {
                guard let self, task === self.task else { return }
                switch result {
                case .failure: self.lost()
                case .success(let message):
                    switch message {
                    case .string(let text): self.onText(text)
                    case .data(let data): self.onData(data)
                    @unknown default: break
                    }
                    self.receive(task)
                }
            }
        }
    }

    private func onText(_ text: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        switch json["t"] as? String {
        case "challenge"?:
            guard let e = Data(base64Encoded: json["e"] as? String ?? ""), let n = Data(base64Encoded: json["n"] as? String ?? ""),
                  let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: e),
                  let shared = try? gate.keys.privateKey.sharedSecretFromKeyAgreement(with: pub) else { lost(); return }
            let key = SymmetricKey(data: shared.withUnsafeBytes { Data($0) })
            let mac = HMAC<SHA256>.authenticationCode(for: Data("kiteline-mp-relay".utf8) + n, using: key)
            let prove: [String: Any] = ["t": "prove", "s": gate.keys.publicKey.base64EncodedString(), "m": Data(mac).base64EncodedString()]
            if let data = try? JSONSerialization.data(withJSONObject: prove) { task?.send(.string(String(decoding: data, as: UTF8.self))) { _ in } }
        case "ok"?:
            proven = true
            delay = 2
            status = "已连接"
            Log.write("小程序远程通道已连上中继 \(url.host ?? "")")
        default: break
        }
    }

    private func onData(_ data: Data) {
        guard proven, data.count >= 5 else { return }
        let kind = data[data.startIndex]
        let cid = data.dropFirst().prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let body = Data(data.dropFirst(5))
        switch kind {
        case 1:
            sessions[cid] = MPSession(gate: gate, remote: "127.0.0.1", via: "relay",
                                      sendBinary: { [weak self] frame in self?.send(3, cid, frame) },
                                      sendText: { [weak self] text in self?.send(2, cid, Data(text.utf8)) })
        case 4:
            sessions.removeValue(forKey: cid)?.close()
        case 2, 3:
            guard let session = sessions[cid] else { return }
            let ok = kind == 2 ? session.onText(String(decoding: body, as: UTF8.self)) : session.onBinary(body)
            if !ok {
                sessions.removeValue(forKey: cid)?.close()
                send(4, cid, Data())
            }
        default: break
        }
    }

    /// MPSession 在自己的锁里调这里（帧顺序要和计数器一致）：URLSessionWebSocketTask.send 按调用顺序发
    private func send(_ kind: UInt8, _ cid: UInt32, _ body: Data) {
        var head = Data([kind])
        withUnsafeBytes(of: cid.bigEndian) { head.append(contentsOf: $0) }
        task?.send(.data(head + body)) { _ in }
    }

    private func closeAll() {
        let all = sessions.values
        sessions.removeAll()
        all.forEach { $0.close() }
    }

    private func lost() {
        closeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        status = "未连接"
        guard !stopped else { return }
        let wait = delay
        delay = min(delay * 2, 60)
        gate.queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        gate.queue.async { if webSocketTask === self.task { self.lost() } }
    }
}
