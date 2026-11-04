import AppKit
import Foundation
import KitelineKit

/// 托管会话：远端（Remote-SSH）项目的新任务、恢复会话不开 VS Code，请那台电脑上的 watcher 在后台起 claude
/// （watcher/kiteline-watch.py 的 hosted_start：守护进程在伪终端里跑交互式 claude，SSH 断开、本机睡眠都不影响）。
/// 之后发消息、按键、关闭走 Delivery 里 tmux 那条路（watcher 写进伪终端），会话终端里的「claude」就是它原本的界面。
/// 那台电脑不支持（Windows）、找不到 claude、卡在要人操作的画面上时，NewSession 退回 VS Code。
/// 按设备开（设置 → 来源，SourceConfig.hostedOn），默认关：用户先检测这台的出口（probe），看过结果确认才开。
/// 后台运行的 claude 和 VS Code 里的 Claude Code 用同一套网络设置（代理、证书、接口地址），watcher 起之前套上、起来后核对
enum Hosted {
    /// 这次新任务 / 恢复走不走后台（以配置里这台的开关为准：传进来的可能是开关改之前拿的）
    static func wanted(_ source: SourceConfig) -> Bool {
        source.kind == .ssh && on(source.id) && !Delivery.dryRun
    }

    static func on(_ sourceId: String) -> Bool {
        AppState.shared.config.sources.first { $0.id == sourceId }?.hostedOn == true
    }

    /// 那台电脑能不能后台运行（不是 Windows、watcher 是有这功能的版本）
    static func supported(_ sourceId: String) -> Bool {
        AppState.shared.source(withId: sourceId)?.hostFeatures.contains("hosted") == true
    }

    /// 能转到后台运行的会话：远端电脑上、在 VS Code 里跑的 Claude Code。会话页据此提示「当前会话支持后台托管」
    static func hostable(_ record: SessionRecord) -> Bool {
        let snap = record.snapshot
        return record.kind == .ssh && snap.hosted == nil && snap.agentID == "claude-code" && snap.isVSCode
            && snap.readOnly != true && supported(record.sourceId)
    }

    /// VS Code 设置里给 Claude Code 配的环境变量：VS Code 里没有在运行的 Claude Code 时，watcher 照终端环境再叠上这些（只取网络相关的）
    static var netEnv: [String: String] {
        EditorSettings.claudeEnvironment(scheme: Delivery.Editor.running()?.scheme ?? "vscode")
    }

