import Foundation
import KitelineKit

/// 会话当前活动状态的归一化结果（由远端 watcher 判定）
enum Activity: String {
    case busy
    case waiting
    case idle
    case unknown

    init(raw: String?) {
        self = Activity(rawValue: raw ?? "") ?? .unknown
    }

    var label: String {
        switch self {
        case .busy: return "运行中"
        case .waiting: return "待确认"
        case .idle: return "已停止"
        case .unknown: return "未知"
        }
    }

    var glyph: String {
        switch self {
        case .busy: return "◐"
        case .waiting: return "●"
        case .idle: return "○"
        case .unknown: return "·"
        }
    }
}

/// 远端一个会话的即时快照，字段与 ccpulse-watch.py 的 snapshots 事件一一对应
struct SessionSnapshot: Codable, Equatable {
    var pid: Int?
    var sessionId: String
    var name: String
    /// Claude Code 自动生成的会话标题（VS Code 标签页上显示的那个；在 VS Code 里改过名的是改的名）。
    /// Claude 没起成标题时 watcher 给第一句话（扩展的标签也用它），见 tabNames
    var title: String?
    /// 没有标题时 VS Code 标签页上可能显示的名字：当场发的标签是第一句，重开 VS Code 恢复的标签是那时的最近一句
    var tabNames: [String]?
    var cwd: String
    var cwdShort: String
    /// 工作目录所在的 git 分支（游离时是「(提交号)」）；在附加工作树里时 worktree 是工作树目录
    var branch: String?
    var worktree: String?
    var status: String?
    var waitingFor: String?
    var needs: String?
    var detail: String?
    var activity: String
    var reason: String?
    /// 正在执行的工具摘要，如「Bash: npm test」
    var activityText: String?
    var message: String?
    var messageUuid: String?
    /// 最近一轮是谁发起的：user（你）/ peer（别的会话来信：SendMessage、群里别的会话发言）；老 watcher 不带
    var turnFrom: String?
    var pendingTool: String?
    var pendingId: String?
    var startedAt: Double?
    var statusUpdatedAt: Double?
    var updatedAt: Double?
    var version: String?
    /// claude-vscode（VS Code 扩展）/ cli（终端）等，决定怎么把回复送进去
    var entrypoint: String?
    /// 哪个编程 agent 的会话（claude-code / codex / …，见 KitelineKit/Shared/AgentMark.swift）；现在的 watcher 只认 Claude Code，不带
    var agent: String?
    var sessionKind: String?
    /// 终端会话所在的 tmux pane（有的话可以远程精确投递）
    var tmuxPane: String?
    /// 用量（watcher 统计，与 VS Code 面板同样的算法）
    var usage: UsageInfo?
    var transcriptPath: String?
    var transcriptUpdatedAt: Double?
    /// Claude 因为接口错误停下了（用量到上限、上下文太长、接口过载…）；只在空闲且最后一句是错误时有
    var error: APIErrorInfo?
    /// 这个会话最近一次 /effort 设的思考等级、ultracode（watcher 从对话记录里认的；没设过为空）
    var effort: EffortInfo?
    /// 这个会话派过几个子 agent（做完的也算）
    var subagents: Int?
    /// 这个会话里开着几个终端（手机上终端按钮的角标；没开的不带）
    var terminals: Int?
    /// 只能看、不能远程操作（Proma：没有对外接口，回复和确认得在它自己的窗口里做）
    var readOnly: Bool?
    /// 只读时给用户看的一句话（插件给，比如「不在 tmux 中运行，只能查看」）；En 是插件自带的英文（我们的词表里没有也能翻）
    var readOnlyReason: String?
    var readOnlyReasonEn: String?
    /// 看、回复、确认、中断以外手机上还能出的按钮：mode / model / compact / subagents / tests（docs/agent-plugins.md 4.4）。
    /// 插件的会话 watcher 给；Claude Code 的和老 watcher 不带，按 agent 补（见 capsPayload）
    var caps: [String]?
    /// 待确认卡片上的按钮，插件给；没有就是手机按老样子画（拒绝 / 允许 / 本会话都允许）
    var pendingOptions: [PendingOption]?
    /// 这一轮任务做到第几步（watcher 给；老 watcher 没有）
    var stage: StageSnapshot?
    /// 目标（/goal）：agent 围着它跨多轮一直做、每轮结束检查一次（watcher 给；没设目标、老 watcher 没有）
    var goal: GoalSnapshot?

    var act: Activity { Activity(raw: activity) }

    /// 这一轮是别的会话来信引起的：答完、发图都不提醒你（会话之间的往来）
    var fromPeer: Bool { turnFrom == "peer" }

