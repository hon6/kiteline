import AppKit
import ApplicationServices
import Foundation
import KitelineKit

/// 主动发现「要人处理才能继续」的状况，告诉手机，能自动处理的给一个「尝试重连」：
/// - VS Code 弹着系统对话框：Remote-SSH 连不上（重试 / 关闭远程 / 更多操作）、断线放弃（无法重新连接。请重新加载窗口。）、
///   「工作区不存在」（远端目录没挂上）、保存确认……框挂着时 Claude 的消息投递不进去，人不在电脑前又看不见；
/// - Kiteline 自己到某台机器的连接断了一分钟以上：那台机器上的会话会从列表里消失。
///
/// 对话框只读窗口这一层的辅助功能树（框是 VS Code 主进程弹的原生窗口，不用开网页的辅助功能，3 秒看一次几乎不花时间）；
/// 画在网页里的提示（右下角的通知、正在重连的进度框）这里看不到。
/// 有人正在用电脑时不推送（框就在他眼前），手机列表顶上照样显示，问题消失就撤掉。
/// 要打开 claude.ai 的 Artifact 链接时弹的「是否要 Code 打开外部网站？」不提醒，直接替用户取消（见 Dialog.artifactLink）；
/// 投递时焦点不在 Claude 输入框、消息粘进了终端弹的「是否确实要将 3 行文本粘贴到终端?」同样取消（见 Dialog.strayPaste）。
final class EditorAlerts {
    static let shared = EditorAlerts()

    struct Alert: Equatable {
        /// dialog = VS Code 的对话框；link = Kiteline 到某台机器的连接
        let kind: String
        let id: String
        /// 哪个窗口（「ccpulse [SSH: 10.168.1.10]」）或哪台机器
        let title: String
        let text: String
        let canReconnect: Bool
        var since: Date
    }

    /// 读出来的一个对话框（后台队列上用）
    private struct Dialog {
        let pid: pid_t
        let window: String
        let texts: [String]
        let buttons: [(title: String, element: AXUIElement)]
        let cancel: AXUIElement?

        var id: String {
            let raw = "\(pid)|\(window)|\(texts.joined(separator: "|"))"
            return "d" + String(UInt64(bitPattern: Int64(raw.hashValue)), radix: 36)
        }

        /// 远端窗口：标题末尾是「[SSH: 主机]」「[WSL: Ubuntu]」「[Dev Container: …]」这类
        var remote: Bool { window.hasSuffix("]") && window.contains(" [") }

        /// 框里本来就有的重连按钮：Remote-SSH 的「重试」、断线后的「重新加载窗口」、正在重连时的「立即重新连接」
        var reconnectButton: AXUIElement? {
            buttons.first { EditorAlerts.reconnectTitles.contains(EditorAlerts.plain($0.title)) }?.element
        }

        /// 远端窗口里和连接有关、但框里没有重连按钮的（「工作区不存在」：远端目录当时不在）：关掉框、重新加载窗口
        var reloadAfterCancel: Bool {
            guard remote, cancel != nil else { return false }
            let all = texts.joined(separator: " ").lowercased()
            return EditorAlerts.connectionWords.contains { all.contains($0) }
        }

        /// 要打开 claude.ai 的 Artifact 链接：Claude 扩展发布 Artifact 后自动打开的预览（链接带 via=auto_preview），或会话里点的链接。
        /// claude.ai 不在 VS Code 受信任的域里时弹「是否要 Code 打开外部网站？」，一律替用户取消：浏览器和 Claude Code 走的网络常常不一样，
        /// 换个 IP 打开 claude.ai 账号容易被风控；框挂着时手机发来的消息也投递不进去。只认 Artifact：登录（claude.ai/oauth/…）等别的链接照常由用户决定
        var artifactLink: Bool {
            cancel != nil && texts.contains(where: EditorAlerts.isArtifactLink)
        }

