import Foundation
import UserNotifications

/// 操作记录：手机（和 Mac 对话页）做过的每个会改变状态的动作——发消息、按确认、新任务、恢复会话、配对……
/// 存在配置目录的 audit.jsonl，一行一条；超过 4000 行时保留最新的 3000 行。
enum Audit {
    private static let queue = DispatchQueue(label: "tars.audit")
    static var fileURL: URL { AppConfig.directoryURL.appendingPathComponent("audit.jsonl") }

    /// 各接口对应的动作名；不在表里的请求不记
    private static let actions: [String: String] = [
        "/api/send": "发送消息", "/api/key": "按键", "/api/answer": "回答提问", "/api/voice": "语音", "/api/close": "关闭会话",
        "/api/new-session": "新任务", "/api/resume": "恢复会话", "/api/quick-replies": "修改快捷短语",
        "/api/digest/push": "推送日报", "/api/push/subscribe": "开启推送", "/api/push/unsubscribe": "关闭推送",
        "/api/push/test": "测试推送", "/api/budget": "修改花费提醒 / 上限", "/pair": "配对",
        "/api/devices/register": "登记设备", "/api/devices/revoke": "停用设备", "/api/devices/rename": "修改设备名称",
        "/api/schedules": "新建定时任务", "/api/schedules/update": "启用 / 停用定时任务", "/api/schedules/delete": "删除定时任务",
        "/api/schedules/run": "立即运行定时任务", "/api/morning/push": "推送早安简报",
        "/api/quiet": "修改免打扰时段", "/api/mute": "静音 / 取消静音会话", "/api/pin": "置顶 / 取消置顶会话", "/api/mark": "标记 / 取消标记会话", "/api/bark": "修改 Bark 推送", "/api/bark/test": "测试 Bark 推送",
        "/api/term": "打开 / 关闭终端", "/api/profile": "修改头像 / 名字", "/api/agent-face": "修改 Agent 头像 / 昵称", "/api/p2p/join": "开通远程访问", "/api/watch": "修改手表设置",
    ]

    private static let keyNames = ["1": "允许", "2": "总是允许", "3": "选项 3", "esc": "拒绝 / 中断", "enter": "确认"]

