#if !KITELINE_MAC
import Foundation

/// 演示模式：给手边没有 Mac 的人（App 审核员、想先看看的用户）体验一遍。
/// 不连任何 Mac：发给「演示 Mac」的请求由 DemoProtocol 截下，在手机本机由 DemoServer 应答。
/// 数据是 tests/record_demo.py 从跑着示例会话的测试实例录下来的（demo-data.json），时间整体挪到现在；
/// 回复、点允许 / 拒绝、回答提问、批准计划会接着演下去：Claude 回一句、会话状态跟着变、别的会话弹提醒
enum Demo {
    static let host = "demo.tars.invalid"
    static let mac = PairedMac(name: "演示电脑", addresses: [URL(string: "https://\(host)")!], token: "demo",
                               caCertificate: nil, remote: nil)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var on = false

    /// 正在演示（网络层、订阅判断、离线缓存都要看，不限线程）
    static var active: Bool { lock.withLock { on } }

    static func set(_ value: Bool) { lock.withLock { on = value } }

    static func isDemo(_ mac: PairedMac) -> Bool { mac.addresses.first?.host() == host }
}

/// 截下发给演示 Mac 的请求，交给 DemoServer。实时事件（/api/events）一直开着，有新事件就往下写
final class DemoProtocol: URLProtocol, @unchecked Sendable {
    private var stream: UUID?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == Demo.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { a, _ in a })
        if url.path == "/api/events" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // URLProtocol 的回调要回到开始加载的那个线程上做
            let loop = CFRunLoopGetCurrent()
            stream = DemoServer.shared.subscribe { [weak self] data in
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                    guard let self else { return }
                    self.client?.urlProtocol(self, didLoad: data)
                }
                CFRunLoopWakeUp(loop)
            }
            return
        }
        let reply = DemoServer.shared.respond(request.httpMethod ?? "GET", url.path, query, Self.body(of: request))
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if let stream { DemoServer.shared.unsubscribe(stream) }
    }

    /// URLSession 交给 URLProtocol 时常把 httpBody 换成流
    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

final class DemoServer: @unchecked Sendable {
    static let shared = DemoServer()

    struct Reply {
        var status: Int
        var type: String
        var data: Data
    }

    /// 匹配录下的回应时不看的参数：和 tests/record_demo.py 里的 VOLATILE 一致
    private static let volatile: Set<String> = ["since", "until", "limit", "v", "bytes", "before", "beforeTs", "reveal", "via", "thumb"]
    private static let unavailable = "演示模式不支持此功能，连接你的电脑后即可使用。"

    private let lock = NSLock()
    private var recorded: [String: Reply] = [:]
    private var state: [String: Any] = [:]
    private var histories: [String: [[String: Any]]] = [:]
    /// 演示用的待办（录的数据里没有：Mac 上的待办是用户自己的，不录）
    private var todos: [[String: Any]] = []
    private var todosHandled: [String] = []
    /// 会话群（演示一个「订单导出联调」：两个会话在群里往来，用户也在群里）
    private var demoGroups: [[String: Any]] = []
    private var demoGroupMessages: [String: [[String: Any]]] = [:]
    private var streams: [UUID: (Data) -> Void] = [:]
    private var serial = 50_000_000
    private var timers: [DispatchWorkItem] = []

