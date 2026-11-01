import Foundation
import Observation

// 会话群（电脑上 Sources/Groups.swift / 电脑端 groups.py 存着，/api/groups + 实时通道的 groups、group_msg 事件）：
// 用户把几个会话（可以在不同电脑、不同项目里）拉进一个群，它们经 Kiteline 互相发消息协作；用户也在群里，能看到全部往来、直接发话。
// 成员会话全都关了 = 历史群；在历史群里发消息，电脑会把成员会话恢复过来接着协作。

/// 群在分屏里同会话一样开成标签页（左右、上下分屏，拖来拖去都一样）：key 是 @group:<群 id>，Mac 左边栏的选中值也是它
enum GroupKey {
    static let prefix = "@group:"

    static func make(_ id: String) -> String { prefix + id }

    /// 是群的 key 就给群 id，会话的 key 给 nil
    static func id(_ key: String?) -> String? {
        guard let key, key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }
}

/// 分屏标签栏上点的群操作，交给那个群聊页去做（面板、确认都由它弹）
enum GroupAction { case members, add, rename, disband }

struct GroupMember: Decodable, Identifiable, Hashable {
    var key: String
    /// 加群时 / 最近一次在跑时的标题（会话关了也认得出）
    var title: String
    var machine: String?
    var project: String?
    var agent: String?
    var joinedAt: Double

    var id: String { key }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        key = c.text("key") ?? ""
        title = c.text("title") ?? ""
        machine = c.text("machine")
        project = c.text("project")
        agent = c.text("agent")
        joinedAt = c.num("joinedAt")
    }

    /// 「gpu-server · content-studio」
    var place: String { [machine, project].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
}

struct GroupMessage: Decodable, Identifiable, Hashable {
    var id: String
    var ts: Double
    /// 成员 key；me = 用户；system = 群提示（谁加入了、改了群名、暂停了转发）
    var from: String
    var fromTitle: String
    var text: String
    /// 只发给这几个成员（nil = 全部）
    var to: [String]?
    /// 各收件成员的投递状态：pending / sent / filled / ended / paused / failed
    var states: [String: String]
    var notes: [String: String]
    /// agent 发的：出自它对话里的哪一条
    var itemId: String?
    /// 群提示的种类和名字（见 Sources/Groups.swift 的 Message.event）：按界面语言拼句子
    var event: String?
    var args: [String]
    /// 用户随消息发的图、文件（存在电脑上，经 /api/groups/media 取）
    var images: [GroupMedia]
    var files: [GroupMedia]

    var mine: Bool { from == "me" }
    var system: Bool { from == "system" }

    /// 群提示显示成什么（不认识的种类、老电脑端：电脑拼好的中文）
    var eventText: String {
        let names = args.joined(separator: L("、"))
        switch event {
        case "created": return L("建群：%@", names)
        case "joined": return L("加入群：%@", names)
        case "left": return L("移出群：%@", names)
        case "renamed": return L("群名改为「%@」", names)
        case "named" where args.count == 2: return L("%@ 给群起名「%@」", args[0], args[1])
        case "paused": return L("已暂停转发")
        case "resumed": return L("已继续转发")
        case "autopaused": return L("agent 之间已连续往来 %@ 条，已暂停转发；轻点「继续转发」接着投递", args.first ?? "")
        default: return text
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? UUID().uuidString
        ts = c.num("ts")
        from = c.text("from") ?? "system"
        fromTitle = c.text("fromTitle") ?? ""
        text = c.text("text") ?? ""
        to = c.one("to")
        states = c.one("states") ?? [:]
        notes = c.one("notes") ?? [:]
        itemId = c.text("itemId")
        event = c.text("event")
        args = c.list("args")
        images = c.list("images")
        files = c.list("files")
    }
}

/// 群消息里的一张图 / 一个文件：ref 是电脑上存的文件名，name 是原名
struct GroupMedia: Decodable, Hashable {
    var ref: String
    var name: String
    var size: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        ref = c.text("ref") ?? ""
        name = c.text("name") ?? ""
        size = Int(c.num("size"))
    }
}

