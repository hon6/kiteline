import Foundation

// 待办（Mac 上 Sources/Todos.swift 存着；/api/todos + 实时通道的 todos 事件），分两种、分开显示（10-27 起的）：
// - 我的待办：只有你能做的事。agent 经待办技能提醒（提示 suggestions）→ 你选「现在处理」或「加入待办」；也能自己记。
//   带来源的「回到会话」：打开原会话、输入框里先写好「已处理好：…」，你确认后发给 agent。
// - agent 的待办：agent 自己以后要做的事，它自己开始做、更新进度、做完；你只看是哪个会话在处理、到哪一步了。

struct TodoSource: Decodable, Hashable {
    var key: String
    var itemId: String
    /// 加进来时会话叫什么
    var title: String
    var machine: String?
    /// 那条消息的时间（毫秒）
    var ts: Double?
    /// 会话的项目目录、哪个 agent（新电脑端才给）：agent 的待办按项目、按 Agent 分组用
    var cwd: String?
    var agent: String?
}

/// agent 的待办正在哪个会话里处理
struct TodoHandler: Decodable, Hashable {
    var key: String
    var title: String
    var machine: String?
    var cwd: String?
    var agent: String?
}

struct TodoItem: Decodable, Identifiable, Hashable {
    var id: String
    var text: String
    var done: Bool
    var createdAt: Double
    var doneAt: Double?
    var source: TodoSource?
    /// 附的截图（Mac 上 /api/todos/media?ref=）
    var images: [ChatImage]
    /// 说明：背景、做到哪一步（agent 记的时候写的）
    var detail: String?
    /// 要你自己动手的事：没有「交给」
    var forUser: Bool
    /// agent 记的
    var agent: Bool
    /// agent 自己的待办：编号、状态（pending / doing / done）、最近的进度、正在处理的会话、最近更新时间
    var ref: String?
    var status: String?
    var progress: String?
    var handler: TodoHandler?
    var updatedAt: Double?

    /// agent 自己的待办（不是要你做的）：单独一块，只看进度
    var agentTask: Bool { agent && !forUser }
    /// 长按菜单里「创建会话」：agent 的待办没人接着做时，自己开个会话交代下去
    var suggestsSession: Bool { agentTask && !done }
    /// 新会话的任务内容：标题 + 说明
    var task: String { [text, detail ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n") }

    /// 截图的地址（RemoteImage、看大图用；key 只是让手机上的缓存归到一类）
    static let mediaPath = "/api/todos/media"
    static func mediaQuery(_ ref: String) -> [String: String] { ["key": "todos", "ref": ref] }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? UUID().uuidString
        text = c.text("text") ?? ""
        done = c.truthy("done")
        createdAt = c.num("createdAt")
        doneAt = c.one("doneAt")
        source = c.one("source")
        images = c.list("images")
        detail = c.text("detail")
        forUser = c.truthy("forUser")
        agent = c.truthy("agent")
        ref = c.text("ref")
        status = c.text("status")
        progress = c.text("progress")
        handler = c.one("handler")
        updatedAt = c.one("updatedAt")
    }
}

/// 编辑面板里的一张截图：原来就有的（Mac 上的 ref），或刚加的（压过的 JPEG + 小预览）
enum TodoShot: Identifiable {
    case saved(ChatImage)
    case new(ComposeAttachment)

    var id: String {
        switch self {
        case .saved(let image): image.ref
        case .new(let item): item.id.uuidString
        }
    }

    /// 发给 Mac 的样子：留下的给 ref，新加的给 data
    var payload: [String: Any] {
        switch self {
        case .saved(let image): ["ref": image.ref]
        case .new(let item): ["data": item.data.base64EncodedString(), "mime": "image/jpeg"]
        }
    }
}

/// Claude 刚说的、还没决定加不加的一条消息（正在跑的会话里新冒出来的）
struct TodoSuggestion: Decodable, Identifiable, Hashable {
    var key: String
    var itemId: String
    var title: String
    var machine: String?
    var ts: Double?
    var asks: [String]
    var at: Double
    /// agent 提醒时写的说明
    var detail: String?

    var id: String { "\(key)|\(itemId)" }
}

struct TodoState: Decodable {
    var items: [TodoItem] = []
    var suggestions: [TodoSuggestion] = []
    /// 加过 / 忽略过的消息（"key|itemId"）：对话里不再问
    var handled: Set<String> = []
    /// 刚冒出来的那条提示（只在实时事件里有）
    var fresh: TodoSuggestion?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        items = c.list("items")
        suggestions = c.list("suggestions")
        handled = Set(c.list("handled") as [String])
        fresh = c.one("fresh")
    }

