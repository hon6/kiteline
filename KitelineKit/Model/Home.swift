import Foundation
import Observation

/// 首页上方四个汇总卡片，和「今日动态」「用量」「历史会话」「项目」几页的数据。接口和手机网页版一样。

/// 推进一个页面（MainView 放进环境里）：首页卡片、列表行用它，不用 NavigationLink 就不会带系统的「›」箭头。
/// 比较时总算相等：放进环境的地方每次重算都新建一个闭包，SwiftUI 比不出闭包相等，会当成环境变了，
/// 下面整棵树（对话页几百行消息）的环境全部重传一遍（10-26 Mac 4 列分屏卡顿的原因之一）。
/// 所以创建时只捕获不随重算变的东西（@State、绑定、单例），别捕获普通的 let 属性
struct OpenRoute: Equatable {
    let action: (Route) -> Void
    func callAsFunction(_ route: Route) { action(route) }
    static func == (a: OpenRoute, b: OpenRoute) -> Bool { true }
}

/// 对话页之外能推进去的页面
enum Route: Hashable {
    case chat(String)
    /// 概览（宽屏右栏：用量、各状态会话数、需要处理的会话）
    case overview
    case today
    case usage
    case history
    case projects
    case inbox
    /// 我的待办
    case todos
    /// 我的收藏
    case favorites
    /// 会话群：全部群（进行中 + 历史群）、某个群的群聊页
    case groups
    case group(String)
    /// 标签组：组里的会话（iPhone / iPad 一次看一个）
    case tabGroup(String)
    case schedules
    case project(ProjectInfo)
    /// 改动报告 / 测试报告 / 项目文件：key 是哪个会话（取它的工作目录）
    case changes(String)
    case diff(key: String, path: String?, commit: String?, title: String)
    case tests(String)
    case files(key: String, path: String)
    case file(key: String, path: String)
    /// 代码 IDE（文件、编辑、源代码管理、提交历史、分支与会话；宽屏是 VS Code 那样的工作区）
    case code(key: String, start: CodeStart)
    case codeFile(key: String, path: String)
    /// mode：unstaged / staged / untracked / commit；空 = 自动
    case codeDiff(key: String, path: String, mode: String?, commit: String?, oldPath: String?)
    case commit(key: String, hash: String)
    case fileHistory(key: String, path: String)

    /// Mac 面板里按 IDE 的大小打开（宽屏布局要 760 以上）
    var wideIDE: Bool {
        switch self {
        case .files, .file, .changes, .code: true
        default: false
        }
    }
}

// MARK: 今日动态（/api/digest）

struct DigestPayload: Decodable {
    var totals: DigestTotals
    var sessions: [DigestSession]
    var errors: [String]
    var generatedAt: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        totals = c.one("totals") ?? DigestTotals()
        sessions = c.list("sessions")
        errors = c.list("errors")
        generatedAt = c.one("generatedAt")
    }
}

struct DigestTotals: Decodable, Hashable {
    var sessions = 0, projects = 0, prompts = 0, replies = 0, files = 0
    var testRuns = 0, testFailed = 0, images = 0, outputTokens = 0, requests = 0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        sessions = c.int("sessions"); projects = c.int("projects"); prompts = c.int("prompts"); replies = c.int("replies")
        files = c.int("files"); testRuns = c.int("testRuns"); testFailed = c.int("testFailed"); images = c.int("images")
        outputTokens = c.int("outputTokens"); requests = c.int("requests")
    }
}

struct DigestSession: Decodable, Identifiable, Hashable {
    struct File: Decodable, Hashable { var path: String; var edits: Int? }
    struct TestRun: Decodable, Hashable { var description: String?; var command: String?; var ok: Bool?; var passed: Int?; var failed: Int? }
    struct Shot: Decodable, Hashable { var ref: String; var caption: String? }

    var key: String?
    var title: String
    var cwd: String?
    var sourceId: String
    var sourceName: String
    var sessionId: String
    var activity: String?
    var prompts: Int
    var fileCount: Int
    var files: [File]
    var images: Int
    var outputTokens: Int
    var testRuns: Int
    var testFailed: Int
    var lastTest: TestRun?
    var conclusion: String?
    var shots: [Shot]
    var firstAt: Double?
    var lastAt: Double?

