import Foundation
import Network
import Security

/// 一个请求（头部键已转小写）
struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    var remoteAddress: String

    var cookies: [String: String] {
        var result: [String: String] = [:]
        for pair in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            result[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    var jsonBody: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                            body: data)
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["ok": false, "error": message], status: status)
    }

    static func text(_ text: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: Data(text.utf8))
    }

    static func redirect(_ location: String, headers extra: [String: String] = [:]) -> HTTPResponse {
        var headers = extra
        headers["Location"] = location
        return HTTPResponse(status: 302, headers: headers)
    }
}

/// SSE 这类长连接的写端。写操作都在服务器自己的队列上排队。
final class HTTPStream {
    private let connection: NWConnection?
    private let queue: DispatchQueue
    /// 不经 TCP 连接的流（微信小程序的加密隧道，见 MPGate.swift）：写进来的字节交给它，关闭时调 closer
    private let sink: ((Data) -> Void)?
    private let closer: (() -> Void)?
    private(set) var isClosed = false
    var onClose: (() -> Void)?
    let remoteAddress: String

    init(connection: NWConnection, queue: DispatchQueue, remoteAddress: String) {
        self.connection = connection
        self.queue = queue
        self.remoteAddress = remoteAddress
        sink = nil
        closer = nil
    }

    init(queue: DispatchQueue, remoteAddress: String, sink: @escaping (Data) -> Void, closer: @escaping () -> Void) {
        connection = nil
        self.queue = queue
        self.remoteAddress = remoteAddress
        self.sink = sink
        self.closer = closer
    }

    /// 交给连接、还没发出去的字节数（只在 queue 上读写）
    private var pending = 0
    /// 对方一直不收（断网没断开、或者故意不读），发不出去的超过这么多就断开它，免得在内存里越攒越多；手机会自己重连
    private static let maxPending = 8 * 1024 * 1024

    func send(_ data: Data) {
        queue.async {
            guard !self.isClosed else { return }
            if let sink = self.sink { sink(data); return }
            guard let connection = self.connection else { return }
            if self.pending + data.count > HTTPStream.maxPending {
                Log.write("实时连接（\(self.remoteAddress)）积压超过 8 MB 没发出去，断开")
                self.close()
                return
            }
            self.pending += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async { self.pending -= data.count }
                if error != nil { self.close() }
            })
        }
    }

    func close() {
        queue.async {
            guard !self.isClosed else { return }
            self.isClosed = true
            self.connection?.cancel()
            self.closer?()
            let callback = self.onClose
            self.onClose = nil
            callback?()
        }
    }
}

/// 极简但正经的 HTTP/1.1 服务器：
/// - 按字节解析（不把整个请求当字符串，图片上传不会被 UTF-8 解码弄坏）
/// - 支持 Content-Length 请求体，上限可配
/// - 普通请求一问一答后关闭连接；SSE 请求交给调用方长期持有
final class HTTPServer {
    enum Reply {
        case response(HTTPResponse)
        /// 先发出响应头，再把连接交给调用方持续写入
        case stream(headers: [String: String], (HTTPStream) -> Void)
    }

    typealias Handler = (HTTPRequest, @escaping (Reply) -> Void) -> Void

    private let port: UInt16
    private let host: String
    private let handler: Handler
    /// 有身份就是 HTTPS
    private let tlsIdentity: SecIdentity?
    private var listener: NWListener?
    let queue = DispatchQueue(label: "ccpulse.http")
    var maxBodyBytes = 48 * 1024 * 1024
    /// 请求体超过 1 MB 时，收之前先按请求头问一句是不是自己人（带着有效令牌）：陌生人发不了大请求体，防有人开一堆连接各灌 48 MB 占满内存
    var allowLargeBody: ((_ headers: [String: String], _ target: String) -> Bool)?
    private let largeBody = 1024 * 1024
    var onStateChange: ((String) -> Void)?
    /// 在局域网上用 Bonjour 宣告自己（Kiteline iOS App 靠它找到 Mac，只输 6 位配对码就能配上）
    var bonjour: NWListener.Service?
    /// 监听出故障后已经连着重启了几次（进入 ready 后清零）；stop() 之后不再重启
    private var failures = 0
    private var stopped = false

    init(host: String, port: UInt16, tlsIdentity: SecIdentity? = nil, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.tlsIdentity = tlsIdentity
        self.handler = handler
    }

    var isSecure: Bool { tlsIdentity != nil }

    /// 握手时把本机根证书一起发出去：Kiteline iOS App 配对时从握手里拿到它，核对二维码里的指纹后记下来，
    /// 之后只认它签的证书（不用像网页版那样去「设置」里装描述文件）。浏览器不受影响。
    /// （证书数组里只放服务器证书之后的部分：服务器证书本身系统会自己带上，放进去会发两遍）
    private static func withChain(_ identity: SecIdentity) -> sec_identity_t? {
        guard let ca = LocalTLS.caCertificate else { return sec_identity_create(identity) }
        return sec_identity_create_with_certificates(identity, [ca] as CFArray)
    }

