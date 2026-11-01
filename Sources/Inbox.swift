import Foundation
import KitelineKit

/// 通知收件箱：Kiteline 发出的每条提醒都记一笔（含免打扰时没推到锁屏的），手机上 🔔 里能翻。
/// 存配置目录 inbox.json，只留最近 300 条。
final class Inbox {
    struct Entry: Codable {
        var id: String
        var ts: Double
        /// attention / conclusion / image / digest / schedule / budget / test
        var kind: String
        var title: String
        var body: String
        /// 点开去哪个会话
        var key: String?
        /// 或者去哪个页面（today / usage / schedules）
        var route: String?
        /// sent = 推到了锁屏；quiet = 免打扰时段没推；muted = 会话静音没推；none = 没有设备开推送（只在打开的页面里弹）
        var delivery: String
        /// 英文版（日报这类在源头按语言拼好的）：英文设备看这份（见 ServerLang.localize 的 titleEn / bodyEn）
        var titleEn: String?
        var bodyEn: String?
    }

    static let shared = Inbox()
    private static let limit = 300

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let saveQueue = DispatchQueue(label: "tars.inbox.save")
    private var url: URL { AppConfig.directoryURL.appendingPathComponent("inbox.json") }

    private init() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
    }

    @discardableResult
    func add(kind: String, title: String, body: String, key: String?, route: String?, delivery: String,
             english: (title: String, body: String)? = nil) -> Entry {
        let entry = Entry(id: String(UUID().uuidString.prefix(8)).lowercased(), ts: (Date().timeIntervalSince1970 * 1000).rounded(),
                          kind: kind, title: String(title.prefix(200)), body: String(body.prefix(600)),
                          key: key, route: route, delivery: delivery,
                          titleEn: english.map { String($0.title.prefix(200)) }, bodyEn: english.map { String($0.body.prefix(600)) })
        lock.lock()
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        lock.unlock()
        save()
        return entry
    }

    /// 最新的在前
    func recent(limit: Int, since: Double = 0) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.filter { $0.ts > since }.suffix(limit).reversed())
    }

    static func payload(_ entry: Entry) -> [String: Any] {
        var item: [String: Any] = ["id": entry.id, "ts": entry.ts, "kind": entry.kind, "title": entry.title,
                                   "body": entry.body, "delivery": entry.delivery]
        if let key = entry.key { item["key"] = key }
        if let route = entry.route { item["route"] = route }
        // 英文版：出口给英文设备换上（ServerLang.localize），中文设备那份不带
        if let title = entry.titleEn { item["titleEn"] = title }
        if let body = entry.bodyEn { item["bodyEn"] = body }
        return item
    }

    private func save() {
        // 快照和写盘在同一个串行队列里，后写的不会被先写的覆盖
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let snapshot = self.entries
            self.lock.unlock()
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            try? data.write(to: self.url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        }
    }
}
