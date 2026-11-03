import Foundation

/// iPhone 实时活动（锁屏 + 灵动岛）：什么时候开、显示什么、什么时候结束都由电脑定，经 Kiteline 推送网关（/push/live）发给每台登记过的 iPhone，
/// App 没开也照样更新。App 那边（KitelineKit/Push/LiveActivities.swift）只报令牌、管开关；排版在扩展 TARSLive。
///
/// 一「轮」= 从有会话开始干活（或等你确认）到全部停下：
/// - 开始干活：给开着实时活动、有「推送启动令牌」的 iPhone 开一个（每轮每台一次）
/// - 期间：内容变了就更新（平时最多 8 秒一次、低优先级；多了要你确认的立刻发、高优先级）
/// - 全部停下满 90 秒（Claude 跑目标检查时会短暂空闲，别一停就收）：发「全部完成」并结束，锁屏上再留 10 分钟
/// - 用户在锁屏上划掉了：这一轮不再开，下一轮照常
///
/// 苹果规定实时活动的推送内容 App 解不了密，所以是明文：只放会话标题、状态和一句细节（在等什么、做到哪一步），不放对话内容
final class LiveActivities {
    static let shared = LiveActivities()

    /// 一台 iPhone 登记的东西（按配对设备记，存 live-activities.json）
    struct Device: Codable {
        var enabled = true
        var env = "production"
        var lang = "zh"
        /// 推送启动令牌：凭它在 App 没开时开一个实时活动
        var startToken: String?
        /// 正在显示的实时活动：id → 更新令牌
        var activities: [String: String] = [:]
        /// 第几轮已经给它开过 / 被用户划掉了（同一轮不再开）
        var startedRound = 0
        var dismissedRound = 0
    }

    private var devices: [String: Device] = [:]
    /// 每台上次发出去的内容（不含时间）和其中待确认的个数：没变不发、多了要你确认的立刻发
    private var lastSent: [String: (state: String, waiting: Int)] = [:]
    private var lastActivity: [String: String] = [:]
    /// 这一轮里刚做完 / 出错停下的会话（标题、细节、时间）：显示到这一轮结束（最长 15 分钟）
    private var finished: [String: (title: String, error: String?, at: Date)] = [:]
    private var sessions: [[String: Any]] = []
    private var round = 0
    private var active = false
    /// 上次看到几个在等你确认：多了要马上发
    private var waitingCount = 0
    private var idleSince: Date?
    private var lastFlush = Date.distantPast
    private var pendingFlush: DispatchWorkItem?
    private var endCheck: DispatchWorkItem?
    private let queue = DispatchQueue(label: "kiteline.live")

