import Foundation
import Observation

/// 一个会话的对话内容：Mac 推来的条目、翻页状态、还没回显的发送
@MainActor
@Observable
final class ChatStore {
    let key: String
    private(set) var items: [String: ChatItem] = [:]
    /// 工具结果按工具调用 id 存，画工具那一步时一起显示
    private(set) var results: [String: ChatItem] = [:]
    var pending: [PendingSend] = []
    var hasMore = true
    var loading = false
    var loaded = false
    /// 用户点开过的折叠步骤组
    var expanded: Set<String> = []
    /// 离开超过 10 分钟再回来：从这个时间之后的标「以下是新消息」
    var newSince: Double?
    /// 刚点过「允许 / 拒绝」的那个确认：等 Mac 状态更新前别再弹出来
    var answeredPrompt: String?
    /// 提问卡片上已经选了的（切出去再回来还在）
    var answers: [String: [QuestionAnswer]] = [:]
    /// 长按消息选了「引用」：发的时候带在前面
    var quote: String?
    /// 输入栏下面的「+」面板开着（点对话区收起）
    var panelOpen = false
    /// 终端面板开着（在输入区的位置，见 TerminalPanel）
    var terminalOpen = false
    /// 用语音发的消息（按转写文字对应），对话里画成语音条
    var voices: [String: VoiceClip] = [:]
    /// 刚在手机上切过的权限模式：Claude Code 要等你下一句话才把新模式写进记录，在那之前按切过去的显示
    var modeOverride: (mode: PermissionMode, baseline: String?)?
    /// 刚在手机上换的模型：要等 Claude 下一次回复，用量里的模型才变，在那之前按换过去的显示（send 是发的那条 /model，发送失败就不算）
    var modelOverride: (model: String, baseline: String?, send: String)?
    /// 刚在手机上发的 /effort（思考等级 / Ultracode）：Claude Code 执行了、记录里认出来之前按发过去的显示。
    /// Claude 在忙时 /effort 要等这一轮做完才执行；send 是发的那条消息，发送失败就不算
    var effortOverride: (effort: String, baseline: String?, send: String)?
    var ultracodeOverride: (on: Bool, baseline: Bool, send: String)?
    /// Mac 输入区里还没发的附图（粘贴、拖进来、选的）
    var attachments: [ComposeAttachment] = []
    /// Mac 输入区上面的常用语展开着（每个会话各记各的：分屏时只展开点的那一块）
    var quickRepliesShown = false
    /// 目标面板开着（输入框下面的「目标」、目标条、会话菜单都能打开，对话页统一弹）
    var goalSheet = false
    private(set) var revision = 0

    init(key: String) { self.key = key }

    func add(_ new: [ChatItem]) {
        guard !new.isEmpty else { return }
        var users: [ChatItem] = []
        var goalNoted = false
        for item in new {
            if item.t == "result", let toolId = item.toolId { results[toolId] = item }
            if item.t == "user" { users.append(item) }
            if item.t == "event", item.goal != nil { goalNoted = true }
            items[item.id] = item
        }
        if !users.isEmpty, !pending.isEmpty { settle(users) }
        // 发的 /goal：对话里出了「已设定目标」这类提示就算到了（Codex 的目标不当成一句话回显）
        if goalNoted { pending.removeAll { !$0.isFailed && $0.text.hasPrefix("/goal") } }
        revision += 1
    }

    func reset() {
        items = [:]
        results = [:]
        hasMore = true
        loaded = false
        revision += 1
    }

    /// 发出去的消息在对话记录里回显了，撤掉本地的「发送中」
    private func settle(_ users: [ChatItem]) {
        pending.removeAll { p in
            if case .failed = p.state { return false }
            if p.voice != nil, p.text.isEmpty { return false }   // 语音还没转写完，认不出是哪条
            let head = String(p.text.prefix(24))
            return users.contains { u in head.isEmpty ? !(u.images ?? []).isEmpty : (u.text ?? "").contains(head) }
        }
    }

    /// 语音的转写刚回来：回显可能已经先到了，再对一遍
    func settleAgain() {
        let users = items.values.filter { $0.t == "user" }
        if !users.isEmpty { settle(Array(users)) }
    }

    /// 这条发送失败了（还留着「轻点重新发送」）
    func sendFailed(_ id: String) -> Bool { pending.contains { $0.id == id && $0.isFailed } }

    func update(_ id: String, _ change: (inout PendingSend) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        change(&pending[index])
    }

    /// 往前翻页的位置
    var oldestOffset: Int? { items.values.filter { !$0.id.hasPrefix("o") }.map(\.offset).min() }
    var oldestTs: Double? { items.values.compactMap(\.ts).min() }

    /// 本轮从哪开始算（最后一条用户消息的时间，和 Claude Code 计时一致）
    var turnStart: Double? { items.values.filter { $0.t == "user" }.compactMap(\.ts).max() }

    /// 最新一次任务清单
    var todos: [JSONValue] {
        items.values.filter { $0.t == "tool" && $0.name == "TodoWrite" }.max(by: ChatItem.ordered)?.input?["todos"]?.array ?? []
    }

    var openTool: ChatItem? { ChatLayout.openTool(items, results) }

    func rows(session: SessionInfo?) -> [ChatRow] { rows(activity: session?.activity) }

    /// 行只跟会话在忙 / 等确认 / 空闲有关（步骤卡片转圈、最后一组步骤折不折叠）
    func rows(activity: String?) -> [ChatRow] {
        ChatLayout.build(items: items, results: results, pending: pending, activity: activity, expanded: expanded, newSince: newSince)
    }
}

/// 发过的一段语音：Mac 上存着录音，按 id 取回来放
struct VoiceClip: Hashable {
    var id: String
    var duration: Double
}

/// 提问卡片上一题的回答
struct QuestionAnswer: Hashable {
    var picked: Set<String> = []
    var other = ""
}
