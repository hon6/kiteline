import AppKit
import Foundation
import UserNotifications
import KitelineKit

/// 今日动态：问每个在线来源的 watcher「这段时间里每个会话做了什么」（包括已经关掉的会话），合并成一份报告。
/// 手机的「今日动态」页、Mac 主窗口的「今日动态」、每天定时推送的日报都用它。
enum Digest {
    /// 本地时间今天 0 点（毫秒）
    static func startOfDay(_ date: Date = Date()) -> Int64 {
        Int64(Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1000)
    }

    /// 同一时间段 30 秒内重复请求直接给缓存（列表页、今日动态页、Mac 窗口可能同时在要）
    private static var cache: [String: (at: Date, payload: [String: Any])] = [:]
    private static var waiting: [String: [([String: Any]) -> Void]] = [:]

    /// 合并所有在线来源的摘要；回调在主线程
    static func collect(since: Int64, until: Int64? = nil, fresh: Bool = false,
                        completion: @escaping ([String: Any]) -> Void) {
        let cacheKey = "\(since)-\(until ?? 0)"
        if !fresh, let hit = cache[cacheKey], Date().timeIntervalSince(hit.at) < 30 {
            completion(hit.payload); return
        }
        if waiting[cacheKey] != nil { waiting[cacheKey]?.append(completion); return }
        waiting[cacheKey] = [completion]

        let state = AppState.shared
        var sessions: [[String: Any]] = []
        // 还没连上的来源也列出来，免得「没动态」其实是「没连上」
        var errors: [String] = state.sourceSummaries.filter { $0.config.enabled && !$0.state.isLive }
            .map { "\($0.config.displayName)：\($0.state.shortLabel)" }
        let complete = errors.isEmpty
        let group = DispatchGroup()
        for source in state.liveSources {
            group.enter()
            var request: [String: Any] = ["cmd": "digest", "since": since]
            if let until = until { request["until"] = until }
            source.request(request, timeout: 60) { result in
                switch result {
                case .success(let response):
                    for var item in (response["sessions"] as? [[String: Any]]) ?? [] {
                        let sessionId = item["sessionId"] as? String ?? ""
                        item["sourceId"] = source.id
                        item["sourceName"] = source.config.displayName
                        let key = "\(source.id)#\(sessionId)"
                        if let record = state.store.record(withKey: key) {
                            item["key"] = key
                            item["activity"] = record.snapshot.act.rawValue
                        }
                        sessions.append(item)
                    }
                case .failure(let error):
                    errors.append("\(source.config.displayName)：\(error.description)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            sessions.sort { number($0["lastAt"]) > number($1["lastAt"]) }
            let payload: [String: Any] = [
                "ok": true, "since": since, "until": until ?? 0,
                "generatedAt": Int64(Date().timeIntervalSince1970 * 1000),
                "sessions": sessions, "totals": totals(sessions), "errors": errors,
            ]
            // 有来源没连上或出错时不缓存，连上后马上能拿到完整的
            if complete && errors.isEmpty { cache[cacheKey] = (Date(), payload) }
            let callbacks = waiting.removeValue(forKey: cacheKey) ?? []
            callbacks.forEach { $0(payload) }
        }
    }

    static func totals(_ sessions: [[String: Any]]) -> [String: Any] {
        func sum(_ key: String) -> Int { sessions.reduce(0) { $0 + Int(number($1[key])) } }
        func testSum(_ key: String) -> Int {
            sessions.reduce(0) { $0 + Int(number(($1["tests"] as? [String: Any])?[key])) }
        }
        let projects = Set(sessions.compactMap { $0["cwd"] as? String })
        return [
            "sessions": sessions.count, "projects": projects.count,
            "prompts": sum("prompts"), "replies": sum("replies"), "requests": sum("requests"),
            "outputTokens": sum("outputTokens"), "files": sum("fileCount"), "images": sum("images"),
            "testRuns": testSum("runs"), "testPassed": testSum("passed"), "testFailed": testSum("failed"),
        ]
    }

    /// 一句话概括，给推送正文和列表顶部卡片用
    static func headline(_ payload: [String: Any], english: Bool = false) -> String {
        let p = Phrase(english: english)
        let t = payload["totals"] as? [String: Any] ?? [:]
        let sessions = Int(number(t["sessions"]))
        guard sessions > 0 else { return p("今日暂无 Claude Code 动态") }
        var parts = [p("%lld 个会话", sessions), p("%lld 轮对话", Int(number(t["prompts"])))]
        let files = Int(number(t["files"]))
        if files > 0 { parts.append(p("修改 %lld 个文件", files)) }
        let runs = Int(number(t["testRuns"]))
        if runs > 0 {
            let failed = Int(number(t["testFailed"]))
            parts.append(failed > 0 ? p("测试 %lld 次（%lld 次失败）", runs, failed) : p("测试 %lld 次", runs))
        }
        let images = Int(number(t["images"]))
        if images > 0 { parts.append(p("%lld 张截图", images)) }
        return parts.joined(separator: " · ")
    }

    /// 日报正文：总览 + 最忙的几个会话各一行
    static func reportBody(_ payload: [String: Any], english: Bool = false) -> String {
        let p = Phrase(english: english)
        var lines = [headline(payload, english: english)]
        let sessions = (payload["sessions"] as? [[String: Any]]) ?? []
        for item in sessions.sorted(by: { number($0["prompts"]) > number($1["prompts"]) }).prefix(4) {
            let title = (item["title"] as? String) ?? ((item["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? p("会话"))
            let prompts = Int(number(item["prompts"]))
            var bits = prompts > 0 ? [p("%lld 轮", prompts)] : []
            let files = Int(number(item["fileCount"]))
            if files > 0 { bits.append(p("%lld 个文件", files)) }
            if let tests = item["tests"] as? [String: Any], number(tests["failed"]) > 0 { bits.append(p("测试有失败")) }
            lines.append(bits.isEmpty ? "• \(title)" : "• \(title)\(p.colon)\(bits.joined(separator: p.comma))")
        }
        return lines.joined(separator: "\n")
    }

    static func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }
}

// MARK: - 每日定时日报

/// 每分钟看一眼：到了设定时间、今天还没发过，就汇总今天的动态推到手机，并在 Mac 上发一条通知。
final class DailyReport {
    static let shared = DailyReport()
    private static let lastSentKey = "dailyReportLastSent"
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 10
    }

    /// 设定时间（"HH:mm"）解析成今天的时刻；空字符串 = 关闭
    static func scheduledDate(_ text: String, on day: Date = Date()) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    private static let morningSentKey = "morningBriefLastSent"

    private func tick() {
        tickMorning(now: Date())
        let config = AppState.shared.config
        guard let due = Self.scheduledDate(config.mobile.digestTime) else { return }
        let now = Date()
        // 只在设定时间之后的 3 小时内补发：电脑半夜醒来不要再推一条「昨天」的日报
        guard now >= due, now.timeIntervalSince(due) < 3 * 3600 else { return }
        let today = Self.dayStamp(now)
        guard LocalState.get(Self.lastSentKey) != today else { return }
        LocalState.set(Self.lastSentKey, today)
        send(manual: false, completion: nil)
    }

    /// 早安简报：到点后 3 小时内、当天没发过就发
    func tickMorning(now: Date) {
        guard let due = Self.scheduledDate(AppState.shared.config.mobile.morningTime, on: now),
              now >= due, now.timeIntervalSince(due) < 3 * 3600 else { return }
        let today = Self.dayStamp(now)
        guard LocalState.get(Self.morningSentKey) != today else { return }
        LocalState.set(Self.morningSentKey, today)
        sendMorning(now: now, manual: false, completion: nil)
    }

    /// 昨晚 18:00 以来的动态 + 现在正等你确认的会话
    func sendMorning(now: Date = Date(), manual: Bool, completion: ((String) -> Void)?) {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let since = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: yesterday) ?? yesterday
        Digest.collect(since: Int64(since.timeIntervalSince1970 * 1000), fresh: true) { payload in
            let sessions = (payload["sessions"] as? [[String: Any]]) ?? []
            let waiting = AppState.shared.store.records.filter { $0.snapshot.act == .waiting }
            if sessions.isEmpty && waiting.isEmpty && !manual {
                Log.write("早安简报：昨晚没有动态，也没有等你的会话，不推送")
                completion?("昨晚无动态"); return
            }
            let stuck = AppState.shared.store.records.compactMap { record in
                StuckWatch.quietMinutes(record.snapshot, now: now).map { (record.snapshot.displayTitle, $0) }
            }
            // 出错停下的会话（用量上限、上下文太长…）：早上第一件事要知道
            let stopped = AppState.shared.store.records.filter { $0.snapshot.act == .idle && $0.snapshot.error != nil }
            // 夜里免打扰时没推到锁屏的提醒：数一下，早上去 🔔 里翻
            let held = Inbox.shared.recent(limit: 300, since: since.timeIntervalSince1970 * 1000).filter { $0.delivery == "quiet" }
            // 按语言各拼一份：中文设备收中文、英文设备收英文（许多小段拼的话整句查表配不上，在这里按语言拼）
            func compose(_ english: Bool, _ projects: [String: Any]) -> (title: String, body: String, lines: [String]) {
                let p = Phrase(english: english)
                var lines: [String] = []
                if !waiting.isEmpty {
                    lines.append(p("待确认：%lld 个会话", waiting.count) + p.comma + waiting.prefix(3).map { $0.snapshot.displayTitle }.joined(separator: p.list))
                }
                lines.append(sessions.isEmpty ? p("昨晚无 Claude Code 动态") : p("昨晚：%@", Digest.headline(payload, english: english)))
                if !stuck.isEmpty {
                    lines.append(p("可能停滞：%lld 个会话", stuck.count) + p.comma + stuck.prefix(3).map { title, minutes in
                        p("%@（%@无进展）", title, minutes >= 120 ? p("%lld 小时", minutes / 60) : p("%lld 分钟", minutes))
                    }.joined(separator: p.semicolon))
                }
                if !stopped.isEmpty {
                    lines.append(p("出错停止：%lld 个会话", stopped.count) + p.comma + stopped.prefix(3).map {
                        let reason = $0.snapshot.error?.display ?? ""
                        return p("%@（%@）", $0.snapshot.displayTitle, english ? ServerLang.translate(reason) : reason)
                    }.joined(separator: p.semicolon))
                }
                if !held.isEmpty {
                    let kinds = Dictionary(grouping: held, by: \.kind)
                    let parts = [("conclusion", "%lld 条结论"), ("error", "%lld 条出错提醒"), ("stuck", "%lld 条停滞提醒"), ("image", "%lld 张图片"),
                                 ("schedule", "%lld 条定时任务")].compactMap { kind, format in kinds[kind].map { p(format, $0.count) } }
                    lines.append(p("免打扰期间有 %lld 条提醒未推送（%@），可在 Kiteline 的通知中查看", held.count, parts.joined(separator: p.list)))
                }
                // 各项目还挂着什么：没提交的改动、没推送的提交（只是附带一句，单独有这个不推）
                if let line = Projects.pendingLine(projects, english: english) { lines.append(line) }
                let body = (lines + Digest.reportBody(payload, english: english).split(separator: "\n").dropFirst().map(String.init)).joined(separator: "\n")
                let title = waiting.isEmpty ? p("早安 · 昨晚的动态") : p("早安 · %lld 个会话待确认", waiting.count)
                return (title, body, lines)
            }
            Projects.collect(detail: true) { projects in
                let (title, body, lines) = compose(false, projects)
                let english = compose(true, projects)
                AppState.shared.mobile.notifyRoute(kind: "digest", title: title, body: body, route: "today", english: (english.title, english.body))
                Audit.note("早安简报", detail: lines.joined(separator: "；"))
                Log.write("早安简报已推送：\(lines.joined(separator: "；"))")
                completion?("已推送：\(lines.joined(separator: "；"))")
            }
        }
    }

    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 立刻汇总并推送（设置里的「现在发一份」也走这里）
    func send(manual: Bool, completion: ((String) -> Void)?) {
        Digest.collect(since: Digest.startOfDay(), fresh: true) { payload in
            let sessions = (payload["sessions"] as? [[String: Any]]) ?? []
            if sessions.isEmpty && !manual {
                Log.write("日报：今天没有动态，不推送")
                completion?("今日无动态"); return
            }
            // 按语言各拼一份：中文设备收中文、英文设备收英文；这台 Mac 自己的通知按 Mac 的界面语言
            func compose(_ english: Bool) -> (title: String, body: String) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: english ? "en" : "zh-Hans")
                formatter.dateFormat = english ? "MMM d" : "M月d日"
                return (Phrase(english: english)("Kiteline 日报 · %@", formatter.string(from: Date())), Digest.reportBody(payload, english: english))
            }
            let (title, body) = compose(false)
            let english = compose(true)
            AppState.shared.mobile.notifyDigest(title: title, body: body, english: english)
            if !Delivery.dryRun { Self.notifyMac(title: Lang.shared.isEnglish ? english.title : title, body: Lang.shared.isEnglish ? english.body : body) }
            Log.write("日报已推送：\(Digest.headline(payload))")
            completion?("已推送：\(Digest.headline(payload))")
        }
    }

    private static func notifyMac(title: String, body: String) {
        guard !Delivery.dryRun else { return }   // 测试实例不往这台 Mac 弹通知（同 SessionStore.deliver）
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = AppState.shared.config.playSound ? .default : nil
        content.userInfo = ["sessionKey": KitelineModel.todayID]
        content.threadIdentifier = "digest"
        let request = UNNotificationRequest(identifier: "digest-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { Log.write("日报通知失败：\(error.localizedDescription)") }
        }
    }
}

// MARK: - 用量报表

/// 各来源的用量报表合并：按天、模型、项目汇总 token 与花费（花费来自 Claude Code 自己记的 cost-state）
enum UsageReport {
    private static var cache: [Int: (at: Date, payload: [String: Any])] = [:]

