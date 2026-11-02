import AppKit
import Combine
import SwiftUI
import KitelineKit

/// 界面用的会话条目（从 SessionRecord 摘出界面需要的字段）
struct SessionItem: Identifiable, Equatable {
    let id: String
    var title: String
    var name: String
    var activity: Activity
    /// 列表第二行：等你确认的原因 / 正在执行的工具 / 最后一句结论
    var line: String
    /// 这一轮任务做到第几步（忙、等确认时才有）：第二行前面挂「2/4 开发中」
    var stage: StageSnapshot?
    /// 目标（/goal）：在做的、结束不久的，第二行前面挂「◎ 目标 · 第 3 轮」
    var goal: GoalSnapshot?
    /// 出错停下了（侧栏「出错」筛选、状态排序排在待确认后面，同手机）
    var failed: Bool
    var sourceId: String
    var sourceName: String
    /// 只能看、不能远程操作（Proma 这类没有对外接口的）
    var readOnly: Bool
    var kind: SourceKind
    var cwd: String
    var folder: String
    var updatedAt: Double?
    var startedAt: Double?
    var pendingTool: String?
    var canReply: Bool
    var isVSCode: Bool
    var entrypoint: String
    /// 哪个编程 agent 的会话（claude-code / codex / …）
    var agent: String
    /// 看、回复、确认、中断以外这个 agent 还有的功能（mode / model / compact / subagents / tests），菜单按它出
    var caps: Set<String>
    var usage: UsageInfo?
    /// 思考等级（/effort 或 VS Code 里选的，watcher 从对话记录里认）
    var effort: String?
    /// 派过几个子 agent（做完的也算）
    var subagents: Int

    /// 「Opus 5.5 · 超高」：模型名 + 思考等级（还不知道就空）
    var tune: String {
        let model = SessionItem.modelName(usage?.model)
        let level = effort.flatMap { SessionItem.effortNames[$0] }
        return [model.isEmpty ? nil : model, level].compactMap { $0 }.joined(separator: " · ")
    }

    static var effortNames: [String: String] { ["auto": L("自动"), "low": L("低"), "medium": L("中"), "high": L("高"), "xhigh": L("超高"), "max": L("最高")] }

    /// claude-opus-5-5 → Opus 5.5
    static func modelName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "" }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    init(record: SessionRecord) {
        let s = record.snapshot
        id = record.key
        title = s.displayTitle
        name = s.name
        activity = s.act
        stage = s.liveStage
        goal = s.listGoal
        switch s.act {
        // 等待原因、出错原因是电脑（watcher）拼的中文：按这台 Mac 的界面语言换；Claude 的回复（message）是内容，不动
        case .waiting: line = s.blockingDescription.map(ServerLang.ui) ?? L("需要确认")
        case .busy:
            line = s.activityText.map { L("正在 %@", "\($0)") } ?? (s.reason.map(ServerLang.ui) ?? L("正在工作…"))
            if let minutes = StuckWatch.quietMinutes(s, now: Date()) { line = L("可能停滞：%@ 分钟无进展 · %@", "\(minutes)", "\(line)") }
        default: line = s.error.map { L("出错已停止：%@", ServerLang.ui($0.display)) } ?? (s.message ?? s.reason ?? "").replacingOccurrences(of: "\n", with: " ")
        }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        failed = s.error != nil
        sourceId = record.sourceId
        sourceName = ServerLang.machine(record.sourceName)
        readOnly = s.readOnly ?? false
        kind = record.kind
        cwd = s.cwd
        folder = (s.cwd as NSString).lastPathComponent
        updatedAt = s.transcriptUpdatedAt ?? s.statusUpdatedAt ?? s.updatedAt
        startedAt = s.startedAt
        pendingTool = s.pendingTool
        canReply = s.canReply(local: record.kind == .local)
        isVSCode = s.isVSCode
        entrypoint = s.entrypoint ?? ""
        agent = s.agentID
        caps = Set(s.capsPayload)
        usage = s.usage
        effort = s.effort?.effort
        subagents = s.subagents ?? 0
    }

    func can(_ cap: String) -> Bool { caps.contains(cap) }
}

struct SourceItem: Identifiable, Equatable {
    let id: String
    var name: String
    var kind: SourceKind
    var host: String?
    var enabled: Bool
    var online: Bool
    var status: String
    var sessions: Int
}

