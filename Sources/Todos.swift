import Foundation

/// 待办分两种（10-27 起的，各端分开两块显示）：
/// - 我的待办：只有用户能做的事。agent 经待办技能提醒（watcher 的 todo --user，对话里是 forUser 的 agent_todo）→ 先记成「提示」
///   （suggestions），各端问一句：现在处理（记为处理过）或加入待办；也能长按消息手动加、自己写一条（可附截图）。
///   带来源的「回到会话」：打开原会话、输入框里先写好「已处理好：…」，用户确认后发给 agent。
/// - agent 的待办：agent 自己以后要做的事（todo，没有 --user），收到就记进来（owner agent），带编号（ref）；
///   agent 用 todo start / progress / done 更新状态、进度，记下是哪个会话在处理（handler）。用户只看、不用管。
///   agent 的待办整份推给在线的 watcher（todos 请求）：agent 用 todo list / done 看得到、关得掉别的会话或别的电脑上记的，
///   发图、发报告时 watcher 也凭它提醒 agent「这个会话还有没关的待办」（10-27：做完了不关，越堆越多就没意义了）。
/// 每条记着出自哪个会话的哪条消息（会话 key + 条目 id），各端点一下就跳回那条消息。加过、处理过的消息记进 handled，不再问第二次。
/// （10-27 起不再从回复里猜「需要你来做」的事，嫌太宽泛：只认 agent 经技能提醒的。）
/// 存配置目录 todos.json；有变化就经实时通道推 todos 事件（整份，量不大），各端直接换掉。
///
///   GET  /api/todos                     待办 + 提示 + 处理过的消息
///   POST /api/todos/add                 {texts:[…], key?, itemId?, title?, ts?, images?:[{data}], detail?, forUser?, agent?}：加几条
///                                       （带 key、itemId 就记来源，这条消息算处理过；附的截图、说明跟着第一条）
///   POST /api/todos/update              {id, done?, text?, images?:[{ref} | {data}]}：images = 改完以后的整组截图（留下的给 ref，新加的给 data）
///   GET  /api/todos/media?ref=          截图（存配置目录 todo-media/）
///   POST /api/todos/delete              {ids:[…]}
///   POST /api/todos/dismiss             {key, itemId}：这条消息里的不加；{items:[{key, itemId}…]}：「全部忽略」
///   POST /api/todos/clear-done          删掉所有做完的
final class Todos {
    struct Source: Codable {
        var key: String
        var itemId: String
        /// 加进来时会话叫什么（会话结束、改名后照样显示得出来）
        var title: String
        var machine: String?
        /// 那条消息的时间（毫秒）
        var ts: Double?
        /// 会话的项目目录、哪个 agent（claude-code / codex / …）：agent 的待办按项目、按 Agent 分组用，会话结束了也分得出来
        var cwd: String?
        var agent: String?
    }

    struct Image: Codable {
        var ref: String
        var mime: String
    }

    struct Item: Codable {
        var id: String
        var text: String
        var done: Bool
        var createdAt: Double
        var doneAt: Double?
        var source: Source?
        /// 附的截图（最多 9 张）
        var images: [Image]?
        /// 说明：背景、做到哪一步、怎么判断做完（agent 记的时候写的）
        var detail: String?
        /// 要你自己动手的事（agent 提醒、你加进来的）
        var forUser: Bool?
        /// agent 记的
        var agent: Bool?
        /// agent 自己的待办：编号（agent 更新时按它找）、状态 pending / doing / done、最近的进度、正在处理的会话、最近更新时间
        var ref: String?
        var status: String?
        var progress: String?
        var handler: Source?
        var updatedAt: Double?

        /// agent 自己的待办（不是要你做的）
        var agentTask: Bool { agent == true && forUser != true }
    }

    /// 新冒出来、还没决定加不加的一条消息
    struct Suggestion: Codable {
        var key: String
        var itemId: String
        var title: String
        var machine: String?
        var ts: Double?
        var asks: [String]
        var at: Double
        /// agent 提醒时写的说明（加进待办时跟着带上）
        var detail: String?
    }

    private struct Store: Codable {
        var items: [Item] = []
        var suggestions: [Suggestion] = []
        /// 加过 / 忽略过的消息（"key|itemId"）
        var handled: [String] = []
    }

    static let shared = Todos()
    private static let itemLimit = 500
    private static let suggestionLimit = 30
    private static let handledLimit = 2000
    private static let imageLimit = 9
    /// 提示放一周：一周都没理的，多半是不用做了
    private static let suggestionTTL: Double = 7 * 86_400_000