    static func collect(days: Int, fresh: Bool = false, completion: @escaping ([String: Any]) -> Void) {
        let days = max(1, min(days, 90))
        if !fresh, let hit = cache[days], Date().timeIntervalSince(hit.at) < 60 { completion(hit.payload); return }
        let since = Digest.startOfDay() - Int64(days - 1) * 86_400_000
        let tz = TimeZone.current.secondsFromGMT() / 60
        let state = AppState.shared
        var byDay: [String: [String: Any]] = [:]
        var byModel: [String: [String: Any]] = [:]
        var byProject: [String: [String: Any]] = [:]
        var bySource: [[String: Any]] = []
        var totals = blank()
        var unpriced = Set<String>()
        var errors = state.sourceSummaries.filter { $0.config.enabled && !$0.state.isLive }
            .map { "\($0.config.displayName)：\($0.state.shortLabel)" }
        let complete = errors.isEmpty
        let group = DispatchGroup()
        for connection in state.liveSources {
            group.enter()
            connection.request(["cmd": "usage_report", "since": since, "tz": tz], timeout: 90) { result in
                switch result {
                case .success(let r):
                    let name = connection.config.displayName
                    for day in r["days"] as? [[String: Any]] ?? [] {
                        let key = day["day"] as? String ?? ""
                        byDay[key] = add(byDay[key] ?? blank(["day": key]), day)
                    }
                    for model in r["models"] as? [[String: Any]] ?? [] {
                        let key = model["model"] as? String ?? "unknown"
                        byModel[key] = add(byModel[key] ?? blank(["model": key]), model)
                    }
                    for project in r["projects"] as? [[String: Any]] ?? [] {
                        let cwd = project["cwd"] as? String ?? ""
                        let key = "\(connection.id)\n\(cwd)"
                        byProject[key] = add(byProject[key] ?? blank(["cwd": cwd, "name": (cwd as NSString).lastPathComponent, "sourceName": name, "sourceId": connection.id]), project)
                    }
                    let sourceTotals = r["totals"] as? [String: Any] ?? [:]
                    totals = add(totals, sourceTotals)
                    if days == 1 { lastToday[connection.id] = (DailyReport.dayStamp(Date()), Digest.number(sourceTotals["cost"])) }
                    bySource.append(add(blank(["name": name]), sourceTotals))
                    (r["unpriced"] as? [String] ?? []).forEach { unpriced.insert($0) }
                case .failure(let error):
                    errors.append("\(connection.config.displayName)：\(error.description)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // 区间里每天都给一行（没用的日子补 0），图表才连续
            var dayList: [[String: Any]] = []
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            for offset in 0..<days {
                let date = Date(timeIntervalSince1970: Double(since) / 1000 + Double(offset) * 86400 + 3600)
                let key = formatter.string(from: date)
                dayList.append(byDay[key] ?? blank(["day": key]))
            }
            func rank(_ a: [String: Any], _ b: [String: Any]) -> Bool {
                let (ca, cb) = (Digest.number(a["cost"]), Digest.number(b["cost"]))
                return ca != cb ? ca > cb : Digest.number(a["output"]) > Digest.number(b["output"])
            }
            let payload: [String: Any] = [
                "ok": true, "days": dayList, "range": days, "since": since,
                "models": byModel.values.sorted(by: rank),
                "projects": Array(byProject.values.sorted(by: rank).prefix(20)),
                "sources": bySource.sorted(by: rank),
                "totals": totals, "unpriced": unpriced.sorted(), "errors": errors,
                "generatedAt": Int64(Date().timeIntervalSince1970 * 1000),
            ]
            if complete && errors.isEmpty { cache[days] = (Date(), payload) }
            completion(payload)
        }
    }

    private static let fields = ["input", "output", "cacheRead", "cacheWrite", "requests", "cost", "estimated"]

    /// 每台机器今天最后一次被看到的花费（离线时花费上限要算上它）
    private static var lastToday: [String: (day: String, cost: Double)] = [:]

    static func offlineTodayCost() -> Double {
        let today = DailyReport.dayStamp(Date())
        let live = Set(AppState.shared.liveSources.map { $0.id })
        return lastToday.filter { !live.contains($0.key) && $0.value.day == today }.reduce(0) { $0 + $1.value.cost }
    }

    private static func blank(_ extra: [String: Any] = [:]) -> [String: Any] {
        var item: [String: Any] = extra
        for field in fields { item[field] = 0.0 }
        return item
    }

    private static func add(_ base: [String: Any], _ other: [String: Any]) -> [String: Any] {
        var out = base
        for field in fields { out[field] = Digest.number(base[field]) + Digest.number(other[field]) }
        return out
    }
}

// MARK: - 等你确认太久的提醒

/// 会话等你确认 10 分钟、30 分钟时各再推一次（第一条推送没看到、Claude 一直卡着的情况）
/// 「可能卡住了」：正在工作，但对话记录 20 分钟没有新动静——多半卡在不会自己结束的命令上（npm run dev、watch 模式的测试），
/// 或者一个跑很久的任务。每次卡住只提醒一次；有了新动静再卡住会再提醒。
final class StuckWatch {
    static let shared = StuckWatch()
    static let threshold: TimeInterval = 1200
    private var timer: Timer?
    /// 会话 → 已经提醒过的那次「最后动静」时间（毫秒）
    private var notified: [String: Double] = [:]

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick(now: Date()) }
        timer?.tolerance = 10
    }

    static func lastProgress(_ snap: SessionSnapshot) -> Double? {
        guard let last = snap.transcriptUpdatedAt ?? snap.statusUpdatedAt ?? snap.updatedAt, last > 0 else { return nil }
        return last
    }

    /// 正在工作且多少分钟没动静（没到门槛返回 nil）
    static func quietMinutes(_ snap: SessionSnapshot, now: Date) -> Int? {
        guard snap.act == .busy, let last = lastProgress(snap) else { return nil }
        let quiet = now.timeIntervalSince1970 - last / 1000
        return quiet >= threshold ? Int(quiet / 60) : nil
    }

    /// now 可以从外面传（自测时模拟时间）
    func tick(now: Date) {
        var alive = Set<String>()
        for record in AppState.shared.store.records {
            let snap = record.snapshot
            guard let minutes = Self.quietMinutes(snap, now: now), let last = Self.lastProgress(snap) else { continue }
            alive.insert(record.key)
            guard notified[record.key] != last else { continue }
            notified[record.key] = last
            let doing = snap.activityText.map { "正在 \($0)" } ?? "正在工作"
            AppState.shared.mobile.notify(kind: "stuck", title: snap.displayTitle,
                                          body: "已有 \(minutes) 分钟无新进展（\(doing)），可能已停滞。点击进入可中断", key: record.key)
            Audit.note("可能停滞", detail: "\(snap.displayTitle) \(minutes) 分钟无进展")
            Log.write("可能卡住了：\(snap.displayTitle) \(minutes) 分钟没动静（\(doing)）")
        }
        notified = notified.filter { alive.contains($0.key) }
    }
}

final class WaitingReminder {
    static let shared = WaitingReminder()
    static let marks: [TimeInterval] = [600, 1800]
    private var timer: Timer?
    /// 会话 + 卡在哪个确认上 → 开始等的时间、已经提醒到第几档
    private var tracked: [String: (since: Date, sent: Int)] = [:]

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick(now: Date()) }
        timer?.tolerance = 10
    }

