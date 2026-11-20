import Foundation

/// 会话浏览器开在用户操作的这台电脑上（本机 watcher 的 BrowserPool 调度），不开在 Remote-SSH 服务器上（11-16）。
/// 远端会话：连远端时 ssh 带一条反向转发（RemoteSession），远端 watcher 的入口 9339 认出会话后经它接到本机入口，
/// 浏览器开在本机。本机 watcher 报各浏览器状态（browser_state：地址、标题），这里按会话 id 补进那个远端会话；
/// 远端 watcher 整理 agent 的指令、转达「请接管」。画面、点击、标签页走本机 watcher，指令列表找远端要（MobileServer.sessionBrowser）
final class BrowserRelay {
    static let shared = BrowserRelay()
    /// 本机 watcher 的入口端口（反向转发接到这里）。正式运行是 9339；隔离的测试实例换一个（按配置目录算，重启不变），
    /// 经环境变量告诉 watcher（AgentSkill.watcherEnvironment），不占正式版的 9339（11-19 测试实例抢了入口，会话浏览器开到了测试那边）
    static let gatePort: Int = {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["CCPULSE_BROWSER_PORT"].flatMap(Int.init) { return explicit }
        guard AppConfig.isolated else { return 9339 }
        var hash: UInt32 = 2_166_136_261   // FNV-1a
        for byte in (env["CCPULSE_CONFIG_DIR"] ?? String(getpid())).utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return 19400 + Int(hash % 500)
    }()

    private let lock = NSLock()
    private var states: [String: [String: Any]] = [:]

    /// 本机 watcher 的 browser_state：这台电脑上开着的浏览器 → {会话 id: {since, url, title}}
    func update(_ raw: [String: Any]) {
        lock.lock()
        states = raw["browsers"] as? [String: [String: Any]] ?? [:]
        lock.unlock()
        DispatchQueue.main.async { AppState.shared.mobile.publishState() }
    }

    func state(_ sessionId: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return states[sessionId]
    }

    /// 会话数据里的 browser：本机会话用自己快照里的；远端会话只在本机真开着它的浏览器时才有（地址、标题取本机的，指令、请接管取远端的）
    func payload(snapshot: BrowserSnapshot?, sessionId: String, local: Bool) -> [String: Any]? {
        if local { return snapshot?.payload }
        guard let mine = state(sessionId) else { return nil }
        var out = snapshot?.payload ?? [:]
        for field in ["url", "title", "since", "closed", "recs"] { if let value = mine[field] { out[field] = value } }
        if out["url"] == nil { out["url"] = "" }
        if out["title"] == nil { out["title"] = "" }
        return out
    }

    /// 本机的来源（本机 watcher）：远端会话的浏览器在它那里
    var localSource: SourceConnection? {
        AppState.shared.liveSources.first { $0.config.kind == .local }
    }

    /// 本机 watcher 推来的画面、请接管：会话可能在别的电脑上，按会话 id 找到它的 key
    func key(source: SourceConnection, sessionId: String) -> String {
        let own = "\(source.config.id)#\(sessionId)"
        let store = AppState.shared.store
        if store.record(withKey: own) != nil || sessionId.isEmpty { return own }
        if let other = store.records.first(where: { $0.snapshot.sessionId == sessionId }) { return other.key }
        return own
    }
}