    /// 每次进演示模式都从头来：录下的数据重新读一遍，时间挪到现在
    func reset() {
        lock.withLock {
            timers.forEach { $0.cancel() }
            timers = []
            recorded = [:]
            histories = [:]
            state = [:]
            guard let url = Bundle.main.url(forResource: "demo-data", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let responses = root["responses"] as? [String: [String: Any]] else { return }
            let shift = TimeShift(recordedAt: (root["recordedAt"] as? NSNumber)?.doubleValue ?? 0)
            for (key, entry) in responses {
                let status = (entry["status"] as? NSNumber)?.intValue ?? 200
                let type = entry["type"] as? String ?? "application/json"
                if let base64 = entry["data"] as? String {
                    recorded[key] = Reply(status: status, type: type, data: Data(base64Encoded: base64) ?? Data())
                } else if let text = entry["body"] as? String {
                    let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))).map(shift.apply)
                    let body = object.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data(text.utf8)
                    recorded[key] = Reply(status: status, type: type, data: body)
                    if key == "/api/state", var object = object as? [String: Any] {
                        // 录的时候电脑端还没有「关闭会话」：Claude Code 的会话补上 close（审核时能点卡片上的「×」看效果）
                        if let sessions = object["sessions"] as? [[String: Any]] {
                            object["sessions"] = sessions.map { session in
                                var session = session
                                let agent = session["agent"] as? String ?? Agents.defaultID
                                if agent == Agents.defaultID, session["caps"] == nil {
                                    session["caps"] = ["mode", "model", "compact", "subagents", "tests", "close"]
                                }
                                // 录的时候还没有任务阶段：在忙、等确认的会话按在做的事补上（列表里的「2/4 开发中」、对话页的任务进展）
                                if session["stage"] == nil, let stage = Self.demoStage(session) { session["stage"] = stage }
                                return session
                            }
                        }
                        state = object
                    }
                    // 就绪检查：演示里不提示「还差几步」（远程访问、权限这些跟演示无关）
                    if key == "/api/readiness", var object = object as? [String: Any], let items = object["items"] as? [[String: Any]] {
                        object["items"] = items.map { item in item.merging(["level": "ok"]) { $1 } }
                        recorded[key]?.data = (try? JSONSerialization.data(withJSONObject: object)) ?? body
                    }
                    // 头像：Mac 头像和内置头像图库（苹果的图）不录，演示里不列出来，免得一片取不到的图
                    if key == "/api/profile", var object = object as? [String: Any] {
                        object["avatar"] = "text"
                        object["hasMacPicture"] = false
                        object["groups"] = []
                        recorded[key]?.data = (try? JSONSerialization.data(withJSONObject: object)) ?? body
                    }
                    if key.hasPrefix("/api/history?"), let object = object as? [String: Any],
                       let sessionKey = URLComponents(string: key)?.queryItems?.first(where: { $0.name == "key" })?.value {
                        histories[sessionKey] = object["items"] as? [[String: Any]] ?? []
                    }
                }
            }
            #if SNAPSHOT
            // 截图版查长文字截断：TARS_DEMO_LONG=1 把会话标题、目录都换成很长的
            if ProcessInfo.processInfo.environment["TARS_DEMO_LONG"] == "1", var sessions = state["sessions"] as? [[String: Any]] {
                for i in sessions.indices {
                    let title = sessions[i]["title"] as? String ?? ""
                    sessions[i]["title"] = title + "，并补充完整的单元测试和集成测试，最后生成覆盖率报告发给我看看"
                    if let cwd = sessions[i]["cwd"] as? String { sessions[i]["cwd"] = cwd + "-enterprise-admin-dashboard-frontend-v2" }
                }
                state["sessions"] = sessions
            }
            // 截图版看换过头像的样子：TARS_DEMO_FACES={"sessions":{…},"agents":{…}}（会话按标题写，换成 key）
            if let raw = ProcessInfo.processInfo.environment["TARS_DEMO_FACES"],
               var faces = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
                let byTitle = (faces["sessions"] as? [String: Any] ?? [:]).reduce(into: [String: Any]()) { out, pair in
                    out[demoKey(pair.key) ?? pair.key] = pair.value
                }
                faces["sessions"] = byTitle
                state["faces"] = faces
            }
            #endif
            seedTodos()
            seedPeers()
            seedGroups()
        }
    }

    // MARK: Agent 详情、设备详情

    /// 演示电脑的设备详情：固定的一组数（录数据的那台电脑的 IP、型号、用户名不带进 App），CPU、内存跟着 sys 的数。调用时已经拿着锁
    private func demoMachine(_ sourceId: String) -> [String: Any] {
        let source = (state["sources"] as? [[String: Any]])?.first { $0["id"] as? String == sourceId }
        let sessions = (state["sessions"] as? [[String: Any]] ?? []).filter { $0["sourceId"] as? String == sourceId }
        var out: [String: Any] = [
            "ok": true, "id": sourceId, "name": source?["name"] as? String ?? "本机", "kind": source?["kind"] as? String ?? "local",
            "online": true, "status": "demo-mac 在线 · \(sessions.count) 会话", "computer": state["host"] as? String ?? "演示 Mac",
            "sessions": sessions.count, "busy": sessions.filter { ["busy", "waiting"].contains($0["activity"] as? String ?? "") }.count,
            "info": [
                "hostname": "demo-mac.local", "os": "macOS 26.1", "arch": "arm64", "cpuModel": "Apple M4 Pro", "cores": 12,
                "user": "demo", "memTotal": 34_359_738_368, "uptime": 273_600, "diskTotal": 994_662_584_320, "diskFree": 512_110_190_592,
                "python": "3.9.6", "watcher": "2.24.0", "primaryIp": "192.168.1.20", "ips": [["name": "en0", "ip": "192.168.1.20"]],
            ] as [String: Any],
            "agents": [
                ["id": "claude-code", "name": "Claude Code", "installed": true, "source": "builtin", "plugin": "2.24.0",
                 "forms": ["vscode": "2.1.300", "cli": "2.1.300"], "abilities": ["view", "reply", "approve", "answer"]],
                ["id": "codex", "name": "Codex", "installed": true, "source": "builtin", "plugin": "1.0.0",
                 "forms": ["cli": "", "vscode": "26.1016.1"], "abilities": ["view", "reply", "approve", "answer"]],
            ] as [[String: Any]],
        ]
        if let stats = machineStats[sourceId] { out["stats"] = stats }
        return out
    }

    private func demoAgentInfo(_ key: String) -> [String: Any] {
        let session = (state["sessions"] as? [[String: Any]])?.first { $0["key"] as? String == key }
        let agent = session?["agent"] as? String ?? Agents.defaultID
        let sourceId = session?["sourceId"] as? String ?? "local"
        let machine = demoMachine(sourceId)
        var out: [String: Any] = ["ok": true, "key": key, "agent": agent, "sourceId": sourceId, "live": session != nil, "machine": machine]
        let faces = state["faces"] as? [String: Any]
        if let face = (faces?["sessions"] as? [String: Any])?[key] { out["face"] = face }
        if let face = (faces?["agents"] as? [String: Any])?[agent] { out["agentFace"] = face }
        if let session {
            for field in ["title", "cwd", "entrypoint", "startedAt"] { out[field] = session[field] }
            out["sessionId"] = key.split(separator: "#").last.map(String.init)
            out["version"] = agent == Agents.defaultID ? "2.1.300" : nil
            out["model"] = (session["usage"] as? [String: Any])?["model"]
            out["pid"] = 40_000 + abs(key.hashValue % 9_000)
        }
        out["plugin"] = (machine["agents"] as? [[String: Any]])?.first { $0["id"] as? String == agent }
        return out
    }

    /// 演示里也能换头像、昵称（存在内存里，退出演示就没了；上传的图演示里不收）
    private func demoSaveFace(_ body: [String: Any]) -> Reply {
        let key = body["key"] as? String ?? "", agent = body["agent"] as? String ?? Agents.defaultID
        if body["image"] != nil { return json(["ok": false, "error": "演示模式下无法上传图片，可选择预设头像。"], status: 400) }
        var faces = state["faces"] as? [String: Any] ?? [:]
        var sessions = faces["sessions"] as? [String: Any] ?? [:], agents = faces["agents"] as? [String: Any] ?? [:]
        let name = String((body["name"] as? String ?? "").prefix(24)), avatar = body["avatar"] as? String ?? ""
        let face: [String: Any]? = name.isEmpty && avatar.isEmpty ? nil : ["name": name, "avatar": avatar]
        if body["scope"] as? String == "agent" {
            agents[agent] = face
            sessions[key] = nil
        } else {
            sessions[key] = face
        }
        faces = ["sessions": sessions, "agents": agents]
        state["faces"] = faces
        emit("state", state)
        return json(faces.merging(["ok": true]) { $1 })
    }

    // MARK: 会话之间的消息

    /// 演示里会话之间互发的消息：三条现成的往来（对话里有「发给 / 来自」的卡片、协作图有线、列表左边有风筝线），
    /// 之后每隔半分钟左右再有一条，会话列表上飞一只纸鸢。调用时已经拿着锁
    private var peerLinks: [String: [String: Any]] = [:]
    private var peerCount = 0

    private func seedPeers() {
        peerLinks = [:]
        peerCount = 0
        guard let busy = demoKey("首页卡片间距"), let plan = demoKey("订单导出功能") else { return }
        if let perm = demoKey("清理构建目录") {
            exchange(from: perm, to: busy, summary: "构建目录已清理", ago: 9 * 60_000,
                     text: "build 目录已清理并重新构建成功，可以重新跑测试了。")
        }
        exchange(from: busy, to: plan, summary: "告知卡片间距的最终取值", ago: 6 * 60_000,
                 text: "首页卡片间距已改为 16px，变量名 --card-gap，圆角 --card-radius: 12px。订单导出页复用卡片组件时直接用这两个变量。")
        exchange(from: plan, to: busy, summary: "导出页已同步卡片样式", ago: 4 * 60_000,
                 text: "收到。订单导出页的卡片已改用 --card-gap 和 --card-radius，等你那边测试通过后一起合并。")
        #if SNAPSHOT
        // 截图版逐帧看纸鸢：TARS_DEMO_FLIGHT=0～1 时连上就飞一只、停在这个位置（见 PeerBoard.frozen），不再定时飞
        if ProcessInfo.processInfo.environment["TARS_DEMO_FLIGHT"] != nil {
            later(0.8) { self.exchange(from: busy, to: plan, summary: "测试已全部通过", ago: 0, text: "单元测试 12 项全部通过，可以合并了。", history: false) }
            return
        }
        #endif
        later(12) { self.demoFlight() }
    }

    private func demoKey(_ title: String) -> String? {
        (state["sessions"] as? [[String: Any]])?.first { $0["title"] as? String == title }?["key"] as? String
    }

    /// 定时再飞一只：在几个演示会话之间轮着发
    private func demoFlight() {
        let keys = ["首页卡片间距", "订单导出功能", "清理构建目录", "选择登录方案"].compactMap(demoKey)
        guard keys.count >= 2 else { return }
        let from = keys[peerCount % keys.count], to = keys[(peerCount + 1 + peerCount / keys.count) % keys.count]
        if from != to {
            let lines = [("同步进度", "我这边改完了，你那边可以继续。"), ("请帮忙确认接口字段", "导出接口的字段名按你的约定改好了，帮忙确认一下。"),
                         ("测试已全部通过", "单元测试 12 项全部通过，可以合并了。")]
            let line = lines[peerCount % lines.count]
            exchange(from: from, to: to, summary: line.0, ago: 0, text: line.1, history: false)
        }
        peerCount += 1
        later(26) { self.demoFlight() }
    }

    /// 一条往来：记进往来表、推实时事件；history = 同时写进两边的对话（发出的那步 + 结果、收到的那条）
    private func exchange(from: String, to: String, summary: String, ago: Double, text: String, history: Bool = true) {
        peerCount += 1
        let id = "demo-peer-\(peerCount)-\(Int(now))"
        let sent = now - ago
        let sid = { (key: String) in String(key.split(separator: "#", maxSplits: 1).last ?? "") }
        let title = { (key: String) in self.session(key)?["title"] as? String ?? "" }
        var link: [String: Any] = ["id": id, "from": from, "to": to, "fromTitle": title(from), "toTitle": title(to),
                                   "summary": summary, "text": text, "sentAt": sent, "ok": true, "source": "local"]
        if ago > 0 { link["readAt"] = sent + 400 }
        peerLinks[id] = link
        if history {
            let toolId = "toolu_\(id)"
            histories[from, default: []].append(["id": nextId(), "ts": sent, "t": "tool", "toolId": toolId, "name": "SendMessage",
                                                 "input": ["to": sid(to), "summary": summary, "message": text],
                                                 "peer": ["dir": "out", "to": sid(to), "session": sid(to), "summary": summary, "text": text]])
            histories[from, default: []].append(["id": nextId(), "ts": sent + 100, "t": "result", "toolId": toolId, "msgId": id,
                                                 "text": "{\"success\":true,\"msg_id\":\"\(id)\"}"])
            histories[to, default: []].append(["id": nextId(), "ts": sent + 400, "t": "event", "text": "来自其他会话的消息",
                                               "peer": ["dir": "in", "session": sid(from), "msgId": id, "body": text, "text": text]])
        }
        emit("peers", ["links": [link]])
        if ago == 0 {
            // 对方过一会儿读到：收信那行闪一下
            later(1.6) {
                self.peerLinks[id]?["readAt"] = self.now
                if let read = self.peerLinks[id] { self.emit("peers", ["links": [read]]) }
            }
        }
    }

    /// 几条演示待办：两条出自会话里的消息（点一下跳回去），一条自己记的，一条已完成
    private func seedTodos() {
        todos = []
        todosHandled = []
        let hour = 3_600_000.0
        func source(_ title: String) -> [String: Any]? {
            guard let key = (state["sessions"] as? [[String: Any]])?.first(where: { $0["title"] as? String == title })?["key"] as? String,
                  let item = histories[key]?.last(where: { ["text", "user"].contains($0["t"] as? String) }),
                  let itemId = item["id"] as? String else { return nil }
            var source: [String: Any] = ["key": key, "itemId": itemId, "title": title, "machine": "本机"]
            if let ts = item["ts"] { source["ts"] = ts }
            return source
        }
        func todo(_ text: String, _ ago: Double, source: [String: Any]? = nil, done: Bool = false) {
            var item: [String: Any] = ["id": "demo-todo-\(todos.count + 1)", "text": text, "done": done, "createdAt": now - ago * hour, "images": []]
            if let source { item["source"] = source }
            if done { item["doneAt"] = now - ago * hour / 2 }
            todos.append(item)
        }
        todo("在 iPhone 15 上确认首页卡片的间距和圆角", 0.5, source: source("首页卡片间距"))
        todo("确认订单导出方案后，通知前端开始联调", 1, source: source("订单导出功能"))
        todo("周五前确认短信服务商的报价", 3)
        todo("合并首页样式改动到 main", 6, done: true)
        #if SNAPSHOT
        // 宣传图「待办」流程的后两步：TARS_DEMO_TODOS=asked 时，Codex 会话那条回复里的事已经加入待办
        if ProcessInfo.processInfo.environment["TARS_DEMO_TODOS"] == "asked",
           let key = (state["sessions"] as? [[String: Any]])?.first(where: { $0["agent"] as? String == "codex" })?["key"] as? String,
           let item = histories[key]?.last(where: { ($0["asks"] as? [String])?.isEmpty == false }),
           let itemId = item["id"] as? String, let asks = item["asks"] as? [String] {
            var from: [String: Any] = ["key": key, "itemId": itemId, "title": "订单接口限流", "machine": "本机"]
            if let ts = item["ts"] { from["ts"] = ts }
            for text in asks.reversed() { todos.insert(["id": "demo-todo-ask-\(todos.count)", "text": text, "done": false,
                                                       "createdAt": now - 60_000, "images": [], "source": from], at: 0) }
            todosHandled.append("\(key)|\(itemId)")
        }
        #endif
    }

    private var todoState: [String: Any] { ["items": todos, "suggestions": demoSuggestions, "handled": todosHandled] }

    /// agent 提醒你做、还没决定加不加的：演示里没有；截图构建 TARS_DEMO_SUGGEST=1 时造一条（看首页「待办」格子两个角标并存）
    private var demoSuggestions: [[String: Any]] {
        #if SNAPSHOT
        if ProcessInfo.processInfo.environment["TARS_DEMO_SUGGEST"] == "1" {
            return [["key": "local#demo-suggest", "itemId": "demo-suggest", "title": "订单接口限流", "machine": "本机",
                     "asks": ["在阿里云控制台开通短信签名", "把测试账号的密码发给前端"], "at": Date().timeIntervalSince1970 * 1000]]
        }
        #endif
        return []
    }

    /// 待办的增删改：只改内存里的这份，退出演示就没了。演示里不存截图
    private func todoAction(_ path: String, _ body: [String: Any]) -> Reply {
        switch path {
        case "/api/todos/add":
            for text in body["texts"] as? [String] ?? [] {
                var item: [String: Any] = ["id": "demo-todo-\(UUID().uuidString)", "text": text, "done": false, "createdAt": now, "images": []]
                if let key = body["key"] as? String, let itemId = body["itemId"] as? String {
                    item["source"] = ["key": key, "itemId": itemId, "title": body["title"] as? String ?? "", "machine": "本机", "ts": body["ts"] ?? now] as [String: Any]
                    todosHandled.append("\(key)|\(itemId)")
                }
                todos.append(item)
            }
        case "/api/todos/update":
            if let id = body["id"] as? String, let index = todos.firstIndex(where: { $0["id"] as? String == id }) {
                if let done = body["done"] as? Bool {
                    todos[index]["done"] = done
                    if done { todos[index]["doneAt"] = now } else { todos[index].removeValue(forKey: "doneAt") }
                }
                if let text = body["text"] as? String { todos[index]["text"] = text }
            }
        case "/api/todos/delete":
            let ids = Set(body["ids"] as? [String] ?? [])
            todos.removeAll { ids.contains($0["id"] as? String ?? "") }
        case "/api/todos/clear-done":
            todos.removeAll { $0["done"] as? Bool == true }
        case "/api/todos/dismiss":
            if let key = body["key"] as? String, let itemId = body["itemId"] as? String { todosHandled.append("\(key)|\(itemId)") }
            for entry in body["items"] as? [[String: Any]] ?? [] {
                if let key = entry["key"] as? String, let itemId = entry["itemId"] as? String { todosHandled.append("\(key)|\(itemId)") }
            }
        default:
            return json(["ok": false, "error": Self.unavailable], status: 400)
        }
        return json(todoState)
    }

    // MARK: 实时事件

    func subscribe(_ send: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        let first = lock.withLock { () -> Data in
            streams[id] = send
            return machineStats.reduce(Self.event("state", state)) { $0 + Self.event("sys", ["id": $1.key, "stats": $1.value]) }
        }
        send(Data("retry: 3000\n\n".utf8) + first)
        return id
    }

    /// 机器的 CPU、内存、网速（会话列表「按来源」分组时显示在机器名旁边）：录下的 state 里带着就用录的（截图版回放真实数据），
    /// 没有就给「本机」一组固定的数。调用时已经拿着锁
    private var machineStats: [String: Any] {
        state["sys"] as? [String: Any] ?? ["local": ["cpu": 0.18, "cores": 12, "memTotal": 34_359_738_368, "memUsed": 15_676_416_000,
                                                     "netIn": 186_000, "netOut": 42_000]]
    }

    func unsubscribe(_ id: UUID) {
        lock.withLock { _ = streams.removeValue(forKey: id) }
    }

    private static func event(_ name: String, _ payload: Any) -> Data {
        // 英文界面：同 respond，对话增量 entries 是内容，原样给
        var payload = Lang.shared.isEnglish && name != "entries" && name != "peers" ? ServerText.localize(payload) : payload
        if Lang.shared.isEnglish, name == "state", var state = payload as? [String: Any], (state["host"] as? String)?.hasPrefix("演示") == true {
            state["host"] = "Demo Mac"
            payload = state
        }
        let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Data("event: \(name)\ndata: \(json)\n\n".utf8)
    }

    /// 调用时已经拿着锁
    private func emit(_ name: String, _ payload: Any) {
        let data = Self.event(name, payload)
        streams.values.forEach { $0(data) }
    }

    // MARK: 接口

    /// 英文界面：演示数据里「电脑生成」的字（等待原因、就绪检查、出错提示……）同真电脑一样换成英文（ServerText）；
    /// 对话、文件这类只有内容的接口原样给（同 Mac 的 MobileServer.contentOnly）
    private static let contentOnly: Set<String> = ["/api/history", "/api/media", "/api/file", "/api/files", "/api/git/diff", "/api/digest/media",
                                                   "/api/task-output", "/api/search", "/api/changelog", "/api/agents", "/api/tts", "/api/peers",
                                                   "/api/groups/messages"]

    func respond(_ method: String, _ path: String, _ query: [String: String], _ body: [String: Any]) -> Reply {
        let reply = respondInChinese(method, path, query, body)
        guard Lang.shared.isEnglish, reply.type.hasPrefix("application/json"), !Self.contentOnly.contains(path) else { return reply }
        // 演示数据里的电脑名（录的时候叫「演示 Mac」）英文界面里叫 Demo Mac
        if path == "/api/state" || path == "/api/info", var object = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any],
           let host = object["host"] as? String, host.hasPrefix("演示") {
            object["host"] = "Demo Mac"
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? reply.data
            return Reply(status: reply.status, type: reply.type, data: ServerText.localize(json: data))
        }
        return Reply(status: reply.status, type: reply.type, data: ServerText.localize(json: reply.data, extra: path == "/api/readiness" ? ["title"] : []))
    }

    private func respondInChinese(_ method: String, _ path: String, _ query: [String: String], _ body: [String: Any]) -> Reply {
        #if SNAPSHOT
        // 截图版看出错的样子：TARS_DEMO_FAIL=/api/inbox,/api/digest 这些接口一律回错误
        if let fail = ProcessInfo.processInfo.environment["TARS_DEMO_FAIL"], fail.split(separator: ",").contains(where: { path.hasPrefix($0) }) {
            return json(["ok": false, "error": "电脑读取数据时出错（截图版模拟的错误）"], status: 500)
        }
        #endif
        return lock.withLock {
            let key = query["key"] ?? ""
            switch (method, path) {
            case ("GET", "/api/state"):
                return json(state.merging(["sys": machineStats]) { $1 })
            case ("GET", "/api/history"):
                // 往前翻页、子 agent 的记录：演示数据里没有更早的
                if query["before"] != nil || query["beforeTs"] != nil || query["agent"] != nil {
                    return json(["ok": true, "hasMore": false, "items": []])
                }
                return json(["ok": true, "hasMore": false, "items": histories[key] ?? []])
            case ("GET", "/api/todos"):
                return json(todoState)
            case ("GET", "/api/machine"):
                return json(demoMachine(query["source"] ?? "local"))
            case ("GET", "/api/agent-info"):
                return json(demoAgentInfo(key))
            case ("POST", "/api/agent-face"):
                return demoSaveFace(body)
            case ("GET", "/api/peers"):
                return json(["links": peerLinks.values.sorted { ($0["sentAt"] as? Double ?? 0) < ($1["sentAt"] as? Double ?? 0) }])
            case ("POST", let todoPath) where todoPath.hasPrefix("/api/todos/"):
                return todoAction(todoPath, body)
            case (_, let groupPath) where groupPath == "/api/groups" || groupPath.hasPrefix("/api/groups/"):
                return groupAction(method, groupPath, query, body)
            case ("GET", "/api/ping"):
                return Reply(status: 200, type: "application/octet-stream", data: Data(count: Int(query["bytes"] ?? "0") ?? 0))
            case ("POST", "/api/send"), ("POST", "/api/resume"):
                return send(key, body["text"] as? String ?? "")
            case ("POST", "/api/voice"):
                let text = "首页按钮偏小，请适当放大，并截图给我确认"
                if body["mode"] as? String == "text" { return json(["ok": true, "text": text]) }
                var reply = send(key, text)
                reply.data = (try? JSONSerialization.data(withJSONObject: ["ok": true, "submitted": true, "text": text])) ?? reply.data
                return reply
            case ("POST", "/api/key"):
                return press(key, body["key"] as? String ?? "")
            case ("POST", "/api/close"):
                // 关闭会话：从列表里拿掉（演示里不会真的关电脑上的窗口）
                guard var sessions = state["sessions"] as? [[String: Any]], sessions.contains(where: { $0["key"] as? String == key }) else {
                    return json(["ok": false, "error": "会话不存在或已结束"], status: 404)
                }
                sessions.removeAll { $0["key"] as? String == key }
                state["sessions"] = sessions
                emit("state", state)
                return json(["ok": true, "message": "已关闭会话"])
            case ("POST", "/api/answer"):
                return answer(key, body["answers"] as? [[String: Any]] ?? [], toolId: body["toolId"] as? String ?? "")
            case ("POST", "/api/pin"):
                toggle("pinned", body["key"] as? String ?? "", body["pinned"] as? Bool ?? false)
                return json(["ok": true])
            case ("POST", "/api/mark"):
                toggle("marked", body["key"] as? String ?? "", body["marked"] as? Bool ?? false, front: true)
                return json(["ok": true])
            case ("POST", "/api/mute"):
                toggle("muted", body["key"] as? String ?? "", body["muted"] as? Bool ?? false)
                return json(["ok": true])
            case ("POST", "/api/quick-replies"):
                if let items = body["items"] as? [String] { state["quickReplies"] = items; emit("state", state) }
                return json(["ok": true, "items": state["quickReplies"] ?? []])
            case ("POST", "/api/presence"), ("POST", "/api/viewed"), ("POST", "/api/watch/status"), ("POST", "/api/clientlog"), ("POST", "/api/watch"),
                 ("POST", "/api/quiet"), ("POST", "/api/budget"), ("POST", "/api/profile"):
                return json(["ok": true])
            case ("POST", _):
                return json(["ok": false, "error": Self.unavailable], status: 400)
            default:
                return lookup(path, query)
            }
        }
    }

    private func lookup(_ path: String, _ query: [String: String]) -> Reply {
        var parts = URLComponents()
        parts.path = path
        let kept = query.filter { !Self.volatile.contains($0.key) }.sorted { $0.key < $1.key }
        if !kept.isEmpty {
            // 和 Python 的 urlencode 一样编码，才对得上录下的 key
            parts.percentEncodedQuery = kept.map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }.joined(separator: "&")
        }
        let key = parts.string ?? path
        if let hit = recorded[key] { return hit }
        return json(["ok": false, "error": "演示模式不提供此数据，连接你的电脑后即可查看。"], status: 404)
    }

    private static func encode(_ text: String) -> String {
        // 只留 ASCII 字母数字和 _.-~（中文也要编码），空格写成 +
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~ ")
        return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text).replacingOccurrences(of: " ", with: "+")
    }

    private func json(_ object: Any, status: Int = 200) -> Reply {
        Reply(status: status, type: "application/json", data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    // MARK: 演下去

    private var now: Double { Date().timeIntervalSince1970 * 1000 }

    private func nextId() -> String {
        serial += 1000
        return "\(serial).0"
    }

    private func add(_ key: String, _ item: [String: Any]) {
        var item = item
        item["id"] = nextId()
        item["ts"] = now
        histories[key, default: []].append(item)
        emit("entries", ["key": key, "items": [item]])
    }

    private func update(_ key: String, _ change: (inout [String: Any]) -> Void) {
        guard var sessions = state["sessions"] as? [[String: Any]], let index = sessions.firstIndex(where: { $0["key"] as? String == key }) else { return }
        change(&sessions[index])
        sessions[index]["updatedAt"] = now
        state["sessions"] = sessions
        emit("state", state)
    }

    /// 演示会话的任务阶段：等提问 → 调研，批准计划 → 自定流程里的方案设计，跑测试 → 测试（pnpm 那个是分了三个端的任务），编译 → 开发；前面几步各用了几分钟
    static func demoStage(_ session: [String: Any]) -> [String: Any]? {
        guard ["busy", "waiting"].contains(session["activity"] as? String ?? "") else { return nil }
        let doing = (session["activityText"] as? String ?? "") + " " + (session["pendingTool"] as? String ?? "")
        let standard = ["调研了解", "开发中", "测试中", "汇报中"]
        let (steps, step, note): ([String], Int, String?) =
            doing.contains("ExitPlanMode") ? (["调研了解", "方案设计", "开发中", "测试中", "发布中"], 2, "导出接口与分页方案")
            : doing.contains("AskUserQuestion") ? (standard, 1, nil)
            : doing.contains("test") ? (standard, 3, "跑相关的单元测试")
            : (standard, 2, nil)
        let now = Date().timeIntervalSince1970 * 1000
        let minutes = [6.0, 14.0, 5.0, 3.0, 2.0]
        var at = now - minutes.prefix(step).reduce(0, +) * 60_000
        var marks: [[Double]] = []
        for index in 0..<step {
            marks.append([Double(index + 1), at])
            at += minutes[index] * 60_000
        }
        var stage: [String: Any] = ["step": step, "total": steps.count, "label": steps[step - 1], "steps": steps, "since": marks.last?[1] ?? now,
                                    "turnAt": marks.first?[1] ?? now, "auto": note == nil, "marks": marks]
        if let note { stage["note"] = note }
        if doing.contains("pnpm") {
            stage["part"] = "Android"
            stage["parts"] = [["name": "iOS", "step": 4, "done": true], ["name": "Android", "step": step, "done": false],
                              ["name": "网页", "step": 0, "done": false]]
            stage["auto"] = false
        }
        return stage
    }

    private func session(_ key: String) -> [String: Any]? {
        (state["sessions"] as? [[String: Any]])?.first { $0["key"] as? String == key }
    }

    private func working(_ key: String, _ what: String) {
        update(key) {
            $0["activity"] = "busy"
            $0["activityText"] = what
            $0["reason"] = what
            $0["blocking"] = nil
            $0["pendingTool"] = nil
            $0["error"] = nil
            if $0["stage"] == nil { $0["stage"] = Self.demoStage($0) }
        }
    }

    /// Claude 说完这一轮：会话空闲，别的页面开着时弹「有结论了」
    private func finish(_ key: String, _ text: String) {
        add(key, ["t": "text", "text": text, "model": "claude-opus-5-5"])
        update(key) {
            $0["activity"] = "idle"
            $0["activityText"] = nil
            $0["reason"] = nil
            $0["preview"] = text
        }
        let title = session(key)?["title"] as? String ?? "会话"
        emit("notify", ["kind": "conclusion", "title": title, "body": String(text.prefix(80)), "key": key, "at": now])
    }

    /// 过一会儿再做（锁外排队，执行时再拿锁）
    private func later(_ seconds: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock { work() }
        }
        timers.append(item)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func send(_ key: String, _ text: String) -> Reply {
        guard session(key) != nil else { return json(["ok": false, "error": "会话不存在或已结束"], status: 404) }
        add(key, ["t": "user", "text": text])
        working(key, "思考中")
        later(1.2) {
            self.add(key, ["t": "thinking", "text": "用户在演示模式里发来一句话，回一句说明真实使用时会发生什么。", "model": "claude-opus-5-5"])
        }
        later(3) {
            self.finish(key, "（演示）收到：「\(text.prefix(40))」\n\n"
                + "连接你的电脑后，这条消息会发送到电脑上正在运行的 Claude Code 会话，由 Claude 继续执行；"
                + "任务完成或需要确认时，手机和手表都会提醒你。")
        }
        return json(["ok": true, "submitted": true])
    }

    /// 等你确认时按的键：1 / 2 / enter 是同意，esc 是拒绝（计划卡片上是「继续规划」）
    private func press(_ key: String, _ button: String) -> Reply {
        guard let current = session(key) else { return json(["ok": false, "error": "会话不存在或已结束"], status: 404) }
        if button == "shift+tab" { return json(["ok": true]) }
        let open = (histories[key] ?? []).last { item in
            item["t"] as? String == "tool" && !(histories[key] ?? []).contains { $0["t"] as? String == "result" && $0["toolId"] as? String == item["toolId"] as? String }
        }
        let toolId = open?["toolId"] as? String ?? ""
        let name = open?["name"] as? String ?? (current["pendingTool"] as? String ?? "")
        let waiting = current["activity"] as? String == "waiting"

        if button == "esc" {
            if !waiting {
                // 正在干活时按 Esc = 中断
                update(key) { $0["activity"] = "idle"; $0["activityText"] = nil; $0["reason"] = nil }
                add(key, ["t": "event", "text": "已中断", "level": "info"])
                return json(["ok": true])
            }
            add(key, ["t": "result", "toolId": toolId, "text": "The user doesn't want to proceed with this tool use.", "isError": true])
            finish(key, name == "ExitPlanMode" ? "好的，方案暂不执行。请告诉我需要调整哪一步。" : "好的，此步骤暂不执行。如需更换方案，请告诉我。")
            return json(["ok": true])
        }
        guard waiting else { return json(["ok": true]) }

        if name == "ExitPlanMode" {
            add(key, ["t": "result", "toolId": toolId, "text": "User has approved your plan. You can now start coding."])
            working(key, "TodoWrite")
            let todos: [[String: Any]] = [
                ["content": "后端新增导出接口", "status": "in_progress", "activeForm": "正在编写导出接口"],
                ["content": "订单列表加「导出」按钮", "status": "pending", "activeForm": "添加导出按钮"],
                ["content": "大数据量改为异步任务", "status": "pending", "activeForm": "改为异步任务"],
            ]
            let todoId = "toolu_demo_\(serial)"
            add(key, ["t": "tool", "name": "TodoWrite", "toolId": todoId, "input": ["todos": todos], "brief": "TodoWrite", "model": "claude-opus-5-5"])
            add(key, ["t": "result", "toolId": todoId, "text": "Todos have been modified successfully"])
            later(3) {
                self.finish(key, "方案已批准，开始实施：先编写后端导出接口，再添加前端按钮。\n\n（演示到此结束。实际使用时，Claude 会在你的电脑上逐步修改代码，任务清单进度可在手机上实时查看。）")
            }
            return json(["ok": true])
        }

        let command = (open?["input"] as? [String: Any])?["command"] as? String
        working(key, command.map { "\(name): \($0)" } ?? name)
        later(1.5) {
            let output = command?.contains("build") == true
                ? "> shop-app@1.4.0 build\n> vite build\n\n✓ 142 modules transformed.\ndist/index.html          0.46 kB\ndist/assets/index.css   18.20 kB\ndist/assets/index.js   146.71 kB\n✓ built in 1.84s"
                : "完成"
            self.add(key, ["t": "result", "toolId": toolId, "text": output])
        }
        later(3.5) {
            self.finish(key, command?.contains("build") == true
                ? "构建完成：`build` 目录已清空并重新生成，共 142 个模块，用时 1.8 秒，无报错。"
                : "已执行完毕。")
        }
        return json(["ok": true])
    }

    private func answer(_ key: String, _ answers: [[String: Any]], toolId: String) -> Reply {
        guard session(key) != nil else { return json(["ok": false, "error": "会话不存在或已结束"], status: 404) }
        var lines: [String] = []
        var first: String?
        for item in answers {
            var parts = (item["picked"] as? [String] ?? []).filter { !$0.isEmpty }
            if let other = item["other"] as? String, !other.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(other) }
            guard !parts.isEmpty else { continue }
            first = first ?? parts.first
            let question = item["question"] as? String ?? ""
            lines.append(question.isEmpty ? "• \(parts.joined(separator: "、"))" : "• \(question)\n  → \(parts.joined(separator: "、"))")
        }
        guard !lines.isEmpty else { return json(["ok": false, "error": "未选择任何选项"], status: 400) }
        add(key, ["t": "result", "toolId": toolId, "text": "用户已在手机上回答", "isError": true])
        add(key, ["t": "user", "text": "（回答你刚才的提问）\n" + lines.joined(separator: "\n")])
        working(key, "思考中")
        later(3) {
            self.finish(key, "好的，按「\(first ?? "你选的方案")」执行。我先搭建登录页的结构，完成后截图给你确认。\n\n（演示到此结束。实际使用时，Claude 会根据你的回答在电脑上继续执行。）")
        }
        return json(["ok": true, "submitted": true])
    }

    private func toggle(_ field: String, _ key: String, _ on: Bool, front: Bool = false) {
        var list = state[field] as? [String] ?? []
        list.removeAll { $0 == key }
        if on { if front { list.insert(key, at: 0) } else { list.append(key) } }
        state[field] = list
        emit("state", state)
    }
}