struct GroupInfo: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    /// 群名还是临时凑的（等第一个发言的 agent 起正式名字）
    var autoName: Bool
    var topic: String?
    var createdAt: Double
    var updatedAt: Double
    /// agent 之间往来太多条，转发暂停了（等用户点继续）
    var paused: Bool
    /// 标记（排最上面、群名前一颗星）、免打扰（agent 发言不推送）：同会话
    var marked: Bool
    var muted: Bool
    var count: Int
    var members: [GroupMember]
    var last: GroupMessage?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? ""
        name = c.text("name") ?? ""
        autoName = c.one("autoName") ?? false
        topic = c.text("topic")
        createdAt = c.num("createdAt")
        updatedAt = c.num("updatedAt")
        paused = c.one("paused") ?? false
        marked = c.one("marked") ?? false
        muted = c.one("muted") ?? false
        count = c.int("count")
        members = c.list("members")
        last = c.one("last")
    }

    func member(_ key: String) -> GroupMember? { members.first { $0.key == key } }
}

private struct GroupList: Decodable {
    var items: [GroupInfo]
    init(from decoder: Decoder) throws { items = try decoder.fields().list("items") }
}

private struct GroupMessages: Decodable {
    var id: String
    var items: [GroupMessage]
    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? ""
        items = c.list("items")
    }
}

private struct GroupMessageEvent: Decodable {
    var id: String
    var message: GroupMessage?
    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? ""
        message = c.one("message")
    }
}

/// 各群概要 + 打开过的群的消息
@MainActor
@Observable
final class GroupBoard {
    private(set) var items: [GroupInfo] = []
    /// 取到过一次群列表（之前 items 空着不代表没有群）
    private(set) var loaded = false
    /// 群 id → 全部消息（打开群时取一次，之后跟着 group_msg 事件加）
    private(set) var messages: [String: [GroupMessage]] = [:]
    /// 自己发出去、电脑还没回的（先显示在群里，发送中）
    private(set) var sending: [String: [String]] = [:]

    func group(_ id: String) -> GroupInfo? { items.first { $0.id == id } }

    /// 这个会话在的群（新的在前）
    func groups(containing key: String) -> [GroupInfo] { items.filter { $0.member(key) != nil } }

    func load(_ api: MacAPI) async {
        guard let data = try? await api.data("/api/groups") else { return }
        apply(data)
    }

    /// groups 事件、/api/groups：整份换掉
    func apply(_ data: Data) {
        guard let list = try? JSONDecoder().decode(GroupList.self, from: data) else { return }
        items = Self.ordered(list.items)
        loaded = true
        // 解散了的群：消息也不留
        let ids = Set(items.map(\.id))
        for id in messages.keys where !ids.contains(id) { messages[id] = nil }
    }

    /// 标记的排前面，再按最近动静
    private static func ordered(_ list: [GroupInfo]) -> [GroupInfo] {
        list.sorted { $0.marked != $1.marked ? $0.marked : $0.updatedAt > $1.updatedAt }
    }

    /// 标记 / 免打扰：先在本机改（星星、铃铛立刻变），电脑没接住再改回来
    func setFlags(_ id: String, marked: Bool? = nil, muted: Bool? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let marked { items[index].marked = marked }
        if let muted { items[index].muted = muted }
        items = Self.ordered(items)
    }

    /// group_msg 事件：一条新消息，或投递状态变了
    func receive(_ data: Data) {
        guard let event = try? JSONDecoder().decode(GroupMessageEvent.self, from: data), let message = event.message else { return }
        upsert(event.id, message)
    }

    func loadMessages(_ id: String, api: MacAPI) async {
        guard let data = try? await api.data("/api/groups/messages", ["id": id]),
              let list = try? JSONDecoder().decode(GroupMessages.self, from: data) else { return }
        messages[id] = list.items
    }

    func upsert(_ id: String, _ message: GroupMessage) {
        var list = messages[id] ?? []
        if let index = list.firstIndex(where: { $0.id == message.id }) {
            list[index] = message
        } else {
            list.append(message)
            list.sort { $0.ts < $1.ts }
        }
        if messages[id] != nil || !list.isEmpty { messages[id] = list }
        if let index = items.firstIndex(where: { $0.id == id }), !message.system, (items[index].last?.ts ?? 0) <= message.ts {
            items[index].last = message
        }
    }

    func markSending(_ id: String, _ text: String, on: Bool) {
        if on { sending[id, default: []].append(text) } else { sending[id]?.removeAll { $0 == text } }
    }
}