        /// Kiteline 投递时焦点不在 Claude 输入框、粘进了终端：VS Code 弹「是否确实要将 3 行文本粘贴到终端?」（多行才弹），
        /// 预览是前三行、每行前 30 个字（长的带「…」）。预览对得上刚投递的话才算，用户自己往终端里粘的不管
        func strayPaste(of pasted: [String]) -> Bool {
            guard cancel != nil, !pasted.isEmpty else { return false }
            let lines = texts.flatMap { $0.components(separatedBy: .newlines) }.map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.contains(where: { $0.contains("粘贴到终端") || $0.lowercased().contains("into the terminal") }),
                  let header = lines.firstIndex(where: { ["预览:", "预览：", "preview:"].contains($0.lowercased()) }),
                  let first = lines[(header + 1)...].first(where: { !$0.isEmpty }) else { return false }
            let head = first.hasSuffix("…") ? String(first.dropLast()) : first
            guard head.count >= 4 else { return false }
            return pasted.contains { text in
                let line = text.components(separatedBy: .newlines).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                return line?.hasPrefix(head) == true
            }
        }
    }

    /// 框里显示的是不是 claude.ai 的 Artifact 链接（claude.ai/artifact/…、claude.ai/code/artifact/…）。扩展传的是 Uri 对象时
    /// VS Code 会把超过 60 个字符的链接截成「https://claude.ai/artifact/xxx?...preview」，截的只是问号后面，路径总是完整的
    private static func isArtifactLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        return (host == "claude.ai" || host.hasSuffix(".claude.ai")) && url.path.contains("/artifact")
    }

    private static let reconnectTitles: Set<String> = ["重新加载窗口", "reload window", "重试", "retry", "立即重新连接", "reconnect now",
                                                       "重新连接", "reconnect", "重新加载", "reload"]
    private static let connectionWords = ["不存在", "does not exist", "连接", "connect", "断开", "找不到", "not found"]
    /// 框挂了这么久才算（一闪而过的不算），没人动电脑这么久才推送
    private static let settle: TimeInterval = 4
    private static let idleBeforePush = testValue("CCPULSE_ALERT_IDLE") ?? 30
    /// Kiteline 到某台机器断了这么久才提醒（睡眠唤醒、网络切换时会断几秒再自己连上）
    private static let linkGrace = testValue("CCPULSE_ALERT_LINK_GRACE") ?? 60

    /// 自测（dry-run）时缩短等待
    private static func testValue(_ name: String) -> TimeInterval? {
        Delivery.dryRun ? ProcessInfo.processInfo.environment[name].flatMap(TimeInterval.init) : nil
    }

    private let queue = DispatchQueue(label: "tars.editor-alerts")
    private var timer: DispatchSourceTimer?
    /// 替用户取消过的框（只在 queue 上读写）：按了没关的下一拍再按，日志只记一次
    private var cancelled: Set<String> = []
    /// Kiteline 最近一分钟往 VS Code 里粘过的话（只在 queue 上读写）：粘进了终端时认得出它弹的框（见 Dialog.strayPaste）
    private var recentPastes: [(text: String, at: Date)] = []
    /// 下面这些只在主线程读写
    private(set) var alerts: [Alert] = []
    private var dialogFirstSeen: [String: Date] = [:]
    private var notified: Set<String> = []
    /// 这次运行里连上过的来源（从没连上过的机器关着不算断线）、断开的时刻
    private var everLive: Set<String> = []
    private var downSince: [String: Date] = [:]
    /// 在推送里说过断线的来源：连回来时说一声
    private var linkNotified: Set<String> = []
    /// 手机上点了重连的时刻
    private var manualRetry: [String: Date] = [:]

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 3, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let dialogs = AXIsProcessTrusted() ? self.cancelAutomatic(in: Self.scanDialogs()) : []
            DispatchQueue.main.async { self.update(dialogs: dialogs) }
        }
        timer.resume()
        self.timer = timer
    }

    /// 给手机的列表（state 里的 alerts）
    var payload: [[String: Any]] {
        alerts.map { alert in
            var item: [String: Any] = ["id": alert.id, "kind": alert.kind, "title": alert.title, "text": alert.text,
                                       "since": alert.since.timeIntervalSince1970 * 1000]
            // 对话框里的字是 VS Code 自己的（跟它的界面语言），原样给；断线那句是 Kiteline 说的，给英文设备换（见 ServerText.localize）
            if alert.kind == "link" { item["textEn"] = ServerLang.translate(alert.text) }
            if alert.canReconnect { item["actions"] = ["reconnect"] }
            return item
        }
    }

    // MARK: - 汇总（主线程）

    private func update(dialogs: [Dialog], now: Date = Date()) {
        var next: [Alert] = []
        var seen = Set<String>()
        for dialog in dialogs {
            let id = dialog.id
            seen.insert(id)
            let first = dialogFirstSeen[id] ?? now
            dialogFirstSeen[id] = first
            guard now.timeIntervalSince(first) >= Self.settle else { continue }
            next.append(Alert(kind: "dialog", id: id, title: dialog.window, text: Self.sentence(dialog.texts),
                              canReconnect: dialog.reconnectButton != nil || dialog.reloadAfterCancel, since: first))
        }
        dialogFirstSeen = dialogFirstSeen.filter { seen.contains($0.key) }
        next += linkAlerts(now: now)

        for alert in next where !notified.contains(alert.id) && shouldNotify(alert, now: now) {
            notified.insert(alert.id)
            notify(alert)
        }
        let current = Set(next.map(\.id))
        for id in linkNotified where !current.contains("l" + id) {
            linkNotified.remove(id)
            if let name = AppState.shared.store.sourceConfigs.first(where: { $0.id == id })?.displayName,
               AppState.shared.store.sourceStates[id]?.isLive == true {
                AppState.shared.mobile.notifyAlert(kind: "link", title: name, head: "已重新连上", body: "这台机器上的会话已恢复显示", alert: nil)
                Log.write("提醒：\(name) 已重新连上")
            }
        }
        notified = notified.intersection(current)
        guard next != alerts else { return }
        alerts = next
        AppState.shared.mobile.publishState()
    }

    private func linkAlerts(now: Date) -> [Alert] {
        let store = AppState.shared.store
        var result: [Alert] = []
        for source in store.sourceConfigs {
            let state = store.sourceStates[source.id] ?? .stopped
            if state.isLive {
                everLive.insert(source.id)
                downSince[source.id] = nil
                manualRetry[source.id] = nil
                continue
            }
            // 用户在设置里停掉的、从没连上过的不算（手机点了重连，断开再连的那一下也是 stopped，照算断着）
            let retrying = (manualRetry[source.id] ?? .distantPast).timeIntervalSince(now) > -5
            guard everLive.contains(source.id), state != .stopped || retrying else { downSince[source.id] = nil; continue }
            let since = downSince[source.id] ?? now
            downSince[source.id] = since
            guard now.timeIntervalSince(since) >= Self.linkGrace else { continue }
            var text = "Kiteline 与这台机器的连接已断开，这台机器上的会话暂时看不到，正在自动重连"
            if case .failed(let reason) = state, !reason.isEmpty { text += "（\(reason.trimmingCharacters(in: .whitespacesAndNewlines))）" }
            result.append(Alert(kind: "link", id: "l" + source.id, title: source.displayName, text: text, canReconnect: true, since: since))
        }
        return result
    }

    private func shouldNotify(_ alert: Alert, now: Date) -> Bool {
        guard alert.kind == "dialog" else { return true }
        // Kiteline 投递时 VS Code 弹的确认框：投递那边已经回给手机了
        if FrontReturn.busy { return false }
        return Self.userIdle() >= Self.idleBeforePush
    }

    private func notify(_ alert: Alert) {
        if alert.kind == "link" {
            linkNotified.insert(String(alert.id.dropFirst()))
            AppState.shared.mobile.notifyAlert(kind: "link", title: alert.title, head: "连接已断开", body: alert.text, alert: alert)
        } else {
            let tail = alert.canReconnect ? "可在手机上轻点「尝试重连」" : "需要在电脑上处理"
            // 对话框的字是 VS Code 自己的（跟它的界面语言），英文版只换 Kiteline 说的那部分
            AppState.shared.mobile.notifyAlert(kind: "editor", title: alert.title.isEmpty ? "VS Code" : alert.title, head: "需要处理",
                                               body: "VS Code 弹出提示：\(alert.text)。\(tail)",
                                               bodyEn: "VS Code is showing a dialog: \(alert.text). \(Lang.shared.english(tail))", alert: alert)
        }
        Log.write("提醒：\(alert.title) \(alert.text)")
    }

    /// 多久没人动鼠标键盘了。Kiteline 自己投递时发的按键也算动静：最后一下落在投递期间（投完 2 秒内）的，是手机那头在操作，人不在电脑前
    static func userIdle() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel]
        let idle = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        let sinceAutomation = Date().timeIntervalSince(FrontReturn.busyUntil)
        return sinceAutomation >= 0 && idle >= sinceAutomation - 2 ? .infinity : idle
    }

    /// 「工作区不存在」「请选择另一个工作区以打开。」→「工作区不存在。请选择另一个工作区以打开」（英文句子之间才空一格）
    private static func sentence(_ texts: [String]) -> String {
        var text = ""
        for part in texts {
            var line = part.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !line.isEmpty else { continue }
            if !"。.？?！!".contains(line.last!) { line += line.unicodeScalars.contains { $0.value >= 0x3000 } ? "。" : "." }
            if let last = text.last { text += "。？！".contains(last) ? "" : " " }
            text += line
        }
        while text.hasSuffix("。") || text.hasSuffix(".") { text.removeLast() }
        return text.count > 300 ? String(text.prefix(298)) + "…" : text
    }

    private static func plain(_ title: String) -> String {
        title.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - 自动取消：打开 Artifact 链接、投递粘进了终端

    /// 投递粘贴前记一下（主线程）
    func notePaste(_ text: String) {
        let now = Date()
        queue.async { [self] in
            recentPastes = recentPastes.filter { now.timeIntervalSince($0.at) < 60 } + [(text, now)]
        }
    }

    /// 后台队列：替用户按掉的框——要打开 Artifact 链接的、投递时粘进了终端的（见 Dialog.strayPaste），返回剩下要提醒的
    private func cancelAutomatic(in dialogs: [Dialog], pruning: Bool = true) -> [Dialog] {
        if pruning { cancelled.formIntersection(dialogs.map(\.id)) }
        recentPastes = recentPastes.filter { Date().timeIntervalSince($0.at) < 60 }
        let pasted = recentPastes.map(\.text)
        return dialogs.filter { dialog in
            let stray = !dialog.artifactLink && dialog.strayPaste(of: pasted)
            guard dialog.artifactLink || stray, let cancel = dialog.cancel else { return true }
            AXUIElementPerformAction(cancel, kAXPressAction as CFString)
            if cancelled.insert(dialog.id).inserted {
                let window = dialog.window.isEmpty ? "VS Code" : dialog.window
                Log.write(stray ? "投递的消息粘进了终端，已替用户取消：\(window) \(Self.sentence(dialog.texts))"
                    : "已拦截 claude.ai 的 Artifact 链接：\(window) \(Self.sentence(dialog.texts))")
            }
            return false
        }
    }

    /// 投递前、回车前用（主线程）：这个 VS Code 弹着该替用户按掉的框（见 cancelAutomatic）就先按掉，等它关上（最多 1 秒）。按掉了返回 true
    func cancelAutomatic(in app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let pid = app.processIdentifier
        return queue.sync {
            let open = Self.scanDialogs(pids: [pid])
            let left = cancelAutomatic(in: open, pruning: false)
            guard left.count < open.count else { return false }
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.1)
                if Self.scanDialogs(pids: [pid]).count <= left.count { return true }
            }
            return false
        }
    }

    // MARK: - 尝试重连

    /// 手机上点了「尝试重连」：框里有重连按钮就按它；「工作区不存在」这类关掉框、重新加载窗口；Kiteline 的连接断了就立即重连。
    /// 回调在主线程：(成功, 给手机看的话)
    func reconnect(id: String, completion: @escaping (Bool, String) -> Void) {
        if id.hasPrefix("l") {
            let sourceId = String(id.dropFirst())
            guard let source = AppState.shared.source(withId: sourceId) else { completion(false, "这台机器已不在 Kiteline 的来源列表中"); return }
            Log.write("手机要求立即重连：\(source.config.displayName)")
            manualRetry[sourceId] = Date()   // 重连期间提示留着，连上了自己撤
            source.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { source.start() }
            completion(true, "正在重新连接「\(source.config.displayName)」")
            return
        }
        guard AXIsProcessTrusted() else { completion(false, Delivery.needsAccessibility); return }
        queue.async {
            guard let dialog = Self.scanDialogs().first(where: { $0.id == id }) else {
                DispatchQueue.main.async { completion(false, "电脑上的这个对话框已经关闭") }
                return
            }
            if let button = dialog.reconnectButton {
                let closed = Self.press(button, closing: id)
                Log.write("手机要求重连：按了「\(dialog.window)」对话框上的重连按钮（\(closed ? "框已关" : "框还在")）")
                DispatchQueue.main.async {
                    closed ? completion(true, "已在电脑上重新连接，VS Code 窗口正在重新加载")
                        : completion(false, "没能按下对话框上的按钮，请在电脑上处理")
                }
                return
            }
            guard dialog.reloadAfterCancel, let cancel = dialog.cancel else {
                DispatchQueue.main.async { completion(false, "这个对话框需要在电脑上处理") }
                return
            }
            guard Self.press(cancel, closing: id) else {
                DispatchQueue.main.async { completion(false, "没能关闭对话框，请在电脑上处理") }
                return
            }
            Log.write("手机要求重连：关掉「\(dialog.window)」的对话框，重新加载窗口")
            // 自测用的假窗口没有命令面板，也别把它切到前台抢用户的焦点
            if Delivery.dryRun, ProcessInfo.processInfo.environment["CCPULSE_ALERT_RELOAD"] != "1" {
                DispatchQueue.main.async { completion(true, "（自测）已关闭对话框，跳过重新加载窗口") }
                return
            }
            DispatchQueue.main.async {
                guard let app = NSRunningApplication(processIdentifier: dialog.pid) else { completion(false, "VS Code 已退出"); return }
                Self.reloadWindow(app: app, title: dialog.window, completion: completion)
            }
        }
    }

    /// 让某个 VS Code 窗口执行「重新加载窗口」：切到这个窗口、⇧⌘P 打开命令面板、贴上命令名、回车。
    /// 每一步先用辅助功能核对，确认焦点在命令面板的输入框里（内容就是「>」）才贴，贴完内容对得上才按回车，
    /// 免得贴进编辑器或 Claude 的输入框。命令面板认英文命令名（中文界面也认）
    private static func reloadWindow(app: NSRunningApplication, title: String, completion: @escaping (Bool, String) -> Void) {
        let command = "Developer: Reload Window"
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        ClaudeInput.holdWebTree(app)
        let front = FrontReturn.capture(automation: 12)
        func finish(_ ok: Bool, _ message: String) {
            if !ok { Log.write("没能重新加载「\(title)」：\(message)") }
            front.restore(after: ok ? 0.8 : 0.3)
            ClaudeInput.releaseWebTree(app)
            completion(ok, message)
        }
        let windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let window = windows.first(where: { attribute($0, kAXTitleAttribute) as? String == title || windowPlace($0) == title }) else {
            finish(false, "找不到这个 VS Code 窗口，请在电脑上处理"); return
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [.activateIgnoringOtherApps])
        // 按键只落在前台：前台必须正是弹框的这个 VS Code 进程、这个窗口。只看「有 VS Code 在前台」不够——
        // 另开的实例（--user-data-dir、Insiders）也算 VS Code，⇧⌘P 会落进用户正在用的那个（10-27 实测踩到）
        let place = windowPlace(window)
        func ours() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                && windowPlace(attribute(ax, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }) == place
        }
        waitUntil(Date().addingTimeInterval(2), ours) { front in
            guard front, !Delivery.editorShowsDialog(app) else {
                finish(false, "没能把这个 VS Code 窗口切到前台，请在电脑上处理"); return
            }
            Delivery.postKey(35, flags: [.maskCommand, .maskShift])   // ⇧⌘P
            // 网页的辅助功能树开了之后要等一会儿才有；焦点输入框读不到就一直等到时限
            waitFocused(ax, until: Date().addingTimeInterval(4), matches: { $0 == ">" }) { opened in
                guard opened, ours() else { finish(false, "没能打开 VS Code 命令面板，请在电脑上重新加载窗口"); return }
                Delivery.pasteText(command)
                waitFocused(ax, until: Date().addingTimeInterval(2), matches: { $0 == ">" + command }) { typed in
                    guard typed, ours() else {
                        if ours() { Delivery.postKey(53) }   // Esc：关掉命令面板（焦点核对过就在面板里）
                        finish(false, "没能在 VS Code 命令面板里输入命令，请在电脑上重新加载窗口"); return
                    }
                    Delivery.postKey(36)
                    Log.write("已让「\(title)」重新加载窗口")
                    finish(true, "已在电脑上重新加载「\(title)」窗口；如果仍连不上，会再提醒你")
                }
            }
        }
    }

    /// 按对话框上的按钮，以框关没关为准（后台队列）：按下去框就关了的话，系统常回「无法完成」（-25204），其实按到了
    private static func press(_ button: AXUIElement, closing id: String) -> Bool {
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.25)
            if !scanDialogs().contains(where: { $0.id == id }) { return true }
        }
        return false
    }

    /// 等到条件成立（每 0.2 秒看一次）；回调在主线程
    private static func waitUntil(_ deadline: Date, _ condition: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        if condition() { then(true); return }
        guard Date() < deadline else { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitUntil(deadline, condition, then: then) }
    }

    /// 等到焦点在一个单行输入框（命令面板是 <input>；编辑器、Claude 的输入框是多行）里、内容符合要求；回调在主线程
    private static func waitFocused(_ ax: AXUIElement, until deadline: Date, matches: @escaping (String) -> Bool,
                                    then: @escaping (Bool) -> Void) {
        if let value = paletteValue(ax), matches(value) {
            then(true); return
        }
        guard Date() < deadline else { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitFocused(ax, until: deadline, matches: matches, then: then) }
    }

    /// 焦点所在的单行输入框里的字；读不到返回 nil。命令面板打开时焦点常报成列表里高亮的那一项（aria-activedescendant，
    /// 10-27 真 VS Code 实测）：那就往上找到这个列表，再在附近找说明文字和列表一样的输入框（都标着「Type the name of a command to run.」这类）
    private static func paletteValue(_ ax: AXUIElement) -> String? {
        guard var element = attribute(ax, kAXFocusedUIElementAttribute).map({ $0 as! AXUIElement }) else { return nil }
        if attribute(element, kAXRoleAttribute) as? String == kAXTextFieldRole { return attribute(element, kAXValueAttribute) as? String ?? "" }
        var label: String?
        for _ in 0..<8 {
            guard let parent = attribute(element, kAXParentAttribute).map({ $0 as! AXUIElement }) else { return nil }
            element = parent
            guard let label else {
                if attribute(element, kAXRoleAttribute) as? String == kAXListRole,
                   let text = attribute(element, kAXDescriptionAttribute) as? String, !text.isEmpty { label = text }
                continue
            }
            if let field = textField(in: element, label: label, depth: 7) { return attribute(field, kAXValueAttribute) as? String ?? "" }
        }
        return nil
    }

    private static func textField(in element: AXUIElement, label: String, depth: Int) -> AXUIElement? {
        if attribute(element, kAXRoleAttribute) as? String == kAXTextFieldRole,
           attribute(element, kAXDescriptionAttribute) as? String == label { return element }
        guard depth > 0 else { return nil }
        for child in children(element) {
            if let found = textField(in: child, label: label, depth: depth - 1) { return found }
        }
        return nil
    }

    // MARK: - 读对话框（后台队列）

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// 窗口标题里「—」后面那段：「Playwright 截图 — ccpulse [SSH: 10.168.1.10]」→「ccpulse [SSH: 10.168.1.10]」
    private static func windowPlace(_ window: AXUIElement?) -> String {
        guard let window, let title = attribute(window, kAXTitleAttribute) as? String else { return "" }
        return title.components(separatedBy: " — ").last?.trimmingCharacters(in: .whitespaces) ?? title
    }

    /// pids 不给就看所有 VS Code 系编辑器
    private static func scanDialogs(pids only: [pid_t]? = nil) -> [Dialog] {
        var result: [Dialog] = []
        var pids = only ?? Delivery.Editor.known.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId) }.map(\.processIdentifier)
        // 自测：拿一个假的「VS Code」进程（弹着同样的框）代替
        if only == nil, Delivery.dryRun { pids += (ProcessInfo.processInfo.environment["CCPULSE_ALERT_PID"] ?? "").split(separator: ",").compactMap { Int32($0) } }
        for pid in pids {
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.5)   // VS Code 卡死时别把这里也卡住
            for window in attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                let subrole = attribute(window, kAXSubroleAttribute) as? String ?? ""
                // 没有父窗口的确认框自己就是一个窗口；挂在项目窗口上的是它的 sheet
                if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole {
                    if let dialog = read(window, pid: pid, place: "") { result.append(dialog) }
                    continue
                }
                for child in children(window) where attribute(child, kAXRoleAttribute) as? String == kAXSheetRole {
                    if let dialog = read(child, pid: pid, place: windowPlace(window)) { result.append(dialog) }
                }
            }
        }
        return result
    }

    /// 只认提示框（文字 + 按钮）；有输入框、文件列表的是打开 / 保存面板，人就在电脑前操作，不算
    private static func read(_ dialog: AXUIElement, pid: pid_t, place: String) -> Dialog? {
        var texts: [(String, CGFloat)] = []
        var buttons: [(title: String, element: AXUIElement)] = []
        var panel = false
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 6, !panel else { return }
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            switch role {
            case kAXTextFieldRole, kAXOutlineRole, kAXBrowserRole, kAXTableRole, kAXListRole, kAXTextAreaRole:
                panel = true
            case kAXStaticTextRole:
                if let value = attribute(element, kAXValueAttribute) as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var point = CGPoint.zero
                    if let position = attribute(element, kAXPositionAttribute) { AXValueGetValue(position as! AXValue, .cgPoint, &point) }
                    texts.append((value, point.y))
                }
            case kAXButtonRole:
                if let title = attribute(element, kAXTitleAttribute) as? String, !title.isEmpty { buttons.append((title, element)) }
            default:
                children(element).forEach { walk($0, depth: depth + 1) }
            }
        }
        walk(dialog, depth: 0)
        guard !panel, !texts.isEmpty, !buttons.isEmpty else { return nil }
        let cancel = attribute(dialog, kAXCancelButtonAttribute).map { $0 as! AXUIElement }
            ?? buttons.first { ["取消", "cancel"].contains(plain($0.title)) }?.element
        return Dialog(pid: pid, window: place, texts: texts.sorted { $0.1 < $1.1 }.map(\.0), buttons: buttons, cancel: cancel)
    }
}
