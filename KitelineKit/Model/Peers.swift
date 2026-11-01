import Foundation
import SwiftUI

// 会话之间的消息（Claude Code 的 SendMessage）：一个会话发给另一个会话的话。
// 电脑上的 watcher 从两边的对话记录里认出来（靠 msg_id 配对），经电脑推过来：
// - 对话里：发出的那步（tool SendMessage）和收到的那条（event）都带 peer，画成「发给 / 来自某会话」的卡片
// - 实时事件 peers / 接口 /api/peers：一条条往来（谁发给谁、什么时候发、对方什么时候读到），
//   给会话列表上飞的纸鸢、头像两侧的风筝线用

/// 对话项上的往来信息（watcher 填的）：dir = out 发出 / in 收到；session 是对方的会话 id（同一台电脑上，对不上时为空）
struct PeerInfo: Codable, Hashable {
    var dir: String?
    var to: String?
    var name: String?
    var session: String?
    var summary: String?
    var text: String?
    var body: String?
    var msgId: String?
}

/// 一条往来：from / to 是会话 key（来源#会话 id）
struct PeerLink: Codable, Identifiable, Hashable {
    var id: String
    var from: String?
    var to: String?
    var fromName: String?
    var toName: String?
    var fromTitle: String?
    var toTitle: String?
    var summary: String?
    var text: String?
    var sentAt: Double?
    var readAt: Double?
    var ok: Bool?
    /// 发出时先用的临时 id（「t:工具调用 id」）：拿到 msg_id 后换成正式的，客户端据此换掉旧的那条
    var was: String?
    var source: String?

    var stamp: Double { sentAt ?? readAt ?? 0 }
}

struct PeersEvent: Decodable {
    var links: [PeerLink]
    var backfill: Bool?
}

/// 列表上正在飞的一只纸鸢（发出一条消息时放一次）
struct PeerFlight: Identifiable, Hashable {
    let id: String
    let from: String?
    let to: String?
    let toLabel: String
    let start: Date
    static let duration: TimeInterval = 1.5
}

/// 用户可选的几样效果（设置 → 外观 → 会话之间的消息）；iPhone、Mac 各存各的
enum PeerPrefs {
    static let flightsKey = "peerFlights"
    static let lanesKey = "peerLanes"
    static let cardsKey = "peerCards"
    /// 分屏里同一封信的两张卡片用绳子连起（见 Views/PeerRopes.swift）
    static let ropesKey = "peerRopes"
    static var flights: Bool { UserDefaults.standard.object(forKey: flightsKey) as? Bool ?? true }
    static var lanes: Bool { UserDefaults.standard.object(forKey: lanesKey) as? Bool ?? true }
    static var cards: Bool { UserDefaults.standard.object(forKey: cardsKey) as? Bool ?? true }
}

/// 往来的总账：电脑推来的都记在这（今天、昨天的），放动画的队列也在这
@MainActor @Observable
final class PeerBoard {
    private(set) var links: [String: PeerLink] = [:]
    private(set) var flights: [PeerFlight] = []
    /// 收信那一行闪一下（对方读到了）：会话 key → 什么时候
    private(set) var pulses: [String: Date] = [:]
    /// 发出那一步的工具调用 id → 正式的往来 id（对话里的卡片按工具调用找状态）
    @ObservationIgnored private var aliases: [String: String] = [:]

    /// 截图版逐帧看纸鸢：TARS_DEMO_FLIGHT=0～1，纸鸢停在这个位置、不飞走（正式 App 里没有）
    var frozen: Double? {
        #if SNAPSHOT
        ProcessInfo.processInfo.environment["TARS_DEMO_FLIGHT"].flatMap(Double.init)
        #else
        nil
        #endif
    }