    /// 我的未完成待办（角标、首页的数）：agent 的待办它自己会做，不算
    var openCount: Int { items.lazy.filter { !$0.done && !$0.agentTask }.count }

    /// 这条消息里的事加进来了几条
    func added(key: String, itemId: String) -> Int {
        items.lazy.filter { $0.source?.key == key && $0.source?.itemId == itemId }.count
    }

    func isHandled(key: String, itemId: String) -> Bool { handled.contains("\(key)|\(itemId)") }
}

extension AppModel {
    private static let todosCacheKey = "todosCache"

    /// 上次存在手机上的待办：断网、Mac 没开也能翻
    /// 演示模式不读也不存：不然真 Mac 的待办会混进演示里（截图取不到），演示的待办也会留到配对真 Mac 以后
    private var cachesTodos: Bool {
        #if KITELINE_MAC
        true
        #else
        !Demo.active
        #endif
    }

    func loadCachedTodos() {
        if cachesTodos, todos.items.isEmpty, let data = UserDefaults.standard.data(forKey: Self.todosCacheKey),
           let state = try? JSONDecoder().decode(TodoState.self, from: data) {
            todos = state
        }
    }

    func applyTodos(_ data: Data) {
        guard var state = try? JSONDecoder().decode(TodoState.self, from: data) else { return }
        state.fresh = nil
        todos = state
        if cachesTodos { UserDefaults.standard.set(data, forKey: Self.todosCacheKey) }
    }

    func refreshTodos() async {
        guard let data = try? await api.data("/api/todos") else { return }
        applyTodos(data)
    }

