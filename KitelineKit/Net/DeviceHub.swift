import Foundation

/// 手机直连的其他 Kiteline 电脑（设备维度里的「Kiteline 设备」）。
///
/// 配对的那台电脑（主电脑，MacStore.current）照旧；另加的每台电脑各一个 MacAPI、各一条事件流（AppModel.LinkedHost）。
/// 它们的设备（来源）并进同一份设备、会话列表，写法和电脑互联一样：`kl:<那台电脑编号前 8 位>:<它的来源>`，
/// 会话 key 是 `kl:<编号>:<来源>#<会话 id>`。这样不管是直连、还是经主电脑互联转过来，同一个会话 key 都一样（天然去重）。
///
/// 请求按会话 / 设备找到所在的那台：查询参数或 JSON 顶层的 key、k、source、sourceId、sessionKey 指向它的设备时，
/// 把 key 换回那台自己的写法直接发给它，回来的 JSON 里的 key 再换回 `kl:` 写法（同 Mac 版 PeerComputers.forward）。
/// 不带会话的接口（待办、用量……）照旧只问主电脑。
final class DeviceHub: @unchecked Sendable {
    static let keyFields = ["key", "k", "source", "sourceId", "sessionKey"]
    static let sourcePrefix = "kl:"

    struct Host {
        let computerId: String
        let api: MacAPI
        /// 这台自己的设备 id（它的写法：local、ssh:xxx），回来的 key 只换这些（它转来的别的电脑的 kl: 设备原样留着）
        var own: Set<String>
        var prefix: String { DeviceHub.prefix(computerId) }
    }

    /// 找到的那台：换好写法的参数，和回来的数据怎么换回本机写法
    struct Routed {
        let api: MacAPI
        let query: [String: String]
        let body: [String: Any]?
        let outward: (Data) -> Data
    }

    private let lock = NSLock()
    private var hosts: [String: Host] = [:]
    /// 本机写法的设备 id → (哪台电脑, 那台的写法)。只放该直连的：那台在线时它自己的设备、别处没有的它转来的设备
    private var table: [String: (computerId: String, remote: String)] = [:]

    static func prefix(_ computerId: String) -> String { sourcePrefix + String(computerId.prefix(8)) + ":" }

    /// 把那台电脑的设备 id 换成本机写法：它自己的加前缀，它转来的（kl: 开头）原样
    static func local(_ remote: String, prefix: String) -> String {
        remote.hasPrefix(sourcePrefix) ? remote : prefix + remote
    }

    func set(hosts list: [Host], table newTable: [String: (computerId: String, remote: String)]) {
        lock.withLock {
            hosts = Dictionary(list.map { ($0.computerId, $0) }, uniquingKeysWith: { a, _ in a })
            table = newTable
        }
    }

    func clear() { set(hosts: [], table: [:]) }

    var isEmpty: Bool { lock.withLock { table.isEmpty } }

    /// 这个会话 / 设备 id 走哪台直连的电脑（nil = 主电脑）
    func computer(of value: String) -> String? {
        let head = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
        return lock.withLock { table[head]?.computerId }
    }

    func api(for computerId: String) -> MacAPI? { lock.withLock { hosts[computerId]?.api } }

    /// 请求是不是冲着直连的电脑上的会话 / 设备来的
    func route(query: [String: String], body: [String: Any]?) -> Routed? {
        var values = Self.keyFields.compactMap { query[$0] }
        if let body {
            values += Self.keyFields.compactMap { body[$0] as? String }
            // 只带 keys 数组的（/api/viewed）：按第一个认（调用方已按电脑分好组）
            if let first = (body["keys"] as? [String])?.first { values.append(first) }
        }
        let (hit, host): ((computerId: String, remote: String, local: String)?, Host?) = lock.withLock {
            for value in values {
                let head = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
                if let entry = table[head], let host = hosts[entry.computerId] { return ((entry.computerId, entry.remote, head), host) }
            }
            return (nil, nil)
        }
        guard let hit, let host else { return nil }
        func inward(_ value: String) -> String {
            if value == hit.local { return hit.remote }
            if value.hasPrefix(hit.local + "#") { return hit.remote + value.dropFirst(hit.local.count) }
            return value
        }
        var newQuery = query
        for field in Self.keyFields { if let value = newQuery[field] { newQuery[field] = inward(value) } }
        var newBody = body
        if var json = body {
            for field in Self.keyFields { if let value = json[field] as? String { json[field] = inward(value) } }
            if let keys = json["keys"] as? [String] { json["keys"] = keys.map(inward) }
            newBody = json
        }
        let prefix = host.prefix, own = host.own
        return Routed(api: host.api, query: newQuery, body: newBody) { data in
            guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return data }
            return (try? JSONSerialization.data(withJSONObject: Self.outward(object, prefix: prefix, own: own), options: [.fragmentsAllowed])) ?? data
        }
    }

    /// 那台电脑回的 JSON 里的会话 key、设备 id 换成本机写法（同 Mac 版 PeerComputers.outward）。
    /// 置顶、标记、静音这几个 key 列表也换
    static func outward(_ object: Any, prefix: String, own: Set<String>) -> Any {
        func map(_ text: String) -> String {
            let head = text.split(separator: "#", maxSplits: 1).first.map(String.init) ?? text
            return own.contains(head) ? prefix + text : text
        }
        if let dict = object as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict {
                if keyFields.contains(key) || key == "from" || key == "to", let text = value as? String {
                    out[key] = map(text)
                } else if ["pinned", "marked", "muted", "keys"].contains(key), let list = value as? [String] {
                    out[key] = list.map(map)
                } else if key == "sys", let stats = value as? [String: Any] {
                    out[key] = Dictionary(stats.map { (map($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
                } else {
                    out[key] = outward(value, prefix: prefix, own: own)
                }
            }
            return out
        }
        if let list = object as? [Any] { return list.map { outward($0, prefix: prefix, own: own) } }
        return object
    }
}