    /// 电脑推来一批（backfill = 刚连上补齐的旧往来：只记，不放动画）
    func receive(_ batch: [PeerLink], backfill: Bool) {
        let now = Date().timeIntervalSince1970 * 1000
        for link in batch {
            var known = links[link.id] != nil
            if let was = link.was {
                if links.removeValue(forKey: was) != nil { known = true }
                if was.hasPrefix("t:") { aliases[String(was.dropFirst(2))] = link.id }
            }
            let before = links[link.id]
            links[link.id] = link
            guard !backfill else { continue }
            // 刚发出的（半分钟内）：放一只纸鸢；对方刚读到：收信那行闪一下
            if !known, let sent = link.sentAt, now - sent < 30_000, PeerPrefs.flights {
                fly(link)
            }
            if before?.readAt == nil, let read = link.readAt, now - read < 30_000, let to = link.to {
                pulses[to] = Date()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    if let at = self?.pulses[to], Date().timeIntervalSince(at) >= 1.9 { self?.pulses[to] = nil }
                }
            }
        }
        prune()
    }

    /// 刚连上：拉最近一天的往来
    func load(_ api: MacAPI) async {
        guard let reply = try? await api.get(PeersEvent.self, "/api/peers", [:]) else { return }
        receive(reply.links, backfill: true)
    }

    /// 发出那一步（工具调用 id）对应的往来
    func link(tool toolId: String?, msgId: String?) -> PeerLink? {
        if let msgId, let link = links[msgId] { return link }
        guard let toolId else { return nil }
        if let id = aliases[toolId], let link = links[id] { return link }
        return links["t:" + toolId]
    }

    /// 某条往来之后，对方有没有回过来
    func reply(to link: PeerLink) -> PeerLink? {
        guard let from = link.from, let to = link.to else { return nil }
        return links.values.filter { $0.from == to && $0.to == from && $0.stamp > link.stamp }.min { $0.stamp < $1.stamp }
    }

    /// 最近 window 毫秒内的往来按方向归并（谁发给谁一条）：风筝线一个方向一条，新的在前
    func recentDirections(within window: Double, now: Double = Date().timeIntervalSince1970 * 1000) -> [PeerDirection] {
        var out: [String: PeerDirection] = [:]
        for link in links.values where now - link.stamp < window {
            guard let from = link.from, let to = link.to, from != to else { continue }
            var direction = out[from + ">" + to] ?? PeerDirection(from: from, to: to)
            direction.last = max(direction.last, link.stamp)
            direction.count += 1
            out[from + ">" + to] = direction
        }
        return out.values.sorted { $0.last > $1.last }
    }

    private func fly(_ link: PeerLink) {
        let flight = PeerFlight(id: link.id + "-" + UUID().uuidString.prefix(4), from: link.from, to: link.to,
                                toLabel: link.toTitle ?? link.toName ?? L("其他会话"), start: Date())
        flights.append(flight)
        guard frozen == nil else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PeerFlight.duration + 2.2))
            self?.flights.removeAll { $0.id == flight.id }
        }
    }

    private func prune() {
        let cutoff = Date().timeIntervalSince1970 * 1000 - 2 * 86_400_000
        if links.count > 400 { links = links.filter { $0.value.stamp >= cutoff } }
    }
}

/// 一个方向上的往来：from 发给 to 的最近一次、一共几条
struct PeerDirection: Hashable {
    var from: String
    var to: String
    var last: Double = 0
    var count = 0
}

extension AppModel {
    /// 对话项里的「对方会话 id」换成会话 key：往来只在同一台电脑上，来源和当前会话一样
    func peerKey(_ session: String?, near key: String) -> String? {
        guard let session, !session.isEmpty, let hash = key.firstIndex(of: "#") else { return nil }
        return String(key[..<hash]) + "#" + session
    }

    /// 会话 key 的显示名：在线会话的标题 → 往来里带的标题 → 会话名（ccpulse-xx）
    func peerTitle(_ key: String?, fallback: String?) -> String {
        if let key, let session = session(key) { return session.title }
        return fallback ?? L("其他会话")
    }
}