    /// 列表里显示的目标：在做的一直显示；结束了的（达成、做不到）一小时内还显示
    var listGoal: GoalSnapshot? {
        guard let goal, goal.valid else { return nil }
        if goal.running { return goal }
        guard let at = goal.at, Date().timeIntervalSince1970 * 1000 - at < 3_600_000 else { return nil }
        return goal
    }

    /// 正在做（忙、等确认）且像样的阶段才显示
    var liveStage: StageSnapshot? {
        guard act == .busy || act == .waiting, let stage, stage.valid else { return nil }
        return stage
    }

    /// 给手机的 caps：没带的 Claude Code 会话是现在 Claude Code 的全套，别家没带就是什么都没有。
    /// close（关闭会话，3.49.7 起）只由电脑端给：手机连老电脑端时的兜底全套里没有它
    /// goal（设定目标，发 /goal）：Claude Code 2.1.139 起有，按会话报来的版本给；别家由插件给（Codex 终端里的会话）
    var capsPayload: [String] {
        var out = caps ?? (agentID == "claude-code" ? ["mode", "model", "compact", "subagents", "tests", "close"] : [])
        if agentID == "claude-code", GoalSnapshot.claudeSupports(version), !out.contains("goal") { out.append("goal") }
        return out
    }

    /// 列表里显示的名字：优先用标题
    var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? name }

    /// 核对 VS Code 前台标签是不是这个会话时认的名字（见 Delivery.tabTitle）；空 = 还没发过消息
    var tabCandidates: [String] {
        ([title ?? ""] + (tabNames ?? [])).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 是否由 VS Code 扩展托管（否则视为终端里的 CLI）
    var isVSCode: Bool { entrypoint == nil || entrypoint == "claude-vscode" }

    /// agent 的 id：没标的就是 Claude Code
    var agentID: String { agent.flatMap { $0.isEmpty ? nil : $0 } ?? "claude-code" }

    /// 能不能从手机 / Mac 回复：VS Code 里的、tmux 里的、本机终端里的 Claude Code；Codex、OpenCode、DeepSeek Harness 走协议，
    /// 在哪台机器上都行；Proma 这类只读的不行
    func canReply(local: Bool) -> Bool {
        readOnly != true && (isVSCode || tmuxPane != nil || local || agentID != "claude-code")
    }

    /// 需要用户给出确认/选择时，用来描述「卡在哪」
    var blockingDescription: String? {
        if let waitingFor = waitingFor, !waitingFor.isEmpty { return waitingFor }
        if let needs = needs, !needs.isEmpty { return needs }
        if let pendingTool = pendingTool, !pendingTool.isEmpty { return "等待确认：\(pendingTool)" }
        return nil
    }
}

/// 待确认卡片的一个按钮：key 是点了发回去的按键（交给插件的 key()），style 为 primary / destructive / normal；
/// labelEn 是插件自带的英文（出口按设备语言换，单独下发的插件新加的文字不用等我们发版）
struct PendingOption: Codable, Equatable {
    var key: String
    var label: String
    var labelEn: String?
    var style: String?

    var payload: [String: Any] {
        var out: [String: Any] = ["key": key, "label": label, "style": style ?? "normal"]
        if let labelEn, !labelEn.isEmpty { out["labelEn"] = labelEn }
        return out
    }
}

/// 任务做到第几步（watcher 按工具调用推断，或 agent 用 stage 命令报的）：列表里「正在工作」前的「2/4 开发中」、对话页的任务进展。
/// 只在忙、等确认时带。字段缺了、类型不对都不抛错：多一个少一个字段不能让整个会话解析失败（见 SessionSnapshot.liveStage）
struct StageSnapshot: Codable, Equatable {
    var step = 0
    var total = 0
    var label = ""
    var steps: [String] = []
    var kinds: [String?] = []
    /// 这一步从什么时候开始、这一轮从什么时候开始（毫秒）
    var since: Double?
    var turnAt: Double?
    /// agent 报阶段时写的一句「在做什么」
    var note: String?
    /// true = 按工具调用推断的；false = agent 自己报的
    var auto = true
    /// 这一轮（规划过的是这个任务）走过的步骤：[[第几步, 开始时间]]
    var marks: [[Double]] = []
    /// 任务分了几部分（几个端）时：正在做哪部分、各部分做到第几步（step 这些说的是正在做的那部分）
    var part: String?
    var parts: [Part] = []

    struct Part: Codable, Equatable {
        var name: String
        var step: Int
        var done: Bool
    }

