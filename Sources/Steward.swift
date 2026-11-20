import Foundation
import KitelineKit

/// 总管模式（实验性，11-20 用户提）：用户在设置里选一台电脑、一个 agent 当「总管」，以后不用自己找设备、项目、会话，直接对总管说需求。
///
/// - 总管就是一个普通会话：工作目录是那台电脑上的 `~/.ccpulse/steward`，里面的 CLAUDE.md / AGENTS.md 是它的说明书（watcher 的 STEWARD_BRIEF，开启时写进去）。
/// - 这里把设备、项目、运行中的会话整理成一份目录推给总管所在的电脑（watcher 存成 `~/.ccpulse/steward.json`），总管用 `steward state` 看。
/// - 总管用 `steward assign / new / group`、被派活的会话用 `steward report`：watcher 写进发图通道（`steward_op`），这里照着做——
///   派活 = 把任务投进那个会话；新开 = 在那台电脑那个项目里开会话；拉群 = 建会话群；汇报 = 投进总管的会话（截图一起带过去）。
/// - 设置存在配置目录的 steward.json（不进 config.json：老版本读不懂也不会丢）。
final class Steward {
    struct Settings: Codable, Equatable {
        var enabled = false
        var sourceId = ""
        /// 当总管的 agent：claude-code 或插件 id（同新任务里选的）
        var agent = "claude-code"
        /// 开启时现有会话怎么办：keep = 保留（总管照样能派活给它们）；close = 全部关掉
        var existing = "keep"
        /// 手机上自动朗读总管的回复
        var speak = true
        /// 总管会话 id（开出来后在会话列表里认到的）
        var sessionId: String?
        /// 总管的工作目录（总管那台电脑上的 ~/.ccpulse/steward）
        var cwd: String?
        var enabledAt: Double?
    }

    static let shared = Steward()

    /// 还在做（11-20）：默认不对外（features 里不带 steward，各端看不到入口）。开发、试用时打开：
    /// `defaults write com.mrhong.tars stewardPreview -bool true` 或环境变量 KITELINE_STEWARD=1
    static var available: Bool {
        ProcessInfo.processInfo.environment["KITELINE_STEWARD"] == "1" || AppConfig.defaults.bool(forKey: "stewardPreview")
    }

    private(set) var settings: Settings
    private var pushedData: Data?
    private var pushWork: DispatchWorkItem?
    /// 处理过的发图通道条目（重连后 watcher 会再吐一遍）
    private var handled: [String] = []
    /// 正在开总管会话（开出来之前别再开一个）
    private var starting = false

    /// 调度记录（手机上「总管」页画派活过程用）：派给了谁、做到哪、回报了什么；最近的一些事（派活、新开、拉群、回报）。
    /// 存在配置目录的 steward-board.json，只留最近 12 小时、最多 60 件 / 80 条
    struct Task: Codable, Equatable {
        var id: String
        /// 派给的会话；新开的会话开出来之前是空的（按电脑 + 目录 + 时间认）
        var key: String
        var op: String
        var title: String
        var device: String
        var deviceId: String
        var cwd: String
        var text: String
        /// sent 已派出 / failed 没派出去 / reported 回报过
        var state: String
        var at: Double
        var reportAt: Double?
        var report: String?
        var images: Int?
        var note: String?
    }
    struct Event: Codable, Equatable {
        var id: String
        /// assign / new / group / report / failed
        var kind: String
        var text: String
        var at: Double
        var keys: [String]?
    }
    private struct Board: Codable {
        var tasks: [Task] = []
        var events: [Event] = []
    }
    private var board = Board()
    private static var boardURL: URL { AppConfig.directoryURL.appendingPathComponent("steward-board.json") }

    private static var fileURL: URL { AppConfig.directoryURL.appendingPathComponent("steward.json") }

