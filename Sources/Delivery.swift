import AppKit
import ApplicationServices
import Foundation

/// 把手机（或面板）上的输入送进对应的 Claude Code 会话。
///
/// Claude Code 没有可写的 stdin（VS Code 扩展用管道跟它说话，本地消息 socket 校验进程祖先），
/// 所以投递只能走前端，按会话的宿主分三条路：
///
/// 1. **VS Code 扩展里的会话**（本机或 Remote-SSH 都一样，UI 都在这台 Mac 的 VS Code 里）
///    a. 用辅助功能找到标题匹配的窗口并置前（远端窗口标题带「[SSH: 主机]」）
///    b. 打开扩展自带的 URI `vscode://anthropic.claude-code/open?session=<id>&prompt=<内容>`：
///       切到这个会话的标签并把内容预填进输入框（扩展源码确认只预填、不提交）
///    c. 需要提交时再按一次回车
/// 2. **终端里的 CLI 会话，且在 tmux 里**：交给 watcher 用 tmux 精确投递（本机远端都行）
/// 3. **本机终端里的 CLI 会话**：沿进程树找到它所在的终端 App，激活后粘贴 + 回车
///
/// Codex、OpenCode 的会话不走这三条：watcher 连着它们自己的本机服务，发消息、确认、回答提问都走协议，
/// 不碰前台、不模拟按键，远端机器上的会话也一样能操作（见 viaAgent）。
enum Delivery {
    struct Outcome {
        var ok: Bool
        var submitted: Bool
        var message: String
    }

    struct Attachment {
        var name: String
        var data: Data
        /// 文件（PDF、Excel……）：消息里写成「[附件] 路径」交给 Claude 自己去读；否则是图
        var file = false
    }

    /// 自检用：只记录将要执行的动作，不碰 VS Code
    static var dryRun: Bool { ProcessInfo.processInfo.environment["CCPULSE_DRY_RUN"] == "1" }

    /// 最近一次投递的内容（自检断言用）
    private(set) static var lastDelivered: (key: String, text: String, submit: Bool)?

    // MARK: - 一次只做一件（切前台、粘贴、按键）

    /// 往 VS Code / 终端里粘贴、按键要占着前台和剪贴板：几件同时来（连点常用语、几个分屏块前后脚发、连点思考等级）会互相抢——
    /// 上一条投完把前台还给 Kiteline 时，下一条正要按回车，就成了「VS Code 不在前台」，文字还留在输入框里。排队一件一件来
    private static var automationQueue: [(@escaping (TimeInterval) -> Void) -> Void] = []
    private static var automating = false

    /// job 做完调 finish(还前台要等几秒)：等前台真还回去了再开始下一件（下一件才记得住用户原来在用的程序）。
    /// job 万一没调 finish，30 秒后也放下一件
    private static func serialized(_ job: @escaping (_ finish: @escaping (TimeInterval) -> Void) -> Void) {
        DispatchQueue.main.async {
            automationQueue.append(job)
            runNextAutomation()
        }
    }

    private static func runNextAutomation() {
        guard !automating, !automationQueue.isEmpty else { return }
        automating = true
        let job = automationQueue.removeFirst()
        var finished = false
        let finish: (TimeInterval) -> Void = { wait in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.6) {
                    automating = false
                    runNextAutomation()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish(0) }
        job(finish)
    }

    // MARK: - 发文本（可带图片）

    /// allowWhileWaiting：回答提问时先按 Esc 关掉了提问框，watcher 还没来得及更新状态，不拦
    static func send(text: String, attachments: [Attachment], to record: SessionRecord,
                     source: SourceConnection?, submit: Bool, allowWhileWaiting: Bool = false, completion: @escaping (Outcome) -> Void) {
        if !allowWhileWaiting, let problem = waitingProblem(record) {
            completion(Outcome(ok: false, submitted: false, message: problem)); return
        }
        stage(attachments, via: source) { result in
            switch result {
            case .failure(let error):
                completion(Outcome(ok: false, submitted: false, message: "图片或文件传输到会话所在机器失败：\(error)"))
            case .success(let paths):
                let prompt = compose(text: text, paths: paths, attachments: attachments)
                guard !prompt.isEmpty else {
                    completion(Outcome(ok: false, submitted: false, message: "内容为空"))
                    return
                }
                if viaAgent(record), !dryRun {
                    // 图片按图片给（Codex、OpenCode 都收本地图片路径），不拼进文字；文件只能写成路径交给它自己读。
                    // ui：这台 Mac 会替插件按键（插件回动作单时执行，见 runUIActions；Cursor 编辑器空闲时发消息靠它）
                    let kinds = zip(paths, attachments.map { $0.file })
                    agentRequest(["cmd": "agent_send", "text": compose(text: text, images: [], files: kinds.filter { $0.1 }.map { $0.0 }),
                                  "images": kinds.filter { !$0.1 }.map { $0.0 }, "ui": ["keys"]],
                                 record: record, source: source, submitted: true, completion: completion)
                    return
                }
                deliver(prompt: prompt, to: record, source: source, submit: submit, checkWaiting: !allowWhileWaiting, completion: completion)
            }
        }
    }

    /// Claude 正在等你确认（允许 / 拒绝、提问的选项、计划审批）：这时输入框被确认框换掉，粘贴进不去，
    /// 回车会替你选中确认框里默认的「允许」（10-25 在 Linux 测试机上实测：消息没发出去，一条命令被执行了）。
    /// 按键式投递（VS Code、终端、tmux）一律不发；Codex、OpenCode 这类走协议的不受影响。nil = 可以发
    static func waitingProblem(_ record: SessionRecord) -> String? {
        guard !viaAgent(record) else { return nil }
        let current = AppState.shared.store.record(withKey: record.key) ?? record
        guard current.snapshot.act == .waiting else { return nil }
        return "Claude 正在等你确认（\(current.snapshot.blockingDescription ?? "允许或拒绝")）。此时发送消息，回车会替你选中确认框中的默认选项，因此消息未发送。请先在确认卡片中作出选择，再重新发送"
    }

    /// 投递途中（粘贴之后、回车之前）Claude 弹出了确认框：回车就会替你选中默认选项，不按了（文字留在输入框里）
    static func waitingMidway(_ record: SessionRecord, into place: String = "VS Code 输入框") -> String? {
        guard let problem = waitingProblem(record) else { return nil }
        Log.write("投递途中 Claude 弹出了确认框，不按回车：\(problem.prefix(60))")
        return "发送途中 Claude 弹出了确认框，为避免回车替你选中默认选项，消息已填入\(place)但未提交。请先在确认卡片中作出选择，再到 VS Code 中按回车"
    }

