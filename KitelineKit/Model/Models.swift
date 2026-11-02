import Foundation

// Mac 上 Kiteline 的数据（/api/state、/api/events、/api/history）。
// 字段一律可选、缺了就用默认值：Mac 和 App 版本不一定同步，多一个少一个字段都不能让整份数据解析失败。

struct Usage: Decodable, Hashable {
    var context: Int?
    var window: Int?
    var model: String?
    var percent: Int?
}

struct SessionInfo: Decodable, Identifiable, Hashable {
    var key: String
    var title: String
    var sourceId: String
    var sourceName: String
    var sourceKind: String?
    /// waiting（等你确认）/ busy（正在工作）/ idle / unknown
    var activity: String
    var activityText: String?
    var blocking: String?
    var reason: String?
    var preview: String?
    var pendingTool: String?
    var canReply: Bool
    var cwd: String?
    var updatedAt: Double?
    var startedAt: Double?
    var usage: Usage?
    var error: String?
    var effort: String?
    var ultracode: Bool?
    /// 权限模式：default / acceptEdits / plan / auto / bypassPermissions（你最近一句话发出时的模式）
    var permissionMode: String?
    var cwdShort: String?
    /// 派过几个子 agent（做完的也算）
    var subagents: Int
    /// 会话里开着几个终端（终端按钮的角标）
    var terminals: Int
    /// 只能看、不能远程操作（Proma 这类没有对外接口的）
    var readOnly: Bool?
    /// 只读时给用户看的一句话（插件给）；没有就按老样子说
    var readOnlyReason: String?
    /// 哪个编程 agent 的会话（claude-code / codex / …，见 Shared/AgentMark.swift）；老版本电脑端不给，按 Claude Code 算
    var agent: String
    /// 看、回复、确认、中断以外还能出的按钮：mode 权限模式 / model 换模型 / compact 压缩 / subagents 子 agent / tests 测试记录
    /// （docs/agent-plugins.md 4.4）。按这个出按钮，不认 agent 名字；老版本电脑端不给：Claude Code 的会话全有，别家全没有
    var caps: Set<String>
    /// 待确认卡片上的按钮（插件给，比如只有「允许这一次」的、四个选项的）；没有就按老样子画
    var pendingOptions: [PendingOption]?
    /// 在那台电脑上的会话 id（代码 IDE 里认「哪个会话在哪个分支」用）
    var sessionId: String?
    /// 工作目录所在的 git 分支；在附加的工作树里时 worktree 是那个工作树的目录
    var branch: String?
    var worktree: String?
    /// 这一轮任务做到第几步（「2/4 开发中」，见 StageViews.swift）：电脑只在忙、等确认时给，老版本电脑端没有
    var stage: StageInfo?
    /// 目标（/goal，见 GoalViews.swift）：agent 围着它跨多轮一直做；没设目标、老版本电脑端没有
    var goal: GoalInfo?

    var id: String { key }
    var isWaiting: Bool { activity == "waiting" }
    var isBusy: Bool { activity == "busy" }
    /// 只用来挑说法（「等同于在 VS Code 中按 Esc」）；功能有没有一律看 can(_:)
    var isClaude: Bool { agent == Agents.defaultID }
    func can(_ cap: String) -> Bool { caps.contains(cap) }
    /// 不能回复时输入框里的说明：插件给的优先
    var readOnlyNote: String {
        readOnlyReason ?? (isClaude ? L("终端会话需在 tmux 中运行才能回复") : L("仅可查看，请在 %@ 中回复", "\(speaker)"))
    }
    static let claudeCaps: Set<String> = ["mode", "model", "compact", "subagents", "tests"]
    /// 对话里怎么称呼这个会话的 agent（「Claude 想使用 Bash」「中断 Codex」）
    var speaker: String { Agents.info(agent).speaker }

