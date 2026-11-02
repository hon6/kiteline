import AppKit
import Foundation
import KitelineKit

/// 全局状态容器：持有配置、所有来源连接和会话判定中枢，供 UI 与通知回调共用。
final class AppState {
    static let shared = AppState()

    private(set) var config: AppConfig
    private(set) var store: SessionStore
    private var sources: [String: SourceConnection] = [:]

    var onStoreUpdate: ((SessionStore) -> Void)?
    var onConfigChange: ((AppConfig) -> Void)?

    /// 手机端服务（网页 App + API）
    private(set) var mobile: MobileServer

    /// 各台机器的 CPU、内存、网速（来源 id → watcher 每 5 秒报的那条 sys）。变得太勤，不放进 state（不然整份会话列表
    /// 每 5 秒重推一次）：GET /api/state 时附上一份，之后的变化单独以 sys 事件推。来源断开就清掉（主线程）
    private(set) var machineStats: [String: [String: Any]] = [:]

    private init() {
        let config = AppConfig.load()
        self.config = config
        self.store = SessionStore(config: config)
        self.mobile = MobileServer(config: config.mobile)
        AgentSkill.enabled = config.mobile.installAgentSkill
        AgentSkill.testEnabled = config.mobile.installTestSkill
        AgentSkill.todoEnabled = config.mobile.installTodoSkill
        AgentSkill.stageEnabled = config.mobile.installStageSkill
        AgentSkill.openCodePlugin = config.mobile.installOpenCodePlugin
        store.delegate = self
        mobile.onClientsChange = { [weak self] in
            guard let self = self else { return }
            self.onStoreUpdate?(self.store)
        }
    }

    // MARK: - 生命周期

