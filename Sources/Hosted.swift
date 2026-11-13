import AppKit
import Foundation
import KitelineKit

/// 托管会话：新任务、恢复会话不开 VS Code，请项目所在电脑上的 watcher 在后台起 claude（本机项目、远端 Remote-SSH 项目都行）
/// （watcher/kiteline-watch.py 的 hosted_start：守护进程在伪终端里跑交互式 claude，SSH 断开、本机睡眠都不影响）。
/// 之后发消息、按键、关闭走 Delivery 里 tmux 那条路（watcher 写进伪终端），会话终端里的「claude」就是它原本的界面。
/// 那台电脑不支持（Windows）、找不到 claude、卡在要人操作的画面上时，NewSession 退回 VS Code。
/// 远端按设备开（设置 → 来源，SourceConfig.hostedOn），默认关：用户先检测这台的出口（probe），看过结果确认才开。
/// 本机默认开（MobileConfig.hostedLocal，11-13 起：平时不必开着 VS Code），同一个面板里能关、能检测出口。
/// 后台运行的 claude 和 VS Code 里的 Claude Code 用同一套网络设置（代理、证书、接口地址），watcher 起之前套上、起来后核对
enum Hosted {
    /// 这次新任务 / 恢复走不走后台（以配置里这台的开关为准：传进来的可能是开关改之前拿的）
    static func wanted(_ source: SourceConfig) -> Bool {
        guard source.kind != .kiteline, on(source.id), !Delivery.dryRun else { return false }
        // 本机还没连上 watcher、或它不支持时不试；刚确认过这台起不来（要人先到电脑上处理）的，过一阵再试
        if source.kind == .local, !supported(source.id) { return false }
        if let until = blocked[source.id]?.until, until > Date() { return false }
        return true
    }

    /// 这台开没开：远端看来源自己的开关，本机看 hostedLocal（默认开）
    static func on(_ sourceId: String) -> Bool {
        let config = AppState.shared.config
        guard let source = config.sources.first(where: { $0.id == sourceId }) else { return false }
        return source.kind == .local ? config.mobile.hostedLocal : source.hostedOn
    }

    /// 这个来源能不能后台运行：本机、SSH 远端，且那边的 watcher 支持（另一台 Kiteline 电脑上的由那台自己管）
    static func capable(_ source: SourceConfig) -> Bool {
        source.kind != .kiteline && supported(source.id)
    }

    /// 刚试过起不来、要用户先到那台电脑上处理的（停在登录、首次设置画面）：这段时间内的新任务直接开 VS Code，
    /// 不然每次都先白等几秒。改开关、检测出口时清掉（用户多半处理过了）
    private(set) static var blocked: [String: (until: Date, reason: String)] = [:]
    static let blockedFor: TimeInterval = 600

    /// 那台电脑能不能后台运行（不是 Windows、watcher 是有这功能的版本）
    static func supported(_ sourceId: String) -> Bool {
        AppState.shared.source(withId: sourceId)?.hostFeatures.contains("hosted") == true
    }

    /// 能转到后台运行的会话：本机或远端电脑上、在 VS Code 里跑的 Claude Code。会话页据此提示「当前会话支持后台托管」
    static func hostable(_ record: SessionRecord) -> Bool {
        let snap = record.snapshot
        return record.kind != .kiteline && snap.hosted == nil && snap.agentID == "claude-code" && snap.isVSCode
            && snap.readOnly != true && supported(record.sourceId)
    }

    /// VS Code 设置里给 Claude Code 配的环境变量：VS Code 里没有在运行的 Claude Code 时，watcher 照终端环境再叠上这些（只取网络相关的）
    static var netEnv: [String: String] {
        EditorSettings.claudeEnvironment(scheme: Delivery.Editor.running()?.scheme ?? "vscode")
    }

