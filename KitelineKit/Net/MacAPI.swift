import Foundation

/// 已配对那台 Mac 的接口：普通请求、图片、实时事件。
/// Mac 有好几个地址（家里 Wi-Fi 的局域网地址、.local 名字、Tailscale），再加远程访问（点对点）在手机本机开的转发。
/// 开着远程访问时优先走它：同一个 Wi-Fi 里它本身走局域网直连，出门走中继，换网络时在同一条连接里换路（像 Tailscale），
/// App 这边不用切路，请求和实时事件流都不断。只有它正走中继、而局域网地址也通时才改走局域网（中继限速，局域网更快）。
/// 免费版、没开远程访问时只走局域网地址；用流量（5G）时局域网地址根本不通，不去挨个等超时。
final class MacAPI: @unchecked Sendable {
    let token: String
    private var addresses: [URL]
    /// 远程访问开好的本机转发（https://127.0.0.1:端口，端口开一次就不变）；还在开的时候 remoteTask 不为空
    private var remote: URL?
    private var remoteTask: Task<URL?, Never>?
    private let client: MacClient
    private let streamClient: MacClient
    /// 图片：单独一组连接。十几张图一起下时不占普通请求的连接（否则普通请求排队到超时，还会被当成断网去重新探路）；
    /// 大截图走远程访问可能要十几秒，超时放宽
    private let mediaClient: MacClient
    /// 要等电脑把一件事做完才回应的请求（见 actionPaths）：单独一组连接、等得久一些
    private let actionClient: MacClient
    /// 发消息、恢复会话、语音转写后发送、按键、回答提问、调整排队、关闭会话：电脑要把这件事做完才回应，
    /// 后台通道卡一下、恢复会话、转写长录音都可能要十几秒。原来和普通请求一样 12 秒超时：
    /// 发消息的会换一条路重发（电脑那头其实还在送，同一条进去两遍），按键、回答的直接报「无法确认电脑是否已收到」
    private static let actionPaths: Set<String> = ["/api/send", "/api/resume", "/api/voice", "/api/key", "/api/answer", "/api/queue", "/api/close"]
    /// 探路用：短超时，几个地址一起试
    private let pingClient: MacClient
    /// 连远程访问的本机转发（https://127.0.0.1:端口）被直接拒绝时调：多半是 App 被挂起期间 iOS 回收了监听端口（苹果 TN2277），
    /// 让点对点把端口重新开起来（AppModel 设）。11-13 用户出门时就是这样：没走「回到前台」那条路，端口一直是坏的，流量下又没有局域网可退
    var remoteRefused: (@Sendable () async -> Void)?
    private let lock = NSLock()
    /// 上次通的那个地址；网络变了、请求连不上时清掉，下次先探路
    private var preferred: URL?
    private var probing: Task<URL?, Never>?

    init(mac: PairedMac) {
        token = mac.token
        // 127.0.0.1 是上次远程访问开的转发，端口每次都变，存下来的没用
        addresses = mac.addresses.filter { AddressKind.of($0) != .remote }
        if addresses.isEmpty { addresses = [URL(string: "https://127.0.0.1:8766")!] }
        client = MacClient(mac: mac, timeout: 12)
        if mac.caCertificate == nil {
            let token = mac.token
            client.onRootCaptured = { der in Task { @MainActor in MacStore.shared.fillCertificate(der, token: token) } }
        }
        pingClient = MacClient(mac: mac, timeout: 4)
        mediaClient = MacClient(mac: mac, timeout: 45)
        actionClient = MacClient(mac: mac, timeout: 40)
        // 实时事件流：Mac 每 15 秒发一次保活，25 秒没动静就算断了（换路重连）
        streamClient = MacClient(mac: mac, timeout: 25)
    }

    deinit {
        client.close()
        streamClient.close()
        pingClient.close()
        mediaClient.close()
        actionClient.close()
    }

    /// 地址是哪条路
    enum AddressKind: Equatable {
        /// loopback：Mac App 主窗口里连自己的服务（http://127.0.0.1）；remote：手机上远程访问开的本机转发（https://127.0.0.1）
        case loopback, lan, remote, tailscale, other

        static func of(_ url: URL) -> AddressKind {
            guard let host = url.host()?.lowercased() else { return .other }
            if host == "127.0.0.1" || host == "localhost" { return url.scheme == "http" ? .loopback : .remote }
            return of(host: host)
        }