/// 把录的时间挪到现在：时间戳（毫秒、秒）整体加上「现在 − 录的时候」，日期（2026-10-21）按天挪
private struct TimeShift {
    let recordedAt: Double
    let delta: Double
    let days: Int

    init(recordedAt: Double) {
        self.recordedAt = recordedAt
        let now = Date().timeIntervalSince1970 * 1000
        delta = recordedAt > 0 ? now - recordedAt : 0
        let calendar = Calendar.current
        days = recordedAt > 0 ? (calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSince1970: recordedAt / 1000)),
                                                         to: calendar.startOfDay(for: Date())).day ?? 0) : 0
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func apply(_ value: Any) -> Any {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return number }
            let v = number.doubleValue
            let span = 400 * 86_400_000.0
            var shifted: Double?
            if v > recordedAt - span, v < recordedAt + 86_400_000 { shifted = v + delta }
            else if v > (recordedAt - span) / 1000, v < (recordedAt + 86_400_000) / 1000 { shifted = v + delta / 1000 }
            guard let shifted else { return number }
            return CFNumberIsFloatType(number) ? NSNumber(value: shifted) : NSNumber(value: Int64(shifted.rounded()))
        case let text as String:
            guard days != 0, text.count == 10, text.dropFirst(4).first == "-", let date = Self.day.date(from: text),
                  let moved = Calendar.current.date(byAdding: .day, value: days, to: date) else { return text }
            return Self.day.string(from: moved)
        case let list as [Any]:
            return list.map(apply)
        case let object as [String: Any]:
            return object.mapValues(apply)
        default:
            return value
        }
    }
}
// MARK: - 会话群（演示）

