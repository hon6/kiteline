import AppKit
import CryptoKit
import Foundation
import Network
import Security
import KitelineKit

// MARK: - Kiteline 电脑互联
//
// 把另一台装了 Kiteline 的电脑加成来源（异地办公）：在「设置 → 来源」里输对方的地址和对方「手机访问」页上的验证码，
// 对方电脑弹窗允许后两台互相登记（双向）：
//   · 对方的每个来源（对方本机、对方连的 Remote-SSH 主机）在这台变成一个 kind = .kiteline 的来源，会话并进同一个列表；
//     来源 id 是「kl:<对方编号前 8 位>:<对方的来源 id>」，会话 key 照旧是「来源 id#会话 id」。
//   · 会话快照、对话增量等 watcher 事件经对方的 /api/peer/watch 原样转过来（KitelineSource），watcher 请求经 /api/peer/rpc 转过去；
//   · 手机、主窗口对这些会话的操作（发消息、批准、关闭、取历史、文件、终端……）整条 HTTP 请求转给对方电脑执行（forward），
//     因为 VS Code 在那台电脑上；会话 key / 来源 id 在出入口换算。
//   · 只转各自「自己的」来源（不转对方加进来的电脑），两台互加也不会绕圈。
//   · 绑在其中一台上的手机，经 /api/computers 拿到另一台的地址、证书和替它登记的令牌：哪台在线就连哪台（iPhone 见 MacAPI）。
//   · 电脑之间只走用户自己的网络（局域网、公网 IP、自己的组网），不经 Kiteline 的中继。
//
// 防撞验证码：电脑来配对一律要对方电脑上点「允许」；从公网地址来的手机配对也要点；同一个验证码输错 5 次就作废换新
// （见 MobileServer.pair）。

struct PeerSourceInfo: Codable, Equatable {
    var id: String
    var name: String
    var kind: String
    var live: Bool?
}

struct PeerComputer: Codable, Equatable, Identifiable {
    /// 对方电脑的编号（PeerComputers.selfId）
    var id: String
    var name: String
    /// 能连的地址（https://IP:端口），最近一次连上的排最前
    var addresses: [String]
    /// 对方给这台电脑的设备令牌（这台在对方那里的身份）
    var token: String
    /// 对方的本机根证书（DER，base64）：之后只认它签的证书
    var ca: String?
    /// 对方在本机设备列表里的那条（本机给对方登记的设备）
    var deviceId: String?
    var addedAt: Double
    /// 对方上次报的来源（对方离线时也照样列出来）
    var sources: [PeerSourceInfo] = []
    /// 本机的手机设备 id → 替它在对方那里登记的设备 id
    var enrolled: [String: String] = [:]
}

final class PeerComputers {
    static let shared = PeerComputers()
    /// 本机里「对方电脑的来源」的 id 前缀
    static let sourcePrefix = "kl:"

    private let lock = NSLock()
    private var peers: [PeerComputer] = []
    /// 对方电脑现在连不连得上：id → nil（在线）/ 连不上的原因（主线程）
    private(set) var problems: [String: String] = [:]
    private var sessions: [String: (URLSession, PeerTrust)] = [:]
    private var refreshTimer: Timer?
    /// 列表、状态变了（设置页刷新用；主线程）
    var onChange: (() -> Void)?

    // 对方连着本机（本机是被添加的那台）：/api/peer/watch 的订阅
    private var subscribers: [ObjectIdentifier: (stream: HTTPStream, src: String, peer: String)] = [:]
    private var lastHello: [String: Data] = [:]
    private var lastSnapshots: [String: Data] = [:]
    private var lastLink: [String: Data] = [:]
    private var heartbeat: DispatchSourceTimer?

    private var fileURL: URL { AppConfig.directoryURL.appendingPathComponent("peers.json") }

    private init() {
        if let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([PeerComputer].self, from: data) {
            peers = list
        }
    }

    // MARK: - 本机身份

    /// 这台电脑的编号：第一次用时生成，存在偏好里
    static var selfId: String {
        if let id = AppConfig.defaults.string(forKey: "computerId"), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        AppConfig.defaults.set(id, forKey: "computerId")
        return id
    }