    func start() {
        guard claimSingleInstance() else {
            // 两个实例会抢同一个手机端口：本次不启动。不弹框（脚本、登录项在后台拉起时没人点「好」，框一直挂在屏幕上），
            // 把已经在跑的那个叫到前台就行
            Log.write("已有另一个 Kiteline 实例在运行，本次启动退出（两个实例会抢同一个手机端口）")
            if !CommandLine.arguments.contains("--background"),
               let text = try? String(contentsOf: AppConfig.directoryURL.appendingPathComponent("instance.pid"), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            exit(0)
        }
        LocalNetwork.startMonitoring()
        NotificationCenterBridge.shared.bootstrap()
        rebuildSources()
        if config.connectOnLaunch {
            sources.values.forEach { $0.start() }
        }
        mobile.start()
        PluginStore.shared.start()   // Agent 插件：定时查官方索引，自动更新在用的插件
        // 远程访问（点对点）。测试实例（dry-run、另一个配置目录）默认不开，免得自测时也去连中继；测远程访问时设 CCPULSE_P2P=1
        let env = ProcessInfo.processInfo.environment
        let testInstance = env["CCPULSE_DRY_RUN"] != nil || env["CCPULSE_CONFIG_DIR"] != nil
        if config.mobile.enabled, config.mobile.remoteEnabled, !testInstance || env["CCPULSE_P2P"] == "1" {
            P2P.shared.start(relay: config.mobile.effectiveRelay, httpsPort: config.mobile.effectiveHTTPSPort)
        }
        DailyReport.shared.start()
        BudgetWatch.shared.start()
        Scheduler.shared.start()
        WaitingReminder.shared.start()
        StuckWatch.shared.start()
        // 24 小时没在 Kiteline 里打开过详情的会话：自动关掉，进历史会话（见 IdleClose.swift）
        IdleClose.shared.start()
        // VS Code 弹着对话框、到某台机器的连接断了：告诉手机，能重连的给「尝试重连」
        EditorAlerts.shared.start()
        // 手机「按住说话」要用 Mac 的语音识别：启动时就把授权弹窗弹出来，免得第一次说话时卡在等授权。
        // 测试实例不提前要：改了 bundle id 的副本系统当成新 App，每起一个就弹一次（真转写时 Transcriber 自己会再要）
        if config.mobile.enabled, !testInstance { Transcriber.requestIfNeeded() }
        // 用过「按住说话」的（普通话）：启动就在后台把本机识别模型下好（约 1 GB，下过就跳过）；测试实例不下
        if config.mobile.enabled, config.mobile.voiceLocale == "zh-CN",
           ProcessInfo.processInfo.environment["CCPULSE_CONFIG_DIR"] == nil,
           FileManager.default.fileExists(atPath: VoiceStore.directory.path) {
            LocalASR.prepare()
        }
    }

    func reconnect() {
        sources.values.forEach { $0.stop() }
        sources.removeAll()
        rebuildSources()
        sources.values.forEach { $0.start() }
    }

    /// 插件变了：各来源换个 watcher 进程载入，会话照旧显示、不报离线（SourceConnection.reload）；来源有增减就整个重连
    func reloadWatchers() {
        let enabled = config.sources.filter { $0.enabled }
        guard Set(enabled.map { $0.id }) == Set(sources.keys) else { reconnect(); return }
        enabled.forEach { sources[$0.id]?.reload() }
    }

    /// 用 pid 文件做单实例判断；上一个实例异常退出时（pid 已不存在）会接管
    private func claimSingleInstance() -> Bool {
        let lockURL = AppConfig.directoryURL.appendingPathComponent("instance.pid")
        try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
        if let text = try? String(contentsOf: lockURL, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0, pid != getpid() {
            if kill(pid, 0) == 0 || errno == EPERM {
                return false
            }
        }
        try? "\(getpid())".write(to: lockURL, atomically: true, encoding: .utf8)
        return true
    }

    func shutdown() {
        sources.values.forEach { $0.stop() }
        sources.removeAll()
        mobile.stop()
    }

    func apply(newConfig: AppConfig) {
        config = newConfig
        config.save()
        AgentSkill.enabled = newConfig.mobile.installAgentSkill
        AgentSkill.testEnabled = newConfig.mobile.installTestSkill
        AgentSkill.todoEnabled = newConfig.mobile.installTodoSkill
        AgentSkill.stageEnabled = newConfig.mobile.installStageSkill
        AgentSkill.openCodePlugin = newConfig.mobile.installOpenCodePlugin
        mobile.update(config: newConfig.mobile)
        // 端口、令牌可能变了：主窗口的原生对话页跟着重连（没变时什么也不做）
        DispatchQueue.main.async { NativeConversation.setUp() }
        store.config = newConfig
        store.applySourceConfigs(newConfig.sources)
        onConfigChange?(newConfig)
        reconnect()
    }

    func reloadConfigFromDisk() {
        apply(newConfig: AppConfig.load())
    }

    func openConfigFile() {
        let url = AppConfig.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            config.save()
        }
        NSWorkspace.shared.open(url)
    }

    func delegateRefresh() {
        onStoreUpdate?(store)
    }

    // MARK: - 来源

    private func rebuildSources() {
        for sourceConfig in config.sources where sourceConfig.enabled {
            let connection: SourceConnection
            switch sourceConfig.kind {
            case .local:
                connection = LocalSource(config: sourceConfig)
            case .ssh:
                connection = RemoteSession(config: sourceConfig)
            }
            connection.delegate = self
            sources[sourceConfig.id] = connection
            store.apply(sourceConfig: sourceConfig, state: .stopped)
        }
    }

    func source(withId id: String) -> SourceConnection? { sources[id] }

    /// 在线的来源（今日动态要逐个去问）
    var liveSources: [SourceConnection] {
        config.sources.compactMap { sources[$0.id] }.filter { $0.state.isLive }
    }

    /// 手动往某个来源部署 watcher（仅 SSH 来源有意义）
    func redeployWatcher(on sourceId: String) {
        (sources[sourceId] as? RemoteSession)?.deployWatcherForcibly()
    }

    /// 菜单/面板用的一行手机端状态
    var mobileStatusLine: String {
        guard config.mobile.enabled else { return "手机访问已关闭" }
        let count = mobile.clientCount
        return count > 0 ? "已连接 \(count) 台手机" : "手机未连接（端口 \(config.mobile.effectiveHTTPSPort)）"
    }

    /// 只改偏好（提醒、发送方式、识别语言…）：保存并生效，不重连来源
    func updatePreferences(_ mutate: (inout AppConfig) -> Void) {
        var next = config
        mutate(&next)
        config = next
        config.save()
        store.config = next
        AgentSkill.enabled = next.mobile.installAgentSkill
        AgentSkill.testEnabled = next.mobile.installTestSkill
        AgentSkill.todoEnabled = next.mobile.installTodoSkill
        AgentSkill.stageEnabled = next.mobile.installStageSkill
        AgentSkill.openCodePlugin = next.mobile.installOpenCodePlugin
        mobile.update(config: next.mobile)
        mobile.publishState()   // 快捷短语等设置要同步到已连着的手机
        onConfigChange?(next)
    }

    /// 添加 Remote-SSH 来源：先确认能免密 ssh 过去
    func addSSHSource(host: String, name: String, completion: @escaping (Result<Void, RemoteError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new",
                                 host, "command -v python3 >/dev/null && echo TARS_OK"]
            let pipe = Pipe(), errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice
            var output = "", errors = ""
            do {
                try process.run()
                process.waitUntilExit()
                output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                errors = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            } catch {
                errors = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard output.contains("TARS_OK") else {
                    let reason = errors.split(separator: "\n").last.map(String.init)
                        ?? (process.terminationStatus == 0 ? "远端未安装 python3" : "ssh 退出码 \(process.terminationStatus)")
                    completion(.failure(RemoteError(reason)))
                    return
                }
                var next = self.config
                next.sources.removeAll { $0.id == "ssh:\(host)" }
                next.sources.append(.ssh(host: host, name: name.isEmpty ? nil : name))
                self.apply(newConfig: next)
                Log.write("已添加来源：\(host)")
                completion(.success(()))
            }
        }
    }

