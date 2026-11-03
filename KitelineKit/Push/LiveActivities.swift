#if !KITELINE_MAC
import ActivityKit
import Foundation

/// 实时活动（锁屏 + 灵动岛，排版在扩展 TARSLive）：开始、更新、结束都由电脑经推送来做（见 Sources/LiveActivities.swift），
/// App 没开也照样更新。App 这边只管两件事：把令牌报给电脑、照设置开关。
///
/// 令牌两种：「推送启动令牌」——电脑凭它在 App 没开时也能开一个实时活动；每个实时活动自己的更新令牌——凭它更新、结束。
/// 电脑开出来的实时活动，系统会在后台叫醒 App 一下，这里趁机把它的更新令牌报上去（activityUpdates）。
/// 用户在锁屏上划掉了，报给电脑「这个结束了」：电脑这一轮不再开新的，等会话都停下、下一轮干活时再开
@MainActor
final class LiveActivities {
    static let shared = LiveActivities()
    /// 设置里的开关（默认开）。推送内容是明文（会话标题和状态），设置页的说明里写清楚
    static let settingKey = "liveActivities"

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true }

    private weak var model: AppModel?
    private var startToken: String?
    /// 实时活动 id → 更新令牌
    private var tokens: [String: String] = [:]
    /// 上一次报给哪台电脑、报了什么：一样的不重复报（一分钟内）
    private var reported: (mark: String, at: Date)?
    private var started = false

    /// App 一启动就调（被电脑开实时活动叫醒时也走这里）：盯住两种令牌
    func start() {
        guard !started else { return }
        started = true
        Task {
            for await data in Activity<KitelineLiveAttributes>.pushToStartTokenUpdates {
                startToken = Self.hex(data)
                await report()
            }
        }
        Task {
            for await activity in Activity<KitelineLiveAttributes>.activityUpdates { watch(activity) }
        }
        for activity in Activity<KitelineLiveAttributes>.activities { watch(activity) }
    }

    /// 连上电脑了：对一下令牌
    func connected(_ model: AppModel) {
        self.model = model
        Task { await report() }
    }

    /// 设置里开关：关掉时把锁屏上的立即撤掉，并告诉电脑别再推
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.settingKey)
        Task {
            if !on {
                for activity in Activity<KitelineLiveAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            reported = nil
            await report()
        }
    }

    private func watch(_ activity: Activity<KitelineLiveAttributes>) {
        let id = activity.id
        Task {
            for await data in activity.pushTokenUpdates {
                tokens[id] = Self.hex(data)
                await report()
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                tokens[id] = nil
                await report(ended: id)
                break
            }
        }
    }

    /// 报给电脑：开没开、推送环境、语言（电脑按它生成锁屏上的字）、两种令牌；ended = 刚结束（被划掉）的那个
    private func report(ended: String? = nil) async {
        guard let api = model?.api, !Demo.active else { return }
        let on = enabled && ActivityAuthorizationInfo().areActivitiesEnabled
        var body: [String: Any] = ["enabled": on, "env": PushSetup.environment, "lang": Lang.shared.code]
        if on {
            if let startToken { body["startToken"] = startToken }
            body["activities"] = tokens.map { ["id": $0.key, "token": $0.value] }
        }
        if let ended { body["ended"] = ended }
        let mark = api.token + "|" + ((try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "")
        if ended == nil, let reported, reported.mark == mark, Date().timeIntervalSince(reported.at) < 60 { return }
        do {
            _ = try await api.post("/api/live/register", body: body)
            reported = (mark, Date())
        } catch {
            // 下次连上再报
        }
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
#endif
