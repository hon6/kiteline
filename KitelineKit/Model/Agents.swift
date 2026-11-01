import Foundation

/// 子 agent、后台任务（Agent map）和权限模式

// MARK: 子 agent / 后台任务（/api/agents）

struct SubagentInfo: Decodable, Identifiable, Hashable {
    struct ToolCall: Decodable, Hashable { var name: String; var brief: String? }

    var id: String
    var description: String
    var agentType: String?
    var model: String?
    var requestShape: String?
    var depth: Int
    var finished: Bool
    var startedAt: Double?
    var endedAt: Double?
    var tokens: Int
    var prompt: String
    var tools: [ToolCall]
    var report: String
    /// 谁派的：main = 主 agent，否则是另一个子 agent 的 id
    var parent: String

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? UUID().uuidString
        description = c.text("description") ?? L("子 agent")
        agentType = c.text("agentType"); model = c.text("model"); requestShape = c.text("requestShape")
        depth = max(1, c.int("depth"))
        finished = c.truthy("finished")
        startedAt = c.one("startedAt"); endedAt = c.one("endedAt")
        tokens = c.int("tokens")
        prompt = c.text("prompt") ?? ""; tools = c.list("tools"); report = c.text("report") ?? ""
        parent = c.text("parent") ?? "main"
    }

    /// 「1m 23s」：做完的按首尾时间，还在跑的算到现在
    var duration: String { AgentFormat.span(startedAt, finished ? endedAt : nil) }
}

struct BackgroundTask: Decodable, Identifiable, Hashable {
    var id: String
    var description: String
    var command: String
    /// running / completed / failed / killed
    var status: String
    var startedAt: Double?
    var endedAt: Double?
    var summary: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? UUID().uuidString
        description = c.text("description") ?? L("后台命令")
        command = c.text("command") ?? ""
        status = c.text("status") ?? "running"
        startedAt = c.one("startedAt"); endedAt = c.one("endedAt"); summary = c.text("summary")
    }

    var running: Bool { status == "running" }
    var duration: String { AgentFormat.span(startedAt, running ? nil : endedAt) }
    var statusText: String { ["running": L("运行中"), "completed": L("已完成"), "failed": L("失败"), "killed": L("已停止")][status] ?? status }
}

struct AgentsReply: Decodable {
    var agents: [SubagentInfo]
    var tasks: [BackgroundTask]

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        agents = c.list("agents"); tasks = c.list("tasks")
    }
}

enum AgentFormat {
    /// 开始到结束（没结束就到现在）的时长：「45s」「1m 23s」「1h 5m」
    static func span(_ start: Double?, _ end: Double?) -> String {
        guard let start else { return "" }
        let stop = end ?? Date().timeIntervalSince1970 * 1000
        return Format.duration(max(0, Int((stop - start) / 1000)))
    }

    /// 「39.2k」「1.2M」
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

// MARK: 权限模式（Claude Code 里 ⇧Tab 依次切换）

enum PermissionMode: String, CaseIterable, Identifiable {
    case manual = "default"
    case acceptEdits
    case plan
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return L("手动")
        case .acceptEdits: return L("自动接受编辑")
        case .plan: return L("计划")
        case .auto: return L("自动")
        }
    }

    var detail: String {
        switch self {
        case .manual: return L("每次修改文件前均需确认")
        case .acceptEdits: return L("修改文件无需确认，其他操作照常确认")
        case .plan: return L("先分析代码并制定计划，经你批准后再执行")
        case .auto: return L("通过安全检查的操作自动放行，存在风险的操作需要确认")
        }
    }

    var symbol: String {
        switch self {
        case .manual: return "hand.raised"
        case .acceptEdits: return "chevron.left.forwardslash.chevron.right"
        case .plan: return "list.bullet.clipboard"
        case .auto: return "bolt"
        }
    }

    /// ⇧Tab 的顺序（和 VS Code 里模式菜单的顺序一样）
    static let cycle: [PermissionMode] = [.manual, .acceptEdits, .plan, .auto]

    /// 对话记录里的值；没记过（老版本或还没说过话）当作手动；跳过所有确认的模式不在 ⇧Tab 里，返回 nil
    static func from(_ raw: String?) -> PermissionMode? {
        guard let raw else { return .manual }
        return PermissionMode(rawValue: raw)
    }
}

enum EffortLevel {
    static var all: [(id: String, name: String)] { [("auto", L("自动")), ("low", L("低")), ("medium", L("中")), ("high", L("高")), ("xhigh", L("超高")), ("max", L("最高"))] }

    static func name(_ id: String?) -> String { all.first { $0.id == (id ?? "auto") }?.name ?? (id ?? L("自动")) }
}