    func setSource(_ id: String, enabled: Bool) {
        var next = config
        guard let index = next.sources.firstIndex(where: { $0.id == id }) else { return }
        next.sources[index].enabled = enabled
        apply(newConfig: next)
    }

    /// 改来源的显示名（清空 = 用默认名：本机 / 主机名）。手机上、会话里的来源名都跟着变
    func renameSource(_ id: String, to name: String) {
        var next = config
        guard let index = next.sources.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next.sources[index].name != trimmed else { return }
        next.sources[index].name = trimmed
        apply(newConfig: next)
    }

    func removeSource(_ id: String) {
        var next = config
        next.sources.removeAll { $0.id == id }
        apply(newConfig: next)
    }

    /// 排障用的一份完整状态
    func diagnostics() -> String {
        var lines: [String] = ["Kiteline \(AppVersion.app) · 观察器 \(AppVersion.watcherScriptVersion)", "来源：\(store.healthLine)", ""]
        lines.append("== 来源 ==")
        for (source, linkState) in sourceSummaries {
            lines.append("• \(source.displayName)（\(source.kind == .local ? "本机" : "ssh \(source.sshHost ?? "")")）→ \(linkState.shortLabel)")
            if let remote = sources[source.id] as? RemoteSession { lines.append("    \(remote.debugCommandLine)") }
        }
        lines.append("")
        lines.append("== 手机访问 ==")
        lines.append("服务：\(mobile.statusText) · HTTPS：\(mobile.secureStatus) · \(mobileStatusLine)")
        lines.append("推送订阅：\(mobile.push.subscriptions.count) · 辅助功能：\(AXIsProcessTrusted() ? "已授权" : "未授权") · 语音识别：\(Transcriber.status)")
        lines.append("")
        lines.append("== 会话（\(store.records.count)）==")
        for record in store.records {
            let s = record.snapshot
            lines.append("• [\(record.sourceName)] \(s.displayTitle)（\(s.name)）[\(s.act.label)] \(s.cwdShort) · \(s.entrypoint ?? "?")")
            if let reason = s.blockingDescription { lines.append("    等待：\(reason)") }
        }
        lines.append("")
        lines.append("== 日志尾部 ==")
        lines.append(Log.tail(60))
        return lines.joined(separator: "\n")
    }

