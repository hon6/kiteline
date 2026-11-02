import AppKit
import Foundation
import KitelineKit
import UserNotifications

protocol SessionStoreDelegate: AnyObject {
    func sessionStoreDidUpdate(_ store: SessionStore)
    func sessionStore(_ store: SessionStore, wantsNotificationFor record: SessionRecord, transition: SessionTransition)
    /// 来源还连着、会话却不在它报来的列表里了（关掉、结束了）
    func sessionStore(_ store: SessionStore, didLose records: [SessionRecord])
}

/// 把多个来源的事件流合并成「会话列表 + 该不该提醒」的判定中枢。
///
/// 提醒规则（去重 + 冷却）：
///  1. 某会话处于 waiting → 「需要你确认」提醒（同一等待原因只提醒一次）
///  2. 会话从 busy 变成 idle 且带结论文本 → 「出结论了」提醒（同一 messageUuid 只提醒一次）
///  3. App 启动时已经存在的等待/结论不补发提醒，避免一开机就被历史消息轰炸
///  4. 别的会话来信引起的那一轮（turnFrom = peer）答完不提醒：那是会话之间的往来，回给发信的会话就行；出错停下照样提醒
///  5. 设了目标（/goal）的会话：每一轮停下不提醒（Codex 一轮接一轮自己续做），目标达成、做不到、停下来时提醒一次
final class SessionStore {
    weak var delegate: SessionStoreDelegate?

    private(set) var records: [SessionRecord] = []
    private(set) var sourceStates: [String: LinkState] = [:]
    private(set) var sourceConfigs: [SourceConfig] = []
    private(set) var lastEventAt: Date?

    private var previous: [String: SessionRecord] = [:]
    private var isPrimed = false

    /// 已经提醒过的等待原因：key -> reason
    private var notifiedNeeds: [String: String] = [:]
    /// 已经提醒过的结论：key -> messageUuid
    private var notifiedConclusions: [String: String] = [:]
    private var lastAttentionAt: [String: Date] = [:]
    private var lastConclusionAt: [String: Date] = [:]
    /// 曾经观察到的会话，用来区分「首次见到」和「重启后再次见到」
    private var knownSessionIds: Set<String> = []

    var config: AppConfig

    init(config: AppConfig) {
        self.config = config
        self.sourceConfigs = config.sources
        knownSessionIds = Set(AppConfig.defaults.stringArray(forKey: "knownSessionKeys") ?? [])
    }

    // MARK: - 输入

    /// 自检用：跳过网络，直接灌入一批快照（走与真实事件完全相同的判定路径）
    func injectForSelfTest(_ records: [SessionRecord]) {
        applyRecords(from: records.first?.sourceId ?? "selftest", records)
    }

    /// 配置变更时同步来源列表（并清掉已删除来源的会话）
    func applySourceConfigs(_ configs: [SourceConfig]) {
        sourceConfigs = configs
        let ids = Set(configs.map { $0.id })
        let removed = Set(records.map { $0.sourceId }).subtracting(ids)
        for sourceId in removed {
            records.removeAll { $0.sourceId == sourceId }
            previous = previous.filter { $0.value.sourceId != sourceId }
        }
        sourceStates = sourceStates.filter { ids.contains($0.key) }
    }

    func apply(sourceConfig: SourceConfig, state: LinkState) {
        sourceStates[sourceConfig.id] = state
        if !sourceConfigs.contains(where: { $0.id == sourceConfig.id }) {
            sourceConfigs.append(sourceConfig)
        }
        delegate?.sessionStoreDidUpdate(self)
    }

    func apply(sourceConfig: SourceConfig, event: WatcherEvent) {
        lastEventAt = Date()
        switch event.kind {
        case "snapshots":
            let incoming = event.sessions.map { snapshot in
                SessionRecord(sourceId: sourceConfig.id,
                              sourceName: sourceConfig.displayName,
                              kind: sourceConfig.kind,
                              snapshot: snapshot)
            }
            applyRecords(from: sourceConfig.id, incoming)
        case "hello", "heartbeat":
            delegate?.sessionStoreDidUpdate(self)
        case "error":
            Log.write("[\(sourceConfig.displayName)] watcher 报错：\(event.message ?? "?")")
            delegate?.sessionStoreDidUpdate(self)
        default:
            break
        }
    }

