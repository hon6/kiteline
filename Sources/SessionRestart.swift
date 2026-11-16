import Foundation
import KitelineKit

/// 重启会话（11-16 用户要的）：关掉再用同一个会话 id 接着聊，对话不丢；agent 重新读设置、技能、MCP
/// （比如新装的 Kiteline 浏览器技能、Playwright MCP 连 Kiteline 浏览器的环境变量，老会话要重启才用得上）。
/// 空闲的马上重启；正在工作 / 等你确认的不打断，等这一轮做完（变空闲）再自动重启。
/// 原来在 VS Code 里的还在 VS Code 里接着；后台运行的还在后台；别家 agent 用它插件的启动配方接着
final class SessionRestart {
    static let shared = SessionRestart()

    struct Result {
        var restarted: [String] = []
        var queued: [String] = []
        var failed: [(key: String, error: String)] = []
    }

    /// 等着变空闲再重启的会话
    private var pending: Set<String> = []
    private var timer: Timer?

    /// 主线程调
    func restart(keys: [String], completion: @escaping (Result) -> Void) {
        var result = Result()
        let group = DispatchGroup()
        for key in keys {
            guard let record = AppState.shared.store.record(withKey: key) else {
                result.failed.append((key, L("会话不存在或已结束"))); continue
            }
            if record.snapshot.act == .busy || record.snapshot.act == .waiting {
                pending.insert(key)
                result.queued.append(key)
                continue
            }
            group.enter()
            perform(record) { error in
                if let error { result.failed.append((key, error)) } else { result.restarted.append(key) }
                group.leave()
            }
        }
        if !pending.isEmpty { watch() }
        group.notify(queue: .main) { completion(result) }
    }

    /// 正在工作的：每 3 秒看一眼，做完了（空闲）就重启；会话没了（被关掉）就不管了
    private func watch() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            for key in self.pending {
                guard let record = AppState.shared.store.record(withKey: key) else { self.pending.remove(key); continue }
                guard record.snapshot.act == .idle || record.snapshot.act == .unknown else { continue }
                self.pending.remove(key)
                self.perform(record) { error in
                    if let error {
                        AppState.shared.mobile.notify(kind: "error", title: record.snapshot.displayTitle, body: L("重启会话未成功：%@", error), key: key)
                    }
                }
            }
            if self.pending.isEmpty { self.timer?.invalidate(); self.timer = nil }
        }
    }

    func isPending(_ key: String) -> Bool { pending.contains(key) }

    /// 关掉 → 等它真的结束 → 用同一个会话 id 接着
    private func perform(_ record: SessionRecord, completion: @escaping (String?) -> Void) {
        let key = record.key
        let snap = record.snapshot
        guard let source = AppState.shared.source(withId: record.sourceId),
              let sourceConfig = AppState.shared.config.sources.first(where: { $0.id == record.sourceId }) else {
            completion(L("会话所在的电脑没连上")); return
        }
        let cwd = snap.cwd
        guard !cwd.isEmpty else { completion(L("未找到该会话的工作目录")); return }
        let hosted = (snap.hosted ?? "").isEmpty == false
        Log.write("重启会话「\(snap.name)」（\(hosted ? "后台运行" : "VS Code")）")
        Delivery.close(record: record, source: source) { outcome in
            guard outcome.ok else { completion(outcome.message); return }
            // 等它真的结束（watcher 报上来要一两秒；VS Code 关标签后 Claude 退出要几秒），最多 30 秒
            let deadline = Date().addingTimeInterval(30)
            func reopen() {
                if AppState.shared.store.record(withKey: key) != nil, Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: reopen); return
                }
                if let agent = snap.agent, !agent.isEmpty, agent != "claude-code" {
                    MobileServer.startAgent(sourceConfig, cwd: cwd, prompt: "", submit: false, sessionId: snap.sessionId, agent: agent,
                                            accepted: { _ in }, completion: { done in completion(done.ok ? nil : done.message) })
                    return
                }
                // 原来在 VS Code 里的还在 VS Code 里接着，后台运行的还在后台（别因为「本机默认后台运行」把它挪了地方）
                NewSession.start(source: sourceConfig, cwd: cwd, prompt: "", submit: false, sessionId: snap.sessionId,
                                 inEditor: !hosted) { done in completion(done.ok ? nil : done.message) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: reopen)
        }
    }
}