    /// 出口检测：本机和远端电脑（sourceId 给了只测那一台）照后台运行时的那套网络设置访问查 IP 的公共网址（不连 Claude），
    /// 回 [{id, name, source, settings, egress, error}]；离线、不支持的也列上
    static func probe(sourceId: String? = nil, completion: @escaping ([[String: Any]]) -> Void) {
        let sources = AppState.shared.config.sources.filter { $0.kind != .kiteline && $0.enabled && (sourceId == nil || $0.id == sourceId) }
        for source in sources { blocked[source.id] = nil }
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
            if state.config.sources[index].kind == .local {
                state.updatePreferences { $0.mobile.hostedLocal = on }
            } else {
                state.updatePreferences { $0.sources[index].hostedOn = on }
                state.store.applySourceConfigs(state.config.sources)
            }
            blocked[sourceId] = nil
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
    /// agent：别家命令行 agent（插件 id，见 /api/launchable）。它们没有 VS Code 那条路，起不来就直接报原因、不退回 VS Code
    static func start(source: SourceConfig, cwd: String, prompt: String, submit: Bool, sessionId: String?, agent: String? = nil,
                      accepted: ((NewSession.Outcome) -> Void)?,
                      completion: @escaping (Result<NewSession.Outcome, RemoteError>) -> Void) {
        guard let connection = AppState.shared.source(withId: source.id), connection.state.isLive else {
            completion(.failure(RemoteError("该机器当前离线"))); return
        }
        // 老版本 watcher 不认 agent：会照常起 Claude Code 还回成功，用户选的却是别家，先拦下
        if agent != nil, !connection.hostFeatures.contains("hosted_agents") {
            completion(.failure(RemoteError("HOSTED_UNSUPPORTED：该电脑上的 Kiteline 组件版本较旧，请更新后重试"))); return
        }
        if agent != nil, Delivery.dryRun {
            Log.write("[dry-run] 后台运行 \(agent ?? "")：\(source.displayName):\(cwd)\(sessionId.map { "，恢复 \($0)" } ?? "")：\(prompt.prefix(120))")
            completion(.success(NewSession.Outcome(ok: true, submitted: submit && !prompt.isEmpty, openedWindow: false, message: "dry-run"))); return
        }
        // netEnv：VS Code 设置里给 Claude Code 配的环境变量（VS Code 里没有在运行的 Claude Code 时，watcher 照终端环境再叠上它），
        // 和「检测出口」用的是同一份，检测到的出口才是实际运行时的。别家 agent 照用户开终端时的环境，不用它
        var payload: [String: Any] = ["cmd": "hosted_start", "cwd": cwd, "prompt": prompt, "submit": submit && !prompt.isEmpty,
                                      "netEnv": netEnv]
        if let sessionId { payload["sessionId"] = sessionId }
        if let agent { payload["agent"] = agent }
        Log.write("新会话：在 \(source.displayName) 后台运行 \(agent ?? "Claude Code")（\(cwd)）\(sessionId.map { "，恢复 \($0)" } ?? "")")
        var done = false
        if submit, !prompt.isEmpty, let accepted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                guard !done else { return }
                accepted(NewSession.Outcome(ok: true, submitted: true, openedWindow: false,
                                            message: agent == nil ? "正在后台启动 Claude Code，启动后将自动提交" : "正在后台启动，启动后将自动提交"))
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
                Log.write(agent == nil ? "新会话：后台启动失败（\(error.description)），改在 VS Code 中打开"
                                       : "新会话：后台启动 \(agent ?? "")失败（\(error.description)）")
                if agent == nil, error.description.contains("停在了需要操作的画面上") {
                    blocked[source.id] = (Date().addingTimeInterval(blockedFor), error.description)
                    Log.write("\(source.displayName)：后台运行暂停 \(Int(blockedFor / 60)) 分钟（Claude Code 停在要人操作的画面上），这期间的新任务直接在 VS Code 中打开")
                }
                completion(.failure(error))
            }
        }
    }

    /// 别家 agent 在后台起不来时给用户看的话：去掉内部前缀；老版本 watcher 不认 agent 的说清楚要更新
    static func agentFailure(_ error: RemoteError) -> String {
        let text = error.description
        if text.contains("未知请求") { return "该电脑上的 Kiteline 组件版本较旧，请更新后重试" }
        for prefix in ["HOSTED_UNSUPPORTED：", "HOSTED_NO_AGENT：", "HOSTED_ACCESS：", "HOSTED_NETWORK："] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    /// 新任务里能选的别家 agent（这台电脑上装着、插件给了后台启动的配方）。老版本 watcher、Windows 电脑返回空
    static func launchable(sourceId: String, completion: @escaping ([[String: Any]]) -> Void) {
        guard let connection = AppState.shared.source(withId: sourceId), connection.state.isLive,
              connection.hostFeatures.contains("hosted_agents") else { completion([]); return }
        connection.request(["cmd": "launchable"], timeout: 25) { result in
            guard case .success(let reply) = result, let agents = reply["agents"] as? [[String: Any]] else { completion([]); return }
            completion(agents)
        }
    }

    /// 退回 VS Code 时要不要告诉用户为什么：不支持、没装 claude、旧 watcher 的不说（本来就该开 VS Code），别的说一句
    static func fallbackNote(_ error: RemoteError) -> String? {
        let text = error.description
        // 网络检查没过（拿不到 VS Code 那边的网络设置、起来后核对不一致）：要告诉用户，出口不能悄悄换
        if text.hasPrefix("HOSTED_NETWORK：") { return "\(text.dropFirst("HOSTED_NETWORK：".count))，已改在 VS Code 中打开" }
        // 读不了项目文件夹（macOS 在等用户允许 Kiteline 访问「文稿」这类位置）：说清楚，用户回到电脑前点一次就好
        if text.hasPrefix("HOSTED_ACCESS：") { return "\(text.dropFirst("HOSTED_ACCESS：".count))，已改在 VS Code 中打开" }
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
