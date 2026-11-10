import Foundation

/// 闲置会话自动关闭（11-01）：24 小时没在 Kiteline 里打开过会话详情的会话，自动关掉它在电脑上的标签
/// （同手动「关闭会话」：VS Code 关标签、终端发 /exit、别家 agent 交给插件），进「历史会话」；标记、置顶的也一样关。
/// 之后在历史里打开它、发一句话就恢复回会话列表（/api/resume）。
///
/// 只认人在 Kiteline 里打开了对话页：别的会话发来消息、它在后台自己回复都不算。算「打开过」的：
/// - 各端对话页打开时报 POST /api/viewed（Mac 主窗口的标签 / 分屏和手机同一套对话页，Windows/Linux 客户端同样报）；
///   对话页开着、App 在前台时每 10 分钟再报一次（一直摆在屏幕上看的，不算没打开）
/// - 旧版 iPhone 不报 /api/viewed，但打开对话页时必取一次 GET /api/voices?key=，也算
/// - 从对话页发消息、按住说话、恢复会话
/// - 各端启动时随 /api/viewed 带上本机记的「最后看过」（seen：未读红点用的那份，打开、看完、标为已读时记），
///   补上升级前的历史：这一版之前打开过的会话不用再从安装时起算 24 小时（11-02 反馈：超时的会话没有关闭）
///
/// 起算时间：有打开记录按最后一次打开；一次都没有的，从 Kiteline 第一次见到它算（first，只在没有任何打开记录时用）；
/// 关掉 / 结束了 10 分钟以上又出现的（在 VS Code 里自己恢复的）重新起算。正在跑的不关，等这一轮停下；要切 VS Code /
/// 终端的，等电脑 10 分钟没人动键盘鼠标再关（不把人正在用的窗口切走），一次一个。
/// 记录存配置目录 viewed.json：{viewed: 会话 key → 最后打开时间（毫秒）, first: 第一次见到的时间}
final class IdleClose {
    static let shared = IdleClose()
    static let threshold: TimeInterval = 24 * 3600
    /// 要切 VS Code / 终端的：人离开电脑这么久才关
    static let userAway: TimeInterval = 600
    /// 离开列表这么久再出现 = 关掉后又恢复了（VS Code 重新加载窗口这类几秒钟的不算）
    static let regone: TimeInterval = 600

    private var timer: Timer?
    /// 打开过的时间（Kiteline 里打开、各端报上来的历史、关掉后又恢复）
    private var viewed: [String: Double] = [:]
    /// 第一次见到的时间：一次打开记录都没有时才拿它起算
    private var first: [String: Double] = [:]
    /// 还开着的会话 / 从列表里消失的时间（看再出现时要不要重新起算）
    private var live: Set<String> = []
    private var goneAt: [String: Date] = [:]
    /// 关不掉的（还没标题认不出标签、等确认的终端会话……）：隔 2 小时再试
    private var failedAt: [String: Date] = [:]
    private var closing = false
    private var saving: DispatchWorkItem?
    private var url: URL { AppConfig.directoryURL.appendingPathComponent("viewed.json") }

    private struct Saved: Codable {
        var viewed: [String: Double]
        var first: [String: Double]
    }

    func start() {
        if let data = try? Data(contentsOf: url) {
            if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
                (viewed, first) = (saved.viewed, saved.first)
            } else if let old = try? JSONDecoder().decode([String: Double].self, from: data), let earliest = old.values.min() {
                // 3.49.15 存的是一张表：装上那一刻一起记下的（2 分钟内）是「第一次见到」，之后的才是真打开过
                for (key, value) in old {
                    if value - earliest < 120_000 { first[key] = value } else { viewed[key] = value }
                }
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.tick(now: Date()) }
        timer?.tolerance = 30
    }

    /// 打开过这些会话的详情（主线程）
    func touch(_ keys: [String], at now: Date = Date()) {
        let keys = keys.filter { !$0.isEmpty && $0.count < 300 }.prefix(50)
        guard !keys.isEmpty else { return }
        for key in keys { viewed[key] = now.timeIntervalSince1970 * 1000 }
        save()
    }

    /// 各端报来的本机历史（key → 最后看过，毫秒）：只补认识的会话，只往后挪（主线程）
    func merge(history: [String: Double], now: Date = Date()) {
        let ms = now.timeIntervalSince1970 * 1000, oldest = ms - 30 * 86400 * 1000
        var changed = false
        for (key, value) in history.prefix(1000) where live.contains(key) || viewed[key] != nil || first[key] != nil {
            let value = min(value, ms)
            guard value > oldest, value > viewed[key] ?? 0 else { continue }
            viewed[key] = value
            changed = true
        }
        if changed { save() }
    }