        /// 只看主机名 / IP（不含端口、方括号）
        static func of(host: String) -> AddressKind {
            let host = host.lowercased()
            if host.hasSuffix(".local") || host.hasPrefix("fe80:") || host.hasPrefix("fd") && host.contains(":") { return .lan }
            let parts = host.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return .other }
            switch (parts[0], parts[1]) {
            case (10, _), (192, 168), (169, 254): return .lan
            case (172, 16...31): return .lan
            case (100, 64...127): return .tailscale
            default: return .other
            }
        }
    }

    var base: URL { lock.withLock { preferred ?? addresses[0] } }

    /// 现在走的路，给人看：「局域网 192.168.1.5」「局域网直连」（远程访问在同一 Wi-Fi 里）「中继」
    var routeLabel: String {
        let url = base
        if url.host() == "demo.tars.invalid" { return L("演示数据（未连接电脑）") }
        switch AddressKind.of(url) {
        case .loopback: return L("本机")
        case .lan: return L("局域网 ") + (url.host() ?? "")
        case .remote:
            let link = PhoneP2P.readLink()
            guard link.up else { return L("远程访问（正在连接）") }
            switch link.path {
            case .direct: return link.onLAN ? L("局域网直连") : L("点对点直连")
            case .relay: return L("中继")
            case .none: return L("远程访问")
            }
        case .tailscale: return "Tailscale " + (url.host() ?? "")
        case .other: return url.host() ?? ""
        }
    }

    /// 远程访问正在开：开好了记下本机转发地址。探路时会等它开好、和局域网一起比
    func useRemote(_ task: Task<URL?, Never>) {
        lock.withLock { remoteTask = task }
        Task {
            let url = await task.value
            lock.withLock {
                if let url { remote = url }
                if remoteTask == task { remoteTask = nil }
            }
        }
    }

    /// 换网络了（Wi-Fi ↔ 5G）：忘掉上次的路，下一个请求先探路
    func networkChanged() {
        lock.withLock { preferred = nil }
    }

    /// 按现在的网络排好的候选地址：远程访问第一；Wi-Fi 上再试局域网，用流量时不试；Tailscale 排最后（手机没开 Tailscale 就不通）
    private func candidates() -> [URL] {
        let (list, remote) = lock.withLock { (addresses, remote) }
        // 免费版只能在局域网里用：不走点对点、Tailscale 和别的地址；不在 Wi-Fi 上就直接算连不上，不去等超时。
        // 局域网地址也要手机直接经 Wi-Fi 到得了：在外面开着 Tailscale 这类组网、经隧道连家里的局域网地址是远程访问。
        // 每个请求都查一次（只查路由表，几十微秒），中途打开 VPN 下一个请求就换不过去
        guard ProGate.isUnlocked else {
            return LocalRoute.direct(list.filter { AddressKind.of($0) == .loopback } + (NetPath.shared.onLAN ? list.filter { AddressKind.of($0) == .lan } : []))
        }
        var ranked = list.filter { AddressKind.of($0) == .loopback }   // 连自己：不管有没有网都通
        if let remote { ranked.append(remote) }
        if NetPath.shared.onLAN { ranked += list.filter { AddressKind.of($0) == .lan } }
        ranked += list.filter { AddressKind.of($0) == .other }
        ranked += list.filter { AddressKind.of($0) == .tailscale }
        return ranked
    }

    /// 电脑的局域网地址要经 VPN 隧道才到得了（手机不在电脑所在的 Wi-Fi，靠 Tailscale 这类组网连回去）：免费版连不上时提示这算远程访问
    var lanViaTunnel: Bool {
        NetPath.shared.onLAN && LocalRoute.tunneled(lock.withLock { addresses }.filter { AddressKind.of($0) == .lan })
    }

    /// 现在该用的地址：上次通的那个还在候选里就用它，否则探一次路
    private func route() async -> URL? {
        if let url = lock.withLock({ preferred }), candidates().contains(url) { return url }
        return await probeRoute()
    }

    /// 所有候选一起试，谁先回就用谁（不用挨个等超时）。都不通返回 false
    @discardableResult
    func probe() async -> Bool { await probeRoute() != nil }

    private func probeRoute() async -> URL? {
        // 同一时间只探一次，大家等同一个结果
        let task: Task<URL?, Never> = lock.withLock {
            if let probing { return probing }
            let task = Task {
                let started = Date()
                let url = await self.race()
                NetLog.note("route", ["to": url.map { "\(AddressKind.of($0))" } ?? "none", "ms": Int(Date().timeIntervalSince(started) * 1000),
                                      "link": "\(PhoneP2P.readLink().path)"])
                return url
            }
            probing = task
            return task
        }
        let url = await task.value
        lock.withLock {
            if probing == task { probing = nil }
            if let url { preferred = url }
        }
        return url
    }

    /// 几条路一起试，按这个顺序挑：远程访问通了且不是走中继（同一 Wi-Fi 里的局域网直连、打洞直连）→ 马上用它；
    /// 远程访问走中继、局域网也通 → 用局域网（中继限速）；先回来的是局域网 → 再给远程访问一小会儿（1 秒，正在重连时 2.5 秒），它直连就用它。
    /// 远程访问还在开（刚启动）就等它开好一起比（只是在本机开端口，一般几十毫秒，最多等 3 秒）
    private func race() async -> URL? {
        let list = candidates()
        var pending: Task<URL?, Never>?
        if ProGate.isUnlocked, !list.contains(where: { AddressKind.of($0) == .remote }) {
            pending = lock.withLock { remoteTask }
        }
        guard !list.isEmpty || pending != nil else { return nil }
        let hasRemote = pending != nil || list.contains { AddressKind.of($0) == .remote }
        let hasLAN = list.contains { AddressKind.of($0) == .lan || AddressKind.of($0) == .loopback }
        // 局域网先回来时给远程访问的那一小会儿：它正在重连（刚回到前台）就多等等，免得先走局域网、几秒后又换过去断一次
        let grace = hasRemote && !PhoneP2P.readLink().up ? 2500 : 1000
        return await withTaskGroup(of: URL?.self) { group -> URL? in
            for base in list {
                group.addTask { await self.ping(base) }
            }
            if let pending {
                group.addTask {
                    guard let url = await Self.value(of: pending, within: 3) else { return nil }
                    return await self.ping(url)
                }
            }
            var remoteHit: URL?   // 远程访问通了，但正走中继（在等局域网）
            var lanHit: URL?      // 局域网通了（在等远程访问）
            var fallback: URL?    // Tailscale、别的地址
            var waiting = false
            for await url in group {
                if url == Self.graceOver { break }
                guard let url else { continue }
                switch AddressKind.of(url) {
                case .remote:
                    if !hasLAN || !NetPath.shared.onLAN || PhoneP2P.readLink().path != .relay {
                        group.cancelAll()
                        return url
                    }
                    if let lanHit {
                        group.cancelAll()
                        return lanHit
                    }
                    remoteHit = url
                case .lan, .loopback:
                    if !hasRemote || remoteHit != nil {
                        group.cancelAll()
                        return url
                    }
                    if lanHit == nil { lanHit = url }
                case .tailscale, .other:
                    if fallback == nil { fallback = url }
                }
                if !waiting, remoteHit != nil || lanHit != nil {
                    waiting = true
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(grace))
                        return Self.graceOver
                    }
                }
            }
            group.cancelAll()
            return lanHit ?? remoteHit ?? fallback
        }
    }

    /// race 里「等的那一小会儿到了」
    private static let graceOver = URL(string: "about:grace")!

    /// 等任务的结果，最多等 seconds 秒（到时间返回 nil、不再等它；Task.value 本身不能取消）
    private static func value(of task: Task<URL?, Never>, within seconds: Double) async -> URL? {
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task {
                let url = await task.value
                if once.first() { continuation.resume(returning: url) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.first() { continuation.resume(returning: nil) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    private func ping(_ base: URL) async -> URL? {
        guard let request = try? MacClient.request(url(base, "/api/ping", [:]), token: token),
              let (_, http) = try? await pingClient.send(request), http.statusCode == 200 else { return nil }
        return base
    }

    /// 局域网这条路通不通：几个局域网地址一起试，返回通的那个。不在 Wi-Fi 上直接算不通，不发请求
    func probeLAN() async -> URL? {
        guard NetPath.shared.onLAN else { return nil }
        let lans = lock.withLock { addresses }.filter { AddressKind.of($0) == .lan }
        return await withTaskGroup(of: URL?.self) { group -> URL? in
            for base in lans { group.addTask { await self.ping(base) } }
            for await url in group where url != nil {
                group.cancelAll()
                return url
            }
            return nil
        }
    }

    /// 远程访问这条路通不通：经手机本机的转发问一次 Mac（还在开就等它开好，最多 3 秒）。免费版不走远程访问
    func probeRelay() async -> URL? {
        guard ProGate.isUnlocked else { return nil }
        var url = lock.withLock { remote }
        if url == nil, let pending = lock.withLock({ remoteTask }) { url = await Self.value(of: pending, within: 3) }
        guard let url else { return nil }
        return await ping(url)
    }

    /// 换到这条路（局域网断了换到远程访问；远程访问直连了换回它）
    func use(_ url: URL) {
        lock.withLock { preferred = url }
    }

    /// 现在走的是哪条路
    var routeKind: AddressKind { AddressKind.of(base) }

    // MARK: 普通请求

    @discardableResult
    func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        let (data, http) = try await perform { try MacClient.request(self.url($0, path, query), token: self.token) }
        return try APIError.check(data, http)
    }

    @discardableResult
    func post(_ path: String, _ query: [String: String] = [:], body: [String: Any] = [:]) async throws -> [String: Any] {
        // 带 cid 的（发消息）Mac 会去重，重发安全；按键这类不能重发：超时了可能已经按上了，再发一次就按到下一个确认上
        let (data, http) = try await perform(idempotent: body["cid"] != nil, using: Self.actionPaths.contains(path) ? actionClient : nil) {
            try MacClient.request(self.url($0, path, query), method: "POST", token: self.token, body: body)
        }
        return try APIError.check(data, http)
    }

    /// POST 拿回原始数据（朗读的音频）
    func postData(_ path: String, _ query: [String: String] = [:], body: [String: Any] = [:]) async throws -> Data {
        let (data, http) = try await perform(idempotent: false) {
            try MacClient.request(self.url($0, path, query), method: "POST", token: self.token, body: body)
        }
        if http.statusCode >= 400 { _ = try APIError.check(data, http) }
        return data
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String] = [:]) async throws -> T {
        let (data, http) = try await perform { try MacClient.request(self.url($0, path, query), token: self.token) }
        _ = try APIError.check(data, http)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 同 get，顺手把回的 JSON 原样存一份在手机上（Offline.savePage）。页面打开时先用 cached 显示上次的，
    /// 后台再用这个取新的、取到就换掉（11-13：进页面不能是空的，更新在后台静默做）
    func getCaching<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String] = [:]) async throws -> T {
        #if SNAPSHOT
        // 截图版测缓存：KITELINE_DEMO_SLOWAPI=<秒> 让这些接口晚这么久才回（看重开时是不是先显示缓存、右上角「更新中」）
        if let delay = Double(ProcessInfo.processInfo.environment["KITELINE_DEMO_SLOWAPI"] ?? "") { try? await Task.sleep(for: .seconds(delay)) }
        #endif
        let (data, http) = try await perform { try MacClient.request(self.url($0, path, query), token: self.token) }
        _ = try APIError.check(data, http)
        let value = try JSONDecoder().decode(T.self, from: data)
        Offline.savePage(Self.pageKey(path, query), data)
        return value
    }

    /// 上次 getCaching 同一个接口、同样参数存下的结果（没存过、解不出来是 nil）。读的是本机文件，不联网
    func cached<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String] = [:]) -> T? {
        Offline.loadPage(Self.pageKey(path, query)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// 同 data（原始 JSON 自己解的页面用，如战绩条），顺手存一份
    func dataCaching(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        let data = try await self.data(path, query)
        Offline.savePage(Self.pageKey(path, query), data)
        return data
    }

    /// 上次 dataCaching 存下的原始数据
    func cachedData(_ path: String, _ query: [String: String] = [:]) -> Data? {
        Offline.loadPage(Self.pageKey(path, query))
    }

    /// 缓存按「接口 + 参数」分开存；fresh（让电脑跳过它自己的缓存）不算参数
    private static func pageKey(_ path: String, _ query: [String: String]) -> String {
        path + "?" + query.filter { $0.key != "fresh" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    /// 图片等原始数据（走图片那组连接）
    func data(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        let (data, http) = try await perform(using: mediaClient) { try MacClient.request(self.url($0, path, query), token: self.token) }
        if http.statusCode >= 400 { _ = try APIError.check(data, http) }
        return data
    }

    /// 原图：边下边报进度（看大图时显示「原图 1.2 MB」和进度条）。走图片那组连接；连不上时换路重试，同 data()
    func data(_ path: String, _ query: [String: String] = [:], progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws -> Data {
        var lastError: Error = URLError(.cannotConnectToHost)
        for _ in 0..<2 {
            guard let base = await route() else { break }
            do {
                let (bytes, http) = try await mediaClient.bytes(try MacClient.request(url(base, path, query), token: token))
                let total = http.expectedContentLength
                var data = Data()
                if total > 0 { data.reserveCapacity(Int(total)) }
                var chunk: [UInt8] = []
                chunk.reserveCapacity(65_536)
                progress(0, total)
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count == 65_536 {
                        data.append(contentsOf: chunk)
                        chunk.removeAll(keepingCapacity: true)
                        progress(Int64(data.count), total)
                    }
                }
                data.append(contentsOf: chunk)
                progress(Int64(data.count), total)
                if http.statusCode >= 400 { _ = try APIError.check(data, http) }
                return data
            } catch let error as URLError where Self.isUnreachable(error) {
                lastError = error
                lock.withLock { if preferred == base { preferred = nil } }
            }
        }
        throw OfflineError(message: MacClient.explain(lastError, host: L("电脑")).localizedDescription)
    }

    private func url(_ base: URL, _ path: String, _ query: [String: String]) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents 不编码 +，Mac 那边会把它当空格
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return parts.url!
    }

    /// 用现在的路发；网络层面的失败（连不上、超时）就探一次路、换探到的再试一次。Mac 回了错误直接报。
    /// idempotent = false（按键、回答这类做两次不一样的）：只有确定没发出去（连不上、握手失败）才换路重发；
    /// 超时、连接中途断了的可能已经送到 Mac，不重发，告诉调用方「不确定」
    private func perform(idempotent: Bool = true, using: MacClient? = nil, _ make: (URL) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error = URLError(.cannotConnectToHost)
        for _ in 0..<2 {
            guard let base = await route() else { break }
            do {
                return try await (using ?? client).send(try make(base))
            } catch let error as URLError where Self.isUnreachable(error) {
                NetLog.note("request_failed", ["via": "\(AddressKind.of(base))", "code": error.code.rawValue])
                lastError = error
                lock.withLock { if preferred == base { preferred = nil } }
                if error.code == .cannotConnectToHost, AddressKind.of(base) == .remote { await remoteRefused?() }
                if !idempotent, !Self.neverSent(error) {
                    throw OfflineError(message: L("网络连接曾中断，无法确认电脑是否已收到，请核实后再操作"))
                }
            }
        }
        throw OfflineError(message: MacClient.explain(lastError, host: L("电脑")).localizedDescription)
    }

    /// 请求肯定没到 Mac（连接都没建起来）：重发不会做两次
    static func neverSent(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed].contains(error.code)
    }

    static func isUnreachable(_ error: URLError) -> Bool {
        [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
         .dnsLookupFailed, .secureConnectionFailed, .cannotLoadFromNetwork].contains(error.code)
    }

    // MARK: 实时事件（SSE）

    /// 连上 /api/events，逐条给出 (事件名, JSON 数据)。连接断了流就结束（或抛错），由调用方决定何时重连
    func events() -> AsyncThrowingStream<(String, Data), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, http) = try await openStream()
                    if http.statusCode != 200 {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 4096 { break } }
                        _ = try APIError.check(body, http)
                        throw APIError(message: L("实时连接失败（%@）", "\(http.statusCode)"), status: http.statusCode)
                    }
                    var event = "message"
                    // 服务端每条事件只有一行 data（JSON 不换行），收到 data 就分发，不依赖空行
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let text = line.dropFirst(5).drop { $0 == " " }
                            continuation.yield((event, Data(text.utf8)))
                            event = "message"
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func openStream() async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var lastError: Error = URLError(.cannotConnectToHost)
        for _ in 0..<2 {
            guard var base = await route() else { break }
            // 先用短超时确认这条路现在通：局域网单向不通（握手发出去没回音）时直接建流要干等到超时
            if await ping(base) == nil {
                lock.withLock { if preferred == base { preferred = nil } }
                guard let other = await probeRoute() else { break }
                base = other
            }
            // patch=1：之后的状态只推变了的部分（新版 Mac 支持；旧版和 Windows/Linux 电脑端不认这个参数，照旧推整份）
            var request = try MacClient.request(url(base, "/api/events", ["patch": "1"]), token: token)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            do {
                return try await streamClient.bytes(request)
            } catch let error as URLError where Self.isUnreachable(error) {
                lastError = error
                lock.withLock { if preferred == base { preferred = nil } }
                if error.code == .cannotConnectToHost, AddressKind.of(base) == .remote { await remoteRefused?() }
            }
        }
        throw OfflineError(message: MacClient.explain(lastError, host: L("电脑")).localizedDescription)
    }
}

/// 所有地址都连不上（不是 Mac 回了错误）：发的消息先排队，连上再发
struct OfflineError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