    private enum CodingKeys: String, CodingKey { case step, total, label, steps, kinds, since, turnAt, note, auto, marks, part, parts }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        step = (try? c.decode(Int.self, forKey: .step)) ?? 0
        total = (try? c.decode(Int.self, forKey: .total)) ?? 0
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        steps = (try? c.decode([String].self, forKey: .steps)) ?? []
        kinds = (try? c.decode([String?].self, forKey: .kinds)) ?? []
        since = try? c.decode(Double.self, forKey: .since)
        turnAt = try? c.decode(Double.self, forKey: .turnAt)
        note = (try? c.decode(String.self, forKey: .note)).flatMap { $0.isEmpty ? nil : $0 }
        auto = (try? c.decode(Bool.self, forKey: .auto)) ?? true
        marks = (try? c.decode([[Double]].self, forKey: .marks)) ?? []
        parts = ((try? c.decode([Part].self, forKey: .parts)) ?? []).filter { !$0.name.isEmpty }
        part = (try? c.decode(String.self, forKey: .part)).flatMap { name in parts.contains { $0.name == name } ? name : nil }
        if parts.count < 2 { parts = []; part = nil }
    }

    var valid: Bool { total >= 2 && (1...total).contains(step) && !label.isEmpty }

    /// 列表里那一小块：「2/4 开发中」、分了部分的「iPhone · 2/4 开发中」（步骤名按界面语言换，agent 自定的原样）
    var short: String { (part.map { "\($0) · " } ?? "") + "\(step)/\(total) \(L(label))" }

    /// 各部分的完成情况（小标识前的圆点）
    var dots: [StageDot] { parts.map { $0.done ? .done : $0.name == part ? .current : .pending } }

    /// 鼠标停在小标识上的说明：各部分到哪了、agent 的说明
    var tip: String {
        let rows = parts.map { p -> String in
            if p.done { return "\(p.name)：\(L("已完成"))" }
            let step = p.name == part ? self.step : p.step
            return "\(p.name)：" + (step >= 1 && step <= steps.count ? "\(step)/\(total) \(L(p.name == part ? label : steps[step - 1]))" : L("未开始"))
        }
        return ([L("任务进展")] + rows + [note].compactMap { $0 }).joined(separator: "\n")
    }

    var payload: [String: Any] {
        var out: [String: Any] = ["step": step, "total": total, "label": label, "steps": steps, "auto": auto,
                                  "kinds": kinds.map { $0.map { $0 as Any } ?? NSNull() }, "marks": marks.map { $0.map { Int64($0) } }]
        if let since { out["since"] = Int64(since) }
        if let turnAt { out["turnAt"] = Int64(turnAt) }
        if let note { out["note"] = note }
        if let part, !parts.isEmpty {
            out["part"] = part
            out["parts"] = parts.map { ["name": $0.name, "step": $0.step, "done": $0.done] as [String: Any] }
        }
        return out
    }
}

/// 目标（/goal；Claude Code 2.1.139 起、Codex 0.128 起）：agent 围着一个目标跨多轮一直做，每轮结束检查，确认达成才停。
/// 字段见 ccpulse-watch.py 的 GoalBook。state：active 进行中 / paused 停下了 / blocked 受阻 / limited 额度或预算用完 /
/// met 已达成 / failed 无法达成 / error 出错中止。字段缺了、类型不对都不抛错（同 StageSnapshot）
struct GoalSnapshot: Codable, Equatable {
    var text = ""
    var state = "active"
    /// 检查了几次（Claude Code 每轮结束检查一次）
    var checks: Int?
    /// 最近一次检查的说法（还差什么 / 为什么做不到）
    var reason: String?
    /// 停下的原因（接口出错、检查超时、额度用完……）
    var note: String?
    var since: Double?
    var at: Double?
    var turns: Int?
    var durationMs: Double?
    var tokens: Int?
    /// token 预算（Codex 设了才有）
    var budget: Int?