    /// 重置配对令牌：所有已配对的手机都要重新配对
    func resetMobileToken() {
        var next = config
        next.mobile.token = MobileConfig.makeToken()
        DeviceStore.shared.revokeAll()
        mobile.disconnectAll()
        apply(newConfig: next)
        Log.write("已重置手机配对令牌")
    }

    var sourceSummaries: [(config: SourceConfig, state: LinkState)] {
        config.sources.map { ($0, sources[$0.id]?.state ?? .stopped) }
    }

    // MARK: - 通知点击

    func handleNotificationTap(sessionKey: String?) {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .ccpulseShowPanel, object: nil,
                                        userInfo: sessionKey.map { ["sessionKey": $0] } ?? [:])
    }

    // MARK: - 回复路由（Mac 面板上的回复框）

    /// 面板回复框：精确投递到会话所在窗口，只预填不提交（面板上还能再看一眼）
    func sendReply(_ text: String, to record: SessionRecord, completion: @escaping (Delivery.Outcome) -> Void) {
        Delivery.send(text: text, attachments: [], to: record, source: sources[record.sourceId],
                      submit: false, completion: completion)
    }

    /// 只发一个回车（用于接受确认）
    func sendEnter(to record: SessionRecord, completion: @escaping (Delivery.Outcome) -> Void) {
        Delivery.press(key: "enter", record: record, source: sources[record.sourceId], completion: completion)
    }

    func jumpToWorkspace(for record: SessionRecord) {
        Actions.jumpToWorkspace(record: record, config: config)
    }

    // MARK: - 手机端数据

    /// 手机上会话列表需要的全部数据
    func mobileStatePayload() -> [String: Any] {
        let sessions: [[String: Any]] = store.records.map { record in
            let snap = record.snapshot
            var item: [String: Any] = [
                "key": record.key,
                "sessionId": snap.sessionId,
                "sourceId": record.sourceId,
                "sourceName": record.sourceName,
                "sourceKind": record.kind.rawValue,
                "name": snap.name,
                "title": snap.displayTitle,
                "cwd": snap.cwd,
                "cwdShort": snap.cwdShort,
                "activity": snap.act.rawValue,
                "entrypoint": snap.entrypoint ?? "",
                "agent": snap.agentID,
                "canReply": snap.canReply(local: record.kind == .local),
            ]
            if let value = snap.reason { item["reason"] = value }
            if let value = snap.branch, !value.isEmpty { item["branch"] = value }
            if let value = snap.worktree, !value.isEmpty { item["worktree"] = value }
            if let value = snap.activityText { item["activityText"] = value }
            if let stage = snap.liveStage { item["stage"] = stage.payload }   // 任务做到第几步（忙、等确认时才有）
            if let goal = snap.goal, goal.valid { item["goal"] = goal.payload }   // 目标（/goal）：在做的、结束不久的
            if let value = snap.message { item["preview"] = value }
            if let effort = snap.effort {
                if let level = effort.effort { item["effort"] = level }
                if let on = effort.ultracode { item["ultracode"] = on }
                if let mode = effort.mode { item["permissionMode"] = mode }
            }
            if let count = snap.subagents, count > 0 { item["subagents"] = count }
            if snap.readOnly == true { item["readOnly"] = true }   // 只能看、不能远程操作（Proma 这类）
            if let reason = snap.readOnlyReason, !reason.isEmpty {
                item["readOnlyReason"] = reason
                if let english = snap.readOnlyReasonEn, !english.isEmpty { item["readOnlyReasonEn"] = english }
            }
            // 终端（term）开在会话所在的机器上，哪家 agent 的会话都能开；只有这一版起的电脑端才有，手机见到才显示终端按钮
            item["caps"] = snap.capsPayload + ["term"]
            if let count = snap.terminals, count > 0 { item["terminals"] = count }
            if let options = snap.pendingOptions, !options.isEmpty, snap.act == .waiting { item["pendingOptions"] = options.map(\.payload) }
            if let error = snap.error, snap.act == .idle {
                item["error"] = error.display
                item["errorKind"] = error.kind
            }
            if let value = snap.blockingDescription, snap.act == .waiting { item["blocking"] = value }
            if let value = snap.pendingTool { item["pendingTool"] = value }
            if let value = snap.transcriptUpdatedAt ?? snap.statusUpdatedAt ?? snap.updatedAt { item["updatedAt"] = value }
            if let value = snap.startedAt { item["startedAt"] = value }
            if let usage = snap.usage { item["usage"] = usage.payload }
            return item
        }
        let sourceList: [[String: Any]] = store.sourceConfigs.map { source in
            let linkState = store.sourceStates[source.id] ?? .stopped
            return ["id": source.id, "name": source.displayName, "kind": source.kind.rawValue,
                    "online": linkState.isLive, "status": linkState.shortLabel]
        }
        return [
            "ok": true,
            "host": Host.current().localizedName ?? "电脑",
            "version": AppVersion.app,
            "submitOnSend": config.mobile.submitOnSend,
            "quickReplies": config.mobile.quickReplies,
            "watch": config.mobile.watch.payload,
            "me": Profile.mePayload(config.mobile),
            "muted": config.mobile.mutedSessions,
            "pinned": config.mobile.pinnedSessions,
            "marked": config.mobile.markedSessions,
            "quietActive": config.mobile.inQuietHours(),
            "sources": sourceList,
            "alerts": EditorAlerts.shared.payload,
            "sessions": sessions,
            "agents": PluginStore.shared.agentCards,
            "faces": AgentFaces.shared.payload,
            // 这版电脑端能做的（手机按它决定给不给入口）：files = 收手机发来的文件（PDF、Excel……）、按路径取回文件
            // groups = 会话群（拉群、群里发言、历史群恢复）；groupMedia = 群里能发图、文件；
            // hostUpdate = 手机上能看这台电脑的新版本、让它下载安装和重启（/api/host-update）
            "features": ["files", "groups", "groupMedia", "hostUpdate"],
        ]
    }

    /// 某台机器报来新的性能数据（nil = 断开了，清掉）：记下，推给手机和 Mac 主窗口（主线程）
    func updateMachineStats(_ sourceId: String, _ stats: [String: Any]?) {
        if let stats {
            machineStats[sourceId] = stats
        } else if machineStats.removeValue(forKey: sourceId) == nil {
            return
        }
        var payload: [String: Any] = ["id": sourceId]
        if let stats { payload["stats"] = stats }
        mobile.publish(event: "sys", payload: payload)
    }
}