    /// 会话列表变了（主线程）：新出现的记下起算时间；关掉 / 结束了一阵子又出现的重新起算
    func storeUpdated(_ records: [SessionRecord], now: Date = Date()) {
        let current = Set(records.map(\.key))
        guard current != live else { return }
        var changed = false
        for key in live.subtracting(current) {
            // 那台机器断开了（会话一起不见）不算关掉
            if let hash = key.firstIndex(of: "#"), AppState.shared.source(withId: String(key[..<hash]))?.state.isLive == true {
                goneAt[key] = now
            }
        }
        for key in current.subtracting(live) {
            if goneAt[key].map({ now.timeIntervalSince($0) >= Self.regone }) == true {
                viewed[key] = max(viewed[key] ?? 0, now.timeIntervalSince1970 * 1000)
                changed = true
            } else if viewed[key] == nil, first[key] == nil {
                first[key] = now.timeIntervalSince1970 * 1000
                changed = true
            }
            goneAt[key] = nil
        }
        live = current
        if changed { save() }
    }

    /// 最后一次在任何一端打开过这个会话的详情（毫秒；没打开过是 nil）：会话状态里带给各端，各端的「新消息」按它算——
    /// 在手机上看过了，Mac 侧栏、标签组上就不再标新消息（11-10 反馈：看过的别再显示）
    func viewedAt(_ key: String) -> Double? { viewed[key] }

    /// 有打开记录的会话（自测用：其余的只记了第一次见到）
    var openedKeys: [String] { Array(viewed.keys) }

    /// 多久没打开了（秒）；没记录的返回 nil
    func idle(_ key: String, now: Date = Date()) -> TimeInterval? {
        (viewed[key] ?? first[key]).map { now.timeIntervalSince1970 - $0 / 1000 }
    }

    /// now 可以从外面传（自测时模拟时间）；force = 不等人离开电脑（自测用）
    func tick(now: Date, force: Bool = false) {
        storeUpdated(AppState.shared.store.records, now: now)
        prune(now)
        guard AppState.shared.config.mobile.autoCloseIdle, !closing else { return }
        let due = AppState.shared.store.records.filter { isDue($0, now: now) }
            .sorted { (idle($0.key, now: now) ?? 0) > (idle($1.key, now: now) ?? 0) }
        closeNext(due.map(\.key), now: now, force: force)
    }

    private func isDue(_ record: SessionRecord, now: Date) -> Bool {
        let snap = record.snapshot
        // 互联的别的 Kiteline 电脑上的会话由那台自己判断（本机看过的经 /api/viewed 转告它，见 PeerComputers.noteViewed）
        guard record.kind != .kiteline, snap.capsPayload.contains("close"), snap.canReply(local: record.kind == .local), snap.act != .busy,
              let idle = idle(record.key, now: now), idle >= Self.threshold else { return false }
        if let failed = failedAt[record.key], now.timeIntervalSince(failed) < 7200 { return false }
        return true
    }

    /// 一个一个关：每关一个前都再核对一遍（这期间可能刚被打开、开始干活了），关完隔 3 秒
    private func closeNext(_ keys: [String], now: Date, force: Bool) {
        guard let key = keys.first else { closing = false; return }
        guard let record = AppState.shared.store.record(withKey: key), isDue(record, now: now) else {
            closeNext(Array(keys.dropFirst()), now: now, force: force); return
        }
        // 要切 VS Code / 终端的：人在用电脑就等下一轮（别家 agent 交给插件关，不碰前台）
        if !Delivery.viaAgent(record), !force, EditorAlerts.userIdle() < Self.userAway { closing = false; return }
        closing = true
        let title = record.snapshot.displayTitle
        let hours = Int((idle(key, now: now) ?? 0) / 3600)
        Log.write("自动关闭会话「\(title)」：\(hours) 小时未打开")
        Delivery.close(record: record, source: AppState.shared.source(withId: record.sourceId)) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                if outcome.ok {
                    self.failedAt[key] = nil
                    Audit.note("自动关闭会话", detail: "\(title)（\(hours) 小时未打开）")
                } else {
                    self.failedAt[key] = now
                    Log.write("自动关闭会话未成功「\(title)」：\(outcome.message)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (Delivery.dryRun ? 0 : 3)) { self.closeNext(Array(keys.dropFirst()), now: now, force: force) }
            }
        }
    }

    /// 只留还开着的和 30 天内打开过的（进了历史的会话恢复时 key 不变，留着它的时间）
    private func prune(_ now: Date) {
        let cutoff = (now.timeIntervalSince1970 - 30 * 86400) * 1000
        let kept = viewed.filter { live.contains($0.key) || $0.value >= cutoff }
        let keptFirst = first.filter { live.contains($0.key) || $0.value >= cutoff }
        if kept.count != viewed.count || keptFirst.count != first.count { (viewed, first) = (kept, keptFirst); save() }
        failedAt = failedAt.filter { live.contains($0.key) }
    }

    private func save() {
        saving?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(Saved(viewed: self.viewed, first: self.first)) else { return }
            try? data.write(to: self.url, options: .atomic)
        }
        saving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