    /// 出口检测：远端电脑（sourceId 给了只测那一台）照后台运行时的那套网络设置访问查 IP 的公共网址（不连 Claude），
    /// 回 [{id, name, source, settings, egress, error}]；离线、不支持的也列上
    static func probe(sourceId: String? = nil, completion: @escaping ([[String: Any]]) -> Void) {
        let sources = AppState.shared.config.sources.filter { $0.kind == .ssh && $0.enabled && (sourceId == nil || $0.id == sourceId) }
        var results = [[String: Any]?](repeating: nil, count: sources.count)
        let group = DispatchGroup()
        let env = netEnv
        for (index, source) in sources.enumerated() {
            var item: [String: Any] = ["id": source.id, "name": source.displayName]
            guard let connection = AppState.shared.source(withId: source.id), connection.state.isLive else {
                item["error"] = "该机器当前离线，未检测"; results[index] = item; continue
            }
            guard connection.hostFeatures.contains("hosted") else {
                item["error"] = "这台电脑暂不支持在后台运行 Claude Code"; results[index] = item; continue
            }
            group.enter()
            connection.request(["cmd": "hosted_probe", "netEnv": env], timeout: 90) { result in
                switch result {
                case .success(let reply):
                    for key in ["source", "settings", "egress"] { item[key] = reply[key] }
                case .failure(let error):
                    item["error"] = error.description.replacingOccurrences(of: "HOSTED_NETWORK：", with: "")
                        .replacingOccurrences(of: "HOSTED_UNSUPPORTED：", with: "")
                }
                results[index] = item
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Log.write("出口检测：" + results.compactMap { item in
                guard let item else { return nil }
                let egress = item["egress"] as? [String: Any]
                return "\(item["name"] ?? "?")=\(egress?["ip"] as? String ?? (item["error"] as? String ?? "未查到"))"
            }.joined(separator: "，"))
            completion(results.compactMap { $0 })
        }
    }

    /// 开 / 关某台的后台运行、「不再提示」（各端的设置页、会话页提示都走这里）。只改开关，不重连这台
    static func update(sourceId: String? = nil, on: Bool? = nil, tipOff: Bool? = nil) {
        let state = AppState.shared
        if let sourceId, let on, let index = state.config.sources.firstIndex(where: { $0.id == sourceId }) {
            state.updatePreferences { $0.sources[index].hostedOn = on }
            state.store.applySourceConfigs(state.config.sources)
            Log.write("\(state.config.sources[index].displayName)：后台运行 Claude Code \(on ? "已开启（检测过出口、用户确认）" : "已关闭")")
        }
        if let tipOff {
            state.updatePreferences { $0.mobile.hostedTipOff = tipOff }
            if tipOff { Log.write("「支持后台运行 Claude Code」的提示：用户选了不再提示") }
        }
        KitelineModel.shared.refresh()
    }

    /// 把 VS Code 里正开着的会话转到后台运行：先请 watcher 接手（照这个会话自己的网络设置、等它退出），再关掉 VS Code 里的标签；
    /// watcher 等那边的 claude 退出后在后台接着这段对话。Claude 正在工作、等确认时不转
    static func moveToBackground(record: SessionRecord, completion: @escaping (NewSession.Outcome) -> Void) {
        let snap = record.snapshot
        func fail(_ message: String) { completion(.init(ok: false, submitted: false, openedWindow: false, message: message)) }
        guard hostable(record), let connection = AppState.shared.source(withId: record.sourceId), connection.state.isLive else {
            fail("此会话无法转到后台运行"); return
        }
        if snap.act == .busy || snap.act == .waiting {
            fail("Claude 正在处理这个会话。为免打断，请在这一轮完成后再转到后台运行"); return
        }
        Log.write("会话「\(snap.name)」转到后台运行：先关掉 VS Code 中的标签，watcher 接着这段对话")
        let payload: [String: Any] = ["cmd": "hosted_start", "cwd": snap.cwd, "prompt": "", "submit": false,
                                      "sessionId": snap.sessionId, "takeOver": true, "netEnv": netEnv]
        connection.request(payload, timeout: 90) { result in
            switch result {
            case .success:
                completion(.init(ok: true, submitted: false, openedWindow: false, message: "已转到后台运行"))
            case .failure(let error):
                Log.write("转到后台运行未成功：\(error.description)")
                fail("未能转到后台运行：\(error.description.replacingOccurrences(of: "HOSTED_NETWORK：", with: ""))")
            }
        }
        // 请求先到（watcher 先记下这个会话的网络设置），再关 VS Code 里的标签；没关掉的话 watcher 等 25 秒后报「没有关闭」。
        // 测试实例（CCPULSE_TEST_NO_EDITOR=1）不碰用户屏幕上的 VS Code：由测试脚本自己结束那边的会话
        if ProcessInfo.processInfo.environment["CCPULSE_TEST_NO_EDITOR"] == "1" { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Delivery.close(record: record, source: connection) { outcome in
                if !outcome.ok { Log.write("转到后台运行：关闭 VS Code 中的标签未成功：\(outcome.message)") }
            }
        }
    }

    /// 起来了回 .success；起不来回 .failure（调用方改开 VS Code）。
    /// accepted：要自动提交、6 秒还没起来时先回一声（手机那边的请求只等 12 秒；一般两三秒就好）
    static func start(source: SourceConfig, cwd: String, prompt: String, submit: Bool, sessionId: String?,
                      accepted: ((NewSession.Outcome) -> Void)?,
                      completion: @escaping (Result<NewSession.Outcome, RemoteError>) -> Void) {
        guard let connection = AppState.shared.source(withId: source.id), connection.state.isLive else {
            completion(.failure(RemoteError("该机器当前离线"))); return
        }
        var payload: [String: Any] = ["cmd": "hosted_start", "cwd": cwd, "prompt": prompt, "submit": submit && !prompt.isEmpty]
        if let sessionId { payload["sessionId"] = sessionId }
        Log.write("新会话：在 \(source.displayName) 后台运行 Claude Code（\(cwd)）\(sessionId.map { "，恢复 \($0)" } ?? "")")
        var done = false
        if submit, !prompt.isEmpty, let accepted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                guard !done else { return }
                accepted(NewSession.Outcome(ok: true, submitted: true, openedWindow: false, message: "正在后台启动 Claude Code，启动后将自动提交"))
            }
        }
        connection.request(payload, timeout: 70) { result in
            done = true
            switch result {
            case .success(let reply):
                let submitted = reply["submitted"] as? Bool ?? false
                // 整句写出来，英文按整句查表
                let message: String
                if prompt.isEmpty {
                    message = sessionId == nil ? "已在后台新建会话" : "已在后台恢复对话"
                } else if submitted {
                    message = sessionId == nil ? "已在后台新建会话并提交" : "已在后台恢复对话并提交"
                } else {
                    message = sessionId == nil ? "已在后台新建会话，内容已填入输入框" : "已在后台恢复对话，内容已填入输入框"
                }
                Log.write("新会话：后台会话 \(reply["hosted"] as? String ?? "?") 已就绪（\(reply["sessionId"] as? String ?? "")）")
                completion(.success(NewSession.Outcome(ok: true, submitted: submitted, openedWindow: false, message: message)))
            case .failure(let error):
                Log.write("新会话：后台启动失败（\(error.description)），改在 VS Code 中打开")
                completion(.failure(error))
            }
        }
    }

    /// 退回 VS Code 时要不要告诉用户为什么：不支持、没装 claude、旧 watcher 的不说（本来就该开 VS Code），别的说一句
    static func fallbackNote(_ error: RemoteError) -> String? {
        let text = error.description
        // 网络检查没过（拿不到 VS Code 那边的网络设置、起来后核对不一致）：要告诉用户，出口不能悄悄换
        if text.hasPrefix("HOSTED_NETWORK：") { return "\(text.dropFirst("HOSTED_NETWORK：".count))，已改在 VS Code 中打开" }
        if text.hasPrefix("HOSTED_") || text.contains("未知请求") || text.contains("离线") { return nil }
        return "后台启动未成功：\(text.split(separator: "\n").first.map(String.init) ?? text)，已改在 VS Code 中打开"
    }

    /// 「在 VS Code 中打开」后台运行的会话：同一段对话不能两个进程一起写，所以 Claude 空闲时先结束后台这份、
    /// 再在 VS Code 里接着这段对话；正在工作、等确认时不打断，提醒这一轮完成后再点
    static func handOver(record: SessionRecord, source: SourceConfig) {
        let snap = record.snapshot
        guard let connection = AppState.shared.source(withId: source.id), connection.state.isLive else {
            Actions.notifyUser(title: L("无法在 VS Code 中打开"), body: L("该机器当前离线")); return
        }
        if snap.activity == "busy" || snap.activity == "waiting" {
            Actions.notifyUser(title: L("会话正在后台运行"),
                               body: L("Claude 正在处理这个会话。为免打断，请在这一轮完成后再点击「在 VS Code 中打开」，届时会转到 VS Code 中继续。"))
            return
        }
        Log.write("后台会话 \(snap.name) 转到 VS Code：先结束后台运行的 claude")
        // ifIdle：快照里的状态晚一两秒，watcher 再看一眼界面，Claude 刚开始干活的也不停
        connection.request(["cmd": "hosted_stop", "sessionId": snap.sessionId, "ifIdle": true], timeout: 20) { result in
            if case .success(let reply) = result, reply["busy"] as? Bool == true {
                Actions.notifyUser(title: L("会话正在后台运行"),
                                   body: L("Claude 正在处理这个会话。为免打断，请在这一轮完成后再点击「在 VS Code 中打开」，届时会转到 VS Code 中继续。"))
                return
            }
            guard case .success(let reply) = result, reply["stopped"] as? Bool == true else {
                let why: String
                if case .failure(let error) = result { why = error.description } else { why = "后台会话没有按时结束" }
                Actions.notifyUser(title: L("无法在 VS Code 中打开"), body: ServerLang.ui(why)); return
            }
            NewSession.start(source: source, cwd: snap.cwd, prompt: "", submit: false, sessionId: snap.sessionId, inEditor: true) { outcome in
                if !outcome.ok { Actions.notifyUser(title: L("无法在 VS Code 中打开"), body: ServerLang.ui(outcome.message)) }
            }
        }
    }
}
