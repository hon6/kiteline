import Foundation

/// 执行过程面板（/api/trace）：一个会话 = 主 agent + 它派出的子 agent；每个 agent 分轮次，每轮是一串步骤
/// （模型调用、工具调用、出错、插话、事件）。电脑端 watcher 的 session_trace 拼好，面板开着时每几秒拉一次。

struct TraceReply: Decodable {
    var start: Double?
    var end: Double?
    var now: Double?
    var stats: TraceStats
    /// 每分钟一格：[分钟起点毫秒, 模型调用, 工具调用, 出错]，只有有动静的分钟
    var activity: [[Double]]
    var firstError: TraceErrorRef?
    var agents: [TraceAgent]
    /// 「agent:轮次」→ 这一轮的步骤（只带请求里 expand 点名的）
    var steps: [String: TraceSteps]
    /// 这个 agent 的对话记录不落文件，看不了执行过程
    var unsupported: Bool
    /// 版本号：下次带上，电脑那边没变就只回 same
    var rev: String?
    var same: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        start = c.one("start"); end = c.one("end"); now = c.one("now")
        stats = c.one("stats") ?? TraceStats()
        activity = c.list("activity")
        firstError = c.one("firstError")
        agents = c.list("agents")
        steps = c.one("steps") ?? [:]
        unsupported = c.truthy("unsupported")
        rev = c.text("rev"); same = c.truthy("same")
    }

    var running: Bool { agents.contains { $0.running } }
}

struct TraceStats: Decodable {
    var agents = 1
    var subagents = 0
    var turns = 0
    var medianTurn: Double?
    var llm = 0
    var tools = 0
    var errors = 0
    var busyMs: Double = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        agents = max(1, c.int("agents")); subagents = c.int("subagents"); turns = c.int("turns")
        medianTurn = c.one("medianTurn"); llm = c.int("llm"); tools = c.int("tools"); errors = c.int("errors")
        busyMs = c.one("busyMs") ?? 0
    }
}

struct TraceErrorRef: Decodable, Hashable {
    var agent: String
    var turn: Int
    var step: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        agent = c.text("agent") ?? "main"; turn = c.int("turn"); step = c.int("step")
    }
}

struct TraceAgent: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var running: Bool
    var start: Double?
    var end: Double?
    var llm: Int
    var tools: Int
    var errors: Int
    var turns: [TraceTurn]
    var turnsOmitted: Int
    /// 谁派的（主 agent 是 nil，否则 main 或另一个子 agent 的 id）
    var parent: String?
    /// 由派它的那个 agent 的第几轮派出
    var fromTurn: Int?
    var agentType: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? "main"; title = c.text("title") ?? ""; running = c.truthy("running")
        start = c.one("start"); end = c.one("end")
        llm = c.int("llm"); tools = c.int("tools"); errors = c.int("errors")
        turns = c.list("turns"); turnsOmitted = c.int("turnsOmitted")
        parent = c.text("parent"); fromTurn = c.one("fromTurn"); agentType = c.text("agentType")
    }

    var isMain: Bool { id == "main" }
}

struct TraceTurn: Decodable, Identifiable, Hashable {
    var i: Int
    var title: String
    /// user 用户的话 / peer 别的会话发来的 / image 只发了图 / resume 记录开头（之前的被压缩、续接）
    var kind: String
    var llm: Int
    var tools: Int
    var errors: Int
    var firstError: Int?
    var start: Double?
    var end: Double?
    var steps: Int
    var running: Bool
    /// 时间条分段：[距本轮开始毫秒, 时长毫秒, 种类 0 模型 1 工具 2 出错]
    var segs: [[Double]]
    /// 出错的时刻
    var errAt: [Double]
    /// 用时拆分（毫秒）：模型、工具、失败的工具、等待
    var llmMs: Double
    var toolMs: Double
    var failMs: Double
    var waitMs: Double

    var id: Int { i }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        i = c.int("i"); title = c.text("title") ?? ""; kind = c.text("kind") ?? "user"
        llm = c.int("llm"); tools = c.int("tools"); errors = c.int("errors"); firstError = c.one("firstError")
        start = c.one("start"); end = c.one("end"); steps = c.int("steps"); running = c.truthy("running")
        segs = c.list("segs"); errAt = c.list("errAt")
        llmMs = c.one("llmMs") ?? 0; toolMs = c.one("toolMs") ?? 0; failMs = c.one("failMs") ?? 0; waitMs = c.one("waitMs") ?? 0
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        switch kind {
        case "image": return L("（图片）")
        case "resume": return L("（记录开头）")
        default: return L("（空消息）")
        }
    }
}

struct TraceSteps: Decodable, Hashable {
    var items: [TraceStep]
    var omitted: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        items = c.list("items"); omitted = c.int("omitted")
    }
}

struct TraceStep: Decodable, Identifiable, Hashable {
    /// llm 模型调用 / tool 工具调用 / error 出错 / user 中途插话 / event 其他事件
    var k: String
    var n: Int
    var start: Double?
    var end: Double?
    var name: String?
    var brief: String?
    var detail: String?
    var result: String?
    var text: String?
    var think: String?
    var thought: Bool
    var model: String?
    var input: Int
    var output: Int
    var error: Bool
    /// 这次工具调用派出的子 agent
    var agent: String?

    var id: Int { n }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        k = c.text("k") ?? "event"; n = c.int("n")
        start = c.one("start"); end = c.one("end")
        name = c.text("name"); brief = c.text("brief"); detail = c.text("detail"); result = c.text("result")
        text = c.text("text"); think = c.text("think"); thought = c.truthy("thought"); model = c.text("model")
        input = c.int("in"); output = c.int("out"); error = c.truthy("error"); agent = c.text("agent")
    }

    /// 工具还没出结果（在跑、或者等确认）
    var pending: Bool { k == "tool" && end == nil }
    var failed: Bool { error || k == "error" }
}

enum TraceFormat {
    /// 毫秒 → 「<1s」「12s」「1m 5s」「2h 3m」
    static func ms(_ value: Double?) -> String {
        guard let value else { return "" }
        if value < 1000 { return "<1s" }
        return Format.duration(Int(value / 1000))
    }

    /// 开始到结束；没结束的算到 now
    static func span(_ start: Double?, _ end: Double?, now: Double) -> String {
        guard let start else { return "" }
        return ms(max(0, (end ?? now) - start))
    }

    /// 「claude-opus-5-5」→「Opus 5.5」；认不出的原样
    static func model(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "" }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first, family.allSatisfy(\.isLetter) else { return id }
        let version = parts.dropFirst().prefix(2).filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}
