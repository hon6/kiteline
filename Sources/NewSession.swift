import AppKit
import ApplicationServices
import Foundation
import KitelineKit

/// 在指定项目里开一个新的 Claude Code 会话（手机和 Mac 上的「新任务」）。
///
/// 1. 项目已经在 VS Code 里开着：用窗口深链把它切到前台；没开着就用同样的深链新开一个窗口（本机或 Remote-SSH）
/// 2. 打开扩展 URI `vscode://anthropic.claude-code/open?prompt=<内容>`：不带 session 时扩展新建一个对话标签并预填内容
///    （扩展源码 handleUri → primaryEditor.open → createPanel(undefined, prompt)）
/// 3. 需要提交时，在新标签里找到填着这段话的输入框，按旁边的「发送」（ClaudeInput；模拟回车落不到没聚焦的输入框上）
enum NewSession {
    struct Outcome {
        var ok: Bool
        var submitted: Bool
        var openedWindow: Bool
        var message: String
    }

    /// 自检用：最近一次（dry-run）要开的会话
    private(set) static var lastStarted: (sourceId: String, cwd: String, prompt: String)?

    /// sessionId 非空 = 恢复这段旧对话（扩展 createPanel(sessionId, prompt) 会在标签里接着这段对话）。
    /// 要自动提交时，得等新标签加载好、内容填进输入框才能按发送（最多等 45 秒）：给了 accepted 的，标签开出来就先回一次 accepted
    /// （手机那边的请求只等 12 秒），提交的结果再走 completion；没给的照旧只在最后回 completion
    /// returnFocus：做完把前台还给用户原来在用的程序（开窗口、开标签都会让 VS Code 跳到前台；新标签加载完它还会再抢一次，多守 8 秒）
    /// inEditor：一定在 VS Code 里开（不走后台托管，见 Hosted）
    static func start(source: SourceConfig, cwd: String, prompt: String, submit: Bool, sessionId: String? = nil,
                      returnFocus: Bool = true, inEditor: Bool = false,
                      accepted: ((Outcome) -> Void)? = nil, completion reply: @escaping (Outcome) -> Void) {
        // 远端项目默认不开 VS Code：在那台电脑上后台运行 Claude Code；起不来再照旧开 VS Code
        if !inEditor, Hosted.wanted(source) {
            // 先回过手机的，退回 VS Code 时就别再回第二次
            var early = accepted
            let first: ((Outcome) -> Void)? = accepted == nil ? nil : { outcome in early?(outcome); early = nil }
            Hosted.start(source: source, cwd: cwd, prompt: prompt, submit: submit, sessionId: sessionId, accepted: first) { result in
                switch result {
                case .success(let outcome):
                    reply(outcome)
                case .failure(let error) where ProcessInfo.processInfo.environment["CCPULSE_TEST_NO_EDITOR"] == "1":
                    // 测试实例：不退回 VS Code（不然会在用户屏幕上开窗口、抢前台）
                    reply(Outcome(ok: false, submitted: false, openedWindow: false, message: "（测试）后台启动失败：\(error.description)"))
                case .failure(let error):
                    start(source: source, cwd: cwd, prompt: prompt, submit: submit, sessionId: sessionId, returnFocus: returnFocus,
                          inEditor: true, accepted: early) { outcome in
                        var outcome = outcome
                        if let note = Hosted.fallbackNote(error) { outcome.message += "（\(note)）" }
                        reply(outcome)
                    }
                }
            }
            return
        }
        // 远端项目还没在 VS Code 里开着：新开的窗口要靠 Remote-SSH 扩展连过去，先确认装好（没装就装上，VS Code 没开着也能装）
        let scheme = Delivery.Editor.running()?.scheme ?? "vscode"
        guard source.kind == .ssh, !Delivery.dryRun, let host = source.sshHost, !host.isEmpty,
              WindowLocator.openFolder(cwd: cwd, kind: .ssh, host: host, port: source.sshPort, scheme: scheme) == nil else {
            begin(source: source, cwd: cwd, prompt: prompt, submit: submit, sessionId: sessionId, returnFocus: returnFocus,
                  note: nil, accepted: accepted, completion: reply)
            return
        }
        var accepted = accepted
        RemoteSSH.prepare(source: source, scheme: scheme, installing: {
            // 装扩展要十几秒：要自动提交的先回手机，后面的结果照常走 completion
            guard submit, !prompt.isEmpty, let early = accepted else { return }
            accepted = nil
            early(Outcome(ok: true, submitted: true, openedWindow: true, message: "正在为 VS Code 安装 Remote-SSH 扩展，安装后将打开项目窗口并自动提交"))
        }) { result in
            switch result {
            case .failure(let error):
                Log.write("新会话：无法打开远端项目窗口（\(error.description)）")
                reply(Outcome(ok: false, submitted: false, openedWindow: false, message: error.description))
            case .success(let note):
                begin(source: source, cwd: cwd, prompt: prompt, submit: submit, sessionId: sessionId, returnFocus: returnFocus,
                      note: note, accepted: accepted, completion: reply)
            }
        }
    }

