import AppKit
import KitelineKit

/// 对话里 agent 的头像和昵称（用户在「Agent 详情」里改的）：存在电脑上（配置目录 agent-faces.json，上传的图在 agent-avatars/），
/// 手机、iPad、Mac 主窗口连同一台电脑即同步。两层：某个会话自己的（按会话 key）、某家 agent 所有会话默认的（按 agent id），会话自己的优先。
/// avatar 的写法（各端自己画，不传图）：
///   mark:<agentId|kite>:<底色>   某家 agent 的标志（kite = 纸鸢）放在一种底色上
///   emoji:<表情>:<底色>          一个表情
///   text:<底色>                  昵称首字
///   image:<id>                   上传的图（GET /api/agent-avatar?id= 取，id 随内容变，可长期缓存）
/// 底色见 KitelineKit/Views/AgentDetails.swift 的 FaceTone；空 = 用默认（agent 自己的标志）。
///
///   POST /api/agent-face   {key?, agent, scope: session|agent, name, avatar | image(base64)}；name、avatar 都空 = 恢复默认
///   GET  /api/agent-avatar?id=
///   GET  /api/agent-info?key=&agent=   Agent 详情：会话、插件、所在机器
///   GET  /api/machine?source=          设备详情：系统、CPU、内存、IP、装了哪些 agent
final class AgentFaces {
    struct Face: Codable, Equatable {
        var name: String
        var avatar: String
        /// 改的时间（毫秒）：会话的条目太多时先删最久没改的
        var at: Double

        var payload: [String: Any] { ["name": name, "avatar": avatar] }
    }

    private struct Store: Codable {
        var sessions: [String: Face] = [:]
        var agents: [String: Face] = [:]
    }

    static let shared = AgentFaces()
    private static let sessionLimit = 500