    enum CodingKeys: String, CodingKey {
        case key, title, name, sourceId, sourceName, sourceKind, activity, activityText, blocking, reason, preview
        case pendingTool, canReply, cwd, updatedAt, startedAt, usage, error, effort, ultracode, permissionMode, cwdShort, subagents, terminals
        case agent, readOnly, readOnlyReason, caps, pendingOptions, sessionId, branch, worktree, stage, goal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil ?? name ?? L("会话")
        sourceId = (try? c.decodeIfPresent(String.self, forKey: .sourceId)) ?? nil ?? ""
        sourceName = (try? c.decodeIfPresent(String.self, forKey: .sourceName)) ?? nil ?? ""
        sourceKind = try? c.decodeIfPresent(String.self, forKey: .sourceKind)
        activity = (try? c.decodeIfPresent(String.self, forKey: .activity)) ?? nil ?? "unknown"
        activityText = try? c.decodeIfPresent(String.self, forKey: .activityText)
        blocking = try? c.decodeIfPresent(String.self, forKey: .blocking)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        pendingTool = try? c.decodeIfPresent(String.self, forKey: .pendingTool)
        canReply = (try? c.decodeIfPresent(Bool.self, forKey: .canReply)) ?? nil ?? false
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
        startedAt = try? c.decodeIfPresent(Double.self, forKey: .startedAt)
        usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        effort = try? c.decodeIfPresent(String.self, forKey: .effort)
        ultracode = try? c.decodeIfPresent(Bool.self, forKey: .ultracode)
        permissionMode = try? c.decodeIfPresent(String.self, forKey: .permissionMode)
        cwdShort = try? c.decodeIfPresent(String.self, forKey: .cwdShort)
        subagents = ((try? c.decodeIfPresent(Int.self, forKey: .subagents)) ?? nil) ?? 0
        terminals = ((try? c.decodeIfPresent(Int.self, forKey: .terminals)) ?? nil) ?? 0
        agent = ((try? c.decodeIfPresent(String.self, forKey: .agent)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } ?? Agents.defaultID
        readOnly = try? c.decodeIfPresent(Bool.self, forKey: .readOnly)
        readOnlyReason = ((try? c.decodeIfPresent(String.self, forKey: .readOnlyReason)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        caps = ((try? c.decodeIfPresent([String].self, forKey: .caps)) ?? nil).map(Set.init) ?? (agent == Agents.defaultID ? Self.claudeCaps : [])
        pendingOptions = ((try? c.decodeIfPresent([PendingOption].self, forKey: .pendingOptions)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        branch = ((try? c.decodeIfPresent(String.self, forKey: .branch)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        worktree = ((try? c.decodeIfPresent(String.self, forKey: .worktree)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        stage = ((try? c.decodeIfPresent(StageInfo.self, forKey: .stage)) ?? nil).flatMap { $0.valid ? $0 : nil }
        goal = ((try? c.decodeIfPresent(GoalInfo.self, forKey: .goal)) ?? nil).flatMap { $0.valid ? $0 : nil }
    }
}

/// 待确认卡片上的一个按钮（插件给）：key 是点了发回电脑的按键，style 为 primary 主按钮 / destructive 拒绝 / normal 次要
struct PendingOption: Decodable, Hashable {
    var key: String
    var label: String
    var style: String?
}

struct SourceInfo: Decodable, Hashable {
    var id: String
    var name: String
    /// local（电脑自己）/ ssh（经 SSH 连的别的机器）
    var kind: String?
    var online: Bool
    var status: String?
}

struct Me: Decodable, Hashable {
    var name: String?
    /// /api/avatar?v=…；空 = 没有头像图，显示名字首字
    var avatar: String?
}

struct StatePayload: Decodable {
    var host: String?
    var version: String?
    var sessions: [SessionInfo]?
    var sources: [SourceInfo]?
    var quickReplies: [String]?
    var me: Me?
    var muted: [String]?
    var pinned: [String]?
    /// 标记的会话（主题色星星，所有列表最上面、不受分组限制；新标记的在前）
    var marked: [String]?
    var submitOnSend: Bool?
    var quietActive: Bool?
    /// 电脑端（Windows / Linux 版 Kiteline）才带："windows" / "linux"；Mac 版不带
    var platform: String?
    /// 各台机器的 CPU、内存、网速（来源 id → 数据）：只有 GET /api/state 带，推来的 state 不带（之后的变化走 sys 事件）
    var sys: [String: MachineStats]?
    /// 电脑端插件给的 agent 名称、称呼、标志：内置表里没有的 agent 靠它显示（见 Shared/AgentMark.swift）
    var agents: [AgentProfile]?
    /// 要人处理的状况：VS Code 弹着对话框、电脑到某台机器的连接断了（问题消失就没了）
    var alerts: [AlertInfo]?
    /// 用户给会话（或某家 agent 全部会话）设的头像、昵称（见 Views/AgentDetails.swift）
    var faces: FacesPayload?
    /// 这版电脑端能做的：files = 收手机发来的文件（PDF、Excel……）、按路径取回文件；旧版不带
    var features: [String]?
}

/// 电脑报来的「要人处理」：kind = dialog（VS Code 的对话框，title 是哪个窗口）/ link（电脑到某台机器的连接，title 是机器名）
struct AlertInfo: Decodable, Hashable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var text: String
    /// reconnect = 能在手机上「尝试重连」
    var actions: [String]?

    var canReconnect: Bool { actions?.contains("reconnect") == true }
}

/// 连着的是哪种电脑。界面文字一律写「电脑」，不写死 Mac / Windows；
/// 只有 macOS 独有的操作路径（「系统设置 → 隐私与安全性 → …」「Kiteline 设置 → …」）看它决定给不给
enum HostPlatform {
    @MainActor static var current = ""
    /// 没收到 platform（Mac 版、还没连上）按 Mac 算
    @MainActor static var isMac: Bool { current.isEmpty || current == "macos" }
}

struct ChatImage: Codable, Hashable {
    var ref: String
    var mime: String?
    var name: String?
}

/// 对话里的一条：user（我说的）/ text（Claude 回复）/ thinking / tool（调用工具）/ result（工具结果）/
/// agent_image（Claude 发来的图）/ event（系统提示，比如用量到上限）
struct ChatItem: Codable, Identifiable, Hashable {
    var t: String
    var id: String
    var ts: Double?
    var text: String?
    var name: String?
    var toolId: String?
    var input: JSONValue?
    var brief: String?
    var isError: Bool?
    var images: [ChatImage]?
    var level: String?
    var resetAt: Double?
    var detail: String?
    var truncated: Bool?
    var fullLength: Int?
    var queued: Bool?
    /// Claude 的回复里认出来的「需要你来做」的事（Mac 认的，见 Sources/Asks.swift）：消息下面问一句「加入待办？」
    var asks: [String]?
    /// 会话之间的消息：发出的那步（tool SendMessage）、收到的那条（event）带着，见 Model/Peers.swift
    var peer: PeerInfo?
    /// SendMessage 的结果里的 msg_id（和收信那边配对）
    var msgId: String?
    /// agent 经待办技能记的待办（agent_todo）：要你自己动手的事（没有「交给」）
    var forUser: Bool?
    /// agent 发来的关键信息（agent_key）：标题、一项项的值、补充说明；text 是拼好的纯文字（收藏、复制用）
    var title: String?
    var fields: [KeyField]?
    var note: String?
    /// agent 发到会话群的（group_say）：哪个群（群 id；老 watcher 可能是空的）、只发给了谁（成员 key）
    var group: String?
    var to: [String]?
    /// 目标的那几行提示（event）：set 设定 / check 检查未达成、继续 / met 达成 / failed 做不到 / paused 停下 / cleared 清除 / error 出错中止
    var goal: String?
    /// 目标达成、做不到那一行带的：用了几轮、多久、多少 token
    var goalStats: GoalStats?

    /// 排序：时间 → transcript 里的偏移 → 同一行里的第几块（id 形如「偏移.序号」，Claude 发图的是 o 开头）
    var offset: Int { id.hasPrefix("o") ? 0 : Int(id.split(separator: ".").first ?? "") ?? 0 }
    var sub: Int { id.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? 0 }

    static func ordered(_ a: ChatItem, _ b: ChatItem) -> Bool {
        let ta = a.ts ?? 0, tb = b.ts ?? 0
        if ta != tb { return ta < tb }
        if a.offset != b.offset { return a.offset < b.offset }
        return a.sub < b.sub
    }
}

struct GoalStats: Codable, Hashable {
    var turns: Int?
    var durationMs: Double?
    var tokens: Int?
}

/// 关键信息里的一项：名称 + 值；secret（密码、令牌）默认遮住，点一下才显示
struct KeyField: Codable, Hashable {
    var name: String?
    var value: String?
    var secret: Bool?
}

struct HistoryPage: Decodable {
    var items: [ChatItem]
    var hasMore: Bool?
}

struct EntriesEvent: Decodable {
    var key: String
    var items: [ChatItem]
}

struct KeyEvent: Decodable {
    var key: String
}

/// Mac 推来的提醒（需要你确认、有结论了……），App 在前台时弹成横幅
struct NotifyEvent: Decodable, Equatable {
    var title: String?
    var body: String?
    var key: String?
    var kind: String?
    /// 不是某个会话的提醒（日报 today、花费 usage、定时任务 schedules）：点开去哪一页
    var route: String?
    /// 记进了通知收件箱（铃铛上加一）
    var inbox: Bool?
    /// 点开滚到会话里的哪条（待办提示：出自的那条消息）
    var itemId: String?
}

extension NotifyEvent {
    /// Mac 送来的 inbox 是收件箱里那条的 id（字符串，没记就是空串），不是 true / false：按「有没有」算。
    /// 以前直接按 Bool 解，整条提醒解不出来，App 开着时横幅不弹、铃铛不加一。写在扩展里，留着逐个字段的构造方法
    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        title = c.text("title")
        body = c.text("body")
        key = c.text("key").flatMap { $0.isEmpty ? nil : $0 }
        kind = c.text("kind")
        route = c.text("route").flatMap { $0.isEmpty ? nil : $0 }
        inbox = (c.one("inbox") as String?).map { !$0.isEmpty } ?? (c.one("inbox") as Bool?)
        itemId = c.text("itemId")
    }
}