extension Notification.Name {
    static let ccpulseShowPanel = Notification.Name("ccpulse.showPanel")
}

extension AppState {
    /// 标记 / 取消标记会话（新标记的排在标记里的最前）
    func setMarked(_ key: String, _ on: Bool) {
        guard on != config.mobile.markedSessions.contains(key) else { return }
        updatePreferences { config in
            config.mobile.markedSessions.removeAll { $0 == key }
            if on { config.mobile.markedSessions.insert(key, at: 0) }
            config.mobile.markedSessions = Array(config.mobile.markedSessions.prefix(50))
        }
        KitelineModel.shared.refresh()
    }

    /// 会话从列表里消失（关掉、结束了）：一分钟后还没回来、它那台机器也还连着，就取消标记。
    /// 等一会儿是怕 VS Code 重新加载窗口这类短暂消失又回来的，把标记弄丢
    func sessionsDisappeared(_ gone: [SessionRecord]) {
        let marked = gone.filter { config.mobile.markedSessions.contains($0.key) }
        guard !marked.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            for record in marked where self.store.record(withKey: record.key) == nil && self.sources[record.sourceId]?.state.isLive == true {
                self.setMarked(record.key, false)
            }
        }
    }
}

extension AppState: SessionStoreDelegate {
    func sessionStoreDidUpdate(_ store: SessionStore) {
        onStoreUpdate?(store)
        IdleClose.shared.storeUpdated(store.records)
        mobile.publishState()
    }