    /// 某个来源断线时清掉它的会话，避免面板里一直挂着已经看不到的旧状态
    func dropSessions(from sourceId: String) {
        records.removeAll { $0.sourceId == sourceId }
        previous = previous.filter { $0.value.sourceId != sourceId }
        delegate?.sessionStoreDidUpdate(self)
    }

    private func applyRecords(from sourceId: String, _ incoming: [SessionRecord]) {
        let others = records.filter { $0.sourceId != sourceId }
        let filtered = incoming.filter { isWatched($0) }
        // 同一会话在两个窗口里同时开着时，watcher 会报出两条同 id 的会话：只留最后打开的那条
        var merged: [SessionRecord] = []
        var slot: [String: Int] = [:]
        for record in others + filtered {
            guard let index = slot[record.key] else {
                slot[record.key] = merged.count
                merged.append(record)
                continue
            }
            if (record.snapshot.startedAt ?? 0) >= (merged[index].snapshot.startedAt ?? 0) { merged[index] = record }
        }

        let sorted = merged.sorted { lhs, rhs in
            rank(lhs) == rank(rhs)
                ? (lhs.snapshot.startedAt ?? 0) > (rhs.snapshot.startedAt ?? 0)
                : rank(lhs) < rank(rhs)
        }

        var transitions: [(SessionRecord, SessionTransition)] = []
        var currentKeys = Set<String>()
        for record in sorted {
            currentKeys.insert(record.key)
            let old = previous[record.key]
            if let transition = classify(old: old, new: record) {
                transitions.append((record, transition))
            }
        }
        var gone: [SessionRecord] = []
        for (key, old) in previous where !currentKeys.contains(key) && old.sourceId == sourceId {
            transitions.append((old, .disappeared))
            gone.append(old)
        }
        if !gone.isEmpty { delegate?.sessionStore(self, didLose: gone) }

        records = sorted
        previous = Dictionary(sorted.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        var newlySeen = false
        for record in sorted where !knownSessionIds.contains(record.key) {
            knownSessionIds.insert(record.key)
            newlySeen = true
        }
        if newlySeen {
            AppConfig.defaults.set(Array(knownSessionIds), forKey: "knownSessionKeys")
        }

        // 首帧只建立基线，不补发历史提醒
        if !isPrimed {
            isPrimed = true
            for record in sorted {
                if record.snapshot.act == .waiting { notifiedNeeds[record.key] = needsKey(record) }
                if record.snapshot.act == .idle {
                    notifiedConclusions[record.key] = record.snapshot.messageUuid ?? record.snapshot.message
                }
            }
            Log.write("建立基线：\(sorted.count) 个会话，来自 \(Set(sorted.map { $0.sourceName }).sorted().joined(separator: "、"))")
            delegate?.sessionStoreDidUpdate(self)
            return
        }

        for (record, transition) in transitions where transition.shouldNotify {
            guard passCooldown(record: record, transition: transition) else { continue }
            delegate?.sessionStore(self, wantsNotificationFor: record, transition: transition)
        }

        delegate?.sessionStoreDidUpdate(self)
    }

    // MARK: - 判定

    private func classify(old: SessionRecord?, new: SessionRecord) -> SessionTransition? {
        let key = new.key
        guard let old = old else {
            // 第一次见到这个会话（App 刚启动、来源刚连上 / 重连、或者打开了一个旧对话）：
            // 记下它现在的状态当基线，不补发已经存在的等待和结论。
            // 早期版本只在「第一个上报的来源」上建基线，后连上的来源会把所有旧结论再推一遍。
            if new.snapshot.act == .waiting { notifiedNeeds[key] = needsKey(new) }
            if new.snapshot.act == .idle {
                notifiedConclusions[key] = new.snapshot.messageUuid ?? new.snapshot.message
            }
            return .appeared
        }

        if new.snapshot.act != .waiting, let goal = GoalSnapshot.ended(old: old.snapshot.goal, new: new.snapshot.goal) {
            // 这一条替掉同时到的「已完成」：结论记成提醒过了
            if new.snapshot.act == .idle { notifiedConclusions[key] = new.snapshot.messageUuid ?? new.snapshot.message }
            return .goalEnded(goal)
        }

        if new.snapshot.act == .waiting {
            let reason = needsKey(new)
            if notifiedNeeds[key] != reason {
                notifiedNeeds[key] = reason
                let text = new.snapshot.blockingDescription ?? "需要确认"
                return .needsAttention(reason: text)
            }
            return nil
        }

        // 离开等待态就清空去重键，下次再等还会提醒
        notifiedNeeds[key] = nil

        if new.snapshot.act == .busy {
            return old.snapshot.act == .busy ? nil : .wentBusy
        }

        if new.snapshot.act == .idle {
            guard let message = new.snapshot.message, !message.isEmpty else { return nil }
            let fingerprint = new.snapshot.messageUuid ?? message
            if notifiedConclusions[key] != fingerprint {
                notifiedConclusions[key] = fingerprint
                if new.snapshot.fromPeer, new.snapshot.error == nil { return nil }
                // 目标还在做：这一轮停下不算完（达成了下一刻就到、停下了过几秒就认出来），等目标的提醒
                if new.snapshot.goal?.state == "active" { return nil }
                return .concluded(message: message)
            }
            return nil
        }

        return nil
    }

    private func passCooldown(record: SessionRecord, transition: SessionTransition) -> Bool {
        let now = Date()
        switch transition {
        case .needsAttention:
            guard config.notifyOnNeedsAttention else { return false }
            if let last = lastAttentionAt[record.key],
               now.timeIntervalSince(last) < config.attentionCooldownSeconds { return false }
            lastAttentionAt[record.key] = now
            return true
        case .goalEnded:
            return config.notifyOnConclusion
        case .concluded:
            guard config.notifyOnConclusion else { return false }
            if let last = lastConclusionAt[record.key],
               now.timeIntervalSince(last) < config.conclusionCooldownSeconds { return false }
            lastConclusionAt[record.key] = now
            return true
        default:
            return false
        }
    }

    private func needsKey(_ record: SessionRecord) -> String {
        record.snapshot.blockingDescription ?? "waiting"
    }

    private func isWatched(_ record: SessionRecord) -> Bool {
        let prefixes = record.sourceId == "local"
            ? (config.sources.first { $0.kind == .local }?.pathPrefixes ?? [])
            : (config.sources.first { $0.id == record.sourceId }?.pathPrefixes ?? [])
        guard !prefixes.isEmpty else { return true }
        return prefixes.contains { record.snapshot.cwd.hasPrefix($0) }
    }

    private func rank(_ record: SessionRecord) -> Int {
        // 等待确认最优先，其次运行中，再是按来源，最后已停下
        switch record.snapshot.act {
        case .waiting: return 0
        case .busy: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }

    // MARK: - 对外查询

    func record(withKey key: String) -> SessionRecord? {
        records.first { $0.key == key }
    }

    /// 企业微信回复时用它把「会话名 / 目录名」映射回具体会话
    func resolveSession(token: String) -> SessionRecord? {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        if let exact = records.first(where: { $0.snapshot.name.lowercased() == needle }) { return exact }
        if let keyed = records.first(where: { $0.key.lowercased() == needle }) { return keyed }
        if let partial = records.first(where: { $0.snapshot.name.lowercased().contains(needle) }) { return partial }
        return records.first { record in
            let dir = (record.snapshot.cwd as NSString).lastPathComponent.lowercased()
            return dir.contains(needle)
        }
    }

    var waitingRecords: [SessionRecord] {
        records.filter { $0.snapshot.act == .waiting }
    }

    var summaryLine: String {
        let waiting = waitingRecords.count
        if waiting > 0 { return "\(waiting) 个会话待确认" }
        let busy = records.filter { $0.snapshot.act == .busy }.count
        if busy > 0 { return "\(busy) 个会话运行中" }
        let online = sourceStates.values.filter { $0.isLive }.count
        return records.isEmpty ? "在线来源 \(online)/\(max(1, sourceConfigs.count))" : "全部空闲"
    }

    var badgeCount: Int { waitingRecords.count }

    /// 所有来源都断了
    var allSourcesDown: Bool {
        !sourceConfigs.isEmpty && sourceStates.values.allSatisfy { !$0.isLive }
    }

    var healthLine: String {
        let online = sourceConfigs.filter { sourceStates[$0.id]?.isLive == true }
        if sourceConfigs.isEmpty { return "未配置来源" }
        if online.count == sourceConfigs.count { return "全部来源在线（\(online.count)）" }
        let names = sourceConfigs.filter { sourceStates[$0.id]?.isLive != true }.map { $0.displayName }
        return "在线 \(online.count)/\(sourceConfigs.count)，离线：\(names.joined(separator: "、"))"
    }
}

// MARK: - 通知投递

/// 负责把 store 的判定变成真正的系统通知（带声音、可点击）
final class NotificationCenterBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterBridge()

    private var authorized = false

    func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // 测试实例只沿用已有的授权、不申请：改了 bundle id 的副本系统当成新 App，一申请就弹授权框
        guard !AppConfig.isolated else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.authorized = granted
            Log.write("通知授权：\(granted)\(error.map { " 错误：\($0.localizedDescription)" } ?? "")")
        }
    }

    func deliver(record: SessionRecord, transition: SessionTransition, config: AppConfig) {
        // 测试实例（CCPULSE_DRY_RUN）不往这台 Mac 弹系统通知：假会话的提醒会被当成真的（10-22 收到「出错已停止 · limit-demo」）。
        // 「提醒 …」那行日志在 AppState 里记，测试照样能断言
        guard !Delivery.dryRun else { return }
        let content = UNMutableNotificationContent()
        content.sound = config.playSound ? .default : nil
        let snapshot = record.snapshot

        switch transition {
        case .needsAttention(let reason):
            content.title = "需要确认 · \(snapshot.name)"
            content.subtitle = record.sourceName
            var lines = [reason]
            if let tool = snapshot.pendingTool, !tool.isEmpty, !reason.contains(tool) {
                lines.append("工具：\(tool)")
            }
            content.body = lines.joined(separator: "\n")
        case .concluded(let message):
            content.title = snapshot.error == nil ? "已完成 · \(snapshot.name)" : "出错已停止 · \(snapshot.name)"
            content.subtitle = record.sourceName
            content.body = snapshot.error?.display ?? message
        case .goalEnded(let goal):
            content.title = "\(L(GoalText.head(goal.state))) · \(snapshot.displayTitle)"
            content.subtitle = record.sourceName
            content.body = goal.pushBody(english: Lang.shared.isEnglish)
        default:
            return
        }

        content.userInfo = ["sessionKey": record.key, "sourceId": record.sourceId, "cwd": snapshot.cwd]
        content.threadIdentifier = record.key

        let identifier = "\(record.key)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { Log.write("通知投递失败：\(error.localizedDescription)") }
        }
    }

    /// 菜单里的「发送测试提醒」：确认系统通知和声音真的能到你面前
    func deliverTest(config: AppConfig) {
        let content = UNMutableNotificationContent()
        content.title = "Kiteline 测试提醒"
        content.body = "收到此通知（并听到提示音）即表示提醒通道正常。点击可展开面板。"
        content.sound = config.playSound ? .default : nil
        let request = UNNotificationRequest(identifier: "ccpulse-test-\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.write("测试通知失败：\(error.localizedDescription)")
            } else {
                Log.write("测试通知已投递")
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let key = info["sessionKey"] as? String
        DispatchQueue.main.async {
            AppState.shared.handleNotificationTap(sessionKey: key)
            completionHandler()
        }
    }
}
