import Foundation

/// 一步（思考 / 工具调用 / 单独的工具结果）的状态：转圈、等确认、成功、出错
enum StepState: Hashable { case none, running, waiting, ok, failed }

struct Step: Identifiable, Hashable {
    var item: ChatItem
    var result: ChatItem?
    var state: StepState
    var id: String { item.id }
}

/// 发出去、还没在对话记录里回显的消息
struct PendingSend: Identifiable, Hashable {
    /// unconfirmed：空闲的会话发出去好一会儿，Claude 没动、对话里也没出现这条（多半没提交上）
    enum State: Hashable { case sending, sent, filled, queued, failed(String), unconfirmed }
    let id: String
    var text: String
    var previews: [Data]
    var payload: [[String: String]]
    /// 跟着发的文件（PDF、Excel……）：显示用的名字、大小，和要传给电脑的 [{name, data(base64)}]
    var files: [PendingFile] = []
    var filePayload: [[String: String]] = []
    var state: State = .sending
    var override = false
    /// 语音：时长（秒）和录音（失败重发要用）；文字是 Mac 转写回来以后才有
    var voice: Double?
    var audio: Data?
}

struct PendingFile: Hashable {
    var name: String
    var size: Int
}

/// 对话页的一行
enum ChatRow: Identifiable, Hashable {
    case separator(id: String, text: String)
    case newMarker
    case user(ChatItem, first: Bool)
    /// Claude 的回复正文、发来的图、任务清单
    case bot(ChatItem, first: Bool)
    /// 一串连续的步骤（思考、工具）；hidden = 折叠起来的前几步
    case steps(id: String, steps: [Step], hidden: Int, first: Bool)
    case event(ChatItem)
    case pending(PendingSend, first: Bool)

    /// 这一行里有没有这条（搜索结果跳转用：工具调用在步骤组里）
    func contains(_ itemId: String) -> Bool {
        switch self {
        case .user(let it, _), .bot(let it, _), .event(let it): return it.id == itemId
        case .steps(_, let steps, _, _): return steps.contains { $0.item.id == itemId || $0.result?.id == itemId }
        default: return false
        }
    }

    var id: String {
        switch self {
        case .separator(let id, _): return "sep-\(id)"
        case .newMarker: return "new-marker"
        case .user(let it, _), .bot(let it, _), .event(let it): return it.id
        case .steps(let id, _, _, _): return "steps-\(id)"
        case .pending(let p, _): return "pending-\(p.id)"
        }
    }
}

/// 把一个会话的所有条目排成对话页的行（和手机网页的 renderChat 同一套规则）
enum ChatLayout {
    /// 认得的对话项种类；以后的插件新加的种类按一行提示（event）显示：不丢、不报错，也不当成回复
    static let knownKinds: Set<String> = ["user", "text", "thinking", "tool", "result", "agent_image", "agent_page", "agent_todo", "agent_key", "group_say", "event"]

    static func isStep(_ item: ChatItem) -> Bool {
        item.t == "thinking" || item.t == "result" || (item.t == "tool" && item.name != "TodoWrite" && !isPeerCard(item))
    }

    /// 会话之间的消息画成卡片（发出的那步、收到的那条），不夹在步骤里；设置里关了卡片就照旧
    static func isPeerCard(_ item: ChatItem) -> Bool {
        item.peer != nil && PeerPrefs.cards && (item.t == "tool" || item.t == "event")
    }

    /// 最后一个还没有结果的工具调用：Claude 正在跑它，或者正等你确认它
    static func openTool(_ items: [String: ChatItem], _ results: [String: ChatItem]) -> ChatItem? {
        items.values.filter { $0.t == "tool" && !results.keys.contains($0.toolId ?? "") }.max(by: ChatItem.ordered)
    }

    static func build(items: [String: ChatItem], results: [String: ChatItem], pending: [PendingSend],
                      activity: String?, expanded: Set<String>, newSince: Double?) -> [ChatRow] {
        let toolIds = Set(items.values.compactMap { $0.t == "tool" ? $0.toolId : nil })
        let list = items.values.filter { item in
            if item.t == "result", let toolId = item.toolId, toolIds.contains(toolId) { return false }   // 并进工具那一步
            if item.t == "thinking", (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            if !knownKinds.contains(item.t), (item.text ?? "").isEmpty, item.detail == nil { return false }
            return true
        }.sorted(by: ChatItem.ordered)
        let open = openTool(items, results)

        var rows: [ChatRow] = []
        var prevTs: Double?
        var prevSide = ""
        var steps: [Step] = []
        var stepsFirst = false
        var markedNew = false

        func flushSteps(live: Bool) {
            guard let head = steps.first else { return }
            let collapse = steps.count > 6 && !live && !expanded.contains(head.id)
            rows.append(.steps(id: head.id, steps: steps, hidden: collapse ? steps.count - 3 : 0, first: stepsFirst))
            steps = []
        }

        for item in list {
            if let ts = item.ts, prevTs == nil || ts - prevTs! > 5 * 60 * 1000 {
                flushSteps(live: false)
                rows.append(.separator(id: item.id, text: Format.separator(ts)))
                prevSide = ""
            }
            if let since = newSince, !markedNew, let ts = item.ts, ts > since, item.id != list.first?.id {
                flushSteps(live: false)
                rows.append(.newMarker)
                markedNew = true
                prevSide = ""
            }
            if let ts = item.ts { prevTs = ts }

            if item.t == "event", isPeerCard(item) {
                flushSteps(live: false)
                rows.append(.bot(item, first: prevSide != "bot"))
                prevSide = "bot"
            } else if item.t == "event" || !knownKinds.contains(item.t) {
                flushSteps(live: false)
                rows.append(.event(item))
                prevSide = "center"
            } else if item.t == "user" {
                flushSteps(live: false)
                rows.append(.user(item, first: prevSide != "me"))
                prevSide = "me"
            } else if isStep(item) {
                if steps.isEmpty { stepsFirst = prevSide != "bot" }
                steps.append(Step(item: item, result: stepResult(item, results), state: state(item, results, open: open, activity: activity)))
                prevSide = "bot"
            } else {
                flushSteps(live: false)
                rows.append(.bot(item, first: prevSide != "bot"))
                prevSide = "bot"
            }
        }
        // 最后一组步骤：Claude 还在忙就别折叠
        flushSteps(live: activity.map { $0 != "idle" } ?? false)
        for (index, p) in pending.enumerated() {
            rows.append(.pending(p, first: index == 0 && prevSide != "me"))
        }
        return rows
    }

    private static func stepResult(_ item: ChatItem, _ results: [String: ChatItem]) -> ChatItem? {
        if item.t == "result" { return item }
        if item.t == "tool", let toolId = item.toolId { return results[toolId] }
        return nil
    }

    private static func state(_ item: ChatItem, _ results: [String: ChatItem], open: ChatItem?, activity: String?) -> StepState {
        if item.t == "thinking" { return .none }
        if let result = stepResult(item, results) { return result.isError == true ? .failed : .ok }
        guard let activity else { return .none }
        if open?.id == item.id { return activity == "waiting" ? .waiting : (activity == "busy" ? .running : .none) }
        return activity == "busy" ? .running : .none
    }
}
