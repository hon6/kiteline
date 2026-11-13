import AppKit
import CryptoKit
import Foundation
import Network
import KitelineKit

/// 手机端（iPhone 上的 Kiteline App、Mac 主窗口的对话页）的服务端：鉴权、会话列表、实时事件（SSE）、历史、图片、发送。
/// 网页版已下线（10-22 起顾客打不开网页）：根路径只回一张「请用 Kiteline App 连接」的说明页，不再托管 Resources/web。
///
/// 接口一览（除说明页与配对外都要令牌）：
///   GET  /                       说明页（不是网页版）
///   GET  /pair?code=123456       用电脑上显示的 6 位配对码换令牌
///   GET  /api/state              会话列表 + 来源状态
///   GET  /api/events             SSE：state / entries / reset / notify
///   GET  /api/history?key=&before=&beforeTs=&limit=
///   GET  /api/media?key=&ref=    图片（带缓存）
///   POST /api/send?key=          {text, images:[{name, data(base64)}], files:[{name, data(base64)}], submit?}
///   GET  /api/download?key=&path=[&cwd=&reveal=1]  电脑上的文件原样取回（手机预览、转发到别的 App）
///   POST /api/key?key=           {key: enter|esc|1|2|3}
///   POST /api/answer?key=        回答 AskUserQuestion：{answers:[{question, picked:[...], other}]}
///   GET  /api/ping[?bytes=N]     网络检测（延迟 / 下行速率）
///   GET  /api/info               连接信息（https 地址、推送订阅数、辅助功能权限）
///   GET  /api/push/key           推送公钥；POST /api/push/subscribe|unsubscribe|test
///   POST /api/live/register      iPhone 实时活动的令牌和开关（见 LiveActivities.swift）
///   GET  /api/share[?key=]       游客链接（局域网只读分享）；POST /api/share {key, hours}、POST /api/share/stop {id}（见 GuestLinks.swift）
///   GET  /g/<编号>、/g/api/<编号>  游客看的页面和内容（不要令牌，只认分享中的编号）
///   POST /api/voice?key=         按住说话：{data(base64), mime, duration, mode: send|text} → 转写（并发送）
///   GET  /api/voices?key=        这个会话发过的语音（手机按文字认出哪条消息是语音）
///   GET  /api/agents?key=        子 agent 和后台任务（Agent map）
///   GET  /api/task-output?key=&task=  后台任务输出的末尾
///   GET  /api/history?key=&agent=     子 agent 的完整记录
///   GET  /api/voice-audio?id=    语音录音（回放）
///   GET  /api/git?key=           改动报告：分支、改动文件、最近提交；/api/git/diff?key=&path=|commit= 看 diff
///   GET  /api/repo?key=&op=      代码 IDE 的 Git：overview|status|log|commit_info|diff；POST /api/repo 暂存、提交、推送、分支……（op 见 watcher repo_op）
///   POST /api/fs?key=            代码 IDE 改文件：{op: write|create|rename|move|copy|delete|upload, …}（删除进废纸篓）
///   GET  /api/tests?key=         测试报告：这个会话跑过的测试和结果
///   GET  /api/todos              我的待办（Claude 说要你做的事）；POST /api/todos/add|update|delete|dismiss|clear-done（见 Todos.swift）
///   GET  /api/favorites          我的收藏（收藏的消息）；POST /api/favorites/add|delete，GET /api/favorites/media（见 Favorites.swift）
///   GET  /api/tabgroups          标签组（相关会话放一组，各端同一套）；POST /api/tabgroups/set 整份换掉（见 TabGroupStore.swift）
///   GET  /api/groups             会话群（跨设备、跨项目的会话互相发消息）；GET /api/groups/messages，POST /api/groups/create|add|remove|rename|send|pause|delete（见 Groups.swift）
///   GET  /ca.mobileconfig        本机根证书描述文件（装上后 https 地址受信任，推送才能用）
///
/// 令牌可以放在请求头 X-CCP-Token、查询参数 t、或 Cookie ccp 里（EventSource 和 <img> 不能带头）。
final class MobileServer {
    private var server: HTTPServer?
    private var secureServer: HTTPServer?
    /// 微信小程序入口（加密隧道，见 MPGate.swift）：和 HTTPS 一起开，端口 = 手机服务端口 + 3
    private(set) var mpGate: MPGate?
    let push = WebPush()
    let voices = VoiceStore()
    private(set) var secureStatus = "未启动"
    private var streams: [ObjectIdentifier: HTTPStream] = [:]
    /// 最近送出去的消息（按「会话 + 消息 id」），10 分钟内重发的直接回上次的结果
    private var recentSends: [String: (at: Date, payload: [String: Any])] = [:]
    /// 正在送的消息、正在做的恢复（按「会话 + 消息 id」→ 同一条重发过来、等着同一个结果的回应，只在主线程读写）。
    /// 手机 10 秒等不到回应会换一条路拿同一个 id 重发，而这边可能还在送（后台通道卡住、恢复会话要十几秒）：
    /// 只记「送完的」认不出来，同一条会被投两遍（11-13 查用户日志：每次后台通道超时都跟着一次重复投递）
    private var pendingSends: [String: [(HTTPResponse) -> Void]] = [:]
    /// 最近做成的恢复（按「会话 + 消息 id」），10 分钟内重发的直接回上次的结果，不再恢复一遍
    private var recentResumes: [String: (at: Date, response: HTTPResponse)] = [:]
    /// 正在恢复的历史会话（key → 排在后面的恢复请求，只在主线程读写）：手机上连发几条时后面的等前一条做完，见 resume
    private var resumeGates: [String: [HTTPRequest]] = [:]
    /// 每条实时连接是哪台设备的（停用设备时把它的连接断掉）
    private var streamDevices: [ObjectIdentifier: String] = [:]
    /// 每条实时连接要哪种语言（en / zh）：电脑生成的字按看的那台设备的语言发（见 ServerLang）
    private var streamLangs: [ObjectIdentifier: String] = [:]
    /// 哪些设备此刻正开着 Kiteline（手机切到前台 / 每 30 秒报一次）：它们的提醒只弹 App 里的横幅，不发系统推送
    private var foreground: [String: Date] = [:]
    private let lock = NSLock()
    private var heartbeat: DispatchSourceTimer?
    private var lastStateJSON = ""
    /// 上一份广播出去的完整状态和它的序号（主线程用）。连接时带 patch=1 的客户端之后只收变了的部分（statepatch，见 statePatch）：
    /// 整份 26 KB（10 个会话），两次之间通常只变一个会话的两三个字段（10-26 实测，约 3 秒一份）
    private var lastState: [String: Any] = [:]
    private var stateSeq = 0
    /// 要增量的实时连接；还没收到第一份整份状态的连接先不收状态（都由 lock 护着）
    private var patchStreams: Set<ObjectIdentifier> = []
    private var pendingStreams: Set<ObjectIdentifier> = []
    /// 设置在主线程改、在 HTTP 队列里每个请求都读（鉴权要看令牌）：用自己的锁护住，别和上面那把嵌套
    private let configLock = NSLock()
    private var storedConfig: MobileConfig
    private(set) var config: MobileConfig {
        get { configLock.lock(); defer { configLock.unlock() }; return storedConfig }
        set { configLock.lock(); storedConfig = newValue; configLock.unlock() }
    }
    private(set) var statusText = "未启动"

    /// 6 位配对码：在 Mac 的「手机访问」窗口里显示，10 分钟有效。主线程生成、HTTP 队列核对，用 pairLock 护住
    private let pairLock = NSLock()
    private var storedPairingCode = ""
    private var storedPairingExpiry = Date.distantPast
    /// 输错配对码的记录（时间、从哪来）：同一个来源 10 分钟错 8 次只锁它自己，所有来源合计 30 次才全锁——
    /// 以前是合计 8 次就全锁，局域网里谁连输 8 次错码，你自己也配不了 10 分钟
    private var failedPairings: [(at: Date, from: String)] = []
    /// 当前这个配对码输错了几次（5 次作废，见 pair）
    private var codeFailures = 0
    /// 二维码 / 配对链接里的一次性令牌 → 过期时间：10 分钟有效，登记一台设备就作废。
    /// 以前二维码里放的是主令牌：被人拍到 / 截到就能一直配对，直到重置。主令牌现在只留在本机（Mac 自己的窗口用）
    private var linkTokens: [String: Date] = [:]
    var pairingCode: String { pairLock.lock(); defer { pairLock.unlock() }; return storedPairingCode }
    var pairingCodeExpiry: Date { pairLock.lock(); defer { pairLock.unlock() }; return storedPairingExpiry }

    var onClientsChange: (() -> Void)?

    init(config: MobileConfig) {
        self.storedConfig = config
    }

