import Foundation

/// 我的收藏（同微信的收藏）：对话里右键 / 长按一条消息点「收藏」，把那条的文字和图片存一份（会话结束、记录清掉也还在），
/// 各端都能翻、搜、复制，点一条跳回出自的那条消息。存配置目录 favorites.json，图存 favorite-media/；
/// 有变化就经实时通道推 favorites 事件（整份，量不大），各端直接换掉。
///
///   GET  /api/favorites                 全部收藏（新的在前）
///   POST /api/favorites/add             {key, itemId, title?, who: me|bot, speaker?, agent?, ts?, text?, images?:[{data}]}：同一条消息收藏过就不重复加
///   POST /api/favorites/delete          {ids:[…]} 或 {key, itemId}（取消收藏）
///   GET  /api/favorites/media?ref=      收藏里的图
final class Favorites {
    struct Image: Codable {
        var ref: String
        var mime: String
    }

    struct Item: Codable {
        var id: String
        var key: String
        var itemId: String
        /// 收藏时会话叫什么（会话结束、改名后照样显示得出来）
        var title: String
        var machine: String?
        /// 谁说的：me = 我发的，bot = agent 回的
        var who: String
        /// 说话的人显示成什么（「Claude」「Codex」……；我发的由各端显示自己的名字）
        var speaker: String?
        var agent: String?
        /// 那条消息的时间（毫秒）
        var ts: Double?
        /// 收藏的时间（毫秒）
        var at: Double
        var text: String?
        var images: [Image]?
    }

    private struct Store: Codable {
        var items: [Item] = []
    }

    static let shared = Favorites()
    private static let itemLimit = 2000
    private static let imageLimit = 9
    private static let textLimit = 100_000

