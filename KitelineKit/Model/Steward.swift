import Foundation
import Observation

/// 总管派出去的一件事（电脑端 Steward.Task）：派给了哪个会话、做到哪、回报了什么
struct StewardTask: Identifiable, Hashable {
    var id: String
    /// 派给的会话；新开的会话开出来之前是空的
    var key: String
    var op: String
    var title: String
    var device: String
    var cwd: String
    var text: String
    /// sent 已派出 / failed 没派出去 / reported 回报过
    var state: String
    var at: Double
    var reportAt: Double?
    var report: String?
    var images: Int?
    var note: String?

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String else { return nil }
        self.id = id
        key = raw["key"] as? String ?? ""
        op = raw["op"] as? String ?? "assign"
        title = raw["title"] as? String ?? ""
        device = raw["device"] as? String ?? ""
        cwd = raw["cwd"] as? String ?? ""
        text = raw["text"] as? String ?? ""
        state = raw["state"] as? String ?? "sent"
        at = (raw["at"] as? NSNumber)?.doubleValue ?? 0
        reportAt = (raw["reportAt"] as? NSNumber)?.doubleValue
        report = raw["report"] as? String
        images = raw["images"] as? Int
        note = raw["note"] as? String
    }

    var project: String { (cwd as NSString).lastPathComponent }
}

/// 总管最近做的一件事（派活 assign、新开 new、拉群 group、回报 report、失败 failed）：底部那条播报、光束的脉冲用
struct StewardEvent: Identifiable, Hashable {
    var id: String
    var kind: String
    var text: String
    var at: Double
    var keys: [String]

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String else { return nil }
        self.id = id
        kind = raw["kind"] as? String ?? ""
        text = raw["text"] as? String ?? ""
        at = (raw["at"] as? NSNumber)?.doubleValue ?? 0
        keys = raw["keys"] as? [String] ?? []
    }
}

/// 总管模式（实验性）：电脑上记着的设置和总管会话（GET / POST /api/steward，事件 steward）。电脑端支持才有（features 里的 steward）。
/// 开着时 iPhone「会话」页签换成总管的点阵球（StewardHome），对总管说需求；见 Sources/Steward.swift
@MainActor
@Observable
final class StewardState {
    var enabled = false
    var sourceId = ""
    var sourceName = ""
    var agent = "claude-code"
    var existing = "keep"
    var speak = true
    /// 总管会话（在跑的才有）
    var key: String?
    var activity: String?
    /// 电脑正在开总管会话
    var starting = false
    /// 读过一次电脑上的设置
    var loaded = false
    /// 调度记录（最近 12 小时）
    var tasks: [StewardTask] = []
    var events: [StewardEvent] = []

    func apply(_ raw: [String: Any]) {
        enabled = raw["enabled"] as? Bool ?? false
        sourceId = raw["sourceId"] as? String ?? ""
        sourceName = raw["sourceName"] as? String ?? ""
        agent = raw["agent"] as? String ?? "claude-code"
        existing = raw["existing"] as? String ?? "keep"
        speak = raw["speak"] as? Bool ?? true
        key = (raw["key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        activity = raw["activity"] as? String
        starting = raw["starting"] as? Bool ?? false
        let incomingTasks = (raw["tasks"] as? [[String: Any]] ?? []).compactMap(StewardTask.init)
        if incomingTasks != tasks { tasks = incomingTasks }
        let incomingEvents = (raw["events"] as? [[String: Any]] ?? []).compactMap(StewardEvent.init)
        if incomingEvents != events { events = incomingEvents }
        loaded = true
    }

    func apply(_ data: Data) {
        if let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { apply(raw) }
    }

    func refresh(_ api: MacAPI) async {
        if let raw = try? await api.get("/api/steward") { apply(raw) }
    }

    /// 开启：电脑准备工作目录、按选的处理现有会话、开总管会话。→ 电脑回的一句话（失败抛错）
    func enable(_ api: MacAPI, sourceId: String, agent: String, existing: String, speak: Bool) async throws -> String {
        let raw = try await api.post("/api/steward", body: ["enabled": true, "sourceId": sourceId, "agent": agent, "existing": existing, "speak": speak])
        apply(raw)
        return raw["message"] as? String ?? ""
    }

    func disable(_ api: MacAPI) async throws {
        apply(try await api.post("/api/steward", body: ["enabled": false]))
    }

    /// 总管会话不在了：再开一个
    func wake(_ api: MacAPI) async throws -> String {
        let raw = try await api.post("/api/steward/wake")
        apply(raw)
        return raw["message"] as? String ?? ""
    }
}