    /// now 可以从外面传（自测时模拟时间）
    func tick(now: Date) {
        guard AppState.shared.config.mobile.remindWaiting else { tracked.removeAll(); return }
        var alive = Set<String>()
        for record in AppState.shared.store.records where record.snapshot.act == .waiting {
            let snap = record.snapshot
            let key = "\(record.key)|\(snap.pendingTool ?? "")|\(snap.blockingDescription ?? "")"
            alive.insert(key)
            var entry = tracked[key] ?? (since: now, sent: 0)
            let waited = now.timeIntervalSince(entry.since)
            if entry.sent < Self.marks.count, waited >= Self.marks[entry.sent] {
                // 一次跳过多档（Mac 睡了很久）只提醒一次，按最高一档算
                while entry.sent < Self.marks.count, waited >= Self.marks[entry.sent] { entry.sent += 1 }
                let minutes = Int(waited / 60)
                let reason = snap.blockingDescription ?? "需要确认"
                AppState.shared.mobile.notify(kind: "attention", title: snap.displayTitle,
                                              body: "已等待确认 \(minutes) 分钟：\(reason)", key: record.key)
                Audit.note("确认提醒", detail: "\(snap.displayTitle) 已等待 \(minutes) 分钟")
                Log.write("催确认：\(snap.displayTitle) 已等 \(minutes) 分钟")
            }
            tracked[key] = entry
        }
        tracked = tracked.filter { alive.contains($0.key) }
    }
}