    func sessionStore(_ store: SessionStore, didLose records: [SessionRecord]) {
        sessionsDisappeared(records)
    }

    func sessionStore(_ store: SessionStore, wantsNotificationFor record: SessionRecord, transition: SessionTransition) {
        Log.write("提醒 \(record.sourceName)/\(record.snapshot.name)：\(transition)")
        // 静音的会话：Mac 上也不弹结论、目标的通知（需要确认的照弹）
        let quiet: Bool
        switch transition {
        case .concluded, .goalEnded: quiet = config.mobile.mutedSessions.contains(record.key)
        default: quiet = false
        }
        if !quiet {
            NotificationCenterBridge.shared.deliver(record: record, transition: transition, config: config)
        }
        switch transition {
        case .needsAttention(let reason):
            mobile.notify(kind: "attention", title: record.snapshot.displayTitle, body: reason, key: record.key)
        case .concluded(let message):
            if let error = record.snapshot.error {
                // 不是结论，是 Claude 出错停下了（用量上限、上下文太长、接口过载…）
                mobile.notify(kind: "error", title: record.snapshot.displayTitle, body: error.display, key: record.key)
            } else {
                mobile.notify(kind: "conclusion", title: record.snapshot.displayTitle, body: message, key: record.key)
            }
        case .goalEnded(let goal):
            mobile.notifyGoal(title: record.snapshot.displayTitle, head: GoalText.head(goal.state),
                              body: goal.pushBody(english: false), bodyEn: goal.pushBody(english: true), key: record.key)
        default:
            return
        }
    }
}

extension AppState: SourceConnectionDelegate {
    func source(_ source: SourceConnection, didChange state: LinkState) {
        store.apply(sourceConfig: source.config, state: state)
        if case .failed = state {
            store.dropSessions(from: source.config.id)
        }
        if !state.isLive { updateMachineStats(source.config.id, nil) }
        if state.isLive {
            DispatchQueue.main.async { PeerLinks.shared.backfill(source) }
            // 刚连上：把 agent 的待办给它一份（agent 在这台电脑上 todo list / done 用得上）
            Todos.shared.pushToAgents(only: source)
            // 会话群的名单也给一份（group say / info 核对成员）
            Groups.shared.pushToAgents(only: source)
        }
    }

