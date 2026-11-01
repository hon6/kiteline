import Foundation

/// 会话群：用户把几个会话（可以在不同电脑、不同项目里）拉进一个群，它们经 Kiteline 互相发消息协作。
///
/// - 建群：手机 / Mac 上把一个会话拖到另一个上，或右键 / 长按「拉群协作」勾选几个会话。
/// - 发言：agent 用 watcher 的 `group say`（写进这个会话的发图通道，对话里是 t=group_say），Kiteline 转给群里其他会话：
///   正在跑的直接投递（同手机发消息，Delivery）；已经关了的先记着，用户在群里发消息时恢复它（NewSession，同「历史会话 → 恢复」），
///   连同它没看到的群消息一起送进去。用户在群里发的话发给全部成员。
/// - 第一次给某个成员投递时带上群说明（成员是谁、在哪台电脑哪个项目、怎么发言）；群名先拿成员标题凑一个，
///   说明里请第一个发言的 agent 用 `--name` 按协作的事起正式群名（用户自己改过就不再换）。
/// - 成员全都关了 = 历史群（各端算，按会话在不在列表里）。agent 之间连着往来太多条（用户没插话）自动暂停转发，等用户点继续。
///
/// 存配置目录 groups.json；有变化经实时通道推 groups（各群概要）、group_msg（一条新消息或投递状态变了），
/// 也推给各台电脑的 watcher（group 子命令核对成员、看最近的群消息）。
///
///   GET  /api/groups                     各群概要（成员、最后一条、条数）
///   GET  /api/groups/messages?id=        某个群的全部消息
///   POST /api/groups/create              {keys:[…], topic?}：topic 非空时作为第一条群消息发给全部成员
///   POST /api/groups/add                 {id, keys:[…]}
///   POST /api/groups/remove              {id, key}
///   POST /api/groups/rename              {id, name}
///   POST /api/groups/send                {id, text, to?:[key], images?:[{name, data}], files?:[{name, data}]}：用户在群里发言（关了的成员先恢复）；
///                                        图、文件存配置目录 group-media/<群 id>/，投递时传到各成员所在的电脑（同手机给会话发图）
///   GET  /api/groups/media?id=&ref=      群消息里的图（带 variant 时给方形缩略图）、文件
///   POST /api/groups/pause               {id, paused}
///   POST /api/groups/delete              {id}（解散）
final class Groups {
    struct Member: Codable {
        var key: String
        var title: String
        var machine: String?
        var project: String?
        var cwd: String?
        var agent: String?
        var joinedAt: Double
        /// 群说明送到了没有：没送到的下一次投递时带上
        var briefed: Bool?
    }

    struct Message: Codable {
        var id: String
        var ts: Double
        /// 成员 key；me = 用户；system = 群里的提示（谁加入了、改了群名、暂停了转发）
        var from: String
        var fromTitle: String
        var text: String
        /// 只发给这几个成员（nil = 除了发的人全部）
        var to: [String]?
        /// 各收件成员的投递状态：pending 排队 / sent 已送达 / filled 已填入未提交 / ended 会话已关闭（恢复时补上）/ paused 转发暂停 / failed
        var states: [String: String]?
        var notes: [String: String]?
        /// 消息出自那个会话对话里的哪一条（agent 发的：跳回原消息用）
        var itemId: String?
        /// 群提示是哪一种（created 建群 / joined 加入 / left 移出 / renamed 用户改名 / named agent 起名 / paused / resumed / autopaused）
        /// 和要填进去的名字：各端按自己的界面语言拼句子；text 是拼好的中文（watcher、老客户端用）
        var event: String?
        var args: [String]?
        /// 用户随消息发的图、文件（存在这台电脑上，ref 是文件名）
        var images: [Media]?
        var files: [Media]?
    }

    struct Media: Codable {
        var ref: String
        var name: String
        var size: Int
    }

    struct Group: Codable {
        var id: String
        var name: String
        /// 群名还是临时凑的：第一个用 --name 的 agent 起正式名字；用户改过就是 false
        var autoName: Bool
        var topic: String?
        var createdAt: Double
        var updatedAt: Double
        var members: [Member]
        var messages: [Message]
        var paused: Bool?
        /// 用户上次发言以来 agent 之间往来了几条（太多就暂停转发）
        var streak: Int?
        /// 标记（列表里排最上面、群名前一颗星）、免打扰（agent 发言不推送；转发自动暂停这种要你决定的照推）：同会话
        var marked: Bool?
        var muted: Bool?
    }

    private struct Store: Codable {
        var groups: [Group] = []
    }

    static let shared = Groups()
    private static let groupLimit = 200
    private static let messageLimit = 500
    private static let textLimit = 8000
    /// 一条群消息最多带几张图 / 几个文件（同手机给会话发：6 张；文件一个最多 25 MB）
    private static let mediaLimit = 6
    private static let fileSizeLimit = 25 * 1024 * 1024
    /// 用户不插话时 agent 之间最多连着转发几条
    private static let streakLimit = 30
    /// 等确认的会话最多等多久再投（之后算投递失败）
    private static let waitLimit: TimeInterval = 15 * 60
    /// agent 在群里发言的推送：同一个群隔这么久才再推一条（往来密的时候不刷屏）
    private static let pushGap: TimeInterval = 120

