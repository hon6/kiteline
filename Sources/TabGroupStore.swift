import Foundation

/// 标签组（同一阶段的几个相关会话放一组；Mac 切到哪组右边就多列显示哪组，手机上点开一组、一次看一个会话）。
/// 组名、颜色、组里有哪些会话、先后存在这台电脑上（配置目录 tabgroups.json），连这台电脑的各端看到同一套；
/// 分屏怎么摆（Mac 的多列布局）各端自己存，不放这里。有变化经实时通道推 tabgroups 事件（整份，量很小），各端直接换掉。
///
///   GET  /api/tabgroups          {ok, rev, groups:[{id, name, color, keys:[会话 key]}]}
///   POST /api/tabgroups/set      {groups:[…], base?: rev}：整份换掉（谁后改听谁的），回新的整份
final class TabGroupStore {
    struct Group: Codable, Equatable {
        var id: String
        var name: String
        var color: String?
        var keys: [String]
    }

    private struct Store: Codable {
        var rev: Int = 0
        var groups: [Group] = []
    }

    static let shared = TabGroupStore()
    private static let groupLimit = 200
    private static let keyLimit = 100

    private let lock = NSLock()
    private var store = Store()
    private let saveQueue = DispatchQueue(label: "tars.tabgroups.save")
    private var url: URL { AppConfig.directoryURL.appendingPathComponent("tabgroups.json") }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
            // 改名前自动起的「标签组 N」改叫「会话组 N」（11-10 界面改叫会话组；用户自己起的名字不动）
            for index in store.groups.indices {
                let name = store.groups[index].name
                if name.hasPrefix("标签组 "), Int(name.dropFirst(4)) != nil { store.groups[index].name = "会话组 " + name.dropFirst(4) }
            }
        }
    }

    func payload() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["ok": true, "rev": store.rev, "groups": store.groups.map { group -> [String: Any] in
            var row: [String: Any] = ["id": group.id, "name": group.name, "keys": group.keys]
            if let color = group.color { row["color"] = color }
            return row
        }]
    }

    /// /api/tabgroups…（MobileServer 转过来）
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/tabgroups"):
            return .json(payload())
        case ("POST", "/api/tabgroups/set"):
            guard let raw = request.jsonBody?["groups"] as? [[String: Any]] else { return .error("缺少 groups", status: 400) }
            var seen = Set<String>()
            let groups: [Group] = raw.prefix(Self.groupLimit).compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
                let name = ((row["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var keys: [String] = []
                for key in (row["keys"] as? [String]) ?? [] where !key.isEmpty && !keys.contains(key) { keys.append(key) }
                return Group(id: id, name: name.isEmpty ? "会话组" : String(name.prefix(60)), color: row["color"] as? String,
                             keys: Array(keys.prefix(Self.keyLimit)))
            }
            set(groups)
            return .json(payload())
        default:
            return .error("接口不存在", status: 404)
        }
    }

    private func set(_ groups: [Group]) {
        lock.lock()
        guard groups != store.groups else { lock.unlock(); return }
        store.groups = groups
        store.rev += 1
        let snapshot = store
        lock.unlock()
        saveQueue.async { [url] in
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        AppState.shared.mobile.publish(event: "tabgroups", payload: payload())
    }
}
