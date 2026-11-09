import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// 整个 App 的状态：会话列表、各会话的对话、和 Mac 的实时连接，以及发消息、点允许这些操作
@MainActor
@Observable
final class AppModel {
    let api: MacAPI

    // Mac 推来的状态（/api/state、事件流 state）
    private(set) var host = ""
    private(set) var version = ""
    private(set) var sessions: [SessionInfo] = []
    /// 上次登记的插件 agent（标志、称呼、要求的 iPhone 版本）：变了要重画列表（Agents 表本身不是 Observable）
    @ObservationIgnored private var agentProfiles: [AgentProfile]?
    private(set) var sources: [SourceInfo] = []
    /// 要人处理的状况（VS Code 弹着对话框、到某台机器的连接断了），列表顶上显示
    private(set) var alerts: [AlertInfo] = []
    /// 正在重连的提示（按钮转圈、不能连点）
    private(set) var reconnecting: Set<String> = []
    /// 各台机器的 CPU、内存、网速（来源 id → 数据，sys 事件每 5 秒一条）。只有「按来源」分组的组头读它，别的页面不跟着刷新
    private(set) var machineStats: [String: MachineStats] = [:]
    /// 会话之间的消息往来（纸鸢传信、风筝线、协作图、对话里的卡片）
    let peers = PeerBoard()
    /// 会话里的终端
    let terminals = TerminalStore()
    /// 会话群（跨设备、跨项目的会话互相发消息，Model/Groups.swift）
    let groups = GroupBoard()
    private(set) var me: Me?
    /// 用户给会话、给某家 agent 设的头像和昵称（电脑上存着，各端同步；见 Views/AgentDetails.swift）
    private(set) var faces = FacesPayload()
    private(set) var quickReplies: [String] = []
    private(set) var pinned: [String] = []
    /// 标记的会话（新标记的在前）：所有列表最上面，不受分组限制；关闭会话、会话结束时电脑端自动取消
    private(set) var marked: [String] = []
    private(set) var muted: Set<String> = []
    private(set) var quietActive = false

    // 连接
    private(set) var connected = false
    private(set) var everConnected = false
    private(set) var connectionError: String?

    /// 正在看的会话（分列时是当前列）：朗读跟着它
    var current: String?
    /// 正开着的群聊页：这个群的提醒不弹横幅
    var viewingGroup: String?
    /// 屏幕上开着的会话，各开了几处（分列时不止一个；同一个会话也可能在分列里和推进去的页面里各一份）：这些不算未读、不弹横幅
    private(set) var openCounts: [String: Int] = [:]
    /// App 在前台时收到的提醒，弹成横幅
    var banner: NotifyEvent?
    /// 底部一闪而过的提示
    var toast: String?
    /// 连着的电脑端能做的（见 StatePayload.features）
    private(set) var hostFeatures: Set<String> = []
    /// 电脑上「远端项目在后台运行 Claude Code」的设置（见 HostedViews.swift）
    private(set) var hosted = HostedSetting()
    /// 超过每日花费上限、问一句「仍然发送吗」
    var capPrompt: (key: String, id: String, message: String)?

    private(set) var chats: [String: ChatStore] = [:]
    /// 首页汇总卡片的数
    let home = HomeStats()
    /// 延迟、下行速率：网差时顶上显示一条
    let net = NetMonitor()
    /// 通知收件箱里还没看过的条数（铃铛上的数）
    private(set) var inboxUnread = 0
    /// 我的待办 + Claude 说要你做、还没决定加不加的提示（Model/Todos.swift）
    var todos = TodoState()
    /// 我的收藏（Model/Favorites.swift）
    var favorites = FavoriteState()
    /// 新建任务后等新会话出现，出现了就自动打开（MainView 看到 pendingOpen 就推进去）
    var pendingOpen: String?
    /// 已经结束的会话的标题、目录（打开它时标题栏用）
    private(set) var pastMeta: [String: PastSession] = [:]
    /// 打开某个会话时要跳到的那条（历史搜索的命中）
    var jumpRequests: [String: String] = [:]
    private var awaitNew: (sourceId: String, cwd: String, known: Set<String>, until: Date)?
    /// 输入框里没发出去的话：像微信一样留着，列表里显示「[草稿]」
    private(set) var drafts: [String: String]
    private var seen: [String: Double]
    private var streamTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    /// 开着的对话页定时报「打开过」（见 reportViewed）
    private var viewedTask: Task<Void, Never>?
    /// 定时看两条路（局域网、远程访问）通不通，走着局域网时它断了就换到远程访问
    private var lanTask: Task<Void, Never>?
    /// 什么时候切到后台的：回来时离开得久，远程访问的旧连接多半已被系统掐断，直接重连不等它超时
    @ObservationIgnored private var backgroundAt: Date?
    @ObservationIgnored private var pathWatch: UUID?
    @ObservationIgnored private var proWatch: NSObjectProtocol?
    private var needResync = false
    /// 最近一份完整状态（解出来的 JSON）和它的序号：之后的增量（statepatch）合进它再当整份处理，见 mergeState
    @ObservationIgnored private var stateRaw: [String: Any]?
    @ObservationIgnored private var stateSeq: Int?
    /// 世界模式打开时交给网页的整份状态（同 /api/state）
    var stateJSON: Data? { stateRaw.flatMap { try? JSONSerialization.data(withJSONObject: $0) } }
    private var toastTask: Task<Void, Never>?

    /// 嵌在 Mac App 主窗口里（连 Mac 自己的服务）：不报「手机开着 App」（不然 Mac 不往手机推提醒）、不开远程访问、不测网速
    let embedded: Bool
    /// Mac 窗口标题栏上点的按钮（文件、改动、测试、中断、菜单……），对话页收到后去做
    var externalAction: (key: String, action: SessionAction, id: UUID)?
    /// Mac 端自测脚本要直接打开的页面（某个文件、某个文件的改动）
    var externalRoute: (key: String, route: Route, id: UUID)?
    /// 分屏标签栏、标题条上给群点的按钮（成员、添加成员、改群名、解散），群聊页收到后去做
    var groupAction: (id: String, action: GroupAction, token: UUID)?
    /// 成员面板展开着的群（标签栏上的成员按钮跟着变实心）
    var groupDrawers: Set<String> = []

