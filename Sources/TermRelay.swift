import Foundation

/// 会话终端的归属和设备名，以及 agent 的 `term run`（在会话终端里跑命令，不在桌面另开终端窗口）。
///
/// - 终端开在哪台电脑上，标签上就写哪台电脑的名字（本机写电脑名，远端写来源名），手机和电脑上一眼分得清。
/// - `term run --on <设备>`：会话在 A 电脑、命令要在 B 电脑上跑（典型：虚拟机上的会话要在 Mac 的桌面会话里签名打包）。
///   A 的 watcher 发 term_run → 这里请 B 的 watcher 开终端（会话 id 用 A 上那个）→ B 的输出、退出码按事件里的 relay 转回 A
///   （term_run_feed），A 上等着的子命令原样打出来。B 上开的这个终端显示在 A 会话的终端面板里（foreign 记着它实际在哪台）。
/// - 同一台电脑上的 term run（watcher 自己接）、脚本在 ssh 里带 KITELINE_SESSION 跑的，也靠按会话 id 找会话归到对的会话下。
final class TermRelay {
    static let shared = TermRelay()

    private let lock = NSLock()
    /// 开在「不是会话所在那台」电脑上的终端：终端 id → (实际所在的来源, 显示在哪个会话下)
    private var foreign: [String: (sourceId: String, key: String)] = [:]
    /// 已经把退出码转回去的 term run 交接号（结束事件可能来两次：跑完一次、收标签一次）
    private var finished: Set<String> = []

    // MARK: - 设备名

    /// 来源对应的设备名：本机用电脑名（「本机」在手机上分不清是哪台），远端用来源名
    static func deviceName(_ sourceId: String) -> String {
        guard let connection = AppState.shared.source(withId: sourceId) else { return sourceId }
        if connection.config.kind == .local {
            return Host.current().localizedName ?? connection.config.displayName
        }
        return connection.config.displayName
    }

    /// 终端信息补上设备名（device）
    static func label(_ term: Any?, sourceId: String) -> [String: Any]? {
        guard var term = term as? [String: Any] else { return nil }
        term["device"] = deviceName(sourceId)
        term["sourceId"] = sourceId
        return term
    }

    // MARK: - 归属

    /// 这个来源上的会话 id 显示在哪个会话下：本来源有就是本来源的；没有就按会话 id 找别的来源上的（term run 跨电脑）
    private func key(source: SourceConnection, sessionId: String) -> String {
        let own = "\(source.config.id)#\(sessionId)"
        let store = AppState.shared.store
        if store.record(withKey: own) != nil || sessionId.isEmpty { return own }
        if let other = store.records.first(where: { $0.snapshot.sessionId == sessionId }) { return other.key }
        return own
    }

