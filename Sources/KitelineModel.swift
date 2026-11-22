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
    /// 左边栏第二行：只说状态（待确认什么工具、正在用什么工具、可能停滞、出错、空闲），不放回复内容——
    /// 截短的两行回复看了等于没看（11-10），进度由前面的「2/4 开发中」标识说
    var status: String
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

    /// 状态短语：「待确认 · Bash」「正在运行 Bash」「可能停滞 12 分钟」「出错已停止」「空闲」
    private static func status(_ s: SessionSnapshot) -> String {
        if s.error != nil { return L("出错已停止") }
        /// 「Bash: S=/tmp/…」只取冒号前的工具名（太长就不要）
        func tool(_ text: String?) -> String? {
            guard let text else { return nil }
            let head = text.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return head.isEmpty || head.count > 24 ? nil : head
        }
        switch s.act {
        case .waiting: return tool(s.pendingTool).map { L("待确认 · %@", $0) } ?? L("待确认")
        case .busy:
            if let minutes = StuckWatch.quietMinutes(s, now: Date()) { return L("可能停滞：%@ 分钟无进展", "\(minutes)") }
            return tool(s.activityText).map { L("正在运行 %@", $0) } ?? L("正在工作…")
        default: return L("空闲")
        }
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
        status = Self.status(s)
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
    /// 那台电脑能后台运行 Claude Code（远端、watcher 支持）；开没开（按设备，见 Hosted）
    var hostedSupport = false
    var hostedOn = false
    /// 互联的 Kiteline 电脑上的来源：是哪台电脑（PeerComputers）
    var peerId: String? = nil
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

    /// 新版界面（11-20）：最左一条图标栏（会话、项目、待办、收藏……）+ 一栏内容，窗口底部一条状态栏，项目点进去看文件、Git、会话。
    /// 经典版（顶上几格入口 + 会话列表）原样留着，默认还是它，窗口右上角的按钮在两套之间换（用户：给个适应的过渡期）
    @Published var newLayout = AppConfig.defaults.bool(forKey: "newLayout") {
        didSet {
            guard newLayout != oldValue else { return }
            AppConfig.defaults.set(newLayout, forKey: "newLayout")
            // 经典版里没有左边栏的待办 / 项目 / 收藏：换回去时收起点开的项目；新版里这三样不占右边：从这三页换过来时右边回到会话
            projectShowsCode = false
            if !newLayout { projectPane = nil }
            if newLayout, [Self.todosID, Self.projectsID, Self.favoritesID].contains(selection ?? "") {
                let page = String((selection ?? "").dropFirst())
                selection = nil
                sideTab = page
            }
applyLayoutToPanes()
            // 两套界面的标题栏 + 工具栏一样高的前提不成立（经典版启动时量到的高度要大得多）：换完重新量一次，
            // 不然从经典版换到新版时左边栏顶上空出一大块（11-21 自测截图）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let window = NSApp.windows.first(where: { $0.frameAutosaveName == "TARSMainWindow" }) else { return }
                let band = window.frame.height - window.contentLayoutRect.maxY
                if band > 20, abs(band - TitlebarInset.band) > 0.5 { TitlebarInset.band = band }
                // 分栏重建一次：从经典版换过来时系统分栏（HSplitView）是在窗口还没量好时排的，侧栏被分得很宽、中间的标签页很窄
                //（11-21 截图）；重启后打开是正常的，换完量好再按重启时的方式排一遍
                self?.layoutEpoch += 1
            }
        }
    }

    /// 新版界面不在分屏标签栏顶上画会话组那一排（用户：上面的会话组不好用，去掉）；经典版照旧
    func applyLayoutToPanes() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.applyLayoutToPanes() }; return }
        let fresh = newLayout
        MainActor.assumeIsolated {
            KitelineKit.showTabGroupsInTitlebar(!fresh)
            // 新版界面每个项目一套标签：切进来时经典那套存起来，切回去放回
            KitelineKit.projectSpaces.setEnabled(fresh, project: projectPane ?? "", seed: [])
        }
        if fresh {
            if !ProjectsModel.shared.loaded { ProjectsModel.shared.load() }   // 认会话属于哪个项目要用到项目列表
            // 重开 App：中间显示的是上次那个项目的标签，项目栏也接上它
            let active = MainActor.assumeIsolated { KitelineKit.projectSpaces.active }
            if projectPane == nil, !active.isEmpty {
                inSpaceSwitch = true
                projectPane = active
                inSpaceSwitch = false
            }
        }
    }

    /// 新版界面左边栏那一栏现在列的是什么：sessions 会话 / todos 待办 / projects 项目 / favorites 收藏（图标栏上点的）。
    /// 记在偏好里，下次打开还是这一页
    static let sideTabs = ["sessions", "todos", "projects", "favorites"]
    @Published var sideTab: String = {
        let saved = AppConfig.defaults.string(forKey: "sideTab") ?? ""
        return KitelineModel.sideTabs.contains(saved) ? saved : "sessions"
    }() {
        didSet { if sideTab != oldValue { AppConfig.defaults.set(sideTab, forKey: "sideTab") } }
    }

    /// 新版界面：切到左边栏的某一栏（图标栏上点的，对话里点「待办」「收藏」、菜单、通知跳过来的）：世界模式里先回到平时的界面，侧栏收着就展开
    func showSideTab(_ tab: String) {
        guard Self.sideTabs.contains(tab) else { return }
        if worldMode { setWorld(false) }
        SidebarState.shared.show()
        if !query.isEmpty { query = "" }   // 搜索时列的是会话，页签看不见
        if sideTab != tab { sideTab = tab }
    }

    /// 新版界面的当前项目（项目合成一项后的 id）：项目栏显示它的会话、文件；中间的标签是它那一套（ProjectSpaces，切项目整套换，
    /// 11-20 反馈：A 项目下不要出现 B 项目的会话）。nil = 没选项目（「全部」那一套）
    @Published var projectPane: String? {
        didSet { if projectPane != oldValue, newLayout { switchSpace() } }
    }
    /// 「项目」一栏现在列的是项目列表（点了「‹」回列表时；当前项目不变，中间的标签不动）
    @Published var projectListShown = false
    /// 切项目时要显示的会话（从「选了别的项目的会话」来的）
    private var spaceFocus: String?
    private var inSpaceSwitch = false

    /// 中间的标签整套换成当前项目那一套；那个项目第一次打开：放它最近有动静的会话
    private func switchSpace() {
        let id = projectPane ?? ""
        let projects = ProjectsModel.shared
        let live = id.isEmpty ? [] : projects.live(group: projects.members(id)).sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }.map(\.id)
        let seed = spaceFocus.map { [$0] } ?? Array(live.prefix(1))
        inSpaceSwitch = true
        MainActor.assumeIsolated {
            KitelineKit.projectSpaces.activate(id, seed: seed)
            if let focus = spaceFocus { KitelineKit.panes.show(focus) }
        }
        let focused = MainActor.assumeIsolated { KitelineKit.panes.focused }
        if selection != focused { selection = focused }
        spaceFocus = nil
        inSpaceSwitch = false
        if !id.isEmpty { MainActor.assumeIsolated { ProjectStripState.shared.reopen(id) } }
    }

    /// 一个标签 / 会话属于哪个项目（项目合成一项后的 id）；群、认不出的回 nil
    func projectID(of key: String) -> String? {
        if key.hasPrefix("@group:") { return nil }
        let projects = ProjectsModel.shared
        if key.hasPrefix(NewDraftKey.prefix) {
            return NewDraftKey.parse(key).map { projects.groupID(ProjectsModel.id(sourceId: $0.sourceId, cwd: $0.cwd)) }
        }
        let sessionKey = MainActor.assumeIsolated { KitelineKit.codeTabSession(key) } ?? key
        if let item = session(sessionKey) { return projects.groupID(ProjectsModel.id(sourceId: item.sourceId, cwd: item.cwd)) }
        if let past = HistoryModel.shared.past(sessionKey) { return projects.groupID(ProjectsModel.id(sourceId: past.sourceId, cwd: past.cwd)) }
        return nil
    }
    /// 二级侧边栏开着时右边显示的是代码（点了文件、改动、提交历史）还是会话
    @Published var projectShowsCode = false

    /// 点项目：没开就打开它的二级侧边栏，开着的正是它就收起
    func toggleProject(_ id: String) {
        projectShowsCode = false
        if newLayout { openProject(id); return }   // 新版：点项目就是切到它（列表里选中、中间的标签和会话列表跟着换）
        projectPane = projectPane == id ? nil : id
    }

    /// 「打开项目」面板（左边栏「项目」页签里的「打开」：选电脑和文件夹、选 Agent，直接打开）
    @Published var showOpenProject = false

    /// 新版界面的布局（11-20 反馈：所有板块都能拖，左右、上下随便组合）：从左到右几栏，每栏从上到下几块。
    /// 块：nav 导航栏（图标栏 + 列表）、sessions 项目的会话列表、files 文件侧栏、tabs 标签页区域（会话、文件开成的标签）。
    /// 状态栏单独：放窗口顶部还是底部。存在 AppConfig.defaults 的 layoutColumns（「nav,sessions|tabs|files」这样一串）
    static let layoutBlocks = ["nav", "sessions", "files", "tabs"]
    static let defaultColumns: [[String]] = [["nav", "sessions"], ["tabs"], ["files"]]
    @Published var layoutColumns: [[String]] = KitelineModel.parseColumns(AppConfig.defaults.string(forKey: "layoutColumns")) {
        didSet { AppConfig.defaults.set(layoutColumns.map { $0.joined(separator: ",") }.joined(separator: "|"), forKey: "layoutColumns") }
    }
    @Published var statusOnTop = AppConfig.defaults.bool(forKey: "layoutStatusTop") {
        didSet { AppConfig.defaults.set(statusOnTop, forKey: "layoutStatusTop") }
    }

    /// 读回存的布局：认不得的块丢掉、缺的块补到合适的地方（导航栏放最左、标签页区域单独一栏、会话列表和文件侧栏跟在导航栏下面），空栏去掉
    static func parseColumns(_ raw: String?) -> [[String]] {
        guard let raw, !raw.isEmpty else { return defaultColumns }
        var seen = Set<String>()
        var columns = raw.split(separator: "|").map { col in
            col.split(separator: ",").map(String.init).filter { layoutBlocks.contains($0) && seen.insert($0).inserted }
        }.filter { !$0.isEmpty }
        for block in layoutBlocks where !seen.contains(block) {
            switch block {
            case "nav": columns.insert(["nav"], at: 0)
            case "tabs": columns.append(["tabs"])
            default: if columns.isEmpty { columns.append([block]) } else { columns[0].append(block) }
            }
        }
        return columns
    }

    /// 切到新版界面时弹不弹布局设置（弹窗里勾「下次不再询问」就不弹了；图标栏上的「布局」随时能再打开）
    var askLayoutOnSwitch: Bool {
        get { AppConfig.defaults.object(forKey: "layoutAskOnSwitch") as? Bool ?? true }
        set { AppConfig.defaults.set(newValue, forKey: "layoutAskOnSwitch") }
    }
    /// 布局设置弹窗
    @Published var showLayoutSetup = false

    /// 打开某个项目的二级侧边栏（「打开项目」开好之后）：左边栏切到「项目」
    func openProject(_ id: String, showList: Bool = true) {
        if showList { showSideTab("projects") }
        projectShowsCode = false
        projectListShown = false
        projectPane = ProjectsModel.shared.groupID(id)   // 几台设备上的同一个项目合成一项，按那一项的 id 记
    }

    @Published private(set) var sessions: [SessionItem] = []
    @Published private(set) var sources: [SourceItem] = []
    @Published private(set) var phoneClients = 0
    @Published private(set) var serverStatus = ""
    @Published private(set) var accessibility = AXIsProcessTrusted()
    /// 换界面后让新版界面的分栏重建（见 newLayout 的 didSet）
    @Published var layoutEpoch = 0

    /// 新版界面里弹窗显示的整页（今日动态 / 用量的 id），nil = 没开
    @Published var popupPage: String?

    @Published var selection: String? {
        didSet {
            // 新版界面（11-21）：今日动态、用量弹窗显示，不占中间的标签页区域；历史会话不单独成页（项目里有），去项目栏。经典版照旧
            if newLayout, let key = selection, [Self.todayID, Self.usageID, Self.historyID].contains(key) {
                selection = oldValue
                if key == Self.historyID { showSideTab("projects") } else { popupPage = key }
                return
            }
            // 世界模式里点了左边栏顶上的入口（今日动态、待办……）：离开世界去那一页；点会话 = 世界里镜头飞过去（见 WorldView）
            if worldMode, let key = selection, key.hasPrefix("@") { worldMode = false }
            // 二级侧边栏开着、右边正看着代码时选了会话（哪怕就是原来那个）：右边回到会话
            if projectShowsCode, selection != nil { projectShowsCode = false }
            // 选中了会话（或群：同会话一样开成一个标签）：右边分屏里已经开着就切到那块，没开着就放进当前块（画右边之前先换好，不闪一下旧的）
            // 代码标签（@code:…，文件、对比、历史）也一样开在分屏里
            guard let key = selection, !key.hasPrefix("@") || key.hasPrefix("@group:") || key.hasPrefix("@code:") || key.hasPrefix("@new:"),
                  key != oldValue else { return }
            // 新版界面选中了别的项目的会话（左边全部会话里点的、通知跳过来的……）：先切到那个项目（中间的标签整套换），再显示它
            if newLayout, !inSpaceSwitch, projectPane != nil, let project = projectID(of: key), project != projectPane {
                spaceFocus = key
                projectPane = project
                return
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { KitelineKit.panes.show(key) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { KitelineKit.panes.show(key) } }
            }
        }
    }
    /// 左边栏里点了一行会话（或群、历史会话）：没开着的照旧开成标签；已经开成标签的不再开，切到那个标签，
    /// 它的边框闪几下主题色（11-20 反馈：已打开的再点一次不要再开标签，对应的标签边框闪主题色）
    func pick(_ key: String) {
        // AR 模式里（小球展开的侧栏）点了会话：镜头运过去、打开那个窗口
        if arMode, !key.hasPrefix("@") { MainActor.assumeIsolated { ARMode.shared.focus(key) } }
        let opened = MainActor.assumeIsolated { KitelineKit.panes.openKeys.contains(key) }
        selection = key
        guard opened else { return }
        MainActor.assumeIsolated {
            KitelineKit.panes.show(key)   // 选中的没变（再点的就是当前这个）时上面不会切，这里补上
            KitelineKit.panes.flashTab(key)
        }
    }

    @Published var query = ""
    /// 「新任务」面板；preset = 预先选中的项目（从某个会话的菜单里点进来）
    @Published var showNewTask = false
    /// 批量重启会话的面板（会话「⋯」、菜单栏「会话」里的「批量重启会话…」）
    @Published var showBatchRestart = false
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

    /// AR 模式：主窗口收起，所有会话漂在透明的屏幕空间里（Sources/ARMode.swift）。不记偏好：下次打开 App 还是平时的窗口
    @Published var arMode = false

    func toggleAR() {
        MainActor.assumeIsolated { ARMode.shared.toggle() }   // 只在界面上点、菜单里按的时候调（主线程）
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

    /// 从提示词链接来的：提示词先填好、链接里的项目对得上就选中（NewTaskSheet 打开时取走）
    var newTaskLink: PromptLink?
    /// 从「发送到会话」面板选了「新建会话」来的：文字、图、文件先放进去（NewTaskSheet 打开时取走）
    var newTaskShare: (text: String, images: [TarsTaskImage], files: [NewTaskSheet.SharedFile])?

    /// 系统共享菜单发来的、还没被「发送到会话」面板取走的（见 ShareInbox.swift）
    @Published var sharedPayload: SharedPayload?
    @Published var showShare = false

    func receiveShare(_ payload: SharedPayload) {
        sharedPayload = payload
        showShare = true
    }

    func newTask(share: (text: String, images: [TarsTaskImage], files: [NewTaskSheet.SharedFile])) {
        newTaskPreset = nil
        newTaskLink = nil
        newTaskShare = share
        // 先收起「发送到会话」面板，再弹「新任务」（两个面板同时弹会叠在一起）
        showShare = false
        if showNewTask { showNewTask = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.showNewTask = true }
    }

    func newTask(link: PromptLink) {
        newTaskPreset = nil
        newTaskLink = link
        if showNewTask {
            // 面板已经开着：关了重开，带上新链接
            showNewTask = false
            DispatchQueue.main.async { self.showNewTask = true }
        } else {
            showNewTask = true
        }
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
                              status: ServerLang.ui(pair.state.shortLabel), sessions: count,
                              hostedSupport: Hosted.capable(pair.config), hostedOn: Hosted.on(pair.config.id),
                              peerId: pair.config.peerId)
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

    /// 一组会话按最近活动排（项目栏「正在运行」）：标记的最前，然后置顶的，其余最近有动静的在上，同时间按 id 定死
    func recentFirst(_ list: [SessionItem]) -> [SessionItem] {
        let marked = state.config.mobile.markedSessions
        let pinned = state.config.mobile.pinnedSessions
        func mark(_ s: SessionItem) -> Int { marked.firstIndex(of: s.id) ?? Int.max }
        func pin(_ s: SessionItem) -> Int { pinned.firstIndex(of: s.id) ?? Int.max }
        return list.sorted {
            if mark($0) != mark($1) { return mark($0) < mark($1) }
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
    /// 重启会话（单个或批量，见 SessionRestart）：做完在窗口底部提示一句
    func restart(_ keys: [String]) {
        SessionRestart.shared.restart(keys: keys) { result in
            var parts: [String] = []
            if !result.restarted.isEmpty { parts.append(L("正在重启 %d 个会话", result.restarted.count)) }
            if !result.queued.isEmpty { parts.append(L("%d 个正在工作，这一轮做完后自动重启", result.queued.count)) }
            if let first = result.failed.first { parts.append(L("%d 个未能重启：%@", result.failed.count, first.error)) }
            MainActor.assumeIsolated { KitelineKit.flash(parts.joined(separator: L("；"))) }
        }
    }

    /// 关闭确认框里那句说明（关了会怎样）；会话已不在时为空
    func closeNote(_ sessionKey: String) -> String? {
        guard let record = record(sessionKey) else { return nil }
        let speaker = Agents.info(record.snapshot.agentID).speaker
        return Delivery.viaAgent(record)
            ? L("将结束此 %@ 会话，并关闭或归档它在电脑上的窗口，正在进行的工作会中断。之后可在 %@ 中找回。", speaker, speaker)
            : record.snapshot.isVSCode
            ? L("将关闭此会话在 VS Code 中的标签页，Claude 随之结束此会话，正在进行的工作会中断。之后可在「历史会话」中恢复。")
            : L("将向终端中的 Claude 发送 /exit 结束此会话，正在进行的工作会中断。之后可在「历史会话」中恢复。")
    }

    /// confirmed：调用方已经确认过（会话卡片上的「×」在按钮旁弹气泡确认，见 CloseConfirm），不再弹框
    func close(_ sessionKey: String, confirmed: Bool = false) {
        guard let record = record(sessionKey), let note = closeNote(sessionKey) else { return }
        if !confirmed {
            let alert = NSAlert()
            alert.messageText = L("关闭此会话？")
            alert.informativeText = note
            alert.addButton(withTitle: L("关闭会话"))
            alert.addButton(withTitle: L("取消"))
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
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