    init(mac: PairedMac, embedded: Bool = false) {
        self.embedded = embedded
        api = MacAPI(mac: mac)
        seen = UserDefaults.standard.dictionary(forKey: "seen") as? [String: Double] ?? [:]
        drafts = UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String] ?? [:]
        Speaker.shared.api = api
        // 先显示上次存在手机上的列表：断网、Mac 没开也能翻
        if let cached = Offline.loadState() { apply(cached) }
        loadCachedTodos()
        loadCachedFavorites()
        terminals.model = self
    }

    func setDraft(_ key: String, _ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard drafts[key] != clean else { return }
        drafts[key] = clean
        UserDefaults.standard.set(drafts, forKey: "drafts")
    }

    // MARK: 查询

    func session(_ key: String) -> SessionInfo? { sessions.first { $0.key == key } }

    /// 单个会话的状态，只在这个会话自己变了时才通知。对话页读这个：别的会话（同时在跑的几个）一有动静，
    /// sessions 整个换掉，读 sessions 的页面全要重算——10-22 真机追踪，每次状态推送对话页卡 50–110 ms
    @Observable @MainActor
    final class SessionSlot {
        fileprivate(set) var info: SessionInfo?
        /// 只有在忙 / 等确认 / 空闲变了才通知（nil 是会话已结束）：对话页的消息行只看这个，
        /// 正在执行哪个工具、用量这些常变的字段由标题、输入区那几小块自己读 info（见 SessionReader）
        fileprivate(set) var activity: String?
        /// 哪个 agent 的会话（助手头像、「中断 Codex」这些称呼用）：也单独拆出来，对话页读它不会跟着 info 一起刷新
        fileprivate(set) var agent: String
        /// 用户设的头像、昵称（会话自己的，没有就是这家 agent 默认的；都没设为 nil）：同样单独拆出来，很少变
        fileprivate(set) var face: AgentFace?
        init(_ info: SessionInfo?) { self.info = info; activity = info?.activity; agent = info?.agent ?? Agents.defaultID }
        fileprivate func set(_ new: SessionInfo?) {
            if info != new { info = new }
            if activity != new?.activity { activity = new?.activity }
            if let agent = new?.agent, agent != self.agent { self.agent = agent }
        }
        fileprivate func setFace(_ new: AgentFace?) { if face != new { face = new } }
        var speaker: String { Agents.info(agent).speaker }
    }
    @ObservationIgnored private var sessionSlots: [String: SessionSlot] = [:]
    /// sessions 按 key 的副本（不触发观察），给 sessionSlot 初始化用
    @ObservationIgnored private var latestSessions: [String: SessionInfo] = [:]

    func sessionSlot(_ key: String) -> SessionSlot {
        if let slot = sessionSlots[key] { return slot }
        let slot = SessionSlot(latestSessions[key])
        slot.setFace(faces.face(key: key, agent: slot.agent))
        sessionSlots[key] = slot
        return slot
    }

    /// 换上电脑推来的头像、昵称（状态里带的、改完接口回的）：变了才换，开着的对话页跟着换头像
    func setFaces(_ incoming: FacesPayload) {
        guard incoming != faces else { return }
        faces = incoming
        for (key, slot) in sessionSlots { slot.setFace(incoming.face(key: key, agent: slot.agent)) }
    }

    func chat(_ key: String) -> ChatStore {
        if let chat = chats[key] { return chat }
        let chat = ChatStore(key: key)
        chats[key] = chat
        return chat
    }

    /// 标记的永远排最前（新标记的在上），然后是置顶的（按置顶顺序），其余看排序方式（同网页版）：
    /// started 开始时间（新的在上，位置不跳）/ recent 最近活动 / status 状态优先（等你确认 → 出错 → 在跑 → 空闲）/ name 名称。
    /// 最后都按 key 定死先后：一样的两个会话不会每次刷新互换位置
    func sortedSessions(_ order: String) -> [SessionInfo] {
        func rank(_ s: SessionInfo) -> Double {
            if s.error != nil { return 0.5 }
            return ["waiting": 0, "busy": 1, "idle": 2][s.activity] ?? 3
        }
        func mark(_ s: SessionInfo) -> Int { marked.firstIndex(of: s.key) ?? Int.max }
        func pin(_ s: SessionInfo) -> Int { pinned.firstIndex(of: s.key) ?? Int.max }
        return sessions.sorted {
            if mark($0) != mark($1) { return mark($0) < mark($1) }
            if pin($0) != pin($1) { return pin($0) < pin($1) }
            switch order {
            case "recent":
                if ($0.updatedAt ?? 0) != ($1.updatedAt ?? 0) { return ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            case "status":
                if rank($0) != rank($1) { return rank($0) < rank($1) }
                if ($0.updatedAt ?? 0) != ($1.updatedAt ?? 0) { return ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            case "name":
                let c = $0.title.localizedStandardCompare($1.title)
                if c != .orderedSame { return c == .orderedAscending }
            default:
                if ($0.startedAt ?? 0) != ($1.startedAt ?? 0) { return ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
            }
            return $0.key < $1.key
        }
    }

    func isUnread(_ s: SessionInfo) -> Bool {
        !isOpen(s.key) && (s.updatedAt ?? 0) > (seen[s.key] ?? 0) && !s.isBusy
    }

    /// 这个会话正开在屏幕上（分列里的任一列）
    func isOpen(_ key: String) -> Bool { (openCounts[key] ?? 0) > 0 }

    /// 需要你看一眼的会话数（等你确认、有新消息），显示在返回按钮上
    var attentionCount: Int {
        sessions.filter { !isOpen($0.key) && ($0.isWaiting || isUnread($0)) }.count
    }

    func markSeen(_ key: String) {
        seen[key] = max(Date().timeIntervalSince1970 * 1000, session(key)?.updatedAt ?? 0)
        UserDefaults.standard.set(seen, forKey: "seen")
    }

    // MARK: 通知收件箱

    private var inboxSeen: Double { UserDefaults.standard.double(forKey: "inboxSeen") }

    func refreshInbox() async {
        guard let reply = try? await api.get(InboxReply.self, "/api/inbox", ["limit": "100", "since": String(Int64(inboxSeen))]) else { return }
        inboxUnread = reply.entries.count
    }

    /// 打开了收件箱：最新那条之前的都算看过
    func markInboxSeen(_ latest: Double) {
        if latest > inboxSeen { UserDefaults.standard.set(latest, forKey: "inboxSeen") }
        inboxUnread = 0
    }

    func setQuickReplies(_ list: [String]) { quickReplies = list }

    func rememberPast(_ session: PastSession) { pastMeta[session.key] = session }

    func loadPastMeta(_ key: String) async {
        guard session(key) == nil, pastMeta[key] == nil,
              let reply = try? await api.data("/api/session-meta", ["key": key]),
              let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let meta = object["session"], let data = try? JSONSerialization.data(withJSONObject: meta),
              let past = try? JSONDecoder().decode(PastSession.self, from: data) else { return }
        pastMeta[key] = past
    }

    /// 新建任务开始了：等这个项目里冒出一个新会话，3 分钟内出现就自动打开
    func awaitNewSession(sourceId: String, cwd: String) {
        awaitNew = (sourceId, cwd, Set(sessions.map(\.key)), Date().addingTimeInterval(180))
    }

    private func checkAwaitNew() {
        guard let wait = awaitNew else { return }
        if Date() > wait.until { awaitNew = nil; return }
        guard let hit = sessions.first(where: { !wait.known.contains($0.key) && $0.sourceId == wait.sourceId
            && ($0.cwd == wait.cwd || ($0.cwd ?? "").hasPrefix(wait.cwd + "/")) }) else { return }
        awaitNew = nil
        flash(L("新会话已开始"))
        pendingOpen = hit.key
    }

    // MARK: 连接

    func start() {
        guard streamTask == nil else { return }
        if !embedded {
            // 在后台时 App 被挂起、收不到网络变化通知，回来时可能已经从 Wi-Fi 换到流量（或反过来）：
            // 先让点对点重新探路、请求重新选路，不然会拿着失效的旧路一直连不上。
            // 离开超过 5 秒：Mac 那头 6 秒没收到包就当这条连接断了，手机这头却要等超时才知道，直接重连
            NetLog.note("foreground", ["away": backgroundAt.map { Int(Date().timeIntervalSince($0)) } ?? -1])
            PhoneP2P.shared.resume()
            if let away = backgroundAt, Date().timeIntervalSince(away) > 5 { PhoneP2P.shared.reconnect() }
            backgroundAt = nil
            PhoneP2P.shared.networkChanged()
            api.networkChanged()
        }
        connect()
        startViewedReports()
        if embedded { return }
        #if !KITELINE_MAC
        if MacStore.shared.isDemo, !everConnected { flash(L("演示模式：使用示例数据，未连接电脑。可在设置中退出")) }
        #endif
        startPresence()
        startRemote()
        startLanWatch()
        net.start(api)
        if pathWatch == nil {
            pathWatch = NetPath.shared.onChange { [weak self] in Task { @MainActor in self?.networkChanged() } }
        }
        if proWatch == nil {
            proWatch = NotificationCenter.default.addObserver(forName: .tarsProChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.proChanged() }
            }
        }
    }

    /// 远程访问：按 Mac 的公钥连过去，把本机转发地址加进候选（在 Wi-Fi 上局域网地址优先；用流量时只走它）
    private func startRemote() {
        // 远程访问是订阅功能：免费版只在局域网里用，不启动（也不占中继）
        guard Store.shared.isPro, let info = MacStore.shared.current?.remote else { return }
        api.useRemote(Task { await PhoneP2P.shared.connect(info) })
    }

    /// 订阅状态变了：订阅了就开远程访问；没订阅了（过期、开发版模拟免费）就关掉，只走局域网
    private func proChanged() {
        if Store.shared.isPro { startRemote() } else { PhoneP2P.shared.stop() }
        networkChanged(force: true)
    }

    /// 换了网络（Wi-Fi ↔ 5G）：远程访问重新探路。
    /// 走着远程访问时实时连接不用动：它在同一条连接里换路（局域网直连 ↔ 中继），不断开；
    /// 走着局域网地址时这条 TCP 连接多半已经断了（或换了网），马上换到新路上，不等它超时。
    /// force：不管走的哪条路都重新选（订阅变了、诊断查通了路）
    func networkChanged(restartStream: Bool = true, force: Bool = false) {
        NetLog.note("network_changed", ["route": "\(api.routeKind)", "force": force, "restart": restartStream])
        PhoneP2P.shared.networkChanged()
        if !force, api.routeKind == .remote, ProGate.isUnlocked { return }
        api.networkChanged()
        guard restartStream, streamTask != nil else { return }
        streamTask?.cancel()
        streamTask = nil
        needResync = true
        connect()
    }

    /// 每次连上 Mac 都对一下远程访问信息：Mac 后来才开远程访问、换了中继，都在这时跟上
    private func refreshRemote() {
        guard PhoneP2P.available, let phoneId = PhoneP2P.publicId() else { return }
        let api = api
        Task {
            guard let reply = try? await api.post("/api/p2p/join", body: ["id": phoneId]), let info = RemoteInfo(reply) else { return }
            if info != MacStore.shared.current?.remote {
                MacStore.shared.setRemote(info)
                startRemote()
            }
        }
    }

    /// 切到后台：iOS 会掐掉连接，主动断开，回来再连、再补上这段时间的变化
    func stop() {
        NetLog.note("background")
        backgroundAt = Date()
        streamTask?.cancel()
        streamTask = nil
        if let pathWatch { NetPath.shared.cancel(pathWatch) }
        pathWatch = nil
        presenceTask?.cancel()
        presenceTask = nil
        viewedTask?.cancel()
        viewedTask = nil
        lanTask?.cancel()
        lanTask = nil
        net.stop()
        connected = false
        needResync = true
        let api = api
        Task { _ = try? await api.post("/api/presence", body: ["visible": false]) }
    }

    private func connect() {
        streamTask = Task { [weak self] in
            var delay = 1.0
            var misses = 0
            while !Task.isCancelled {
                guard let api = self?.api else { return }
                do {
                    var opened = false
                    for try await (event, data) in api.events() {
                        guard let self, !Task.isCancelled else { return }
                        if !opened {
                            opened = true
                            // 连上过又断了：第一次马上重连（远程访问重连好了、换了路），连不上再慢慢退避
                            delay = 0.3
                            NetLog.note("stream_open", ["via": "\(api.routeKind)", "link": "\(PhoneP2P.shared.link.path)"])
                            self.opened()
                        }
                        self.handle(event, data)
                    }
                    NetLog.note("stream_end", ["err": "eof", "via": "\(api.routeKind)"])
                    NetLog.saveP2PLogs()
                } catch let error as APIError where error.unauthorized {
                    // 这台手机在 Mac 上被停用了，或者 Mac 重置了配对（同组还有别的电脑就换过去）
                    MacStore.shared.dropCurrent()
                    return
                } catch {
                    NetLog.note("stream_end", ["err": "\(error)", "cancelled": Task.isCancelled, "via": "\(api.routeKind)"])
                    NetLog.saveP2PLogs()
                    if !Task.isCancelled { self?.connectionError = error.localizedDescription }
                }
                guard let self, !Task.isCancelled else { return }
                self.connected = false
                self.needResync = true
                // 几个地址一起探路：哪个通就先用哪个（Wi-Fi 断了就走远程访问）
                if await api.probe() {
                    delay = min(delay, 1)
                    misses = 0
                } else {
                    misses += 1
                    // 这台电脑连续连不上：和它互联的电脑里有连得上的就换过去（两台里有一台在线就能用）
                    if misses >= 2, !self.embedded, await self.switchToReachableComputer() { return }
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(max(delay * 2, 1), 15)
            }
        }
    }

    private func opened() {
        connected = true
        everConnected = true
        connectionError = nil
        terminals.reconnected()
        flushQueued()
        refreshRemote()
        #if !KITELINE_MAC
        // 锁屏推送：每次连上都对一下订阅（换了推送令牌、关了通知，Mac 那边跟着变）
        if !embedded {
            PushSetup.shared.connected(self)
            LiveActivities.shared.connected(self)   // 实时活动的令牌也报一下
        }
        #endif
        Task {
            await refreshInbox()
            await refreshTodos()
            await refreshFavorites()
            await peers.load(api)
            await groups.load(api)   // 老版本电脑端没有这个接口：取不到就是空的
            if !embedded { await syncComputers() }
        }
        if needResync {
            needResync = false
            resync()
        }
    }

    /// 两条路的状态，设置 → 连接里的两个灯（nil = 还没测完）：局域网（直连电脑）、中继
    private(set) var lanUp: Bool?
    private(set) var relayUp: Bool?

    /// 现在走的路，给人看（设置、诊断里显示）。读远程访问的状态，换路时跟着变
    var routeLabel: String {
        _ = PhoneP2P.shared.link
        return api.routeLabel
    }

    /// 两个灯里哪个正在用
    var usingLAN: Bool { api.routeKind == .lan || api.routeKind == .remote && PhoneP2P.shared.link.onLAN }
    var usingRelay: Bool { api.routeKind == .remote && PhoneP2P.shared.link.path == .relay }

    /// 每 3 秒读一次远程访问的状态（本机调用，不发请求）；每 15 秒测一次局域网（只连家里的电脑，不经过服务器）。
    /// 走着远程访问时不换路（它自己在连接里换）；走着局域网地址时它断了马上换到远程访问，远程访问直连了也换回去
    private func startLanWatch() {
        lanTask?.cancel()
        lanTask = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                guard let self else { return }
                if round % 5 == 0 { await self.checkRoutes() } else { self.readLink() }
                round += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func readLink() {
        guard PhoneP2P.shared.localURL != nil else { return }
        let link = PhoneP2P.shared.refreshLink()
        relayUp = link.relayOnline
        if link.onLAN { lanUp = true }
    }

    /// 连着 Wi-Fi、远程访问却一直走中继（手机和电脑之间的直连被挡了），又测得通局域网地址：连着几轮了
    @ObservationIgnored private var relayOnWiFiRounds = 0

    /// 测一轮，按「远程访问直连就用它；局域网地址断了就换到远程访问」换路
    private func checkRoutes() async {
        readLink()
        NetLog.saveP2PLogs()
        let link = PhoneP2P.shared.link
        // 远程访问正走局域网直连：局域网肯定通，不用另外测
        var lan: URL?
        if !link.onLAN { lan = await api.probeLAN() }
        guard !Task.isCancelled else { return }
        lanUp = link.onLAN || lan != nil
        if PhoneP2P.shared.localURL == nil { relayUp = nil }
        guard connected else { return }   // 还没连上：实时连接自己会探路重连
        switch api.routeKind {
        case .lan:
            // 远程访问已经直连上了（含同一 Wi-Fi 里的局域网直连）：换过去，以后换网络不用断线重连；
            // 局域网地址断了（离开家、Wi-Fi 换了）：也换到远程访问
            let direct = link.up && link.path == .direct
            if direct || lan == nil, let relayURL = await api.probeRelay() { switchRoute(to: relayURL) }
        case .remote:
            // 在家却一直走中继（中继限速、绕远）：一分钟（4 轮）都这样就换到局域网地址。
            // 先等一分钟：局域网只是短暂不通（没断 Wi-Fi）时，远程访问自己会在一分钟内升级回直连，不用断线重连
            relayOnWiFiRounds = link.path == .relay && lan != nil ? relayOnWiFiRounds + 1 : 0
            if relayOnWiFiRounds >= 4, let lan {
                relayOnWiFiRounds = 0
                switchRoute(to: lan)
            }
        default:
            break
        }
    }

    /// 换路：请求从现在起走新路，实时连接也断开重连到新路上
    private func switchRoute(to url: URL) {
        NetLog.note("switch_route", ["from": "\(api.routeKind)", "to": "\(MacAPI.AddressKind.of(url))"])
        api.use(url)
        guard streamTask != nil else { return }
        streamTask?.cancel()
        streamTask = nil
        needResync = true
        connect()
    }

    /// 告诉 Mac 这台手机正开着 Kiteline：开着时提醒只在 App 里弹横幅，不再发锁屏推送
    private func startPresence() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let api = self?.api else { return }
                _ = try? await api.post("/api/presence", body: ["visible": true])
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// 告诉电脑这几个会话的详情打开过：电脑会把 24 小时没在 Kiteline 里打开过详情的会话自动关掉、移进历史（Mac 端 IdleClose）。
    /// 对话页打开时报一次；开着、App 在前台（Mac：窗口在屏幕上看得见）时每 10 分钟再报一次，一直摆在屏幕上看的不算没打开。
    /// 只报人打开着的对话页：别的会话发来消息、它在后台回复，都不经过这里。
    /// history：再带上本机记的最后看过（未读红点那份 seen，打开、看完、标为已读时记），补上电脑升级前的历史
    func reportViewed(_ keys: [String]? = nil, history: Bool = false) {
        let keys = keys ?? Array(openCounts.keys)
        guard !keys.isEmpty || history else { return }
        var body: [String: Any] = ["keys": keys]
        if history {
            let oldest = Date().timeIntervalSince1970 * 1000 - 30 * 86400 * 1000
            body["seen"] = seen.filter { $0.value > oldest }
        }
        let api = api
        Task { _ = try? await api.post("/api/viewed", body: body) }
    }

    /// 回到前台（start）先报一次开着的（连同本机历史），之后每 10 分钟；切到后台（stop）停
    private func startViewedReports() {
        viewedTask?.cancel()
        viewedTask = Task { [weak self] in
            var history = true
            while !Task.isCancelled {
                if let self {
                    let visible = self.windowVisible
                    if visible || history { self.reportViewed(visible ? nil : [], history: history) }
                }
                history = false
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    private var windowVisible: Bool {
        #if os(macOS)
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible) }
        #else
        true   // 手机切到后台就 stop()，这个循环跟着停
        #endif
    }

    private func handle(_ event: String, _ data: Data) {
        PerfTrace.measure("事件 \(event) \(data.count)B") { handleEvent(event, data) }
    }

    private func handleEvent(_ event: String, _ data: Data) {
        let decoder = JSONDecoder()
        #if os(iOS)
        // 世界模式开着：整份状态（增量合成整份后会再走一遍 "state"）、对话、会话之间的消息、负载、待办也转给网页
        WorldBridge.current?.event(event, data)
        #endif
        switch event {
        case "state":
            if let state = try? decoder.decode(StatePayload.self, from: data) {
                apply(state)
                Offline.saveState(data)
            }
            stateRaw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            stateSeq = stateRaw?["stateSeq"] as? Int
        case "statepatch":
            // 只有变了的部分：接得上（以手里这份为底）就合进去；接不上（中间漏了一份）重连，连上时先收整份
            let patch = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard let merged = Self.mergeState(stateRaw, seq: stateSeq, patch: patch),
                  let full = try? JSONSerialization.data(withJSONObject: merged) else {
                NetLog.note("statepatch_gap", ["have": stateSeq ?? -1, "base": patch["base"] as? Int ?? -1])
                stateRaw = nil
                stateSeq = nil
                guard streamTask != nil else { break }
                streamTask?.cancel()
                streamTask = nil
                needResync = true
                connect()
                break
            }
            handleEvent("state", full)
        case "entries":
            if let entries = try? decoder.decode(EntriesEvent.self, from: data) {
                let chat = chat(entries.key)
                // 朗读模式：正在看的会话里 Claude 新说的话自动读（刚到的，不是翻出来的旧记录）
                if Speaker.shared.autoRead, entries.key == current {
                    let fresh = Date().timeIntervalSince1970 * 1000 - 120_000
                    for item in entries.items.sorted(by: ChatItem.ordered)
                    where item.t == "text" && chat.items[item.id] == nil && (item.ts ?? 0) > fresh && !(item.text ?? "").isEmpty {
                        Speaker.shared.enqueue(item.text ?? "", id: item.id)
                    }
                }
                PerfTrace.measure("合并 \(entries.items.count) 条") { chat.add(entries.items) }
                if chat.loaded { PerfTrace.measure("离线缓存 \(chat.items.count) 条") { Offline.saveChat(entries.key, Array(chat.items.values)) } }
            }
        case "reset":
            if let reset = try? decoder.decode(KeyEvent.self, from: data) {
                chats[reset.key]?.reset()
                if isOpen(reset.key) { Task { await loadHistory(reset.key, older: false) } }
            }
        case "notify":
            guard let note = try? decoder.decode(NotifyEvent.self, from: data) else { break }
            if note.inbox == true { inboxUnread += 1 }
            // 朗读模式：别的会话需要你确认、有结论了，播报一句
            if Speaker.shared.autoRead, note.key != current, ["attention", "conclusion"].contains(note.kind ?? "") {
                // 整句交给翻译（英文语序不同）：「标题，需要你确认。正文」/「Title needs your approval. Body」
                let title = note.title ?? "", body = String((note.body ?? "").prefix(80))
                Speaker.shared.enqueue(note.kind == "attention" ? L("%@，需要你确认。%@", title, body) : L("%@，有结论了。%@", title, body),
                                       id: "notify-\(Date().timeIntervalSince1970)")
            }
            if note.key.map(isOpen) != true, viewingGroup.map({ note.route == "group:" + $0 }) != true { banner = note }
        case "todos":
            receiveTodos(data)
        case "favorites":
            applyFavorites(data)
        case "groups":
            groups.apply(data)
        case "group_msg":
            groups.receive(data)
        case "sys":
            if let sys = try? decoder.decode(MachineStatsEvent.self, from: data) { machineStats[sys.id] = sys.stats }
        case "peers":
            if let event = try? decoder.decode(PeersEvent.self, from: data) { peers.receive(event.links, backfill: event.backfill == true) }
        case "term", "term_exit":
            terminals.receive(event, data)
        default:
            break
        }
    }

    /// 某台机器现在的 CPU、内存、网速：连着电脑、这台机器在线才给（断线时留下的旧数、离线缓存里的不显示）
    func liveStats(_ sourceId: String) -> MachineStats? {
        guard connected, sources.first(where: { $0.id == sourceId })?.online ?? true else { return nil }
        return machineStats[sourceId]
    }

    /// 消息翻译先交给这台电脑（translate = 有 /api/translate；translateLocal = 能只在电脑本机翻，Mac 的系统翻译）
    private func registerHostTranslate() {
        guard hostFeatures.contains("translate") else { Translator.shared.hostTranslate = nil; return }
        let api = api, local = hostFeatures.contains("translateLocal")
        Translator.shared.hostTranslate = { text, source, target, localOnly in
            if localOnly && !local { throw TranslateError(L("这台电脑不能在本机翻译")) }
            let data: Data
            do {
                data = try await api.postData("/api/translate", body: ["text": text, "to": target, "from": source, "local": localOnly])
            } catch let error as APIError {
                throw TranslateError(L("电脑翻译失败：%@", error.message), pause: error.status == 400 ? nil : 60)
            } catch {
                throw TranslateError(L("连不上电脑"), pause: 30)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let out = object["text"] as? String else {
                throw TranslateError(L("电脑返回了无法识别的内容"))
            }
            return out
        }
    }

    private func apply(_ state: StatePayload) {
        host = state.host ?? host
        version = state.version ?? version
        HostPlatform.current = state.platform ?? ""
        if let features = state.features {
            hostFeatures = Set(features)
            registerHostTranslate()
        }
        if let value = state.hosted, value != hosted { hosted = value }
        // 先登记，下面换会话列表时新 agent 的标志就画得出来；插件信息变了而会话没变（先显示的是上次的缓存）也要重画一遍
        let agentsChanged = state.agents.map { $0 != agentProfiles } ?? false
        if agentsChanged, let agents = state.agents { Agents.register(agents); agentProfiles = agents }
        let incoming = state.sessions ?? []
        // 和上次一模一样就不换：换了的话所有读 sessions 的页面都要重算
        if incoming != sessions || agentsChanged { sessions = incoming }
        #if !KITELINE_MAC
        if !embedded { LiveActivities.shared.sessionsChanged(incoming, host: host) }   // 前台时有会话在干活：本机开实时活动
        #endif
        latestSessions = Dictionary(incoming.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, slot) in sessionSlots { slot.set(latestSessions[key]) }
        if let incoming = state.faces { setFaces(incoming) } else { for (key, slot) in sessionSlots { slot.setFace(faces.face(key: key, agent: slot.agent)) } }
        sources = state.sources ?? []
        let incomingAlerts = state.alerts ?? []
        if incomingAlerts != alerts { alerts = incomingAlerts }
        if let sys = state.sys { machineStats = sys }
        me = state.me
        quickReplies = state.quickReplies ?? []
        pinned = state.pinned ?? []
        if let incoming = state.marked, incoming != marked { marked = incoming }
        muted = Set(state.muted ?? [])
        quietActive = state.quietActive ?? false
        // 第一次见到的会话不算未读，之后有新动静才亮红点
        var changed = false
        for s in sessions where seen[s.key] == nil {
            seen[s.key] = s.updatedAt ?? Date().timeIntervalSince1970 * 1000
            changed = true
        }
        if changed { UserDefaults.standard.set(seen, forKey: "seen") }
        for key in openCounts.keys where session(key) != nil { markSeen(key) }
        checkAwaitNew()
        #if os(iOS) && !targetEnvironment(macCatalyst) && !KITELINE_MAC
        // 等你确认 / 在工作的数变了：推给 Apple Watch 的表盘复杂功能
        if !embedded { WatchBridge.shared.phoneStateChanged(sessions) }
        #endif
    }

    /// 断线重连 / 回到前台：中间的变化可能漏了，重新拉列表和正在看的会话的最新一页
    /// 重连后补上断开这段时间的变化：状态不用另外取（流里第一条就是整份），只重新拉开着的对话
    func resync() {
        Task {
            for key in openCounts.keys where chat(key).loaded { await loadHistory(key, older: false) }
        }
    }

    /// 增量合进上一份完整状态（Mac 的 MobileServer.statePatch 出的）：base 要和手里这份的序号对上，不然返回 nil。
    /// upsert 的会话按 key 整条换、新的先放后面，remove 的拿掉，带了 order 就按它排；set / unset 换会话以外的字段
    nonisolated static func mergeState(_ raw: [String: Any]?, seq: Int?, patch: [String: Any]) -> [String: Any]? {
        guard var state = raw, let seq, patch["base"] as? Int == seq, let next = patch["seq"] as? Int else { return nil }
        var sessions = state["sessions"] as? [[String: Any]] ?? []
        let upsert = patch["upsert"] as? [[String: Any]] ?? []
        if !upsert.isEmpty {
            var index = Dictionary(sessions.enumerated().compactMap { i, s in (s["key"] as? String).map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
            for session in upsert {
                guard let key = session["key"] as? String else { continue }
                if let i = index[key] { sessions[i] = session } else { index[key] = sessions.count; sessions.append(session) }
            }
        }
        if let remove = patch["remove"] as? [String], !remove.isEmpty {
            let gone = Set(remove)
            sessions.removeAll { ($0["key"] as? String).map(gone.contains) ?? false }
        }
        if let order = patch["order"] as? [String] {
            let byKey = Dictionary(sessions.compactMap { s in (s["key"] as? String).map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
            sessions = order.compactMap { byKey[$0] }
        }
        state["sessions"] = sessions
        for (field, value) in patch["set"] as? [String: Any] ?? [:] { state[field] = value }
        for field in patch["unset"] as? [String] ?? [] { state.removeValue(forKey: field) }
        state["stateSeq"] = next
        return state
    }

    func refresh() async {
        do {
            let data = try await api.data("/api/state")
            apply(try JSONDecoder().decode(StatePayload.self, from: data))
            Offline.saveState(data)
        } catch {
            show(error)
        }
    }

    func loadHistory(_ key: String, older: Bool) async {
        let chat = chat(key)
        guard !chat.loading, !(older && !chat.hasMore) else { return }
        chat.loading = true
        defer { chat.loading = false }
        var query = ["key": key, "limit": "60"]
        if older {
            if let offset = chat.oldestOffset { query["before"] = String(offset) }
            if let ts = chat.oldestTs { query["beforeTs"] = String(Int64(ts)) }
        }
        do {
            let page = try await api.get(HistoryPage.self, "/api/history", query)
            if older || !chat.loaded { chat.hasMore = (page.hasMore ?? false) && !page.items.isEmpty }
            chat.loaded = true
            chat.add(page.items)
            Offline.saveChat(key, Array(chat.items.values))
        } catch {
            show(error)
        }
    }

    /// 打开一个会话：离开超过 10 分钟的，标出「以下是新消息」。分列里不是当前列的（focus = false）不抢朗读
    func open(_ key: String, focus: Bool = true) {
        openCounts[key, default: 0] += 1
        if focus || current == nil { current = key }
        let chat = chat(key)
        if let last = seen[key], Date().timeIntervalSince1970 * 1000 - last > 10 * 60 * 1000 {
            chat.newSince = last
        } else {
            chat.newSince = nil
        }
        #if SNAPSHOT
        // 截图版看「离开期间小结」：TARS_DEMO_CATCHUP=分钟，当作离开了这么久
        if let minutes = ProcessInfo.processInfo.environment["TARS_DEMO_CATCHUP"].flatMap(Double.init) {
            chat.newSince = Date().timeIntervalSince1970 * 1000 - minutes * 60_000
        }
        #endif
        markSeen(key)
        reportViewed([key])
        // 先放上次存在手机上的，连上后再换成最新的
        if !chat.loaded, chat.items.isEmpty, let cached = Offline.loadChat(key) { chat.add(cached) }
        Task { await loadHistory(key, older: false) }
        Task { await loadVoices(key) }
    }

    /// 这个会话里用语音发过的消息：对话里画成语音条，点了能放。
    /// 只在打开对话页时取：电脑把这个请求也当「打开过详情」（不报 /api/viewed 的旧版靠它），别处别调
    private func loadVoices(_ key: String) async {
        guard let reply = try? await api.get("/api/voices", ["key": key]),
              let list = reply["voices"] as? [[String: Any]] else { return }
        let chat = chat(key)
        for entry in list {
            guard let id = entry["id"] as? String, let text = entry["text"] as? String else { continue }
            chat.voices[text.trimmingCharacters(in: .whitespacesAndNewlines)] = VoiceClip(id: id, duration: entry["duration"] as? Double ?? 0)
        }
    }

    func close(_ key: String) {
        let left = (openCounts[key] ?? 1) - 1
        openCounts[key] = left > 0 ? left : nil
        if current == key, left <= 0 { current = openCounts.keys.first }
        markSeen(key)
    }

    // MARK: 操作

    /// 发消息（可带图）。会话已经结束的，Mac 会先在 VS Code 里恢复这段对话再发。返回这条的 id（没发返回 nil）
    @discardableResult
    func send(_ key: String, text: String, images: [(name: String, data: Data, preview: Data)], files: [(name: String, data: Data)] = []) -> String? {
        let id = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<1_000_000), radix: 36)
        let pending = PendingSend(id: id, text: text, previews: images.map(\.preview),
                                  payload: images.map { ["name": $0.name, "data": $0.data.base64EncodedString()] },
                                  files: files.map { PendingFile(name: $0.name, size: $0.data.count) },
                                  filePayload: files.map { ["name": $0.name, "data": $0.data.base64EncodedString()] })
        chat(key).pending.append(pending)
        Task { await deliver(key, id) }
        return id
    }

    /// 按住说话：录音交给 Mac 转写，转写完直接发给 Claude（附着的图一起发）
    func sendVoice(_ key: String, audio: Data, duration: Double, images: [(name: String, data: Data, preview: Data)], files: [(name: String, data: Data)] = []) {
        let id = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<1_000_000), radix: 36)
        var pending = PendingSend(id: id, text: "", previews: images.map(\.preview),
                                  payload: images.map { ["name": $0.name, "data": $0.data.base64EncodedString()] },
                                  files: files.map { PendingFile(name: $0.name, size: $0.data.count) },
                                  filePayload: files.map { ["name": $0.name, "data": $0.data.base64EncodedString()] })
        pending.voice = duration
        pending.audio = audio
        chat(key).pending.append(pending)
        Task { await deliver(key, id) }
    }

    /// 按住说话后滑到「转文字」：只转写、不发送，文字放进输入框给你改了再发
    func transcribe(_ audio: Data) async -> String? {
        do {
            let reply = try await api.post("/api/voice", body: ["data": audio.base64EncodedString(), "mime": "audio/wav", "mode": "text"])
            return reply["text"] as? String
        } catch {
            show(error)
            return nil
        }
    }

    /// 没发出去的消息不要了：从对话里拿掉
    func discard(_ key: String, _ id: String) {
        chat(key).pending.removeAll { $0.id == id }
    }

    func retry(_ key: String, _ id: String, override: Bool = false) {
        chat(key).update(id) {
            $0.state = .sending
            if override { $0.override = true }
        }
        Task { await deliver(key, id) }
    }

    private func deliver(_ key: String, _ id: String) async {
        let chat = chat(key)
        guard let p = chat.pending.first(where: { $0.id == id }) else { return }
        let live = session(key) != nil
        do {
            let reply: [String: Any]
            if let audio = p.audio {
                reply = try await api.post("/api/voice", ["key": key], body: [
                    "data": audio.base64EncodedString(), "mime": "audio/wav", "duration": p.voice ?? 0,
                    "mode": "send", "images": p.payload, "files": p.filePayload,
                ])
                if let text = reply["text"] as? String {
                    chat.update(id) { $0.text = text }
                    if let voiceId = reply["voiceId"] as? String {
                        chat.voices[text.trimmingCharacters(in: .whitespacesAndNewlines)] = VoiceClip(id: voiceId, duration: p.voice ?? 0)
                    }
                    chat.settleAgain()
                }
            } else {
                reply = try await api.post(live ? "/api/send" : "/api/resume", ["key": key],
                                           body: ["text": p.text, "images": p.payload, "files": p.filePayload, "override": p.override, "cid": p.id])
            }
            let submitted = reply["submitted"] as? Bool ?? false
            chat.update(id) { $0.state = submitted ? .sent : .filled }
            if !submitted { flash(reply["message"] as? String ?? L("已填入 VS Code 输入框，未提交")) }
            // 发给空闲的会话：15 秒后 Claude 还没动、对话里也没出现这条，多半没提交上（10-25 用户遇到过：回车被输入法拿去上屏拼音），
            // 标出来，别让它两分钟后悄悄消失。斜杠命令不回显成消息，不算
            if submitted, live, let before = session(key), !before.isBusy, !before.isWaiting,
               !(chat.pending.first { $0.id == id }?.text ?? "").hasPrefix("/") {
                Task { [weak self, weak chat] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, let chat, let now = self.session(key), !now.isBusy, !now.isWaiting,
                          chat.pending.contains(where: { $0.id == id && $0.state == .sent }) else { return }
                    chat.update(id) { $0.state = .unconfirmed }
                }
            }
            // 等对话记录回显来撤掉占位；万一没回显，两分钟后也撤掉（没提交上的留着，等用户自己移除）
            Task { [weak chat] in
                try? await Task.sleep(for: .seconds(120))
                chat?.pending.removeAll { $0.id == id && !$0.isFailed && $0.state != .unconfirmed }
            }
        } catch is OfflineError {
            chat.update(id) { $0.state = .queued }   // 网络不通：排队，连上后自动发
        } catch let error as APIError {
            chat.update(id) { $0.state = .failed(error.message) }
            if error.data["capExceeded"] as? Bool == true { capPrompt = (key, id, error.message) }
        } catch {
            chat.update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// 连上了：把离线时排队的消息依次发出去
    private func flushQueued() {
        for (key, chat) in chats {
            for p in chat.pending where p.state == .queued { retry(key, p.id) }
        }
    }

    /// 确认框上的按键：1 允许 / 2 总是允许 / esc 拒绝或中断 / enter 确认
    func press(_ key: String, _ button: String, label: String) async -> Bool {
        do {
            try await api.post("/api/key", ["key": key], body: ["key": button])
            flash(label)
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// 关闭会话：电脑上关掉它在 VS Code 里的标签页（终端里发 /exit），会话进「历史会话」
    func closeSession(_ key: String) async -> Bool {
        do {
            let reply = try await api.post("/api/close", ["key": key], body: [:])
            flash(reply["message"] as? String ?? L("已关闭会话"))
            return true
        } catch {
            show(error)
            return false
        }
    }

    func answer(_ key: String, tool: ChatItem, answers: [[String: Any]]) async -> Bool {
        do {
            let reply = try await api.post("/api/answer", ["key": key], body: ["answers": answers, "toolId": tool.toolId ?? ""])
            flash(reply["submitted"] as? Bool == true ? L("已回答") : (reply["message"] as? String ?? L("已填入")))
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// 「尝试重连」：VS Code 对话框上有重连按钮就替你按，「工作区不存在」这类关掉框、重新加载窗口，电脑到某台机器断了就立即重连。
    /// 只是修连接，免费版也能用
    func reconnect(alert id: String) async {
        guard !reconnecting.contains(id) else { return }
        reconnecting.insert(id)
        defer { reconnecting.remove(id) }
        do {
            let reply = try await api.post("/api/alerts/reconnect", body: ["id": id])
            flash(reply["message"] as? String ?? L("正在重新连接…"))
        } catch {
            show(error)
        }
    }

    /// 改电脑上的后台运行设置：某台开 / 关、提示不再提示（先在本机改，电脑没接住再改回来）
    func setHosted(sourceId: String? = nil, on: Bool? = nil, tipOff: Bool? = nil) async {
        let before = (hosted, sources)
        if let tipOff { hosted.tipOff = tipOff }
        if let sourceId, let on, let index = sources.firstIndex(where: { $0.id == sourceId }) { sources[index].hosted = on ? "on" : "off" }
        var body: [String: Any] = [:]
        if let sourceId { body["sourceId"] = sourceId }
        if let on { body["on"] = on }
        if let tipOff { body["tipOff"] = tipOff }
        do {
            try await api.post("/api/hosted/settings", body: body)
        } catch {
            (hosted, sources) = before
            show(error)
        }
    }

    func setPinned(_ key: String, _ on: Bool) {
        Task {
            do {
                try await api.post("/api/pin", body: ["key": key, "pinned": on])
                pinned = on ? [key] + pinned.filter { $0 != key } : pinned.filter { $0 != key }
            } catch { show(error) }
        }
    }

    func isMarked(_ key: String) -> Bool { marked.contains(key) }

    /// 标记 / 取消标记：先在本机改（星星立刻亮 / 灭），电脑没接住再改回来
    func setMarked(_ key: String, _ on: Bool) {
        let before = marked
        marked = on ? [key] + marked.filter { $0 != key } : marked.filter { $0 != key }
        Haptics.tap()
        Task {
            do {
                try await api.post("/api/mark", body: ["key": key, "marked": on])
            } catch {
                marked = before
                show(error)
            }
        }
    }

    func setMuted(_ key: String, _ on: Bool) {
        Task {
            do {
                try await api.post("/api/mute", body: ["key": key, "muted": on])
                if on { muted.insert(key) } else { muted.remove(key) }
            } catch { show(error) }
        }
    }

    // MARK: 提示

    /// 一直挂着、不自动收起的小提示（取文件的进度）；nil 收起
    func hold(_ text: String?) {
        toastTask?.cancel()
        toast = text
    }

    func flash(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }

    func show(_ error: Error) {
        if (error as? APIError)?.unauthorized == true {
            MacStore.shared.dropCurrent()
            return
        }
        flash(error.localizedDescription)
    }
}

extension PendingSend {
    var isFailed: Bool { if case .failed = state { return true } else { return false } }
}

// MARK: - 电脑互联：同组的其他 Kiteline 电脑

/// GET /api/computers 的回答（旧版电脑端没有这个接口）
private struct ComputersReply: Decodable {
    struct Computer: Decodable {
        var id: String
        var name: String
        var addresses: [String]?
    }
    var selfId: String?
    var computers: [Computer]
    private enum CodingKeys: String, CodingKey { case selfId = "self", computers }
}

extension AppModel {
    /// 连上后问这台电脑「还和哪些电脑互联」：没有令牌的请这台电脑替手机在那台上登记，记进 MacStore（这台连不上时换过去）
    func syncComputers() async {
        guard let reply = try? await api.get(ComputersReply.self, "/api/computers") else { return }
        let known = MacStore.shared.current?.others ?? []
        var list: [PairedMac] = []
        for computer in reply.computers {
            if var mac = known.first(where: { $0.computerId == computer.id }) {
                mac.name = computer.name
                for raw in computer.addresses ?? [] {
                    if let url = URL(string: raw), !mac.addresses.contains(url) { mac.addresses.append(url) }
                }
                list.append(mac)
                continue
            }
            guard let answer = try? await api.post("/api/computers/enroll", body: ["id": computer.id]),
                  let token = answer["token"] as? String, !token.isEmpty else { continue }
            let addresses = (answer["addresses"] as? [String] ?? computer.addresses ?? []).compactMap(URL.init(string:))
            guard !addresses.isEmpty else { continue }
            let ca = (answer["ca"] as? String).flatMap { Data(base64Encoded: $0) }
            // 自动登记的不算新配对：换过去时不再弹「还差几步」（MainView.firstReadiness 按令牌记）
            UserDefaults.standard.set(true, forKey: "readinessShown:\(token.prefix(12))")
            list.append(PairedMac(name: answer["name"] as? String ?? computer.name, addresses: addresses, token: token,
                                  caCertificate: ca, remote: nil, computerId: computer.id))
        }
        await MainActor.run { MacStore.shared.setOthers(selfId: reply.selfId, list) }
    }

    /// 现在这台连不上：挨个试同组的其他电脑，有连得上的就换过去（MainView 按令牌重建，列表、对话都从那台取）
    func switchToReachableComputer() async -> Bool {
        let others = await MainActor.run { MacStore.shared.current?.others ?? [] }
        for mac in others {
            guard let id = mac.computerId else { continue }
            let probe = MacAPI(mac: mac)
            if await probe.probe() {
                NetLog.note("computer_switch", ["to": mac.name])
                await MainActor.run {
                    MacStore.shared.switchTo(id)
                    flash(L("已切换到电脑「%@」", mac.name))
                }
                return true
            }
        }
        return false
    }
}