/// 左边会话列表显示还是收起（世界模式里能收起，世界占满整个窗口；展开时浮在世界上面）。
/// 单独一个小对象，只有分栏和世界的按钮看它：分栏视图排版时会回写这个值，写的和原来一样就不发通知——
/// 原来放在 KitelineModel 里，每次回写整个窗口都跟着重算、又触发回写，转了几百圈系统直接退出（10-27 崩过一次）
final class SidebarState: ObservableObject {
    static let shared = SidebarState()
    @Published private(set) var visibility: NavigationSplitViewVisibility = .doubleColumn

    var binding: Binding<NavigationSplitViewVisibility> {
        Binding(get: { self.visibility }, set: { value in if value != self.visibility { self.visibility = value } })
    }

    var collapsed: Bool { visibility == .detailOnly }
    func toggle() { visibility = collapsed ? .doubleColumn : .detailOnly }
    func show() { if collapsed { visibility = .doubleColumn } }
}

/// 界面状态中枢：AppState 有变化时刷新，SwiftUI 视图都观察它
final class KitelineModel: ObservableObject {
    static let shared = KitelineModel()
    /// 侧栏「今日动态」那一行的选中值
    static let todayID = "@today"
    static let historyID = "@history"
    static let usageID = "@usage"
    static let projectsID = "@projects"
    static let todosID = "@todos"
    static let favoritesID = "@favorites"

