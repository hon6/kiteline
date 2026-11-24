import Foundation
import Observation

/// 一个会话的对话内容：Mac 推来的条目、翻页状态、还没回显的发送
@MainActor
final class ChatStore: KLObservable {
    let _klRegistrar = KLRegistrar.make()
    let key: String
    @Tracked private(set) var items: [String: ChatItem] = [:]
    /// 工具结果按工具调用 id 存，画工具那一步时一起显示
    @Tracked private(set) var results: [String: ChatItem] = [:]
    @Tracked var pending: [PendingSend] = []
    /// 收到过的用户消息（id + 时间；reset 后也留着）：重新加载历史时再来一遍的旧消息不拿去认回显
    private var seenUsers: Set<String> = []
    @Tracked var hasMore = true
    @Tracked var loading = false
    @Tracked var loaded = false
    /// 用户点开过的折叠步骤组
    @Tracked var expanded: Set<String> = []
    /// 离开超过 10 分钟再回来：从这个时间之后的标「以下是新消息」
    @Tracked var newSince: Double?
    /// 刚点过「允许 / 拒绝」的那个确认：等 Mac 状态更新前别再弹出来
    @Tracked var answeredPrompt: String?
    /// 提问卡片上已经选了的（切出去再回来还在）
    @Tracked var answers: [String: [QuestionAnswer]] = [:]
    /// 长按消息选了「引用」：发的时候带在前面
    @Tracked var quote: String?
    /// 输入栏下面的「+」面板开着（点对话区收起）
    @Tracked var panelOpen = false
    /// 终端面板开着（在输入区的位置，见 TerminalPanel）
    @Tracked var terminalOpen = false
    /// 用语音发的消息（按转写文字对应），对话里画成语音条
    @Tracked var voices: [String: VoiceClip] = [:]
    /// 刚在手机上切过的权限模式：Claude Code 要等你下一句话才把新模式写进记录，在那之前按切过去的显示
    @Tracked var modeOverride: (mode: PermissionMode, baseline: String?)?
    /// 刚在手机上换的模型：要等 Claude 下一次回复，用量里的模型才变，在那之前按换过去的显示（send 是发的那条 /model，发送失败就不算）
    @Tracked var modelOverride: (model: String, baseline: String?, send: String)?
    /// 刚在手机上发的 /effort（思考等级 / Ultracode）：Claude Code 执行了、记录里认出来之前按发过去的显示。
    /// Claude 在忙时 /effort 要等这一轮做完才执行；send 是发的那条消息，发送失败就不算
    @Tracked var effortOverride: (effort: String, baseline: String?, send: String)?
    @Tracked var ultracodeOverride: (on: Bool, baseline: Bool, send: String)?
    /// Mac 输入区里还没发的附图（粘贴、拖进来、选的）
    @Tracked var attachments: [ComposeAttachment] = []
    /// Mac 输入区上面的常用语展开着（每个会话各记各的：分屏时只展开点的那一块）
    @Tracked var quickRepliesShown = false
    /// 目标面板开着（输入框下面的「目标」、目标条、会话菜单都能打开，对话页统一弹）
    @Tracked var goalSheet = false
    /// 刚在这台设备上调过排队消息（上移 / 下移 / 改 / 删）：电脑的新队列传回来之前按调过的显示，别让列表跳回去
    @Tracked var queueDraft: (items: [QueuedItem], at: Date)?
    /// 排队列表收起了
    @Tracked var queueCollapsed = false
    @Tracked private(set) var revision = 0
    /// 正在生成的那一块（电脑推的 live，见 watcher 的 LiveTap）：画在对话最后、一个字一个字长出来。
    /// 对话记录要等一整块说完才写，以前长回复要等很久才一下子出来，终端里却早就逐字出了（11-24）
    @Tracked private(set) var live: ChatItem?
    private var liveN = 0
    /// 电脑说这一块说完了：记录里那条（几乎同时到）到了再撤，免得中间空一下；3 秒还没到也撤
    private var liveEnding = false

    /// 输入框上方排队列表的一行：电脑队列里的（能改）或这台设备刚发、还没在队列里出现的
    struct QueueRow: Identifiable, Hashable {
        var id: String
        var text: String
        /// 能上移、下移、编辑、删除（电脑队列里的）；否则只能强插
        var editable: Bool
        /// 还在发往电脑的路上（发的时候 Claude 正忙，先列在这里）：还不能强插
        var sending = false
    }