    private static var cachedName: String?
    /// 这台电脑的名字（系统设置里的电脑名）
    static var selfName: String {
        if let name = cachedName { return name }
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespaces) ?? ""
        cachedName = name.isEmpty ? "电脑" : name
        return cachedName ?? "电脑"
    }

    /// 本机给别的电脑、手机连的地址（只给 HTTPS）
    static var selfAddresses: [String] {
        let mobile = AppState.shared.config.mobile
        guard mobile.enabled, mobile.httpsEnabled else { return [] }
        var seen = Set<String>()
        return PhoneAccess.addresses(port: mobile.port, publicURL: mobile.publicURL, httpsPort: mobile.effectiveHTTPSPort)
            .map(\.base).filter { seen.insert($0).inserted }
    }

    private static var selfCA: String? { LocalTLS.caDER?.base64EncodedString() }

    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 列表

    var all: [PeerComputer] {
        lock.lock(); defer { lock.unlock() }
        return peers
    }

    func peer(_ id: String?) -> PeerComputer? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        return peers.first { $0.id == id }
    }

    private func mutate(_ id: String, _ change: (inout PeerComputer) -> Void) {
        lock.lock()
        if let index = peers.firstIndex(where: { $0.id == id }) { change(&peers[index]) }
        lock.unlock()
        save()
    }

    private func save() {
        lock.lock()
        let list = peers
        lock.unlock()
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)   // 里面有令牌
    }

    /// 本机里代表「对方某个来源」的来源 id
    static func sourceId(peer: String, source: String) -> String {
        "\(sourcePrefix)\(peer.prefix(8)):\(source)"
    }

    /// 对方的来源 → 本机的来源配置（名字留空 = 自动起名，见 SourceConfig.displayName）
    static func sourceConfigs(_ peer: PeerComputer) -> [SourceConfig] {
        peer.sources.map { info in
            var config = SourceConfig(id: sourceId(peer: peer.id, source: info.id), name: "", kind: .kiteline)
            config.peerId = peer.id
            config.peerSource = info.id
            return config
        }
    }

    /// 来源的默认名字：对方本机就叫对方电脑名，对方连的远端叫「对方电脑名 · 远端名」
    func defaultName(_ config: SourceConfig) -> String {
        guard let peer = peer(config.peerId) else { return "Kiteline 电脑" }
        guard let info = peer.sources.first(where: { $0.id == config.peerSource }), info.kind != "local" else { return peer.name }
        return "\(peer.name) · \(info.name)"
    }

    func start() {
        guard refreshTimer == nil else { return }
        startHeartbeat()
        DispatchQueue.main.async { self.syncSources() }
        refreshAll()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refreshAll() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refreshAll() {
        for peer in all { refresh(peer.id) }
    }

    /// 问对方现在有哪些来源（顺带挑出能连的地址）：来源有变就同步本机的来源列表
    func refresh(_ id: String, completion: ((Bool) -> Void)? = nil) {
        guard let peer = peer(id) else { completion?(false); return }
        call(peer, "GET", "/api/peer/hello", timeout: 8) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply) where reply.status == 200:
                let json = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
                let list = (json["sources"] as? [[String: Any]] ?? []).compactMap { item -> PeerSourceInfo? in
                    guard let sid = item["id"] as? String, !sid.isEmpty else { return nil }
                    return PeerSourceInfo(id: sid, name: item["name"] as? String ?? sid, kind: item["kind"] as? String ?? "ssh", live: item["live"] as? Bool)
                }
                let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? peer.name
                let addresses = (json["addresses"] as? [String] ?? []).filter { $0.hasPrefix("https://") }
                var sourcesChanged = false
                self.mutate(id) { p in
                    sourcesChanged = p.sources.map(\.id) != list.map(\.id) || p.sources.map(\.name) != list.map(\.name) || p.name != name
                    p.sources = list
                    p.name = name
                    for address in addresses where !p.addresses.contains(address) { p.addresses.append(address) }
                }
                DispatchQueue.main.async {
                    self.problems[id] = nil
                    if sourcesChanged { self.syncSources() }
                    self.onChange?()
                    completion?(true)
                }
            case .success(let reply):
                let why = reply.status == 401 || reply.status == 403 ? "对方电脑已移除这台电脑，请重新添加" : "对方电脑返回 \(reply.status)"
                DispatchQueue.main.async { self.problems[id] = why; self.onChange?(); completion?(false) }
            case .failure(let error):
                DispatchQueue.main.async { self.problems[id] = error.description; self.onChange?(); completion?(false) }
            }
        }
    }

    /// 本机的来源列表跟上对方电脑的来源（只增删 kind = .kiteline 的，见 AppState.applyPeerSources）
    func syncSources() {
        let desired = all.flatMap(Self.sourceConfigs)
        AppState.shared.applyPeerSources(desired)
    }

    // MARK: - 添加（本机是发起的那台）

    /// 输地址 + 对方「手机访问」页上的 6 位验证码添加。fingerprint：局域网里找到的电脑（Bonjour）宣告的根证书指纹，有就核对
    func add(address raw: String, code: String, fingerprint: String?, completion: @escaping (Result<PeerComputer, RemoteError>) -> Void) {
        guard let base = Self.normalize(raw) else { completion(.failure(RemoteError("地址格式不对，请填 IP 或域名，例如 192.168.1.20"))); return }
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { completion(.failure(RemoteError("请输入对方电脑上显示的 6 位验证码"))); return }
        guard let myCA = Self.selfCA else { completion(.failure(RemoteError("本机证书尚未就绪，请确认「手机访问」已开启"))); return }
        // 先给对方在本机登记一个身份：配上之后对方也能把本机加成来源（双向）
        let (device, tokenForPeer) = DeviceStore.shared.register(agent: "Kiteline", ip: URL(string: base)?.host ?? "", via: "电脑互联", name: "Kiteline 电脑")
        DeviceStore.shared.setPeer(device.id, kind: "computer", peer: nil, ref: nil)
        let body: [String: Any] = [
            "code": digits, "name": Self.selfName,
            "computer": ["id": Self.selfId, "name": Self.selfName, "addresses": Self.selfAddresses, "ca": myCA, "token": tokenForPeer,
                         "port": AppState.shared.config.mobile.effectiveHTTPSPort],
        ]
        let trust = PeerTrust(anchorDER: nil)
        let session = URLSession(configuration: Self.configuration(timeout: 90), delegate: trust, delegateQueue: nil)
        guard let url = URL(string: base + "/pair") else { completion(.failure(RemoteError("地址格式不对"))); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.clientHeader, forHTTPHeaderField: "X-Kiteline-Client")
        Log.write("添加 Kiteline 电脑：向 \(base) 请求互联，等待对方电脑上确认")
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()
            let fail: (String) -> Void = { why in
                DeviceStore.shared.revoke(device.id)
                Log.write("添加 Kiteline 电脑失败（\(base)）：\(why)")
                DispatchQueue.main.async { completion(.failure(RemoteError(why))) }
            }
            if let error {
                let code = (error as NSError).code
                // 连不上多半是对方的防火墙拦着（Windows 第一次运行时关掉了系统的提示框）
                let hint = [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost].contains(code)
                    ? "。请确认那台电脑上 Kiteline 正在运行；若那台电脑开着防火墙，在它的「就绪检查」里点「防火墙放行 → 一键放行」" : ""
                fail(Self.describe(error) + hint); return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            guard status == 200, let token = json["token"] as? String, !token.isEmpty else {
                if status == 0 { fail("对方没有回应，请确认地址和端口"); return }
                fail(json["error"] as? String ?? "对方电脑返回 \(status)"); return
            }
            guard let info = json["computer"] as? [String: Any], let peerId = info["id"] as? String, !peerId.isEmpty else {
                fail("对方的 Kiteline 版本过旧，不支持电脑互联，请先在那台电脑上更新 Kiteline"); return
            }
            guard peerId != Self.selfId else { fail("不能添加本机"); return }
            // 对方报的根证书必须就是这次握手里那条证书链上的：中间有人冒充的话对不上
            guard let caText = info["ca"] as? String, let caDER = Data(base64Encoded: caText), trust.chain.contains(caDER) else {
                fail("对方电脑的证书与连接不符，已中止"); return
            }
            if let fingerprint, !fingerprint.isEmpty, Self.fingerprint(caDER) != fingerprint.lowercased() {
                fail("对方电脑的证书指纹与局域网中宣告的不一致，已中止"); return
            }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? "Kiteline 电脑"
            var addresses = [base]
            for address in info["addresses"] as? [String] ?? [] where address.hasPrefix("https://") && !addresses.contains(address) {
                addresses.append(address)
            }
            let peer = PeerComputer(id: peerId, name: name, addresses: addresses, token: token, ca: caText, deviceId: device.id,
                                    addedAt: Date().timeIntervalSince1970 * 1000)
            _ = DeviceStore.shared.rename(device.id, to: name)
            DeviceStore.shared.setPeer(device.id, kind: "computer", peer: peerId, ref: nil)
            DispatchQueue.main.async {
                self.store(peer, keepDevice: device.id)
                Log.write("已添加 Kiteline 电脑「\(name)」（\(base)）")
                completion(.success(peer))
                self.refresh(peerId)
            }
        }.resume()
    }

    /// 存一台对方电脑（同一台再加一次就换掉旧的：旧的令牌、旧的登记都作废）
    private func store(_ peer: PeerComputer, keepDevice: String?) {
        lock.lock()
        let old = peers.first { $0.id == peer.id }
        peers.removeAll { $0.id == peer.id }
        peers.append(peer)
        sessions.removeValue(forKey: peer.id)?.0.invalidateAndCancel()
        lock.unlock()
        save()
        if let oldDevice = old?.deviceId, oldDevice != keepDevice { DeviceStore.shared.revoke(oldDevice) }
        syncSources()
        onChange?()
    }

    /// 移除对方电脑：告诉对方一声（对方也删掉本机），作废互相给的令牌、替手机登记的设备，删掉它的来源。
    /// notify = false：是对方通知过来的，不用再回告
    func remove(_ id: String, notify: Bool = true) {
        guard let peer = peer(id) else { return }
        if notify { call(peer, "POST", "/api/peer/unlink", body: Data("{}".utf8), timeout: 6) { _ in } }
        lock.lock()
        peers.removeAll { $0.id == id }
        let session = sessions.removeValue(forKey: id)
        let theirs = subscribers.filter { $0.value.peer == id }.map(\.value.stream)
        lock.unlock()
        // 等 unlink 发出去再断：直接 invalidateAndCancel 会把刚发的请求也取消掉
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { session?.0.invalidateAndCancel() }
        theirs.forEach { $0.close() }
        save()
        if let deviceId = peer.deviceId { DeviceStore.shared.revoke(deviceId) }
        for device in DeviceStore.shared.all where device.peer == id && device.kind != "computer" { DeviceStore.shared.revoke(device.id) }
        DispatchQueue.main.async {
            self.problems[id] = nil
            self.syncSources()
            self.onChange?()
        }
        Log.write("已移除 Kiteline 电脑「\(peer.name)」")
    }

    /// 设备页里停用了一台电脑：同移除这台电脑
    func deviceRevoked(_ device: DeviceStore.Device) {
        guard device.kind == "computer", let peer = all.first(where: { $0.deviceId == device.id }) else { return }
        remove(peer.id)
    }

    // MARK: - 被添加（本机是对方连过来的那台）

    /// 对方电脑带着验证码来配对、本机点了允许：给它登记设备，存下它给本机的令牌（双向），回本机的身份
    func acceptPairing(_ request: HTTPRequest, computer info: [String: Any]) -> HTTPResponse {
        guard let peerId = info["id"] as? String, !peerId.isEmpty, peerId != Self.selfId else {
            return .error("不能添加本机", status: 400)
        }
        let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? "Kiteline 电脑"
        // 同一台电脑重新添加：旧的登记作废
        for device in DeviceStore.shared.all where device.kind == "computer" && device.peer == peerId { DeviceStore.shared.revoke(device.id) }
        let (device, token) = DeviceStore.shared.register(agent: request.headers["user-agent"] ?? "Kiteline", ip: request.remoteAddress,
                                                          via: "电脑互联", name: name)
        DeviceStore.shared.setPeer(device.id, kind: "computer", peer: peerId, ref: nil)
        if let theirToken = info["token"] as? String, !theirToken.isEmpty, let ca = info["ca"] as? String, Data(base64Encoded: ca) != nil {
            var addresses = (info["addresses"] as? [String] ?? []).filter { $0.hasPrefix("https://") }
            // 对方从哪个地址连过来的：也试一下（对方在公网、在别的网段时它报的局域网地址本机多半连不上）
            if let port = info["port"] as? Int, !DeviceStore.isLoopback(request.remoteAddress) {
                let host = request.remoteAddress.contains(":") ? "[\(request.remoteAddress)]" : request.remoteAddress
                let seen = "https://\(host):\(port)"
                if !addresses.contains(seen) { addresses.append(seen) }
            }
            let peer = PeerComputer(id: peerId, name: name, addresses: addresses, token: theirToken, ca: ca, deviceId: device.id,
                                    addedAt: Date().timeIntervalSince1970 * 1000)
            DispatchQueue.main.async {
                self.store(peer, keepDevice: device.id)
                self.refresh(peerId)
            }
        }
        Log.write("Kiteline 电脑「\(name)」（\(request.remoteAddress)）已添加这台电脑")
        return .json(["ok": true, "token": token, "deviceId": device.id,
                      "computer": ["id": Self.selfId, "name": Self.selfName, "addresses": Self.selfAddresses, "ca": Self.selfCA ?? ""]])
    }

    /// 只给对方电脑（kind = computer 的设备）用的接口：/api/peer/*。处理了返回 true（主线程调）
    func handle(_ request: HTTPRequest, device: DeviceStore.Device?, reply: @escaping (HTTPServer.Reply) -> Void,
                respond: @escaping (HTTPResponse) -> Void) -> Bool {
        guard request.path.hasPrefix("/api/peer/") else { return false }
        guard let device, device.kind == "computer", let peerId = device.peer else {
            respond(.error("只有互联的 Kiteline 电脑能用", status: 403)); return true
        }
        switch (request.method, request.path) {
        case ("GET", "/api/peer/hello"):
            respond(.json(["id": Self.selfId, "name": Self.selfName, "version": AppVersion.app, "addresses": Self.selfAddresses,
                           "sources": localSources()]))
        case ("GET", "/api/peer/watch"):
            let src = request.query["src"] ?? ""
            guard localSources().contains(where: { $0["id"] as? String == src }) else { respond(.error("没有这个来源", status: 404)); return true }
            reply(.stream(headers: ["Content-Type": "application/x-ndjson; charset=utf-8", "X-Accel-Buffering": "no"]) { [weak self] stream in
                self?.subscribe(stream, src: src, peer: peerId)
            })
        case ("POST", "/api/peer/rpc"):
            let src = request.query["src"] ?? ""
            guard let connection = AppState.shared.source(withId: src), connection.config.kind != .kiteline,
                  let payload = request.jsonBody else { respond(.error("没有这个来源", status: 404)); return true }
            let timeout = min(300, max(2, Double(request.headers["x-kiteline-timeout"] ?? "") ?? 30))
            connection.request(payload, timeout: timeout) { result in
                switch result {
                case .success(let raw): respond(.json(["ok": true, "response": raw]))
                case .failure(let error): respond(.json(["ok": false, "error": error.description], status: 502))
                }
            }
        case ("POST", "/api/peer/enroll"):
            // 对方电脑替绑在它上面的手机要一个本机的令牌：手机连不上它时直接连本机
            let body = request.jsonBody ?? [:]
            guard let phone = body["phone"] as? String, !phone.isEmpty else { respond(.error("缺少手机", status: 400)); return true }
            let ref = "\(peerId):\(phone)"
            for old in DeviceStore.shared.all where old.ref == ref { DeviceStore.shared.revoke(old.id) }
            let name = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "手机"
            let (enrolled, token) = DeviceStore.shared.register(agent: body["agent"] as? String ?? "", ip: request.remoteAddress,
                                                                via: "经电脑「\(device.name)」", name: name)
            DeviceStore.shared.setPeer(enrolled.id, kind: nil, peer: peerId, ref: ref)
            respond(.json(["ok": true, "token": token, "deviceId": enrolled.id, "id": Self.selfId, "name": Self.selfName,
                           "addresses": Self.selfAddresses, "ca": Self.selfCA ?? ""]))
        case ("POST", "/api/peer/enroll/revoke"):
            // 对方电脑停用了一台手机：替它登记的也作废
            if let phone = request.jsonBody?["phone"] as? String {
                for old in DeviceStore.shared.all where old.ref == "\(peerId):\(phone)" { DeviceStore.shared.revoke(old.id) }
            }
            respond(.json(["ok": true]))
        case ("POST", "/api/peer/unlink"):
            respond(.json(["ok": true]))
            if let peer = all.first(where: { $0.id == peerId }) {
                remove(peer.id, notify: false)
            } else {
                DeviceStore.shared.revoke(device.id)
                for other in DeviceStore.shared.all where other.peer == peerId && other.kind != "computer" { DeviceStore.shared.revoke(other.id) }
            }
        default:
            respond(.error("not found", status: 404))
        }
        return true
    }

    /// 本机自己的来源（不含别的电脑加进来的，免得两台互加时绕圈）
    private func localSources() -> [[String: Any]] {
        AppState.shared.config.sources.filter { $0.kind != .kiteline && $0.enabled }.map { source in
            let live = AppState.shared.source(withId: source.id)?.state.isLive ?? false
            return ["id": source.id, "name": source.displayName, "kind": source.kind.rawValue, "live": live]
        }
    }

    private func subscribe(_ stream: HTTPStream, src: String, peer: String) {
        let id = ObjectIdentifier(stream)
        lock.lock()
        subscribers[id] = (stream, src, peer)
        let replay = [lastLink[src], lastHello[src], lastSnapshots[src]].compactMap { $0 }
        lock.unlock()
        stream.onClose = { [weak self] in
            self?.lock.lock()
            self?.subscribers.removeValue(forKey: id)
            self?.lock.unlock()
        }
        replay.forEach { stream.send($0) }
        Log.write("Kiteline 电脑（\(stream.remoteAddress)）开始接收来源 \(src) 的会话")
    }

    /// 本机来源的 watcher 事件：照抄给连着的对方电脑（AppState.source(_:didReceive:) 调；任意线程）
    func tap(sourceId: String, kind: SourceKind, raw: [String: Any]) {
        guard kind != .kiteline else { return }
        lock.lock()
        let watching = subscribers.values.contains { $0.src == sourceId }
        let cache = ["hello", "snapshots"].contains(raw["event"] as? String ?? "")
        lock.unlock()
        guard watching || cache, var data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        data.append(0x0A)
        lock.lock()
        if raw["event"] as? String == "hello" { lastHello[sourceId] = data }
        if raw["event"] as? String == "snapshots" { lastSnapshots[sourceId] = data }
        let targets = subscribers.values.filter { $0.src == sourceId }.map(\.stream)
        lock.unlock()
        targets.forEach { $0.send(data) }
    }

    /// 本机来源连上 / 断开：告诉连着的对方电脑（对方据此显示在线 / 离线）
    func tap(sourceId: String, kind: SourceKind, state: LinkState) {
        guard kind != .kiteline else { return }
        var event: [String: Any] = ["event": "peer_link", "live": state.isLive]
        if case .failed(let reason) = state { event["reason"] = reason }
        guard var data = try? JSONSerialization.data(withJSONObject: event) else { return }
        data.append(0x0A)
        lock.lock()
        lastLink[sourceId] = data
        // 只在断了、停了时清：「连接中」和新进程的 hello 谁先到不一定（状态是异步换的），清了对方就再也等不到 hello
        switch state {
        case .failed, .stopped: lastHello[sourceId] = nil; lastSnapshots[sourceId] = nil
        default: break
        }
        let targets = subscribers.values.filter { $0.src == sourceId }.map(\.stream)
        lock.unlock()
        targets.forEach { $0.send(data) }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let beat = Data("{\"event\":\"heartbeat\"}\n".utf8)
            self.lock.lock()
            let all = self.subscribers.values.map(\.stream)
            self.lock.unlock()
            all.forEach { $0.send(beat) }
        }
        timer.resume()
        heartbeat = timer
    }

    /// 这台电脑现在连着本机（在收本机的会话）
    func isStreaming(_ peerId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return subscribers.values.contains { $0.peer == peerId }
    }

    /// 别的电脑替它的手机在本机登记的设备：那台电脑连着本机时，本机的提醒由那台电脑转推（它也收得到本机的会话），本机不再推，免得手机收两条
    func pushSuppressed() -> Set<String> {
        Set(DeviceStore.shared.all.filter { $0.kind != "computer" && $0.peer != nil && isStreaming($0.peer ?? "") }.map(\.id))
    }

    // MARK: - 手机：另一台电脑的地址和令牌

    /// GET /api/computers：绑在本机的手机问「还有哪些电脑能连」
    func computersPayload() -> [String: Any] {
        ["self": Self.selfId, "computers": all.map { peer -> [String: Any] in
            ["id": peer.id, "name": peer.name, "addresses": peer.addresses, "online": problems[peer.id] == nil,
             "fp": peer.ca.flatMap { Data(base64Encoded: $0) }.map(Self.fingerprint) ?? ""]
        }]
    }

    /// POST /api/computers/enroll {id}：替这台手机在对方电脑上登记，回对方的地址、证书、给手机的令牌
    func enroll(phone: DeviceStore.Device, computer id: String, respond: @escaping (HTTPResponse) -> Void) {
        guard let peer = peer(id) else { respond(.error("没有这台电脑", status: 404)); return }
        let body: [String: Any] = ["phone": phone.id, "name": phone.name, "agent": phone.agent]
        call(peer, "POST", "/api/peer/enroll", body: try? JSONSerialization.data(withJSONObject: body), timeout: 10) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply) where reply.status == 200:
                let json = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
                guard let token = json["token"] as? String else { respond(.error("对方电脑没有给出令牌", status: 502)); return }
                if let remoteId = json["deviceId"] as? String { self.mutate(id) { $0.enrolled[phone.id] = remoteId } }
                var addresses = self.peer(id)?.addresses ?? peer.addresses
                for address in json["addresses"] as? [String] ?? [] where address.hasPrefix("https://") && !addresses.contains(address) {
                    addresses.append(address)
                }
                Log.write("已替「\(phone.name)」在 Kiteline 电脑「\(peer.name)」上登记")
                respond(.json(["ok": true, "id": peer.id, "name": json["name"] as? String ?? peer.name, "addresses": addresses,
                               "ca": json["ca"] as? String ?? peer.ca ?? "", "token": token]))
            case .success(let reply):
                respond(.error("对方电脑返回 \(reply.status)", status: 502))
            case .failure(let error):
                respond(.error("连不上电脑「\(peer.name)」：\(error.description)", status: 502))
            }
        }
    }

    /// 本机停用了一台手机：它在别的电脑上的登记也作废
    func phoneRevoked(_ device: DeviceStore.Device) {
        for peer in all {
            guard let remote = peer.enrolled[device.id] else { continue }
            mutate(peer.id) { $0.enrolled[device.id] = nil }
            Log.write("「\(device.name)」已停用，作废它在电脑「\(peer.name)」上的登记（\(remote)）")
            call(peer, "POST", "/api/peer/enroll/revoke", body: try? JSONSerialization.data(withJSONObject: ["phone": device.id]), timeout: 6) { _ in }
        }
    }

    // MARK: - 转发（手机、主窗口对「对方电脑的会话」的操作，整条转给对方执行）

    /// 留在本机处理的接口：置顶、标记、静音、看过、待办、收藏、群、游客链接……都是本机自己的状态
    private static let localPaths: Set<String> = ["/api/pin", "/api/mark", "/api/mute", "/api/viewed", "/api/quiet", "/api/share", "/api/share/stop",
                                                  "/api/inbox", "/api/state", "/api/events", "/api/computers", "/api/computers/enroll"]
    private static let localPrefixes = ["/api/todos", "/api/favorites", "/api/groups", "/api/peer/", "/api/devices", "/api/push", "/api/live"]
    private static let keyFields = ["key", "k", "source", "sourceId", "sessionKey"]

    /// 本机自己发起的投递（会话群的消息、定时任务、闲置自动关闭……）落到对方电脑的会话上：交给那台电脑执行
    func deliver(_ path: String, record: SessionRecord, body: [String: Any], completion: @escaping (Delivery.Outcome) -> Void) {
        let finish: (Delivery.Outcome) -> Void = { outcome in DispatchQueue.main.async { completion(outcome) } }
        guard let source = AppState.shared.config.sources.first(where: { $0.id == record.sourceId }),
              let peer = peer(source.peerId), let remote = source.peerSource else {
            finish(Delivery.Outcome(ok: false, submitted: false, message: "这台电脑已移除")); return
        }
        let key = remote + "#" + record.snapshot.sessionId
        // 会话 key 只放在查询参数里（/api/key 的 body.key 是按哪个键）
        call(peer, "POST", path, query: ["key": key], body: try? JSONSerialization.data(withJSONObject: body), timeout: 120) { result in
            switch result {
            case .failure(let error):
                finish(Delivery.Outcome(ok: false, submitted: false, message: "连不上电脑「\(peer.name)」：\(error.description)"))
            case .success(let reply):
                let answer = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
                let ok = answer["ok"] as? Bool ?? (reply.status == 200)
                finish(Delivery.Outcome(ok: ok, submitted: answer["submitted"] as? Bool ?? false,
                                        message: answer["message"] as? String ?? answer["error"] as? String ?? ""))
            }
        }
    }

    /// 本机打开过对方电脑上的会话：告诉那台（它的「闲置自动关闭」按它算，见 IdleClose）
    func noteViewed(_ keys: [String]) {
        var byPeer: [String: [String]] = [:]
        for key in keys where key.hasPrefix(Self.sourcePrefix) {
            guard let hash = key.firstIndex(of: "#"),
                  let source = AppState.shared.config.sources.first(where: { $0.id == String(key[..<hash]) }),
                  let peerId = source.peerId, let remote = source.peerSource else { continue }
            byPeer[peerId, default: []].append(remote + key[hash...])
        }
        for (peerId, list) in byPeer {
            guard let peer = peer(peerId) else { continue }
            call(peer, "POST", "/api/viewed", body: try? JSONSerialization.data(withJSONObject: ["keys": list]), timeout: 10) { _ in }
        }
    }

    /// 这个请求是不是冲着对方电脑的会话 / 来源来的（主线程调）
    func forwardTarget(_ request: HTTPRequest) -> SourceConfig? {
        guard request.path.hasPrefix("/api/"), !Self.localPaths.contains(request.path),
              !Self.localPrefixes.contains(where: { request.path.hasPrefix($0) }) else { return nil }
        var values = Self.keyFields.compactMap { request.query[$0] }
        if request.headers["content-type"]?.contains("json") == true || request.body.first == UInt8(ascii: "{"),
           let body = request.jsonBody {
            values += Self.keyFields.compactMap { body[$0] as? String }
        }
        let candidates = values.filter { $0.hasPrefix(Self.sourcePrefix) }
        guard !candidates.isEmpty else { return nil }
        let sources = AppState.shared.config.sources.filter { $0.kind == .kiteline }
        for value in candidates {
            if let source = sources.first(where: { value == $0.id || value.hasPrefix($0.id + "#") }) { return source }
        }
        return nil
    }

    func forward(_ request: HTTPRequest, to source: SourceConfig, respond: @escaping (HTTPResponse) -> Void) {
        guard let peer = peer(source.peerId), let remoteSource = source.peerSource else {
            respond(.error("这台电脑已移除", status: 410)); return
        }
        let local = source.id
        func inward(_ value: String) -> String {
            if value == local { return remoteSource }
            if value.hasPrefix(local + "#") { return remoteSource + value.dropFirst(local.count) }
            return value
        }
        var query = request.query
        query.removeValue(forKey: "t")   // 本机的令牌别带过去
        for field in Self.keyFields { if let value = query[field] { query[field] = inward(value) } }
        var body = request.body
        if var json = request.jsonBody {
            for field in Self.keyFields { if let value = json[field] as? String { json[field] = inward(value) } }
            if let keys = json["keys"] as? [String] { json["keys"] = keys.map(inward) }
            body = (try? JSONSerialization.data(withJSONObject: json)) ?? body
        }
        var headers: [String: String] = [:]
        for name in ["content-type", "x-kiteline-lang", "x-kiteline-client"] { if let value = request.headers[name] { headers[name] = value } }
        let prefix = "\(Self.sourcePrefix)\(peer.id.prefix(8)):"
        let remoteIds = Set(peer.sources.map(\.id))
        call(peer, request.method, request.path, query: query, body: request.method == "GET" ? nil : body, headers: headers, timeout: 180) { result in
            switch result {
            case .failure(let error):
                respond(.error("连不上电脑「\(peer.name)」：\(error.description)", status: 502))
            case .success(let reply):
                var response = HTTPResponse(status: reply.status)
                for name in ["Content-Type", "Content-Disposition", "Cache-Control", "ETag", "Last-Modified"] {
                    if let value = reply.headers[name] { response.headers[name] = value }
                }
                var data = reply.body
                if reply.headers["Content-Type"]?.contains("json") == true,
                   let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    let mapped = Self.outward(object, prefix: prefix, remoteIds: remoteIds)
                    data = (try? JSONSerialization.data(withJSONObject: mapped, options: [.fragmentsAllowed])) ?? data
                }
                response.body = data
                respond(response)
            }
        }
    }

    /// 对方回的 JSON 里的会话 key、来源 id 换回本机的写法
    private static func outward(_ object: Any, prefix: String, remoteIds: Set<String>) -> Any {
        if let dict = object as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict {
                if keyFields.contains(key) || key == "from" || key == "to", let text = value as? String {
                    let head = text.split(separator: "#", maxSplits: 1).first.map(String.init) ?? text
                    out[key] = remoteIds.contains(head) ? prefix + text : text
                } else {
                    out[key] = outward(value, prefix: prefix, remoteIds: remoteIds)
                }
            }
            return out
        }
        if let list = object as? [Any] { return list.map { outward($0, prefix: prefix, remoteIds: remoteIds) } }
        return object
    }

    // MARK: - 连对方电脑

    static var clientHeader: String { "kiteline-mac/\(AppVersion.app)" }

    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 3600 * 24 * 365
        configuration.connectionProxyDictionary = [:]   // 电脑之间直连，不走系统代理
        configuration.waitsForConnectivity = false
        return configuration
    }

    private func session(for peer: PeerComputer) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let (session, _) = sessions[peer.id] { return session }
        let trust = PeerTrust(anchorDER: peer.ca.flatMap { Data(base64Encoded: $0) })
        let session = URLSession(configuration: Self.configuration(timeout: 75), delegate: trust, delegateQueue: nil)
        sessions[peer.id] = (session, trust)
        return session
    }

    private func trust(for peer: PeerComputer) -> PeerTrust? {
        _ = session(for: peer)
        lock.lock(); defer { lock.unlock() }
        return sessions[peer.id]?.1
    }

    private func makeRequest(_ base: String, _ peer: PeerComputer, _ method: String, _ path: String, query: [String: String],
                             body: Data?, headers: [String: String], timeout: TimeInterval) -> URLRequest? {
        guard var components = URLComponents(string: base + path) else { return nil }
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if body != nil, headers["content-type"] == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(peer.token, forHTTPHeaderField: "X-CCP-Token")
        if headers["x-kiteline-client"] == nil { request.setValue(Self.clientHeader, forHTTPHeaderField: "X-Kiteline-Client") }
        return request
    }

    typealias Reply = (status: Int, headers: [String: String], body: Data)

    /// 一问一答：按地址顺序试，连上的那个排到最前
    func call(_ peer: PeerComputer, _ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
              headers: [String: String] = [:], timeout: TimeInterval = 20, completion: @escaping (Result<Reply, RemoteError>) -> Void) {
        let session = session(for: peer)
        let addresses = peer.addresses
        var lastError = "没有可用的地址"
        func attempt(_ index: Int) {
            guard index < addresses.count else { completion(.failure(RemoteError(lastError))); return }
            guard let request = makeRequest(addresses[index], peer, method, path, query: query, body: body, headers: headers,
                                            timeout: index == 0 ? timeout : min(timeout, 8)) else { attempt(index + 1); return }
            session.dataTask(with: request) { [weak self] data, response, error in
                if let error {
                    lastError = Self.describe(error)
                    attempt(index + 1)
                    return
                }
                let http = response as? HTTPURLResponse
                var fields: [String: String] = [:]
                for (key, value) in http?.allHeaderFields ?? [:] {
                    if let key = key as? String, let value = value as? String { fields[Self.canonical(key)] = value }
                }
                if index > 0 { self?.promote(peer.id, addresses[index]) }
                completion(.success((http?.statusCode ?? 0, fields, data ?? Data())))
            }.resume()
        }
        attempt(0)
    }

    private static func canonical(_ name: String) -> String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: "-")
            .replacingOccurrences(of: "Etag", with: "ETag")
    }

    private func promote(_ id: String, _ address: String) {
        mutate(id) { peer in
            peer.addresses.removeAll { $0 == address }
            peer.addresses.insert(address, at: 0)
        }
    }

    /// 长连接（/api/peer/watch）：用第一个地址（refresh 已经把能连的排到最前）
    func stream(_ peer: PeerComputer, path: String, query: [String: String], onData: @escaping (Data) -> Void,
                onEnd: @escaping (String) -> Void) -> URLSessionDataTask? {
        let session = session(for: peer)
        guard let trust = trust(for: peer), let base = peer.addresses.first,
              let request = makeRequest(base, peer, "GET", path, query: query, body: nil, headers: [:], timeout: 60) else {
            onEnd("没有可用的地址"); return nil
        }
        let task = session.dataTask(with: request)
        trust.track(task, onData: onData, onEnd: onEnd)
        task.resume()
        return task
    }

    /// watcher 请求转给对方电脑上的那个来源
    func rpc(_ peer: PeerComputer, source: String, payload: [String: Any], timeout: TimeInterval,
             completion: @escaping (Result<[String: Any], RemoteError>) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            DispatchQueue.main.async { completion(.failure(RemoteError("请求无法编码"))) }; return
        }
        call(peer, "POST", "/api/peer/rpc", query: ["src": source], body: body, headers: ["x-kiteline-timeout": String(Int(timeout))],
             timeout: timeout + 10) { result in
            let outcome: Result<[String: Any], RemoteError>
            switch result {
            case .failure(let error): outcome = .failure(error)
            case .success(let reply):
                let json = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
                if json["ok"] as? Bool == true, let response = json["response"] as? [String: Any] {
                    outcome = .success(response)
                } else {
                    outcome = .failure(RemoteError(json["error"] as? String ?? "对方电脑返回 \(reply.status)"))
                }
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    static func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorTimedOut: return "连接超时"
        case NSURLErrorCannotConnectToHost: return "对方拒绝连接（Kiteline 没开，或端口不对）"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "找不到这个地址"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "网络不通"
        case NSURLErrorServerCertificateUntrusted, NSURLErrorCancelled, NSURLErrorSecureConnectionFailed: return "对方电脑的证书不对（可能不是原来那台电脑）"
        default: return error.localizedDescription
        }
    }

    /// 「192.168.1.20」「mac.local:8766」「https://x.example.com」→ https://主机:端口（默认 8766）
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("http://") { text = "https://" + text.dropFirst("http://".count) }
        if !text.hasPrefix("https://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        if components.port == nil { components.port = 8766 }
        components.path = ""
        components.query = nil
        return components.string
    }
}

