import Foundation
import KitelineKit

/// 会话之间的消息往来（Claude Code 的 SendMessage）：各台机器的 watcher 从对话记录里认出来（peers 事件），
/// 这里把会话 id 换成「来源#会话 id」（和会话列表的 key 一致）记下，再转给手机（实时事件 peers）、
/// 给 /api/peers（手机刚连上、协作图要看今天的）和 Mac 自己的界面（KitelineKit 里的同一套视图）用。
/// 只在主线程用。
final class PeerLinks {
    static let shared = PeerLinks()

    /// 往来 id（msg_id）→ 往来；id 全局唯一，不用再按来源分
    private var links: [String: [String: Any]] = [:]
    /// 留多久：协作图看「今天」，多留一天够用
    private let keep: Double = 2 * 86_400_000

    /// watcher 推来的一批往来：换成会话 key，存下，返回换好的（转给手机、Mac 界面）
    @discardableResult
    func ingest(sourceId: String, _ raw: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for item in raw {
            guard let id = item["id"] as? String else { continue }
            var link = item
            for side in ["from", "to"] {
                if let sid = item[side] as? String, !sid.isEmpty { link[side] = "\(sourceId)#\(sid)" }
            }
            link["source"] = sourceId
            if let was = item["was"] as? String { links.removeValue(forKey: was) }
            links[id] = link
            out.append(link)
        }
        prune()
        return out
    }

    /// 某个时间（毫秒）以来的往来，按时间排
    func since(_ ms: Double) -> [[String: Any]] {
        links.values.filter { stamp($0) >= ms }.sorted { stamp($0) < stamp($1) }
    }

    /// 来源连上了：让 watcher 翻对话记录补齐最近一天的往来（旧版 watcher 不认这个请求，失败就算了）
    func backfill(_ connection: SourceConnection) {
        let sourceId = connection.config.id
        let since = Date().timeIntervalSince1970 * 1000 - 86_400_000
        connection.request(["cmd": "peers", "since": Int64(since)], timeout: 60) { [weak self] result in
            guard case .success(let response) = result, let raw = response["links"] as? [[String: Any]], !raw.isEmpty else { return }
            let links = self?.ingest(sourceId: sourceId, raw) ?? []
            // 补齐的是旧往来：手机、Mac 界面（嵌的是同一套，也走实时事件）收下就行，不放动画
            AppState.shared.mobile.publish(event: "peers", payload: ["links": links, "backfill": true])
        }
    }

    private func stamp(_ link: [String: Any]) -> Double {
        Digest.number(link["sentAt"]) > 0 ? Digest.number(link["sentAt"]) : Digest.number(link["readAt"])
    }

    private func prune() {
        let cutoff = Date().timeIntervalSince1970 * 1000 - keep
        links = links.filter { stamp($0.value) >= cutoff }
    }
}