    /// 连着的手机：只数用设备令牌连的。Mac 主窗口的原生对话页也连这条实时通道，但它用的是主令牌，不算手机
    var clientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return Set(streamDevices.values).count
    }

    // MARK: - 生命周期

    func start() {
        // 明文 HTTP 只开本机（主窗口的对话页、本机工具要用）：手机上的 Kiteline 只走 HTTPS，
        // 网页版不再在局域网里走明文（扫码链接里的令牌会被同一 Wi-Fi 下的人看到；10-22 确认不用网页版）
        let host = "127.0.0.1"
        let server = HTTPServer(host: host, port: UInt16(clamping: config.port)) { [weak self] request, reply in
            self?.route(request, reply: reply)
        }
        server.allowLargeBody = { [weak self] headers, target in self?.mayUpload(headers, target) ?? false }
        // 状态回调在 HTTP 队列里来，界面在主线程读：统一回主线程再写
        server.onStateChange = { [weak self] text in
            DispatchQueue.main.async { self?.statusText = text; self?.onClientsChange?() }
        }
        do {
            try server.start()
            self.server = server
            statusText = config.enabled ? "启动中" : "仅本机"
            Log.write("手机服务监听 \(host):\(config.port)")
        } catch {
            statusText = "启动失败：\(error)"
            Log.write("手机服务启动失败：\(error)")
        }
        push.contact = config.pushContact
        if config.enabled && config.httpsEnabled { startSecure() }
        startHeartbeat()
        MediaCache.prune()
    }

    /// HTTPS 端口：证书生成要调 openssl（约一秒），放后台做
    private func startSecure() {
        let config = self.config
        secureStatus = "准备证书中"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let net = NetworkInfo.current()
            guard let identity = LocalTLS.identity(ips: net.allIPs + ["127.0.0.1"], names: net.names + ["localhost"]) else {
                DispatchQueue.main.async { self?.secureStatus = "证书准备失败（见日志）" }
                return
            }
            DispatchQueue.main.async {
                guard let self = self, self.config == config else { return }
                let secure = HTTPServer(host: config.bindAddress, port: UInt16(clamping: config.effectiveHTTPSPort),
                                        tlsIdentity: identity) { [weak self] request, reply in
                    self?.route(request, reply: reply)
                }
                secure.allowLargeBody = { [weak self] headers, target in self?.mayUpload(headers, target) ?? false }
                secure.onStateChange = { [weak self] text in DispatchQueue.main.async { self?.secureStatus = text } }
                // 只听本机（127.0.0.1）时宣告了也没人连得上；测试实例不宣告（见 LocalNetwork.offInTestInstance）
                if !["127.0.0.1", "::1", "localhost"].contains(config.bindAddress), !LocalNetwork.offInTestInstance {
                    var txt = NWTXTRecord(["role": "mac"])
                    if let fp = LocalTLS.caFingerprint { txt["fp"] = fp }
                    secure.bonjour = NWListener.Service(name: Host.current().localizedName ?? "电脑", type: "_tars._tcp", txtRecord: txt)
                }
                do {
                    try secure.start()
                    self.secureServer = secure
                    Log.write("手机 HTTPS 服务监听 \(config.bindAddress):\(config.effectiveHTTPSPort)")
                } catch {
                    self.secureStatus = "启动失败：\(error)"
                }
                if self.mpGate == nil {
                    let gate = MPGate(route: { [weak self] request, reply in self?.route(request, reply: reply) },
                                      hostName: { Host.current().localizedName ?? "电脑" })
                    do {
                        try gate.start(host: config.bindAddress, port: UInt16(clamping: config.port + 3))
                        self.mpGate = gate
                        if config.remoteEnabled, MPGate.remoteAllowed, let link = MPRelayLink(gate: gate, relay: config.effectiveRelay) {
                            gate.relay = link   // 远程：电脑主动连中继，小程序经中继找到这台电脑
                            link.start()
                        }
                    } catch {
                        Log.write("小程序入口启动失败：\(error)")
                    }
                }
            }
        }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        lock.lock()
        let all = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        all.forEach { $0.close() }
        server?.stop()
        server = nil
        secureServer?.stop()
        secureServer = nil
        mpGate?.stop()
        mpGate = nil
        statusText = "已停止"
    }

    func update(config newConfig: MobileConfig) {
        let restart = newConfig.port != config.port || newConfig.bindAddress != config.bindAddress
            || newConfig.enabled != config.enabled || newConfig.token != config.token
            || newConfig.httpsEnabled != config.httpsEnabled || newConfig.httpsPort != config.httpsPort
        config = newConfig
        if restart { stop(); start() }
    }

    /// 新的一次性配对令牌（「手机访问」页的二维码、复制的链接用）。以 p 开头，和设备令牌（d 开头）、主令牌区分
    func newLinkToken() -> String {
        let token = "p" + MobileConfig.makeToken()
        let now = Date()
        pairLock.lock()
        linkTokens = linkTokens.filter { $0.value > now }
        linkTokens[token] = now.addingTimeInterval(600)
        pairLock.unlock()
        // 开着远程访问：这 10 分钟里手机和 Mac 局域网不通也能经中继扫码配对
        if config.remoteEnabled { P2P.shared.openPairing(code: nil) }
        return token
    }

    /// 配对令牌还能不能用（「手机访问」页据此在用掉 / 过期后换新二维码）
    func linkTokenValid(_ token: String) -> Bool {
        pairLock.lock(); defer { pairLock.unlock() }
        return (linkTokens[token] ?? .distantPast) > Date()
    }

    /// 登记设备时用掉：只能用一次
    private func consumeLinkToken(_ token: String) -> Bool {
        pairLock.lock(); defer { pairLock.unlock() }
        guard (linkTokens[token] ?? .distantPast) > Date() else { return false }
        linkTokens[token] = nil
        return true
    }

    func newPairingCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        pairLock.lock()
        codeFailures = 0
        storedPairingCode = code
        storedPairingExpiry = Date().addingTimeInterval(600)
        pairLock.unlock()
        // 开着远程访问：这 10 分钟里手机不在同一个 Wi-Fi 也能经中继输验证码配对
        if config.remoteEnabled { P2P.shared.openPairing(code: code) }
        return code
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            // SSE 注释行：保活，防止中间设备掐掉空闲连接
            self?.broadcastRaw(Data(": ping\n\n".utf8))
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - 推送

    /// 会话列表变化时调用（主线程）。内容没变就不推。
    func publishState() {
        let payload = AppState.shared.mobileStatePayload()
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        guard text != lastStateJSON else { return }
        lastStateJSON = text
        let previous = lastState, base = stateSeq
        lastState = payload
        stateSeq += 1
        // iPhone 锁屏 / 灵动岛上的实时活动跟着会话状态走
        LiveActivities.shared.update(sessions: payload["sessions"] as? [[String: Any]] ?? [])
        var full = payload
        full["stateSeq"] = stateSeq
        guard let fullData = try? JSONSerialization.data(withJSONObject: full, options: [.sortedKeys]) else { return }
        let patch = previous.isEmpty ? nil : Self.statePatch(from: previous, to: payload, base: base, seq: stateSeq, fullSize: fullData.count)
        broadcastState(full: fullData, patch: patch)
    }

    /// 两份状态之间的增量：会话按 key 整条换（upsert）、没了的列出来（remove）、成员或顺序变了才带新顺序（order）；
    /// 会话以外变了的字段放 set、没了的放 unset。客户端合进上一份（序号 base）再按整份处理（KitelineKit/Model/AppModel.swift 的 mergeState）。
    /// 增量不比整份小多少（变了一大半）就不发，大家收整份
    static func statePatch(from old: [String: Any], to new: [String: Any], base: Int, seq: Int, fullSize: Int) -> Data? {
        func key(_ session: [String: Any]) -> String? { session["key"] as? String }
        let oldList = old["sessions"] as? [[String: Any]] ?? [], newList = new["sessions"] as? [[String: Any]] ?? []
        let oldByKey = Dictionary(oldList.compactMap { s in key(s).map { ($0, s as NSDictionary) } }, uniquingKeysWith: { $1 })
        let oldKeys = oldList.compactMap(key), newKeys = newList.compactMap(key)
        let upsert = newList.filter { s in key(s).map { oldByKey[$0] != (s as NSDictionary) } ?? false }
        let remaining = Set(newKeys)
        let remove = oldKeys.filter { !remaining.contains($0) }
        var patch: [String: Any] = ["base": base, "seq": seq]
        if !upsert.isEmpty { patch["upsert"] = upsert }
        if !remove.isEmpty { patch["remove"] = remove }
        if newKeys != oldKeys { patch["order"] = newKeys }
        var set: [String: Any] = [:]
        for (field, value) in new where field != "sessions" {
            if (old[field] as? NSObject)?.isEqual(value) != true { set[field] = value }
        }
        if !set.isEmpty { patch["set"] = set }
        let unset = old.keys.filter { $0 != "sessions" && new[$0] == nil }
        if !unset.isEmpty { patch["unset"] = Array(unset) }
        guard let data = try? JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys]), data.count * 10 < fullSize * 6 else { return nil }
        return data
    }

    /// 状态发给每条实时连接：要增量的发 statepatch，其余发整份；英文的连接把界面文字换成英文（每种只换一次、各条共用）
    private func broadcastState(full: Data, patch: Data?) {
        lock.lock()
        let all = streams.filter { !pendingStreams.contains($0.key) }
            .map { ($0.value, streamLangs[$0.key] ?? "zh", patch != nil && patchStreams.contains($0.key)) }
        lock.unlock()
        var ready: [String: Data] = [:]
        for (stream, lang, wantsPatch) in all {
            let event = wantsPatch ? "statepatch" : "state"
            let id = event + "-" + lang
            if ready[id] == nil {
                var body = wantsPatch ? (patch ?? full) : full
                if lang == "en" { body = ServerLang.localize(json: body) }
                ready[id] = Data("event: \(event)\ndata: ".utf8) + body + Data("\n\n".utf8)
            }
            if let message = ready[id] { stream.send(message) }
        }
    }

    /// 提醒：正开着 Kiteline 的设备只弹 App 里的横幅；在后台的设备收系统通知（同一条不会两样都来）
    func notify(kind: String, title: String, body: String, key: String) {
        let inApp = inAppDevices()
        let wantsPush = config.shouldPush(kind: kind, key: key)
        let entry = record(kind: kind, title: title, body: body, key: key, route: nil, inApp: inApp)
        publish(event: "notify", payload: ["kind": kind, "title": title, "body": body, "key": key, "inbox": entry?.id ?? "",
                                           "pushed": wantsPush ? Array(push.deviceIds(except: inApp)) : [], "at": Date().timeIntervalSince1970 * 1000])
        // 免打扰时段 / 静音的会话：只在应用里弹横幅，不推到锁屏
        guard wantsPush else {
            Log.write("免打扰：「\(title)」的\(kind == "conclusion" ? "结论" : "提醒")不推送")
            return
        }
        // Bark 分不出是哪台设备：有设备正开着 Kiteline 就不发；语言跟这台电脑的界面语言
        if inApp.isEmpty, Bark.wants(kind, config: config) {
            let head = ["attention": "需要确认", "conclusion": "已完成", "image": "发来图片", "todo": "新待办", "keyinfo": "关键信息",
                        "error": "出错已停止", "stuck": "可能停滞"][kind] ?? "新消息"
            Bark.send(title: "\(title) · \(L(head))", body: Lang.shared.isEnglish ? ServerLang.translate(body) : body, kind: kind, config: config)
        }
        guard !push.subscriptions.isEmpty else { return }
        let head: String
        switch kind {
        case "attention": head = "需要确认"
        case "conclusion": head = "已完成"
        case "image": head = "发来图片"
        case "todo": head = "新待办"
        case "keyinfo": head = "关键信息"
        case "error": head = "出错已停止"
        case "stuck": head = "可能停滞"
        default: head = "新消息"
        }
        pushLocalized(["title": "\(title) · \(head)", "body": String(body.prefix(240)), "key": key, "kind": kind],
                      ["title": "\(title) · \(Lang.shared.english(head))", "body": String(ServerLang.translate(body).prefix(240)), "key": key, "kind": kind],
                      except: inApp)
    }

    /// 目标（/goal）达成、做不到、停下：标题「会话 · 目标已达成」，正文是目标和结果。中英两份在源头拼好（正文里夹着目标原文，按句式反推会切错）
    func notifyGoal(title: String, head: String, body: String, bodyEn: String, key: String) {
        let inApp = inAppDevices()
        let wantsPush = config.shouldPush(kind: "goal", key: key)
        let shown = "\(title) · \(head)", shownEn = "\(title) · \(Lang.shared.english(head))"
        let entry = record(kind: "goal", title: shown, body: body, key: key, route: nil, inApp: inApp, english: (shownEn, bodyEn))
        publish(event: "notify", payload: ["kind": "goal", "title": shown, "body": body, "titleEn": shownEn, "bodyEn": bodyEn, "key": key,
                                           "inbox": entry?.id ?? "", "pushed": wantsPush ? Array(push.deviceIds(except: inApp)) : [],
                                           "at": Date().timeIntervalSince1970 * 1000])
        guard wantsPush else {
            Log.write("免打扰：「\(shown)」不推送")
            return
        }
        if inApp.isEmpty, Bark.wants("goal", config: config) {
            Bark.send(title: Lang.shared.isEnglish ? shownEn : shown, body: Lang.shared.isEnglish ? bodyEn : body, kind: "goal", config: config)
        }
        guard !push.subscriptions.isEmpty else { return }
        pushLocalized(["title": shown, "body": String(body.prefix(240)), "key": key, "kind": "goal"],
                      ["title": shownEn, "body": String(bodyEn.prefix(240)), "key": key, "kind": "goal"], except: inApp)
    }

    /// 日报：点开直接进「今日动态」页
    func notifyDigest(title: String, body: String, english: (title: String, body: String)? = nil) {
        notifyRoute(kind: "digest", title: title, body: body, route: "today", english: english)
    }

    /// 点开进某个页面（today / usage）的提醒：在线的手机弹横幅，订阅了推送的收系统通知
    /// english：源头按语言拼好的英文版（日报、早安简报）；没给就在出口逐句查表
    /// key：跟着的会话（群消息 = 发言的那个）：不认识这个 route 的老版本点开时进这个会话
    func notifyRoute(kind: String, title: String, body: String, route: String, english: (title: String, body: String)? = nil, key: String? = nil) {
        let inApp = inAppDevices()
        let wantsPush = config.shouldPush(kind: kind, key: nil)
        let entry = record(kind: kind, title: title, body: body, key: key, route: route, inApp: inApp, english: english)
        var event: [String: Any] = ["kind": kind, "title": title, "body": body, "route": route, "inbox": entry?.id ?? "",
                                    "pushed": wantsPush ? Array(push.deviceIds(except: inApp)) : [], "at": Date().timeIntervalSince1970 * 1000]
        if let key { event["key"] = key }
        if let english { event["titleEn"] = english.title; event["bodyEn"] = english.body }   // 出口给英文设备换上（见 ServerLang.localize）
        publish(event: "notify", payload: event)
        guard wantsPush else { return }
        let englishTitle = english?.title ?? ServerLang.translate(title), englishBody = english?.body ?? ServerLang.translate(body)
        if inApp.isEmpty, Bark.wants(kind, config: config) {
            Bark.send(title: Lang.shared.isEnglish ? englishTitle : title, body: Lang.shared.isEnglish ? englishBody : body, kind: kind, config: config)
        }
        guard !push.subscriptions.isEmpty else { return }
        pushLocalized(["title": title, "body": String(body.prefix(400)), "key": key ?? kind, "route": route, "kind": kind],
                      ["title": englishTitle, "body": String(englishBody.prefix(400)), "key": key ?? kind, "route": route, "kind": kind],
                      urgency: "normal", except: inApp)
    }

    /// 要人处理的状况（见 EditorAlerts）：VS Code 弹着对话框（editor）、到某台机器的连接断了 / 又连上了（link）。
    /// 带着 alert 的：锁屏通知长按有「尝试重连」，手机列表顶上那条也能点
    /// bodyEn：源头拼好的英文（里面夹着 VS Code 对话框的原文，按句式反推会切错）；没给就在出口逐句查表
    func notifyAlert(kind: String, title: String, head: String, body: String, bodyEn: String? = nil, alert: EditorAlerts.Alert?) {
        let inApp = inAppDevices()
        let wantsPush = config.shouldPush(kind: kind, key: nil)
        let englishBody = bodyEn ?? ServerLang.translate(body)
        let entry = record(kind: kind, title: title, body: body, key: nil, route: nil, inApp: inApp, english: bodyEn.map { (title, $0) })
        var event: [String: Any] = ["kind": kind, "title": title, "body": body, "inbox": entry?.id ?? "",
                                    "pushed": wantsPush ? Array(push.deviceIds(except: inApp)) : [], "at": Date().timeIntervalSince1970 * 1000]
        if let alert { event["alert"] = alert.id }
        if let bodyEn { event["bodyEn"] = bodyEn }
        publish(event: "notify", payload: event)
        guard wantsPush else { return }
        if inApp.isEmpty, Bark.wants(kind, config: config) {
            Bark.send(title: "\(title) · \(L(head))", body: Lang.shared.isEnglish ? englishBody : body, kind: kind, config: config)
        }
        guard !push.subscriptions.isEmpty else { return }
        var zh: [String: Any] = ["title": "\(title) · \(head)", "body": String(body.prefix(240)), "kind": kind]
        var en: [String: Any] = ["title": "\(title) · \(Lang.shared.english(head))", "body": String(englishBody.prefix(240)), "kind": kind]
        if let alert, alert.canReconnect {
            zh["alert"] = alert.id; en["alert"] = alert.id
            zh["actions"] = ["reconnect"]; en["actions"] = ["reconnect"]
        }
        pushLocalized(zh, en, except: inApp)
    }

    /// 正开着 Kiteline 的设备：30 秒一次的「我在前台」没断（留 75 秒余量），而且实时连接还在
    func inAppDevices() -> Set<String> {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        let online = Set(streamDevices.values)
        return Set(foreground.filter { now.timeIntervalSince($0.value) < 75 && online.contains($0.key) }.keys)
    }

    private func presence(_ request: HTTPRequest, deviceId: String?, respond: @escaping (HTTPResponse) -> Void) {
        guard let deviceId = deviceId else { respond(.json(["ok": true])); return }   // 主令牌（Mac 自己的对话页）不参与
        let visible = request.jsonBody?["visible"] as? Bool ?? false
        lock.lock()
        if visible { foreground[deviceId] = Date() } else { foreground.removeValue(forKey: deviceId) }
        lock.unlock()
        respond(.json(["ok": true]))
    }

    /// 记进通知收件箱，顺带记下这条有没有推到锁屏、没推是为什么（测试推送不记）
    private func record(kind: String, title: String, body: String, key: String?, route: String?, inApp: Set<String>,
                        english: (title: String, body: String)? = nil) -> Inbox.Entry? {
        guard kind != "test" else { return nil }
        let delivery: String
        if !config.shouldPush(kind: kind, key: key) {
            delivery = key.map { config.mutedSessions.contains($0) } == true && ["conclusion", "image", "error", "stuck", "goal"].contains(kind) ? "muted" : "quiet"
        } else {
            let pushed = !push.deviceIds(except: inApp).isEmpty || push.subscriptions.contains { $0.deviceId == nil }
            let bark = inApp.isEmpty && Bark.wants(kind, config: config)
            delivery = pushed || bark ? "sent" : (inApp.isEmpty ? "none" : "app")
        }
        return Inbox.shared.add(kind: kind, title: title, body: body, key: key, route: route, delivery: delivery, english: english)
    }

    func publish(event: String, payload: [String: Any]) {
        WorldHost.forward(event: event, payload: payload)   // 世界模式（对话增量、会话之间的消息、机器负载、待办）
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        broadcast(event: event, json: text)
    }

    /// 发给每条实时连接：英文的连接把界面文字换成英文（只换一次、各条共用）；对话增量 entries 全是内容，只换其中的事件提示
    private func broadcast(event: String, json: String) {
        let original = Data("event: \(event)\ndata: \(json)\n\n".utf8)
        lock.lock()
        let all = streams.map { ($0.value, streamLangs[$0.key] ?? "zh") }
        lock.unlock()
        var english: Data?
        for (stream, lang) in all {
            guard lang == "en", event != "peers", event != "term" else { stream.send(original); continue }   // 终端输出原样转（没有界面文字）
            if english == nil {
                let body = event == "entries" ? ServerLang.localizeEvents(json: Data(json.utf8)) : ServerLang.localize(json: Data(json.utf8))
                english = Data("event: \(event)\ndata: \(String(decoding: body, as: UTF8.self))\n\n".utf8)
            }
            stream.send(english ?? original)
        }
    }

    /// 只有内容（对话、文件、图片、差异……）、个头又大的接口：英文设备也原样回，不逐字段查表
    static let contentOnly: Set<String> = ["/api/history", "/api/media", "/api/file", "/api/files", "/api/git/diff", "/api/digest/media",
                                           "/api/task-output", "/api/search", "/api/changelog", "/api/agents", "/api/trace", "/api/tts", "/api/translate", "/api/peers", "/api/download",
                                           "/api/groups/messages", "/api/groups/media"]

    /// 每台设备的界面语言（锁屏推送按它发）：存起来，电脑重启后第一条推送也对
    private static let langsKey = "deviceLangs"
    private static let langLock = NSLock()

    static func noteLang(_ deviceId: String, _ lang: String) {
        langLock.lock(); defer { langLock.unlock() }
        var langs = AppConfig.defaults.dictionary(forKey: langsKey) as? [String: String] ?? [:]
        guard langs[deviceId] != lang else { return }
        langs[deviceId] = lang
        AppConfig.defaults.set(langs, forKey: langsKey)
    }

    static func englishDevices() -> Set<String> {
        langLock.lock(); defer { langLock.unlock() }
        let langs = AppConfig.defaults.dictionary(forKey: langsKey) as? [String: String] ?? [:]
        return Set(langs.filter { $0.value == "en" }.keys)
    }

    /// 锁屏推送：中文设备收 zh，英文设备收 en（except 里的设备都不发）
    private func pushLocalized(_ zh: [String: Any], _ en: [String: Any], urgency: String = "high", except: Set<String>) {
        // 别的电脑替手机在本机登记的：那台电脑连着本机时由它转推，本机不推（免得一条提醒手机收两遍）
        let except = except.union(PeerComputers.shared.pushSuppressed())
        let english = MobileServer.englishDevices()
        push.send(zh, urgency: urgency, except: except.union(english))
        let targets = english.subtracting(except)
        if !targets.isEmpty { push.send(en, urgency: urgency, only: targets) }
    }

    private func broadcastRaw(_ data: Data) {
        lock.lock()
        let all = Array(streams.values)
        lock.unlock()
        all.forEach { $0.send(data) }
    }

    // MARK: - 路由

    private func route(_ request: HTTPRequest, reply: @escaping (HTTPServer.Reply) -> Void) {
        // 写操作和配对都记进操作记录（结果出来后再记，带上成败）
        let respond: (HTTPResponse) -> Void = { response in
            Audit.record(request, response)
            var response = response
            if ServerLang.of(request) == "en", response.headers["Content-Type"]?.hasPrefix("application/json") == true {
                if !MobileServer.contentOnly.contains(request.path) {
                    response.body = ServerLang.localize(json: response.body, extra: request.path == "/api/readiness" ? ["title"] : [])
                } else if request.path == "/api/history" {
                    response.body = ServerLang.localizeEvents(json: response.body)
                }
            }
            if request.cookies["ccp"] != nil, response.headers["Set-Cookie"] == nil { response.headers["Set-Cookie"] = MobileServer.clearCookie }
            reply(.response(response))
        }

        if request.method == "OPTIONS" {
            respond(HTTPResponse(status: 204)); return
        }

        switch (request.method, request.path) {
        case ("GET", "/ca.mobileconfig"):
            guard let profile = LocalTLS.mobileconfig() else {
                respond(.text("证书尚未就绪", status: 503)); return
            }
            respond(HTTPResponse(status: 200, headers: [
                "Content-Type": "application/x-apple-aspen-config",
                "Content-Disposition": "attachment; filename=\"CCPulse.mobileconfig\"",
            ], body: profile))
            return
        case ("GET", "/pair"), ("POST", "/pair"):
            pair(request, respond: respond); return
        case ("GET", let path) where path.hasPrefix("/g/"):
            // 游客链接（局域网只读分享）：页面和内容都由这台电脑给，只认分享中的编号
            GuestLinks.shared.serve(request, respond: respond); return
        case ("GET", _) where !request.path.hasPrefix("/api/"):
            // 网页版已下线：浏览器打开根路径只看到说明页，别的路径（app.js、manifest……）一律 404
            respond(["/", "", "/index.html"].contains(request.path) ? MobileServer.noticePage() : .text("not found", status: 404)); return
        default:
            break
        }

        guard let auth = authorize(request) else {
            respond(.error("未配对或令牌已失效", status: 401)); return
        }
        // 一次性配对令牌只能用来配对：探路、看是哪台 Mac、登记设备
        if case .link = auth, !["/api/ping", "/api/info", "/api/devices/register"].contains(request.path) {
            respond(.error("配对链接只能用于配对，请重新扫码", status: 401)); return
        }
        // 手表经手机来的请求（?via=watch）：记下这台手机的手表最近在用
        if request.query["via"] == "watch", let deviceId = auth.deviceId { DeviceStore.shared.touchWatch(deviceId) }
        if let deviceId = auth.deviceId { MobileServer.noteLang(deviceId, ServerLang.of(request)) }

        // API 都在主线程处理：会话状态归主线程所有；耗时的事都是异步回调
        DispatchQueue.main.async {
            // 电脑互联：别的 Kiteline 电脑来取本机的会话（/api/peer/*）；手机问另一台电脑的地址（/api/computers）
            if case .device(let device) = auth, PeerComputers.shared.handle(request, device: device, reply: reply, respond: respond) { return }
            if request.path.hasPrefix("/api/peer/") { respond(.error("只有互联的 Kiteline 电脑能用", status: 403)); return }
            switch (request.method, request.path) {
            case ("GET", "/api/computers"):
                respond(.json(PeerComputers.shared.computersPayload())); return
            case ("POST", "/api/readiness/fix"):
                // 就绪检查里的一键处理：Mac 上目前只有「防火墙放行」（只认写死的动作，请求内容不进命令）
                guard request.jsonBody?["action"] as? String == "allow-firewall" else {
                    respond(.json(["ok": false, "message": "不支持的操作", "error": "不支持的操作"], status: 409)); return   // 同电脑端 r_readiness_fix
                }
                Log.write("就绪检查一键处理：防火墙放行，等待电脑上授权")
                // 授权框要等人去点（手机请求等不了那么久）：先告诉手机已经弹出来了，结果写进日志，就绪检查再查一次就能看到
                if Delivery.dryRun {
                    Firewall.allow { ok, message in respond(.json(["ok": ok, "message": message])) }
                } else {
                    Firewall.allow { _, _ in }
                    respond(.json(["ok": true, "message": "已在电脑上弹出授权窗口：请在电脑上输入管理员密码，完成后同一网络里的手机、其他电脑即可连接"]))
                }
                return
            case ("POST", "/api/computers/add"), ("POST", "/api/computers/remove"):
                // 本机界面、自测用（只认主令牌）：添加 / 移除 Kiteline 电脑
                guard case .master = auth else { respond(.error("只有这台电脑自己能用", status: 403)); return }
                let body = request.jsonBody ?? [:]
                if request.path.hasSuffix("/remove") {
                    PeerComputers.shared.remove(body["id"] as? String ?? ""); respond(.json(["ok": true])); return
                }
                PeerComputers.shared.add(address: body["address"] as? String ?? "", code: body["code"] as? String ?? "",
                                         fingerprint: body["fingerprint"] as? String) { result in
                    switch result {
                    case .success(let peer): respond(.json(["ok": true, "id": peer.id, "name": peer.name]))
                    case .failure(let error): respond(.error("添加失败：\(error.description)", status: 400))
                    }
                }
                return
            case ("POST", "/api/computers/enroll"):
                guard case .device(let phone) = auth, phone.kind != "computer" else { respond(.error("只有手机能用", status: 403)); return }
                PeerComputers.shared.enroll(phone: phone, computer: request.jsonBody?["id"] as? String ?? "", respond: respond); return
            default: break
            }
            // 对互联的别的电脑上的会话的操作：整条转给那台电脑执行（VS Code 在那台上）
            if let target = PeerComputers.shared.forwardTarget(request) {
                if request.path == "/api/send" || request.path == "/api/resume" { IdleClose.shared.touch([request.query["key"] ?? ""]) }
                PeerComputers.shared.forward(request, to: target, respond: respond); return
            }
            switch (request.method, request.path) {
            case ("GET", "/api/state"):
                // 各台机器的性能只在这里附上（刚连上时用）：之后的变化走 sys 事件，不进推送的 state
                var payload = AppState.shared.mobileStatePayload()
                payload["sys"] = AppState.shared.machineStats
                respond(.json(payload))
            case ("GET", "/api/events"):
                reply(.stream(headers: ["Content-Type": "text/event-stream; charset=utf-8",
                                        "X-Accel-Buffering": "no"]) { [weak self] stream in
                    self?.attach(stream, deviceId: auth.deviceId, lang: ServerLang.of(request), patch: request.query["patch"] == "1")
                })
            case ("GET", "/api/history"):
                self.history(request, respond: respond)
            case ("GET", "/api/agents"):
                self.forwardAny(request, ["cmd": "agents"], respond: respond)
            case ("GET", "/api/trace"):
                // 执行过程面板：agent → 轮次 → 步骤（expand 是要带上步骤的轮次，「agent:轮次」逗号分隔）
                self.forwardAny(request, ["cmd": "trace", "expand": request.query["expand"] ?? "", "rev": request.query["rev"] ?? ""], respond: respond)
            case ("GET", "/api/peers"):
                // 会话之间的消息往来（默认最近一天）：刚连上、协作图用；之后的走实时事件 peers
                let since = Double(request.query["since"] ?? "") ?? (Date().timeIntervalSince1970 * 1000 - 86_400_000)
                respond(.json(["links": PeerLinks.shared.since(since)]))
            case ("GET", "/api/task-output"):
                self.forwardAny(request, ["cmd": "task_output", "taskId": request.query["task"] ?? ""], respond: respond)
            case ("GET", "/api/media"):
                self.media(request, respond: respond)
            case ("POST", "/api/send"):
                IdleClose.shared.touch([request.query["key"] ?? ""])   // 从对话页发消息 = 打开过（自动关闭闲置会话，见 IdleClose）
                self.capGuard(request, respond: respond) { self.send(request, respond: respond) }
            case ("POST", "/api/key"):
                self.key(request, respond: respond)
            case ("POST", "/api/close"):
                self.close(request, respond: respond)
            case ("POST", "/api/queue"):
                self.queue(request, respond: respond)
            case ("POST", "/api/hosted/probe"):
                let sourceId = request.jsonBody?["sourceId"] as? String
                DispatchQueue.main.async { Hosted.probe(sourceId: sourceId) { respond(.json(["ok": true, "machines": $0])) } }
            case ("POST", "/api/hosted/settings"):
                let body = request.jsonBody ?? [:]
                DispatchQueue.main.async {
                    Hosted.update(sourceId: body["sourceId"] as? String, on: body["on"] as? Bool, tipOff: body["tipOff"] as? Bool)
                    respond(.json(["ok": true]))
                }
            case ("POST", "/api/hosted/move"):
                if let (record, _) = self.resolve(request) {
                    DispatchQueue.main.async {
                        Hosted.moveToBackground(record: record) { outcome in
                            respond(.json(["ok": outcome.ok, "message": outcome.message], status: outcome.ok ? 200 : 409))
                        }
                    }
                } else {
                    respond(.error("会话不存在或已结束", status: 404))
                }
            case ("POST", "/api/answer"):
                self.answer(request, respond: respond)
            case ("POST", "/api/voice"):
                if (request.jsonBody?["mode"] as? String ?? "send") == "send" {
                    IdleClose.shared.touch([request.query["key"] ?? ""])
                    self.capGuard(request, respond: respond) { self.voice(request, respond: respond) }
                } else {
                    self.voice(request, respond: respond)
                }
            case ("GET", "/api/git"):
                self.sessionGit(request, ["cmd": "git_status"], respond: respond)
            case ("GET", "/api/git/diff"):
                var payload: [String: Any] = ["cmd": "git_diff"]
                if let path = request.query["path"] { payload["path"] = path }
                if let commit = request.query["commit"] { payload["commit"] = commit }
                self.sessionGit(request, payload, respond: respond)
            case ("GET", "/api/digest"):
                let since = Int64(request.query["since"] ?? "") ?? Digest.startOfDay()
                let until = Int64(request.query["until"] ?? "").flatMap { $0 > 0 ? $0 : nil }
                Digest.collect(since: since, until: until, fresh: request.query["fresh"] == "1") { respond(.json($0)) }
            case ("GET", "/api/digest/media"):
                self.digestMedia(request, respond: respond)
            case ("POST", "/api/digest/push"):
                DailyReport.shared.send(manual: true) { message in respond(.json(["ok": true, "message": message])) }
            case ("GET", "/api/bark"):
                respond(.json(["ok": true, "url": self.config.barkURL, "mode": self.config.barkMode,
                               "encrypted": !self.config.barkKey.isEmpty, "valid": Bark.parse(self.config.barkURL) != nil]))
            case ("POST", "/api/bark"):
                let body = request.jsonBody ?? [:]
                let url = (body["url"] as? String ?? self.config.barkURL).trimmingCharacters(in: .whitespacesAndNewlines)
                guard url.isEmpty || Bark.parse(url) != nil else { respond(.error("Bark 地址无效：请在 Bark App 中复制形如 https://api.day.app/xxxx 的地址", status: 400)); return }
                let mode = body["mode"] as? String ?? self.config.barkMode
                guard ["off", "attention", "all"].contains(mode) else { respond(.error("推送范围无效", status: 400)); return }
                let key = body["key"] as? String ?? self.config.barkKey
                let iv = body["iv"] as? String ?? self.config.barkIV
                guard key.isEmpty || ([16, 24, 32].contains(key.utf8.count) && iv.utf8.count == 16) else {
                    respond(.error("加密密钥须为 16 / 24 / 32 个字符，IV 须为 16 个字符（与 Bark App 中的设置一致）", status: 400)); return
                }
                AppState.shared.updatePreferences {
                    $0.mobile.barkURL = url; $0.mobile.barkMode = mode; $0.mobile.barkKey = key; $0.mobile.barkIV = key.isEmpty ? "" : iv
                }
                respond(.json(["ok": true, "url": url, "mode": mode, "encrypted": !key.isEmpty]))
            case ("POST", "/api/bark/test"):
                guard Bark.parse(self.config.barkURL) != nil else { respond(.error("尚未填写 Bark 地址", status: 400)); return }
                Bark.send(title: "Kiteline 测试", body: "Bark 备用推送通道正常 ✓\(self.config.barkKey.isEmpty ? "" : "（加密）")", kind: "attention",
                          config: self.config) { ok, message in
                    respond(.json(["ok": ok, "message": message, "error": ok ? "" : message], status: ok ? 200 : 502))
                }
            case ("GET", "/api/schedules"):
                respond(.json(["ok": true, "schedules": Scheduler.shared.tasks.map { Scheduler.shared.payload($0) }]))
            case ("POST", "/api/schedules"):
                let body = request.jsonBody ?? [:]
                let sourceId = body["sourceId"] as? String ?? ""
                guard AppState.shared.config.sources.contains(where: { $0.id == sourceId }) else {
                    respond(.error("机器不存在", status: 404)); return
                }
                switch Scheduler.shared.add(sourceId: sourceId, cwd: body["cwd"] as? String ?? "", prompt: body["prompt"] as? String ?? "",
                                            repeatMode: body["repeat"] as? String ?? "", time: body["time"] as? String ?? "",
                                            date: body["date"] as? String) {
                case .success(let task): respond(.json(["ok": true, "schedule": Scheduler.shared.payload(task)]))
                case .failure(let error): respond(.error(error.message, status: 400))
                }
            case ("POST", "/api/schedules/update"):
                let body = request.jsonBody ?? [:]
                guard let task = Scheduler.shared.update(body["id"] as? String ?? "", enabled: body["enabled"] as? Bool ?? true) else {
                    respond(.error("定时任务不存在", status: 404)); return
                }
                respond(.json(["ok": true, "schedule": Scheduler.shared.payload(task)]))
            case ("POST", "/api/schedules/delete"):
                guard let task = Scheduler.shared.remove(request.jsonBody?["id"] as? String ?? "") else {
                    respond(.error("定时任务不存在", status: 404)); return
                }
                respond(.json(["ok": true, "label": Scheduler.shared.label(task)]))
            case ("POST", "/api/schedules/run"):
                Scheduler.shared.run(request.jsonBody?["id"] as? String ?? "") { ok, message in
                    respond(.json(["ok": ok, "message": message, "error": ok ? "" : message], status: ok ? 200 : 409))
                }
            case ("GET", "/api/readiness"):
                Readiness.check { items in respond(.json(["ok": true, "items": items])) }
            case ("POST", "/api/quiet"):
                let body = request.jsonBody ?? [:]
                let start = body["start"] as? String ?? "", end = body["end"] as? String ?? ""
                guard (start.isEmpty && end.isEmpty) || (Scheduler.parseTime(start) != nil && Scheduler.parseTime(end) != nil) else {
                    respond(.error("时间格式应为 HH:mm", status: 400)); return
                }
                AppState.shared.updatePreferences { $0.mobile.quietStart = start; $0.mobile.quietEnd = end }
                respond(.json(["ok": true, "start": start, "end": end, "active": self.config.inQuietHours()]))
            case ("POST", "/api/pin"):
                let body = request.jsonBody ?? [:]
                guard let key = body["key"] as? String, !key.isEmpty else { respond(.error("缺少会话", status: 400)); return }
                let pinned = body["pinned"] as? Bool ?? true
                AppState.shared.updatePreferences { config in
                    config.mobile.pinnedSessions.removeAll { $0 == key }
                    if pinned { config.mobile.pinnedSessions.insert(key, at: 0) }
                    config.mobile.pinnedSessions = Array(config.mobile.pinnedSessions.prefix(50))
                }
                KitelineModel.shared.refresh()
                respond(.json(["ok": true, "key": key, "pinned": pinned]))
            case ("POST", "/api/mark"):
                let body = request.jsonBody ?? [:]
                guard let key = body["key"] as? String, !key.isEmpty else { respond(.error("缺少会话", status: 400)); return }
                let marked = body["marked"] as? Bool ?? true
                AppState.shared.setMarked(key, marked)
                respond(.json(["ok": true, "key": key, "marked": marked]))
            case ("POST", "/api/mute"):
                let body = request.jsonBody ?? [:]
                guard let key = body["key"] as? String, !key.isEmpty else { respond(.error("缺少会话", status: 400)); return }
                let muted = body["muted"] as? Bool ?? true
                AppState.shared.updatePreferences { config in
                    config.mobile.mutedSessions.removeAll { $0 == key }
                    if muted { config.mobile.mutedSessions.append(key) }
                    config.mobile.mutedSessions = Array(config.mobile.mutedSessions.suffix(200))
                }
                respond(.json(["ok": true, "key": key, "muted": muted]))
            case ("POST", "/api/alerts/reconnect"):
                // 列表顶上 / 锁屏通知里的「尝试重连」（见 EditorAlerts）
                guard let id = request.jsonBody?["id"] as? String, !id.isEmpty else { respond(.error("缺少提示", status: 400)); return }
                EditorAlerts.shared.reconnect(id: id) { ok, message in
                    respond(.json(["ok": ok, "message": message, "error": ok ? "" : message], status: ok ? 200 : 409))
                }
            case ("POST", "/api/notify/test") where Delivery.dryRun:
                // 自测用：走一遍真实的提醒分发（免打扰 / 静音过滤 + Bark）
                let body = request.jsonBody ?? [:]
                self.notify(kind: body["kind"] as? String ?? "conclusion", title: body["title"] as? String ?? "测试",
                            body: body["body"] as? String ?? "", key: body["key"] as? String ?? "")
                respond(.json(["ok": true]))
            case ("POST", "/api/stuck/tick") where Delivery.dryRun:
                // 自测用：模拟时间推进，验证「可能卡住了」
                StuckWatch.shared.tick(now: Date(timeIntervalSince1970: Digest.number(request.jsonBody?["now"]) / 1000))
                respond(.json(["ok": true]))
            case ("POST", "/api/idleclose/tick") where Delivery.dryRun:
                // 自测用：模拟时间推进，验证闲置会话自动关闭（不等人离开电脑）
                IdleClose.shared.tick(now: Date(timeIntervalSince1970: Digest.number(request.jsonBody?["now"]) / 1000), force: true)
                respond(.json(["ok": true, "opened": IdleClose.shared.openedKeys]))
            case ("POST", "/api/reminders/tick") where Delivery.dryRun:
                // 自测用：模拟时间推进，验证等确认提醒
                WaitingReminder.shared.tick(now: Date(timeIntervalSince1970: Digest.number(request.jsonBody?["now"]) / 1000))
                respond(.json(["ok": true]))
            case ("POST", "/api/morning/push"):
                DailyReport.shared.sendMorning(manual: true) { message in respond(.json(["ok": true, "message": message])) }
            case ("POST", "/api/schedules/tick") where Delivery.dryRun:
                // 只在自测（dry-run）时开放：模拟「现在是某个时间」，验证到点触发和错过判断
                let now = Date(timeIntervalSince1970: Digest.number(request.jsonBody?["now"]) / 1000)
                Scheduler.shared.tick(now: now)
                respond(.json(["ok": true]))
            case ("GET", "/api/repo-info"):
                guard let connection = AppState.shared.source(withId: request.query["sourceId"] ?? ""), connection.state.isLive else {
                    respond(.error("该机器当前离线", status: 404)); return
                }
                self.forwardTo(connection, ["cmd": "repo_info", "cwd": request.query["cwd"] ?? ""], respond: respond)
            case ("GET", "/api/tts/voices"):
                let voices = TTS.voices().map { ["id": $0.id, "name": $0.name, "label": $0.label, "quality": $0.quality] as [String: Any] }
                respond(.json(["ok": true, "voices": voices, "best": TTS.bestVoiceId ?? "", "edge": TTS.edgeAvailable]))
            case ("POST", "/api/translate"):
                // 翻译一条消息（微信小程序用：小程序连不上 Google 这类服务，也没有系统翻译）：电脑这边联网翻好回去
                let body = request.jsonBody ?? [:]
                let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 8000 else { respond(.error("翻译内容为空或过长", status: 400)); return }
                let target = body["to"] as? String
                Task {
                    do {
                        let r = try await HostTranslate.run(text, target: target, source: body["from"] as? String, local: body["local"] as? Bool ?? false)
                        respond(.json(["ok": true, "text": r.text, "from": r.source, "to": r.target, "engine": r.engine]))
                    } catch {
                        respond(.error(error.localizedDescription, status: 502))
                    }
                }
            case ("POST", "/api/tts"):
                // 朗读：Mac 上的自然语音合成一段 AAC，手机播放
                let body = request.jsonBody ?? [:]
                let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 1500 else { respond(.error("朗读文本为空或过长", status: 400)); return }
                let rate = Digest.number(body["rate"])
                TTS.shared.synthesize(text: text, voice: body["voice"] as? String, rate: rate > 0 ? rate : 1) { data, mime in
                    guard let data = data else { respond(.error("电脑语音合成失败", status: 500)); return }
                    respond(HTTPResponse(status: 200, headers: ["Content-Type": mime, "Cache-Control": "private, max-age=86400"], body: data))
                }
                TTS.shared.trimCache()
            case ("GET", "/api/inbox"):
                let limit = max(1, min(300, Int(request.query["limit"] ?? "") ?? 150))
                let since = Double(request.query["since"] ?? "") ?? 0
                respond(.json(["ok": true, "entries": Inbox.shared.recent(limit: limit, since: since).map(Inbox.payload)]))
            case ("GET", "/api/whoami"):
                var payload: [String: Any] = ["ok": true, "auth": auth.deviceId == nil ? "master" : "device"]
                if case .device(let device) = auth { payload["device"] = self.devicePayload(device, current: device.id) }
                respond(.json(payload))
            case ("GET", "/api/devices"):
                respond(.json(["ok": true, "devices": DeviceStore.shared.all.map { self.devicePayload($0, current: auth.deviceId) }]))
            case ("POST", "/api/devices/link"):
                // 新的一次性配对令牌（10 分钟、用一次就作废）：只有本机（主令牌）能要，Mac 的「手机访问」页、测试用
                guard case .master = auth else { respond(.error("只有这台电脑本身可以生成配对链接", status: 403)); return }
                respond(.json(["ok": true, "token": self.newLinkToken()]))
            case ("POST", "/api/devices/register"):
                // 只有拿配对令牌（扫码链接，一次性）或主令牌来的才能登记新设备；设备令牌不能再生出别的令牌
                guard auth.deviceId == nil else { respond(.error("该设备已登记", status: 403)); return }
                if case .link(let token) = auth, !self.consumeLinkToken(token) {
                    respond(.error("配对链接已使用或已过期，请在电脑上重新扫码", status: 401)); return
                }
                let (device, token) = DeviceStore.shared.register(agent: request.headers["user-agent"] ?? "", ip: request.remoteAddress,
                                                                  via: "扫码", name: request.jsonBody?["name"] as? String)
                respond(.json(["ok": true, "token": token, "device": self.devicePayload(device, current: device.id)]))
            // 停用 / 改名不限主令牌：配好的手机本来就完全可信（能让 Claude 执行任何命令），手机设置里就有「停用别的设备」
            case ("POST", "/api/devices/revoke"):
                let id = request.jsonBody?["id"] as? String ?? ""
                guard let device = self.revokeDevice(id) else { respond(.error("设备不存在", status: 404)); return }
                respond(.json(["ok": true, "name": device.name]))
            case ("POST", "/api/devices/rename"):
                let id = request.jsonBody?["id"] as? String ?? auth.deviceId ?? ""
                guard let device = DeviceStore.shared.rename(id, to: request.jsonBody?["name"] as? String ?? "") else {
                    respond(.error("名字不能为空", status: 400)); return
                }
                respond(.json(["ok": true, "device": self.devicePayload(device, current: auth.deviceId)]))
            case ("GET", "/api/files"):
                self.projectFiles(request, ["cmd": "ls", "path": request.query["path"] ?? ""], respond: respond)
            case ("GET", "/api/file"):
                self.projectFiles(request, ["cmd": "read_file", "path": request.query["path"] ?? "",
                                            "reveal": request.query["reveal"] == "1", "edit": request.query["edit"] == "1"], respond: respond)
            case ("POST", "/api/fs"):
                // 代码 IDE：保存、新建、改名、移动、复制、删除（进废纸篓）、上传
                var body = request.jsonBody ?? [:]
                body["cmd"] = "fs"
                self.projectFiles(request, body, timeout: 120, respond: respond)
            case ("GET", "/api/repo"):
                // 代码 IDE 的 Git（只读）：overview / status / log / commit_info / diff
                var body: [String: Any] = ["cmd": "repo", "op": request.query["op"] ?? "overview"]
                for field in ["ref", "q", "path", "commit", "mode", "oldPath", "job"] { if let value = request.query[field] { body[field] = value } }
                for field in ["skip", "limit", "context"] { if let value = Int(request.query[field] ?? "") { body[field] = value } }
                self.sessionGit(request, body, timeout: 60, respond: respond)
            case ("POST", "/api/repo"):
                // 代码 IDE 的 Git（会改仓库）：暂存、提交、推送拉取、分支、合并……推送能跑几分钟
                var body = request.jsonBody ?? [:]
                body["cmd"] = "repo"
                self.sessionGit(request, body, timeout: 200, respond: respond)
            case ("POST", "/api/term"):
                // 会话里的终端：开、列、读最近的输出、按键、改大小、关（开在会话所在的机器上，见 watcher 的 term）
                var body = request.jsonBody ?? [:]
                body["cmd"] = "term"
                self.sessionGit(request, body, timeout: 20, respond: respond)
            case ("GET", "/api/download"):
                self.download(request, respond: respond)
            case ("GET", "/api/files/find"):
                self.projectFiles(request, ["cmd": "find_files", "q": request.query["q"] ?? ""], respond: respond)
            case ("GET", "/api/audit"):
                respond(.json(["ok": true, "entries": Audit.recent(limit: max(1, min(500, Int(request.query["limit"] ?? "") ?? 200)))]))
            case ("GET", "/api/budget"):
                SpendGuard.check { capped in
                    respond(.json(["ok": true, "daily": self.config.dailyBudget, "cap": self.config.dailyCap, "capped": capped ?? ""]))
                }
            case ("POST", "/api/budget"):
                let body = request.jsonBody ?? [:]
                let daily = body["daily"] == nil ? self.config.dailyBudget : Digest.number(body["daily"])
                let cap = body["cap"] == nil ? self.config.dailyCap : Digest.number(body["cap"])
                guard daily >= 0, daily <= 100_000, cap >= 0, cap <= 100_000 else { respond(.error("金额无效", status: 400)); return }
                AppState.shared.updatePreferences { $0.mobile.dailyBudget = daily; $0.mobile.dailyCap = cap }
                if daily > 0 && body["daily"] != nil { BudgetWatch.shared.check() }
                respond(.json(["ok": true, "daily": daily, "cap": cap]))
            case ("POST", "/api/budget/check"):
                BudgetWatch.shared.check { message in respond(.json(["ok": true, "message": message])) }
            case ("POST", "/api/brag/shared"):
                // 手机上点了分享战绩：按设备记次数（主令牌——电脑自己的界面——不记）
                if let deviceId = auth.deviceId { DeviceStore.shared.noteShare(request.jsonBody?["via"] as? String ?? "", for: deviceId) }
                respond(.json(["ok": true]))
            case ("GET", "/api/brag"):
                // 分享战绩：带 key 只算这一个会话（任务做完时分享），不带就是最近 N 天按天的数字
                if request.query["key"] != nil {
                    self.forwardAny(request, ["cmd": "brag"], respond: respond)
                } else {
                    Brag.collect(days: Int(request.query["days"] ?? "") ?? 30, fresh: request.query["fresh"] == "1") { respond(.json($0)) }
                }
            case ("GET", "/api/usage"):
                UsageReport.collect(days: Int(request.query["days"] ?? "") ?? 7, fresh: request.query["fresh"] == "1") { respond(.json($0)) }
            case ("GET", "/api/limits"):
                Limits.collect(fresh: request.query["fresh"] == "1") { respond(.json($0)) }
            case ("GET", "/api/sessions"):
                PastSessions.list(sourceId: request.query["source"], cwd: request.query["cwd"], project: request.query["project"]) { respond(.json($0)) }
            case ("GET", "/api/search"):
                let q = (request.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty, q.count <= 100 else { respond(.error("搜索词为空或过长", status: 400)); return }
                if request.query["key"] != nil {
                    // 对话内搜索：只搜这一个会话
                    guard let target = self.resolveAny(request) else { respond(.error("会话不存在，或其所在机器离线", status: 404)); return }
                    self.forwardTo(target.connection, ["cmd": "search", "q": q, "sessionId": target.sessionId], respond: respond)
                    return
                }
                PastSessions.search(q) { respond(.json($0)) }
            case ("GET", "/api/changelog"):
                let text = ChangelogWindowController.bundledText(english: ServerLang.of(request) == "en")   // 按手机的语言给中文版 / 英文版
                respond(.json(["ok": !text.isEmpty, "text": text, "version": AppVersion.app, "error": text.isEmpty ? "此版本未包含更新记录" : ""]))
            case ("GET", "/api/host-update"):
                // 手机上看这台电脑的 Kiteline 有没有新版本、下载安装到哪了（同 Windows / Linux 版；见 Updater.payload）
                respond(.json(Updater.shared.payload()))
            case ("POST", "/api/host-update"):
                // 手机上点的：{action: check / start / cancel / restart}——让电脑下载安装新版本、装好后重启换上
                respond(.json(Updater.shared.remote(request.jsonBody?["action"] as? String ?? "")))
            case ("GET", "/api/session-meta"):
                self.sessionMeta(request, respond: respond)
            case ("POST", "/api/viewed"):
                // 打开了这些会话的详情（对话页打开时、开着且在前台时每 10 分钟）：{keys:[…]}；
                // 启动时再带上本机记的最后看过 seen:{key: 毫秒}，补升级前的历史。见 IdleClose
                IdleClose.shared.touch((request.jsonBody?["keys"] as? [String]) ?? [])
                PeerComputers.shared.noteViewed((request.jsonBody?["keys"] as? [String]) ?? [])
                if let seen = request.jsonBody?["seen"] as? [String: Any] {
                    IdleClose.shared.merge(history: seen.compactMapValues { ($0 as? NSNumber)?.doubleValue })
                }
                respond(.json(["ok": true]))
            case ("POST", "/api/resume"):
                IdleClose.shared.touch([request.query["key"] ?? ""])
                self.capGuard(request, respond: respond) { self.resume(request, respond: respond) }
            case ("GET", "/api/projects"):
                Projects.collect(detail: request.query["detail"] == "1") { respond(.json($0)) }
            case ("GET", "/api/dirs"), ("POST", "/api/dirs"):
                self.dirs(request, respond: respond)
            case ("GET", "/api/launchable"):
                // 新任务里除了 Claude Code 还能选哪几家（在那台电脑上后台运行）
                Hosted.launchable(sourceId: request.query["sourceId"] ?? "") { agents in
                    respond(.json(["ok": true, "agents": agents]))
                }
            case ("POST", "/api/new-session"):
                self.capGuard(request, respond: respond) { self.newSession(request, respond: respond) }
            case ("POST", "/api/quick-replies"):
                // items 为 null = 恢复默认
                let body = request.jsonBody ?? [:]
                let items = (body["items"] as? [Any])?.compactMap { $0 as? String }
                let cleaned = items.map(MobileConfig.cleanQuickReplies) ?? MobileConfig.defaultQuickReplies
                AppState.shared.updatePreferences { $0.mobile.quickReplies = cleaned }
                self.publishState()
                respond(.json(["ok": true, "items": cleaned]))
            case ("GET", "/api/avatar"):
                self.avatar(request, respond: respond)
            case ("GET", "/api/profile"):
                respond(.json(Profile.editorPayload(AppState.shared.config.mobile)))
            case ("POST", "/api/profile"):
                self.saveProfile(request, respond: respond)
            case ("POST", "/api/agent-face"):
                // 对话里 agent 的头像、昵称（Agent 详情里改的），见 AgentFaces
                respond(AgentFaces.shared.save(request))
            case ("GET", "/api/agent-avatar"):
                respond(AgentFaces.shared.image(request))
            case ("GET", "/api/agent-info"):
                AgentFaces.agentInfo(key: request.query["key"] ?? "", agentHint: request.query["agent"]) { respond(.json($0)) }
            case ("GET", "/api/machine"):
                AgentFaces.machine(request.query["source"] ?? "") { respond(.json($0, status: $0["ok"] as? Bool == false ? 404 : 200)) }
            case ("GET", "/api/tests"):
                self.forward(request, ["cmd": "tests", "limit": 50], respond: respond)
            case ("GET", "/api/voices"):
                let key = request.query["key"] ?? ""
                // 各端只在打开对话页时取这个：旧版手机不报 /api/viewed，靠它算「打开过」
                IdleClose.shared.touch([key])
                respond(.json(["ok": true, "voices": self.voices.list(key: key).map {
                    ["id": $0.id, "text": $0.text, "duration": $0.duration, "ts": $0.ts * 1000]
                }]))
            case ("GET", "/api/voice-audio"):
                guard let entry = self.voices.entry(id: request.query["id"] ?? ""),
                      let data = try? Data(contentsOf: self.voices.fileURL(entry)) else {
                    respond(.error("语音不存在", status: 404)); return
                }
                // 类型是手机上传时报的：只认音频，别的一律当二进制下载，免得被当成网页在本站执行
                let audio = ["audio/wav", "audio/x-wav", "audio/wave", "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac",
                             "audio/webm", "audio/ogg", "audio/mpeg"]
                let base = entry.mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                respond(HTTPResponse(status: 200, headers: ["Content-Type": audio.contains(base) ? base : "application/octet-stream",
                                                            "X-Content-Type-Options": "nosniff",
                                                            "Content-Security-Policy": "sandbox; default-src 'none'",
                                                            "Cache-Control": "private, max-age=31536000, immutable"], body: data))
            case ("GET", "/api/ping"):
                // 网络检测：bytes>0 时附带一段数据测下行速率（上限 512KB）
                let size = min(max(Int(request.query["bytes"] ?? "0") ?? 0, 0), 512 * 1024)
                var response = HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream",
                                                                   "Cache-Control": "no-store"],
                                            body: Data(count: size))
                response.headers["X-Server-Time"] = String(Int(Date().timeIntervalSince1970 * 1000))
                respond(response)
            case ("GET", "/api/info"):
                respond(.json(self.info(request)))
            case ("GET", "/api/watch"):
                // Apple Watch 的选项，和各台手机报上来的手表状态
                let watches: [[String: Any]] = DeviceStore.shared.all.compactMap { device in
                    guard let watch = device.watch else { return nil }
                    var item: [String: Any] = ["device": device.name, "deviceId": device.id, "paired": watch.paired,
                                               "installed": watch.installed, "updatedAt": watch.updatedAt, "label": watch.label]
                    if let lastUsed = watch.lastUsed { item["lastUsed"] = lastUsed }
                    if let complication = watch.complication { item["complication"] = complication }
                    return item
                }
                respond(.json(["ok": true, "prefs": AppState.shared.config.mobile.watch.payload,
                               "suggested": WatchConfig.suggestedReplies, "watches": watches]))
            case ("POST", "/api/watch"):
                var watch = AppState.shared.config.mobile.watch
                watch.merge(request.jsonBody ?? [:])
                AppState.shared.updatePreferences { $0.mobile.watch = watch }
                self.publishState()
                respond(.json(["ok": true, "prefs": watch.payload]))
            case ("POST", "/api/watch/status"):
                // 手机报手表状态：配没配 Apple Watch、装没装 Kiteline（手机打开 Kiteline、配对状态变了时报）
                guard let deviceId = auth.deviceId else { respond(.error("仅已配对的手机可上报手表状态", status: 403)); return }
                let body = request.jsonBody ?? [:]
                DeviceStore.shared.setWatch(paired: body["paired"] as? Bool ?? false, installed: body["installed"] as? Bool ?? false,
                                            complication: body["complication"] as? Bool, for: deviceId)
                respond(.json(["ok": true]))
            case ("POST", "/api/p2p/join"):
                // 开通远程访问：配对过的手机（设备令牌）报上自己的点对点公钥，拿回 Mac 的公钥和中继。
                // 之后 Mac 只接受这些公钥的远程连接；停用设备时一起撤掉
                guard let deviceId = auth.deviceId else { respond(.error("仅已配对的手机可开通远程访问", status: 403)); return }
                let phoneId = (request.jsonBody?["id"] as? String ?? "").lowercased()
                guard phoneId.count == 64, phoneId.allSatisfy(\.isHexDigit) else { respond(.error("手机公钥无效", status: 400)); return }
                DeviceStore.shared.setP2PId(phoneId, for: deviceId)
                P2P.shared.refreshAllowlist()
                if var info = P2P.shared.joinInfo {
                    info["ok"] = true
                    respond(.json(info))
                } else {
                    respond(.json(["ok": false, "error": self.config.remoteEnabled ? "电脑的远程访问尚未就绪" : "电脑未开启远程访问（Kiteline 设置 → 远程访问）"]))
                }
            case ("POST", "/api/clientlog"):
                // 手机上出的、Mac 这边看不到的问题（比如图片取到了却显示不出来）：手机报上来记进日志
                let message = (request.jsonBody?["msg"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").prefix(300)
                if !message.isEmpty { Log.write("手机报告：\(message)") }
                respond(.json(["ok": true]))
            case ("POST", "/api/presence"):
                self.presence(request, deviceId: auth.deviceId, respond: respond)
            case ("GET", "/api/push/key"):
                respond(.json(["ok": true, "publicKey": self.push.publicKey, "subscriptions": self.push.subscriptions.count]))
            case ("POST", "/api/push/subscribe"):
                self.subscribe(request, deviceId: auth.deviceId, respond: respond)
            case ("GET", "/api/share"):
                respond(.json(["ok": true, "shares": GuestLinks.shared.list(sessionKey: request.query["key"]).map(GuestLinks.payload)]))
            case ("POST", "/api/share"):
                guard let key = request.jsonBody?["key"] as? String, !key.isEmpty else { respond(.error("缺少会话", status: 400)); return }
                guard let share = GuestLinks.shared.create(sessionKey: key, hours: request.jsonBody?["hours"] as? Int ?? 24) else {
                    respond(.error("有效期只能是 1 小时、24 小时或 7 天", status: 400)); return
                }
                respond(.json(["ok": true].merging(GuestLinks.payload(share)) { $1 }))
            case ("POST", "/api/share/stop"):
                GuestLinks.shared.stop(id: request.jsonBody?["id"] as? String ?? "")
                respond(.json(["ok": true]))
            case ("POST", "/api/live/register"):
                LiveActivities.shared.register(deviceId: auth.deviceId, body: request.jsonBody ?? [:])
                respond(.json(["ok": true]))
            case ("POST", "/api/push/unsubscribe"):
                if let endpoint = request.jsonBody?["endpoint"] as? String { self.push.remove(endpoint: endpoint) }
                respond(.json(["ok": true]))
            case ("POST", "/api/push/test"):
                self.push.send(["title": "Kiteline", "body": "推送通道正常 ✓", "kind": "test"]) { delivered, errors in
                    respond(.json(["ok": delivered > 0, "delivered": delivered, "errors": errors,
                                   "error": delivered > 0 ? "" : (errors.first ?? "没有可用的推送订阅")]))
                }
            case (_, let path) where path == "/api/todos" || path.hasPrefix("/api/todos/"):
                respond(Todos.shared.handle(request))
            case (_, let path) where path == "/api/favorites" || path.hasPrefix("/api/favorites/"):
                respond(Favorites.shared.handle(request))
            case (_, let path) where path == "/api/tabgroups" || path.hasPrefix("/api/tabgroups/"):
                respond(TabGroupStore.shared.handle(request))
            case (_, let path) where path == "/api/groups" || path.hasPrefix("/api/groups/"):
                Groups.shared.handle(request, respond: respond)
            default:
                respond(.error("接口不存在", status: 404))
            }
        }
    }

    private func attach(_ stream: HTTPStream, deviceId: String?, lang: String, patch: Bool) {
        let id = ObjectIdentifier(stream)
        lock.lock()
        streams[id] = stream
        streamLangs[id] = lang
        if patch { patchStreams.insert(id) }
        pendingStreams.insert(id)
        if let deviceId = deviceId { streamDevices[id] = deviceId }
        lock.unlock()
        stream.onClose = { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.streams.removeValue(forKey: id)
            self.streamLangs.removeValue(forKey: id)
            self.patchStreams.remove(id)
            self.pendingStreams.remove(id)
            if let deviceId = self.streamDevices.removeValue(forKey: id), !self.streamDevices.values.contains(deviceId) {
                self.foreground.removeValue(forKey: deviceId)
            }
            self.lock.unlock()
            Log.write("手机断开（\(stream.remoteAddress)），剩 \(self.clientCount) 个")
            DispatchQueue.main.async { self.onClientsChange?() }
        }
        Log.write("手机连上（\(stream.remoteAddress)），共 \(clientCount) 个")
        // 建议客户端断线 3 秒后重连；先发一份完整状态
        stream.send(Data("retry: 3000\n\n".utf8))
        DispatchQueue.main.async {
            // 先把最新的状态发布出去（有变化时别的连接照常收到），新连接拿同一份、带上序号：之后的增量都以它为底
            self.publishState()
            self.lock.lock()
            self.pendingStreams.remove(id)
            self.lock.unlock()
            var payload = self.lastState
            payload["stateSeq"] = self.stateSeq
            if var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                if lang == "en" { data = ServerLang.localize(json: data) }
                stream.send(Data("event: state\ndata: ".utf8) + data + Data("\n\n".utf8))
            }
            // 再补上各台机器现在的性能（不然要等下一次 sys，最多 5 秒）
            for (id, stats) in AppState.shared.machineStats {
                if let data = try? JSONSerialization.data(withJSONObject: ["id": id, "stats": stats]),
                   let text = String(data: data, encoding: .utf8) {
                    stream.send(Data("event: sys\ndata: \(text)\n\n".utf8))
                }
            }
            self.onClientsChange?()
        }
    }

    // MARK: - 鉴权

    /// 主令牌（扫码链接、Mac 自己的对话页）或某台已配对设备的令牌
    enum Auth {
        case master
        case device(DeviceStore.Device)
        /// 一次性配对令牌（二维码里的）
        case link(String)
        var deviceId: String? { if case .device(let d) = self { return d.id }; return nil }
    }

    static func presentedTokens(_ request: HTTPRequest) -> [String] {
        [request.headers["x-ccp-token"], request.query["t"]].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// 头像图片：不带参数 = 现在用的；preset = 系统自带头像的小图；of=mac / custom = Mac 账户头像、自己选的图的小图（换头像页预览用）
    private func avatar(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let config = AppState.shared.config.mobile
        let preset = request.query["preset"], of = request.query["of"], version = request.query["v"]
        DispatchQueue.global(qos: .userInitiated).async {
            var data: Data?
            var cache = "no-store"
            if let preset = preset {
                data = Profile.thumbnail("system:" + preset)
                cache = "private, max-age=31536000, immutable"
            } else if let of = of {
                data = Profile.thumbnail(of)
            } else {
                let now = Profile.current(config)
                data = now.jpeg
                // 地址里带着版本号：头像换了地址就变，旧地址可以放心长期缓存
                if version == now.version { cache = "private, max-age=31536000, immutable" }
            }
            let response = data.map {
                HTTPResponse(status: 200, headers: ["Content-Type": "image/jpeg", "Cache-Control": cache, "X-Content-Type-Options": "nosniff"], body: $0)
            } ?? .error("未设置头像", status: 404)
            DispatchQueue.main.async { respond(response) }
        }
    }

    /// 改「我」的名字 / 头像。name 空 = 跟着 Mac 用户名；avatar = mac / text / system:<id>；image = 自己选的图（base64）
    private func saveProfile(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let body = request.jsonBody ?? [:]
        var avatar = body["avatar"] as? String
        if let image = body["image"] as? String {
            let base64 = image.range(of: "base64,").map { String(image[$0.upperBound...]) } ?? image
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), Profile.saveCustom(data) else {
                respond(.error("无法打开此图片，请选择其他图片", status: 400)); return
            }
            avatar = "custom"
        }
        if let value = avatar, !Profile.isValid(value) { respond(.error("头像不存在", status: 400)); return }
        let name = (body["name"] as? String).map(Profile.cleanName)
        AppState.shared.updatePreferences { config in
            if let value = avatar { config.mobile.avatar = value }
            if let value = name { config.mobile.myName = value == Profile.macName ? "" : value }
        }
        respond(.json(Profile.editorPayload(AppState.shared.config.mobile)))
    }

    private func authorize(_ request: HTTPRequest) -> Auth? {
        let expected = config.token
        for token in MobileServer.presentedTokens(request) {
            if !expected.isEmpty, MobileServer.constantTimeEquals(token, expected) { return .master }
            if let device = DeviceStore.shared.authenticate(token, ip: request.remoteAddress, client: request.headers["x-kiteline-client"],
                                                            agent: request.headers["user-agent"],
                                                            pro: request.headers["x-kiteline-pro"].map { $0 == "1" },
                                                            mpUser: request.headers["x-kiteline-mp"],
                                                            plan: request.headers["x-kiteline-plan"]) { return .device(device) }
            if token.hasPrefix("p"), linkTokenValid(token) { return .link(token) }
        }
        return nil
    }


    /// 收大请求体之前（HTTP 队列上调）：请求头里带的是不是主令牌或有效的设备令牌（只查不记，不算一次使用）。配对令牌不行
    private func mayUpload(_ headers: [String: String], _ target: String) -> Bool {
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") { query = HTTPServer.parseQuery(String(target[target.index(after: mark)...])) }
        let request = HTTPRequest(method: "POST", path: "", query: query, headers: headers, body: Data(), remoteAddress: "")
        let expected = config.token
        return MobileServer.presentedTokens(request).contains { token in
            (!expected.isEmpty && MobileServer.constantTimeEquals(token, expected)) || DeviceStore.shared.peek(token) != nil
        }
    }

    /// 局域网 / 本机 / Tailscale 这类内网地址（不是从公网来的）
    static func isPrivateAddress(_ raw: String) -> Bool {
        var ip = (raw.split(separator: "%").first.map(String.init) ?? raw).lowercased()
        if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst("::ffff:".count)) }
        if ip.contains(":") {
            return ip == "::1" || ip.hasPrefix("fe80") || ip.hasPrefix("fc") || ip.hasPrefix("fd") || ip.hasPrefix("fd7a:115c:a1e0")
        }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // Tailscale / 运营商级 NAT
        default: return false
        }
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<a.count { diff |= a[index] ^ b[index] }
        return diff == 0
    }

    /// 以前配对时把设备令牌也放进 Cookie（ccp）。浏览器的 Cookie 不分端口：同一台机器上别的端口的网页服务（开发服务器之类）
    /// 也会收到它。网页版一直是用请求头 / ?t= 带令牌，Cookie 用不着：不再发、不再认，看到旧的就让浏览器删掉
    private static let clearCookie = "ccp=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"

    /// 配对：6 位码换令牌。失败多了就锁一会儿，防止被人猜码。
    /// 经远程访问（中继）来的（在本机看来是 127.0.0.1）：码对了还要在 Mac 上点「允许」才配上——
    /// 用的人多了，有人输错一位碰巧撞上别人 Mac 上正显示的码，或者有人批量乱试，都配不进去
    private func pair(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let code = request.query["code"] ?? (request.jsonBody?["code"] as? String) ?? ""
        // 另一台 Kiteline 电脑来互联（带着它自己的身份，见 PeerComputers）
        let computer = request.jsonBody?["computer"] as? [String: Any]
        let publicSource = !MobileServer.isPrivateAddress(request.remoteAddress)
        let now = Date()
        pairLock.lock()
        failedPairings.removeAll { now.timeIntervalSince($0.at) > 3600 }
        let recent = failedPairings.filter { now.timeIntervalSince($0.at) <= 600 }
        // 有人把端口开到公网：从公网地址来的错码一小时合计超过 10 次，公网来的配对一律先停一小时（局域网里的照常）
        let publicFailures = failedPairings.filter { !MobileServer.isPrivateAddress($0.from) }.count
        if recent.filter({ $0.from == request.remoteAddress }).count >= 8 || recent.count >= 30 || (publicSource && publicFailures >= 10) {
            pairLock.unlock()
            Log.write("配对被拒：输错太多次（\(request.remoteAddress)）")
            respond(.error(publicSource && publicFailures >= 10 ? "尝试次数过多，请 1 小时后重试" : "尝试次数过多，请 10 分钟后重试", status: 429))
            return
        }
        guard !storedPairingCode.isEmpty, now < storedPairingExpiry,
              MobileServer.constantTimeEquals(code, storedPairingCode) else {
            let why = storedPairingCode.isEmpty ? "这个码已经用过" : (now >= storedPairingExpiry ? "码已过期" : "码不对")
            failedPairings.append((now, request.remoteAddress))
            // 防撞码：同一个验证码输错 5 次就作废（「手机访问」页上自动换新码），一个码最多只给猜 5 次
            if !storedPairingCode.isEmpty, now < storedPairingExpiry {
                codeFailures += 1
                if codeFailures >= 5 {
                    storedPairingCode = ""
                    storedPairingExpiry = now
                    Log.write("配对码连续输错 5 次，已作废，换新码")
                }
            }
            pairLock.unlock()
            // 失败也记一笔：之前只记成功，用户说「配对码从来没成功过」时日志里什么都查不到
            Log.write("手机配对失败：\(why)（\(request.remoteAddress)）")
            respond(.error("配对码错误或已过期，请在电脑上的 Kiteline「设置 → 手机访问」中查看最新配对码", status: 403))
            return
        }
        storedPairingCode = ""   // 一次性：等确认的这段时间里别人再拿同一个码来也不行
        pairLock.unlock()
        if let computer {
            let name = (computer["name"] as? String).map { String($0.prefix(60)) } ?? "Kiteline 电脑"
            Log.write("电脑「\(name)」（\(request.remoteAddress)）请求互联，等待本机确认")
            DispatchQueue.main.async {
                if PeerPrompt.ask(name: name, address: request.remoteAddress) {
                    respond(PeerComputers.shared.acceptPairing(request, computer: computer))
                } else {
                    self.pairLock.lock()
                    self.failedPairings.append((Date(), request.remoteAddress))
                    self.pairLock.unlock()
                    Log.write("电脑互联未获允许（点了拒绝，或 60 秒内没有确认）")
                    respond(.error("对方电脑上未允许这次互联。请确认输入的是那台电脑上显示的验证码，重新添加后在那台电脑上点「允许」", status: 403))
                }
            }
            return
        }
        // 局域网里来的直接配上；经远程访问（中继，本机看来是 127.0.0.1）、从公网地址来的，要在电脑上点「允许」
        guard DeviceStore.isLoopback(request.remoteAddress) || publicSource else {
            respond(finishPairing(request))
            return
        }
        let name = (request.jsonBody?["name"] as? String).map { String($0.prefix(60)) } ?? "一台手机"
        Log.write("手机经远程访问请求配对（\(name)），等待 Mac 上确认")
        DispatchQueue.main.async {
            if PairingPrompt.ask(device: name) {
                respond(self.finishPairing(request))
            } else {
                self.pairLock.lock()
                self.failedPairings.append((Date(), request.remoteAddress))
                self.pairLock.unlock()
                Log.write("经远程访问的配对未获允许（Mac 上点了拒绝，或 60 秒内没有确认）")
                respond(.error("电脑上未允许这次配对。请确认输入的是你自己电脑上显示的验证码，重新输入后在电脑上点「允许」", status: 403))
            }
        }
    }

    private func finishPairing(_ request: HTTPRequest) -> HTTPResponse {
        Log.write("手机配对成功（\(request.remoteAddress)）")
        // 设备报的名字（小程序是「机型（微信小程序）」）：同扫码登记一样用上，免得设备列表里叫「浏览器 2」分不清
        let (device, token) = DeviceStore.shared.register(agent: request.headers["user-agent"] ?? "", ip: request.remoteAddress, via: "配对码",
                                                          name: request.jsonBody?["name"] as? String)
        return .json(["ok": true, "token": token, "deviceId": device.id])
    }

    /// 浏览器打开根路径时的说明页：网页版已下线，只说明请用 Kiteline App 连接（中英双语；不带脚本、不引用任何外部资源）。
    /// Windows / Linux 版（desktop/kiteline/server.py 的 NOTICE_PAGE）是同一份，改要两边改
    static func noticePage() -> HTTPResponse {
        var response = HTTPResponse(status: 200, body: Data(noticeHTML.utf8))
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response
    }

    private static let noticeHTML = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>Kiteline</title>
    <style>
    body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; background: #f5f5f7; color: #1d1d1f;
           font: 15px/1.7 -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", "Microsoft YaHei", sans-serif; }
    main { max-width: 440px; padding: 40px 24px; text-align: center; }
    h1 { margin: 0 0 14px; font-size: 22px; font-weight: 600; letter-spacing: 0.2px; }
    p { margin: 0; color: #6e6e73; }
    p.en { margin-top: 16px; font-size: 13px; }
    @media (prefers-color-scheme: dark) { body { background: #0b0b0c; color: #f5f5f7; } p { color: #98989d; } }
    </style>
    </head>
    <body>
    <main>
    <h1>Kiteline</h1>
    <p>Kiteline 服务正在这台电脑上运行。<br>请使用 iPhone 上的 Kiteline App 连接。</p>
    <p class="en">Kiteline is running on this computer.<br>Please connect with the Kiteline app on your iPhone.</p>
    </main>
    </body>
    </html>
    """

    // MARK: - API

    private func resolve(_ request: HTTPRequest) -> (SessionRecord, SourceConnection?)? {
        guard let key = request.query["key"], let record = AppState.shared.store.record(withKey: key) else { return nil }
        return (record, AppState.shared.source(withId: record.sourceId))
    }

    /// 只读查询（历史、图片、概要）用：会话还在跑就用它的记录，已经结束的按 key「来源#会话 id」去那台机器找
    private func resolveAny(_ request: HTTPRequest) -> (key: String, sessionId: String, connection: SourceConnection)? {
        guard let key = request.query["key"] else { return nil }
        return resolveAny(key: key)
    }

    private func resolveAny(key: String) -> (key: String, sessionId: String, connection: SourceConnection)? {
        if let record = AppState.shared.store.record(withKey: key) {
            guard let connection = AppState.shared.source(withId: record.sourceId) else { return nil }
            return (key, record.snapshot.sessionId, connection)
        }
        guard let hash = key.firstIndex(of: "#") else { return nil }
        let sourceId = String(key[key.startIndex..<hash])
        let sessionId = String(key[key.index(after: hash)...])
        guard sessionId.range(of: "^[A-Za-z0-9-]{8,64}$", options: .regularExpression) != nil,
              let connection = AppState.shared.source(withId: sourceId), connection.state.isLive else { return nil }
        return (key, sessionId, connection)
    }

    /// 把请求原样转给会话所在机器的 watcher（改动报告、测试报告这类只读查询）
    private func forward(_ request: HTTPRequest, _ payload: [String: Any], respond: @escaping (HTTPResponse) -> Void) {
        guard let (record, source) = resolve(request), let connection = source else {
            respond(.error("会话不存在或已结束", status: 404)); return
        }
        var body = payload
        body["sessionId"] = record.snapshot.sessionId
        connection.request(body, timeout: 40) { result in
            switch result {
            case .success(var response):
                response.removeValue(forKey: "event")
                response.removeValue(forKey: "id")
                respond(.json(response))
            case .failure(let error):
                respond(.error(error.description, status: 502))
            }
        }
    }

    /// 和 forward 一样，但已经结束的会话也行（按「来源#会话 id」找）
    private func forwardAny(_ request: HTTPRequest, _ payload: [String: Any], respond: @escaping (HTTPResponse) -> Void) {
        guard let target = resolveAny(request) else {
            respond(.error("会话不存在，或其所在机器离线", status: 404)); return
        }
        var body = payload
        body["sessionId"] = target.sessionId
        target.connection.request(body, timeout: 40) { result in
            switch result {
            case .success(var response):
                response.removeValue(forKey: "event")
                response.removeValue(forKey: "id")
                respond(.json(response))
            case .failure(let error):
                respond(.error(error.description, status: 502))
            }
        }
    }

    /// 今日动态里的截图：会话可能已经关了，所以按「来源 + 会话 id」取；只允许 outbox 里的图（Claude 发来的）
    private func digestMedia(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let sourceId = request.query["source"], let connection = AppState.shared.source(withId: sourceId),
              let sessionId = request.query["sid"], sessionId.range(of: "^[A-Za-z0-9-]{8,64}$", options: .regularExpression) != nil,
              let ref = request.query["ref"], ref.range(of: "^o[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else {
            respond(.error("参数无效", status: 400)); return
        }
        connection.request(["cmd": "media", "sessionId": sessionId, "ref": ref], timeout: 40) { result in
            switch result {
            case .success(let response):
                guard let base64 = response["data"] as? String, let data = Data(base64Encoded: base64) else {
                    respond(.error("图片不存在", status: 404)); return
                }
                respond(Thumbnail.reply(data, mime: response["mime"] as? String ?? "image/png", request: request,
                                        cacheKey: "digest|\(sourceId)|\(sessionId)|\(ref)"))
            case .failure(let error):
                respond(.error(error.description, status: 502))
            }
        }
    }

    private func history(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let target = resolveAny(request) else {
            respond(.error("会话不存在，或其所在机器离线", status: 404)); return
        }
        let connection = target.connection
        var payload: [String: Any] = ["cmd": "history", "sessionId": target.sessionId,
                                      "limit": Int(request.query["limit"] ?? "") ?? 60]
        if let before = request.query["before"], let value = Int(before) { payload["before"] = value }
        if let beforeTs = request.query["beforeTs"], let value = Int64(beforeTs) { payload["beforeTs"] = value }
        // 子 agent 的完整记录（Agent map 里「打开完整记录」）
        if let agent = request.query["agent"], agent.range(of: "^[A-Za-z0-9_-]{3,64}$", options: .regularExpression) != nil {
            payload["agentId"] = agent
        }
        connection.request(payload, timeout: 30) { result in
            switch result {
            case .success(let response):
                respond(.json(["ok": true, "items": response["items"] as? [[String: Any]] ?? [],
                               "hasMore": response["hasMore"] ?? false]))
            case .failure(let error):
                respond(.error(error.description, status: 502))
            }
        }
    }

    /// 游客链接取会话最近的记录（同 /api/history，见 GuestLinks）：取不到回 nil；第二个值 = 前面还有更早的
    func historyItems(key: String, limit: Int, completion: @escaping ([[String: Any]]?, Bool) -> Void) {
        guard let target = resolveAny(key: key) else { completion(nil, false); return }
        target.connection.request(["cmd": "history", "sessionId": target.sessionId, "limit": limit], timeout: 30) { result in
            if case .success(let response) = result {
                completion(response["items"] as? [[String: Any]] ?? [], response["hasMore"] as? Bool ?? false)
            } else {
                completion(nil, false)
            }
        }
    }

    private func media(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let ref = request.query["ref"], let key = request.query["key"] else {
            respond(.error("缺少参数", status: 400)); return
        }
        // 取过的图先看缓存：会话已结束、机器正在重连时也照样能看。缓存里的 SVG 不用：客户端都显示不了，新版 watcher 会换成 PNG 给
        let cacheKey = "\(key)|\(ref)"
        if let (data, mime) = MediaCache.load(cacheKey), mime != "image/svg+xml" {
            respond(Thumbnail.reply(data, mime: mime, request: request, cacheKey: cacheKey)); return
        }
        guard let target = resolveAny(request) else {
            Log.write("无法获取图片：会话不存在或机器离线（\(key)，\(ref.prefix(80))）")
            respond(.error("会话不存在，或其所在机器离线", status: 404)); return
        }
        target.connection.request(["cmd": "media", "sessionId": target.sessionId, "ref": ref], timeout: 60) { result in
            switch result {
            case .success(let response):
                guard let text = response["data"] as? String, let data = Data(base64Encoded: text) else {
                    respond(.error("图片数据损坏", status: 502)); return
                }
                let mime = response["mime"] as? String ?? "image/png"
                MediaCache.store(cacheKey, data: data, mime: mime)
                respond(Thumbnail.reply(data, mime: mime, request: request, cacheKey: cacheKey))
            case .failure(let error):
                Log.write("无法获取图片（\(ref.prefix(80))）：\(error.description)")
                respond(.error(error.description, status: 502))
            }
        }
    }

    /// 图片响应：nosniff + CSP sandbox，SVG 被「在新标签页打开」时里面的脚本也跑不起来（读不到令牌）
    static func imageResponse(_ data: Data, mime: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": mime, "Cache-Control": "private, max-age=31536000, immutable",
                                            "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "sandbox; default-src 'none'; style-src 'unsafe-inline'"],
                     body: data)
    }

    /// 手机随消息带的图（images）和文件（files：PDF、Excel……，别的 App 里「用其他应用打开」发来的）：[{name, data(base64)}]，图在前。
    /// 文字发送、按住说话、新任务、恢复会话都可能带
    static func attachments(in body: [String: Any]) -> [Delivery.Attachment] {
        ["images", "files"].flatMap { field in
            (body[field] as? [[String: Any]] ?? []).compactMap { item -> Delivery.Attachment? in
                guard let encoded = item["data"] as? String, let data = Data(base64Encoded: encoded) else { return nil }
                return .init(name: item["name"] as? String ?? (field == "files" ? "file" : "image.jpg"), data: data, file: field == "files")
            }
        }
    }

    /// 电脑上的文件原样取回手机（Claude 回复里提到的路径、手机发过去的附件）：手机上预览、转发到别的 App。
    /// 路径可以在项目目录以外（Claude 常把生成的表格放桌面）；相对路径按会话目录算（已结束的会话由手机带上 cwd）
    private func download(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let path = request.query["path"] ?? ""
        guard !path.isEmpty, path.count < 4096 else { respond(.error("缺少参数", status: 400)); return }
        guard let target = resolveAny(request) else { respond(.error("会话不存在，或其所在机器离线", status: 404)); return }
        let cwd = AppState.shared.store.record(withKey: target.key)?.snapshot.cwd ?? request.query["cwd"] ?? ""
        Log.write("手机取文件：\(path.prefix(120))")
        let payload: [String: Any] = ["cmd": "get_file", "path": path, "cwd": cwd, "reveal": request.query["reveal"] == "1"]
        func finish(_ result: Result<[String: Any], RemoteError>) {
            switch result {
            case .success(let response):
                if response["secret"] as? Bool == true {
                    respond(.json(["ok": false, "secret": true, "error": "此文件可能包含密钥或密码，默认不传到手机"], status: 403)); return
                }
                guard let text = response["data"] as? String, let data = Data(base64Encoded: text) else {
                    respond(.error("文件数据损坏", status: 502)); return
                }
                respond(HTTPResponse(status: 200, headers: ["Content-Type": response["mime"] as? String ?? "application/octet-stream",
                                                            "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store",
                                                            "Content-Security-Policy": "sandbox; default-src 'none'"], body: data))
            case .failure(let error):
                respond(.error(error.description, status: 404))
            }
        }
        // 会话在别的机器上、那边没有这个文件时，再到本机找一次：远端的 agent 常把文件拷到用户这台电脑上
        // （经挂载目录、scp），回复里写的却是本机路径（如 ~/Downloads/a.pdf），远端自然找不到。相对路径只按会话目录算，不兜底
        let local = target.connection.config.kind == .local ? nil
            : AppState.shared.liveSources.first { $0.config.kind == .local }
        let absolute = path.hasPrefix("/") || path.hasPrefix("~/")
        target.connection.request(payload, timeout: 120) { result in
            guard case .failure(let error) = result, let local = local, absolute, error.description.hasPrefix("文件不存在") else {
                finish(result); return
            }
            Log.write("会话所在机器没有这个文件，改在本机找")
            local.request(payload, timeout: 120) { second in
                if case .failure = second { finish(result) } else { finish(second) }
            }
        }
    }

    /// 回应的内容里 ok 不是 false（恢复没做成时有的回 200、ok 为 false）
    private static func succeeded(_ response: HTTPResponse) -> Bool {
        ((try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any])?["ok"] as? Bool != false
    }

    /// deduped：调用方（恢复会话）已经按消息 id 认过重发了，这里不再认
    private func send(_ request: HTTPRequest, deduped: Bool = false, respond: @escaping (HTTPResponse) -> Void) {
        guard let (record, source) = resolve(request) else {
            respond(.error("会话不存在或已结束", status: 404)); return
        }
        guard let body = request.jsonBody else { respond(.error("请求格式无效", status: 400)); return }
        let text = body["text"] as? String ?? ""
        let attachments = MobileServer.attachments(in: body)
        let submit = body["submit"] as? Bool ?? config.submitOnSend
        // 手机断网重发时按消息 id 去重：请求其实已经到了、只是回应丢了，别让 Claude 收到两遍
        let cid = deduped ? nil : (body["cid"] as? String).map { "\(record.key)|\($0)" }
        let now = Date()
        recentSends = recentSends.filter { now.timeIntervalSince($0.value.at) < 600 }
        if let cid = cid, let previous = recentSends[cid] {
            Log.write("手机重发的消息已经送过（\(cid.suffix(12))），不再投递")
            var payload = previous.payload
            payload["duplicate"] = true
            respond(.json(payload)); return
        }
        // 这条在恢复会话时已经送进去了（手机没收到回应，重发时会话已经在列表里，于是改走了发消息这个入口）
        if let cid = cid, let previous = recentResumes[cid], now.timeIntervalSince(previous.at) < 600 {
            Log.write("手机重发的消息在恢复会话时已经送过（\(cid.suffix(12))），不再投递")
            respond(previous.response); return
        }
        if let cid = cid, pendingSends[cid] != nil {
            Log.write("手机重发的消息还在送达途中（\(cid.suffix(12))），等那一次的结果，不再投递")
            pendingSends[cid]?.append(respond); return
        }
        if let cid = cid { pendingSends[cid] = [] }
        Log.write("手机发往「\(record.snapshot.name)」：\(text.prefix(60))（图 \(attachments.count) 张）")
        Delivery.send(text: text, attachments: attachments, to: record, source: source, submit: submit) { outcome in
            var payload: [String: Any] = ["ok": outcome.ok, "submitted": outcome.submitted, "message": outcome.message]
            if outcome.later { payload["later"] = true }
            if let qid = outcome.qid { payload["qid"] = qid }
            if outcome.ok, let cid = cid { self.recentSends[cid] = (Date(), payload) }
            let waiters = cid.flatMap { self.pendingSends.removeValue(forKey: $0) } ?? []
            respond(.json(payload, status: outcome.ok ? 200 : 409))
            if !waiters.isEmpty {
                payload["duplicate"] = true
                let again = HTTPResponse.json(payload, status: outcome.ok ? 200 : 409)
                waiters.forEach { $0(again) }
            }
        }
    }

    private func forwardTo(_ connection: SourceConnection, _ payload: [String: Any], respond: @escaping (HTTPResponse) -> Void) {
        connection.request(payload, timeout: 30) { result in
            switch result {
            case .success(var response):
                response.removeValue(forKey: "event")
                response.removeValue(forKey: "id")
                respond(.json(response))
            case .failure(let error):
                respond(.error(error.description, status: 502))
            }
        }
    }

    /// 每日花费硬上限：超了先拦住，手机上确认「仍然发送」后带 override 再来
    private func capGuard(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void, then proceed: @escaping () -> Void) {
        if request.jsonBody?["override"] as? Bool == true { proceed(); return }
        SpendGuard.check { reason in
            guard let reason = reason else { proceed(); return }
            respond(.json(["ok": false, "capExceeded": true, "error": reason], status: 409))
        }
    }

    /// 项目文件（只读）：以会话的工作目录为根，交给那台机器的 watcher 列目录 / 读文件 / 找文件
    private func projectFiles(_ request: HTTPRequest, _ payload: [String: Any], timeout: TimeInterval = 40,
                              respond: @escaping (HTTPResponse) -> Void) {
        withSessionCwd(request, respond: respond) { target, root in
            var body = payload
            body["root"] = root
            body["sessionId"] = target.sessionId
            target.connection.request(body, timeout: timeout) { result in
                switch result {
                case .success(var response):
                    response.removeValue(forKey: "event")
                    response.removeValue(forKey: "id")
                    response["root"] = root
                    respond(.json(response))
                case .failure(let error):
                    respond(.error(error.description, status: 400))
                }
            }
        }
    }

    /// 改动报告：会话还在跑就用它当前的目录；已经结束的（历史会话、项目总览）用对话记录里的目录
    private func sessionGit(_ request: HTTPRequest, _ payload: [String: Any], timeout: TimeInterval = 40,
                            respond: @escaping (HTTPResponse) -> Void) {
        withSessionCwd(request, respond: respond) { target, cwd in
            var body = payload
            body["sessionId"] = target.sessionId
            body["cwd"] = cwd
            target.connection.request(body, timeout: timeout) { result in
                switch result {
                case .success(var response):
                    response.removeValue(forKey: "event")
                    response.removeValue(forKey: "id")
                    respond(.json(response))
                case .failure(let error):
                    respond(.error(error.description, status: 502))
                }
            }
        }
    }

    /// 会话的工作目录：在跑的取快照里的，结束的去那台机器查对话记录
    private func withSessionCwd(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void,
                                run: @escaping ((key: String, sessionId: String, connection: SourceConnection), String) -> Void) {
        guard let target = resolveAny(request) else { respond(.error("会话不存在，或其所在机器离线", status: 404)); return }
        if let record = AppState.shared.store.record(withKey: target.key), !record.snapshot.cwd.isEmpty {
            run(target, record.snapshot.cwd); return
        }
        target.connection.request(["cmd": "session_info", "sessionId": target.sessionId], timeout: 20) { result in
            guard case .success(let response) = result, let cwd = (response["session"] as? [String: Any])?["cwd"] as? String, !cwd.isEmpty else {
                respond(.error("未找到该会话的工作目录", status: 404)); return
            }
            run(target, cwd)
        }
    }

    // MARK: - 设备

    private func devicePayload(_ device: DeviceStore.Device, current: String?) -> [String: Any] {
        lock.lock()
        let online = streamDevices.values.contains(device.id)
        lock.unlock()
        return ["id": device.id, "name": device.name, "via": device.via, "createdAt": device.createdAt,
                "lastSeen": device.lastSeen, "lastIP": device.lastIP, "online": online, "current": device.id == current,
                "push": push.subscriptions.contains { $0.deviceId == device.id },
                "watch": device.watch.map { ["paired": $0.paired, "installed": $0.installed, "lastUsed": $0.lastUsed ?? 0, "label": $0.label] } ?? NSNull()]
    }

    /// 停用一台设备：删令牌、断开它的实时连接、删它的推送订阅
    @discardableResult
    func revokeDevice(_ id: String) -> DeviceStore.Device? {
        guard let device = DeviceStore.shared.revoke(id) else { return nil }
        lock.lock()
        let victims = streamDevices.filter { $0.value == id }.compactMap { streams[$0.key] }
        lock.unlock()
        victims.forEach { $0.close() }
        push.remove(deviceId: id)
        LiveActivities.shared.forget(deviceId: id)
        return device
    }

    /// 重置主令牌时：所有实时连接都断掉
    func disconnectAll() {
        lock.lock()
        let all = Array(streams.values)
        lock.unlock()
        all.forEach { $0.close() }
    }

    var onlineDeviceIds: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(streamDevices.values)
    }

    /// 会话概要（标题、目录）：已经结束的会话打开时用
    private func sessionMeta(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let target = resolveAny(request) else { respond(.error("会话不存在，或其所在机器离线", status: 404)); return }
        let sourceName = AppState.shared.config.sources.first(where: { $0.id == target.connection.id })?.displayName ?? ""
        target.connection.request(["cmd": "session_info", "sessionId": target.sessionId], timeout: 20) { result in
            switch result {
            case .success(let response):
                var meta = response["session"] as? [String: Any] ?? [:]
                meta["key"] = target.key
                meta["sourceId"] = target.connection.id
                meta["sourceName"] = sourceName
                meta["sourceKind"] = target.connection.config.kind.rawValue
                meta["live"] = AppState.shared.store.record(withKey: target.key) != nil
                respond(.json(["ok": true, "session": meta]))
            case .failure(let error):
                respond(.error(error.description, status: 404))
            }
        }
    }

    /// 恢复已经结束的会话：在它项目的 VS Code 窗口里打开这段对话；带了内容就顺便发出去。
    /// 同一会话前一条恢复还没做完（手机上连发了几条）：这条先回「排在后面」，等前一条做完——会话接上了就当普通消息发进去，
    /// 没接上再恢复一次。不然几条各自去起后台 claude、各开 VS Code 标签，互相撞掉（11-12 第一条卡在登录画面、后面两条丢了）
    private func resume(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let key = request.query["key"] ?? ""
        DispatchQueue.main.async {
            // 手机等不到回应重发的（同一个消息 id）：还在恢复就等那一次的结果，恢复成了的直接回上次的结果。
            // 原来重发的那条被当成新消息排在后面，会话恢复后同一句话进去两遍，还可能再开一个 VS Code 窗口
            var respond = respond
            if let cid = (request.jsonBody?["cid"] as? String).map({ "\(key)|\($0)" }) {
                let now = Date()
                self.recentResumes = self.recentResumes.filter { now.timeIntervalSince($0.value.at) < 600 }
                if let previous = self.recentResumes[cid] {
                    Log.write("手机重发的恢复请求已经做过（\(cid.suffix(12))），不再恢复")
                    respond(previous.response); return
                }
                if self.pendingSends[cid] != nil {
                    Log.write("手机重发的恢复请求还在处理（\(cid.suffix(12))），等那一次的结果")
                    self.pendingSends[cid]?.append(respond); return
                }
                self.pendingSends[cid] = []
                let first = respond
                respond = { response in
                    DispatchQueue.main.async {
                        // 只记做成了的：没做成的（含状态 200、内容里 ok 为 false 的）不记，手机上点重试要能再做一次
                        if response.status < 400, MobileServer.succeeded(response) { self.recentResumes[cid] = (Date(), response) }
                        let waiters = self.pendingSends.removeValue(forKey: cid) ?? []
                        first(response)
                        waiters.forEach { $0(response) }
                    }
                }
            }
            if self.resumeGates[key] != nil {
                Log.write("手机恢复会话：前一条还在恢复这个会话，这条排在它后面")
                self.resumeGates[key]?.append(request)
                respond(.json(["ok": true, "submitted": true, "openedWindow": false, "queued": true, "error": "",
                               "message": "前一条消息正在恢复此会话，这条将在其后发出"]))
                return
            }
            self.resumeGates[key] = []
            self.resumeNow(request, respond: respond, release: self.resumeRelease(key))
        }
    }

    /// 一条恢复做完时调（只算一次）：接着处理排在后面的。完成回调没来（不该发生）：最多拦 75 秒
    private func resumeRelease(_ key: String) -> () -> Void {
        var released = false
        let release = {
            DispatchQueue.main.async {
                guard !released else { return }
                released = true
                self.drainResumes(key)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 75) { release() }
        return release
    }

    /// 主线程：处理排在最前的一条，处理完再处理下一条；都处理完才撤掉闸门（处理期间新来的接着排）。
    /// 先等几秒看会话接上没有（watcher 报上来要一两秒），接上了当普通消息发；没接上它自己再恢复一次。
    /// 这些请求已经回过手机了，出错推一条提醒
    private func drainResumes(_ key: String) {
        guard let waiters = resumeGates[key], let first = waiters.first else {
            resumeGates.removeValue(forKey: key); return
        }
        resumeGates[key] = Array(waiters.dropFirst())
        let deadline = Date().addingTimeInterval(8)
        func check() {
            if AppState.shared.store.record(withKey: key) != nil {
                send(first) { response in
                    self.queuedFailure(response)
                    DispatchQueue.main.async { self.drainResumes(key) }
                }
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
            } else {
                resumeNow(first, respond: queuedFailure, release: resumeRelease(key))
            }
        }
        check()
    }

    private func queuedFailure(_ response: HTTPResponse) {
        guard response.status >= 400 else { return }
        let reply = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let message = reply?["error"] as? String ?? reply?["message"] as? String ?? ""
        notifyRoute(kind: "error", title: "消息未能送达", body: message.isEmpty ? "恢复会话未成功" : message, route: "")
    }

    private func resumeNow(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void, release: @escaping () -> Void) {
        guard let target = resolveAny(request),
              let sourceConfig = AppState.shared.config.sources.first(where: { $0.id == target.connection.id }) else {
            release()
            respond(.error("会话不存在，或其所在机器离线", status: 404)); return
        }
        if AppState.shared.store.record(withKey: target.key) != nil {
            // 手机上还当它是历史会话，其实已经接上了：直接当普通消息发（重发的在 resume 入口认过了）
            send(request, deduped: true) { response in
                respond(response)
                release()
            }
            return
        }
        let body = request.jsonBody ?? [:]
        let text = body["text"] as? String ?? ""
        let attachments = MobileServer.attachments(in: body)
        let connection = target.connection
        connection.request(["cmd": "session_info", "sessionId": target.sessionId], timeout: 20) { result in
            guard case .success(let response) = result, let meta = response["session"] as? [String: Any],
                  let cwd = meta["cwd"] as? String, cwd.hasPrefix("/") else {
                release()
                respond(.error("未找到该会话的工作目录", status: 404)); return
            }
            Delivery.stage(attachments, via: connection) { staged in
                guard case .success(let paths) = staged else {
                    release()
                    if case .failure(let error) = staged { respond(.error("图片或文件传输失败：\(error)", status: 502)) }
                    return
                }
                let prompt = Delivery.compose(text: text, paths: paths, attachments: attachments)
                let submit = !prompt.isEmpty && (body["submit"] as? Bool ?? self.config.submitOnSend)
                Log.write("手机恢复会话 \(sourceConfig.displayName):\(target.sessionId)：\(text.prefix(60))")
                let reply = self.launchReplies(respond, cwd: cwd, branch: nil)
                // 别家 agent 已经结束的会话：用它插件的启动配方在后台接着这段对话（没有 VS Code 那条路）
                if let agent = meta["agent"] as? String, !agent.isEmpty, agent != "claude-code" {
                    MobileServer.startAgent(sourceConfig, cwd: cwd, prompt: prompt, submit: submit, sessionId: target.sessionId,
                                            agent: agent, accepted: reply.accepted,
                                            completion: { outcome in release(); reply.finished(outcome) })
                    return
                }
                // editor：「在 VS Code 中恢复」按钮（Windows / Linux 客户端），远端项目也开 VS Code、不走后台托管
                NewSession.start(source: sourceConfig, cwd: cwd, prompt: prompt, submit: submit, sessionId: target.sessionId,
                                 inEditor: body["editor"] as? Bool == true, accepted: reply.accepted,
                                 completion: { outcome in release(); reply.finished(outcome) })
            }
        }
    }

    /// 新任务 / 恢复会话怎么回手机：要自动提交的，标签开出来就先回（新标签加载要十几秒，手机的请求等不了），
    /// 之后没提交成功再推一条提醒；不用等的照旧在最后回
    private func launchReplies(_ respond: @escaping (HTTPResponse) -> Void, cwd: String, branch: String?)
        -> (accepted: (NewSession.Outcome) -> Void, finished: (NewSession.Outcome) -> Void) {
        var replied = false
        func reply(_ outcome: NewSession.Outcome) {
            var payload: [String: Any] = ["ok": outcome.ok, "submitted": outcome.submitted, "openedWindow": outcome.openedWindow,
                                          "message": outcome.message, "error": outcome.ok ? "" : outcome.message, "cwd": cwd]
            if let branch { payload["branch"] = branch }
            respond(.json(payload, status: outcome.ok ? 200 : 409))
        }
        let accepted: (NewSession.Outcome) -> Void = { outcome in
            replied = true
            reply(outcome)
        }
        let finished: (NewSession.Outcome) -> Void = { outcome in
            guard replied else { reply(outcome); return }
            guard !outcome.submitted else { return }
            self.notifyRoute(kind: "error", title: "新任务未能自动提交", body: outcome.message, route: "")
        }
        return (accepted, finished)
    }

    /// 在后台运行别家命令行 agent（新任务选了它，或接着它已经结束的会话）：起不来直接报原因
    static func startAgent(_ source: SourceConfig, cwd: String, prompt: String, submit: Bool, sessionId: String?, agent: String,
                           accepted: @escaping (NewSession.Outcome) -> Void, completion: @escaping (NewSession.Outcome) -> Void) {
        // 「插件 id:变体」= 桌面应用经界面新建（如 codebuddy:workbuddy）：插件回动作单（打开它自己的深链接、按回车），这台 Mac 执行
        if agent.contains(":") {
            guard let connection = AppState.shared.source(withId: source.id), connection.state.isLive else {
                completion(NewSession.Outcome(ok: false, submitted: false, openedWindow: false, message: L("该机器当前离线"))); return
            }
            connection.request(["cmd": "agent_new", "agent": agent, "cwd": cwd, "text": prompt, "ui": ["keys", "open", "paste"]],
                               timeout: 20) { result in
                switch result {
                case .success(let reply):
                    let message = reply["message"] as? String ?? "已新建任务"
                    guard let actions = reply["ui"] as? [[String: Any]], !actions.isEmpty else {
                        completion(NewSession.Outcome(ok: true, submitted: true, openedWindow: false, message: message)); return
                    }
                    DispatchQueue.main.async {
                        Delivery.runUIActions(actions, local: source.kind == .local, sessionId: "", source: connection) { problem in
                            completion(NewSession.Outcome(ok: problem == nil, submitted: problem == nil, openedWindow: false,
                                                          message: problem ?? message))
                        }
                    }
                case .failure(let error):
                    completion(NewSession.Outcome(ok: false, submitted: false, openedWindow: false, message: Hosted.agentFailure(error)))
                }
            }
            return
        }
        Hosted.start(source: source, cwd: cwd, prompt: prompt, submit: submit, sessionId: sessionId, agent: agent,
                     accepted: accepted) { result in
            switch result {
            case .success(let outcome):
                completion(outcome)
            case .failure(let error):
                completion(NewSession.Outcome(ok: false, submitted: false, openedWindow: false, message: Hosted.agentFailure(error)))
            }
        }
    }

    /// 新任务「打开其他文件夹」：列某台电脑上一个目录里的子文件夹（不限项目目录，空 = 主目录）；POST 带 mkdir = 先在里面新建再列
    private func dirs(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let body = request.jsonBody ?? [:]
        let sourceId = request.query["sourceId"] ?? body["sourceId"] as? String ?? ""
        guard let connection = AppState.shared.source(withId: sourceId), connection.state.isLive else {
            respond(.error("该机器当前离线", status: 404)); return
        }
        var payload: [String: Any] = ["cmd": "dirs", "path": request.query["path"] ?? body["path"] as? String ?? "",
                                      "hidden": request.query["hidden"] == "1" || body["hidden"] as? Bool == true]
        if request.method == "POST", let name = body["mkdir"] as? String { payload["mkdir"] = name }
        connection.request(payload, timeout: 20) { result in
            switch result {
            case .success(var response):
                response.removeValue(forKey: "event")
                response.removeValue(forKey: "id")
                respond(.json(response))
            case .failure(let error):
                // 旧版 watcher 不认 dirs
                respond(.error(error.description.contains("未知请求") ? "该电脑上的 Kiteline 组件版本较旧，请更新后重试" : error.description, status: 400))
            }
        }
    }

    /// 新任务：在某个来源的某个目录里开一个新的 Claude Code 会话
    private func newSession(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let body = request.jsonBody else { respond(.error("请求格式无效", status: 400)); return }
        let sourceId = body["sourceId"] as? String ?? ""
        guard let sourceConfig = AppState.shared.config.sources.first(where: { $0.id == sourceId }),
              let connection = AppState.shared.source(withId: sourceId), connection.state.isLive else {
            respond(.error("该机器当前离线", status: 404)); return
        }
        let cwd = (body["cwd"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard cwd.hasPrefix("/"), cwd.count < 1024, !cwd.contains("\n"), !cwd.contains("\0") else {
            respond(.error("项目路径无效", status: 400)); return
        }
        let text = body["text"] as? String ?? ""
        let attachments = MobileServer.attachments(in: body)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            respond(.error("请先填写任务内容", status: 400)); return
        }
        let submit = body["submit"] as? Bool ?? config.submitOnSend
        connection.request(["cmd": "is_dir", "path": cwd], timeout: 15) { result in
            guard case .success(let check) = result, check["isDir"] as? Bool == true else {
                respond(.error("\(sourceConfig.displayName) 上不存在该目录：\(cwd)", status: 400)); return
            }
            Delivery.stage(attachments, via: connection) { staged in
                guard case .success(let paths) = staged else {
                    if case .failure(let error) = staged { respond(.error("图片或文件传输失败：\(error)", status: 502)) }
                    return
                }
                let prompt = Delivery.compose(text: text, paths: paths, attachments: attachments)
                Log.write("手机新任务 \(sourceConfig.displayName):\(cwd)：\(text.prefix(60))（图 \(attachments.count) 张）")
                // agent：选了别家命令行 agent（插件 id）就在那台电脑上后台运行它（见 Hosted.launchable）
                let agent = (body["agent"] as? String).flatMap { $0.isEmpty || $0 == "claude-code" ? nil : $0 }
                func launch(_ cwd: String, _ prompt: String, _ branch: String?) {
                    let reply = self.launchReplies(respond, cwd: cwd, branch: branch)
                    guard let agent else {
                        NewSession.start(source: sourceConfig, cwd: cwd, prompt: prompt, submit: submit,
                                         accepted: reply.accepted, completion: reply.finished)
                        return
                    }
                    MobileServer.startAgent(sourceConfig, cwd: cwd, prompt: prompt, submit: submit, sessionId: nil, agent: agent,
                                            accepted: reply.accepted, completion: reply.finished)
                }
                guard body["worktree"] as? Bool == true else { launch(cwd, prompt, nil); return }
                Worktree.prepare(connection, cwd: cwd, prompt: prompt) { prepared in
                    switch prepared {
                    case .success(let p): launch(p.cwd, p.prompt, p.branch)
                    case .failure(let error): respond(.error("独立分支创建失败：\(error.description)", status: 409))
                    }
                }
            }
        }
    }

    private func info(_ request: HTTPRequest) -> [String: Any] {
        let net = NetworkInfo.current()
        let hosts = net.tailscale + net.lan + net.names
        var https: [String] = []
        if config.httpsEnabled { https = hosts.map { "https://\($0):\(config.effectiveHTTPSPort)" } }
        let custom = config.publicURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if custom.hasPrefix("https://") { https.insert(custom, at: 0) }
        return [
            "ok": true,
            "host": Host.current().localizedName ?? "电脑",
            "version": AppVersion.app,
            "https": https,
            "http": ["http://127.0.0.1:\(config.port)"],   // 明文只开本机，见 start()
            "secureStatus": secureStatus,
            "pushSubscriptions": push.subscriptions.count,
            "accessibility": AXIsProcessTrusted(),
            "accessibilityName": Delivery.accessibilityName,
            "caName": LocalTLS.caName ?? "Kiteline Local CA",
            "speech": Transcriber.status,
            "submitOnSend": config.submitOnSend,
            "digestTime": config.digestTime,
            "morningTime": config.morningTime,
            "quietStart": config.quietStart,
            "quietEnd": config.quietEnd,
            "quietActive": config.inQuietHours(),
            "remindWaiting": config.remindWaiting,
            "autoCloseIdle": config.autoCloseIdle,
            "dailyBudget": config.dailyBudget,
            "remote": ["enabled": config.remoteEnabled, "state": P2P.shared.status.state, "relay": P2P.shared.status.relay ?? ""],
        ]
    }

    private func subscribe(_ request: HTTPRequest, deviceId: String?, respond: @escaping (HTTPResponse) -> Void) {
        guard let body = request.jsonBody, let endpoint = body["endpoint"] as? String,
              let keys = body["keys"] as? [String: Any],
              let p256dh = keys["p256dh"] as? String, let auth = keys["auth"] as? String else {
            respond(.error("订阅数据不完整", status: 400)); return
        }
        guard WebPush.acceptable(endpoint: endpoint, p256dh: p256dh, auth: auth) else {
            respond(.error("推送订阅地址不合法", status: 400)); return
        }
        push.add(.init(endpoint: endpoint, p256dh: p256dh, auth: auth,
                       createdAt: Date().timeIntervalSince1970, label: body["label"] as? String, deviceId: deviceId))
        respond(.json(["ok": true, "subscriptions": push.subscriptions.count]))
    }

    /// 回答提问：VS Code 的提问框只能逐项点选，没法用按键可靠地选中，
    /// 所以关掉提问框（Esc），再把答案作为一条消息提交，Claude 会按这条消息继续。
    private func answer(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let (record, source) = resolve(request) else {
            respond(.error("会话不存在或已结束", status: 404)); return
        }
        let answers = request.jsonBody?["answers"] as? [[String: Any]] ?? []
        var lines: [String] = []
        for item in answers {
            let question = (item["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var parts = (item["picked"] as? [String] ?? []).filter { !$0.isEmpty }
            if let other = item["other"] as? String, !other.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append(other.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !parts.isEmpty else { continue }
            lines.append(question.isEmpty ? "• \(parts.joined(separator: "、"))" : "• \(question)\n  → \(parts.joined(separator: "、"))")
        }
        guard !lines.isEmpty else { respond(.error("未选择任何选项", status: 400)); return }
        let text = "（回答你刚才的提问）\n" + lines.joined(separator: "\n")
        Log.write("手机回答「\(record.snapshot.name)」的提问：\(lines.joined(separator: " | ").prefix(120))")
        Delivery.answer(text: text, answers: answers, to: record, source: source) { outcome in
            respond(.json(["ok": outcome.ok, "submitted": outcome.submitted, "message": outcome.message],
                          status: outcome.ok ? 200 : 409))
        }
    }

    /// 按住说话：先转写；mode=text 只把文字还给手机（让用户改了再发），mode=send 转写后直接发给会话
    private func voice(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let body = request.jsonBody, let encoded = body["data"] as? String,
              let audio = Data(base64Encoded: encoded), audio.count > 44 else {
            respond(.error("未收到录音", status: 400)); return
        }
        guard audio.count < 12 * 1024 * 1024 else { respond(.error("录音过长", status: 413)); return }
        let mode = body["mode"] as? String ?? "send"
        let mime = body["mime"] as? String ?? "audio/wav"
        let duration = body["duration"] as? Double ?? 0
        // 输入栏里先附了截图再按住说话：图跟这段话一起交给 Claude
        let attachments = MobileServer.attachments(in: body)
        let target = resolve(request)
        if mode == "send", target == nil { respond(.error("会话不存在或已结束", status: 404)); return }
        let file: URL
        do { file = try voices.saveAudio(audio, mime: mime) } catch {
            respond(.error("录音保存失败：\(error.localizedDescription)", status: 500)); return
        }
        Transcriber.transcribe(file: file, locale: config.voiceLocale) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                try? FileManager.default.removeItem(at: file)
                respond(.error(error.description, status: 422))
            case .success(let text) where text.isEmpty:
                try? FileManager.default.removeItem(at: file)
                respond(.error("未能识别，请重新说一遍", status: 422))
            case .success(let text):
                Log.write("语音转写（\(String(format: "%.1f", duration)) 秒）：\(text.prefix(60))\(attachments.isEmpty ? "" : "（带图 \(attachments.count) 张）")")
                guard mode == "send", let (record, source) = target else {
                    try? FileManager.default.removeItem(at: file)
                    respond(.json(["ok": true, "text": text]))
                    return
                }
                Delivery.send(text: text, attachments: attachments, to: record, source: source,
                              submit: self.config.submitOnSend) { outcome in
                    var payload: [String: Any] = ["ok": outcome.ok, "text": text, "submitted": outcome.submitted,
                                                  "message": outcome.message]
                    if outcome.later { payload["later"] = true }
                    if let qid = outcome.qid { payload["qid"] = qid }
                    if outcome.ok {
                        let entry = self.voices.record(key: record.key, text: text, duration: duration,
                                                       file: file, mime: mime)
                        payload["voiceId"] = entry.id
                    } else {
                        try? FileManager.default.removeItem(at: file)
                    }
                    respond(.json(payload, status: outcome.ok ? 200 : 409))
                }
            }
        }
    }

    private func key(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let (record, source) = resolve(request) else {
            respond(.error("会话不存在或已结束", status: 404)); return
        }
        let key = (request.jsonBody?["key"] as? String) ?? request.query["k"] ?? ""
        let times = request.jsonBody?["times"] as? Int ?? 1
        Log.write("手机在「\(record.snapshot.name)」按键 \(key)\(times > 1 ? " ×\(times)" : "")")
        Delivery.press(key: key, times: times, record: record, source: source) { outcome in
            respond(.json(["ok": outcome.ok, "message": outcome.message], status: outcome.ok ? 200 : 409))
        }
    }

    /// 排队的消息：{action: move | edit | delete | now, id, text?, dir?}（见 Delivery.queue）
    private func queue(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let (record, source) = resolve(request) else {
            respond(.error("会话不存在或已结束", status: 404)); return
        }
        let body = request.jsonBody ?? [:]
        let action = body["action"] as? String ?? ""
        guard ["move", "edit", "delete", "now"].contains(action), let qid = body["id"] as? String else {
            respond(.error("请求格式无效", status: 400)); return
        }
        let text = (body["text"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if action == "edit", text == nil { respond(.error("内容为空", status: 400)); return }
        Log.write("手机调整「\(record.snapshot.name)」的排队消息：\(action)")
        Delivery.queue(action: action, qid: qid, text: text, dir: body["dir"] as? Int, record: record, source: source) { outcome in
            respond(.json(["ok": outcome.ok, "message": outcome.message], status: outcome.ok ? 200 : 409))
        }
    }

    /// 关闭会话（VS Code 里关掉它的标签页，终端里 /exit）：{key}
    private func close(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let (record, source) = resolve(request) else {
            respond(.error("会话不存在或已结束", status: 404)); return
        }
        Log.write("关闭会话「\(record.snapshot.name)」")
        Delivery.close(record: record, source: source) { outcome in
            respond(.json(["ok": outcome.ok, "message": outcome.message], status: outcome.ok ? 200 : 409))
        }
    }
}

/// 图片缓存：同一张图手机会反复看（滚动、重开），远端取一次就够
enum MediaCache {
    static var directory: URL {
        AppConfig.directoryURL.appendingPathComponent("media-cache", isDirectory: true)
    }

    private static func name(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ key: String) -> (Data, String)? {
        let base = directory.appendingPathComponent(name(key))
        guard let data = try? Data(contentsOf: base),
              let mime = try? String(contentsOf: base.appendingPathExtension("mime"), encoding: .utf8) else { return nil }
        return (data, mime)
    }

    static func store(_ key: String, data: Data, mime: String) {
        let base = directory.appendingPathComponent(name(key))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: base, options: .atomic)
        try? mime.write(to: base.appendingPathExtension("mime"), atomically: true, encoding: .utf8)
    }

    /// 启动时清掉 14 天没碰过的缓存
    static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentAccessDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for file in files {
            let accessed = (try? file.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
            if accessed < cutoff { try? fm.removeItem(at: file) }
        }
    }
}

/// 经远程访问用验证码配对时，在 Mac 上问一句「是否允许」。60 秒没点算拒绝；问完把前台还给原来的程序
/// （Kiteline 抢了前台，VS Code 就收不到手机发来的消息回车）
enum PairingPrompt {
    static func ask(device: String) -> Bool {
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "是否允许这台手机配对？"
        alert.informativeText = "「\(device)」正在通过远程访问，用这台 Mac 上显示的验证码请求配对。"
            + "配对后，它可以查看并操作这台 Mac 上的会话。\n\n如果不是你本人正在手机上输入验证码，请点「拒绝」。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "拒绝")
        alert.addButton(withTitle: "允许")
        let timer = Timer(timeInterval: 60, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let result = alert.runModal()
        timer.invalidate()
        if let previous, previous != NSRunningApplication.current { previous.activate() }
        return result == .alertSecondButtonReturn
    }
}