    private init() {
        settings = (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: Self.fileURL))) ?? Settings()
        board = (try? JSONDecoder().decode(Board.self, from: Data(contentsOf: Self.boardURL))) ?? Board()
    }

    private static var now: Double { Date().timeIntervalSince1970 * 1000 }

    /// 改调度记录：只留最近 12 小时，存盘、推给手机
    private func noteBoard(_ change: (inout Board) -> Void) {
        change(&board)
        let cutoff = Self.now - 12 * 3600 * 1000
        board.tasks = Array(board.tasks.filter { $0.at > cutoff }.suffix(60))
        board.events = Array(board.events.filter { $0.at > cutoff }.suffix(80))
        if let data = try? JSONEncoder().encode(board) { try? data.write(to: Self.boardURL, options: .atomic) }
        publish()
    }

    private func event(_ kind: String, _ text: String, keys: [String]? = nil) -> Event {
        Event(id: UUID().uuidString.prefix(8).lowercased(), kind: kind, text: String(text.prefix(300)), at: Self.now, keys: keys)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - 总管会话

    /// 总管会话的 key（在跑的才有）：记着的会话 id 还在就是它；不在了，找总管那台电脑上工作目录是 ~/.ccpulse/steward 的、最新开的那个
    var key: String? {
        guard settings.enabled else { return nil }
        let records = AppState.shared.store.records.filter { $0.sourceId == settings.sourceId }
        if let id = settings.sessionId, let record = records.first(where: { $0.snapshot.sessionId == id }) { return record.key }
        guard let cwd = settings.cwd else { return nil }
        return records.filter { Self.sameDir($0.snapshot.cwd, cwd) }.max { ($0.snapshot.startedAt ?? 0) < ($1.snapshot.startedAt ?? 0) }?.key
    }

    private var record: SessionRecord? { key.flatMap { AppState.shared.store.record(withKey: $0) } }

    /// 两个目录是不是同一个：去掉末尾的 /，macOS 的 /tmp、/var 实际在 /private 下（会话报的是 /private/tmp/…，用户写的是 /tmp/…）
    static func sameDir(_ a: String, _ b: String) -> Bool {
        func norm(_ path: String) -> String {
            var p = path
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            for prefix in ["/private/tmp", "/private/var", "/private/etc"] where p == prefix || p.hasPrefix(prefix + "/") { p.removeFirst("/private".count) }
            return p
        }
        return norm(a) == norm(b)
    }

    func isSteward(_ key: String) -> Bool { settings.enabled && key == self.key }

    // MARK: - 接口

    /// GET /api/steward：现在的设置、总管会话；POST /api/steward：开启（带配置）/ 关闭；POST /api/steward/wake：总管会话不在了，重新开一个
    func handle(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        DispatchQueue.main.async { self.route(request, respond: respond) }
    }

    private func route(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/api/steward"):
            respond(.json(status()))
        case ("POST", "/api/steward"):
            let body = request.jsonBody ?? [:]
            guard body["enabled"] as? Bool == true else {
                disable()
                respond(.json(status()))
                return
            }
            // 测试实例（dry-run 开不出真的总管会话）：testSessionId 指定一个现成的会话当总管
            if AppConfig.isolated, let id = body["testSessionId"] as? String, !id.isEmpty {
                settings.sessionId = id
                save()
            }
            enable(sourceId: body["sourceId"] as? String ?? "", agent: body["agent"] as? String ?? "claude-code",
                   existing: body["existing"] as? String ?? "keep", speak: body["speak"] as? Bool ?? true, respond: respond)
        case ("POST", "/api/steward/wake"):
            guard settings.enabled else { respond(.error(L("总管模式未开启"), status: 409)); return }
            if record != nil { respond(.json(status())); return }
            launch { outcome in
                var out = self.status()
                out["ok"] = outcome.ok
                out["message"] = outcome.message
                respond(.json(out, status: outcome.ok ? 200 : 409))
            }
        default:
            respond(.error("接口不存在", status: 404))
        }
    }

    func status() -> [String: Any] {
        let source = AppState.shared.config.sources.first { $0.id == settings.sourceId }
        var out: [String: Any] = ["ok": true, "enabled": settings.enabled, "sourceId": settings.sourceId, "agent": settings.agent,
                                  "existing": settings.existing, "speak": settings.speak, "starting": starting,
                                  "sourceName": source?.displayName ?? ""]
        if let record {
            out["key"] = record.key
            out["activity"] = record.snapshot.activity
        }
        out["tasks"] = board.tasks.compactMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        out["events"] = board.events.suffix(30).compactMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        return out
    }

    private func publish() {
        AppState.shared.mobile.publish(event: "steward", payload: status())
    }

    // MARK: - 开启、关闭

    private func enable(sourceId: String, agent: String, existing: String, speak: Bool, respond: @escaping (HTTPResponse) -> Void) {
        guard let source = AppState.shared.config.sources.first(where: { $0.id == sourceId }),
              let connection = AppState.shared.source(withId: sourceId), connection.state.isLive else {
            respond(.error(L("该机器当前离线"), status: 404)); return
        }
        guard !starting else { respond(.error(L("总管正在启动，请稍候"), status: 409)); return }
        // 准备工作目录、写说明书
        connection.request(["cmd": "steward", "op": "setup"], timeout: 20) { result in
            DispatchQueue.main.async {
                guard case .success(let reply) = result, let cwd = reply["cwd"] as? String, !cwd.isEmpty else {
                    let reason: String
                    if case .failure(let error) = result { reason = error.description } else { reason = L("这台电脑上的 Kiteline 版本较旧，请先更新") }
                    respond(.error(L("无法在 %@ 上准备总管：%@", source.displayName, reason), status: 409)); return
                }
                let moved = !self.settings.sourceId.isEmpty && (self.settings.sourceId != sourceId || self.settings.agent != agent)
                self.settings.enabled = true
                self.settings.sourceId = sourceId
                self.settings.agent = agent.isEmpty ? "claude-code" : agent
                self.settings.existing = existing == "close" ? "close" : "keep"
                self.settings.speak = speak
                self.settings.cwd = cwd
                self.settings.enabledAt = Date().timeIntervalSince1970 * 1000
                if moved { self.settings.sessionId = nil }
                self.save()
                Log.write("总管模式：开启（\(source.displayName)，\(self.settings.agent)，现有会话\(self.settings.existing == "close" ? "全部关闭" : "保留")）")
                if self.settings.existing == "close" { self.closeOthers() }
                self.pushedData = nil
                self.push()
                // 已经有总管会话在跑（之前开过、关了总管模式又开）：接着用
                if self.record != nil {
                    self.publish()
                    var out = self.status()
                    out["message"] = L("总管模式已开启")
                    respond(.json(out)); return
                }
                self.launch { outcome in
                    var out = self.status()
                    out["ok"] = outcome.ok
                    out["message"] = outcome.ok ? L("总管模式已开启，总管正在 %@ 上启动", source.displayName) : outcome.message
                    respond(.json(out, status: outcome.ok ? 200 : 409))
                }
            }
        }
    }

    private func disable() {
        guard settings.enabled else { return }
        settings.enabled = false
        save()
        Log.write("总管模式：关闭（总管会话保留）")
        pushedData = nil
        push()
        publish()
    }

    /// 开启时选了「关闭现有会话」：除了总管自己，运行中的会话一个一个关（关会话本身会问 VS Code / 后台，慢，排着来）
    private func closeOthers() {
        let targets = AppState.shared.store.records.filter { $0.key != key && $0.kind != .kiteline }
        func next(_ rest: ArraySlice<SessionRecord>) {
            guard let record = rest.first else { return }
            Delivery.close(record: record, source: AppState.shared.source(withId: record.sourceId)) { _ in
                DispatchQueue.main.async { next(rest.dropFirst()) }
            }
        }
        next(targets[...])
    }

    /// 在总管那台电脑的工作目录里开总管会话：Claude Code 走新任务那条路（默认后台运行），别家 agent 走插件的后台运行
    private func launch(_ completion: @escaping (NewSession.Outcome) -> Void) {
        guard let source = AppState.shared.config.sources.first(where: { $0.id == settings.sourceId }), let cwd = settings.cwd else {
            completion(NewSession.Outcome(ok: false, submitted: false, openedWindow: false, message: L("总管所在的电脑不存在"))); return
        }
        starting = true
        publish()
        let prompt = L("总管模式已开启。请先运行 steward state 了解现在有哪些设备、项目和会话，然后用一两句话向用户问好，说明你能帮他做什么。")
        let done: (NewSession.Outcome) -> Void = { outcome in
            DispatchQueue.main.async {
                self.starting = false
                Log.write("总管模式：启动总管会话 \(outcome.ok ? "成功" : "失败")：\(outcome.message)")
                self.publish()
                completion(outcome)
            }
        }
        if settings.agent == "claude-code" {
            NewSession.start(source: source, cwd: cwd, prompt: prompt, submit: true, returnFocus: true, completion: done)
        } else {
            MobileServer.startAgent(source, cwd: cwd, prompt: prompt, submit: true, sessionId: nil, agent: settings.agent,
                                    accepted: { _ in }, completion: done)
        }
    }

    // MARK: - 推目录

    /// 会话列表变了：认一下总管会话（开出来了就记下 id），过 3 秒把目录推给总管那台电脑（连着变只推一次）
    func sessionsChanged() {
        guard settings.enabled else { return }
        claimNewSessions()
        if let key, let id = key.split(separator: "#", maxSplits: 1).last.map(String.init), settings.sessionId != id {
            settings.sessionId = id
            save()
            publish()
        }
        schedulePush()
    }

    /// 新开的会话开出来了：同一台电脑、同一个目录、派活之后才开始的那个就是它（已经认给别的任务的不算）
    private func claimNewSessions() {
        let pending = board.tasks.indices.filter { board.tasks[$0].key.isEmpty && board.tasks[$0].state != "failed" && Self.now - board.tasks[$0].at < 10 * 60 * 1000 }
        guard !pending.isEmpty else { return }
        let taken = Set(board.tasks.map(\.key))
        var changes: [(Int, SessionRecord)] = []
        for index in pending {
            let task = board.tasks[index]
            if let hit = AppState.shared.store.records.filter({ $0.sourceId == task.deviceId && Self.sameDir($0.snapshot.cwd, task.cwd) && !taken.contains($0.key)
                && ($0.snapshot.startedAt ?? 0) >= task.at - 5000 })
                .min(by: { ($0.snapshot.startedAt ?? 0) < ($1.snapshot.startedAt ?? 0) }) {
                changes.append((index, hit))
            }
        }
        guard !changes.isEmpty else { return }
        noteBoard { board in
            for (index, hit) in changes where board.tasks.indices.contains(index) {
                board.tasks[index].key = hit.key
                board.tasks[index].title = hit.snapshot.displayTitle
            }
        }
    }

    /// 来源刚连上：是总管那台电脑就推一份
    func sourceConnected(_ source: SourceConnection) {
        guard settings.enabled || pushedData != nil, source.id == settings.sourceId else { return }
        pushedData = nil
        schedulePush()
    }

    private func schedulePush() {
        guard pushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pushWork = nil
            self?.push()
        }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func push() {
        guard let connection = AppState.shared.source(withId: settings.sourceId), connection.state.isLive else { return }
        directory { directory in
            let data = try? JSONSerialization.data(withJSONObject: directory, options: [.sortedKeys])
            guard data != self.pushedData else { return }
            self.pushedData = data
            connection.request(["cmd": "steward", "directory": directory], timeout: 20) { _ in }
        }
    }

    /// 推给总管的目录：设备、运行中的会话（标题、状态、做到哪一步、最近一句）、项目（最近用过的，含没有会话在跑的）
    private func directory(_ completion: @escaping ([String: Any]) -> Void) {
        let state = AppState.shared
        guard settings.enabled, let key else { completion(["steward": [String: Any]()]); return }
        let devices: [[String: Any]] = state.config.sources.filter { $0.kind != .kiteline }.map { source in
            ["id": source.id, "name": source.displayName, "kind": source.kind.rawValue, "online": state.source(withId: source.id)?.state.isLive == true]
        }
        let sessions: [[String: Any]] = state.store.records.map { record in
            let snap = record.snapshot
            var row: [String: Any] = ["key": record.key, "sessionId": snap.sessionId, "title": snap.displayTitle, "device": record.sourceName,
                                      "deviceId": record.sourceId, "project": (snap.cwd as NSString).lastPathComponent, "cwd": snap.cwd,
                                      "agent": snap.agent ?? "claude-code", "activity": snap.activity]
            if let stage = snap.liveStage, stage.total > 0 { row["stage"] = "\(stage.step)/\(stage.total) \(stage.label)" }
            if let message = snap.message, !message.isEmpty { row["last"] = String(message.prefix(300)) }
            if let updated = snap.updatedAt { row["updatedAt"] = updated }
            return row
        }
        let steward: [String: Any] = ["key": key, "sessionId": String(key.split(separator: "#", maxSplits: 1).last ?? ""), "deviceId": settings.sourceId]
        Projects.collect { payload in
            let projects = (payload["projects"] as? [[String: Any]] ?? [])
                .filter { ($0["cwd"] as? String) != self.settings.cwd && $0["kind"] as? String != SourceKind.kiteline.rawValue }
                .sorted { Digest.number($0["lastActive"]) > Digest.number($1["lastActive"]) }
                .prefix(80)
                .map { item -> [String: Any] in
                    ["name": item["name"] ?? "", "path": item["cwd"] ?? "", "deviceId": item["sourceId"] ?? "", "device": item["sourceName"] ?? "",
                     "live": item["live"] ?? 0]
                }
            completion(["steward": steward, "devices": devices, "sessions": sessions.filter { ($0["key"] as? String) != key },
                        "projects": Array(projects)])
        }
    }

    // MARK: - 总管 / 被派活的会话发来的

    /// watcher 发图通道里的 steward_op（steward 子命令写的）
    func agentOp(key: String, item: [String: Any]) {
        DispatchQueue.main.async { self.perform(key: key, item: item) }
    }

    private func perform(key: String, item: [String: Any]) {
        let marker = "\(key)|\(item["id"] as? String ?? UUID().uuidString)"
        guard !handled.contains(marker) else { return }
        handled.append(marker)
        if handled.count > 400 { handled.removeFirst(100) }
        guard settings.enabled else {
            Log.write("总管模式：总管模式已关闭，忽略 \(key) 的 \(item["op"] as? String ?? "")")
            return
        }
        let op = item["op"] as? String ?? ""
        let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if op == "report" {
            report(from: key, text: text, images: item["images"] as? [String] ?? [])
            return
        }
        guard isSteward(key) else {
            Log.write("总管模式：\(key) 不是总管，忽略它的 \(op)")
            return
        }
        switch op {
        case "assign":
            for target in item["to"] as? [String] ?? [] { assign(text, to: target) }
        case "group":
            let members = [key] + (item["to"] as? [String] ?? []).filter { $0 != key }
            Groups.shared.stewardGroup(keys: members, topic: text, from: key)
            let names = members.dropFirst().compactMap { AppState.shared.store.record(withKey: $0)?.snapshot.displayTitle }
            noteBoard { $0.events.append(self.event("group", L("拉群：%@。%@", names.joined(separator: " × "), text), keys: Array(members.dropFirst()))) }
        case "new":
            startWorker(sourceId: item["device"] as? String ?? "", cwd: item["cwd"] as? String ?? "", agent: item["agent"] as? String, text: text)
        default:
            Log.write("总管模式：不认识的操作 \(op)")
        }
    }

    /// 派活：投进那个会话。末尾告诉它做完怎么回报
    private func assign(_ text: String, to target: String) {
        guard let record = AppState.shared.store.record(withKey: target) else {
            tell(L("【Kiteline】派活失败：会话已关闭（%@）。可以用 steward new 在它的项目里新开一个。", target)); return
        }
        let prompt = L("【Kiteline 总管派来的任务】") + "\n" + text + "\n\n" + footer(record.sourceId)
        if Delivery.dryRun { Log.write("[dry-run] 总管派活 → \(record.snapshot.displayTitle)：\(prompt)") }
        let snap = record.snapshot
        let task = Task(id: UUID().uuidString.prefix(8).lowercased(), key: record.key, op: "assign", title: snap.displayTitle, device: record.sourceName,
                        deviceId: record.sourceId, cwd: snap.cwd, text: String(text.prefix(500)), state: "sent", at: Self.now)
        noteBoard { board in
            board.tasks.append(task)
            board.events.append(self.event("assign", L("派给「%@」：%@", snap.displayTitle, text), keys: [record.key]))
        }
        deliver(prompt, task: task.id, key: record.key, since: Date())
    }

    /// 派活最多等多久：会话在等你确认时先排着（回车会替你点了确认框），确认完再送；等太久算没送到
    private static let queueLimit: TimeInterval = 15 * 60

    /// 把任务投进那个会话。它在等你确认：标成排队中，5 秒后再看（同会话群的投递）
    private func deliver(_ prompt: String, task id: String, key: String, since: Date) {
        guard let record = AppState.shared.store.record(withKey: key) else {
            noteBoard { board in
                if let i = board.tasks.firstIndex(where: { $0.id == id }) { board.tasks[i].state = "failed"; board.tasks[i].note = L("会话已关闭") }
            }
            return
        }
        let title = record.snapshot.displayTitle
        if !Delivery.viaBridge(record), Delivery.waitingProblem(record) != nil {
            guard Date().timeIntervalSince(since) < Self.queueLimit else {
                fail(id, key: key, title: title, message: L("会话一直在等你确认，未能派出"))
                return
            }
            if board.tasks.first(where: { $0.id == id })?.state != "queued" {
                noteBoard { board in
                    if let i = board.tasks.firstIndex(where: { $0.id == id }) { board.tasks[i].state = "queued" }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.deliver(prompt, task: id, key: key, since: since) }
            return
        }
        if board.tasks.first(where: { $0.id == id })?.state == "queued" {
            noteBoard { board in
                if let i = board.tasks.firstIndex(where: { $0.id == id }) { board.tasks[i].state = "sent" }
            }
        }
        Delivery.send(text: prompt, attachments: [], to: record, source: AppState.shared.source(withId: record.sourceId), submit: true) { outcome in
            guard !outcome.ok else { return }
            DispatchQueue.main.async { self.fail(id, key: key, title: title, message: outcome.message) }
        }
    }

    private func fail(_ id: String, key: String, title: String, message: String) {
        noteBoard { board in
            if let i = board.tasks.firstIndex(where: { $0.id == id }) { board.tasks[i].state = "failed"; board.tasks[i].note = message }
            board.events.append(self.event("failed", L("没送到「%@」：%@", title, message), keys: [key]))
        }
        tell(L("【Kiteline】派给「%@」的任务没有送到：%@", title, message))
    }

    /// 新开会话做这件事
    private func startWorker(sourceId: String, cwd: String, agent: String?, text: String) {
        guard let source = AppState.shared.config.sources.first(where: { $0.id == sourceId }),
              let connection = AppState.shared.source(withId: sourceId), connection.state.isLive else {
            tell(L("【Kiteline】新开会话失败：设备 %@ 离线或不存在", sourceId)); return
        }
        connection.request(["cmd": "is_dir", "path": cwd], timeout: 15) { result in
            DispatchQueue.main.async {
                guard case .success(let check) = result, check["isDir"] as? Bool == true else {
                    self.tell(L("【Kiteline】新开会话失败：%@ 上没有目录 %@", source.displayName, cwd)); return
                }
                let prompt = L("【Kiteline 总管派来的任务】") + "\n" + text + "\n\n" + self.footer(sourceId)
                let project = (cwd as NSString).lastPathComponent
                let task = Task(id: UUID().uuidString.prefix(8).lowercased(), key: "", op: "new", title: project, device: source.displayName,
                                deviceId: sourceId, cwd: cwd, text: String(text.prefix(500)), state: "sent", at: Self.now)
                self.noteBoard { board in
                    board.tasks.append(task)
                    board.events.append(self.event("new", L("在 %@ 新开会话（%@）：%@", source.displayName, project, text)))
                }
                let done: (NewSession.Outcome) -> Void = { outcome in
                    let line = outcome.ok ? L("【Kiteline】已在 %@ 的 %@ 新开会话：%@", source.displayName, cwd, outcome.message)
                                          : L("【Kiteline】在 %@ 的 %@ 新开会话失败：%@", source.displayName, cwd, outcome.message)
                    if !outcome.ok {
                        DispatchQueue.main.async {
                            self.noteBoard { board in
                                if let i = board.tasks.firstIndex(where: { $0.id == task.id }) { board.tasks[i].state = "failed"; board.tasks[i].note = outcome.message }
                                board.events.append(self.event("failed", L("新开会话失败（%@）：%@", project, outcome.message)))
                            }
                        }
                    }
                    self.tell(line)
                }
                let agent = (agent ?? "").isEmpty || agent == "claude-code" ? nil : agent
                Log.write("总管模式：在 \(source.displayName):\(cwd) 新开会话（\(agent ?? "Claude Code")）")
                if let agent {
                    MobileServer.startAgent(source, cwd: cwd, prompt: prompt, submit: true, sessionId: nil, agent: agent, accepted: { _ in }, completion: done)
                } else {
                    NewSession.start(source: source, cwd: cwd, prompt: prompt, submit: true, completion: done)
                }
            }
        }
    }

    /// 被派活的会话回报：投进总管的会话；带的截图先从它那台电脑取回来，跟着这条一起送过去（总管再 send-image 给用户）
    private func report(from key: String, text: String, images: [String]) {
        guard let sender = AppState.shared.store.record(withKey: key) else { return }
        let snap = sender.snapshot
        let head = L("【汇报 · 「%@」（%@ · %@）】", snap.displayTitle, sender.sourceName, (snap.cwd as NSString).lastPathComponent)
        noteBoard { board in
            if let i = board.tasks.lastIndex(where: { $0.key == key }) {
                board.tasks[i].state = "reported"
                board.tasks[i].reportAt = Self.now
                board.tasks[i].report = String(text.prefix(300))
                board.tasks[i].images = images.isEmpty ? nil : min(images.count, 6)
                board.tasks[i].title = snap.displayTitle
            }
            board.events.append(self.event("report", L("「%@」回报：%@", snap.displayTitle, text), keys: [key]))
        }
        guard !images.isEmpty, let connection = AppState.shared.source(withId: sender.sourceId) else {
            tell(head + "\n" + text); return
        }
        var attachments: [Delivery.Attachment] = []
        func fetch(_ rest: ArraySlice<String>) {
            guard let path = rest.first else {
                DispatchQueue.main.async { self.tell(head + "\n" + text, attachments: attachments) }
                return
            }
            connection.request(["cmd": "get_file", "path": path, "cwd": snap.cwd], timeout: 60) { result in
                if case .success(let reply) = result, let encoded = reply["data"] as? String, let data = Data(base64Encoded: encoded) {
                    attachments.append(.init(name: reply["name"] as? String ?? "image.png", data: data))
                }
                fetch(rest.dropFirst())
            }
        }
        fetch(images.prefix(6)[...])
    }

    /// 给总管的会话发一条（派活结果、汇报）：总管忙时后台送达会排到这一轮结束后
    private func tell(_ text: String, attachments: [Delivery.Attachment] = []) {
        DispatchQueue.main.async {
            guard let record = self.record else {
                Log.write("总管模式：总管会话不在，没送到：\(text.prefix(80))"); return
            }
            if Delivery.dryRun { Log.write("[dry-run] 告诉总管：\(text)") }
            Delivery.send(text: text, attachments: attachments, to: record, source: AppState.shared.source(withId: record.sourceId), submit: true) { outcome in
                if !outcome.ok { Log.write("总管模式：告诉总管失败：\(outcome.message)") }
            }
        }
    }

    private func footer(_ sourceId: String) -> String {
        let command = Groups.shared.command(for: sourceId)
        return L("做完、卡住或需要用户决定时，运行 %@ steward report \"结果或问题\" 向总管汇报（截图加 --image 路径）；总管会转告用户。", command)
    }

}