    private let lock = NSLock()
    private var store = Store()
    private let saveQueue = DispatchQueue(label: "tars.favorites.save")
    private var url: URL { AppConfig.directoryURL.appendingPathComponent("favorites.json") }
    private var mediaDir: URL { AppConfig.directoryURL.appendingPathComponent("favorite-media", isDirectory: true) }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        }
    }

    private static var now: Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    func payload() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["ok": true, "items": store.items.sorted { $0.at > $1.at }.map(Self.itemPayload)]
    }

    /// /api/favorites…（MobileServer 转过来）
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.jsonBody ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/api/favorites"):
            return .json(payload())
        case ("POST", "/api/favorites/add"):
            guard let key = body["key"] as? String, !key.isEmpty, let itemId = body["itemId"] as? String, !itemId.isEmpty else {
                return .error("缺少 key、itemId", status: 400)
            }
            let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = body["images"] as? [[String: Any]] ?? []
            guard (text?.isEmpty == false) || !raw.isEmpty else { return .error("这条消息没有可收藏的内容", status: 400) }
            if exists(key: key, itemId: itemId) { return .json(payload()) }
            guard let images = saveImages(raw) else { return .error("图片过多或无法打开（最多 \(Self.imageLimit) 张）", status: 400) }
            add(Item(id: String(UUID().uuidString.prefix(8)).lowercased(), key: key, itemId: itemId, title: "", machine: nil,
                     who: (body["who"] as? String) == "me" ? "me" : "bot",
                     speaker: (body["speaker"] as? String).map { String($0.prefix(60)) },
                     agent: (body["agent"] as? String).map { String($0.prefix(60)) },
                     ts: (body["ts"] as? Double) ?? (body["ts"] as? Int).map(Double.init), at: Self.now,
                     text: text.map { String($0.prefix(Self.textLimit)) }, images: images.isEmpty ? nil : images),
                title: body["title"] as? String)
            return .json(payload())
        case ("POST", "/api/favorites/delete"):
            let ids = Set(body["ids"] as? [String] ?? (body["id"] as? String).map { [$0] } ?? [])
            let key = body["key"] as? String, itemId = body["itemId"] as? String
            guard !ids.isEmpty || (key != nil && itemId != nil) else { return .error("缺少 id", status: 400) }
            mutate { store in
                let gone = store.items.filter { ids.contains($0.id) || ($0.key == key && $0.itemId == itemId) }
                Self.dropImages(gone, in: self.mediaDir)
                store.items.removeAll { ids.contains($0.id) || ($0.key == key && $0.itemId == itemId) }
            }
            return .json(payload())
        case ("GET", "/api/favorites/media"):
            guard let ref = request.query["ref"], Self.validRef(ref),
                  let data = try? Data(contentsOf: mediaDir.appendingPathComponent(ref)) else { return .error("图片不存在", status: 404) }
            return Thumbnail.reply(data, mime: ref.hasSuffix(".png") ? "image/png" : "image/jpeg", request: request, cacheKey: "favorite|\(ref)")
        default:
            return .error("未知的收藏接口", status: 404)
        }
    }

    // MARK: - 改动

    private func exists(key: String, itemId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store.items.contains { $0.key == key && $0.itemId == itemId }
    }

    private func add(_ item: Item, title: String?) {
        var item = item
        // 会话还在跑：标题、机器取 Mac 这边的；已经结束的用手机传来的标题
        var name = title ?? ""
        if let record = AppState.shared.store.record(withKey: item.key) {
            name = record.snapshot.displayTitle
            item.machine = record.sourceName
        } else if let hash = item.key.firstIndex(of: "#") {
            let sourceId = String(item.key[..<hash])
            item.machine = AppState.shared.config.sources.first { $0.id == sourceId }?.displayName
        }
        item.title = String((name.isEmpty ? "会话" : name).prefix(200))
        mutate { store in
            guard !store.items.contains(where: { $0.key == item.key && $0.itemId == item.itemId }) else { return }
            store.items.append(item)
            if store.items.count > Self.itemLimit {
                // 超了删最早收藏的
                let extra = store.items.count - Self.itemLimit
                let oldest = store.items.sorted { $0.at < $1.at }.prefix(extra).map(\.id)
                Self.dropImages(store.items.filter { oldest.contains($0.id) }, in: self.mediaDir)
                store.items.removeAll { oldest.contains($0.id) }
            }
        }
    }

    /// 消息里的图（base64，各端从 /api/media 取来原图再传过来）存成文件。nil = 太多或打不开
    private func saveImages(_ list: [[String: Any]]) -> [Image]? {
        guard list.count <= Self.imageLimit else { return nil }
        var result: [Image] = []
        for entry in list {
            guard let encoded = entry["data"] as? String, let data = Data(base64Encoded: encoded), data.count > 8, data.count < 15_000_000 else { return nil }
            let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            guard png || data.starts(with: [0xFF, 0xD8]) else { return nil }
            let ref = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() + (png ? ".png" : ".jpg")
            try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            let file = mediaDir.appendingPathComponent(ref)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            result.append(Image(ref: ref, mime: png ? "image/png" : "image/jpeg"))
        }
        return result
    }

    private static func validRef(_ ref: String) -> Bool {
        ref.range(of: "^[a-f0-9]{16}\\.(jpg|png)$", options: .regularExpression) != nil
    }

    private static func dropImages(_ items: [Item], in dir: URL) {
        for image in items.flatMap({ $0.images ?? [] }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(image.ref))
        }
    }

    private func mutate(_ change: (inout Store) -> Void) {
        lock.lock()
        change(&store)
        lock.unlock()
        save()
        DispatchQueue.main.async {
            AppState.shared.mobile.publish(event: "favorites", payload: self.payload())
        }
    }

    private static func itemPayload(_ item: Item) -> [String: Any] {
        var out: [String: Any] = ["id": item.id, "key": item.key, "itemId": item.itemId, "title": item.title, "who": item.who, "at": item.at]
        if let machine = item.machine { out["machine"] = machine }
        if let speaker = item.speaker { out["speaker"] = speaker }
        if let agent = item.agent { out["agent"] = agent }
        if let ts = item.ts { out["ts"] = ts }
        if let text = item.text { out["text"] = text }
        if let images = item.images, !images.isEmpty { out["images"] = images.map { ["ref": $0.ref, "mime": $0.mime] } }
        return out
    }

    private func save() {
        // 快照和写盘在同一个串行队列里，后写的不会被先写的覆盖
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let snapshot = self.store
            self.lock.unlock()
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            try? data.write(to: self.url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        }
    }
}