// MARK: - 证书：只认对方的本机根证书

/// 对方电脑用的是它自己的本机根证书（LocalTLS）签的证书：之后只认添加时记下的那张根证书；
/// 不核对主机名（经公网 IP、域名、端口转发连过去时证书上没有那个名字）。第一次添加时先记下握手里的整条证书链，
/// 再和对方回的根证书核对（PeerComputers.add）。也管长连接的数据回调
final class PeerTrust: NSObject, URLSessionDataDelegate {
    private let anchor: SecCertificate?
    private let lock = NSLock()
    private var captured: [Data] = []
    private var handlers: [Int: (onData: (Data) -> Void, onEnd: (String) -> Void)] = [:]

    init(anchorDER: Data?) {
        anchor = anchorDER.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    var chain: [Data] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    func track(_ task: URLSessionTask, onData: @escaping (Data) -> Void, onEnd: @escaping (String) -> Void) {
        lock.lock()
        handlers[task.taskIdentifier] = (onData, onEnd)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        if let anchor {
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        let certificates = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        lock.lock()
        captured = certificates.map { SecCertificateCopyData($0) as Data }
        lock.unlock()
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            lock.lock()
            let handler = handlers.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            handler?.onEnd(status == 401 || status == 403 ? "对方电脑已移除这台电脑，请重新添加" : "对方电脑返回 \(status)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let handler = handlers[dataTask.taskIdentifier]
        lock.unlock()
        handler?.onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let handler = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        handler?.onEnd(error.map(PeerComputers.describe) ?? "连接已断开")
    }
}

// MARK: - 来源：对方电脑上的一个来源

/// 对方电脑上的一个来源（对方本机、对方连的远端）：watcher 事件经对方的 /api/peer/watch 原样过来，请求经 /api/peer/rpc 转过去。
/// 对方离线、这个来源在对方那边没连上时显示离线，隔一会儿重连
final class KitelineSource: SourceConnection {
    weak var delegate: SourceConnectionDelegate?
    let config: SourceConfig
    var id: String { config.id }
    private(set) var state: LinkState = .stopped
    private(set) var hostHome: String?
    let hostFeatures: Set<String> = []

    private var task: URLSessionDataTask?
    private var reader: WatcherLineReader?
    private var stopped = true
    private var attempt = 0
    private var generation = 0
    private var lastEventAt = Date()
    private var watchdog: Timer?

    init(config: SourceConfig) {
        self.config = config
    }

    private var peerName: String { PeerComputers.shared.peer(config.peerId)?.name ?? "Kiteline 电脑" }

    func start() {
        stopped = false
        attempt = 0
        connect()
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, !self.stopped, self.task != nil, Date().timeIntervalSince(self.lastEventAt) > 50 else { return }
            self.delegate?.source(self, didLog: "「\(self.peerName)」超过 50 秒没有消息，重连")
            self.task?.cancel()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func stop() {
        stopped = true
        generation += 1
        task?.cancel()
        task = nil
        watchdog?.invalidate()
        watchdog = nil
        update(.stopped)
    }

    func reload() {}

    private func connect() {
        guard !stopped else { return }
        guard let peer = PeerComputers.shared.peer(config.peerId), let remote = config.peerSource else {
            update(.failed(reason: "这台电脑已移除")); return
        }
        generation += 1
        let current = generation
        if !state.isLive { update(.connecting) }
        // 先问一下对方（顺带挑出能连的地址），再接长连接
        PeerComputers.shared.refresh(peer.id) { [weak self] ok in
            guard let self, !self.stopped, current == self.generation else { return }
            guard ok, let fresh = PeerComputers.shared.peer(self.config.peerId) else {
                self.retry(PeerComputers.shared.problems[peer.id] ?? "连不上「\(peer.name)」")
                return
            }
            let reader = WatcherLineReader(onEvent: { [weak self] event in
                DispatchQueue.main.async { if current == self?.generation { self?.handle(event) } }
            }, onGarbage: { _ in })
            self.reader = reader
            self.lastEventAt = Date()
            self.task = PeerComputers.shared.stream(fresh, path: "/api/peer/watch", query: ["src": remote], onData: { data in
                reader.feed(data)
            }, onEnd: { [weak self] why in
                DispatchQueue.main.async {
                    guard let self, current == self.generation, !self.stopped else { return }
                    self.task = nil
                    self.retry(why)
                }
            })
        }
    }

    private func retry(_ reason: String) {
        guard !stopped else { return }
        attempt += 1
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
        update(.failed(reason: reason))
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, current == self.generation else { return }
            self.connect()
        }
    }

    private func handle(_ event: WatcherEvent) {
        lastEventAt = Date()
        switch event.kind {
        case "peer_link":
            if event.raw["live"] as? Bool != true {
                let reason = (event.raw["reason"] as? String).map { "对方电脑上未连接：\($0)" } ?? "对方电脑上未连接"
                update(.failed(reason: reason))
                delegate?.source(self, didReceive: WatcherEvent(json: ["event": "snapshots", "sessions": []])!)
            }
            return
        case "heartbeat":
            if !state.isLive, hostHome != nil { update(.live(host: peerName, watcher: nil, sessionCount: 0)) }
            return
        case "hello":
            attempt = 0
            if let home = event.raw["home"] as? String { hostHome = home }
            // 对方本机的 watcher 报的主机名多半就是电脑名：一样就只写一遍
            let host = event.host.flatMap { $0 == peerName || peerName.hasPrefix($0.replacingOccurrences(of: ".local", with: "")) ? nil : $0 }
            update(.live(host: host.map { "\(peerName) · \($0)" } ?? peerName, watcher: event.watcherVersion, sessionCount: 0))
            delegate?.source(self, didLog: "已连上 Kiteline 电脑「\(peerName)」的来源 \(config.peerSource ?? "")")
        case "snapshots":
            if case .live(let host, let watcher, let count) = state {
                if count != event.sessions.count { update(.live(host: host, watcher: watcher, sessionCount: event.sessions.count)) }
            } else {
                update(.live(host: peerName, watcher: nil, sessionCount: event.sessions.count))   // 没等到 hello 也算连上了
            }
        default:
            break
        }
        delegate?.source(self, didReceive: event)
    }

    /// 那台电脑自己管它的 watcher（技能开关、agent 待办、会话群名单）：本机推的这些不转过去，免得两台互相覆盖
    private static let ownedByPeer: Set<String> = ["skills", "todos", "groups"]

    func request(_ payload: [String: Any], timeout: TimeInterval, completion: @escaping (Result<[String: Any], RemoteError>) -> Void) {
        if let cmd = payload["cmd"] as? String, Self.ownedByPeer.contains(cmd) {
            DispatchQueue.main.async { completion(.success(["ok": true, "skipped": true])) }; return
        }
        guard let peer = PeerComputers.shared.peer(config.peerId), let remote = config.peerSource else {
            DispatchQueue.main.async { completion(.failure(RemoteError("这台电脑已移除"))) }; return
        }
        PeerComputers.shared.rpc(peer, source: remote, payload: payload, timeout: timeout, completion: completion)
    }

    private func update(_ newState: LinkState) {
        DispatchQueue.main.async {
            guard self.state != newState else { return }
            self.state = newState
            self.delegate?.source(self, didChange: newState)
        }
    }
}

// MARK: - 局域网里找装了 Kiteline 的电脑

/// 「添加 Kiteline 电脑」里列出局域网中的电脑（Bonjour _tars._tcp，role = mac；Windows / Linux 版宣告的也是这个），不列本机
final class PeerFinder: ObservableObject {
    struct Found: Identifiable, Hashable {
        var name: String
        var fingerprint: String?
        var endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var found: [Found] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let mine = LocalTLS.caFingerprint
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_tars._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { result -> Found? in
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let txt) = result.metadata, txt["role"] == "mac" else { return nil }
                if let fp = txt["fp"], fp == mine { return nil }
                return Found(name: name, fingerprint: txt["fp"], endpoint: result.endpoint)
            }
            DispatchQueue.main.async { self?.found = list.sorted { $0.name < $1.name } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Bonjour 名字 → https://IP:端口（连一下看实际连到的地址；只要 IPv4）
    func address(of item: Found, completion: @escaping (String?) -> Void) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: item.endpoint, using: parameters)
        var done = false
        let finish: (String?) -> Void = { value in
            guard !done else { return }
            done = true
            connection.cancel()
            completion(value)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint else { finish(nil); return }
                let text: String
                switch host {
                case .ipv4(let ip): text = "\(ip)".components(separatedBy: "%").first ?? "\(ip)"
                case .name(let name, _): text = name
                default: text = "\(host)"
                }
                finish("https://\(text):\(port.rawValue)")
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(nil) }
    }
}

/// 别的电脑用本机的验证码请求互联：一律在本机问一句（60 秒没点算拒绝），问完把前台还回去
enum PeerPrompt {
    static func ask(name: String, address: String) -> Bool {
        // 自测：测试实例不在屏幕上弹框，按环境变量答
        if Delivery.dryRun, let answer = ProcessInfo.processInfo.environment["KITELINE_TEST_PEER_ALLOW"] { return answer == "1" }
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("是否允许电脑「%@」与这台电脑互联？", name)
        alert.informativeText = L("「%@」（%@）正在用这台电脑上显示的验证码请求互联。允许后，它可以查看并操作这台电脑上的会话，这台电脑也会把它加为来源；绑定在任意一台上的手机，两台电脑中有一台在线即可连接。\n\n如果不是你本人正在那台电脑上操作，请点「拒绝」。", name, address)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("拒绝"))
        alert.addButton(withTitle: L("允许"))
        let timer = Timer(timeInterval: 60, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let result = alert.runModal()
        timer.invalidate()
        if let previous, previous != NSRunningApplication.current { previous.activate() }
        return result == .alertSecondButtonReturn
    }
}