    /// 加几条待办；带 key + itemId 就记下出自哪条消息（这条消息算处理过，不再问）；附的截图跟着第一条
    @discardableResult
    func addTodos(_ texts: [String], key: String? = nil, itemId: String? = nil, title: String? = nil, ts: Double? = nil,
                  shots: [TodoShot] = [], detail: String? = nil, forUser: Bool = false, agent: Bool = false) async -> Bool {
        let clean = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return false }
        var body: [String: Any] = ["texts": clean]
        if let detail, !detail.isEmpty { body["detail"] = detail }
        if forUser { body["forUser"] = true }
        if agent { body["agent"] = true }
        if !shots.isEmpty { body["images"] = shots.map(\.payload) }
        if let key, let itemId {
            body["key"] = key
            body["itemId"] = itemId
            body["title"] = title ?? session(key)?.title ?? pastMeta[key]?.title ?? ""
            if let ts { body["ts"] = ts }
        }
        do {
            applyTodos(try await api.postData("/api/todos/add", body: body))
            Haptics.tap()
            flash(clean.count == 1 ? L("已加入待办") : L("已加入待办（%@ 项）", "\(clean.count)"))
            return true
        } catch {
            show(error)
            return false
        }
    }

    func setTodoDone(_ item: TodoItem, _ done: Bool) {
        // 先在手机上打上勾，Mac 回来的整份再换掉
        if let index = todos.items.firstIndex(where: { $0.id == item.id }) {
            todos.items[index].done = done
            todos.items[index].doneAt = done ? Date().timeIntervalSince1970 * 1000 : nil
        }
        if done { Haptics.tap() }
        todoRequest("/api/todos/update", ["id": item.id, "done": done])
    }

    /// 改字、改截图（shots = 改完以后的整组）：等 Mac 存好再关面板，返回成没成
    func editTodo(_ item: TodoItem, text: String, shots: [TodoShot]) async -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        var body: [String: Any] = ["id": item.id, "text": clean]
        let refs = shots.map(\.id)
        if refs != item.images.map(\.ref) { body["images"] = shots.map(\.payload) }
        do {
            applyTodos(try await api.postData("/api/todos/update", body: body))
            return true
        } catch {
            show(error)
            return false
        }
    }

    func deleteTodos(_ ids: [String]) {
        todos.items.removeAll { ids.contains($0.id) }
        todoRequest("/api/todos/delete", ["ids": ids])
    }

    func clearDoneTodos() {
        todos.items.removeAll(where: \.done)
        todoRequest("/api/todos/clear-done", [:])
    }

    /// 这条消息里的不加（对话里、首页上不再问）
    func dismissAsks(key: String, itemId: String) {
        todos.suggestions.removeAll { $0.key == key && $0.itemId == itemId }
        todos.handled.insert("\(key)|\(itemId)")
        todoRequest("/api/todos/dismiss", ["key": key, "itemId": itemId])
    }

    /// 「全部忽略」：现在列着的提示都不加（只报看得见的这几条，刚冒出来的新提示不跟着丢）
    func dismissAllAsks() {
        let shown = todos.suggestions
        guard !shown.isEmpty else { return }
        shown.forEach { todos.handled.insert("\($0.key)|\($0.itemId)") }
        todos.suggestions.removeAll { s in shown.contains { $0.id == s.id } }
        todoRequest("/api/todos/dismiss", ["items": shown.map { ["key": $0.key, "itemId": $0.itemId] }])
    }

    private func todoRequest(_ path: String, _ body: [String: Any]) {
        Task {
            do {
                applyTodos(try await api.postData(path, body: body))
            } catch {
                show(error)
                await refreshTodos()
            }
        }
    }

    /// 跳到出自的那条消息：打开会话（已经结束的也行），滚到那条、闪一下
    func openSource(key: String, itemId: String, open: OpenRoute) {
        jumpRequests[key] = itemId
        open(.chat(key))
    }

    /// agent 提醒你做的事：「加入待办」（说明一起带上，算我的待办）
    func addSuggestion(_ s: TodoSuggestion) async {
        guard let text = s.asks.first else { return }
        await addTodos([text], key: s.key, itemId: s.itemId, title: s.title, ts: s.ts, detail: s.detail, forUser: true, agent: true)
    }

    /// 「现在处理」：不加进待办（这条记为处理过），打开那个会话；处理好后回到会话告诉 agent
    func handleNow(key: String, itemId: String, open: OpenRoute?) {
        dismissAsks(key: key, itemId: itemId)
        Haptics.tap()
        if let open { openSource(key: key, itemId: itemId, open: open) }
    }

    /// 「回到会话」/「已处理好」：打开那个会话，输入框里先写好「已处理好：…」，用户确认后再发（不直接发，防点错）
    func replyDone(key: String, text: String, open: OpenRoute) {
        let draft = L("已处理好：%@", text)
        if (drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { setDraft(key, draft) }
        open(.chat(key))
    }

    /// agent 的待办没人在做了：在处理它（没人接手就是记下它）的会话已经结束。连着电脑、那台机器在线才判断（断线时看不出来，当还在）
    func todoOrphaned(_ item: TodoItem) -> Bool {
        guard connected, item.agentTask, !item.done, let key = item.handler?.key ?? item.source?.key,
              let hash = key.firstIndex(of: "#"), sources.first(where: { $0.id == String(key[..<hash]) })?.online == true else { return false }
        return session(key) == nil
    }

    /// agent 的待办在哪台机器、哪个项目、哪个 agent（分组用）：看在处理它的会话（没人接手就是记下它的），
    /// 电脑端没记的（老电脑端、早先记的）从还在的会话、看过的历史会话里补；都没有就是 nil
    func todoPlace(_ item: TodoItem) -> (sourceId: String, machine: String?, cwd: String?, agent: String?) {
        let key = item.handler?.key ?? item.source?.key ?? ""
        let sourceId = key.firstIndex(of: "#").map { String(key[..<$0]) } ?? ""
        let live = session(key)
        let machine = item.handler?.machine ?? item.source?.machine ?? live?.sourceName ?? sources.first { $0.id == sourceId }?.name
        let cwd = item.handler?.cwd ?? (item.handler == nil ? item.source?.cwd : nil) ?? live?.cwd ?? pastMeta[key]?.cwd ?? item.source?.cwd
        let agent = item.handler?.agent ?? (item.handler == nil ? item.source?.agent : nil) ?? live?.agent ?? item.source?.agent
        return (sourceId, machine, cwd.flatMap { $0.isEmpty ? nil : $0 }, agent)
    }

    /// 待办出自的会话在哪台机器的哪个目录（「创建会话」时选中原项目）
    func todoOrigin(_ item: TodoItem) -> TaskOrigin? {
        guard let key = item.source?.key, let hash = key.firstIndex(of: "#"),
              let cwd = session(key)?.cwd ?? pastMeta[key]?.cwd else { return nil }
        return TaskOrigin(sourceId: String(key[..<hash]), cwd: cwd)
    }

    /// 实时通道送来新的待办（整份）；刚冒出来的提示：没开着那个会话就弹个横幅问一句
    func receiveTodos(_ data: Data) {
        let fresh = (try? JSONDecoder().decode(TodoState.self, from: data))?.fresh
        applyTodos(data)
        guard let fresh, !isOpen(fresh.key) else { return }
        let first = fresh.asks.first.map { String($0.prefix(60)) + ($0.count > 60 ? "…" : "") } ?? ""
        banner = NotifyEvent(title: fresh.title, body: L("需要你处理：%@。现在处理，或加入待办稍后处理。", first),
                             key: fresh.key, kind: "todo", itemId: fresh.itemId)
    }
}