extension DemoServer {
    /// 演示群：「订单导出功能」和「首页卡片间距」在群里约好接口字段，用户也说了一句（同真电脑 Sources/Groups.swift 的数据形状）
    fileprivate func seedGroups() {
        demoGroups = []
        demoGroupMessages = [:]
        if var features = state["features"] as? [String] {
            if !features.contains("groups") { features.append("groups") }
            state["features"] = features
        } else {
            state["features"] = ["files", "groups"]
        }
        guard let plan = demoKey("订单导出功能"), let home = demoKey("首页卡片间距") else { return }
        let minute = 60_000.0
        let members: [[String: Any]] = [
            ["key": plan, "title": "订单导出功能", "machine": "演示 Mac", "project": "admin", "joinedAt": now - 40 * minute],
            ["key": home, "title": "首页卡片间距", "machine": "演示 Mac", "project": "shop-app", "joinedAt": now - 40 * minute],
        ]
        var serial = 0
        func message(_ from: String, _ title: String, _ text: String, _ ago: Double, event: String? = nil, args: [String] = []) -> [String: Any] {
            serial += 1
            var out: [String: Any] = ["id": "demo-gm-\(serial)", "ts": now - ago * minute, "from": from, "fromTitle": title, "text": text]
            if from != "system" { out["states"] = Dictionary(uniqueKeysWithValues: [plan, home].filter { $0 != from }.map { ($0, "sent") }) }
            if let event { out["event"] = event; out["args"] = args }
            return out
        }
        let messages = [
            message("system", "", "建群：订单导出功能、首页卡片间距", 40, event: "created", args: ["订单导出功能", "首页卡片间距"]),
            message("me", "用户", "订单导出接口改完后告诉首页那边，首页再接新字段。", 39.5),
            message("system", "", "订单导出功能 给群起名「订单导出联调」", 31, event: "named", args: ["订单导出功能", "订单导出联调"]),
            message(plan, "订单导出功能", "导出接口已经改好：新增 `exportedAt`、`operator` 两个字段，接口文档在 docs/export.md。首页那边可以开始接了。", 31),
            message(home, "首页卡片间距", "收到，我这边改完卡片后发截图给你核对字段显示。", 28),
            message(home, "首页卡片间距", "首页卡片已经接上新字段，截图发在我的会话里了，导出时间按本地时区显示。", 6),
        ]
        // 截图用：TARS_DEMO_GROUP_FLAGS=marked,muted 让演示群带上标记、免打扰
        let flags = (ProcessInfo.processInfo.environment["TARS_DEMO_GROUP_FLAGS"] ?? "").split(separator: ",")
        let group: [String: Any] = ["id": "demo-group-1", "name": "订单导出联调", "autoName": false, "createdAt": now - 40 * minute,
                                    "updatedAt": now - 6 * minute, "paused": false, "members": members, "count": 4, "last": messages.last!,
                                    "marked": flags.contains("marked"), "muted": flags.contains("muted")]
        demoGroups = [group]
        demoGroupMessages["demo-group-1"] = messages
    }