    private enum CodingKeys: String, CodingKey { case text, state, checks, reason, note, since, at, turns, durationMs, tokens, budget }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? "active"
        checks = try? c.decode(Int.self, forKey: .checks)
        reason = (try? c.decode(String.self, forKey: .reason)).flatMap { $0.isEmpty ? nil : $0 }
        note = (try? c.decode(String.self, forKey: .note)).flatMap { $0.isEmpty ? nil : $0 }
        since = try? c.decode(Double.self, forKey: .since)
        at = try? c.decode(Double.self, forKey: .at)
        turns = try? c.decode(Int.self, forKey: .turns)
        durationMs = try? c.decode(Double.self, forKey: .durationMs)
        tokens = try? c.decode(Int.self, forKey: .tokens)
        budget = try? c.decode(Int.self, forKey: .budget)
    }

    var valid: Bool { !text.isEmpty }
    /// 还在进行（含停下了、等你发话的）；结束了的是 met / failed / error
    var running: Bool { GoalText.running(state) }
    /// 正在第几轮（检查过 n 次没达成 = 在做第 n+1 轮）；没有检查次数的（Codex）不说
    var round: Int? { checks.map { running ? $0 + 1 : max(1, $0) } }

    /// Claude Code 的版本号（2.1.314）够不够用 /goal
    static func claudeSupports(_ version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        return parts.count == 3 && !parts.lexicographicallyPrecedes([2, 1, 139])
    }

    var payload: [String: Any] {
        var out: [String: Any] = ["text": text, "state": state]
        if let checks { out["checks"] = checks }
        if let reason { out["reason"] = reason }
        if let note { out["note"] = note }
        if let since { out["since"] = Int64(since) }
        if let at { out["at"] = Int64(at) }
        if let turns { out["turns"] = turns }
        if let durationMs { out["durationMs"] = Int64(durationMs) }
        if let tokens { out["tokens"] = tokens }
        if let budget { out["budget"] = budget }
        return out
    }

    /// 推送正文：目标是什么 + 结果（用了几轮、多久 / 为什么做不到 / 为什么停下）。english：给英文设备的那份
    func pushBody(english: Bool) -> String {
        let p = Phrase(english: english)
        let goal = text.count > 80 ? String(text.prefix(80)) + "…" : text
        var detail: String?
        switch state {
        case "met":
            var parts: [String] = []
            if let rounds = turns ?? checks, rounds > 0 { parts.append(p("%lld 轮", rounds)) }
            if let ms = durationMs, ms >= 60_000 {
                let minutes = Int(ms / 60_000)
                parts.append(minutes >= 120 ? p("%lld 小时", minutes / 60) : p("%lld 分钟", minutes))
            }
            detail = parts.isEmpty ? nil : p("用了 %@", parts.joined(separator: " · "))
        case "paused":
            detail = note.map { english ? ServerLang.translate($0) : $0 } ?? p("发送消息即可继续")
        default:
            detail = (note.map { english ? ServerLang.translate($0) : $0 }) ?? reason
        }
        return [p("目标：%@", goal), detail].compactMap { $0 }.joined(separator: "\n")
    }

    /// 目标从「在做」变成另一个状态：达成、做不到、停下、出错时提醒（你自己清除的不提醒，快照里就没了）
    static func ended(old: GoalSnapshot?, new: GoalSnapshot?) -> GoalSnapshot? {
        guard let new, new.valid, new.state != "active" else { return nil }
        guard let old, old.text == new.text else { return nil }   // 刚看到的（App 刚启动）、换了目标的不算
        return old.state != new.state ? new : nil
    }
}

struct EffortInfo: Codable, Equatable {
    var effort: String?
    var ultracode: Bool?
    /// 权限模式：default / acceptEdits / plan / auto / bypassPermissions（你最近一句话发出时的模式）
    var mode: String?
}

/// 接口错误（watcher 已经翻译成人话）：kind = limit / too_long / api / billing / auth
struct APIErrorInfo: Codable, Equatable {
    var kind: String
    var text: String
    /// 用量上限什么时候恢复（毫秒）
    var resetAt: Double?
    var raw: String?

    /// 带上本机时间的恢复时刻：「Claude 用量到上限了，21:10 恢复」；已经过了就说可以接着做
    var display: String {
        guard let reset = resetAt, reset > 0 else { return text }
        let date = Date(timeIntervalSince1970: reset / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        if date <= Date() { return "\(text)（\(formatter.string(from: date)) 已恢复，发送「继续」即可接着执行）" }
        return "\(text)，\(formatter.string(from: date)) 恢复"
    }
}

/// 会话用量：上下文占用、累计 token、花费（花费来自 Claude Code 自己记的 cost-state）
struct UsageInfo: Codable, Equatable {
    var context: Int
    var window: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var requests: Int?
    var model: String?
    var cost: Double?
    var costAt: Double?

    var contextRatio: Double { window > 0 ? min(1, Double(context) / Double(window)) : 0 }
    var percent: Int { Int((contextRatio * 100).rounded()) }
    var totalTokens: Int { input + output + cacheRead + cacheWrite }

    static func compact(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fk", v / 1_000) }
        return "\(value)"
    }

    var payload: [String: Any] {
        var dict: [String: Any] = ["context": context, "window": window, "input": input, "output": output,
                                   "cacheRead": cacheRead, "cacheWrite": cacheWrite, "percent": percent]
        if let requests = requests { dict["requests"] = requests }
        if let model = model { dict["model"] = model }
        if let cost = cost { dict["cost"] = cost }
        return dict
    }
}