    /// 路由出口统一调用：只记写操作（POST）和配对
    static func record(_ request: HTTPRequest, _ response: HTTPResponse) {
        guard request.method == "POST" || request.path == "/pair", let action = actions[request.path] else { return }
        // 终端只记开、关：按键不记（会记下 sudo 密码这类东西），读输出、改大小太多
        if request.path == "/api/term", !["open", "close"].contains(request.jsonBody?["op"] as? String ?? "") { return }
        // 要查会话标题（主线程的状态），统一回主线程记
        guard Thread.isMainThread else { DispatchQueue.main.async { record(request, response) }; return }
        let reply = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        let ok = (200..<300).contains(response.status) && reply["ok"] as? Bool != false
        var entry: [String: Any] = [
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
            "action": action,
            "ok": ok,
            "client": client(request),
        ]
        if let message = (reply["error"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? reply["message"] as? String,
           !message.isEmpty, message != "dry-run" {
            entry["message"] = String(message.prefix(120))
        }
        if response.status == 401 { entry["message"] = "未配对的请求被拒绝" }
        if let target = target(request) { entry["target"] = target }
        if let detail = detail(request, reply) { entry["detail"] = detail }
        append(entry)
    }

    /// 直接记一条（不是经 HTTP 来的动作，比如花费提醒发出）
    static func note(_ action: String, detail: String) {
        append(["ts": Int64(Date().timeIntervalSince1970 * 1000), "action": action, "ok": true, "client": "Kiteline", "detail": detail])
    }

    private static func append(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry), var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = fileURL
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                // 会抛 Swift 错误的写法（磁盘满等情况下旧的 seekToEndOfFile / write(_:) 抛 Objective-C 异常，App 会闪退）
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
                // 记着谁在什么时候做了什么：只有自己能读
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            trimIfNeeded(url)
        }
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_500_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        guard lines.count > 4000 else { return }
        try? (lines.suffix(3000).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 最近的记录，新的在前
    static func recent(limit: Int = 200) -> [[String: Any]] {
        let limit = max(1, limit)
        return queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").suffix(limit).reversed().compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
    }

    /// 哪台设备：本机回环 = 这台 Mac 上的 Kiteline 窗口；否则看 UA 认 iPhone / iPad / 安卓 / 电脑，加上 IP
    static func client(_ request: HTTPRequest) -> String {
        let address = request.remoteAddress.replacingOccurrences(of: "::ffff:", with: "")
        if let device = MobileServer.presentedTokens(request).lazy.compactMap({ DeviceStore.shared.peek($0) }).first {
            // 手表经这台手机发来的（?via=watch）
            if request.query["via"] == "watch" { return "\(device.name)的 Apple Watch · \(address)" }
            return "\(device.name) · \(address)"
        }
        if ["127.0.0.1", "::1", "localhost"].contains(address) { return "这台 Mac" }
        let agent = request.headers["user-agent"] ?? ""
        let device: String
        if agent.contains("iPhone") { device = "iPhone" }
        else if agent.contains("iPad") { device = "iPad" }
        else if agent.contains("Android") { device = "安卓手机" }
        else if agent.contains("Macintosh") { device = "Mac 浏览器" }
        else if agent.contains("Windows") { device = "Windows 浏览器" }
        else { device = "浏览器" }
        return "\(device) · \(address)"
    }

    private static func target(_ request: HTTPRequest) -> String? {
        if let key = request.query["key"] {
            if let record = AppState.shared.store.record(withKey: key) { return record.snapshot.displayTitle }
            if let past = HistoryModel.shared.past(key) { return past.displayTitle }
            return String(key.split(separator: "#").last?.prefix(8) ?? "")
        }
        if request.path == "/api/new-session", let cwd = request.jsonBody?["cwd"] as? String {
            return (cwd as NSString).lastPathComponent
        }
        return nil
    }

    private static func detail(_ request: HTTPRequest, _ reply: [String: Any]) -> String? {
        let body = request.path == "/api/voice" ? nil : request.jsonBody
        switch request.path {
        case "/api/send", "/api/answer", "/api/new-session", "/api/resume":
            if reply["capExceeded"] as? Bool == true { return "超出每日花费上限，已拦截" }
            var text = (body?["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            let images = (body?["images"] as? [Any])?.count ?? 0
            if text.count > 80 { text = String(text.prefix(80)) + "…" }
            if images > 0 { text += text.isEmpty ? "（\(images) 张图）" : "（附 \(images) 张图）" }
            // 手机发来的文件（PDF、Excel……）：记下文件名
            let files = (body?["files"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            if !files.isEmpty {
                let names = files.prefix(2).joined(separator: "、") + (files.count > 2 ? " 等 \(files.count) 个" : "")
                text += text.isEmpty ? "（文件 \(names)）" : "（附文件 \(names)）"
            }
            if let branch = reply["branch"] as? String { text += "（独立分支 \(branch)）" }
            return text.isEmpty ? nil : text
        case "/api/key":
            let key = body?["key"] as? String ?? ""
            return keyNames[key] ?? key
        case "/api/term":
            return body?["op"] as? String == "open" ? "打开终端" : "关闭终端"
        case "/api/voice":
            return (reply["text"] as? String).map { "“\($0.prefix(60))”" }
        case "/api/quick-replies":
            return (reply["items"] as? [Any]).map { "\($0.count) 条" }
        case "/api/profile":
            return (reply["me"] as? [String: Any])?["name"] as? String
        case "/api/agent-face":
            return (body?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        case "/api/schedules", "/api/schedules/update":
            guard let item = reply["schedule"] as? [String: Any] else { return nil }
            return "\(item["name"] as? String ?? "") · \(item["label"] as? String ?? "")\(item["enabled"] as? Bool == false ? "（已暂停）" : "")"
        case "/api/schedules/delete":
            return reply["label"] as? String
        case "/api/devices/revoke":
            return reply["name"] as? String
        case "/api/devices/register", "/api/devices/rename":
            return (reply["device"] as? [String: Any])?["name"] as? String
        case "/api/budget":
            let daily = (reply["daily"] as? Double).map { $0 > 0 ? String(format: "提醒 $%.0f", $0) : "提醒关闭" }
            let cap = (reply["cap"] as? Double).map { $0 > 0 ? String(format: "上限 $%.0f", $0) : "不设上限" }
            return [daily, cap].compactMap { $0 }.joined(separator: " · ")
        default:
            return nil
        }
    }
}

// MARK: - 小状态（今天日报 / 花费提醒发过没有）

/// 存在配置目录的 state.json，不用 UserDefaults：自测实例和正式 App 是同一个 bundle id，
/// 共用 UserDefaults 会让测试把正式 App「今天已经发过」的标记写掉
enum LocalState {
    private static let lock = NSLock()
    private static var url: URL { AppConfig.directoryURL.appendingPathComponent("state.json") }

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return read()[key]
    }

    static func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        var all = read()
        all[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func read() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }
}

// MARK: - 花费硬上限

/// 今天的花费有没有超过每日硬上限（只管 Kiteline 自己发起的开销：定时任务、新任务、恢复会话、手机发消息）
enum SpendGuard {
    /// 超了返回一句说明；没设上限或没超返回 nil。回调在主线程
    static func check(completion: @escaping (String?) -> Void) {
        let cap = AppState.shared.config.mobile.dailyCap
        guard cap > 0 else { completion(nil); return }
        UsageReport.collect(days: 1) { payload in
            // 有机器离线时它的花费不在 totals 里：加上它今天最后一次被看到的花费，免得上限被绕过
            let cost = Digest.number((payload["totals"] as? [String: Any])?["cost"]) + UsageReport.offlineTodayCost()
            completion(cost >= cap ? String(format: "今日已花费 $%.2f，超出每日上限 $%.0f", cost, cap) : nil)
        }
    }
}

// MARK: - 花费提醒

/// 每 10 分钟看一眼今天花了多少：到每日预算的 80% 和 100% 各提醒一次（手机推送 + Mac 通知）
final class BudgetWatch {
    static let shared = BudgetWatch()
    private static let sentKey = "budgetAlertSent"   // "日期|档位"
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.check() }
    }

    func check(completion: ((String) -> Void)? = nil) {
        let budget = AppState.shared.config.mobile.dailyBudget
        guard budget > 0 else { completion?("未设置每日预算"); return }
        UsageReport.collect(days: 1, fresh: true) { payload in
            let totals = payload["totals"] as? [String: Any] ?? [:]
            let cost = Digest.number(totals["cost"])
            let level = cost >= budget ? 100 : (cost >= budget * 0.8 ? 80 : 0)
            guard level > 0 else { completion?(String(format: "今日 $%.2f，未达提醒额度", cost)); return }
            let today = DailyReport.dayStamp(Date())
            let sent = LocalState.get(Self.sentKey) ?? ""
            // 同一天同一档只提醒一次；已经提醒过 100% 就不再提醒 80%
            if sent.hasPrefix(today), let last = Int(sent.split(separator: "|").last ?? ""), last >= level {
                completion?("今日已提醒"); return
            }
            LocalState.set(Self.sentKey, "\(today)|\(level)")
            let title = level >= 100 ? String(format: "今日已花费 $%.0f，超出预算 $%.0f", cost, budget)
                                     : String(format: "今日已花费 $%.0f，达到预算的 80%%", cost)
            let body = Self.breakdown(payload)
            AppState.shared.mobile.notifyRoute(kind: "budget", title: title, body: body, route: "usage")
            Self.notifyMac(title: title, body: body)
            Audit.note("花费提醒", detail: title)
            Log.write("花费提醒：\(title)")
            completion?(title)
        }
    }

    /// 花在哪：最多的两个项目和模型
    static func breakdown(_ payload: [String: Any]) -> String {
        var parts: [String] = []
        for project in ((payload["projects"] as? [[String: Any]]) ?? []).prefix(2) {
            let name = (project["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "其他"
            parts.append(String(format: "%@ $%.0f", name, Digest.number(project["cost"])))
        }
        if let model = ((payload["models"] as? [[String: Any]]) ?? []).first {
            parts.append(String(format: "主要来自 %@", model["model"] as? String ?? ""))
        }
        return parts.isEmpty ? "点击查看用量报表" : parts.joined(separator: " · ")
    }

    private static func notifyMac(title: String, body: String) {
        guard !Delivery.dryRun else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = AppState.shared.config.playSound ? .default : nil
        content.userInfo = ["sessionKey": KitelineModel.usageID]
        let request = UNNotificationRequest(identifier: "budget-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