// MARK: 模型（Claude Code 里的 /model）

enum ModelChoice {
    static let all: [(id: String, name: String)] = [
        ("claude-fable-5-1", "Fable 5.1"), ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-haiku-5-5", "Haiku 5.5"),
    ]
}

extension AppModel {
    /// 会话现在是哪个模式：刚在手机上切过、Claude Code 还没在记录里写下新模式（要等你下一句话）时，先按切过去的算
    func permissionMode(_ key: String) -> PermissionMode? {
        let server = session(key)?.permissionMode
        if let override = chat(key).modeOverride, override.baseline == server { return override.mode }
        return PermissionMode.from(server)
    }

    /// 会话现在用的模型：刚在手机上换过、Claude 还没用新模型回过话时，按换过去的算
    func currentModel(_ key: String) -> String? {
        let used = session(key)?.usage?.model
        let chat = chat(key)
        if let override = chat.modelOverride, override.baseline == used, !chat.sendFailed(override.send) { return override.model }
        return used
    }

    /// 换模型：在这个会话里发一条 /model（和在 VS Code 输入框里打一样，只改这个会话）
    func setModel(_ key: String, _ id: String, _ name: String) {
        guard let session = session(key), session.canReply else { flash(L("此会话不支持远程操作")); return }
        chat(key).pending.removeAll { $0.isFailed && $0.text.hasPrefix("/model") }   // 之前没发出去的 /model 被这次取代了
        guard let sent = send(key, text: "/model \(id)", images: []) else { return }
        chat(key).modelOverride = (id, session.usage?.model, sent)
        flash(L("已发送 /model：切换为 %@", "\(name)"))
    }

    /// 会话现在的思考等级：刚发过 /effort、记录里还没认出来时（Claude 在忙要等这一轮做完才执行），先按发过去的算
    func currentEffort(_ key: String) -> String? {
        let server = session(key)?.effort
        let chat = chat(key)
        if let override = chat.effortOverride, override.baseline == server, !chat.sendFailed(override.send) { return override.effort }
        return server
    }

    func currentUltracode(_ key: String) -> Bool {
        let server = session(key)?.ultracode == true
        let chat = chat(key)
        if let override = chat.ultracodeOverride, override.baseline == server, !chat.sendFailed(override.send) { return override.on }
        return server
    }

    /// 思考等级（level）/ Ultracode（ultracode）：发一条 /effort。界面上马上按新的显示；和现在（含还在等生效的）一样就不发，免得连点发出一串
    func setEffort(_ key: String, level: String? = nil, ultracode: Bool? = nil, _ name: String) {
        guard let session = session(key), session.canReply else { flash(L("此会话不支持远程操作")); return }
        let chat = chat(key)
        let arg: String
        if let level {
            guard level != (currentEffort(key) ?? "auto") else { return }
            arg = level
        } else if let ultracode {
            guard ultracode != currentUltracode(key) else { return }
            arg = ultracode ? "ultracode on" : "ultracode off"
        } else { return }
        // 之前没发出去的 /effort 被这次取代了：拿掉，别挂在对话底下
        chat.pending.removeAll { $0.isFailed && $0.text.hasPrefix("/effort") }
        guard let id = send(key, text: "/effort \(arg)", images: []) else { return }
        if let level { chat.effortOverride = (level, session.effort, id) }
        if let ultracode { chat.ultracodeOverride = (ultracode, session.ultracode == true, id) }
        flash(session.isBusy ? L("已发送 /effort %@（%@），Claude 本轮结束后生效", "\(arg)", "\(name)") : L("已发送 /effort %@：%@", "\(arg)", "\(name)"))
    }

    /// 切权限模式：替你在 Claude Code 里按 ⇧Tab，按到目标那一档
    func setPermissionMode(_ key: String, _ target: PermissionMode) async {
        guard let session = session(key), session.canReply else { flash(L("此会话不支持远程操作")); return }
        guard let current = permissionMode(key) else {
            flash(L("此会话当前为「跳过所有确认」模式，需在电脑上切换"))
            return
        }
        let from = PermissionMode.cycle.firstIndex(of: current) ?? 0
        let to = PermissionMode.cycle.firstIndex(of: target) ?? 0
        let presses = (to - from + PermissionMode.cycle.count) % PermissionMode.cycle.count
        guard presses > 0 else { return }
        do {
            try await api.post("/api/key", ["key": key], body: ["key": "shift+tab", "times": presses])
            chat(key).modeOverride = (target, session.permissionMode)
            flash(L("已切换至「%@」", "\(target.title)"))
        } catch {
            show(error)
        }
    }
}
