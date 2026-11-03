import Foundation

/// 游客链接（局域网）：把一个会话分享成只读网址 http://<这台电脑的局域网 IP>:<端口>/g/<编号>，
/// 同一网络（Wi-Fi）里的人用浏览器打开就能看，不用装 Kiteline。
///
/// 页面（Resources/guest/index.html）和内容都由这台电脑直接给，不经过任何服务器（11-03 起：中继不提供内容展示）；
/// 电脑关机、离开这个网络，链接就打不开。每次打开、刷新（页面 8 秒取一次，没变回 304）现取会话最近的记录生成快照：
/// 只放对话文字和步骤（工具名 + 一句说明），不放思考过程、图片、关键信息（agent 发的密码、地址这类）。
/// 编号是 16 字节随机数，到期或「停止分享」后链接失效。
///
/// 手机访问的明文 HTTP 只开本机（局域网只走 HTTPS，自签证书会让同事的浏览器报「不是私密连接」），
/// 所以有分享时另开一个只给游客页面用的端口（手机端口 + 2，默认 8767），监听局域网、只认 /g/ 下的路径，没有分享就关掉
final class GuestLinks {
    static let shared = GuestLinks()

    struct Share: Codable {
        var id: String
        var sessionKey: String
        /// 会话结束后快照里还用这个标题
        var title: String
        /// 到期时间（秒）
        var expires: Double
        var created: Double
    }

    static let hourChoices = [1, 24, 168]

