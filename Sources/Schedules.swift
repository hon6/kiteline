import Foundation

/// 定时任务：到点在某个项目里新开一个 Claude Code 会话并把要求发出去（和手机上的「新任务」同一条路）。
/// 存在配置目录的 schedules.json；每 30 秒看一次有没有到点的。Mac 睡着错过的，1 小时内醒来补跑，超过就记为「错过」。
final class Scheduler {
    struct Task: Codable, Equatable {
        var id: String
        var sourceId: String
        var cwd: String
        var prompt: String
        /// once / daily / weekdays
        var repeatMode: String
        /// "HH:mm"
        var time: String
        /// 只有 once 用："yyyy-MM-dd"
        var date: String?
        var enabled: Bool
        var createdAt: Double
        var lastRun: Double?
        var lastOk: Bool?
        var lastResult: String?
    }

    static let shared = Scheduler()
    static let modes = ["once": "一次", "daily": "每天", "weekdays": "工作日"]
    private static let grace: TimeInterval = 3600

    private(set) var tasks: [Task] = []
    private var timer: Timer?
    /// 正在开的任务（防双击「现在运行」开出两个会话）
    private var inFlight = Set<String>()
    private var url: URL { AppConfig.directoryURL.appendingPathComponent("schedules.json") }

    private init() {
        if let data = try? Data(contentsOf: url) {
            if let list = try? JSONDecoder().decode([Task].self, from: data) { tasks = list } else {
                // 读不出来（格式变了 / 损坏）：先备份，别让下一次保存把它覆盖成空
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))"))
                Log.write("定时任务文件读不出来，已备份为 .bak")
            }
        }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick(now: Date()) }
        timer?.tolerance = 5
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick(now: Date()) }
    }

    // MARK: - 增删改

    func add(sourceId: String, cwd: String, prompt: String, repeatMode: String, time: String, date: String?) -> Result<Task, ValidationError> {
        guard Self.modes[repeatMode] != nil else { return .failure(.init("重复方式无效")) }
        guard Self.parseTime(time) != nil else { return .failure(.init("时间格式应为 HH:mm")) }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.init("请先填写任务内容")) }
        guard cwd.hasPrefix("/"), !cwd.contains("\n") else { return .failure(.init("项目路径无效")) }
        var task = Task(id: String(UUID().uuidString.prefix(8)).lowercased(), sourceId: sourceId, cwd: cwd, prompt: String(text.prefix(4000)),
                        repeatMode: repeatMode, time: time, date: nil, enabled: true, createdAt: Date().timeIntervalSince1970 * 1000)
        if repeatMode == "once" {
            guard let date = date, let when = Self.onceDate(date, time) else { return .failure(.init("一次性任务需选择日期")) }
            guard when > Date() else { return .failure(.init("该时间已过")) }
            task.date = date
        }
        tasks.append(task)
        save()
        return .success(task)
    }

    func update(_ id: String, enabled: Bool) -> Task? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        tasks[index].enabled = enabled
        // 重新打开的每日任务：从现在起算，不补跑关着期间错过的
        if enabled && tasks[index].repeatMode != "once" {
            tasks[index].lastRun = max(tasks[index].lastRun ?? 0, Date().timeIntervalSince1970 * 1000)
        }
        save()
        return tasks[index]
    }

    @discardableResult
    func remove(_ id: String) -> Task? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let task = tasks.remove(at: index)
        save()
        return task
    }

    // MARK: - 到点执行

    /// now 可以从外面传（自测时模拟时间）
    func tick(now: Date) {
        for task in tasks where task.enabled {
            guard let due = dueOccurrence(task, now: now) else { continue }
            if now.timeIntervalSince(due) > Self.grace {
                finish(task.id, at: due, ok: false, message: "已错过：到达设定时间时电脑未开机或处于睡眠状态", now: now)
            } else {
                run(task.id, at: due)
            }
        }
    }

    /// 立刻跑一次（「现在运行」按钮；也给定时用）
    func run(_ id: String, at due: Date? = nil, completion: ((Bool, String) -> Void)? = nil) {
        guard let task = tasks.first(where: { $0.id == id }) else { completion?(false, "任务不存在"); return }
        if due == nil && inFlight.contains(id) { completion?(false, "该任务正在启动，请稍候"); return }
        let ran = due ?? Date()
        guard let source = AppState.shared.config.sources.first(where: { $0.id == task.sourceId }),
              let connection = AppState.shared.source(withId: task.sourceId), connection.state.isLive else {
            // 定时触发时机器暂时不在线（比如 SSH 正在重连）：宽限期内不记结果，下一次 tick 再试
            if let due = due, Date().timeIntervalSince(due) < Self.grace, !inFlight.contains(id) {
                Log.write("定时任务 \((task.cwd as NSString).lastPathComponent)：机器暂时不在线，稍后重试"); return
            }
            finish(id, at: ran, ok: false, message: "目标机器当时离线"); completion?(false, "目标机器当前离线"); return
        }
        // 先记上「已经跑过这一次」，免得结果没回来前下一次 tick 又触发
        if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].lastRun = ran.timeIntervalSince1970 * 1000 }
        inFlight.insert(id)
        SpendGuard.check { [weak self] capped in
            if let capped = capped {
                self?.finish(id, at: ran, ok: false, message: "跳过：\(capped)")
                completion?(false, capped); return
            }
            self?.startChecked(task, source: source, connection: connection, ran: ran, completion: completion)
        }
    }

    private func startChecked(_ task: Task, source: SourceConfig, connection: SourceConnection, ran: Date,
                              completion: ((Bool, String) -> Void)?) {
        let id = task.id
        connection.request(["cmd": "is_dir", "path": task.cwd], timeout: 15) { [weak self] result in
            guard case .success(let check) = result, check["isDir"] as? Bool == true else {
                self?.finish(id, at: ran, ok: false, message: "项目目录已不存在")
                completion?(false, "项目目录已不存在"); return
            }
            NewSession.start(source: source, cwd: task.cwd, prompt: task.prompt, submit: true) { outcome in
                self?.finish(id, at: ran, ok: outcome.ok, message: outcome.message)
                completion?(outcome.ok, outcome.message)
            }
        }
    }

    private func finish(_ id: String, at ran: Date, ok: Bool, message: String, now: Date = Date()) {
        inFlight.remove(id)
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].lastRun = ran.timeIntervalSince1970 * 1000
        tasks[index].lastOk = ok
        tasks[index].lastResult = message
        if tasks[index].repeatMode == "once" { tasks[index].enabled = false }
        save()
        let task = tasks[index]
        let project = (task.cwd as NSString).lastPathComponent
        Audit.note("定时任务", detail: "\(project)：\(ok ? "已开始" : message) · \(task.prompt.prefix(40))")
        Log.write("定时任务 \(project)：\(ok ? "已开始" : message)")
        AppState.shared.mobile.notifyRoute(kind: "schedule",
                                           title: ok ? "定时任务已开始 · \(project)" : "定时任务启动失败 · \(project)",
                                           body: ok ? String(task.prompt.prefix(120)) : message, route: "schedules")
    }

    // MARK: - 时间计算

    static func parseTime(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    static func onceDate(_ date: String, _ time: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(date) \(time)")
    }

    private static func at(_ day: Date, _ time: String) -> Date? {
        guard let (h, m) = parseTime(time) else { return nil }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: day)
    }

    private static func isWeekday(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)   // 1 = 周日
        return weekday != 1 && weekday != 7
    }

    /// 到点了但还没跑的那一次（最近的一次 ≤ now，且晚于上次运行 / 创建时间）
    func dueOccurrence(_ task: Task, now: Date) -> Date? {
        let anchor = Date(timeIntervalSince1970: (task.lastRun ?? task.createdAt) / 1000)
        var candidate: Date?
        switch task.repeatMode {
        case "once":
            guard task.lastRun == nil, let date = task.date, let when = Self.onceDate(date, task.time), when <= now else { return nil }
            return when
        default:
            for back in 0..<8 {
                guard let day = Calendar.current.date(byAdding: .day, value: -back, to: now),
                      let when = Self.at(day, task.time), when <= now else { continue }
                if task.repeatMode == "weekdays" && !Self.isWeekday(when) { continue }
                candidate = when
                break
            }
        }
        guard let due = candidate, due > anchor else { return nil }
        return due
    }

    /// 下一次什么时候跑
    func nextRun(_ task: Task, after now: Date = Date()) -> Date? {
        guard task.enabled else { return nil }
        if task.repeatMode == "once" {
            guard task.lastRun == nil, let date = task.date else { return nil }
            return Self.onceDate(date, task.time)
        }
        for ahead in 0..<9 {
            guard let day = Calendar.current.date(byAdding: .day, value: ahead, to: now),
                  let when = Self.at(day, task.time), when > now else { continue }
            if task.repeatMode == "weekdays" && !Self.isWeekday(when) { continue }
            return when
        }
        return nil
    }

    func payload(_ task: Task) -> [String: Any] {
        let source = AppState.shared.config.sources.first(where: { $0.id == task.sourceId })
        var item: [String: Any] = [
            "id": task.id, "sourceId": task.sourceId, "sourceName": source?.displayName ?? task.sourceId,
            "cwd": task.cwd, "name": (task.cwd as NSString).lastPathComponent, "prompt": task.prompt,
            "repeat": task.repeatMode, "time": task.time, "enabled": task.enabled, "createdAt": task.createdAt,
            "label": label(task),
        ]
        if let date = task.date { item["date"] = date }
        if let next = nextRun(task) { item["nextRun"] = Int64(next.timeIntervalSince1970 * 1000) }
        if let last = task.lastRun { item["lastRun"] = last }
        if let ok = task.lastOk { item["lastOk"] = ok }
        if let result = task.lastResult { item["lastResult"] = result }
        return item
    }

    func label(_ task: Task) -> String {
        switch task.repeatMode {
        case "daily": return "每天 \(task.time)"
        case "weekdays": return "工作日 \(task.time)"
        default:
            let parts = (task.date ?? "").split(separator: "-")
            let day = parts.count == 3 ? "\(Int(parts[1]) ?? 0)月\(Int(parts[2]) ?? 0)日" : (task.date ?? "")
            return "\(day) \(task.time) 一次"
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tasks) else { return }
        try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    struct ValidationError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