    private let lock = NSLock()
    private var store = Store()
    private let saveQueue = DispatchQueue(label: "tars.todos.save")
    private var url: URL { AppConfig.directoryURL.appendingPathComponent("todos.json") }
    private var mediaDir: URL { AppConfig.directoryURL.appendingPathComponent("todo-media", isDirectory: true) }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        }
        // 以前从回复里猜出来、还没处理的提示（10-27 之前的）：不再用了，清掉。之后的提示都是 agent 经技能提醒的
        let guessedBefore: Double = 1_793_030_400_000   // 2026-10-27 00:00（北京时间）
        if store.suggestions.contains(where: { $0.at < guessedBefore }) {
            store.suggestions.removeAll { $0.at < guessedBefore }
            save()
        }
        // 10-27 中午之前记的 agent 待办没有编号，agent 没法关（todo done 要编号）：补上
        if Self.numberAgentTasks(&store) { save() }
    }

    private static var now: Double { (Date().timeIntervalSince1970 * 1000).rounded() }
    private static func mark(_ key: String, _ itemId: String) -> String { "\(key)|\(itemId)" }

    // MARK: - agent 记的

    /// 这条消息处理过没有（加过、删过、忽略过、正在提示）
    private func known(_ mark: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store.handled.contains(mark) || store.suggestions.contains { Self.mark($0.key, $0.itemId) == mark }
            || store.items.contains { $0.source.map { Self.mark($0.key, $0.itemId) } == mark }
    }

    /// agent 自己以后要做的事（对话里不带 forUser 的 agent_todo）：直接记进「agent 的待办」。返回 true = 新记的
    @discardableResult
    func addAgentTask(key: String, itemId: String, text: String, detail: String, ref: String, ts: Double?) -> Bool {
        guard !known(Self.mark(key, itemId)), let source = source(from: ["key": key, "itemId": itemId, "ts": ts as Any]) else { return false }
        add([String(text.prefix(2000))], source: source, images: [], detail: String(detail.prefix(4000)), forUser: false, agent: true,
            ref: ref.isEmpty ? nil : ref)
        return true
    }

    /// 只有用户能做的事（带 forUser 的 agent_todo）：先记成提示，各端问一句「现在处理 / 加入待办」。返回 true = 新的（要推送）
    @discardableResult
    func suggestForUser(key: String, itemId: String, title: String, machine: String?, ts: Double?, text: String, detail: String) -> Bool {
        guard !known(Self.mark(key, itemId)) else { return false }
        let fresh = Suggestion(key: key, itemId: itemId, title: String(title.prefix(200)), machine: machine, ts: ts,
                               asks: [String(text.prefix(2000))], at: Self.now, detail: detail.isEmpty ? nil : String(detail.prefix(4000)))
        lock.lock()
        let cutoff = Self.now - Self.suggestionTTL
        store.suggestions.removeAll { $0.at < cutoff }
        store.suggestions.append(fresh)
        if store.suggestions.count > Self.suggestionLimit { store.suggestions.removeFirst(store.suggestions.count - Self.suggestionLimit) }
        lock.unlock()
        changed(fresh: fresh)
        return true
    }

    /// agent 更新自己的待办（todo start / progress / done）：按编号改状态、进度，记下是哪个会话在处理。返回那条的标题（找不到 nil）
    @discardableResult
    func updateAgentTask(ref: String, status: String, progress: String, key: String) -> String? {
        var handler = source(from: ["key": key, "itemId": "-"]) ?? Source(key: key, itemId: "", title: "会话", machine: nil, ts: nil, cwd: nil, agent: nil)
        handler.itemId = ""
        handler.ts = nil
        var title: String?
        mutate { store in
            guard let index = store.items.lastIndex(where: { $0.ref == ref }) else { return }
            title = store.items[index].text
            store.items[index].status = status
            if !progress.isEmpty { store.items[index].progress = String(progress.prefix(1000)) }
            store.items[index].handler = handler
            store.items[index].updatedAt = Self.now
            let done = status == "done"
            if store.items[index].done != done {
                store.items[index].done = done
                store.items[index].doneAt = done ? Self.now : nil
            }
        }
        return title
    }

    // MARK: - 接口

    func payload() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Self.now - Self.suggestionTTL
        return [
            "ok": true,
            "items": store.items.map(Self.itemPayload),
            "suggestions": store.suggestions.filter { $0.at >= cutoff }.map(Self.suggestionPayload),
            "handled": store.handled,
        ]
    }

    /// /api/todos…（MobileServer 转过来）
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.jsonBody ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/api/todos"):
            return .json(payload())
        case ("POST", "/api/todos/add"):
            let texts = (body["texts"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !texts.isEmpty, texts.count <= 50 else { return .error("没有可添加的内容", status: 400) }
            guard let images = saveImages(body["images"], keeping: []) else { return .error("截图过多或无法打开（最多 \(Self.imageLimit) 张）", status: 400) }
            // 从提示加进来的（agent 提醒用户的那条）：说明跟着带上，算「我的待办」
            let pending = (body["key"] as? String).flatMap { key in (body["itemId"] as? String).flatMap { id in suggestion(key, id) } }
            let detail = ((body["detail"] as? String) ?? pending?.detail)?.trimmingCharacters(in: .whitespacesAndNewlines)
            add(texts.map { String($0.prefix(2000)) }, source: source(from: body), images: images,
                detail: detail.map { String($0.prefix(4000)) }, forUser: (body["forUser"] as? Bool) ?? (pending != nil ? true : nil),
                agent: (body["agent"] as? Bool) ?? (pending != nil ? true : nil))
            return .json(payload())
        case ("POST", "/api/todos/update"):
            guard let id = body["id"] as? String else { return .error("缺少 id", status: 400) }
            let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, text.isEmpty { return .error("内容不能为空", status: 400) }
            var images: [Image]?
            if body["images"] != nil {
                let current = item(id)?.images ?? []
                guard let saved = saveImages(body["images"], keeping: current) else { return .error("截图过多或无法打开（最多 \(Self.imageLimit) 张）", status: 400) }
                images = saved
            }
            guard update(id: id, done: body["done"] as? Bool, text: text.map { String($0.prefix(2000)) }, images: images) else {
                return .error("该待办已不存在", status: 404)
            }
            return .json(payload())
        case ("GET", "/api/todos/media"):
            guard let ref = request.query["ref"], Self.validRef(ref),
                  let data = try? Data(contentsOf: mediaDir.appendingPathComponent(ref)) else { return .error("图片不存在", status: 404) }
            return Thumbnail.reply(data, mime: ref.hasSuffix(".png") ? "image/png" : "image/jpeg", request: request, cacheKey: "todo|\(ref)")
        case ("POST", "/api/todos/delete"):
            let ids = Set(body["ids"] as? [String] ?? (body["id"] as? String).map { [$0] } ?? [])
            guard !ids.isEmpty else { return .error("缺少 id", status: 400) }
            mutate { store in
                Self.dropImages(store.items.filter { ids.contains($0.id) }, in: self.mediaDir)
                store.items.removeAll { ids.contains($0.id) }
            }
            return .json(payload())
        case ("POST", "/api/todos/dismiss"):
            // 「全部忽略」：items 是手机上当时列着的那几条（只忽略看得见的，刚冒出来的新提示不跟着丢）
            if let list = body["items"] as? [[String: Any]] {
                let marks = list.compactMap { entry -> String? in
                    guard let key = entry["key"] as? String, let itemId = entry["itemId"] as? String else { return nil }
                    return Self.mark(key, itemId)
                }
                mutate { store in
                    store.suggestions.removeAll { marks.contains(Self.mark($0.key, $0.itemId)) }
                    marks.forEach { Self.remember(&store, $0) }
                }
                return .json(payload())
            }
            guard let key = body["key"] as? String, let itemId = body["itemId"] as? String else { return .error("缺少 key、itemId", status: 400) }
            mutate { store in
                store.suggestions.removeAll { $0.key == key && $0.itemId == itemId }
                Self.remember(&store, Self.mark(key, itemId))
            }
            return .json(payload())
        case ("POST", "/api/todos/clear-done"):
            mutate { store in
                Self.dropImages(store.items.filter(\.done), in: self.mediaDir)
                store.items.removeAll { $0.done }
            }
            return .json(payload())
        default:
            return .error("未知的待办接口", status: 404)
        }
    }

    // MARK: - 改动

    private func source(from body: [String: Any]) -> Source? {
        guard let key = body["key"] as? String, !key.isEmpty, let itemId = body["itemId"] as? String, !itemId.isEmpty else { return nil }
        // 会话还在跑：标题、机器取 Mac 这边的；已经结束的用手机传来的标题
        var title = (body["title"] as? String) ?? ""
        var machine: String?
        let record = AppState.shared.store.record(withKey: key)
        if let record {
            title = record.snapshot.displayTitle
            machine = record.sourceName
        } else if let hash = key.firstIndex(of: "#") {
            let sourceId = String(key[..<hash])
            machine = AppState.shared.config.sources.first { $0.id == sourceId }?.displayName
        }
        let pending = { () -> Suggestion? in
            self.lock.lock(); defer { self.lock.unlock() }
            return self.store.suggestions.first { $0.key == key && $0.itemId == itemId }
        }()
        if title.isEmpty { title = pending?.title ?? "会话" }
        let ts = (body["ts"] as? Double) ?? (body["ts"] as? Int).map(Double.init) ?? pending?.ts
        return Source(key: key, itemId: itemId, title: String(title.prefix(200)), machine: machine ?? pending?.machine, ts: ts,
                      cwd: record.flatMap { $0.snapshot.cwd.isEmpty ? nil : $0.snapshot.cwd }, agent: record?.snapshot.agentID)
    }

    /// 早先记的（没有项目目录、agent）：会话还在的从会话补上，之后会话结束了照样能按项目、按 Agent 分组。
    /// 会话列表每次更新时调（主线程）；都补齐了就什么也不做
    func fillSessionMeta() {
        lock.lock()
        let lacking = store.items.contains { $0.agentTask && (($0.handler ?? $0.source).map { $0.cwd == nil } ?? false) }
        lock.unlock()
        guard lacking else { return }
        let records = AppState.shared.store
        var filled = false
        func fill(_ source: inout Source?) {
            guard var s = source, s.cwd == nil, let record = records.record(withKey: s.key), !record.snapshot.cwd.isEmpty else { return }
            s.cwd = record.snapshot.cwd
            s.agent = s.agent ?? record.snapshot.agentID
            source = s
            filled = true
        }
        lock.lock()
        for index in store.items.indices where store.items[index].agentTask {
            fill(&store.items[index].source)
            fill(&store.items[index].handler)
        }
        lock.unlock()
        if filled { changed() }
    }

    private func suggestion(_ key: String, _ itemId: String) -> Suggestion? {
        lock.lock(); defer { lock.unlock() }
        return store.suggestions.first { $0.key == key && $0.itemId == itemId }
    }

    private func add(_ texts: [String], source: Source?, images: [Image], detail: String? = nil, forUser: Bool? = nil, agent: Bool? = nil,
                     ref: String? = nil) {
        mutate { store in
            let now = Self.now
            for (i, text) in texts.enumerated() {
                // 同一条消息里的同一句加过就不重复加
                if let source, store.items.contains(where: { $0.text == text && $0.source?.key == source.key && $0.source?.itemId == source.itemId }) { continue }
                store.items.append(Item(id: String(UUID().uuidString.prefix(8)).lowercased(), text: text, done: false,
                                        createdAt: now + Double(i), doneAt: nil, source: source,
                                        images: i == 0 && !images.isEmpty ? images : nil,
                                        detail: i == 0 && detail?.isEmpty == false ? detail : nil,
                                        forUser: i == 0 && forUser == true ? true : nil, agent: agent == true ? true : nil,
                                        ref: i == 0 ? ref : nil, status: i == 0 && ref != nil ? "pending" : nil, progress: nil, handler: nil,
                                        updatedAt: nil))
            }
            if store.items.count > Self.itemLimit {
                // 超了先删最早做完的，还超就删最早的
                let overflow = store.items.count - Self.itemLimit
                let doneIds = store.items.filter(\.done).sorted { ($0.doneAt ?? 0) < ($1.doneAt ?? 0) }.prefix(overflow).map(\.id)
                Self.dropImages(store.items.filter { doneIds.contains($0.id) }, in: self.mediaDir)
                store.items.removeAll { doneIds.contains($0.id) }
                if store.items.count > Self.itemLimit {
                    let extra = store.items.count - Self.itemLimit
                    Self.dropImages(Array(store.items.prefix(extra)), in: self.mediaDir)
                    store.items.removeFirst(extra)
                }
            }
            if let source {
                store.suggestions.removeAll { $0.key == source.key && $0.itemId == source.itemId }
                Self.remember(&store, Self.mark(source.key, source.itemId))
            }
            _ = Self.numberAgentTasks(&store)
        }
    }

    private func update(id: String, done: Bool?, text: String?, images: [Image]?) -> Bool {
        var found = false
        mutate { store in
            guard let index = store.items.firstIndex(where: { $0.id == id }) else { return }
            found = true
            if let done, store.items[index].done != done {
                store.items[index].done = done
                store.items[index].doneAt = done ? Self.now : nil
                if store.items[index].agentTask {
                    // 用户替 agent 勾掉 / 恢复：状态跟着变，agent 那边 todo list 也就对得上
                    store.items[index].status = done ? "done" : "pending"
                    store.items[index].updatedAt = Self.now
                }
            }
            if let text { store.items[index].text = text }
            if let images {
                // 去掉的截图连文件一起删
                let kept = Set(images.map(\.ref))
                for old in store.items[index].images ?? [] where !kept.contains(old.ref) {
                    try? FileManager.default.removeItem(at: self.mediaDir.appendingPathComponent(old.ref))
                }
                store.items[index].images = images.isEmpty ? nil : images
            }
        }
        return found
    }

    private func item(_ id: String) -> Item? {
        lock.lock(); defer { lock.unlock() }
        return store.items.first { $0.id == id }
    }

    // MARK: - 截图

    /// 改完以后的整组截图：{ref} = 原来就有的（只认这条待办自己的），{data} = 新加的（base64，存成文件）。nil = 太多或打不开
    private func saveImages(_ raw: Any?, keeping current: [Image]) -> [Image]? {
        let list = raw as? [[String: Any]] ?? []
        guard list.count <= Self.imageLimit else { return nil }
        var result: [Image] = []
        for entry in list {
            if let ref = entry["ref"] as? String {
                if let old = current.first(where: { $0.ref == ref }) { result.append(old) }
                continue
            }
            guard let encoded = entry["data"] as? String, let data = Data(base64Encoded: encoded), data.count > 8, data.count < 15_000_000 else { return nil }
            let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            guard png || data.starts(with: [0xFF, 0xD8]) else { return nil }
            let ref = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() + (png ? ".png" : ".jpg")
            try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            let file = mediaDir.appendingPathComponent(ref)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            result.append(Image(ref: ref, mime: png ? "image/png" : "image/jpeg"))
        }
        return result
    }

    private static func validRef(_ ref: String) -> Bool {
        ref.range(of: "^[a-f0-9]{16}\\.(jpg|png)$", options: .regularExpression) != nil
    }

    private static func dropImages(_ items: [Item], in dir: URL) {
        for image in items.flatMap({ $0.images ?? [] }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(image.ref))
        }
    }

    /// agent 的待办都要有编号（agent 凭它更新、关掉）：没有的补一个（取 id 前 6 位，撞了就随机）。返回 true = 补过
    private static func numberAgentTasks(_ store: inout Store) -> Bool {
        var used = Set(store.items.compactMap(\.ref))
        var changed = false
        for index in store.items.indices where store.items[index].agentTask && store.items[index].ref == nil {
            var ref = "t-\(store.items[index].id.prefix(6))"
            while used.contains(ref) || ref.range(of: "^t-[0-9a-f]{6}$", options: .regularExpression) == nil {
                ref = "t-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased())"
            }
            used.insert(ref)
            store.items[index].ref = ref
            if store.items[index].status == nil { store.items[index].status = store.items[index].done ? "done" : "pending" }
            changed = true
        }
        return changed
    }

    private static func remember(_ store: inout Store, _ mark: String) {
        guard !store.handled.contains(mark) else { return }
        store.handled.append(mark)
        if store.handled.count > handledLimit { store.handled.removeFirst(store.handled.count - handledLimit) }
    }

    private func mutate(_ change: (inout Store) -> Void) {
        lock.lock()
        change(&store)
        lock.unlock()
        changed()
    }

    /// 存盘 + 推给各端（fresh = 刚冒出来的提示：没开着那个会话的设备弹个横幅问一句）+ agent 的待办有变化就告诉各台电脑上的 watcher
    private func changed(fresh: Suggestion? = nil) {
        save()
        DispatchQueue.main.async {
            var payload = self.payload()
            if let fresh { payload["fresh"] = Self.suggestionPayload(fresh) }
            AppState.shared.mobile.publish(event: "todos", payload: payload)
        }
        pushToAgents()
    }

    // MARK: - 告诉各台电脑上的 agent

    /// 隔离的测试实例连着的 watcher 用的是真的数据目录，别拿测试数据盖掉（watcher 也隔离了数据目录的才推）
    private static var syncsAgents: Bool {
        !AppConfig.isolated || !(ProcessInfo.processInfo.environment["CCPULSE_DATA_DIR"] ?? "").isEmpty
    }

    /// 上次推出去的内容（没变不重发）；只在主线程碰
    private var pushedAgents: Data?

    /// agent 的待办推给在线的 watcher（todos 请求）：agent 用 todo list / done 看得到、接手、关掉别的会话或别的电脑上记的，
    /// 用户在这边勾掉、删掉的 agent 那边也对得上。only = 刚连上的那一个（不管上次推过什么都发一份）
    func pushToAgents(only source: SourceConnection? = nil) {
        guard Self.syncsAgents else { return }
        DispatchQueue.main.async {
            let items = self.agentSnapshot()
            if source == nil {
                let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
                guard data != self.pushedAgents else { return }
                self.pushedAgents = data
            }
            for target in source.map({ [$0] }) ?? AppState.shared.liveSources {
                // 老版本 watcher 不认这个请求，回个错误，不用管
                target.request(["cmd": "todos", "items": items], timeout: 20) { _ in }
            }
        }
    }

    /// 推给 watcher 的那份：没做完的全带上，做完的只带最近一周的（agent 对得上自己刚关的）；holder = 在处理的会话，没人接手就是记下它的会话
    private func agentSnapshot() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Self.now - 7 * 86_400_000
        return store.items.filter { $0.agentTask && $0.ref != nil && (!$0.done || ($0.doneAt ?? 0) >= cutoff) }.map { item in
            var row: [String: Any] = ["ref": item.ref ?? "", "text": item.text, "status": item.done ? "done" : (item.status ?? "pending"),
                                      "at": item.updatedAt ?? item.createdAt]
            if let progress = item.progress, !progress.isEmpty { row["progress"] = String(progress.prefix(300)) }
            if !item.done, let detail = item.detail, !detail.isEmpty { row["detail"] = String(detail.prefix(1500)) }
            if let holder = item.handler ?? item.source {
                row["key"] = holder.key
                row["title"] = holder.title
                if let machine = holder.machine { row["machine"] = machine }
            }
            return row
        }
    }

    private static func itemPayload(_ item: Item) -> [String: Any] {
        var out: [String: Any] = ["id": item.id, "text": item.text, "done": item.done, "createdAt": item.createdAt]
        if let doneAt = item.doneAt { out["doneAt"] = doneAt }
        if let detail = item.detail { out["detail"] = detail }
        if item.forUser == true { out["forUser"] = true }
        if item.agent == true { out["agent"] = true }
        if let ref = item.ref { out["ref"] = ref }
        if let status = item.status { out["status"] = status }
        if let progress = item.progress { out["progress"] = progress }
        if let updatedAt = item.updatedAt { out["updatedAt"] = updatedAt }
        if let handler = item.handler {
            var h: [String: Any] = ["key": handler.key, "title": handler.title]
            if let machine = handler.machine { h["machine"] = machine }
            if let cwd = handler.cwd { h["cwd"] = cwd }
            if let agent = handler.agent { h["agent"] = agent }
            out["handler"] = h
        }
        if let images = item.images, !images.isEmpty { out["images"] = images.map { ["ref": $0.ref, "mime": $0.mime] } }
        if let source = item.source {
            var s: [String: Any] = ["key": source.key, "itemId": source.itemId, "title": source.title]
            if let machine = source.machine { s["machine"] = machine }
            if let ts = source.ts { s["ts"] = ts }
            if let cwd = source.cwd { s["cwd"] = cwd }
            if let agent = source.agent { s["agent"] = agent }
            out["source"] = s
        }
        return out
    }

    private static func suggestionPayload(_ s: Suggestion) -> [String: Any] {
        var out: [String: Any] = ["key": s.key, "itemId": s.itemId, "title": s.title, "asks": s.asks, "at": s.at]
        if let machine = s.machine { out["machine"] = machine }
        if let detail = s.detail { out["detail"] = detail }
        if let ts = s.ts { out["ts"] = ts }
        return out
    }

    private func save() {
        // 快照和写盘在同一个串行队列里，后写的不会被先写的覆盖
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let snapshot = self.store
            self.lock.unlock()
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            try? data.write(to: self.url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        }
    }
}
