import Foundation

/// 订阅额度（5 小时 / 每周）：问每台在线电脑的 watcher（limits），按电脑分组。
/// Claude Code 的读数来自 watcher 装的小 mod（每次回复后写下引擎拿到的额度，不碰凭证），Codex 的来自它自己的 rollout。
/// 手机首页、Mac 侧栏的「今日用量」卡片画成环形（/api/limits）
enum Limits {
    private static var cache: (at: Date, payload: [String: Any])?
    /// 每台电脑最近一次的读数：来源断开时照样给出
    private static var lastKnown: [String: [String: Any]] = [:]
    private static var waiting: [([String: Any]) -> Void] = []

    /// 自测渲染用：之后一直给这份
    private static var injected: [String: Any]?
    static func inject(_ payload: [String: Any]) { injected = payload }

    /// 合并各台电脑的额度；回调在主线程。30 秒内重复要直接给缓存（侧栏、手机首页可能同时在要）
    static func collect(fresh: Bool = false, completion: @escaping ([String: Any]) -> Void) {
        if let injected { completion(injected); return }
        if !fresh, let hit = cache, Date().timeIntervalSince(hit.at) < 30 { completion(hit.payload); return }
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        let sources = AppState.shared.liveSources
        // 有来源还没连上（刚启动、断线重连中）：这次不缓存，连上后马上能拿到完整的
        let complete = AppState.shared.config.sources.filter(\.enabled).count == sources.count
        let group = DispatchGroup()
        for connection in sources {
            group.enter()
            // 旧版 watcher 不认这个命令：当这台电脑没有读数
            connection.request(["cmd": "limits"], timeout: 20) { result in
                if case .success(let reply) = result {
                    let agents = reply["agents"] as? [[String: Any]] ?? []
                    lastKnown[connection.id] = agents.isEmpty ? nil
                        : ["sourceId": connection.id, "name": connection.config.displayName, "local": connection.config.kind == .local, "agents": agents]
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // 电脑的顺序同设置里来源的顺序（本机在前）；暂时连不上的电脑给它最近一次的读数（卡片上写着是多久前的）
            let payload: [String: Any] = [
                "ok": true, "devices": AppState.shared.config.sources.filter(\.enabled).compactMap { lastKnown[$0.id] },
                "generatedAt": Int64(Date().timeIntervalSince1970 * 1000),
            ]
            if complete { cache = (Date(), payload) }
            let callbacks = waiting
            waiting = []
            callbacks.forEach { $0(payload) }
        }
    }
}