    private static var fileURL: URL { AppConfig.directoryURL.appendingPathComponent("live-activities.json") }
    private static var gateway: URL { WebPush.gateway.appendingPathComponent("live") }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode([String: Device].self, from: data) {
            devices = saved
        }
    }

    // MARK: - iPhone 登记（POST /api/live/register）

    /// body：enabled、env、lang、startToken、activities [{id, token}]、ended（刚结束 / 被划掉的那个）
    func register(deviceId: String?, body: [String: Any]) {
        guard let deviceId else { return }   // 主令牌（Mac 自己的对话页）不参与
        DispatchQueue.main.async { [self] in
            var device = devices[deviceId] ?? Device()
            device.enabled = body["enabled"] as? Bool ?? false
            if let env = body["env"] as? String, ["production", "development"].contains(env) { device.env = env }
            if let lang = body["lang"] as? String { device.lang = lang == "en" ? "en" : "zh" }
            if let ended = body["ended"] as? String, device.activities[ended] != nil, active {
                // 这一轮还没结束就没了：用户在锁屏上划掉的，这一轮别再开
                device.dismissedRound = round
            }
            if device.enabled {
                if let token = body["startToken"] as? String, Self.validToken(token) { device.startToken = token }
                let reported = (body["activities"] as? [[String: Any]] ?? []).compactMap { item -> (String, String)? in
                    guard let id = item["id"] as? String, let token = item["token"] as? String, Self.validToken(token) else { return nil }
                    return (id, token)
                }
                let fresh = reported.contains { device.activities[$0.0] == nil }
                device.activities = Dictionary(reported, uniquingKeysWith: { $1 })
                // 刚开出来的实时活动报了令牌：马上补一份最新的（开的时候带的那份可能已经过时）
                if fresh { lastSent[deviceId] = nil }
            } else {
                device.startToken = nil
                device.activities = [:]
            }
            devices[deviceId] = device
            save()
            if active { schedule(urgent: true) }
        }
    }

    /// 停用、删除配对设备时：它的令牌一起删
    func forget(deviceId: String) {
        DispatchQueue.main.async { [self] in
            devices[deviceId] = nil
            lastSent[deviceId] = nil
            save()
        }
    }

    // MARK: - 会话状态变了（MobileServer.publishState，主线程）

    func update(sessions list: [[String: Any]]) {
        guard !devices.isEmpty else { return }
        let now = Date()
        for session in list {
            guard let key = session["key"] as? String else { continue }
            let activity = session["activity"] as? String ?? ""
            let before = lastActivity[key]
            if activity == "busy" || activity == "waiting" {
                finished[key] = nil
            } else if before == "busy" || before == "waiting" {
                finished[key] = (Self.title(session), session["error"] as? String, now)
            }
            lastActivity[key] = activity
        }
        finished = finished.filter { now.timeIntervalSince($0.value.at) < 15 * 60 }
        sessions = list
        let working = list.contains { ["busy", "waiting"].contains($0["activity"] as? String) }
        let waiting = list.filter { $0["activity"] as? String == "waiting" }.count
        // 新一轮开始、多了要你确认的：马上发（不等 8 秒）
        var urgent = waiting > waitingCount
        waitingCount = waiting
        if working {
            if !active {
                active = true
                round += 1
                urgent = true
            }
            idleSince = nil
            endCheck?.cancel()
            schedule(urgent: urgent)
        } else if active, idleSince == nil {
            idleSince = now
            let check = DispatchWorkItem { [weak self] in self?.endIfIdle() }
            endCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: check)
            schedule(urgent: false)
        }
    }

    private func endIfIdle() {
        guard active, let idleSince, Date().timeIntervalSince(idleSince) >= 89 else { return }
        active = false
        pendingFlush?.cancel()
        let dismiss = Int64(Date().timeIntervalSince1970) + 10 * 60
        for (id, device) in devices where device.enabled && !device.activities.isEmpty {
            let state = content(for: device.lang)
            for token in device.activities.values {
                send(deviceId: id, token: token, env: device.env, body: ["event": "end", "state": state, "dismiss": dismiss, "urgency": "normal"])
            }
            devices[id]?.activities = [:]
        }
        lastSent = [:]
        finished = [:]
        save()
    }

    /// 平时最多 8 秒发一次；急的（多了要你确认的、刚登记的）马上发
    private func schedule(urgent: Bool) {
        let wait = urgent ? 0 : max(0, 8 - Date().timeIntervalSince(lastFlush))
        if wait == 0 {
            pendingFlush?.cancel()
            pendingFlush = nil
            flush()
            return
        }
        guard pendingFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingFlush = nil
            self?.flush()
        }
        pendingFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func flush() {
        guard active else { return }
        lastFlush = Date()
        let stale = Int64(Date().timeIntervalSince1970) + 20 * 60
        for (id, device) in devices where device.enabled {
            let state = content(for: device.lang)
            let waiting = state["waiting"] as? Int ?? 0
            let mark = Self.mark(state)
            if !device.activities.isEmpty {
                guard lastSent[id]?.state != mark else { continue }
                let urgent = waiting > (lastSent[id]?.waiting ?? 0)
                lastSent[id] = (mark, waiting)
                for token in device.activities.values {
                    send(deviceId: id, token: token, env: device.env,
                         body: ["event": "update", "state": state, "stale": stale, "urgency": urgent ? "high" : "normal"])
                }
            } else if let token = device.startToken, device.startedRound != round, device.dismissedRound != round,
                      (state["busy"] as? Int ?? 0) + waiting > 0 {
                devices[id]?.startedRound = round
                lastSent[id] = (mark, waiting)
                let top = (state["items"] as? [[String: Any]])?.first
                let alert = ["title": top?["t"] as? String ?? "Kiteline", "body": top?["l"] as? String ?? ""]
                send(deviceId: id, token: token, env: device.env,
                     body: ["event": "start", "state": state, "attributes": ["host": Host.current().localizedName ?? ""],
                            "alert": alert, "stale": stale, "urgency": "high"])
                save()
            }
        }
    }

    // MARK: - 显示什么

    /// 给一台 iPhone 的内容（按它的语言）：顶上一句 + 最多 3 个会话（等你确认的在前，其次在干活的，再是刚做完 / 出错的）
    func content(for lang: String) -> [String: Any] {
        let english = lang == "en"
        func text(_ chinese: String) -> String { english ? ServerLang.translate(chinese) : chinese }
        func updated(_ session: [String: Any]) -> Double { (session["updatedAt"] as? NSNumber)?.doubleValue ?? 0 }
        let waiting = sessions.filter { $0["activity"] as? String == "waiting" }.sorted { updated($0) > updated($1) }
        let busy = sessions.filter { $0["activity"] as? String == "busy" }.sorted { updated($0) > updated($1) }
        var items: [[String: Any]] = []
        for session in waiting {
            let detail = (session["blocking"] as? String) ?? (session["pendingTool"] as? String)
            items.append(item(session, status: "waiting", label: english ? "Needs approval" : "待确认", detail: detail.map(text)))
        }
        for session in busy {
            var detail = (session["activityText"] as? String).map(text)
            if let stage = session["stage"] as? [String: Any], let total = stage["total"] as? Int, total > 0,
               let step = stage["step"] as? Int, let label = stage["label"] as? String, !label.isEmpty {
                detail = "\(step)/\(total) \(text(label))"
            }
            items.append(item(session, status: "busy", label: english ? "Running" : "进行中", detail: detail))
        }
        for (key, done) in finished.sorted(by: { $0.value.at > $1.value.at }) {
            let failed = done.error != nil
            items.append(["k": key, "t": Self.clip(done.title, 40), "s": failed ? "error" : "done",
                          "l": failed ? (english ? "Stopped on error" : "出错已停止") : (english ? "Done" : "已完成")]
                         .merging(done.error.map { ["d": Self.clip(text($0), 60)] } ?? [:]) { $1 })
        }
        var head: [String] = []
        if !waiting.isEmpty { head.append(english ? "\(waiting.count) waiting" : "\(waiting.count) 个待确认") }
        if !busy.isEmpty { head.append(english ? "\(busy.count) running" : "\(busy.count) 个进行中") }
        return ["head": head.isEmpty ? (english ? "All done" : "全部完成") : head.joined(separator: " · "),
                "waiting": waiting.count, "busy": busy.count, "items": Array(items.prefix(3)),
                "at": Date().timeIntervalSince1970]
    }

    private func item(_ session: [String: Any], status: String, label: String, detail: String?) -> [String: Any] {
        var out: [String: Any] = ["k": session["key"] as? String ?? "", "t": Self.clip(Self.title(session), 40), "s": status, "l": label]
        if let detail, !detail.isEmpty { out["d"] = Self.clip(detail, 60) }
        return out
    }

    private static func title(_ session: [String: Any]) -> String {
        let title = (session["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? (session["name"] as? String ?? "") : title
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// 比较内容变没变：去掉时间
    private static func mark(_ state: [String: Any]) -> String {
        var copy = state
        copy["at"] = nil
        return (try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func validToken(_ token: String) -> Bool {
        token.count >= 64 && token.count <= 200 && token.allSatisfy(\.isHexDigit)
    }

    // MARK: - 发给网关

    private func send(deviceId: String, token: String, env: String, body: [String: Any]) {
        var payload = body
        payload["token"] = token
        payload["env"] = env
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: Self.gateway, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let event = body["event"] as? String ?? ""
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return }
            Log.write("实时活动 \(event) 没发出去：\(error?.localizedDescription ?? "网关返回 \(status)")")
            // 令牌失效（App 删了、实时活动没了）：删掉，别再发
            guard status == 410 else { return }
            DispatchQueue.main.async {
                guard let self, var device = self.devices[deviceId] else { return }
                if device.startToken == token { device.startToken = nil }
                device.activities = device.activities.filter { $0.value != token }
                self.devices[deviceId] = device
                self.save()
            }
        }.resume()
    }

    private func save() {
        let snapshot = devices
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        }
    }
}