    /// 图片先落到会话所在的机器上（本机或远端都走 watcher 的 put_file），拿到路径再写进消息
    static func stage(_ attachments: [Attachment], via source: SourceConnection?,
                              completion: @escaping (Result<[String], RemoteError>) -> Void) {
        guard !attachments.isEmpty else { completion(.success([])); return }
        guard let source = source else { completion(.failure(RemoteError("来源未连接"))); return }
        var paths: [String] = []
        func next(_ index: Int) {
            guard index < attachments.count else { completion(.success(paths)); return }
            let item = attachments[index]
            source.request(["cmd": "put_file", "name": item.name, "data": item.data.base64EncodedString()],
                           timeout: 120) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let response):
                    guard let path = response["path"] as? String else {
                        completion(.failure(RemoteError("watcher 未返回路径"))); return
                    }
                    paths.append(path)
                    next(index + 1)
                }
            }
        }
        next(0)
    }

    /// 消息正文 + 附图行 / 附件行。附图行的格式与 watcher 的 split_attachments 约定一致，手机上会还原成图片；
    /// 附件行（PDF、Excel……）原样留在消息里，手机认出来画成文件卡片。Claude 看到的是普通路径，会自己打开。
    /// paths 与 attachments 一一对应（stage 的结果）；不给 attachments 就都当图
    static func compose(text: String, paths: [String], attachments: [Attachment] = []) -> String {
        let kinds = paths.indices.map { $0 < attachments.count && attachments[$0].file }
        return compose(text: text, images: zip(paths, kinds).filter { !$0.1 }.map { $0.0 }, files: zip(paths, kinds).filter { $0.1 }.map { $0.0 })
    }

    static func compose(text: String, images: [String], files: [String]) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !images.isEmpty || !files.isEmpty else { return body }
        let lines = (images.map { "[附图] \($0)" } + files.map { "[附件] \($0)" }).joined(separator: "\n")
        let lead = !body.isEmpty ? body : files.isEmpty ? "请查看我发来的图片：" : images.isEmpty ? "请查看我发来的文件：" : "请查看我发来的图片和文件："
        return "\(lead)\n\n\(lines)"
    }

    private static func deliver(prompt: String, to record: SessionRecord, source: SourceConnection?,
                                submit: Bool, checkWaiting: Bool = true, completion: @escaping (Outcome) -> Void) {
        if dryRun {
            lastDelivered = (record.key, prompt, submit)
            Log.write("[dry-run] 投递到 \(record.snapshot.name)（submit=\(submit)）：\(prompt.prefix(120))")
            completion(Outcome(ok: true, submitted: submit, message: "dry-run"))
            return
        }
        let snapshot = record.snapshot
        if snapshot.isVSCode {
            sendToVSCode(prompt: prompt, record: record, submit: submit, checkWaiting: checkWaiting, completion: completion)
        } else if snapshot.tmuxPane != nil, let source = source, let pid = snapshot.pid {
            source.request(["cmd": "tmux_send", "pid": pid, "text": prompt, "submit": submit], timeout: 20) { result in
                switch result {
                case .success: completion(Outcome(ok: true, submitted: submit, message: "已经 tmux 送达"))
                case .failure(let error): completion(Outcome(ok: false, submitted: false, message: error.description))
                }
            }
        } else if record.kind == .local, let pid = snapshot.pid {
            sendToTerminal(prompt: prompt, pid: pid, submit: submit, record: checkWaiting ? record : nil, completion: completion)
        } else {
            completion(Outcome(ok: false, submitted: false,
                               message: "远端终端中的 CLI 会话需在 tmux 中运行才能远程发送"))
        }
    }

    // MARK: - 回答提问（AskUserQuestion）

    /// 先 Esc 关掉提问框，再把答案作为消息提交。
    /// Codex、OpenCode 的提问是协议里的请求：把选项原样答回去（answers 是手机给的 [{question, picked, other}]）；
    /// 对不上待答的提问（比如已经在电脑上答过了）再退回发一条消息
    static func answer(text: String, answers: [[String: Any]] = [], to record: SessionRecord, source: SourceConnection?,
                       completion: @escaping (Outcome) -> Void) {
        if viaAgent(record), !dryRun {
            agentRequest(["cmd": "agent_answer", "answers": answers], record: record, source: source, submitted: true) { outcome in
                if outcome.ok { completion(outcome); return }
                send(text: text, attachments: [], to: record, source: source, submit: true, completion: completion)
            }
            return
        }
        press(key: "esc", record: record, source: source) { outcome in
            guard outcome.ok else { completion(outcome); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (dryRun ? 0 : 1.2)) {
                send(text: text, attachments: [], to: record, source: source, submit: true, allowWhileWaiting: true, completion: completion)
            }
        }
    }

    // MARK: - 按键（确认框选项 / 中断）

    /// key: enter / esc / 1 / 2 / 3 / shift+tab；times = 连按几次（切权限模式要按到目标那一档）
    static func press(key: String, times: Int = 1, record: SessionRecord, source: SourceConnection?,
                      completion: @escaping (Outcome) -> Void) {
        let times = max(1, min(times, 6))
        guard let (code, flags) = keyCode(key) else {
            completion(Outcome(ok: false, submitted: false, message: "不支持的按键：\(key)")); return
        }
        if dryRun {
            lastDelivered = (record.key, "<key:\(key)>", false)
            Log.write("[dry-run] 在 \(record.snapshot.name) 按键 \(key)")
            completion(Outcome(ok: true, submitted: false, message: "dry-run"))
            return
        }
        if viaAgent(record) {
            // 1 允许 / 2 本会话都允许 / Esc 拒绝（不在等确认时 Esc = 中断）：watcher 换成 Codex、OpenCode 的说法
            agentRequest(["cmd": "agent_key", "key": key], record: record, source: source, submitted: false, completion: completion)
            return
        }
        let snapshot = record.snapshot
        if snapshot.isVSCode {
            pressInVSCode(code, flags: flags, times: times, record: record, done: "已按下 \(key)", skipped: "未指定按键", completion: completion)
        } else if snapshot.tmuxPane != nil, let source = source, let pid = snapshot.pid {
            source.request(["cmd": "tmux_send", "pid": pid, "keys": Array(repeating: key, count: times)], timeout: 20) { result in
                switch result {
                case .success: completion(Outcome(ok: true, submitted: false, message: "已按下 \(key)"))
                case .failure(let error): completion(Outcome(ok: false, submitted: false, message: error.description))
                }
            }
        } else if record.kind == .local, let pid = snapshot.pid {
            guard AXIsProcessTrusted() else {
                completion(Outcome(ok: false, submitted: false, message: Delivery.needsAccessibility)); return
            }
            serialized { finish in
                let front = FrontReturn.capture()
                guard let host = activateHostApp(of: pid) else {
                    front.release()
                    completion(Outcome(ok: false, submitted: false, message: "未找到该 CLI 会话所在的终端程序")); finish(0); return
                }
                front.target = host
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    postKeys(code, flags: flags, times: times)
                    let wait = Double(times) * 0.25 + 0.4
                    front.restore(after: wait)
                    completion(Outcome(ok: true, submitted: false, message: "已按下 \(key)"))
                    finish(wait)
                }
            }
        } else {
            completion(Outcome(ok: false, submitted: false,
                               message: "远端终端中的 CLI 会话需在 tmux 中运行才能远程操作"))
        }
    }

    /// 在 VS Code 里这个会话的标签上按键：切到它、核对前台标签确实是它再按，按完把前台还给用户原来在用的程序（见 FrontReturn）；
    /// 和别的投递排队。done / skipped：按了、没按时给用户看的话（skipped 替换提示里的「此消息未发送」）
    private static func pressInVSCode(_ code: CGKeyCode, flags: CGEventFlags, times: Int, record: SessionRecord,
                                      done: String, skipped: String, completion: @escaping (Outcome) -> Void) {
        // 键要按在这个会话的 Claude 面板里：焦点在终端的话「1」「回车」就按进终端了（见 ClaudeInput.Focus）。网页辅助功能树先开上，切标签这一秒里正好建好
        let editor = AXIsProcessTrusted() ? Editor.running()?.app : nil
        let treeReady = Date().addingTimeInterval(editor.map { ClaudeInput.holdWebTree($0) } == true ? 0 : 3)
        let titles = record.snapshot.tabCandidates
        let finished: (Outcome) -> Void = { outcome in
            if let editor { ClaudeInput.releaseWebTree(editor) }
            completion(outcome)
        }
        actInVSCode(record: record, done: done, skipped: skipped, wait: Double(times) * 0.25 + 0.4, completion: finished) { acted in
            guard let editor else { postKeys(code, flags: flags, times: times); acted(nil); return }
            ClaudeInput.ensureFocus(app: editor, titles: titles, needInput: false, deadline: treeReady.addingTimeInterval(1.5)) { focus in
                if case .elsewhere(let place) = focus {
                    acted(focusElsewhere(record, place: place).replacingOccurrences(of: "此消息未发送", with: skipped)); return
                }
                postKeys(code, flags: flags, times: times)
                acted(nil)
            }
        }
    }

    /// 焦点在别处、放不进这个会话的输入框（见 ClaudeInput.Focus）时回给手机的话
    static func focusElsewhere(_ record: SessionRecord, place: String) -> String {
        "VS Code 的键盘焦点在\(place)，未能移到「\(record.snapshot.displayTitle)」的输入框。为避免误输入，此消息未发送。请在电脑上点一下该会话的输入框后重试"
    }

    /// 同 pressInVSCode，核对完前台标签后做的是 act（回调 nil = 做了；回调原因 = 没做，原因给用户看）。wait：做完等几秒再还前台
    private static func actInVSCode(record: SessionRecord, done: String, skipped: String, wait: Double,
                                    completion: @escaping (Outcome) -> Void, act: @escaping (_ acted: @escaping (String?) -> Void) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(Outcome(ok: false, submitted: false, message: Delivery.needsAccessibility)); return
        }
        // 还没发过消息的会话：同 sendToVSCode，不开链接（会另开空白标签、按键按到那里）
        let untitled = record.snapshot.tabCandidates.isEmpty
        if untitled, siblings(of: record).count > 1 {
            completion(Outcome(ok: false, submitted: false, message: untitledAmbiguous(record).replacingOccurrences(of: "此消息未发送", with: skipped))); return
        }
        serialized { finish in
            let front = FrontReturn.capture()
            focusVSCodeSession(record: record, prompt: nil, openSession: !untitled) { focus in
                switch focus {
                case .notFound:
                    front.release()
                    completion(Outcome(ok: false, submitted: false, message: windowNotFound)); finish(0); return
                case .confirming:   // 前台留在 VS Code：切走的话框会被盖住
                    front.release()
                    completion(Outcome(ok: false, submitted: false, message: linkConfirmation(press: true))); finish(0); return
                case .focused: break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    reclaimFront { _ in
                        // 按「1 允许」、关标签按到别的会话上比发错消息还危险：同样先核对前台标签
                        if let problem = frontSessionProblem(record) {
                            front.restore()
                            completion(Outcome(ok: false, submitted: false, message: problem.replacingOccurrences(of: "此消息未发送", with: skipped)))
                            finish(0.4)
                            return
                        }
                        act { problem in
                            front.restore(after: problem == nil ? wait : 0.4)
                            completion(Outcome(ok: problem == nil, submitted: false, message: problem ?? done))
                            finish(problem == nil ? wait : 0.4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 关闭会话

    static let closeWhileWaiting = "Claude 正在等你确认。终端中的会话需输入 /exit 并按回车才能关闭，此时回车会替你选中确认框中的默认选项，因此会话未关闭。请先在确认卡片中作出选择，再关闭会话"

    /// 关闭会话：VS Code 里关掉它的标签页（同点标签上的 ×，Claude Code 随之结束这个会话）；终端里的 CLI 发 /exit。
    /// 关掉的会话进「历史会话」，之后可以恢复。正在开着的会话越积越多、VS Code 里标签越开越多时用（10-25）
    static func close(record: SessionRecord, source: SourceConnection?, completion: @escaping (Outcome) -> Void) {
        // 关掉了就取消标记（标记是为了多任务时找得到还开着的会话）
        let completion: (Outcome) -> Void = { outcome in
            if outcome.ok { DispatchQueue.main.async { AppState.shared.setMarked(record.key, false) } }
            completion(outcome)
        }
        if dryRun {
            lastDelivered = (record.key, "<close>", false)
            Log.write("[dry-run] 关闭会话 \(record.snapshot.name)")
            completion(Outcome(ok: true, submitted: false, message: "dry-run"))
            return
        }
        if viaAgent(record) {
            // Codex、OpenCode 这些：交给 watcher 里的插件（各家怎么关见 watcher/kiteline-watch.py 各插件的 close）
            agentRequest(["cmd": "agent_close"], record: record, source: source, submitted: false, completion: completion)
            return
        }
        if record.snapshot.isVSCode {
            // 还没有标题（没发过消息，或刚发、标题还在生成）：同项目的标签都叫「Claude Code」，认不出是哪个，不关
            if record.snapshot.tabCandidates.isEmpty, siblings(of: record).count > 1 {
                completion(Outcome(ok: false, submitted: false, message: "「\(record.snapshot.displayTitle)」还没有标题（尚未发送消息，或标题正在生成），"
                    + "VS Code 中同一项目的标签页都名为「Claude Code」，暂时无法确定要关闭哪一个。为避免关错，会话未关闭。刚发过消息的请稍后再试；未使用的空白标签页可在 VS Code 中直接关闭"))
                return
            }
            // 点菜单栏「文件 → 关闭编辑器」（Claude Code 的会话标签也是编辑器标签），不按 ⌘W：焦点在 Claude 的网页视图里时，
            // ⌘W 会被网页转发和菜单快捷键各执行一次，连着关掉两个标签（VS Code 靠网页视图得失焦点开关菜单快捷键，链接切标签时
            // 新旧标签的焦点事件先后不定）。10-27 连关 5 个会话，3 次多关了刚用过的另一个，其中一个正在发版
            actInVSCode(record: record, done: "已关闭会话", skipped: "会话未关闭", wait: 0.4, completion: completion) { acted in
                pressCloseEditorMenu(tries: 4, acted)
            }
        } else {
            // 终端里的 CLI（本机终端、tmux）：发 /exit。Claude 等确认时不发（回车会替你选中默认选项）
            if waitingProblem(record) != nil {
                completion(Outcome(ok: false, submitted: false, message: Self.closeWhileWaiting)); return
            }
            deliver(prompt: "/exit", to: record, source: source, submit: true) { outcome in
                completion(Outcome(ok: outcome.ok, submitted: false, message: outcome.ok ? "已关闭会话" : outcome.message))
            }
        }
    }

    /// 点 VS Code 菜单栏里的「关闭编辑器」：认 ⌘W 这个快捷键（不认文字，菜单跟着 VS Code 的显示语言变）。
    /// 菜单项要 VS Code 窗口拿到焦点后才可用，刚切过来还是灰的就隔 0.3 秒再看，最多 tries 次
    static func pressCloseEditorMenu(tries: Int, _ acted: @escaping (String?) -> Void) {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        let failed = "未能点到 VS Code 菜单中的「文件 → 关闭编辑器」。为避免关错，会话未关闭，请在 VS Code 中关闭该会话的标签页"
        guard let editor = Editor.running(), let bar = attribute(AXUIElementCreateApplication(editor.app.processIdentifier), kAXMenuBarAttribute) else {
            acted(failed); return
        }
        // ⌘W 且不带别的修饰键（kAXMenuItemModifierNone = 0；⇧⌘W 是「关闭窗口」）
        let item = children(bar as! AXUIElement).lazy.flatMap { children($0) }.flatMap { children($0) }.first {
            (attribute($0, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "W"
                && (attribute($0, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0
        }
        guard let item else { Log.write("关闭会话：VS Code 菜单里没有 ⌘W 那一项"); acted(failed); return }
        guard attribute(item, kAXEnabledAttribute) as? Bool == true else {
            if tries > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pressCloseEditorMenu(tries: tries - 1, acted) }
            } else {
                Log.write("关闭会话：VS Code 菜单的「关闭编辑器」一直是灰的"); acted(failed)
            }
            return
        }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if result != .success { Log.write("关闭会话：点「关闭编辑器」失败（\(result.rawValue)）") }
        acted(result == .success ? nil : failed)
    }

    // MARK: - Codex、OpenCode

    /// Claude Code 以外的 agent 的会话：消息、确认都交给 watcher 走协议
    static func viaAgent(_ record: SessionRecord) -> Bool { record.snapshot.agentID != "claude-code" }

    private static func agentRequest(_ payload: [String: Any], record: SessionRecord, source: SourceConnection?,
                                     submitted: Bool, completion: @escaping (Outcome) -> Void) {
        guard let source = source else { completion(Outcome(ok: false, submitted: false, message: "来源未连接")); return }
        var body = payload
        body["sessionId"] = record.snapshot.sessionId
        source.request(body, timeout: 30) { result in
            switch result {
            case .success(let response):
                let message = response["message"] as? String ?? "已送达"
                // 插件回了动作单：照着在这台 Mac 上按（远端来源的会话界面也在这台 Mac 上）
                if let actions = response["ui"] as? [[String: Any]], !actions.isEmpty {
                    DispatchQueue.main.async {
                        runUIActions(actions, record: record, source: source) { problem in
                            completion(problem.map { Outcome(ok: false, submitted: false, message: $0) }
                                       ?? Outcome(ok: true, submitted: submitted, message: message))
                        }
                    }
                    return
                }
                completion(Outcome(ok: true, submitted: submitted, message: message))
            case .failure(let error):
                completion(Outcome(ok: false, submitted: false, message: error.description))
            }
        }
    }

    /// 动作单里认得的程序（插件写 app 名，这里换成 bundle id）
    static let uiApps: [String: (bundleId: String, name: String)] = ["cursor": ("com.todesktop.230313mzl4w4u92", "Cursor")]

    /// 插件回的动作单（watcher 的 HOST_CAPS「ui.keys」，规范 docs/agent-plugins.md 3.3 的第一步），按顺序做：
    ///   focus  把 app 里打开了这个项目的窗口切到前台，核对确实在前台
    ///   plugin 回头请插件做一步（agent_ui），比如 Cursor 的配套扩展在窗口到前台后往对话输入框里填字
    ///   key    核对前台还是那个窗口，按键
    /// 和别的投递排队；哪一步不成就停下、不按键（宁可不发也不发错），告诉用户停在哪（填进去了没有）；做完把前台还给用户。
    /// 远端来源的会话界面也在这台 Mac 上，同样在这里做。problem 为 nil = 都做完了
    static func runUIActions(_ actions: [[String: Any]], record: SessionRecord, source: SourceConnection,
                             completion: @escaping (_ problem: String?) -> Void) {
        let shown = actions.lazy.compactMap { uiApps[$0["app"] as? String ?? ""]?.name }.first ?? "编辑器"
        var filled = false
        func problem(_ why: String) -> String {
            filled ? "消息已填入 \(shown) 的输入框，但未能自动发送：\(why)，请在电脑上按回车发送" : "此消息未发送：\(why)"
        }
        guard AXIsProcessTrusted() else { completion(problem(needsAccessibility)); return }
        serialized { finish in
            let front = FrontReturn.capture()
            var raised: NSRunningApplication?
            func fail(_ why: String) {
                front.restore()
                completion(problem(why))
                finish(0.4)
            }
            func step(_ index: Int) {
                guard index < actions.count else {
                    front.restore(after: 0.5)
                    completion(nil)
                    finish(0.5)
                    return
                }
                let action = actions[index]
                switch action["do"] as? String {
                case "focus":
                    guard let target = uiApps[action["app"] as? String ?? ""] else {
                        fail("当前版本的 Kiteline 不支持这一步，请更新 Kiteline"); return
                    }
                    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleId).first else {
                        fail("\(target.name) 没有在运行"); return
                    }
                    let folder = action["folder"] as? String ?? ""
                    front.target = app
                    guard raiseWindow(of: app, cwd: folder, remote: false) else {
                        fail("未找到 \(target.name) 中打开「\((folder as NSString).lastPathComponent)」的窗口"); return
                    }
                    raised = app
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                            fail("\(target.name) 未能切到前台（电脑可能已锁屏，或被其他窗口遮挡），为避免误输入到其他应用而停止"); return
                        }
                        step(index + 1)
                    }
                case "plugin":
                    source.request(["cmd": "agent_ui", "sessionId": record.snapshot.sessionId, "step": action["step"] as? String ?? ""],
                                   timeout: 15) { result in
                        DispatchQueue.main.async {
                            switch result {
                            case .success:
                                filled = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { step(index + 1) }
                            case .failure(let error):
                                fail(error.description)
                            }
                        }
                    }
                case "key":
                    guard let (code, flags) = keyCode(action["name"] as? String ?? "") else {
                        fail("当前版本的 Kiteline 不支持这一步，请更新 Kiteline"); return
                    }
                    if let raised, NSWorkspace.shared.frontmostApplication?.processIdentifier != raised.processIdentifier {
                        fail("\(shown) 已不在前台，为避免误输入到其他应用而停止"); return
                    }
                    postKeys(code, flags: flags, times: 1)
                    Log.write("动作单：在 \(shown) 按下 \(action["name"] as? String ?? "")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { step(index + 1) }
                default:
                    fail("当前版本的 Kiteline 不支持这一步，请更新 Kiteline")
                }
            }
            step(0)
        }
    }

    /// macOS 27 起「辅助功能」这个隐私权限改名「设备控制和数据访问」（系统设置 → 隐私与安全性 里），提示里用当前系统的叫法
    static var accessibilityName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "设备控制和数据访问" : "辅助功能"
    }

    static var needsAccessibility: String {
        "此电脑尚未为 Kiteline 开启「\(accessibilityName)」权限（系统设置 → 隐私与安全性 → \(accessibilityName)），无法模拟按键"
    }

    // MARK: - VS Code

    static let windowNotFound = "未找到该会话所在的 VS Code 窗口（VS Code 未运行，或打开了多个窗口而无法确定目标）"

    private static func sendToVSCode(prompt: String, record: SessionRecord, submit: Bool, checkWaiting: Bool = true,
                                     completion: @escaping (Outcome) -> Void) {
        // 新版 Claude Code 扩展（2.1.30x 起）：会话标签开着时，链接带进来的文字会被丢掉
        // （VS Code 右下角提示「Session is already open. Your prompt was not applied」）。
        // 所以：链接只用来切到这个会话（扩展会把这个标签切到前面并给它焦点），再用「辅助功能」粘贴、回车。
        // 同一个窗口里常开着好几个会话：粘贴前核对前台标签确实是这个会话，对不上宁可不发，绝不能发进别的会话。
        guard AXIsProcessTrusted() else {
            completion(Outcome(ok: false, submitted: false, message: needsAccessibilityToSend)); return
        }
        // 还没发过消息的会话（没有标题）：扩展的链接找不到它，会另开一个空白的 Claude Code 标签，
        // 消息就粘进了新标签、成了另一个会话，原来那个还是空的（06 在 Windows 上实测，Mac 同样）。
        // 这种会话不开链接，只把窗口切到前台，前台标签正好是它（同项目里只有它一个）才粘贴；同项目还有别的会话时认不出是哪个，动 VS Code 之前就拒绝
        let titles = record.snapshot.tabCandidates
        let untitled = titles.isEmpty
        if untitled, siblings(of: record).count > 1 {
            completion(Outcome(ok: false, submitted: false, message: untitledAmbiguous(record))); return
        }
        // 发完把前台还给用户原来在用的程序（在 Kiteline 里发消息的，回到 Kiteline 接着打字；见 FrontReturn）。
        // 只填不提交的（面板回复框「预填」）不还：用户就是要到 VS Code 里再看一眼。和别的投递排队，一条发完再发下一条
        serialized { finish in
            let front = FrontReturn.capture()
            // 粘贴前要看会话是不是「仍在别处打开」（ClaudeInput.openHereIfHeld）：网页辅助功能树先开上，切标签这一秒里正好建好
            let editor = Editor.running()?.app
            let treeReady = Date().addingTimeInterval(editor.map { ClaudeInput.holdWebTree($0) } == true ? 0 : 3)
            let done: (Outcome, Double) -> Void = { outcome, wait in
                if submit || !outcome.ok { front.restore(after: wait) } else { front.release() }
                if let editor { ClaudeInput.releaseWebTree(editor) }
                completion(outcome)
                finish(wait)
            }
            focusVSCodeSession(record: record, prompt: nil, openSession: !untitled) { focus in
                switch focus {
                case .notFound:
                    done(Outcome(ok: false, submitted: false, message: windowNotFound), 0.4); return
                case .confirming:   // 不还前台：切走的话框会被盖住，用户在电脑前也像是它自己消失了
                    front.release()
                    if let editor { ClaudeInput.releaseWebTree(editor) }
                    completion(Outcome(ok: false, submitted: false, message: linkConfirmation())); finish(0); return
                case .focused: break
                }
                // 粘贴之后：回车提交（只填不提交的到此为止）。input = 粘贴前核对过焦点在的那个输入框；
                // pasted = 粘贴后它里面的文字，回车后拿来核对提交上没有；retried = 回车落空、这是补按的那一下
                func submitPasted(into input: AXUIElement? = nil, pasted: String? = nil, retried: Bool = false) {
                    guard submit else {
                        done(Outcome(ok: true, submitted: false, message: "已填入输入框"), 0.4); return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (retried ? 0 : 0.35)) {
                        // 回车前再看一眼：焦点要是跑到别的应用 / 别的会话，就不按了（文字留在输入框里）
                        reclaimFront { _ in
                            // 第一下回车只是慢了一拍、这会儿已经提交上的，不再补按
                            if retried, let input, let pasted, submittedFrom(input, pasted: pasted, prompt: prompt) {
                                done(Outcome(ok: true, submitted: true, message: "已提交"), 0.4); return
                            }
                            if let problem = frontSessionProblem(record) {
                                done(Outcome(ok: false, submitted: false, message: "文字已粘贴，但提交时出现问题：" + problem), 0.4); return
                            }
                            // 斜杠命令（/compact 这类）：输入框可能弹出命令菜单，第一下回车只是选中，再按一下才执行；
                            // 没弹菜单时第二下落在空输入框上，什么也不会发生
                            let slash = prompt.hasPrefix("/") && !prompt.contains("\n")
                            // 焦点离开了输入框（比如跳到了终端）：回车会按在那里，不按。斜杠命令的焦点落在面板里的命令菜单上不算
                            if let input, let editor, let place = ClaudeInput.focusLeft(input, app: editor, menuOK: slash) {
                                Log.write("粘贴后焦点到了\(place)，不按回车")
                                done(Outcome(ok: false, submitted: false, message: "文字已粘贴，但提交前 VS Code 的键盘焦点移到了\(place)，为避免误操作，未按回车。请在电脑上检查该会话的输入框"), 0.4); return
                            }
                            if checkWaiting, let problem = waitingMidway(record) {
                                done(Outcome(ok: true, submitted: false, message: problem), 0.4); return
                            }
                            postKey(36)
                            if slash, !retried {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { postKey(36) }
                            }
                            // 回车后核对：输入框里不再是这段话才算提交上。读不出输入框（网页辅助功能树没建好）的照旧当作已提交
                            guard let input, let pasted else {
                                done(Outcome(ok: true, submitted: true, message: "已提交"), slash ? 0.9 : 0.4); return
                            }
                            poll(slash && !retried ? 2.0 : 1.5, until: { submittedFrom(input, pasted: pasted, prompt: prompt) }) { cleared in
                                if cleared { done(Outcome(ok: true, submitted: true, message: "已提交"), 0.4); return }
                                let front = frontAppName()
                                guard !retried else {
                                    Log.write("补按回车后输入框里仍是这段话（前台是 \(front ?? "VS Code")），按未提交报")
                                    done(Outcome(ok: true, submitted: false, message: "消息已在 VS Code 输入框中，但按回车后未能提交"
                                                 + (front.map { "（电脑前台被「\($0)」占用）" } ?? "") + "。请在电脑上检查该会话的输入框"), 0.4); return
                                }
                                Log.write("回车后输入框里仍是这段话（前台是 \(front ?? "VS Code")），补按一次")
                                submitPasted(into: input, pasted: pasted, retried: true)
                            }
                        }
                    }
                }
                // 粘贴后核对：输入框里的字变了才算粘上（前台被别的程序抢走时，⌘V 落在那个程序里，输入框还是空的）。
                // 落空的叫回 VS Code、光标放回输入框再粘一次；还不行就报没发出去（这时输入框是空的，手机上可以放心重发）
                func pasteChecked(into input: AXUIElement?, retried: Bool = false) {
                    guard let input, let editor, let before = ClaudeInput.text(of: input) else {
                        pasteText(prompt); submitPasted(into: input); return
                    }
                    pasteText(prompt)
                    poll(1.2, until: { ClaudeInput.text(of: input).map { $0 != before } ?? true }) { landed in
                        if landed { submitPasted(into: input, pasted: ClaudeInput.text(of: input)); return }
                        let front = frontAppName()
                        guard !retried else {
                            Log.write("重新粘贴后输入框仍没变（前台是 \(front ?? "VS Code")），不发")
                            done(Outcome(ok: false, submitted: false, message: "未能将消息粘贴进 VS Code 的输入框"
                                         + (front.map { "（电脑前台被「\($0)」占用）" } ?? "") + "，消息未发送"), 0.4); return
                        }
                        Log.write("粘贴后输入框没变（前台是 \(front ?? "VS Code")），叫回 VS Code 再粘一次")
                        reclaimFront { _ in
                            if let problem = frontSessionProblem(record) {
                                done(Outcome(ok: false, submitted: false, message: problem), 0.4); return
                            }
                            ClaudeInput.refocus(input)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                if let place = ClaudeInput.focusLeft(input, app: editor) {
                                    done(Outcome(ok: false, submitted: false, message: focusElsewhere(record, place: place)), 0.4); return
                                }
                                pasteChecked(into: input, retried: true)
                            }
                        }
                    }
                }
                // 等扩展把会话标签切到前面
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    reclaimFront { _ in
                        if let problem = frontSessionProblem(record) {
                            done(Outcome(ok: false, submitted: false, message: problem), 0.4); return
                        }
                        // 会话在终端、别的窗口还开着（或窗口刚重新加载、之前的 Claude 进程还没退）：标签里是「仍在别处打开」，
                        // 输入框不能用，粘贴没反应。替用户按「Open here anyway」，等输入框能用再粘贴
                        guard let editor else { pasteText(prompt); submitPasted(); return }
                        ClaudeInput.openHereIfHeld(app: editor, treeReady: treeReady) { pressed in
                            reclaimFront { _ in
                                if pressed, let problem = frontSessionProblem(record) {
                                    done(Outcome(ok: false, submitted: false, message: problem), 0.4); return
                                }
                                // 键盘焦点得在这个会话的输入框里：标签切过来了，焦点却可能还在终端、编辑器里（见 ClaudeInput.Focus），那就先把光标放进输入框
                                ClaudeInput.ensureFocus(app: editor, titles: titles, needInput: true, deadline: treeReady.addingTimeInterval(2)) { focus in
                                    var input: AXUIElement?
                                    switch focus {
                                    case .elsewhere(let place):
                                        done(Outcome(ok: false, submitted: false, message: focusElsewhere(record, place: place)), 0.4); return
                                    case .input(let found): input = found
                                    case .panel: break
                                    case .unknown: Log.write("读不出 VS Code 的焦点（网页辅助功能树未就绪），照常粘贴")
                                    }
                                    EditorAlerts.shared.notePaste(prompt)
                                    pasteChecked(into: input)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    static var needsAccessibilityToSend: String {
        "发送失败：新版 Claude Code 扩展不再接受从外部传入已打开会话的文字，Kiteline 需要通过「\(accessibilityName)」权限将消息粘贴到输入框。"
            + "请在电脑的「系统设置 → 隐私与安全性 → \(accessibilityName)」中开启 Kiteline（若列表中已有 Kiteline 且已开启但未生效，请先选中并点击「−」删除，再在「Kiteline 设置 → 权限」中点击「打开系统设置」重新添加）"
    }

    /// 粘贴一段文字（剪贴板用完还原）
    static func pasteText(_ text: String) {
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        board.clearContents()
        board.setString(text, forType: .string)
        postKey(9, flags: .maskCommand)   // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

    /// 前台是不是 VS Code、当前标签是不是这个会话；不是的话返回原因（nil = 没问题）
    static func frontSessionProblem(_ record: SessionRecord) -> String? {
        guard let editor = Editor.running(), editorIsFrontmost() else {
            return "VS Code 不在前台（电脑可能已锁屏，或被其他应用遮挡）。为避免误输入到其他应用，此消息未发送"
        }
        // 要打开 claude.ai 的 Artifact 链接弹的「打开外部网站」框、投递时粘进了终端弹的「粘贴到终端?」框：替用户取消
        // （见 EditorAlerts.cancelAutomatic），不然这条消息发不出去
        if editorShowsDialog(editor.app), !EditorAlerts.shared.cancelAutomatic(in: editor.app) || editorShowsDialog(editor.app) {
            return "电脑上的 VS Code 正在显示对话框，需要先在电脑上处理。为避免误操作，此消息未发送"
        }
        let want = record.snapshot.tabCandidates
        guard let (front, project) = frontTab(editor.app) else {
            return "无法读取 VS Code 当前标签页，无法确认是否为「\(record.snapshot.displayTitle)」。为避免发错会话，此消息未发送"
        }
        // 扩展有时给会话标签起通用名「Claude Code」：这个项目里只开着这一个会话时，切过去的只能是它
        let folder = (record.snapshot.cwd as NSString).lastPathComponent
        let siblings = Self.siblings(of: record)
        if front == "Claude Code", project == folder, siblings.count == 1 { return nil }
        // 还没发过消息的新会话没有标题，VS Code 里的标签都叫「Claude Code」，同一个项目里有好几个时认不出是哪个
        if want.isEmpty {
            if siblings.count > 1 { return untitledAmbiguous(record) }
            // 没开链接切标签（见 sendToVSCode），前台不是它的标签就不发
            return "「\(record.snapshot.displayTitle)」在 VS Code 中尚未发送过消息，无法自动切换到它的标签页（VS Code 当前为「\(front)」）。为避免发错会话，此消息未发送。"
                + "请先在 VS Code 中切到该会话的标签页（名称为「Claude Code」）后再发送"
        }
        guard want.contains(where: { tabTitle(front, matches: $0) }) else {
            Log.write("前台标签「\(front)」不是会话「\(record.snapshot.displayTitle)」，不投递")
            return "未能切换到会话「\(record.snapshot.displayTitle)」（VS Code 当前为「\(front)」）。为避免发错会话，此消息未发送。"
                + "请先在 VS Code 中打开该会话的标签页后再发送"
        }
        return nil
    }

    /// 同一台机器、同一个目录下的会话（含它自己）
    static func siblings(of record: SessionRecord) -> [SessionRecord] {
        AppState.shared.store.records.filter { $0.sourceId == record.sourceId && $0.snapshot.cwd == record.snapshot.cwd }
    }

    static func untitledAmbiguous(_ record: SessionRecord) -> String {
        "「\(record.snapshot.displayTitle)」在 VS Code 中尚未发送过消息，同一项目中还有其他会话，标签页都名为「Claude Code」，无法识别目标会话。为避免发错会话，此消息未发送。"
            + "请先在 VS Code 中发送第一条消息；如不再使用，关闭该空白标签页即可"
    }

    /// VS Code 前台窗口标题拆成（当前标签名, 项目名）：「● 首页卡片间距 — ccpulse [SSH: 10.168.1.10]」→（首页卡片间距, ccpulse）
    static func frontTab(_ app: NSRunningApplication) -> (String, String)? {
        guard let full = frontWindowTitle(app) else { return nil }
        let parts = full.components(separatedBy: " — ")
        let tab = (parts.first ?? full).replacingOccurrences(of: "● ", with: "").trimmingCharacters(in: .whitespaces)
        let project = parts.count > 1 ? (parts[1].components(separatedBy: " [").first ?? parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (tab, project)
    }

    /// VS Code 正弹着系统级的对话框：主进程的确认框（焦点窗口就是它）或贴在窗口上的表单。
    /// 画在窗口网页里的对话框（扩展链接的确认框就是）这里看不出来，那种由 EditorSettings 事先免掉、免不掉的走 Focus.confirming
    static func editorShowsDialog(_ app: NSRunningApplication) -> Bool {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        guard let focused = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) else { return false }
        let window = focused as! AXUIElement
        if let subrole = attribute(window, kAXSubroleAttribute) as? String, [kAXDialogSubrole, kAXSystemDialogSubrole].contains(subrole) {
            return true
        }
        let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.contains { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole }
    }

    static func frontWindowTitle(_ app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let focused = window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard let full = title as? String, !full.isEmpty else { return nil }
        return full
    }

    /// 标签名和会话标题对得上（VS Code 可能截断长标题，两边都按前缀比；拿用户的话当标签名时里面可能有换行，空白都并成一个空格，同扩展）
    static func tabTitle(_ tab: String, matches title: String) -> Bool {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "…", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let a = clean(tab), b = clean(title)
        guard a.count >= 2, b.count >= 2 else { return false }
        if a == b { return true }
        let n = min(a.count, b.count, 16)
        return n >= 4 && a.prefix(n) == b.prefix(n)
    }

    /// 先把会话所在的窗口切到前台（扩展 URI 只会发给最近使用的窗口），
    /// 再用扩展 URI 切到这个会话（prompt 非空时顺带预填）。
    ///
    /// 找窗口的顺序：
    /// 1. VS Code 自己记录的已打开窗口（storage.json）里找工作区根目录包含会话目录的那个，
    ///    用它自己的地址做深链 —— VS Code 会聚焦已有窗口，不需要任何权限；
    /// 2. 有辅助功能权限时按窗口标题找；
    /// 3. 都找不到：VS Code 只开了一个窗口就发给它，否则报错（宁可不发也不能发错会话）。
    /// openSession = false：只切窗口、不开链接（还没发过消息的会话，见 sendToVSCode）
    private static func focusVSCodeSession(record: SessionRecord, prompt: String?, openSession: Bool = true,
                                           completion: @escaping (Focus) -> Void) {
        guard let editor = Editor.running() else { completion(.notFound); return }
        let source = AppState.shared.config.sources.first(where: { $0.id == record.sourceId })
        // 扩展链接免确认（见 EditorSettings）；刚写进设置的，VS Code 要一会儿才读到，开链接前多等一下
        let trust = openSession ? EditorSettings.trustClaudeLinks(scheme: editor.scheme) : (trusted: true, wrote: false)
        let afterFocus: (@escaping () -> Void) -> Void
        if let link = WindowLocator.folderLink(for: record, source: source, scheme: editor.scheme) {
            Log.write("聚焦会话所在窗口：\(link.absoluteString.removingPercentEncoding ?? link.absoluteString)")
            afterFocus = { WindowLocator.open(link, completion: $0) }
        } else if AXIsProcessTrusted(), raiseWindow(of: editor.app, cwd: record.snapshot.cwd,
                                                    remote: record.kind == .ssh) {
            afterFocus = { $0() }
        } else if WindowLocator.windowCount(of: editor.app) <= 1 {
            editor.app.activate(options: [.activateIgnoringOtherApps])
            afterFocus = { $0() }
        } else {
            Log.write("找不到会话「\(record.snapshot.name)」所在的 VS Code 窗口，放弃投递")
            completion(.notFound)
            return
        }
        afterFocus {
            guard openSession else {
                Log.write("会话「\(record.snapshot.name)」尚未发送过消息，不打开会话链接，只切到所在窗口")
                completion(.focused)
                return
            }
            openSessionLink(record: record, prompt: prompt, scheme: editor.scheme, after: trust.wrote ? 1.5 : 0.7) { opened in
                completion(!opened ? .notFound : trust.trusted ? .focused : .confirming)
            }
        }
    }

    enum Focus {
        case focused
        case notFound
        /// 开了扩展链接，但 VS Code 会先弹确认框（没能替用户设成免确认）：这次不粘贴、不按键，前台留在 VS Code 等用户点
        case confirming
    }

    /// 没能替用户免掉扩展链接的确认框（Focus.confirming）时回给手机的话
    static func linkConfirmation(press: Bool = false) -> String {
        press
            ? "电脑上的 VS Code 弹出了确认框，询问是否允许 Claude Code 扩展打开链接。请在电脑上勾选「不再询问」并点击「打开」后重试，未按下按键"
            : "电脑上的 VS Code 弹出了确认框，询问是否允许 Claude Code 扩展打开链接。请在电脑上勾选「不再询问」并点击「打开」后重新发送，此消息未发送"
    }

    private static func openSessionLink(record: SessionRecord, prompt: String?, scheme: String, after delay: TimeInterval,
                                        completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var components = URLComponents()
            components.scheme = scheme
            components.host = "anthropic.claude-code"
            components.path = "/open"
            var items = [URLQueryItem(name: "session", value: record.snapshot.sessionId)]
            if let prompt = prompt { items.append(URLQueryItem(name: "prompt", value: prompt)) }
            components.queryItems = items
            // URLComponents 不转义 + 和 &（属于合法查询字符），扩展用 URLSearchParams 解析会把 + 当空格
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            guard let url = components.url else { completion(false); return }
            Log.write("打开 \(scheme)://anthropic.claude-code/open（会话 \(record.snapshot.name)）")
            NSWorkspace.shared.open(url)
            completion(true)
        }
    }

    /// VS Code 系编辑器（URI scheme 各不相同）
    struct Editor {
        var app: NSRunningApplication
        var scheme: String

        static let known: [(bundleId: String, scheme: String)] = [
            ("com.microsoft.VSCode", "vscode"),
            ("com.microsoft.VSCodeInsiders", "vscode-insiders"),
            ("com.vscodium", "vscodium"),
            ("com.todesktop.230313mzl4w4u92", "cursor"),
        ]

        static func running() -> Editor? {
            for (bundleId, scheme) in known {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                    return Editor(app: app, scheme: scheme)
                }
            }
            return nil
        }
    }

    /// 按窗口标题找会话所在窗口。VS Code 默认标题形如「文件 — 根目录名」，
    /// Remote-SSH 窗口的根目录名后面带「[SSH: 主机]」。会话 cwd 可能是工作区根的子目录，
    /// 所以从最深的一级目录往上逐级匹配。
    static func raiseWindow(of app: NSRunningApplication, cwd: String, remote: Bool) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return false }
        let titles: [String] = windows.map { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return title as? String ?? ""
        }
        let folders = cwd.split(separator: "/").map(String.init).reversed()
        for folder in folders where !folder.isEmpty {
            for (window, title) in zip(windows, titles) where windowTitle(title, matches: folder, remote: remote) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                app.activate(options: [.activateIgnoringOtherApps])
                Log.write("已置前窗口：\(title)")
                return true
            }
        }
        return false
    }

    /// 远端窗口标题里的主机名是 VS Code 里填的写法（可能是别名也可能是 IP），这里只认目录名
    static func windowTitle(_ title: String, matches folder: String, remote: Bool) -> Bool {
        let segments = title.components(separatedBy: " — ").flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if remote {
            return segments.contains { $0.hasPrefix("\(folder) [SSH: ") }
        }
        return !title.contains("[SSH:") && segments.contains(folder)
    }

    // MARK: - 本机终端

    /// record：给了就在回车前再看一眼 Claude 是不是刚弹出了确认框（见 waitingMidway）
    private static func sendToTerminal(prompt: String, pid: Int, submit: Bool, record: SessionRecord? = nil,
                                       completion: @escaping (Outcome) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(Outcome(ok: false, submitted: false, message: needsAccessibility)); return
        }
        serialized { finish in
            let front = FrontReturn.capture()
            guard let host = activateHostApp(of: pid) else {
                front.release()
                completion(Outcome(ok: false, submitted: false, message: "未找到该 CLI 会话所在的终端程序")); finish(0); return
            }
            front.target = host
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(prompt, forType: .string)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                postKey(9, flags: .maskCommand)   // ⌘V
                guard submit else {
                    front.release()
                    completion(Outcome(ok: true, submitted: false, message: "已粘贴到终端")); finish(0); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if let record, let problem = waitingMidway(record, into: "终端") {
                        front.restore()
                        completion(Outcome(ok: true, submitted: false, message: problem)); finish(0.4); return
                    }
                    postKey(36)
                    front.restore()
                    completion(Outcome(ok: true, submitted: true, message: "已提交"))
                    finish(0.4)
                }
            }
        }
    }

    /// 沿父进程链往上找第一个有界面的程序（Terminal、iTerm、VS Code 内置终端……）并激活；返回激活的那个程序
    static func activateHostApp(of pid: Int) -> NSRunningApplication? {
        var current = pid_t(pid)
        for _ in 0..<40 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                app.activate(options: [.activateIgnoringOtherApps])
                return app
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - 按键

    static func keyCode(_ key: String) -> (CGKeyCode, CGEventFlags)? {
        switch key.lowercased() {
        case "enter", "return": return (36, [])
        case "esc", "escape": return (53, [])
        case "1": return (18, [])
        case "2": return (19, [])
        case "3": return (20, [])
        case "4": return (21, [])
        // 切权限模式（Claude Code 里的 ⇧Tab：手动 → 自动改文件 → 计划 → 自动 → 手动……）
        case "shift+tab": return (48, .maskShift)
        default: return nil
        }
    }

    /// 连按几次，每次隔 0.25 秒（Claude Code 要来得及切到下一档）
    static func postKeys(_ code: CGKeyCode, flags: CGEventFlags, times: Int) {
        for index in 0..<max(1, times) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.25) { postKey(code, flags: flags) }
        }
    }

    /// 前台是不是 VS Code 系编辑器（按回车前确认，免得回车打进用户正在用的别的 App）
    static func editorIsFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Editor.known.contains { $0.bundleId == front }
    }

    /// 前台不是 VS Code 时是谁（给用户看）；是 VS Code = nil
    static func frontAppName() -> String? {
        editorIsFrontmost() ? nil : NSWorkspace.shared.frontmostApplication?.localizedName ?? "其他程序"
    }

    /// 回车后输入框里不再是粘贴后的那段话：提交上了。开头一截还在的不算（回车被输入法拿去上屏、或变成了换行）；读不出的不拦
    static func submittedFrom(_ input: AXUIElement, pasted: String, prompt: String) -> Bool {
        guard let now = ClaudeInput.text(of: input) else { return true }
        let head = String(prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(24))
        return now != pasted && (head.count < 4 || !now.contains(head))
    }

    /// 每 0.15 秒看一次 check，成立或到时间（秒）就回调（主线程）
    static func poll(_ timeout: Double, until check: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func step() {
            if check() { then(true); return }
            guard Date() < deadline else { then(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step() }
        }
        step()
    }

    /// VS Code 刚把窗口切到前面，又被别的程序挤到后台（比如刚启动的程序抢了前台）：叫回来一次，0.6 秒后再往下走。
    /// 本来就在前台直接走（reclaimed = false）。叫没叫回来、回来的是不是那个窗口，由调用方接着核对
    static func reclaimFront(_ then: @escaping (_ reclaimed: Bool) -> Void) {
        guard !editorIsFrontmost(), let editor = Editor.running() else { then(false); return }
        Log.write("VS Code 被挤到了后台（前台是 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知")），叫回前台再试")
        if AXIsProcessTrusted() {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(editor.app.processIdentifier),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        editor.app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { then(true) }
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        // 带上标记：投递期间截用户按键时（KeyHold）放行自己发的
        down?.setIntegerValueField(.eventSourceUserData, value: KeyHold.marker)
        up?.setIntegerValueField(.eventSourceUserData, value: KeyHold.marker)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