    /// 排队列表：电脑给了队列就按它（加上刚发、还没出现在里面的）；老版本（没有队列）列这台设备记下的排队消息
    func queueRows(_ session: SessionInfo?) -> [QueueRow] {
        let mine = pending.filter(\.inQueueStrip)
        guard let session, var queue = session.queue else {
            return mine.map { QueueRow(id: $0.qid ?? $0.id, text: $0.text, editable: false, sending: $0.state == .sending) }
        }
        if let draft = queueDraft, Date().timeIntervalSince(draft.at) < 4 { queue = draft.items }
        let known = Set(queue.map(\.id))
        return queue.map { QueueRow(id: $0.id, text: $0.text, editable: true) }
            + mine.filter { !$0.seen && !known.contains($0.qid ?? "") }
                .map { QueueRow(id: $0.qid ?? $0.id, text: $0.text, editable: false, sending: $0.state == .sending) }
    }

    init(key: String) { self.key = key }

    func add(_ new: [ChatItem]) {
        guard !new.isEmpty else { return }
        var users: [ChatItem] = []
        var goalNoted = false
        for item in new {
            if item.t == "result", let toolId = item.toolId { results[toolId] = item }
            if item.t == "user", seenUsers.insert("\(item.id)|\(item.ts ?? 0)").inserted { users.append(item) }
            if item.t == "event", item.goal != nil { goalNoted = true }
            items[item.id] = item
        }
        if !users.isEmpty, !pending.isEmpty { settle(users) }
        if liveEnding, new.contains(where: { $0.t == "text" || $0.t == "thinking" || $0.t == "tool" }) {
            live = nil
            liveEnding = false
        }
        // 发的 /goal：对话里出了「已设定目标」这类提示就算到了（Codex 的目标不当成一句话回显）
        if goalNoted { pending.removeAll { !$0.isFailed && $0.text.hasPrefix("/goal") } }
        revision += 1
    }

    /// 电脑推来的 live 事件：text 是整段（新的一块、或隔一会儿补一次），append 是接在后面的（n 接不上就等下一次整段）
    func applyLive(_ event: LiveEvent) {
        if event.clear == true {
            guard let current = live, !liveEnding else { return }
            liveEnding = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(seconds: 3)
                guard let self, self.liveEnding, self.live?.detail == current.detail else { return }
                self.live = nil
                self.liveEnding = false
            }
            return
        }
        guard let block = event.id, let kind = event.kind, let n = event.n else { return }
        if let text = event.text {
            // 排在已有内容后面：用电脑上这一块开始的时刻（和记录同一个钟），不早于已有的最后一条
            let ts = live?.detail == block ? live?.ts : max(event.at ?? 0, (items.values.compactMap(\.ts).max() ?? 0) + 1)
            live = ChatItem(t: kind, id: "live", ts: ts, text: text, detail: block)
        } else if let append = event.append, var current = live, current.detail == block, n == liveN + 1 {
            current.text = (current.text ?? "") + append
            live = current
        } else {
            return
        }
        liveN = n
        liveEnding = false
    }

    func reset() {
        items = [:]
        live = nil
        liveEnding = false
        results = [:]
        hasMore = true
        loaded = false
        revision += 1
    }

    /// 发出去的消息在对话记录里回显了，撤掉本地的「发送中」。
    /// 只认这条发出之后才有的用户消息（电脑和手机的钟可能差一点，放宽两分钟）：以前只比文字，网络不好重连、重新加载历史时，
    /// 早先发过的同样的话（「继续」「好的」）被当成回显，还没送到的这条就被悄悄撤掉、也不再重发（11-20 反馈「消息没了」）
    private func settle(_ users: [ChatItem]) {
        pending.removeAll { p in
            if case .failed = p.state { return false }
            if p.voice != nil, p.text.isEmpty { return false }   // 语音还没转写完，认不出是哪条
            let head = String(p.text.prefix(24))
            return users.contains { u in
                guard (u.ts ?? .infinity) >= p.at - 120_000 else { return false }
                return head.isEmpty ? !(u.images ?? []).isEmpty : (u.text ?? "").contains(head)
            }
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
        var items = items
        if let live { items[live.id] = live }
        return ChatLayout.build(items: items, results: results, pending: pending, activity: activity, expanded: expanded, newSince: newSince)
    }
}

/// 电脑推来的正在生成的文字（见 ChatStore.applyLive）
struct LiveEvent: Decodable {
    var key: String
    var id: String?
    var kind: String?
    var n: Int?
    var text: String?
    var append: String?
    var at: Double?
    var clear: Bool?
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
