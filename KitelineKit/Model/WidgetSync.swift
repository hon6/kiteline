#if !KITELINE_MAC
import SwiftUI
import WidgetKit

/// 把 App 里的会话、额度、今日用量写成小组件用的摘要（WidgetSnapshot），内容变了才写、才叫小组件重画。
/// 小组件不自己联网：App 开着时跟着实时数据走，退到后台时再写一次；后台收到推送由通知扩展改对应会话（WidgetSnapshot.applyPush）
@MainActor
enum WidgetSync {
    private static var last: WidgetSnapshot?
    private static var savedAt = Date.distantPast
    private static var pending: Task<Void, Never>?

    /// 摘要（at 先填 0，写的时候再盖时间，比较内容变没变时不算它）
    static func snapshot(_ model: AppModel) -> WidgetSnapshot {
        let sessions = model.sessions
        let rows = sessions.map { s -> WidgetSnapshot.Row in
            let state = s.isWaiting ? "waiting" : s.error != nil ? "error" : s.isBusy ? "busy" : model.isUnread(s) ? "unread" : "idle"
            let detail: String? = switch state {
            case "waiting": s.blocking ?? s.reason
            case "error": s.error
            case "busy": s.activityText
            default: s.preview.map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            }
            return WidgetSnapshot.Row(key: s.key, title: s.title, agent: s.agent, state: state,
                                      detail: detail.map { String($0.prefix(80)) }, updatedAt: s.updatedAt)
        }
        // 要紧的在前，同级按最近活动
        .sorted { a, b in
            let ra = WidgetSnapshot.rank(a.state), rb = WidgetSnapshot.rank(b.state)
            return ra != rb ? ra > rb : (a.updatedAt ?? 0) > (b.updatedAt ?? 0)
        }
        let limits = model.home.limits.flatMap { device in
            device.agents.compactMap { agent -> WidgetSnapshot.Limit? in
                let windows = agent.windows.filter { $0.kind != "spend_limit" }.map {
                    WidgetSnapshot.Window(label: $0.label, percent: $0.percent, resetsAt: $0.resetsAt)
                }
                guard !windows.isEmpty else { return nil }
                return WidgetSnapshot.Limit(agent: agent.agent, name: Agents.info(agent.agent).name, device: device.name,
                                            plan: agent.plan, windows: windows)
            }
        }
        let usage = model.home.usage
        return WidgetSnapshot(at: 0, host: model.host, lang: Lang.shared.code,
                              total: sessions.count, waiting: sessions.filter(\.isWaiting).count, busy: sessions.filter(\.isBusy).count,
                              sessions: Array(rows.prefix(8)),
                              tokens: usage.map(\.tokens), cost: usage.flatMap { $0.unpriced ? nil : $0.cost },
                              limits: limits)
    }

    /// 内容变了就写（正在干活的会话每秒都在变那句「正在 …」：这种只变文字的 20 秒内最多写一次；
    /// 数目、状态、额度变了马上写）。force：退到后台时盖一次时间
    static func update(_ model: AppModel, force: Bool = false) {
        guard model.connected || force, !MacStore.shared.isDemo || isSnapshotBuild else { return }
        var next = snapshot(model)
        guard force || next != last else { return }
        let urgent = force || last.map { shape($0) != shape(next) } ?? true
        let wait = urgent ? 0 : max(0, 20 - Date().timeIntervalSince(savedAt))
        pending?.cancel()
        pending = Task { @MainActor in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            next.at = Date().timeIntervalSince1970 * 1000
            last = next
            savedAt = Date()
            next.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
        last = next
    }

    /// 断开配对、进演示模式：清掉，小组件回到「打开 Kiteline」
    static func clear() {
        last = nil
        WidgetSnapshot.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 不算文字的样子：会话和状态、计数、额度百分比取整
    private static func shape(_ s: WidgetSnapshot) -> String {
        s.sessions.map { "\($0.key)=\($0.state)" }.joined(separator: ",") + "|\(s.total)/\(s.waiting)/\(s.busy)|"
            + s.limits.map { $0.windows.map { "\(Int($0.percent))" }.joined(separator: ",") }.joined(separator: ";")
            + "|\(Int((s.tokens ?? 0) / 10000))"
    }

    private static var isSnapshotBuild: Bool {
        #if SNAPSHOT
        true
        #else
        false
        #endif
    }
}

/// 挂在主界面上：会话、额度、用量一变就交给 WidgetSync（只这个小视图跟着重算，不牵动整页）
struct WidgetProbe: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = WidgetSync.snapshot(model)
        Color.clear.onChange(of: snapshot, initial: true) { _, _ in WidgetSync.update(model) }
    }
}
#endif