    /// 已经关掉的会话也能点开看（用「来源#会话 ID」当 key）
    var id: String { key ?? "\(sourceId)#\(sessionId)" }
    var live: Bool { key != nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        key = c.text("key")
        cwd = c.text("cwd")
        title = c.text("title") ?? cwd.map { ($0 as NSString).lastPathComponent } ?? L("会话")
        sourceId = c.text("sourceId") ?? ""
        sourceName = c.text("sourceName") ?? ""
        sessionId = c.text("sessionId") ?? ""
        activity = c.text("activity")
        prompts = c.int("prompts")
        fileCount = c.int("fileCount")
        files = c.list("files")
        images = c.int("images")
        outputTokens = c.int("outputTokens")
        let tests: JSONValue? = c.one("tests")
        testRuns = Int(tests?["runs"]?.double ?? 0)
        testFailed = Int(tests?["failed"]?.double ?? 0)
        lastTest = tests?["last"]?.array.first.flatMap { run in
            TestRun(description: run["description"]?.string, command: run["command"]?.string, ok: run["ok"]?.bool,
                    passed: run["passed"]?.double.map(Int.init), failed: run["failed"]?.double.map(Int.init))
        }
        let conclusions: [JSONValue] = c.list("conclusions")
        conclusion = conclusions.last?["text"]?.string
        shots = c.list("shots")
        firstAt = c.one("firstAt")
        lastAt = c.one("lastAt")
    }
}

// MARK: 用量（/api/usage、/api/budget）

struct UsagePayload: Decodable {
    var totals: UsageItem
    var days: [UsageItem]
    var models: [UsageItem]
    var projects: [UsageItem]
    var sources: [UsageItem]
    /// 按 agent（Claude Code、Codex……）；旧电脑端没有
    var agents: [UsageItem]
    var unpriced: [String]
    var errors: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        totals = c.one("totals") ?? UsageItem()
        days = c.list("days"); models = c.list("models"); projects = c.list("projects"); sources = c.list("sources"); agents = c.list("agents")
        unpriced = c.list("unpriced"); errors = c.list("errors")
    }
}

/// 一行用量（总计、某天、某个模型 / 项目 / 机器都是这几个数）
struct UsageItem: Decodable, Hashable {
    var name = ""
    var sub = ""
    var day = ""
    /// 按项目统计时：「来源\n目录」，和项目列表对上
    var key = ""
    var cost = 0.0, estimated = 0.0, requests = 0.0, input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0
    /// 没有花费数据（agent 不记花费的模型、这家 agent）：显示「仅 token」，不显示 $0
    var unpriced = false
    /// token 总数：输入、输出、读写缓存都算
    var tokens: Double { input + output + cacheRead + cacheWrite }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        cost = c.num("cost"); estimated = c.num("estimated"); requests = c.num("requests"); input = c.num("input")
        output = c.num("output"); cacheRead = c.num("cacheRead"); cacheWrite = c.num("cacheWrite")
        day = c.text("day") ?? ""
        unpriced = c.one("unpriced") ?? false
        let cwd = c.text("cwd")
        name = c.text("model") ?? c.text("name") ?? cwd.map { ($0 as NSString).lastPathComponent } ?? L("（未知）")
        sub = c.text("sourceName") ?? ""
        key = "\(c.text("sourceId") ?? "")\n\(cwd ?? "")"
    }
}

struct Budget: Decodable {
    var daily = 0.0
    var cap = 0.0
    var capped = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        daily = c.num("daily"); cap = c.num("cap"); capped = c.text("capped") ?? ""
    }
}

// MARK: 历史会话（/api/sessions、/api/search）

struct PastSession: Decodable, Identifiable, Hashable {
    struct Hit: Decodable, Hashable { var snippet: String; var t: String?; var id: String? }

    var key: String
    var title: String
    var cwd: String?
    var sourceName: String
    var firstPrompt: String?
    var lastActive: Double?
    var live: Bool
    var activity: String?
    var hits: [Hit]
    /// 搜到它是因为项目名（project）或标题（title）里有搜索词（可能没有正文片段）
    var match: [String]

    var id: String { key }
    /// 项目名 = 工作目录的最后一级
    var project: String { cwd.map { ($0 as NSString).lastPathComponent } ?? "" }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        let sourceId = c.text("sourceId") ?? ""
        key = c.text("key") ?? "\(sourceId)#\(c.text("sessionId") ?? "")"
        cwd = c.text("cwd")
        firstPrompt = c.text("firstPrompt")
        title = c.text("title") ?? firstPrompt ?? cwd.map { ($0 as NSString).lastPathComponent } ?? L("会话")
        sourceName = c.text("sourceName") ?? ""
        lastActive = c.one("lastActive")
        live = c.truthy("live")
        activity = c.text("activity")
        hits = c.list("hits")
        match = c.list("match")
    }
}

// MARK: 项目（/api/projects?detail=1）