    private let lock = NSLock()
    private var store = Store()
    private let saveQueue = DispatchQueue(label: "tars.agentfaces.save")
    private var url: URL { AppConfig.directoryURL.appendingPathComponent("agent-faces.json") }
    private var imageDir: URL { AppConfig.directoryURL.appendingPathComponent("agent-avatars", isDirectory: true) }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        }
    }

    /// 放进 /api/state 的 faces：{sessions: {key: {name, avatar}}, agents: {agentId: {name, avatar}}}
    var payload: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["sessions": store.sessions.mapValues(\.payload), "agents": store.agents.mapValues(\.payload)]
    }

    /// 某个会话现在用的（会话自己的 → 这家 agent 默认的）；Mac 侧栏画头像用
    func face(key: String, agent: String) -> Face? {
        lock.lock(); defer { lock.unlock() }
        return store.sessions[key] ?? store.agents[agent]
    }

    private func entries(key: String, agent: String) -> (session: Face?, agent: Face?) {
        lock.lock(); defer { lock.unlock() }
        return (store.sessions[key], store.agents[agent])
    }

    // MARK: - 接口

    func save(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.jsonBody ?? [:]
        let key = (body["key"] as? String) ?? ""
        let agent = ((body["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? "claude-code"
        let scope = (body["scope"] as? String) == "agent" ? "agent" : "session"
        guard scope == "agent" || !key.isEmpty else { return .error("缺少会话 key", status: 400) }
        guard agent.count <= 60 else { return .error("agent 不对", status: 400) }
        let name = Profile.cleanName(body["name"] as? String ?? "")
        var avatar = (body["avatar"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if let image = body["image"] as? String, !image.isEmpty {
            let base64 = image.range(of: "base64,").map { String(image[$0.upperBound...]) } ?? image
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), let id = saveImage(data) else {
                return .error("无法打开此图片，请选择其他图片", status: 400)
            }
            avatar = "image:\(id)"
        }
        guard avatar.isEmpty || Self.isValid(avatar) else { return .error("头像格式不对", status: 400) }
        let face = name.isEmpty && avatar.isEmpty ? nil : Face(name: name, avatar: avatar, at: (Date().timeIntervalSince1970 * 1000).rounded())
        mutate { store in
            if scope == "agent" {
                store.agents[agent] = face
                // 「用于所有会话」：这个会话跟着默认走，不再留自己的
                if !key.isEmpty { store.sessions[key] = nil }
            } else {
                store.sessions[key] = face
            }
            if store.sessions.count > Self.sessionLimit {
                for old in store.sessions.sorted(by: { $0.value.at < $1.value.at }).prefix(store.sessions.count - Self.sessionLimit) {
                    store.sessions[old.key] = nil
                }
            }
        }
        var reply = payload
        reply["ok"] = true
        return .json(reply)
    }

    func image(_ request: HTTPRequest) -> HTTPResponse {
        guard let id = request.query["id"], Self.validImageId(id),
              let data = try? Data(contentsOf: imageDir.appendingPathComponent("\(id).jpg")) else {
            return .error("头像不存在", status: 404)
        }
        return Thumbnail.reply(data, mime: "image/jpeg", request: request, cacheKey: "agent-avatar|\(id)")
    }

    // MARK: - 存取

    private func mutate(_ change: (inout Store) -> Void) {
        lock.lock()
        change(&store)
        let snapshot = store
        lock.unlock()
        let used = Set((Array(snapshot.sessions.values) + Array(snapshot.agents.values)).compactMap { face in
            face.avatar.hasPrefix("image:") ? String(face.avatar.dropFirst(6)) : nil
        })
        let file = url, dir = imageDir
        saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            // 没人用的上传图删掉
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".jpg") {
                if !used.contains(String(name.dropLast(4))) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
            }
        }
        DispatchQueue.main.async {
            AppState.shared.mobile.publishState()
            KitelineModel.shared.refresh()
        }
    }

    /// 上传的图：居中裁成 256×256 JPEG，按内容起名（同一张图传两次是同一个文件）
    private func saveImage(_ data: Data) -> String? {
        guard data.count <= 20 * 1024 * 1024, let image = NSImage(data: data), let jpeg = Profile.squareJPEG(image, side: 256) else { return nil }
        let id = Profile.fingerprint(jpeg)
        do {
            try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
            try jpeg.write(to: imageDir.appendingPathComponent("\(id).jpg"), options: .atomic)
        } catch { return nil }
        return id
    }

    static func validImageId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 16 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func isValid(_ avatar: String) -> Bool {
        let parts = avatar.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func tone(_ value: String) -> Bool { !value.isEmpty && value.count <= 12 && value.allSatisfy { $0.isASCII && $0.isLowercase } }
        switch parts.first {
        case "mark":
            return parts.count == 3 && !parts[1].isEmpty && parts[1].count <= 60 && tone(parts[2])
        case "emoji":
            return parts.count == 3 && !parts[1].isEmpty && parts[1].count <= 2 && parts[1].unicodeScalars.count <= 12 && tone(parts[2])
        case "text":
            return parts.count == 2 && tone(parts[1])
        case "image":
            return parts.count == 2 && validImageId(parts[1])
        default:
            return false
        }
    }
}

// MARK: - 设备详情、Agent 详情

extension AgentFaces {
    /// 设备详情：来源的配置和连接状态 + 那台机器的 watcher 报的系统信息（machine_info）+ 现在的 CPU、内存 + 装了哪些 agent。
    /// 机器离线、watcher 太旧（没有 machine_info）时只给知道的那部分
    static func machine(_ sourceId: String, completion: @escaping ([String: Any]) -> Void) {
        let state = AppState.shared
        guard let config = state.config.sources.first(where: { $0.id == sourceId }) else {
            completion(["ok": false, "error": "未知的设备"]); return
        }
        let connection = state.source(withId: sourceId)
        let link = connection?.state ?? .stopped
        let records = state.store.records.filter { $0.sourceId == sourceId }
        var out: [String: Any] = [
            "ok": true, "id": config.id, "name": config.displayName, "kind": config.kind.rawValue,
            "online": link.isLive, "status": link.shortLabel, "enabled": config.enabled,
            "sessions": records.count,
            "busy": records.filter { $0.snapshot.act == .busy || $0.snapshot.act == .waiting }.count,
        ]
        if config.kind == .local { out["computer"] = Host.current().localizedName ?? "" }
        if let host = config.sshHost, !host.isEmpty { out["sshHost"] = host + (config.sshPort.map { ":\($0)" } ?? "") }
        if case .live(_, let watcher, _) = link, let watcher { out["watcher"] = watcher }
        if let stats = state.machineStats[sourceId] { out["stats"] = stats }
        guard let connection, link.isLive else { completion(out); return }
        let group = DispatchGroup()
        group.enter()
        connection.request(["cmd": "machine_info"], timeout: 10) { result in
            switch result {
            case .success(var info):
                info.removeValue(forKey: "event"); info.removeValue(forKey: "id")
                out["info"] = info
            case .failure(let error):
                // 旧版 watcher 回「未知请求」：outdated（各端说「组件版本较旧」），别的是 failed + 原因
                out["infoError"] = error.description.contains("未知请求") ? "outdated" : "failed"
                out["detail"] = error.description
            }
            group.leave()
        }
        group.enter()
        connection.request(["cmd": "plugins"], timeout: 10) { result in
            if case .success(let reply) = result {
                out["agents"] = (reply["plugins"] as? [[String: Any]] ?? []).compactMap { row -> [String: Any]? in
                    guard let id = row["id"] as? String else { return nil }
                    let detect = row["detect"] as? [String: Any]
                    var item: [String: Any] = ["id": id, "name": row["name"] as? String ?? id,
                                               "installed": (detect?["installed"] as? Bool) == true]
                    if let version = row["version"] { item["plugin"] = "\(version)" }
                    if let source = row["source"] as? String { item["source"] = source }
                    if let status = row["status"] as? String { item["state"] = status }
                    if let forms = detect?["forms"] as? [String: Any], !forms.isEmpty { item["forms"] = forms.mapValues { "\($0)" } }
                    if let abilities = row["abilities"] as? [String] { item["abilities"] = abilities }
                    return item
                }
            }
            group.leave()
        }
        group.notify(queue: .main) {
            // Claude Code 不是插件（watcher 自带），machine_info 单独报它装了哪些形态：排在最前
            if let claude = (out["info"] as? [String: Any])?["claude"] as? [String: Any] {
                var row: [String: Any] = ["id": "claude-code", "name": "Claude Code", "installed": true, "source": "builtin",
                                          "abilities": ["view", "reply", "approve", "answer"]]
                if let watcher = (out["info"] as? [String: Any])?["watcher"] { row["plugin"] = "\(watcher)" }
                if let forms = claude["forms"] as? [String: Any], !forms.isEmpty { row["forms"] = forms.mapValues { "\($0)" } }
                out["agents"] = [row] + (out["agents"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != "claude-code" }
            }
            completion(out)
        }
    }

    /// Agent 详情：头像昵称（会话自己的、这家 agent 默认的）+ 会话（前端、版本、进程、目录、模型）+ 插件 + 所在机器
    static func agentInfo(key: String, agentHint: String?, completion: @escaping ([String: Any]) -> Void) {
        let state = AppState.shared
        let record = state.store.record(withKey: key)
        let sourceId = record?.sourceId ?? String(key.split(separator: "#", maxSplits: 1).first ?? "")
        let agent = record?.snapshot.agentID ?? agentHint.flatMap { $0.isEmpty ? nil : $0 } ?? "claude-code"
        let faces = shared.entries(key: key, agent: agent)
        var out: [String: Any] = ["ok": true, "key": key, "agent": agent, "sourceId": sourceId, "live": record != nil]
        if let face = faces.session { out["face"] = face.payload }
        if let face = faces.agent { out["agentFace"] = face.payload }
        if let record {
            let snap = record.snapshot
            out["title"] = snap.displayTitle
            out["sessionId"] = snap.sessionId
            out["cwd"] = snap.cwd
            out["entrypoint"] = snap.entrypoint ?? ""
            if let kind = snap.sessionKind { out["sessionKind"] = kind }
            if snap.tmuxPane != nil { out["tmux"] = true }
            if let version = snap.version, !version.isEmpty { out["version"] = version }
            if let pid = snap.pid { out["pid"] = pid }
            if let started = snap.startedAt { out["startedAt"] = started }
            if let model = snap.usage?.model { out["model"] = model }
            if snap.readOnly == true { out["readOnly"] = true }
        }
        machine(sourceId) { machine in
            var out = out
            out["machine"] = machine
            if let plugin = (machine["agents"] as? [[String: Any]])?.first(where: { $0["id"] as? String == agent }) { out["plugin"] = plugin }
            completion(out)
        }
    }
}