    private var shares: [Share] = []
    /// 编号 → 上次生成的快照（会话没变就直接给，免得每个看的人每 8 秒都去机器上取一次记录）
    private var cache: [String: (mark: String, body: Data)] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "kiteline.guest")
    /// 游客端口（有分享时开着）
    private var listener: HTTPServer?
    private var listenerPort = 0
    private static var fileURL: URL { AppConfig.directoryURL.appendingPathComponent("guest-links.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode([Share].self, from: data) {
            shares = saved.filter { $0.expires > Date().timeIntervalSince1970 }
        }
        DispatchQueue.main.async { self.syncListener() }
    }

    /// 游客端口：手机端口 + 2（HTTPS 是 + 1）
    static var port: Int { AppState.shared.mobile.config.port + 2 }

    /// 局域网网址：这台电脑的局域网 IP（没有就用 Bonjour 名称）+ 游客端口
    static func url(_ share: Share) -> String {
        let net = NetworkInfo.current()
        let host = net.lan.first ?? net.names.first ?? "127.0.0.1"
        return "http://\(host):\(port)/g/\(share.id)"
    }

    static func payload(_ share: Share) -> [String: Any] {
        ["id": share.id, "url": url(share), "expires": share.expires, "created": share.created, "key": share.sessionKey]
    }

    /// 有分享就开着游客端口、没有就关（端口设置改了换新的）。主线程调
    func syncListener() {
        let active = !list(sessionKey: nil).isEmpty
        let port = Self.port
        if !active || listenerPort != port {
            listener?.stop()
            listener = nil
            listenerPort = 0
        }
        guard active, listener == nil else { return }
        let host = AppState.shared.mobile.config.bindAddress
        let server = HTTPServer(host: host, port: UInt16(clamping: port)) { [weak self] request, reply in
            guard request.method == "GET", request.path.hasPrefix("/g/"), let self else { reply(.response(.text("not found", status: 404))); return }
            self.serve(request) { reply(.response($0)) }
        }
        do {
            try server.start()
            listener = server
            listenerPort = port
            Log.write("游客链接端口监听 \(host):\(port)")
        } catch {
            Log.write("游客链接端口启动失败（\(port)）：\(error)")
        }
    }

    // MARK: - 接口（MobileServer：GET /api/share、POST /api/share、POST /api/share/stop）

    /// 这个会话正在分享的链接（没给 key 就列全部）
    func list(sessionKey: String?) -> [Share] {
        lock.withLock {
            pruneLocked()
            return shares.filter { sessionKey == nil || $0.sessionKey == sessionKey }
        }
    }

    func create(sessionKey: String, hours: Int) -> Share? {
        guard Self.hourChoices.contains(hours) else { return nil }
        let now = Date().timeIntervalSince1970
        let share = Share(id: Self.randomID(), sessionKey: sessionKey,
                          title: AppState.shared.store.record(withKey: sessionKey)?.snapshot.displayTitle ?? "",
                          expires: now + Double(hours) * 3600, created: now)
        lock.withLock {
            shares.append(share)
            saveLocked()
        }
        DispatchQueue.main.async { self.syncListener() }
        Log.write("开始在局域网分享会话「\(share.title)」的只读网址（\(hours) 小时）")
        return share
    }

    /// 停止分享：链接马上失效
    func stop(id: String) {
        lock.withLock {
            guard let share = shares.first(where: { $0.id == id }) else { return }
            shares.removeAll { $0.id == id }
            cache[id] = nil
            saveLocked()
            Log.write("已停止分享会话「\(share.title)」的只读网址")
        }
        DispatchQueue.main.async { self.syncListener() }
    }

    // MARK: - 看的人（GET /g/<编号> 页面、GET /g/api/<编号> 内容；不要令牌）

    func serve(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let parts = request.path.split(separator: "/").map(String.init)   // ["g", 编号] 或 ["g", "api", 编号]
        if parts.count == 2 {
            respond(Self.page())
            return
        }
        guard parts.count == 3, parts[1] == "api" else { respond(.text("not found", status: 404)); return }
        let id = parts[2]
        guard let share = lock.withLock({ () -> Share? in pruneLocked(); return shares.first { $0.id == id } }) else {
            respond(Self.json(["ok": false, "error": "链接已失效"], status: 404))
            return
        }
        let record = AppState.shared.store.record(withKey: share.sessionKey)
        let snap = record?.snapshot
        let mark = snap.map { "\($0.act.rawValue)|\(Int64($0.transcriptUpdatedAt ?? $0.statusUpdatedAt ?? $0.updatedAt ?? 0))|\($0.displayTitle)" } ?? "ended"
        let etag = "\"\(String(UInt64(bitPattern: Int64(mark.hashValue)), radix: 36))\""
        if request.headers["if-none-match"] == etag {
            respond(HTTPResponse(status: 304, headers: ["ETag": etag, "Cache-Control": "no-store", "X-Share-Expires": String(Int64(share.expires))]))
            return
        }
        if let cached = lock.withLock({ cache[id] }), cached.mark == mark {
            respond(Self.snapshotResponse(cached.body, etag: etag, expires: share.expires))
            return
        }
        AppState.shared.mobile.historyItems(key: share.sessionKey, limit: 150) { [weak self] items, more in
            guard let self else { return }
            guard let items else {
                respond(Self.json(["ok": false, "error": "取不到这个会话的记录（所在电脑可能离线）"], status: 502))
                return
            }
            let body = (try? JSONSerialization.data(withJSONObject: Self.snapshot(share: share, record: record, items: items, more: more))) ?? Data("{}".utf8)
            self.lock.withLock { self.cache[id] = (mark, body) }
            respond(Self.snapshotResponse(body, etag: etag, expires: share.expires))
        }
    }

    private static func snapshotResponse(_ body: Data, etag: String, expires: Double) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "ETag": etag,
                                            "X-Share-Expires": String(Int64(expires)), "X-Content-Type-Options": "nosniff"], body: body)
    }

    private static func json(_ object: [String: Any], status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                     body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    /// 看的页面：只连这台电脑，不让别的网站嵌进去，不带来源
    private static func page() -> HTTPResponse {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "guest"),
              let data = try? Data(contentsOf: url) else { return .text("not found", status: 404) }
        return HTTPResponse(status: 200, headers: [
            "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache", "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex, nofollow",
        ], body: data)
    }

    /// 快照：标题、状态、项目名、agent、最近的对话（u 你说的 / a 回复 / s 步骤 / p 网页 / i 图片张数）
    static func snapshot(share: Share, record: SessionRecord?, items: [[String: Any]], more: Bool) -> [String: Any] {
        func clip(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }
        var rows: [[String: Any]] = []
        for item in items {
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var row: [String: Any] = [:]
            switch item["t"] as? String {
            case "user" where !text.isEmpty: row = ["r": "u", "x": clip(text, 8000)]
            case "text" where !text.isEmpty: row = ["r": "a", "x": clip(text, 8000)]
            case "tool":
                let name = item["name"] as? String ?? ""
                guard !name.isEmpty, name != "TodoWrite" else { continue }
                let brief = (item["brief"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                row = ["r": "s", "x": clip(brief.isEmpty ? name : "\(name) · \(brief)", 120)]
            case "agent_page": row = ["r": "p", "x": clip(item["title"] as? String ?? "", 80)]
            case "agent_image": row = ["r": "i", "n": (item["images"] as? [Any])?.count ?? 1]
            default: continue
            }
            if let ts = item["ts"] { row["ts"] = ts }
            rows.append(row)
        }
        let agent = record?.snapshot.agentID ?? ""
        let agentNames = ["claude-code": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "cursor": "Cursor",
                          "qwen": "Qwen Code", "dsh": "DeepSeek Harness", "proma": "Proma"]
        var out: [String: Any] = ["v": 1, "title": record?.snapshot.displayTitle ?? share.title, "items": rows, "more": more,
                                  "status": record.map { ["busy", "waiting"].contains($0.snapshot.act.rawValue) ? $0.snapshot.act.rawValue : "idle" } ?? "idle",
                                  "updatedAt": Date().timeIntervalSince1970 * 1000]
        if let cwd = record?.snapshot.cwd, !cwd.isEmpty { out["project"] = (cwd as NSString).lastPathComponent }
        if !agent.isEmpty { out["agent"] = agentNames[agent] ?? agent }
        return out
    }

    // MARK: - 小工具（调用方持锁的带 Locked）

    private func pruneLocked() {
        let now = Date().timeIntervalSince1970
        let before = shares.count
        shares.removeAll { $0.expires <= now }
        if shares.count != before {
            cache = cache.filter { entry in shares.contains { $0.id == entry.key } }
            saveLocked()
        }
    }

    private func saveLocked() {
        let snapshot = shares
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        }
    }

    /// 22 位编号（16 字节随机数，base64url）
    static func randomID() -> String {
        var data = Data(count: 16)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