    /// note：要附在结果后面告诉用户的提醒（如 VS Code 用不上的密钥文件）
    private static func begin(source: SourceConfig, cwd: String, prompt: String, submit: Bool, sessionId: String?,
                              returnFocus: Bool, note: String?,
                              accepted: ((Outcome) -> Void)?, completion reply: @escaping (Outcome) -> Void) {
        let front = returnFocus && !Delivery.dryRun ? FrontReturn.capture(automation: 60, holdKeys: false) : nil
        var keepFront = false
        let completion: (Outcome) -> Void = { outcome in
            if !keepFront { front?.restore(guardFor: 8) } else { front?.release() }
            var outcome = outcome
            if let note { outcome.message += "。提醒：\(note)" }
            reply(outcome)
        }
        if Delivery.dryRun {
            lastStarted = (source.id, cwd, prompt)
            let what = sessionId.map { "恢复会话 \($0)" } ?? "新会话"
            Log.write("[dry-run] \(what) \(source.displayName):\(cwd)（submit=\(submit)）：\(prompt.prefix(120))")
            completion(Outcome(ok: true, submitted: submit, openedWindow: false, message: "dry-run"))
            return
        }
        let host = source.kind == .ssh ? source.sshHost : nil
        if source.kind == .ssh && (host ?? "").isEmpty {
            completion(Outcome(ok: false, submitted: false, openedWindow: false, message: "此远端来源未配置主机地址")); return
        }
        let editor = Delivery.Editor.running()
        let scheme = editor?.scheme ?? "vscode"
        // 扩展链接免确认（见 EditorSettings）。写不进设置的照样开链接（人在电脑前点一下就行），只是前台留在 VS Code、回话里说明
        let linkTrusted = EditorSettings.trustClaudeLinks(scheme: scheme).trusted
        var opened = false
        var target: URL?
        /// 窗口标题里的项目名（工作区根目录名）：提交时先在这个项目的窗口里找新标签
        var project = (cwd as NSString).lastPathComponent
        if let folder = WindowLocator.openFolder(cwd: cwd, kind: source.kind, host: host, port: source.sshPort, scheme: scheme) {
            target = WindowLocator.link(folder, scheme: scheme)
            project = (folder.path as NSString).lastPathComponent
        } else {
            target = WindowLocator.newWindowLink(cwd: cwd, host: host, port: source.sshPort, scheme: scheme, forceNew: editor != nil)
            opened = true
        }
        guard let windowURL = target else {
            completion(Outcome(ok: false, submitted: false, openedWindow: false, message: "项目路径不合法：\(cwd)")); return
        }
        Log.write("新会话：\(opened ? "新开" : "切到")窗口 \(windowURL.absoluteString.removingPercentEncoding ?? windowURL.absoluteString)")
        // 窗口切过去（转交启动参数的进程退出）以后再开始等：扩展链接只发给当前活动窗口
        let windowShown = DispatchGroup()
        windowShown.enter()
        WindowLocator.open(windowURL) { windowShown.leave() }
        // VS Code 在虚拟屏幕上运行时，Kiteline 新开的窗口也挪过去（VS Code 是 Kiteline 拉起来的，恢复出来的窗口一起挪）
        if opened || editor == nil {
            VirtualScreen.shared.adoptNewWindows(project: project, remote: source.kind == .ssh, all: editor == nil)
        }
        // 新开的窗口要等 VS Code 和扩展加载完（远端还要连 SSH、起服务端），扩展 URI 只发给当前活动窗口
        let wait: Double = opened ? (source.kind == .ssh ? 15 : 7) : (editor == nil ? 7 : 0.8)
        var accepted = accepted
        // 远端窗口里 Claude Code 扩展跑在远端：没装时扩展链接会被悄悄丢掉，先装上再发（和上面的等待同时进行）。
        // 窗口还在连、服务端还没起来时发的链接 VS Code 会先存着，连好再交给扩展（10-23 实测），所以不用等窗口连好
        func whenReady(_ go: @escaping () -> Void) {
            windowShown.notify(queue: .main) {
                let sendAt = Date().addingTimeInterval(wait)
                guard source.kind == .ssh else { DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: go); return }
                RemoteSSH.ensureRemoteExtension(source: source, scheme: scheme, installing: {
                    guard submit, !prompt.isEmpty, let early = accepted else { return }
                    accepted = nil
                    early(Outcome(ok: true, submitted: true, openedWindow: opened,
                                  message: "正在远端主机上安装 Claude Code 扩展（首次约需 1 分钟），安装后将自动提交"))
                }) { state in
                    if case .failed(let why) = state {
                        completion(Outcome(ok: false, submitted: false, openedWindow: opened,
                                           message: "远端主机未安装 Claude Code 扩展，自动安装失败（\(why)）；请在 VS Code 中为该主机安装 Claude Code 扩展"))
                        return
                    }
                    // 刚装上的扩展，窗口要过几秒才认出来
                    var delay = max(0, sendAt.timeIntervalSinceNow)
                    if case .installed = state { delay = max(delay, 5) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: go)
                }
            }
        }
        whenReady {
            var components = URLComponents()
            components.scheme = scheme
            components.host = "anthropic.claude-code"
            components.path = "/open"
            var items: [URLQueryItem] = []
            if let sessionId = sessionId { items.append(URLQueryItem(name: "session", value: sessionId)) }
            if !prompt.isEmpty { items.append(URLQueryItem(name: "prompt", value: prompt)) }
            components.queryItems = items
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = components.url else {
                completion(Outcome(ok: false, submitted: false, openedWindow: opened, message: "内容无法编码")); return
            }
            Log.write("新会话：打开 \(scheme)://anthropic.claude-code/open（\(source.displayName):\(cwd)）")
            NSWorkspace.shared.open(url)
            guard linkTrusted else {
                keepFront = true   // 前台留在 VS Code：切走的话框会被盖住，用户在电脑前也像是它自己消失了
                completion(Outcome(ok: false, submitted: false, openedWindow: opened, message: prompt.isEmpty
                    ? "电脑上的 VS Code 弹出了确认框，询问是否允许 Claude Code 扩展打开链接。请在电脑上勾选「不再询问」并点击「打开」，会话即会打开"
                    : "电脑上的 VS Code 弹出了确认框，询问是否允许 Claude Code 扩展打开链接。请在电脑上勾选「不再询问」并点击「打开」，会话打开后内容会填入输入框，按回车键即可提交"))
                return
            }
            // 整句写出来，别把「新建会话」拼进去：英文按整句查表，拼出来的会被当成按钮名翻成「New Session」
            let where_ = opened ? (sessionId == nil ? "已打开 VS Code 窗口并新建会话" : "已打开 VS Code 窗口并恢复对话")
                                : (sessionId == nil ? "已在 VS Code 中新建会话" : "已在 VS Code 中恢复对话")
            guard submit, !prompt.isEmpty else {
                if prompt.isEmpty { completion(Outcome(ok: true, submitted: false, openedWindow: opened, message: where_)); return }
                completion(Outcome(ok: true, submitted: false, openedWindow: opened, message: "\(where_)，内容已填入输入框")); return
            }
            guard AXIsProcessTrusted() else {
                completion(Outcome(ok: true, submitted: false, openedWindow: opened,
                                   message: "\(where_)，内容已填入输入框；未获得「\(Delivery.accessibilityName)」权限，无法自动提交")); return
            }
            accepted?(Outcome(ok: true, submitted: true, openedWindow: opened, message: "\(where_)，加载完成后将自动提交"))
            let notSent = "\(where_)，内容已填入输入框；"
            func fail(_ why: String) {
                Log.write("新会话：没有自动提交（\(why)）")
                completion(Outcome(ok: true, submitted: false, openedWindow: opened, message: notSent + why + "，未自动提交，请在电脑上按回车键提交"))
            }
            guard let app = Delivery.Editor.running()?.app else { fail("VS Code 未运行"); return }
            // 新标签把内容预填进输入框、却不把光标放进去，模拟回车会落空：在这个项目的窗口里找到填着这段话的输入框，按它旁边的「发送」
            ClaudeInput.submit(prompt: prompt, app: app, project: project, remote: source.kind == .ssh,
                               deadline: Date().addingTimeInterval(45)) { result in
                switch result {
                case .sent:
                    Log.write("新会话：已按发送")
                    completion(Outcome(ok: true, submitted: true, openedWindow: opened, message: "\(where_)并提交"))
                case .focused:
                    // 没认出发送按钮（扩展改了界面）：光标已经放进那个输入框，VS Code 在前台就回车
                    Delivery.reclaimFront { _ in
                        guard Delivery.editorIsFrontmost() else { fail("VS Code 被其他应用遮挡"); return }
                        Delivery.postKey(36)
                        Log.write("新会话：已在输入框里回车")
                        completion(Outcome(ok: true, submitted: true, openedWindow: opened, message: "\(where_)并提交"))
                    }
                case .notFound:
                    // 新开的窗口没信任过：VS Code 先问信任，答之前 Claude Code 扩展不运行（Mac 上多半已被上面的 .blocked 认出来）
                    fail(opened && EditorSettings.workspaceTrustEnabled(scheme: scheme)
                         ? "45 秒内未在 VS Code 中找到已填入内容的新标签页（如果 VS Code 以受限模式打开了此项目，请点击顶部横幅中的「管理」并信任此文件夹：Claude Code 扩展只在受信任的文件夹中运行）"
                         : "45 秒内未在 VS Code 中找到已填入内容的新标签页")
                case .restricted:
                    keepFront = true   // 前台留在 VS Code：用户回到电脑前一眼就能看到那条横幅
                    Log.write("新会话：项目窗口是受限模式（文件夹没信任过），Claude Code 扩展不运行，没有自动提交")
                    completion(Outcome(ok: false, submitted: false, openedWindow: opened,
                                       message: "此项目文件夹在 VS Code 中尚未受信任（受限模式），Claude Code 扩展不会运行。请在电脑上点击 VS Code 顶部横幅中的「管理」，再点击「信任」（也可以信任上级文件夹，其中的项目以后都不再询问），然后重新发送"))
                case .blocked(let dialog):
                    keepFront = true   // 前台留在 VS Code：切走的话框会被盖住
                    Log.write("新会话：VS Code 弹着对话框「\(dialog)」，没有自动提交")
                    let trust = dialog.localizedCaseInsensitiveContains("trust") || dialog.contains("信任")
                    completion(Outcome(ok: false, submitted: false, openedWindow: opened, message: trust
                        ? "电脑上的 VS Code 正在询问是否信任此文件夹中文件的作者，Claude Code 扩展只在受信任的文件夹中运行。请在电脑上点击「是，我信任此作者」（勾选信任上级文件夹后，其中的项目都不再询问），然后重新发送"
                        : "电脑上的 VS Code 正在显示对话框「\(dialog)」，需要先在电脑上处理，然后重新发送"))
                }
            }
        }
    }
}