    func start() throws {
        stopped = false
        failures = 0
        try listen(withBonjour: true)
    }

    private func listen(withBonjour: Bool) throws {
        let parameters: NWParameters
        if let identity = tlsIdentity, let secIdentity = Self.withChain(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteError("端口号非法：\(port)")
        }
        if !host.isEmpty, host != "0.0.0.0", host != "::" {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        let listener = host.isEmpty || host == "0.0.0.0" || host == "::"
            ? try NWListener(using: parameters, on: nwPort)
            : try NWListener(using: parameters)
        listener.service = withBonjour ? bonjour : nil
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.failures = 0
                self?.onStateChange?("监听中 \(self?.host ?? ""):\(self?.port ?? 0)")
            case .failed(let error):
                Log.write("HTTP 服务故障：\(error.localizedDescription)，稍后自动重启")
                self?.onStateChange?("故障：\(error.localizedDescription)，正在重启")
                self?.restartAfterFailure(listener)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// 监听故障后自动重启（2026-10-22：系统的 mDNSResponder 出了一次故障，带 Bonjour 宣告的 HTTPS 监听跟着停了，
    /// 之后一直没恢复，手机全连不上，只能重开 Kiteline）。间隔逐次拉长；第二次起先不带 Bonjour 宣告
    /// （已配对的手机记着地址，不靠它；先保住 HTTPS），起来两分钟后再带上宣告重开一次
    private func restartAfterFailure(_ failed: NWListener) {
        failed.cancel()
        guard !stopped, listener === failed else { return }
        listener = nil
        failures += 1
        let delays: [Double] = [2, 5, 15, 30, 60]
        let delay = delays[min(failures - 1, delays.count - 1)]
        let withBonjour = bonjour != nil && failures < 2
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.listener == nil else { return }
            do {
                try self.listen(withBonjour: withBonjour)
                let note = withBonjour || self.bonjour == nil ? "" : "，暂不宣告 Bonjour"
                Log.write("HTTP 服务已自动重启（端口 \(self.port)\(note)）")
            } catch {
                Log.write("HTTP 服务重启失败：\(error.localizedDescription)")
                self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, !self.stopped, self.listener == nil else { return }
                    try? self.listen(withBonjour: false)
                }
            }
            guard !withBonjour, self.bonjour != nil else { return }
            // 不带 Bonjour 起来后，过两分钟再带上宣告（新手机靠它在局域网里找到这台电脑）
            self.queue.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, !self.stopped, self.failures == 0, let current = self.listener, current.service == nil else { return }
                current.stateUpdateHandler = nil
                current.cancel()
                self.listener = nil
                try? self.listen(withBonjour: true)
            }
        }
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = ReadDeadline()
        deadline.arm(15, queue: queue, connection: connection)
        receive(connection, buffer: Data(), header: nil, deadline: deadline)
    }

    /// 读请求的期限：请求头 15 秒内没收齐、请求体没在期限内收完（1 MB 以内 60 秒，更大的 10 分钟）就断开——
    /// 防有人一个字节一个字节地慢慢发，把连接数占满。
    /// 请求收齐交给处理函数以后不再计时（实时事件流本来就是长连接）。只在 HTTP 队列上用
    private final class ReadDeadline {
        private var item: DispatchWorkItem?
        func arm(_ seconds: Double, queue: DispatchQueue, connection: NWConnection) {
            item?.cancel()
            let work = DispatchWorkItem { connection.cancel() }
            item = work
            queue.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        func disarm() {
            item?.cancel()
            item = nil
        }
    }

    private struct ParsedHeader {
        var method: String
        var target: String
        var headers: [String: String]
        var headerLength: Int
        var contentLength: Int
    }

    private func receive(_ connection: NWConnection, buffer: Data, header: ParsedHeader?, deadline: ReadDeadline) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var accumulated = buffer
            if let data = data { accumulated.append(data) }
            if error != nil {
                connection.cancel(); return
            }

            var parsed = header
            if parsed == nil {
                guard let end = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                    if accumulated.count > 64 * 1024 || isComplete {
                        connection.cancel(); return
                    }
                    self.receive(connection, buffer: accumulated, header: nil, deadline: deadline)
                    return
                }
                guard let head = String(data: accumulated.subdata(in: 0..<end.lowerBound), encoding: .utf8),
                      let result = self.parseHeader(head, headerLength: end.upperBound) else {
                    deadline.disarm()
                    self.write(.text("bad request", status: 400), to: connection)
                    return
                }
                if result.contentLength > self.maxBodyBytes {
                    deadline.disarm()
                    self.write(.error("请求体太大", status: 413), to: connection)
                    return
                }
                if result.contentLength > self.largeBody, let allow = self.allowLargeBody, !allow(result.headers, result.target) {
                    deadline.disarm()
                    self.write(.error("未配对或令牌已失效", status: 401), to: connection)
                    return
                }
                // 请求体：1 MB 以内给 60 秒；更大的已经核对过令牌（自己人传图片），慢网也给足 10 分钟
                deadline.arm(result.contentLength > self.largeBody ? 600 : 60, queue: self.queue, connection: connection)
                parsed = result
            }

            guard let current = parsed else { return }
            let have = accumulated.count - current.headerLength
            if have < current.contentLength {
                if isComplete { connection.cancel(); return }
                self.receive(connection, buffer: accumulated, header: current, deadline: deadline)
                return
            }
            deadline.disarm()
            let body = accumulated.subdata(in: current.headerLength..<(current.headerLength + current.contentLength))
            self.dispatch(current, body: body, connection: connection)
        }
    }

    private func parseHeader(_ text: String, headerLength: Int) -> ParsedHeader? {
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        return ParsedHeader(method: String(parts[0]).uppercased(), target: String(parts[1]),
                            headers: headers, headerLength: headerLength, contentLength: max(0, length))
    }

    private func dispatch(_ header: ParsedHeader, body: Data, connection: NWConnection) {
        var path = header.target
        var query: [String: String] = [:]
        if let mark = header.target.firstIndex(of: "?") {
            path = String(header.target[header.target.startIndex..<mark])
            query = HTTPServer.parseQuery(String(header.target[header.target.index(after: mark)...]))
        }
        let remote: String = {
            if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
            return "?"
        }()
        let request = HTTPRequest(method: header.method, path: path.removingPercentEncoding ?? path,
                                  query: query, headers: header.headers, body: body, remoteAddress: remote)
        let gzip = (header.headers["accept-encoding"] ?? "").contains("gzip")
        handler(request) { [weak self] reply in
            guard let self = self else { return }
            self.queue.async {
                switch reply {
                case .response(let response):
                    self.write(response, to: connection, gzip: gzip)
                case .stream(let headers, let body):
                    self.openStream(connection: connection, headers: headers, remote: remote, body: body)
                }
            }
        }
    }

    private func openStream(connection: NWConnection, headers: [String: String], remote: String,
                            body: @escaping (HTTPStream) -> Void) {
        var head = "HTTP/1.1 200 OK\r\n"
        var all = headers
        all["Connection"] = "keep-alive"
        all["Cache-Control"] = "no-store"
        for (key, value) in all { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        let stream = HTTPStream(connection: connection, queue: queue, remoteAddress: remote)
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: stream.close()
            default: break
            }
        }
        // 客户端断开时 receive 会拿到 isComplete / error，据此回收
        func watchClose() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
                if isComplete || error != nil { stream.close() } else { watchClose() }
            }
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
            if error != nil { stream.close(); return }
            watchClose()
            body(stream)
        })
    }

    private func write(_ response: HTTPResponse, to connection: NWConnection, gzip: Bool = false) {
        var head = "HTTP/1.1 \(response.status) \(HTTPServer.reason(response.status))\r\n"
        var headers = response.headers
        var body = response.body
        // 网页、接口 JSON 这类文本压一下，手机网络差时快很多（app.js 约 190KB → 50KB）
        if gzip, Gzip.worthCompressing(response), let packed = Gzip.compress(body), packed.count < body.count {
            body = packed
            headers["Content-Encoding"] = "gzip"
            headers["Vary"] = "Accept-Encoding"
        }
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        if headers["Content-Type"] == nil { headers["Content-Type"] = "text/plain; charset=utf-8" }
        // 头里的值去掉回车换行：哪怕某个值来自外部，也拼不出额外的响应头
        for (key, value) in headers { head += "\(key): \(value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        // 标成最后一段（isComplete）：系统把数据全部发完、TLS 收好尾再关连接。以前是「交给系统就 cancel()」，
        // HTTPS 上数据还在加密、发送缓冲里就被强行断开，大一点的响应只到一半——
        // 10-22 实测 207 KB 的原图经 HTTPS 只收到 130 KB，手机上看大图一直转圈、最后「轻点重试」
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [queue] _ in
            // 对方收完会自己关；万一一直不关（客户端挂住），过一会儿再收回连接
            queue.asyncAfter(deadline: .now() + 20) { connection.cancel() }
        })
    }

    static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).replacingOccurrences(of: "+", with: " ")
            let value = kv.count > 1 ? String(kv[1]).replacingOccurrences(of: "+", with: " ") : ""
            result[key.removingPercentEncoding ?? key] = value.removingPercentEncoding ?? value
        }
        return result
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}
