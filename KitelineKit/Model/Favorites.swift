import Foundation

// 我的收藏（同微信的收藏；电脑上 Sources/Favorites.swift / 电脑端 records.py 存着，/api/favorites + 实时通道的 favorites 事件）：
// 对话里长按 / 右键一条消息点「收藏」，那条的文字和图片在电脑上存一份；各端都能翻、搜、复制，点一条跳回原消息。
// 存在电脑上、各端连着同一台电脑，所以手机上收藏的电脑上马上看得到（不用账号、不经云端）；手机上另存一份，断网也能翻

struct FavoriteItem: Decodable, Identifiable, Hashable {
    var id: String
    var key: String
    var itemId: String
    /// 收藏时会话叫什么
    var title: String
    var machine: String?
    /// me = 我发的，bot = agent 回的
    var who: String
    /// agent 显示成什么（「Claude」「Codex」……）；我发的显示自己的名字
    var speaker: String?
    var agent: String?
    /// 那条消息的时间（毫秒）
    var ts: Double?
    /// 收藏的时间（毫秒）
    var at: Double
    var text: String?
    /// 收藏时存下来的图（电脑上 /api/favorites/media?ref=）
    var images: [ChatImage]

    /// 图的地址（RemoteImage、看大图用；key 只是让手机上的缓存归到一类）
    static let mediaPath = "/api/favorites/media"
    static func mediaQuery(_ ref: String) -> [String: String] { ["key": "favorites", "ref": ref] }

    var mine: Bool { who == "me" }
    var mark: String { "\(key)|\(itemId)" }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? UUID().uuidString
        key = c.text("key") ?? ""
        itemId = c.text("itemId") ?? ""
        title = c.text("title") ?? ""
        machine = c.text("machine")
        who = c.text("who") ?? "bot"
        speaker = c.text("speaker")
        agent = c.text("agent")
        ts = c.one("ts")
        at = c.num("at")
        text = c.text("text")
        images = c.list("images")
    }
}

struct FavoriteState: Decodable {
    var items: [FavoriteItem] = [] {
        didSet { marks = Set(items.map(\.mark)) }
    }
    /// 收藏过的消息（"key|itemId"）：对话里菜单显示「取消收藏」
    private(set) var marks: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        items = c.list("items")
        marks = Set(items.map(\.mark))
    }

    func contains(key: String, itemId: String) -> Bool { marks.contains("\(key)|\(itemId)") }
}

extension AppModel {
    private static let favoritesCacheKey = "favoritesCache"

    /// 演示模式不读也不存（同待办）
    private var cachesFavorites: Bool {
        #if KITELINE_MAC
        true
        #else
        !Demo.active
        #endif
    }

    /// 上次存在手机上的收藏：断网、电脑没开也能翻
    func loadCachedFavorites() {
        if cachesFavorites, favorites.items.isEmpty, let data = UserDefaults.standard.data(forKey: Self.favoritesCacheKey),
           let state = try? JSONDecoder().decode(FavoriteState.self, from: data) {
            favorites = state
        }
    }

    func applyFavorites(_ data: Data) {
        guard let state = try? JSONDecoder().decode(FavoriteState.self, from: data) else { return }
        favorites = state
        if cachesFavorites { UserDefaults.standard.set(data, forKey: Self.favoritesCacheKey) }
    }

    func refreshFavorites() async {
        guard let data = try? await api.data("/api/favorites") else { return }
        applyFavorites(data)
    }

    /// 收藏一条消息：文字和图都存一份到电脑上（图取原图传过去：会话结束、记录清掉也还在）
    func addFavorite(key: String, item: ChatItem, mine: Bool) {
        guard !favorites.contains(key: key, itemId: item.id) else { return }
        let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let images = item.t == "agent_page" ? [] : item.images ?? []   // 网页（agent_page）只收藏标题和说明
        guard !text.isEmpty || !images.isEmpty else { return }
        Task {
            var body: [String: Any] = ["key": key, "itemId": item.id, "who": mine ? "me" : "bot",
                                       "title": session(key)?.title ?? pastMeta[key]?.title ?? ""]
            if !text.isEmpty { body["text"] = text }
            if let ts = item.ts { body["ts"] = ts }
            if !mine {
                let agent = sessionSlot(key).agent
                body["agent"] = agent
                body["speaker"] = Agents.info(agent).speaker
            }
            if !images.isEmpty {
                var list: [[String: Any]] = []
                for image in images.prefix(9) {
                    guard let data = try? await api.data("/api/media", ["key": key, "ref": image.ref]) else {
                        flash(L("无法获取图片"))
                        return
                    }
                    list.append(["data": data.base64EncodedString()])
                }
                body["images"] = list
            }
            do {
                applyFavorites(try await api.postData("/api/favorites/add", body: body))
                Haptics.tap()
                flash(L("已收藏"))
            } catch {
                show(error)
            }
        }
    }

    /// 取消收藏：对话里按消息取消，收藏页里按条目删
    func removeFavorite(key: String, itemId: String) {
        favorites.items.removeAll { $0.key == key && $0.itemId == itemId }
        favoriteRequest(["key": key, "itemId": itemId])
        flash(L("已取消收藏"))
    }

    func removeFavorites(_ ids: [String]) {
        favorites.items.removeAll { ids.contains($0.id) }
        favoriteRequest(["ids": ids])
    }

    private func favoriteRequest(_ body: [String: Any]) {
        Task {
            do {
                applyFavorites(try await api.postData("/api/favorites/delete", body: body))
            } catch {
                show(error)
                await refreshFavorites()
            }
        }
    }

    /// 消息菜单里的「收藏 / 取消收藏」（有文字或图的消息才有）
    func favoriteAction(key: String, item: ChatItem, mine: Bool) -> MenuAction? {
        guard !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(item.images ?? []).isEmpty else { return nil }
        if favorites.contains(key: key, itemId: item.id) {
            return MenuAction(title: L("取消收藏"), symbol: "star.slash") { self.removeFavorite(key: key, itemId: item.id) }
        }
        return MenuAction(title: L("加入收藏"), symbol: "star") { self.addFavorite(key: key, item: item, mine: mine) }
    }
}