    func source(_ source: SourceConnection, didReceive event: WatcherEvent) {
        switch event.kind {
        case "sys":
            var stats = event.raw
            stats.removeValue(forKey: "event")
            DispatchQueue.main.async { self.updateMachineStats(source.config.id, stats) }
        case "plugin_error", "plugin_retired":
            // Agent 插件出错：弹窗问要不要发报告；外部插件被 watcher 停用了，本机的文件退回上一版本
            DispatchQueue.main.async { PluginStore.shared.handle(event, from: source) }
        case "peers":
            // 会话之间的消息：换成会话 key 记下，转给手机（Mac 主窗口也经同一条实时连接收到）
            let raw = event.raw["links"] as? [[String: Any]] ?? []
            DispatchQueue.main.async {
                let links = PeerLinks.shared.ingest(sourceId: source.config.id, raw)
                if !links.isEmpty { self.mobile.publish(event: "peers", payload: ["links": links]) }
            }
        case "term", "term_exit":
            // 会话里的终端：输出、结束直接转给手机（和 Mac 主窗口），键与会话列表里的 key 一致
            guard let sessionId = event.raw["sessionId"] as? String else { return }
            var payload = event.raw
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "sessionId")
            payload["key"] = "\(source.config.id)#\(sessionId)"
            DispatchQueue.main.async { self.mobile.publish(event: event.kind, payload: payload) }
        case "entries", "reset":
            // 对话增量直接转给手机，键与会话列表里的 key 一致
            guard let sessionId = event.raw["sessionId"] as? String else { return }
            let key = "\(source.config.id)#\(sessionId)"
            DispatchQueue.main.async {
                if event.kind == "entries" {
                    let items = event.raw["items"] as? [[String: Any]] ?? []
                    self.mobile.publish(event: "entries", payload: ["key": key, "items": items])
                    self.agentItems(key: key, items: items)
                } else {
                    self.mobile.publish(event: "reset", payload: ["key": key])
                }
            }
        default:
            if event.kind == "hello" { Groups.shared.noteHello(sourceId: source.config.id, raw: event.raw) }
            DispatchQueue.main.async {
                self.store.apply(sourceConfig: source.config, event: event)
                // 早先记的 agent 待办没有项目目录、agent：会话还在的趁这时补上（按项目 / 按 Agent 分组用）
                if event.kind == "snapshots" {
                    Todos.shared.fillSessionMeta()
                    // 会话群：成员开了 / 关了，排着的群消息接着投或改成恢复时补上
                    Groups.shared.sessionsChanged()
                }
            }
        }
    }

    /// agent 经 watcher 子命令主动发来的：图推到手机锁屏；要用户做的事（todo --user）记成提示、推一条问「现在处理 / 加入待办」；
    /// agent 自己的待办（todo）记进「agent 的待办」、更新（todo start / progress / done）按编号改，都不推送；关键信息（keyinfo）推一条，不带具体的值
    private func agentItems(key: String, items: [[String: Any]]) {
        let record = store.record(withKey: key)
        let title = record?.snapshot.displayTitle ?? "会话"
        let speaker = Agents.info(record?.snapshot.agentID).speaker
        for item in items {
            switch item["t"] as? String {
            case "agent_image":
                // 回别的会话来信的那一轮里发的图：是会话之间的往来，对话里照常显示，不推送
                guard record?.snapshot.fromPeer != true else { continue }
                let caption = item["text"] as? String ?? ""
                mobile.notify(kind: "image", title: title, body: caption.isEmpty ? "\(speaker) 发来一张图片" : caption, key: key)
            case "agent_todo":
                guard let id = item["id"] as? String, let text = item["text"] as? String, !text.isEmpty else { continue }
                let ts = Digest.number(item["ts"])
                let detail = item["detail"] as? String ?? ""
                if item["forUser"] as? Bool == true {
                    if Todos.shared.suggestForUser(key: key, itemId: id, title: title, machine: record?.sourceName, ts: ts > 0 ? ts : nil,
                                                   text: text, detail: detail) {
                        mobile.notify(kind: "todo", title: title, body: "需要你处理：\(text)", key: key)
                    }
                } else {
                    Todos.shared.addAgentTask(key: key, itemId: id, text: text, detail: detail, ref: item["ref"] as? String ?? "", ts: ts > 0 ? ts : nil)
                }
            case "agent_todo_update":
                guard let ref = item["ref"] as? String, !ref.isEmpty else { continue }
                Todos.shared.updateAgentTask(ref: ref, status: item["status"] as? String ?? "doing", progress: item["progress"] as? String ?? "", key: key)
            case "agent_key":
                let name = item["title"] as? String ?? ""
                mobile.notify(kind: "keyinfo", title: title, body: "\(speaker) 发来关键信息：\(name)。可在对话中查看、收藏。", key: key)
            case "group_say":
                // 发到会话群的（watcher 的 group say）：转给群里其他会话
                Groups.shared.agentSaid(key: key, item: item)
            default:
                continue
            }
        }
    }

    func source(_ source: SourceConnection, didLog message: String) {
        Log.write("[\(source.config.displayName)] \(message)")
    }
}