struct ProjectInfo: Decodable, Identifiable, Hashable {
    var cwd: String
    var name: String
    var sourceId: String
    var sourceName: String
    var title: String?
    var sessionKey: String?
    var sessions: Int
    var today: Int
    var live: Int
    var waiting: Int
    var busy: Int
    var lastActive: Double?
    var exists: Bool
    var branch: String?
    var changed: Int
    var untracked: Int
    var ahead: Int
    var behind: Int
    var lastCommit: String?
    var lastCommitAt: Double?
    var lastHash: String?
    var upstream: String?
    var hasGit: Bool
    /// git 状态读取超时（Mac 上没允许 Kiteline 访问这个文件夹）
    var gitTimeout: Bool
    /// Mac 上 VS Code 已经打开着这个项目
    var open: Bool
    /// local / ssh
    var kind: String?

    var id: String { "\(sourceId)\n\(cwd)" }
    var dirty: Bool { changed + untracked + ahead > 0 }

    /// 新任务「打开其他文件夹」选的：还没在这台电脑上用过 Claude Code
    init(picked cwd: String, source: SourceInfo) {
        self.cwd = cwd
        name = cwd.components(separatedBy: cwd.contains("\\") && !cwd.hasPrefix("/") ? "\\" : "/").last { !$0.isEmpty } ?? cwd
        sourceId = source.id
        sourceName = source.name
        sessions = 0; today = 0; live = 0; waiting = 0; busy = 0
        exists = true
        changed = 0; untracked = 0; ahead = 0; behind = 0
        hasGit = false
        gitTimeout = false
        open = false
        kind = source.kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        cwd = c.text("cwd") ?? ""
        name = c.text("name") ?? (cwd as NSString).lastPathComponent
        let source = c.text("sourceId") ?? ""
        sourceId = source
        sourceName = c.text("sourceName") ?? ""
        title = c.text("title")
        sessionKey = c.text("sessionId").map { "\(source)#\($0)" }
        sessions = c.int("sessions"); today = c.int("today"); live = c.int("live"); waiting = c.int("waiting"); busy = c.int("busy")
        lastActive = c.one("lastActive")
        exists = c.one("exists") ?? true
        let git: JSONValue? = c.one("git")
        branch = git?["branch"]?.string
        changed = Int(git?["changed"]?.double ?? 0)
        untracked = Int(git?["untracked"]?.double ?? 0)
        ahead = Int(git?["ahead"]?.double ?? 0)
        behind = Int(git?["behind"]?.double ?? 0)
        lastCommit = git?["last"]?["subject"]?.string
        lastCommitAt = git?["last"]?["ts"]?.double
        lastHash = git?["last"]?["hash"]?.string
        upstream = git?["upstream"]?.string
        hasGit = git != nil
        gitTimeout = git?["timeout"]?.bool ?? false
        open = c.truthy("open")
        kind = c.text("kind")
    }
}

// MARK: 首页卡片的数

@MainActor
@Observable
final class HomeStats {
    private(set) var today: DigestTotals?
    private(set) var usage: UsageItem?
    /// 各台电脑的订阅额度（5 小时 / 本周），首页「今日用量」大卡片画成环形
    private(set) var limits: [LimitDevice] = []
    private(set) var projects: [ProjectInfo] = []
    /// 近 7 天每天的用量（概览看板的小柱图；只在显示概览时取）
    private(set) var week: [UsageItem] = []
    private(set) var budget: Budget?
    /// 卡片上的刷新按钮转圈
    private(set) var limitsBusy = false
    /// 正在后台取新的（页面上已经显示着上次存的，右上角一个小转圈「更新中」）
    private(set) var refreshing = false
    private var refreshedAt: Date?
    private var limitsRefreshedAt: Date?
    private var weekRefreshedAt: Date?

    /// 启动时先填上次存在手机上的（今天的动态、用量、额度、项目、近 7 天），没连上电脑也有数；之后 refresh 静默换成新的
    func restore(_ api: MacAPI) {
        if today == nil { today = api.cached(DigestPayload.self, "/api/digest", ["since": Self.dayStart(0)])?.totals }
        if usage == nil { usage = api.cached(UsagePayload.self, "/api/usage", ["days": "1"])?.totals }
        if limits.isEmpty { limits = api.cached(LimitsPayload.self, "/api/limits")?.devices ?? [] }
        if projects.isEmpty { projects = api.cached(ProjectsReply.self, "/api/projects", ["detail": "1"])?.projects ?? [] }
        if week.isEmpty { week = api.cached(UsagePayload.self, "/api/usage", ["days": "7"])?.days ?? [] }
        if budget == nil { budget = api.cached(Budget.self, "/api/budget") }
    }