/// 新任务要在独立分支里做：先让那台机器的 watcher 建 worktree，再把会话目录换过去、在要求后面交代一句
enum Worktree {
    struct Prepared {
        var cwd: String
        var prompt: String
        var branch: String
    }

    static func prepare(_ connection: SourceConnection, cwd: String, prompt: String,
                        completion: @escaping (Result<Prepared, RemoteError>) -> Void) {
        connection.request(["cmd": "worktree_add", "cwd": cwd], timeout: 30) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                guard let path = response["path"] as? String, let branch = response["branch"] as? String else {
                    completion(.failure(RemoteError("worktree 创建失败"))); return
                }
                let base = (response["base"] as? String).map { "（基于 \($0)）" } ?? ""
                let note = "\n\n（当前为独立的 git worktree，分支 \(branch)\(base)，目录 \(path)。请仅在此目录中修改；完成后暂不合并，并说明改动内容及合并方式。）"
                Log.write("新任务用独立 worktree：\(branch) → \(path)")
                completion(.success(Prepared(cwd: path, prompt: prompt + note, branch: branch)))
            }
        }
    }
}

/// 「新任务」可选的项目：各来源最近用过 Claude Code 的目录 + 正在运行的会话目录 + VS Code 已打开的窗口
enum Projects {
    /// 最近一次项目总览里，本机读 git 超时的目录
    static var slowLocal: [String] = []