    /// 开在别的电脑上、显示在这个会话下的终端（实际所在来源 → 终端 id）
    func foreignTerms(for key: String) -> [String: [String]] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: [String]] = [:]
        for (id, value) in foreign where value.key == key { out[value.sourceId, default: []].append(id) }
        return out
    }

    func route(_ termId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return foreign[termId]?.sourceId
    }

    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return foreign.values.filter { $0.key == key }.count
    }

    private func remember(_ termId: String, sourceId: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        foreign[termId] = (sourceId, key)
    }

    private func forget(_ termId: String) {
        lock.lock(); defer { lock.unlock() }
        foreign[termId] = nil
    }

    // MARK: - 事件

    /// watcher 的 term / term_exit / term_open：换成会话 key、补设备名转给手机和主窗口；跨电脑跑的把输出转回发起的那台
    func event(_ kind: String, _ raw: [String: Any], from source: SourceConnection) {
        guard let termId = raw["term"] as? String else { return }
        let sessionId = raw["sessionId"] as? String ?? ""
        DispatchQueue.main.async {
            let key = self.key(source: source, sessionId: sessionId)
            let elsewhere = !key.hasPrefix("\(source.config.id)#")
            if kind == "term_exit", raw["keep"] as? Bool != true {
                self.forget(termId)
            } else if elsewhere {
                self.remember(termId, sourceId: source.config.id, key: key)
            }
            var payload = raw
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "sessionId")
            payload.removeValue(forKey: "relay")
            payload["key"] = key
            payload["device"] = Self.deviceName(source.config.id)
            if let info = Self.label(raw["info"], sourceId: source.config.id) { payload["info"] = info }
            if !sessionId.isEmpty { AppState.shared.mobile.publish(event: kind, payload: payload) }
            if let relay = raw["relay"] as? [String: Any] { self.feedBack(kind, raw, relay: relay) }
        }
    }

    /// 跨电脑的 term run：输出、退出码转回发起的那台 watcher
    private func feedBack(_ kind: String, _ raw: [String: Any], relay: [String: Any]) {
        guard let rid = relay["rid"] as? String, let from = relay["from"] as? String,
              let origin = AppState.shared.source(withId: from) else { return }
        var body: [String: Any] = ["cmd": "term_run_feed", "rid": rid]
        switch kind {
        case "term":
            guard let data = raw["data"] as? String else { return }
            body["data"] = data
        case "term_exit":
            lock.lock()
            let first = finished.insert(rid).inserted
            lock.unlock()
            guard first else { return }
            body["exit"] = raw["code"] ?? NSNull()
        default:
            return
        }
        origin.request(body, timeout: 20) { _ in }
    }

    // MARK: - term run --on <设备>

    /// 发起的那台 watcher 请别的电脑跑一条命令
    func run(_ raw: [String: Any], from origin: SourceConnection) {
        guard let rid = raw["rid"] as? String, let command = raw["run"] as? String else { return }
        let sessionId = raw["sessionId"] as? String ?? ""
        let want = (raw["on"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        DispatchQueue.main.async {
            func fail(_ message: String) {
                Log.write("term run \(rid)：\(message)")
                origin.request(["cmd": "term_run_feed", "rid": rid, "error": message], timeout: 20) { _ in }
            }
            guard let target = self.resolveDevice(want) else {
                let names = self.deviceChoices().joined(separator: "、")
                fail("找不到叫「\(want)」的设备（可用：\(names)）"); return
            }
            guard target.state.isLive else { fail("「\(Self.deviceName(target.config.id))」现在没连上"); return }
            var body: [String: Any] = ["cmd": "term", "op": "open", "sessionId": sessionId, "run": command,
                                       "cwd": raw["cwd"] as? String ?? "", "cols": raw["cols"] ?? 120, "rows": raw["rows"] ?? 32,
                                       "relay": ["rid": rid, "from": origin.config.id]]
            if let title = raw["title"] as? String, !title.isEmpty { body["title"] = title }
            let device = Self.deviceName(target.config.id)
            Log.write("term run \(rid)：会话 \(sessionId.prefix(8)) 请「\(device)」跑 \(command.prefix(200))")
            target.request(body, timeout: 30) { result in
                switch result {
                case .success(let response):
                    guard let term = response["term"] as? [String: Any], let termId = term["term"] as? String else {
                        fail(response["error"] as? String ?? "没开起来"); return
                    }
                    let key = self.key(source: target, sessionId: sessionId)
                    if !key.hasPrefix("\(target.config.id)#") { self.remember(termId, sourceId: target.config.id, key: key) }
                    origin.request(["cmd": "term_run_feed", "rid": rid, "started": true, "term": termId, "device": device,
                                    "cwd": term["cwd"] ?? ""], timeout: 20) { _ in }
                case .failure(let error):
                    fail(error.description)
                }
            }
        }
    }

    /// 发起那台的子命令被打断（Ctrl+C、超时）：停掉别的电脑上那个终端
    func cancel(_ raw: [String: Any], from origin: SourceConnection) {
        guard let rid = raw["rid"] as? String else { return }
        DispatchQueue.main.async {
            // 不知道开在哪台：问一遍连着的来源（一般就一两台），把带这个交接号的停掉
            for config in AppState.shared.store.sourceConfigs {
                guard let connection = AppState.shared.source(withId: config.id), connection.state.isLive else { continue }
                connection.request(["cmd": "term", "op": "list"], timeout: 10) { result in
                    guard case .success(let response) = result else { return }
                    for term in response["terms"] as? [[String: Any]] ?? [] {
                        guard (term["relay"] as? [String: Any])?["rid"] as? String == rid, term["ended"] == nil,
                              let id = term["term"] as? String else { continue }
                        connection.request(["cmd": "term", "op": "input", "term": id, "data": "\u{3}"], timeout: 10) { _ in }
                    }
                }
            }
        }
    }

    /// --on 写的设备：本机（mac / local / 本机 / 电脑名）或来源名、主机名、来源 id；都不中再按包含找唯一的
    private func resolveDevice(_ want: String) -> SourceConnection? {
        let needle = want.lowercased()
        let live = AppState.shared.store.sourceConfigs.compactMap { AppState.shared.source(withId: $0.id) }
        func names(_ connection: SourceConnection) -> [String] {
            var out = [connection.config.displayName, connection.config.id, Self.deviceName(connection.config.id)]
            if let host = connection.config.sshHost { out.append(host) }
            if connection.config.kind == .local { out += ["mac", "local", "本机", "localhost", "这台电脑"] }
            return out.map { $0.lowercased() }
        }
        if let exact = live.first(where: { names($0).contains(needle) }) { return exact }
        let partial = live.filter { names($0).contains { $0.contains(needle) } }
        return partial.count == 1 ? partial[0] : nil
    }

    private func deviceChoices() -> [String] {
        AppState.shared.store.sourceConfigs.filter(\.enabled).map { Self.deviceName($0.id) }
    }
}