    /// /api/groups…：列表、消息；在群里发话（记成已送达，演示里不会真的投递）、建群、加人、改名、暂停、标记、免打扰、解散
    fileprivate func groupAction(_ method: String, _ path: String, _ query: [String: String], _ body: [String: Any]) -> Reply {
        let id = body["id"] as? String ?? query["id"] ?? ""
        let index = demoGroups.firstIndex { $0["id"] as? String == id }
        func changed() -> Reply {
            let payload: [String: Any] = ["ok": true, "items": demoGroups]
            emit("groups", payload)
            return json(index.map { ["ok": true, "group": demoGroups.indices.contains($0) ? demoGroups[$0] : [:]] } ?? payload)
        }
        switch (method, path) {
        case ("GET", "/api/groups"):
            return json(["ok": true, "items": demoGroups])
        case ("GET", "/api/groups/messages"):
            guard index != nil else { return json(["ok": false, "error": "会话群不存在"], status: 404) }
            return json(["ok": true, "id": id, "items": demoGroupMessages[id] ?? []])
        case ("POST", "/api/groups/send"):
            guard let index, let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return json(["ok": false, "error": "内容为空"], status: 400)
            }
            let members = (demoGroups[index]["members"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
            let message: [String: Any] = ["id": "demo-gm-\(Int(now))", "ts": now, "from": "me", "fromTitle": "用户", "text": text,
                                          "states": Dictionary(uniqueKeysWithValues: members.map { ($0, "sent") })]
            demoGroupMessages[id, default: []].append(message)
            demoGroups[index]["last"] = message
            demoGroups[index]["updatedAt"] = now
            emit("group_msg", ["id": id, "message": message])
            _ = changed()
            return json(["ok": true, "message": message])
        case ("POST", "/api/groups/create"):
            let keys = body["keys"] as? [String] ?? []
            guard keys.count >= 2 else { return json(["ok": false, "error": "至少选两个会话"], status: 400) }
            let sessions = state["sessions"] as? [[String: Any]] ?? []
            let members: [[String: Any]] = keys.map { key in
                let session = sessions.first { $0["key"] as? String == key } ?? [:]
                return ["key": key, "title": session["title"] ?? "会话", "machine": "演示 Mac",
                        "project": ((session["cwd"] as? String) as NSString?)?.lastPathComponent ?? "", "joinedAt": now]
            }
            let newId = "demo-group-\(demoGroups.count + 1)"
            let titles = members.compactMap { $0["title"] as? String }
            let created: [String: Any] = ["id": "demo-gm-c\(Int(now))", "ts": now, "from": "system", "fromTitle": "", "text": "建群：" + titles.joined(separator: "、"),
                                          "event": "created", "args": titles]
            demoGroups.insert(["id": newId, "name": titles.prefix(3).joined(separator: "、"), "autoName": true, "createdAt": now, "updatedAt": now,
                               "paused": false, "members": members, "count": 0, "last": created], at: 0)
            demoGroupMessages[newId] = [created]
            emit("groups", ["ok": true, "items": demoGroups])
            return json(["ok": true, "group": demoGroups[0]])
        case ("POST", "/api/groups/rename"):
            guard let index, let name = body["name"] as? String, !name.isEmpty else { return json(["ok": false, "error": "群名不能为空"], status: 400) }
            demoGroups[index]["name"] = name
            demoGroups[index]["autoName"] = false
            return changed()
        case ("POST", "/api/groups/pause"):
            guard let index else { return json(["ok": false, "error": "会话群不存在"], status: 404) }
            demoGroups[index]["paused"] = body["paused"] as? Bool ?? true
            return changed()
        case ("POST", "/api/groups/mark"), ("POST", "/api/groups/mute"):
            guard let index else { return json(["ok": false, "error": "会话群不存在"], status: 404) }
            let field = path.hasSuffix("/mark") ? "marked" : "muted"
            demoGroups[index][field] = body[field] as? Bool ?? true
            return changed()
        case ("POST", "/api/groups/add"):
            guard let index else { return json(["ok": false, "error": "会话群不存在"], status: 404) }
            let sessions = state["sessions"] as? [[String: Any]] ?? []
            var members = demoGroups[index]["members"] as? [[String: Any]] ?? []
            for key in body["keys"] as? [String] ?? [] where !members.contains(where: { $0["key"] as? String == key }) {
                let session = sessions.first { $0["key"] as? String == key } ?? [:]
                members.append(["key": key, "title": session["title"] ?? "会话", "machine": "演示 Mac",
                                "project": ((session["cwd"] as? String) as NSString?)?.lastPathComponent ?? "", "joinedAt": now])
            }
            demoGroups[index]["members"] = members
            return changed()
        case ("POST", "/api/groups/remove"):
            guard let index else { return json(["ok": false, "error": "会话群不存在"], status: 404) }
            let key = body["key"] as? String
            demoGroups[index]["members"] = (demoGroups[index]["members"] as? [[String: Any]] ?? []).filter { $0["key"] as? String != key }
            return changed()
        case ("POST", "/api/groups/delete"):
            demoGroups.removeAll { $0["id"] as? String == id }
            demoGroupMessages[id] = nil
            emit("groups", ["ok": true, "items": demoGroups])
            return json(["ok": true, "items": demoGroups])
        default:
            return json(["ok": false, "error": "未知的会话群接口"], status: 404)
        }
    }
}

#endif