    /// 一分钟内不重复拉（回到首页、下拉刷新时 force）
    func refresh(_ api: MacAPI, force: Bool = false) async {
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < 60 { return }
        refreshedAt = Date()
        limitsRefreshedAt = Date()
        refreshing = true
        defer { refreshing = false }
        async let digest = try? api.getCaching(DigestPayload.self, "/api/digest", ["since": Self.dayStart(0)])
        async let usage = try? api.getCaching(UsagePayload.self, "/api/usage", ["days": "1"])
        async let projects = try? api.getCaching(ProjectsReply.self, "/api/projects", ["detail": "1"])
        async let limits = try? api.getCaching(LimitsPayload.self, "/api/limits")
        if let digest = await digest { today = digest.totals }
        if let usage = await usage { self.usage = usage.totals }
        if let limits = await limits { self.limits = limits.devices }
        if let projects = await projects { self.projects = projects.projects }
    }

    /// 只拉额度和今天的 token 数：首页开着时每 5 分钟一次（11-03：要 5～10 分钟一更），older 内拉过的跳过；
    /// 卡片上的刷新按钮 fresh，让电脑端跳过 30 秒缓存、当场问各台电脑
    func refreshLimits(_ api: MacAPI, older: TimeInterval = 0, fresh: Bool = false) async {
        if older > 0, let limitsRefreshedAt, Date().timeIntervalSince(limitsRefreshedAt) < older { return }
        if fresh {
            if limitsBusy { return }
            limitsBusy = true
        }
        defer { if fresh { limitsBusy = false } }
        limitsRefreshedAt = Date()
        let skipCache = fresh ? ["fresh": "1"] : [:]
        async let usage = try? api.getCaching(UsagePayload.self, "/api/usage", skipCache.merging(["days": "1"]) { $1 })
        async let limits = try? api.getCaching(LimitsPayload.self, "/api/limits", skipCache)
        if let usage = await usage { self.usage = usage.totals }
        if let limits = await limits { self.limits = limits.devices }
    }

    /// 概览看板：近 7 天每天的花费、每日预算。和上面分开取：只有 iPhone Duo 外屏、宽屏的概览页用得到
    func refreshWeek(_ api: MacAPI, force: Bool = false) async {
        if !force, let weekRefreshedAt, Date().timeIntervalSince(weekRefreshedAt) < 300 { return }
        weekRefreshedAt = Date()
        async let usage = try? api.getCaching(UsagePayload.self, "/api/usage", ["days": "7"])
        async let budget = try? api.getCaching(Budget.self, "/api/budget")
        if let usage = await usage { week = usage.days }
        if let budget = await budget { self.budget = budget }
    }

    /// 某天 0 点（毫秒）：0 = 今天，-1 = 昨天
    static func dayStart(_ offset: Int) -> String {
        let start = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return String(Int64(start.timeIntervalSince1970 * 1000))
    }
}

struct ProjectsReply: Decodable {
    var projects: [ProjectInfo]
    var errors: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        projects = c.list("projects")
        errors = c.list("errors")
    }
}

struct PastSessionsReply: Decodable {
    var sessions: [PastSession]
    var errors: [String]
    var truncated: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        let sessions: [PastSession] = c.list("sessions")
        self.sessions = sessions.isEmpty ? c.list("results") : sessions
        errors = c.list("errors")
        truncated = c.truthy("truncated")
    }
}

// MARK: 解码小工具：Mac 给的 JSON 字段时有时无、数字可能是小数，缺了就用默认值，不让整页解析失败

struct FieldKey: CodingKey {
    let stringValue: String
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension Decoder {
    func fields() throws -> KeyedDecodingContainer<FieldKey> { try container(keyedBy: FieldKey.self) }
}

extension KeyedDecodingContainer where Key == FieldKey {
    func one<T: Decodable>(_ key: String) -> T? { (try? decodeIfPresent(T.self, forKey: FieldKey(key))) ?? nil }
    func list<T: Decodable>(_ key: String) -> [T] { one(key) ?? [] }
    func num(_ key: String) -> Double { one(key) ?? 0 }
    func int(_ key: String) -> Int { Int(num(key)) }
    func text(_ key: String) -> String? { one(key) }
    /// true / 1 / 3 都算「是」
    func truthy(_ key: String) -> Bool { (one(key) as Bool?) ?? (num(key) > 0) }
}

extension JSONValue {
    var double: Double? { if case .number(let v) = self { return v } else { return nil } }
}

enum Money {
    /// 「$9.39」「$12.4」「$135」「$1.2k」（和网页版一样）
    static func cost(_ v: Double) -> String {
        if v <= 0 { return "$0" }
        if v >= 1000 { return String(format: "$%.1fk", v / 1000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 10 { return String(format: "$%.1f", v) }
        return String(format: "$%.2f", v)
    }

    /// 「850」「14k」「3.2M」
    static func compact(_ n: Double) -> String {
        if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1e3 { return "\(Int((n / 1e3).rounded()))k" }
        return String(Int(n))
    }
}