    /// 只在主线程上读写
    private var store = Store()
    private let saveQueue = DispatchQueue(label: "tars.groups.save")
    private var url: URL { AppConfig.directoryURL.appendingPathComponent("groups.json") }
    private func mediaDir(_ id: String) -> URL {
        AppConfig.directoryURL.appendingPathComponent("group-media", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
    /// 各台电脑上 agent 调 watcher 的写法（hello 带来）：写进群说明里
    private var commands: [String: String] = [:]
    /// 排队要投的：(群, 消息, 收件成员, 进队时间)。一次投一条（投递要占前台、按键），投完再下一条
    private var queue: [(group: String, message: String, key: String, since: Date)] = []
    private var delivering = false
    /// 上次推给 watcher 的那份（没变不重推）、群成员里上次在跑的（变了要重推）
    private var pushedAgents: Data?
    private var liveMembers: Set<String> = []
    /// 各群上次推送的时间
    private var lastPush: [String: Date] = [:]

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        }
        // 上次退出时没投完的：会话还在就接着投（启动时会话列表还没来，等第一次快照）
        for group in store.groups {
            for message in group.messages {
                for (key, state) in message.states ?? [:] where state == "pending" {
                    queue.append((group.id, message.id, key, Date()))
                }
            }
        }
    }

    private static var now: Double { (Date().timeIntervalSince1970 * 1000).rounded() }
    private static func newId(_ prefix: String) -> String { prefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased() }

    // MARK: - 接口

    /// /api/groups…（MobileServer 转过来；回调可能稍后才来：发言要等投递）
    func handle(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        DispatchQueue.main.async { self.route(request, respond: respond) }
    }