    /// 早安简报里的一句：哪些项目有没提交的改动、没推送的提交（只有新文件的不算，免得天天念叨同一个草稿目录）
    static func pendingLine(_ payload: [String: Any], english: Bool = false) -> String? {
        let p = Phrase(english: english)
        let items = payload["projects"] as? [[String: Any]] ?? []
        func git(_ item: [String: Any]) -> [String: Any] { item["git"] as? [String: Any] ?? [:] }
        let dirty = items.filter { Digest.number(git($0)["changed"]) > 0 }
        let unpushed = items.filter { Digest.number(git($0)["ahead"]) > 0 }
        guard !dirty.isEmpty || !unpushed.isEmpty else { return nil }
        func names(_ list: [[String: Any]]) -> String {
            list.prefix(3).compactMap { $0["name"] as? String }.joined(separator: p.list) + (list.count > 3 ? p(" 等") : "")
        }
        var parts: [String] = []
        if !dirty.isEmpty { parts.append(p("%lld 个有未提交的改动（%@）", dirty.count, names(dirty))) }
        if !unpushed.isEmpty { parts.append(p("%lld 个未推送（%@）", unpushed.count, names(unpushed))) }
        return p("项目：%@", parts.joined(separator: p.semicolon))
    }

    /// detail：项目总览用，多带每个项目的会话数、今天动过几个、git 概况（各台机器并行跑 git，慢一点）
    static func collect(detail: Bool = false, completion: @escaping ([String: Any]) -> Void) {
        let state = AppState.shared
        var items: [String: [String: Any]] = [:]   // 键：来源 id + 目录
        var order: [String] = []
        var errors: [String] = []
        func upsert(_ source: SourceConfig, _ cwd: String, _ fill: (inout [String: Any]) -> Void) {
            let key = "\(source.id)\n\(cwd)"
            var item = items[key] ?? ["sourceId": source.id, "sourceName": source.displayName, "kind": source.kind.rawValue,
                                      "cwd": cwd, "name": (cwd as NSString).lastPathComponent, "exists": true,
                                      "lastActive": 0, "live": 0, "open": false]
            fill(&item)
            if items[key] == nil { order.append(key) }
            items[key] = item
        }
        let group = DispatchGroup()
        let startOfDay = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        for connection in state.liveSources {
            group.enter()
            var request: [String: Any] = ["cmd": "projects"]
            if detail {
                // 正在跑的会话的目录也要在列表里（哪怕它的对话记录不在最近的几十个项目里）
                let liveCwds = state.store.records.filter { $0.sourceId == connection.id }.map { $0.snapshot.cwd }.filter { !$0.isEmpty }
                request = ["cmd": "project_overview", "limit": 40, "since": startOfDay, "extra": Array(Set(liveCwds))]
            }
            connection.request(request, timeout: 30) { result in
                switch result {
                case .success(let response):
                    for project in response["projects"] as? [[String: Any]] ?? [] {
                        guard let cwd = project["cwd"] as? String else { continue }
                        upsert(connection.config, cwd) { item in
                            if Digest.number(project["lastActive"]) > Digest.number(item["lastActive"]) { item["lastActive"] = project["lastActive"] }
                            item["exists"] = project["exists"] ?? true
                            if let title = project["title"] as? String { item["title"] = title }
                            for field in ["sessionId", "sessions", "today", "git"] where project[field] != nil && !(project[field] is NSNull) {
                                item[field] = project[field]
                            }
                        }
                    }
                case .failure(let error):
                    errors.append("\(connection.config.displayName)：\(error.description)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            for record in state.store.records {
                guard let source = state.config.sources.first(where: { $0.id == record.sourceId }) else { continue }
                let snap = record.snapshot
                guard !snap.cwd.isEmpty else { continue }
                upsert(source, snap.cwd) { item in
                    item["live"] = (item["live"] as? Int ?? 0) + 1
                    if snap.act == .waiting { item["waiting"] = (item["waiting"] as? Int ?? 0) + 1 }
                    if snap.act == .busy { item["busy"] = (item["busy"] as? Int ?? 0) + 1 }
                    let updated = Int64(snap.transcriptUpdatedAt ?? snap.updatedAt ?? 0)
                    if updated > (item["lastActive"] as? NSNumber)?.int64Value ?? 0 { item["lastActive"] = updated }
                    if item["title"] == nil { item["title"] = snap.displayTitle }
                }
            }
            let scheme = Delivery.Editor.running()?.scheme ?? "vscode"
            let windows = Delivery.Editor.running() == nil ? [] : WindowLocator.openFolders(scheme: scheme)
            let live = Set(state.liveSources.map { $0.id })
            for folder in windows {
                // 窗口对应哪个来源：本机窗口给本机来源，远端窗口比主机
                guard let source = state.config.sources.first(where: { live.contains($0.id)
                        && WindowLocator.matches(folder, kind: $0.kind, host: $0.sshHost, port: $0.sshPort) }) else { continue }
                upsert(source, folder.path) { $0["open"] = true }
            }
            // 项目在窗口工作区里面（子目录）也算开着
            for key in order {
                guard var item = items[key], item["open"] as? Bool != true,
                      let source = state.config.sources.first(where: { $0.id == item["sourceId"] as? String }),
                      let cwd = item["cwd"] as? String else { continue }
                if windows.contains(where: { folder in
                    (cwd == folder.path || cwd.hasPrefix(folder.path + "/"))
                        && WindowLocator.matches(folder, kind: source.kind, host: source.sshHost, port: source.sshPort)
                }) {
                    item["open"] = true
                    items[key] = item
                }
            }
            if detail {
                // 本机项目 git 读超时：多半是 macOS 在等用户授权访问「文稿」/ 网络卷，就绪检查里提示
                slowLocal = order.compactMap { items[$0] }.filter { item in
                    item["kind"] as? String == SourceKind.local.rawValue && (item["git"] as? [String: Any])?["timeout"] as? Bool == true
                }.compactMap { $0["cwd"] as? String }
            }
            let list = order.compactMap { items[$0] }.sorted { a, b in
                func rank(_ x: [String: Any]) -> Int { ((x["live"] as? Int ?? 0) > 0 ? 2 : 0) + (x["open"] as? Bool == true ? 1 : 0) }
                if rank(a) != rank(b) { return rank(a) > rank(b) }
                return Digest.number(a["lastActive"]) > Digest.number(b["lastActive"])
            }
            completion(["ok": true, "projects": list, "errors": errors])
        }
    }
}

/// 历史会话：各来源 ~/.claude/projects 里的全部对话（会话关了也能看、能搜、能恢复）
enum PastSessions {
    /// 合并各来源的结果；每条带上 key（来源#会话 id）和是否还在运行
    private static func gather(_ request: [String: Any], field: String, timeout: TimeInterval, only sourceId: String? = nil,
                               completion: @escaping ([[String: Any]], [String], Bool) -> Void) {
        let state = AppState.shared
        var items: [[String: Any]] = []
        var errors: [String] = []
        var truncated = false
        let group = DispatchGroup()
        for connection in state.liveSources where sourceId == nil || connection.id == sourceId {
            group.enter()
            connection.request(request, timeout: timeout) { result in
                switch result {
                case .success(let response):
                    truncated = truncated || (response["truncated"] as? Bool ?? false)
                    for var item in response[field] as? [[String: Any]] ?? [] {
                        let sessionId = item["sessionId"] as? String ?? ""
                        let key = "\(connection.id)#\(sessionId)"
                        item["key"] = key
                        item["sourceId"] = connection.id
                        item["sourceName"] = connection.config.displayName
                        item["sourceKind"] = connection.config.kind.rawValue
                        if let record = state.store.record(withKey: key) {
                            item["live"] = true
                            item["activity"] = record.snapshot.act.rawValue
                        } else {
                            item["live"] = false
                        }
                        items.append(item)
                    }
                case .failure(let error):
                    errors.append("\(connection.config.displayName)：\(error.description)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(items, errors, truncated) }
    }

    /// sourceId + cwd 给定时只列那台机器上这个项目的会话（项目详情页用）；
    /// project（项目名 = 目录最后一级）给定时列各机器上这个项目的会话，多取一些（历史会话按项目筛时补全，不止最近那 120 个里的）
    static func list(sourceId: String? = nil, cwd: String? = nil, project: String? = nil, completion: @escaping ([String: Any]) -> Void) {
        var request: [String: Any] = ["cmd": "sessions_list", "limit": 120]
        if let cwd = cwd, !cwd.isEmpty { request["cwd"] = cwd; request["limit"] = 40 }
        if let project = project, !project.isEmpty { request["project"] = project; request["limit"] = 300 }
        gather(request, field: "sessions", timeout: 40, only: sourceId) { items, errors, _ in
            let sorted = items.sorted { Digest.number($0["lastActive"]) > Digest.number($1["lastActive"]) }
            completion(["ok": true, "sessions": sorted, "errors": errors])
        }
    }

    static func search(_ query: String, completion: @escaping ([String: Any]) -> Void) {
        gather(["cmd": "search", "q": query], field: "results", timeout: 40) { items, errors, truncated in
            func newest(_ item: [String: Any]) -> Double {
                ((item["hits"] as? [[String: Any]]) ?? []).map { Digest.number($0["ts"]) }.max() ?? Digest.number(item["lastActive"])
            }
            let sorted = items.sorted { newest($0) > newest($1) }
            completion(["ok": true, "query": query, "results": sorted, "errors": errors, "truncated": truncated])
        }
    }
}