extension AppModel {
    /// 连着的电脑能拉群（老版本电脑端没有，不给入口）
    var supportsGroups: Bool { hostFeatures.contains("groups") }

    /// 连着的电脑能在群里收图、文件（老版本只收文字：输入栏不给「+」里的相册、文件）
    var supportsGroupMedia: Bool { hostFeatures.contains("groupMedia") }

    /// 还有成员会话在跑的 = 进行中的群；全都关了 = 历史群
    func isLive(_ group: GroupInfo) -> Bool { group.members.contains { session($0.key) != nil } }

    /// 成员现在叫什么：在跑的用会话列表里的标题（改过名的跟着变）
    func title(of member: GroupMember) -> String { session(member.key)?.title ?? member.title }

    /// 建群，返回群 id
    func createGroup(keys: [String], topic: String) async -> String? {
        do {
            let data = try await api.postData("/api/groups/create", body: ["keys": keys, "topic": topic])
            let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            await groups.load(api)
            return (reply?["group"] as? [String: Any])?["id"] as? String
        } catch {
            show(error)
            return nil
        }
    }

    @discardableResult
    func addToGroup(_ id: String, keys: [String]) async -> Bool {
        await groupCall("/api/groups/add", ["id": id, "keys": keys])
    }

    func removeFromGroup(_ id: String, key: String) async {
        _ = await groupCall("/api/groups/remove", ["id": id, "key": key])
    }

    func renameGroup(_ id: String, _ name: String) async {
        _ = await groupCall("/api/groups/rename", ["id": id, "name": name])
    }

    func pauseGroup(_ id: String, _ paused: Bool) async {
        _ = await groupCall("/api/groups/pause", ["id": id, "paused": paused])
    }

    func markGroup(_ id: String, _ on: Bool) {
        groups.setFlags(id, marked: on)
        Haptics.tap()
        Task { if !(await groupFlag("/api/groups/mark", ["id": id, "marked": on])) { groups.setFlags(id, marked: !on) } }
    }

    func muteGroup(_ id: String, _ on: Bool) {
        groups.setFlags(id, muted: on)
        Task { if !(await groupFlag("/api/groups/mute", ["id": id, "muted": on])) { groups.setFlags(id, muted: !on) } }
    }

    /// 只改个开关：不用重取群列表和消息（电脑会推 groups 事件）
    private func groupFlag(_ path: String, _ body: [String: Any]) async -> Bool {
        do {
            _ = try await api.postData(path, body: body)
            return true
        } catch {
            show(error)
            return false
        }
    }

    func deleteGroup(_ id: String) async {
        _ = await groupCall("/api/groups/delete", ["id": id])
    }

    /// 在群里发话（可带图、文件）：发给全部成员（或 to 里的几个）；关了的成员电脑会先恢复它
    func sendToGroup(_ id: String, text: String, to: [String]?, images: [(name: String, data: Data, preview: Data)] = [],
                     files: [(name: String, data: Data)] = []) async -> Bool {
        let shown = text.isEmpty ? (images.isEmpty ? L("[文件]") : L("[图片]")) : text
        groups.markSending(id, shown, on: true)
        defer { groups.markSending(id, shown, on: false) }
        var body: [String: Any] = ["id": id, "text": text]
        if let to, !to.isEmpty { body["to"] = to }
        if !images.isEmpty { body["images"] = images.map { ["name": $0.name, "data": $0.data.base64EncodedString()] } }
        if !files.isEmpty { body["files"] = files.map { ["name": $0.name, "data": $0.data.base64EncodedString()] } }
        do {
            let data = try await api.postData("/api/groups/send", body: body)
            if let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let raw = reply["message"], let json = try? JSONSerialization.data(withJSONObject: raw),
               let message = try? JSONDecoder().decode(GroupMessage.self, from: json) {
                groups.upsert(id, message)
            }
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func groupCall(_ path: String, _ body: [String: Any]) async -> Bool {
        do {
            let data = try await api.postData(path, body: body)
            if path == "/api/groups/delete" { groups.apply(data) } else { await groups.load(api) }
            if let id = body["id"] as? String, groups.group(id) != nil { await groups.loadMessages(id, api: api) }
            return true
        } catch {
            show(error)
            return false
        }
    }
}