    private func route(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let body = request.jsonBody ?? [:]
        // 取群里的图也认 key=@group:<群 id>（各端取图的写法同对话里的图 /api/media?key=&ref=）
        let id = body["id"] as? String ?? request.query["id"] ?? request.query["key"].flatMap { $0.hasPrefix("@group:") ? String($0.dropFirst(7)) : nil } ?? ""
        switch (request.method, request.path) {
        case ("GET", "/api/groups"):
            respond(.json(summaryPayload()))
        case ("GET", "/api/groups/messages"):
            guard let group = group(id) else { respond(.error("会话群不存在", status: 404)); return }
            respond(.json(["ok": true, "id": group.id, "items": group.messages.map(Self.messagePayload)]))
        case ("GET", "/api/groups/media"):
            let ref = request.query["ref"] ?? ""
            guard group(id) != nil, Self.validRef(ref), let data = try? Data(contentsOf: mediaDir(id).appendingPathComponent(ref)) else {
                respond(.error("文件不存在", status: 404)); return
            }
            let mime = Self.mime(ref)
            if mime.hasPrefix("image/") {
                respond(Thumbnail.reply(data, mime: mime, request: request, cacheKey: "group|\(id)|\(ref)"))
            } else {
                respond(HTTPResponse(status: 200, headers: ["Content-Type": mime, "X-Content-Type-Options": "nosniff", "Cache-Control": "private, max-age=31536000, immutable",
                                                            "Content-Security-Policy": "sandbox; default-src 'none'"], body: data))
            }
        case ("POST", "/api/groups/create"):
            let keys = Self.keys(body["keys"])
            guard keys.count >= 2 else { respond(.error("至少选两个会话", status: 400)); return }
            let topic = (body["topic"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let group = create(keys: keys, topic: topic)
            respond(.json(["ok": true, "group": summary(group)]))
        case ("POST", "/api/groups/add"):
            guard group(id) != nil else { respond(.error("会话群不存在", status: 404)); return }
            let keys = Self.keys(body["keys"])
            guard !keys.isEmpty else { respond(.error("没有选会话", status: 400)); return }
            add(keys, to: id)
            respond(.json(["ok": true, "group": group(id).map(summary) ?? [:]]))
        case ("POST", "/api/groups/remove"):
            guard let key = body["key"] as? String, group(id) != nil else { respond(.error("会话群不存在", status: 404)); return }
            remove(key, from: id)
            respond(.json(["ok": true, "group": group(id).map(summary) as Any? ?? NSNull()]))
        case ("POST", "/api/groups/rename"):
            let name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { respond(.error("群名不能为空", status: 400)); return }
            guard group(id) != nil else { respond(.error("会话群不存在", status: 404)); return }
            rename(id, to: String(name.prefix(40)))
            respond(.json(["ok": true, "group": group(id).map(summary) ?? [:]]))
        case ("POST", "/api/groups/pause"):
            guard group(id) != nil else { respond(.error("会话群不存在", status: 404)); return }
            setPaused(id, body["paused"] as? Bool ?? true)
            respond(.json(["ok": true, "group": group(id).map(summary) ?? [:]]))
        case ("POST", "/api/groups/mark"), ("POST", "/api/groups/mute"):
            guard var group = group(id) else { respond(.error("会话群不存在", status: 404)); return }
            if request.path.hasSuffix("/mark") { group.marked = body["marked"] as? Bool ?? true } else { group.muted = body["muted"] as? Bool ?? true }
            replace(group, changed: nil)
            respond(.json(["ok": true, "group": summary(group)]))
        case ("POST", "/api/groups/delete"):
            mutate { $0.groups.removeAll { $0.id == id } }
            queue.removeAll { $0.group == id }
            try? FileManager.default.removeItem(at: mediaDir(id))
            respond(.json(summaryPayload()))
        case ("POST", "/api/groups/send"):
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard group(id) != nil else { respond(.error("会话群不存在", status: 404)); return }
            let attachments = MobileServer.attachments(in: body)
            guard !text.isEmpty || !attachments.isEmpty else { respond(.error("内容为空", status: 400)); return }
            guard attachments.filter({ !$0.file }).count <= Self.mediaLimit, attachments.filter(\.file).count <= Self.mediaLimit else {
                respond(.error("一次最多发送 \(Self.mediaLimit) 张图片、\(Self.mediaLimit) 个文件", status: 400)); return
            }
            if let big = attachments.first(where: { $0.data.count > Self.fileSizeLimit }) {
                respond(.error("「\(big.name)」超过 25 MB，无法发送", status: 400)); return
            }
            guard let saved = store(attachments, in: id) else { respond(.error("图片或文件保存失败", status: 500)); return }
            let to = Self.keys(body["to"])
            let message = userSays(text: String(text.prefix(Self.textLimit)), in: id, to: to.isEmpty ? nil : to,
                                   images: saved.filter { !$0.file }.map(\.media), files: saved.filter(\.file).map(\.media))
            respond(.json(["ok": true, "message": Self.messagePayload(message)]))
        default:
            respond(.error("未知的会话群接口", status: 404))
        }
    }

    /// 随群消息发来的图、文件存进这个群的目录：名字换成随机的（保留扩展名），原名记在消息里。nil = 写不进去
    private func store(_ attachments: [Delivery.Attachment], in id: String) -> [(media: Media, file: Bool)]? {
        guard !attachments.isEmpty else { return [] }
        let dir = mediaDir(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var saved: [(media: Media, file: Bool)] = []
        for item in attachments {
            let ext = (item.name as NSString).pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
            let ref = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() + (ext.isEmpty ? "" : "." + ext)
            let file = dir.appendingPathComponent(ref)
            guard (try? item.data.write(to: file, options: .atomic)) != nil else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let name = (item.name as NSString).lastPathComponent
            saved.append((Media(ref: ref, name: String((name.isEmpty ? ref : name).prefix(120)), size: item.data.count), item.file))
        }
        return saved
    }

    private static func validRef(_ ref: String) -> Bool {
        ref.range(of: "^[a-f0-9]{16}(\\.[a-z0-9]{1,8})?$", options: .regularExpression) != nil
    }

    private static func mime(_ ref: String) -> String {
        switch (ref as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "txt", "md", "log", "csv": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    /// 投递时随群消息带上的图、文件（读回存着的数据；读不到的跳过）
    private func attachments(_ messages: [Message], in id: String) -> [Delivery.Attachment] {
        let dir = mediaDir(id)
        return messages.flatMap { message in
            (message.images ?? []).map { ($0, false) } + (message.files ?? []).map { ($0, true) }
        }.compactMap { media, file in
            (try? Data(contentsOf: dir.appendingPathComponent(media.ref))).map { Delivery.Attachment(name: media.name, data: $0, file: file) }
        }
    }

    /// 超过条数上限删掉的旧消息：它们的图、文件也删掉
    private func dropMedia(_ messages: [Message], in id: String) {
        let dir = mediaDir(id)
        for media in messages.flatMap({ ($0.images ?? []) + ($0.files ?? []) }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(media.ref))
        }
    }

    private static func keys(_ raw: Any?) -> [String] {
        var seen = Set<String>()
        return (raw as? [String] ?? []).filter { $0.contains("#") && seen.insert($0).inserted }
    }

    // MARK: - 建群、加人、改名

    private func create(keys: [String], topic: String) -> Group {
        let members = keys.map(member)
        let at = Self.now
        var group = Group(id: Self.newId("g-"), name: Self.provisionalName(members: members, topic: topic), autoName: true,
                          topic: topic.isEmpty ? nil : String(topic.prefix(2000)), createdAt: at, updatedAt: at, members: members, messages: [])
        group.messages.append(event("建群：" + members.map(\.title).joined(separator: "、"), "created", members.map(\.title)))
        mutate { store in
            store.groups.append(group)
            if store.groups.count > Self.groupLimit {
                store.groups = Array(store.groups.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.groupLimit))
            }
        }
        Log.write("会话群「\(group.name)」：\(members.map { "\($0.title)（\($0.machine ?? "?")）" }.joined(separator: "、"))")
        fillEnded(group.id)
        // 用户写了要协作的事：作为第一条群消息发给全部成员（群说明一起带上）；没写的等第一条群消息来了再带说明，不打扰正在干活的会话
        if !topic.isEmpty { _ = userSays(text: topic, in: group.id, to: nil) }
        return self.group(group.id) ?? group
    }

    private func add(_ keys: [String], to id: String) {
        guard var group = group(id) else { return }
        let fresh = keys.filter { key in !group.members.contains { $0.key == key } }.map(member)
        guard !fresh.isEmpty else { return }
        group.members += fresh
        group.messages.append(event("加入群：" + fresh.map(\.title).joined(separator: "、"), "joined", fresh.map(\.title)))
        group.updatedAt = Self.now
        replace(group)
        fillEnded(id)
    }

    /// 拉进来时已经关了的会话：Mac 这边没有它的标题、目录，去它那台电脑上查（历史会话里的那份）
    private func fillEnded(_ id: String) {
        guard let group = group(id) else { return }
        for member in group.members where member.cwd == nil && AppState.shared.store.record(withKey: member.key) == nil {
            let parts = member.key.split(separator: "#", maxSplits: 1).map(String.init)
            guard parts.count == 2, let connection = AppState.shared.source(withId: parts[0]), connection.state.isLive else { continue }
            connection.request(["cmd": "session_info", "sessionId": parts[1]], timeout: 20) { result in
                guard case .success(let response) = result, let meta = response["session"] as? [String: Any] else { return }
                DispatchQueue.main.async {
                    guard var group = self.group(id), let index = group.members.firstIndex(where: { $0.key == member.key }) else { return }
                    if let title = meta["title"] as? String, !title.isEmpty { group.members[index].title = String(title.prefix(80)) }
                    if let cwd = meta["cwd"] as? String, !cwd.isEmpty {
                        group.members[index].cwd = cwd
                        group.members[index].project = (cwd as NSString).lastPathComponent
                    }
                    self.replace(group, changed: nil)
                }
            }
        }
    }

    private func remove(_ key: String, from id: String) {
        guard var group = group(id), let member = group.members.first(where: { $0.key == key }) else { return }
        group.members.removeAll { $0.key == key }
        group.messages.append(event("移出群：\(member.title)", "left", [member.title]))
        group.updatedAt = Self.now
        queue.removeAll { $0.group == id && $0.key == key }
        replace(group)
    }

    private func rename(_ id: String, to name: String) {
        guard var group = group(id), group.name != name else { return }
        group.name = name
        group.autoName = false
        group.messages.append(event("群名改为「\(name)」", "renamed", [name]))
        group.updatedAt = Self.now
        replace(group)
    }

    private func setPaused(_ id: String, _ paused: Bool) {
        guard var group = group(id), (group.paused ?? false) != paused else { return }
        group.paused = paused
        if !paused {
            group.streak = 0
            // 暂停时记下没转的：现在接着投
            for index in group.messages.indices {
                for (key, state) in group.messages[index].states ?? [:] where state == "paused" {
                    group.messages[index].states?[key] = "pending"
                    queue.append((group.id, group.messages[index].id, key, Date()))
                }
            }
        }
        group.messages.append(paused ? event("已暂停转发", "paused") : event("已继续转发", "resumed"))
        replace(group)
        pump()
    }

    /// 会话 → 成员（标题、电脑、项目记一份：会话关了也认得出）
    private func member(_ key: String) -> Member {
        let record = AppState.shared.store.record(withKey: key)
        let sourceId = String(key.split(separator: "#").first ?? "")
        let machine = record?.sourceName ?? AppState.shared.config.sources.first { $0.id == sourceId }?.displayName
        let cwd = record?.snapshot.cwd
        return Member(key: key, title: String((record?.snapshot.displayTitle ?? "会话").prefix(80)), machine: machine,
                      project: cwd.map { ($0 as NSString).lastPathComponent }, cwd: cwd, agent: record?.snapshot.agentID,
                      joinedAt: Self.now, briefed: false)
    }

    /// 临时群名：写了要协作的事就取它的第一句，否则拿成员标题凑（各取前几个字）
    private static func provisionalName(members: [Member], topic: String) -> String {
        let first = topic.components(separatedBy: CharacterSet(charactersIn: "\n。！？!?；;，,")).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if !first.isEmpty { return first.count > 14 ? String(first.prefix(14)) + "…" : first }
        return members.prefix(3).map { $0.title.count > 8 ? String($0.title.prefix(8)) + "…" : $0.title }.joined(separator: "、")
    }

    private func event(_ text: String, _ code: String? = nil, _ args: [String] = []) -> Message {
        Message(id: Self.newId("m-"), ts: Self.now, from: "system", fromTitle: "", text: text, event: code, args: args.isEmpty ? nil : args)
    }

    // MARK: - 发言

    /// 用户在群里说话：发给全部成员（或指定的几个）；关了的成员先恢复
    private func userSays(text: String, in id: String, to: [String]?, images: [Media] = [], files: [Media] = []) -> Message {
        // 用户发话了：暂停期间攒下的先放出去（排在这句前面）
        if group(id)?.paused == true { setPaused(id, false) }
        guard var group = group(id) else { return event(text) }
        group.streak = 0
        // 群名还是凑的：拿用户第一句话里的事先顶上（agent 起了正式名字再换）
        if group.autoName, !text.isEmpty, !group.messages.contains(where: { $0.from == "me" }) {
            group.name = Self.provisionalName(members: group.members, topic: text)
        }
        var message = Message(id: Self.newId("m-"), ts: Self.now, from: "me", fromTitle: "用户", text: text, to: to)
        message.images = images.isEmpty ? nil : images
        message.files = files.isEmpty ? nil : files
        let targets = group.members.filter { to == nil || to!.contains($0.key) }
        message.states = Dictionary(uniqueKeysWithValues: targets.map { ($0.key, "pending") })
        group.messages.append(message)
        group.updatedAt = message.ts
        replace(group)
        var ended: [Member] = []
        for target in targets {
            if AppState.shared.store.record(withKey: target.key) != nil {
                queue.append((group.id, message.id, target.key, Date()))
            } else {
                ended.append(target)
            }
        }
        pump()
        // 关了的成员：在原来的项目窗口里恢复这段对话，把没看到的群消息和这句话一起送进去（一个一个来：都要开 VS Code 标签）
        resume(ended, group: group.id, upTo: message.id)
        return message
    }

    /// agent 经 group say 发来的（对话里 t=group_say 的那一条）
    func agentSaid(key: String, item: [String: Any]) {
        guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let itemId = item["id"] as? String
        let wanted = item["group"] as? String ?? ""
        let mine = store.groups.filter { $0.members.contains { $0.key == key } }
        guard var group = mine.first(where: { $0.id == wanted || (!wanted.isEmpty && $0.name == wanted) })
                ?? mine.max(by: { $0.updatedAt < $1.updatedAt }) else {
            Log.write("会话群：\(key) 发了群消息，但它不在任何群里，忽略")
            return
        }
        // 同一条（重连后 watcher 又吐了一遍）不重复转
        if let itemId, group.messages.contains(where: { $0.from == key && $0.itemId == itemId }) { return }
        let sender = group.members.first { $0.key == key }
        let title = AppState.shared.store.record(withKey: key)?.snapshot.displayTitle ?? sender?.title ?? "会话"
        if let index = group.members.firstIndex(where: { $0.key == key }) {
            group.members[index].title = String(title.prefix(80))
            group.members[index].briefed = true   // 它会发群消息，说明已经看过了
        }
        if group.autoName, let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            group.name = String(name.prefix(40))
            group.autoName = false
            group.messages.append(event("\(title) 给群起名「\(group.name)」", "named", [title, group.name]))
        }
        let to = resolve(item["to"] as? [String] ?? [], in: group, sender: key)
        var message = Message(id: Self.newId("m-"), ts: Self.now, from: key, fromTitle: title, text: String(text.prefix(Self.textLimit)),
                              to: to.isEmpty ? nil : to, itemId: itemId)
        let targets = group.members.filter { $0.key != key && (to.isEmpty || to.contains($0.key)) }
        group.streak = (group.streak ?? 0) + 1
        if group.paused != true, (group.streak ?? 0) > Self.streakLimit {
            group.paused = true
            group.messages.append(event("agent 之间已连续往来 \(Self.streakLimit) 条，已暂停转发；轻点「继续转发」接着投递", "autopaused", ["\(Self.streakLimit)"]))
            AppState.shared.mobile.notifyRoute(kind: "group", title: group.name, body: "agent 之间往来较多，已暂停转发，请确认是否继续", route: "group:" + group.id, key: key)
        } else if group.muted != true, group.paused != true, Date().timeIntervalSince(lastPush[group.id] ?? .distantPast) > Self.pushGap {
            // 同微信群：有人说话推一条（免打扰的群不推；同一个群两分钟内只推一条）
            lastPush[group.id] = Date()
            let line = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            AppState.shared.mobile.notifyRoute(kind: "group", title: group.name, body: "\(title)：\(line)", route: "group:" + group.id, key: key)
        }
        var states: [String: String] = [:]
        for target in targets {
            if group.paused == true {
                states[target.key] = "paused"
            } else if AppState.shared.store.record(withKey: target.key) != nil {
                states[target.key] = "pending"
                queue.append((group.id, message.id, target.key, Date()))
            } else {
                states[target.key] = "ended"
            }
        }
        message.states = states
        group.messages.append(message)
        group.updatedAt = message.ts
        replace(group)
        Log.write("会话群「\(group.name)」：\(title) → \(targets.map(\.title).joined(separator: "、"))：\(text.prefix(60))")
        pump()
    }

    /// --to 写的：成员 key（watcher 核对过的）或名字（老 watcher 没拿到成员表时原样带来）
    private func resolve(_ names: [String], in group: Group, sender: String) -> [String] {
        let others = group.members.filter { $0.key != sender }
        return names.compactMap { name in
            if others.contains(where: { $0.key == name }) { return name }
            let low = name.lowercased()
            let hits = others.filter { $0.title.lowercased().contains(low) || $0.project?.lowercased() == low || $0.machine?.lowercased() == low }
            return hits.count == 1 ? hits[0].key : nil
        }
    }

    // MARK: - 投递

    /// 排队的一条一条投：会话在等你确认时先不投（回车会替你点允许），过会儿再试
    private func pump() {
        guard !delivering, !queue.isEmpty else { return }
        let now = Date()
        guard let index = queue.firstIndex(where: { job in
            guard let record = AppState.shared.store.record(withKey: job.key) else { return true }
            return Delivery.waitingProblem(record) == nil || now.timeIntervalSince(job.since) > Self.waitLimit
        }) else {
            // 收件的会话都在等确认：过几秒再看
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.pump() }
            return
        }
        let job = queue.remove(at: index)
        guard let group = group(job.group), group.messages.contains(where: { $0.id == job.message }),
              let member = group.members.first(where: { $0.key == job.key }) else { pump(); return }
        guard let record = AppState.shared.store.record(withKey: job.key) else {
            setState(job.group, job.message, job.key, "ended")
            pump(); return
        }
        if Delivery.waitingProblem(record) != nil {
            setState(job.group, job.message, job.key, "failed", note: "会话一直在等你确认，未能投递")
            pump(); return
        }
        // 这次要送的：没看过的群说明、会话关着时错过的群消息、这一条
        let backlog = group.messages.filter { $0.id != job.message && $0.states?[job.key] == "ended" }
        let batch = backlog + group.messages.filter { $0.id == job.message }
        let text = compose(batch, for: member, in: group)
        let media = attachments(batch, in: group.id)
        if Delivery.dryRun { Log.write("[dry-run] 群消息全文 → \(member.title)：\(text)\(media.isEmpty ? "" : "（附 \(media.count) 个图片或文件）")") }
        delivering = true
        Delivery.send(text: text, attachments: media, to: record, source: AppState.shared.source(withId: record.sourceId), submit: true) { outcome in
            DispatchQueue.main.async {
                self.delivering = false
                let state = outcome.ok ? (outcome.submitted ? "sent" : "filled") : "failed"
                for message in batch { self.setState(job.group, message.id, job.key, state, note: outcome.ok ? nil : outcome.message) }
                if outcome.ok { self.markBriefed(job.group, job.key) }
                if !outcome.ok { Log.write("会话群「\(group.name)」投递给 \(member.title) 失败：\(outcome.message)") }
                self.pump()
            }
        }
    }

    /// 恢复关了的成员（一个一个来）：在它项目的 VS Code 窗口里接着这段对话，送进没看到的群消息
    private func resume(_ members: [Member], group id: String, upTo messageId: String) {
        guard let first = members.first else { return }
        let rest = Array(members.dropFirst())
        let next = { DispatchQueue.main.async { self.resume(rest, group: id, upTo: messageId) } }
        guard let group = group(id), let member = group.members.first(where: { $0.key == first.key }) else { next(); return }
        let parts = first.key.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, let source = AppState.shared.config.sources.first(where: { $0.id == parts[0] }),
              let connection = AppState.shared.source(withId: parts[0]), connection.state.isLive else {
            setState(id, messageId, first.key, "ended", note: "会话所在的电脑未连接，暂时无法恢复")
            next(); return
        }
        guard (member.agent ?? "claude-code") == "claude-code" else {
            setState(id, messageId, first.key, "ended", note: "这类会话无法从 Kiteline 恢复，请在它的 agent 中打开")
            next(); return
        }
        let backlog = group.messages.filter { $0.states?[first.key] == "ended" || $0.id == messageId }
        let text = compose(backlog, for: member, in: group)
        let media = attachments(backlog, in: id)
        if Delivery.dryRun { Log.write("[dry-run] 群消息全文 → \(member.title)（恢复）：\(text)\(media.isEmpty ? "" : "（附 \(media.count) 个图片或文件）")") }
        let start: (String, String) -> Void = { cwd, prompt in
            NewSession.start(source: source, cwd: cwd, prompt: prompt, submit: true, sessionId: parts[1]) { outcome in
                DispatchQueue.main.async {
                    let state = outcome.ok ? (outcome.submitted ? "sent" : "filled") : "ended"
                    for message in backlog { self.setState(id, message.id, first.key, state, note: outcome.ok ? nil : outcome.message) }
                    if outcome.ok { self.markBriefed(id, first.key) }
                    next()
                }
            }
        }
        let launch: (String) -> Void = { cwd in
            for message in backlog { self.setState(id, message.id, first.key, "pending", note: "正在恢复会话") }
            Log.write("会话群「\(group.name)」：恢复 \(member.title)（\(source.displayName):\(cwd)）")
            guard !media.isEmpty else { start(cwd, text); return }
            // 图、文件先传到它所在的电脑，路径写在送进去的那段末尾（同给会话发图）
            Delivery.stage(media, via: connection) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let paths): start(cwd, Delivery.compose(text: text, paths: paths, attachments: media))
                    case .failure(let error):
                        for message in backlog { self.setState(id, message.id, first.key, "failed", note: "图片或文件传输到会话所在机器失败：\(error)") }
                        next()
                    }
                }
            }
        }
        if let cwd = member.cwd, cwd.hasPrefix("/") { launch(cwd); return }
        connection.request(["cmd": "session_info", "sessionId": parts[1]], timeout: 20) { result in
            guard case .success(let response) = result, let cwd = (response["session"] as? [String: Any])?["cwd"] as? String, cwd.hasPrefix("/") else {
                self.setState(id, messageId, first.key, "ended", note: "未找到该会话的工作目录")
                next(); return
            }
            launch(cwd)
        }
    }

    /// 送进会话的文字：没看过群说明的先带上说明，再是群消息（几条的话按先后），最后一行怎么回
    private func compose(_ messages: [Message], for member: Member, in group: Group) -> String {
        let command = commands[String(member.key.split(separator: "#").first ?? "")] ?? "python3 ~/.ccpulse/ccpulse-watch.py"
        var lines: [String] = []
        if member.briefed != true {
            lines.append("【Kiteline 会话群「\(group.name)」】用户把这个会话和下面几个会话拉进了一个群，大家可能在不同电脑、不同项目里，经 Kiteline 互相发消息协作：")
            for other in group.members {
                lines.append("· \(other.key == member.key ? "你：" : "")\(Self.label(other))")
            }
            lines.append("发群消息（成员会收到，用户在群里也看得到）：\(command) group say \"内容\"；只发给某一个加 --to 名字；看成员和最近的群消息：\(command) group info。")
            lines.append("需要对方知道或配合的事（进度、结果、请求、回答对方的问题）再发，不用客套回复；用户在群里说的话也用 group say 回复。")
            if group.autoName {
                lines.append("这个群还没有正式名字：你第一次发群消息时加上 --name \"群名\"（概括这次协作的事，12 个字以内）。")
            }
            lines.append("")
        }
        for message in messages {
            let who: String
            switch message.from {
            case "me": who = "用户"
            case "system": who = "群提示"
            default: who = group.members.first { $0.key == message.from }.map(Self.label) ?? message.fromTitle
            }
            lines.append("【群「\(group.name)」· \(who)】\(message.to != nil ? "（只发给你）" : "")")
            if !message.text.isEmpty { lines.append(message.text) }
            let media = (message.images ?? []).count, files = (message.files ?? []).map(\.name)
            if media > 0 || !files.isEmpty {
                lines.append("（" + [media > 0 ? "附图 \(media) 张" : nil, files.isEmpty ? nil : "附件 " + files.joined(separator: "、")]
                    .compactMap { $0 }.joined(separator: "，") + "，路径在本条消息末尾）")
            }
        }
        if member.briefed == true {
            lines.append("（回复群里：\(command) group say \"内容\"；不需要回复就不用回）")
        }
        return lines.joined(separator: "\n")
    }

    private static func label(_ member: Member) -> String {
        let where_ = [member.machine, member.project].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return where_.isEmpty ? member.title : "\(member.title)（\(where_)）"
    }

    private func setState(_ groupId: String, _ messageId: String, _ key: String, _ state: String, note: String? = nil) {
        guard var group = group(groupId), let index = group.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var message = group.messages[index]
        guard message.states?[key] != state || message.notes?[key] != note else { return }
        message.states = (message.states ?? [:]).merging([key: state]) { $1 }
        var notes = message.notes ?? [:]
        notes[key] = note
        message.notes = notes.isEmpty ? nil : notes
        group.messages[index] = message
        replace(group, changed: message)
    }

    private func markBriefed(_ groupId: String, _ key: String) {
        guard var group = group(groupId), let index = group.members.firstIndex(where: { $0.key == key }), group.members[index].briefed != true else { return }
        group.members[index].briefed = true
        replace(group, quiet: true)
    }

    // MARK: - 外面来的事

    /// watcher 的 hello：记下这台电脑上 agent 调 watcher 的写法
    func noteHello(sourceId: String, raw: [String: Any]) {
        if let command = raw["selfCommand"] as? String, !command.isEmpty {
            DispatchQueue.main.async { self.commands[sourceId] = command }
        }
    }

    /// 会话列表变了：群成员开了、关了要告诉 watcher（group info 里写着谁在跑）；排着的投递有了会话就接着投，
    /// 成员会话关了的改成「恢复时补上」；还在跑的成员更新标题
    func sessionsChanged() {
        let live = Set(store.groups.flatMap(\.members).map(\.key).filter { AppState.shared.store.record(withKey: $0) != nil })
        guard live != liveMembers else { return }
        let ended = liveMembers.subtracting(live)
        liveMembers = live
        for job in queue where ended.contains(job.key) { setState(job.group, job.message, job.key, "ended") }
        queue.removeAll { ended.contains($0.key) }
        for index in store.groups.indices {
            for m in store.groups[index].members.indices {
                if let record = AppState.shared.store.record(withKey: store.groups[index].members[m].key) {
                    store.groups[index].members[m].title = String(record.snapshot.displayTitle.prefix(80))
                    if !record.snapshot.cwd.isEmpty { store.groups[index].members[m].cwd = record.snapshot.cwd }
                }
            }
        }
        save()
        publishSummary()
        pushToAgents()
        pump()
    }

    /// 群名单变了马上推（agent 收到群说明就可能发言，名单不到 watcher 会当它不在群里）；内容没变不重推。来源刚连上给它一份
    func pushToAgents(only source: SourceConnection? = nil) {
        DispatchQueue.main.async {
            let items = self.agentSnapshot()
            if let source {
                source.request(["cmd": "groups", "items": items], timeout: 20) { _ in }
                return
            }
            let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
            guard data != self.pushedAgents else { return }
            self.pushedAgents = data
            for target in AppState.shared.liveSources {
                target.request(["cmd": "groups", "items": items], timeout: 20) { _ in }
            }
        }
    }

    /// 推给 watcher 的：成员（会话 id、标题、电脑、项目、在不在跑）和最近 8 条群消息（每条截短）
    private func agentSnapshot() -> [[String: Any]] {
        store.groups.map { group in
            var row: [String: Any] = ["id": group.id, "name": group.name, "autoName": group.autoName, "paused": group.paused ?? false]
            if let topic = group.topic { row["topic"] = String(topic.prefix(500)) }
            row["members"] = group.members.map { member -> [String: Any] in
                ["key": member.key, "sessionId": String(member.key.split(separator: "#", maxSplits: 1).last ?? ""), "title": member.title,
                 "machine": member.machine ?? "", "project": member.project ?? "", "live": AppState.shared.store.record(withKey: member.key) != nil]
            }
            row["recent"] = group.messages.filter { $0.from != "system" }.suffix(8).map { message -> [String: Any] in
                ["fromTitle": message.from == "me" ? "用户" : message.fromTitle, "text": String(Self.agentText(message).prefix(500)), "ts": message.ts]
            }
            return row
        }
    }

    // MARK: - 给各端的

    private func group(_ id: String) -> Group? { store.groups.first { $0.id == id } }

    /// agent 用 group info 看到的一条：带了图、文件的注上（只发图时正文是空的）
    private static func agentText(_ message: Message) -> String {
        let images = (message.images ?? []).count, files = (message.files ?? []).map(\.name)
        let note = [images > 0 ? "附图 \(images) 张" : nil, files.isEmpty ? nil : "附件 " + files.joined(separator: "、")].compactMap { $0 }.joined(separator: "，")
        return note.isEmpty ? message.text : [message.text, "（\(note)）"].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func summary(_ group: Group) -> [String: Any] {
        var out: [String: Any] = ["id": group.id, "name": group.name, "autoName": group.autoName, "createdAt": group.createdAt,
                                  "updatedAt": group.updatedAt, "paused": group.paused ?? false, "count": group.messages.filter { $0.from != "system" }.count,
                                  "marked": group.marked ?? false, "muted": group.muted ?? false]
        if let topic = group.topic { out["topic"] = topic }
        out["members"] = group.members.map { member -> [String: Any] in
            var row: [String: Any] = ["key": member.key, "title": member.title, "joinedAt": member.joinedAt]
            if let machine = member.machine { row["machine"] = machine }
            if let project = member.project { row["project"] = project }
            if let agent = member.agent { row["agent"] = agent }
            return row
        }
        if let last = group.messages.last(where: { $0.from != "system" }) ?? group.messages.last { out["last"] = Self.messagePayload(last) }
        return out
    }

    private func summaryPayload() -> [String: Any] {
        // 标记的排前面，再按最近动静
        ["ok": true, "items": store.groups.sorted { ($0.marked ?? false) != ($1.marked ?? false) ? $0.marked == true : $0.updatedAt > $1.updatedAt }.map(summary)]
    }

    private static func messagePayload(_ message: Message) -> [String: Any] {
        var out: [String: Any] = ["id": message.id, "ts": message.ts, "from": message.from, "fromTitle": message.fromTitle, "text": message.text]
        if let to = message.to { out["to"] = to }
        if let states = message.states, !states.isEmpty { out["states"] = states }
        if let notes = message.notes, !notes.isEmpty { out["notes"] = notes }
        if let itemId = message.itemId { out["itemId"] = itemId }
        if let event = message.event { out["event"] = event }
        if let args = message.args { out["args"] = args }
        if let images = message.images, !images.isEmpty { out["images"] = images.map { ["ref": $0.ref, "name": $0.name, "size": $0.size] } }
        if let files = message.files, !files.isEmpty { out["files"] = files.map { ["ref": $0.ref, "name": $0.name, "size": $0.size] } }
        return out
    }

    private func publishSummary() {
        AppState.shared.mobile.publish(event: "groups", payload: summaryPayload())
    }

    // MARK: - 改动

    private func mutate(_ change: (inout Store) -> Void) {
        change(&store)
        save()
        publishSummary()
        pushToAgents()
    }

    /// 换掉一个群：新加 / 改了的消息单独推（group_msg），概要整份推；quiet = 只存不推（各端看不出区别的改动）
    private func replace(_ group: Group, changed: Message? = nil, quiet: Bool = false) {
        var group = group
        if group.messages.count > Self.messageLimit {
            let extra = group.messages.count - Self.messageLimit
            dropMedia(Array(group.messages.prefix(extra)), in: group.id)
            group.messages.removeFirst(extra)
        }
        guard let index = store.groups.firstIndex(where: { $0.id == group.id }) else { return }
        let before = store.groups[index]
        store.groups[index] = group
        save()
        guard !quiet else { return }
        let added = group.messages.filter { message in !before.messages.contains { $0.id == message.id } }
        for message in added + (changed.map { [$0] } ?? []) {
            AppState.shared.mobile.publish(event: "group_msg", payload: ["id": group.id, "message": Self.messagePayload(message)])
        }
        if changed == nil || before.name != group.name || before.members.count != group.members.count {
            publishSummary()
            pushToAgents()
        }
    }

    private func save() {
        let snapshot = store
        // 快照和写盘在同一个串行队列里，后写的不会被先写的覆盖
        saveQueue.async { [url] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