    @Published private(set) var sessions: [SessionItem] = []
    @Published private(set) var sources: [SourceItem] = []
    @Published private(set) var phoneClients = 0
    @Published private(set) var serverStatus = ""
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published var selection: String? {
        didSet {
            // 世界模式里点了左边栏顶上的入口（今日动态、待办……）：离开世界去那一页；点会话 = 世界里镜头飞过去（见 WorldView）
            if worldMode, let key = selection, key.hasPrefix("@") { worldMode = false }
            // 选中了会话（或群：同会话一样开成一个标签）：右边分屏里已经开着就切到那块，没开着就放进当前块（画右边之前先换好，不闪一下旧的）
            guard let key = selection, !key.hasPrefix("@") || key.hasPrefix("@group:"), key != oldValue else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { KitelineKit.panes.show(key) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { KitelineKit.panes.show(key) } }
            }
        }
    }
    @Published var query = ""
    /// 「新任务」面板；preset = 预先选中的项目（从某个会话的菜单里点进来）
    @Published var showNewTask = false
    /// 正在看哪个会话的 Agent 详情 / 哪台机器的设备详情（侧栏右键菜单、组头点开的，在窗口正中弹面板）
    @Published var agentDetail: String?
    @Published var machineDetail: String?
    /// 拉群面板要先勾上的会话（右键「拉群协作」的那个、拖到一起的两个）；nil = 面板没开
    @Published var groupSeed: [String]?
    /// 侧栏「会话群」页（历史群在这里）、某个群的选中值（@group:<群 id>，群同会话一样开在右边分屏的标签里）
    static let groupsID = "@groups"
    static func groupID(_ id: String) -> String { "@group:" + id }
    /// 世界模式：右边整块是像素世界（Sources/WorldView.swift）。记在偏好里，下次打开还是世界
    @Published private(set) var worldMode = AppConfig.defaults.bool(forKey: "worldMode") {
        didSet { AppConfig.defaults.set(worldMode, forKey: "worldMode") }
    }
    /// 世界里点了某人的屏幕：这个会话的对话页悬浮在世界上面（同主窗口右边的分屏会话页）
    @Published var worldDetail: String?
    /// 世界那块放哪一页：像素园区（world）还是数据流大屏（flow）；两页共用一个网页宿主（WorldHost）。记在偏好里
    @Published private(set) var worldPage = AppConfig.defaults.string(forKey: "worldPage") == "flow" ? "flow" : "world" {
        didSet { AppConfig.defaults.set(worldPage, forKey: "worldPage") }
    }

    /// 地球 / 数据流两个入口：没开就打开这一页；开着别的那页就切过来；开着的正是这页就离开
    func toggleWorld(page: String) {
        if worldMode && worldPage == page { setWorld(false) } else { setWorld(true, page: page) }
    }

    func setWorld(_ on: Bool, page: String? = nil) {
        if on, let page, page != worldPage {
            worldPage = page
            worldDetail = nil
            MainActor.assumeIsolated { WorldHost.shared.setPage(page) }   // 只在界面上点的时候调（主线程）
        }
        guard on != worldMode else { return }
        worldMode = on
        if !on {
            worldDetail = nil
            SidebarState.shared.show()   // 平时的界面没有收起侧栏的按钮：回来时展开
        }
    }
    var newTaskPreset: (sourceId: String, cwd: String)?

    func newTask(in item: SessionItem? = nil) {
        newTaskPreset = item.map { ($0.sourceId, $0.cwd) }
        showNewTask = true
    }

    func newTask(sourceId: String, cwd: String) {
        newTaskPreset = (sourceId, cwd)
        showNewTask = true
    }

    /// 菜单栏图标状态变化时通知 AppDelegate 重画
    var onGlyphChange: ((TarsGlyph.State) -> Void)?

    private init() {}

    var state: AppState { AppState.shared }

    func refresh() {
        let store = state.store
        let items = store.records.map(SessionItem.init(record:))
        if items != sessions { sessions = items }
        let summaries = state.sourceSummaries.map { pair -> SourceItem in
            var online = false
            var count = 0
            if case .live(_, _, let n) = pair.state { online = true; count = n }
            // 名字、状态是服务端拼的中文（也发给手机，在出口按手机的语言换）：Mac 自己显示时按界面语言换
            return SourceItem(id: pair.config.id, name: ServerLang.machine(pair.config.displayName), kind: pair.config.kind,
                              host: pair.config.sshHost, enabled: pair.config.enabled, online: online,
                              status: ServerLang.ui(pair.state.shortLabel), sessions: count)
        }
        if summaries != sources { sources = summaries }
        if phoneClients != state.mobile.clientCount { phoneClients = state.mobile.clientCount }
        if serverStatus != ServerLang.ui(state.mobile.statusText) { serverStatus = ServerLang.ui(state.mobile.statusText) }
        if accessibility != AXIsProcessTrusted() { accessibility = AXIsProcessTrusted() }
        if let selected = selection, !sessions.contains(where: { $0.id == selected }) {
            // 选中的会话结束了：保留选中（右侧显示「已结束」），不强行跳走
        }
        onGlyphChange?(glyphState)
    }

    // MARK: - 派生数据

    var filtered: [SessionItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.lowercased().contains(q) || $0.name.lowercased().contains(q)
                || $0.cwd.lowercased().contains(q) || $0.sourceName.lowercased().contains(q)
                || Agents.info($0.agent).name.lowercased().contains(q)
        }
    }

    /// 菜单栏面板按状态分区：某一类（标记的另在最上面一区，这里不含），置顶的、最近有动静的在前
    func sessions(_ activity: Activity) -> [SessionItem] {
        let marked = Set(state.config.mobile.markedSessions)
        let pinned = state.config.mobile.pinnedSessions
        func pin(_ s: SessionItem) -> Int { pinned.firstIndex(of: s.id) ?? Int.max }
        return filtered.filter { $0.activity == activity && !marked.contains($0.id) }
            .sorted {
                if pin($0) != pin($1) { return pin($0) < pin($1) }
                return ($0.updatedAt ?? 0) != ($1.updatedAt ?? 0) ? ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) : $0.id < $1.id
            }
    }

    /// 菜单栏面板最上面一区：标记的会话（按标记先后）
    var markedSessions: [SessionItem] {
        let marked = state.config.mobile.markedSessions
        return marked.compactMap { key in filtered.first { $0.id == key } }
    }

    /// 侧栏的会话（搜索过的），排法同手机（AppModel.sortedSessions）：标记的排最前（新标记的在上），然后是置顶的（按置顶顺序）；
    /// 其余按开始时间 / 最近活动 / 状态（待确认 → 出错 → 工作中 → 空闲）/ 名称排。
    /// 最后按 id 定死先后：一样的两个会话不会每次刷新互换位置
    func sortedSessions(_ order: String) -> [SessionItem] {
        let marked = state.config.mobile.markedSessions
        let pinned = state.config.mobile.pinnedSessions
        func mark(_ s: SessionItem) -> Int { marked.firstIndex(of: s.id) ?? Int.max }
        func pin(_ s: SessionItem) -> Int { pinned.firstIndex(of: s.id) ?? Int.max }
        func rank(_ s: SessionItem) -> Double {
            if s.failed { return 0.5 }
            return [Activity.waiting: 0, .busy: 1, .idle: 2][s.activity] ?? 3
        }
        return filtered.sorted {
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
            return $0.id < $1.id
        }
    }

    func isPinned(_ key: String) -> Bool { state.config.mobile.pinnedSessions.contains(key) }

    func isMarked(_ key: String) -> Bool { state.config.mobile.markedSessions.contains(key) }

    /// 标记 / 取消标记（列表、标签栏上的星星，右键菜单）
    func toggleMark(_ key: String) {
        state.setMarked(key, !isMarked(key))
        objectWillChange.send()
    }

    func togglePin(_ key: String) {
        let pinned = state.config.mobile.pinnedSessions.contains(key)
        state.updatePreferences { config in
            config.mobile.pinnedSessions.removeAll { $0 == key }
            if !pinned { config.mobile.pinnedSessions.insert(key, at: 0) }
        }
        objectWillChange.send()
        refresh()
    }

    func session(_ key: String?) -> SessionItem? {
        guard let key = key else { return nil }
        return sessions.first { $0.id == key }
    }

    var waitingCount: Int { sessions.filter { $0.activity == .waiting }.count }
    var busyCount: Int { sessions.filter { $0.activity == .busy }.count }
    var onlineSources: Int { sources.filter { $0.online }.count }

    var glyphState: TarsGlyph.State {
        if !sources.isEmpty && sources.allSatisfy({ !$0.online }) { return .offline }
        if waitingCount > 0 { return .waiting }
        if busyCount > 0 { return .busy }
        return .idle
    }

    /// 一句话总结：给菜单栏面板标题和提示用
    var summary: String {
        if !sources.isEmpty && onlineSources == 0 { return L("所有来源均离线") }
        var parts: [String] = []
        if waitingCount > 0 { parts.append(L("%lld 个待确认", count: waitingCount)) }
        if busyCount > 0 { parts.append(L("%lld 个进行中", count: busyCount)) }
        if parts.isEmpty { return sessions.isEmpty ? L("没有运行中的会话") : L("%lld 个会话，均处于空闲", count: sessions.count) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 动作

    func record(_ key: String) -> SessionRecord? { state.store.record(withKey: key) }

    func press(_ key: String, on sessionKey: String, completion: ((Delivery.Outcome) -> Void)? = nil) {
        guard let record = record(sessionKey) else { return }
        Delivery.press(key: key, record: record, source: state.source(withId: record.sourceId)) { outcome in
            completion?(outcome)
            if !outcome.ok { Self.alert(L("发送失败"), outcome.message) }
        }
    }

    /// 直接发一句话给 Claude 并提交（压缩上下文这类快捷操作）
    func send(_ text: String, to sessionKey: String) {
        guard let record = record(sessionKey) else { return }
        Delivery.send(text: text, attachments: [], to: record, source: state.source(withId: record.sourceId), submit: true) { outcome in
            if !outcome.ok { Self.alert(L("发送失败"), outcome.message) }
        }
    }

    /// 压缩上下文（/compact）：先确认，细节会被总结掉
    func compact(_ sessionKey: String) {
        let alert = NSAlert()
        alert.messageText = L("压缩此会话的上下文？")
        alert.informativeText = L("等同于在 Claude Code 中输入 /compact：此前的对话将被总结为摘要以释放上下文空间，部分细节可能丢失。")
        alert.addButton(withTitle: L("压缩"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("/compact", to: sessionKey)
    }

    func jump(_ sessionKey: String) {
        guard let record = record(sessionKey) else { return }
        state.jumpToWorkspace(for: record)
    }

    /// 关闭会话（先确认）：VS Code 里关掉它的标签页、终端里发 /exit，会话进「历史会话」，之后可以恢复
    func close(_ sessionKey: String) {
        guard let record = record(sessionKey) else { return }
        let alert = NSAlert()
        alert.messageText = L("关闭此会话？")
        let speaker = Agents.info(record.snapshot.agentID).speaker
        alert.informativeText = Delivery.viaAgent(record)
            ? L("将结束此 %@ 会话，并关闭或归档它在电脑上的窗口，正在进行的工作会中断。之后可在 %@ 中找回。", speaker, speaker)
            : record.snapshot.isVSCode
            ? L("将关闭此会话在 VS Code 中的标签页，Claude 随之结束此会话，正在进行的工作会中断。之后可在「历史会话」中恢复。")
            : L("将向终端中的 Claude 发送 /exit 结束此会话，正在进行的工作会中断。之后可在「历史会话」中恢复。")
        alert.addButton(withTitle: L("关闭会话"))
        alert.addButton(withTitle: L("取消"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Delivery.close(record: record, source: state.source(withId: record.sourceId)) { outcome in
            if !outcome.ok { Self.alert(L("无法关闭会话"), ServerLang.ui(outcome.message)) }
        }
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("好"))
        alert.runModal()
    }
}
