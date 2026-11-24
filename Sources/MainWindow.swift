import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KitelineKit

/// Kiteline 主窗口：左边会话列表，右边完整对话。
/// 关掉主窗口后 App 继续留在菜单栏；主窗口开着时出现在 Dock 和 ⌘Tab 里。
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController()

    private init() {
        // 先连上对话页用的服务再建界面：上次的分屏一打开就要画（TarsPanesView 不会因为后来连上而重画，会一直转圈）
        NativeConversation.setUp()
        let hosting = NSHostingController(rootView: MainView().tarsLook())
        // 让 SwiftUI 的 toolbar / 标题直接用在 NSWindow 上（统一工具栏，macOS 26 起是液态玻璃）
        if #available(macOS 14, *) { hosting.sceneBridgingOptions = [.toolbars, .title] }
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Kiteline"
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("TARSMainWindow")
        super.init(window: window)
        window.delegate = self
        // 新版界面各栏让出标题栏用的高度（TitlebarInset 不能自己来问 shared，见那里）
        let band = window.frame.height - window.contentLayoutRect.maxY
        if band > 20 { TitlebarInset.band = band }
        // 窗口顶上飞的纸鸢（透明子窗口，窗口出现时自动挂上）
        KiteOverlay.shared.attach(to: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(select key: String? = nil) {
        NativeConversation.setUp()
        if let key = key { KitelineModel.shared.selection = key }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        // 没有其他窗口开着就退回纯菜单栏模式（不占 Dock）
        DispatchQueue.main.async {
            if !SettingsWindowController.shared.isVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - 主视图

struct MainView: KLView {
    @ObservedObject var model = KitelineModel.shared
    @ObservedObject private var sidebar = SidebarState.shared

    var klBody: some View {
        // 两套界面并存（11-20 反馈：现在的界面保留，右上角可以切到新版，给个适应的过渡期）：
        // 经典版 = SidebarView（顶上几格入口 + 会话列表）；新版 = RailSidebar（最左一条图标栏 + 一栏内容）加窗口底部的状态栏（NewLayout.swift）
        root(model.newLayout)
    }

    /// 新版界面不用系统的分栏（它的侧栏只能在最左边）：几栏几块由用户摆（NewLayoutRoot）；经典版照旧
    @ViewBuilder private func root(_ fresh: Bool) -> some View {
        if fresh {
            NewLayoutRoot(model: model).modifier(MainChrome(model: model))
        } else {
            split(false).modifier(MainChrome(model: model))
        }
    }

    #if KL_MODERN
    private func split(_ fresh: Bool) -> some View {
        NavigationSplitView(columnVisibility: sidebar.binding) {
            Group {
                if fresh { RailSidebar(model: model) } else { SidebarView(model: model) }
            }
            .modifier(SidebarChrome(model: model))
            .navigationSplitViewColumnWidth(min: fresh ? 290 : 260, ideal: fresh ? 330 : 300, max: fresh ? 450 : 400)
        } detail: {
            ProjectSplit(model: model)
                // 窗口右上角的界面切换按钮：不放工具栏，挂在右边这一栏上（挂在外层会被系统的分栏视图盖住），见 LayoutSwitchCorner
                .overlay(alignment: .topTrailing) { LayoutSwitchCorner(model: model) }
                // 装了带新版界面的版本：右上角按钮下面提示一次（NewLayoutTour.swift）
                .overlay(alignment: .topTrailing) { NewLayoutAnnouncement() }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "搜索会话")
    }
    #else
    @ViewBuilder
    private func split(_ fresh: Bool) -> some View {
        if #available(macOS 13, *) {
            NavigationSplitView(columnVisibility: sidebar.binding) {
                sidebarColumn(fresh)
                    .navigationSplitViewColumnWidth(min: fresh ? 290 : 260, ideal: fresh ? 330 : 300, max: fresh ? 450 : 400)
            } detail: {
                detailColumn
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: "搜索会话")
        } else {
            // macOS 12 没有 NavigationSplitView：NavigationView 的两栏（侧栏能用系统的按钮收起）
            NavigationView {
                sidebarColumn(fresh)
                    .frame(minWidth: fresh ? 290 : 260, idealWidth: fresh ? 330 : 300, maxWidth: fresh ? 450 : 400)
                detailColumn
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: "搜索会话")
        }
    }
    #endif

    private func sidebarColumn(_ fresh: Bool) -> some View {
        Group {
            if fresh { RailSidebar(model: model) } else { SidebarView(model: model) }
        }
        .modifier(SidebarChrome(model: model))
    }

    private var detailColumn: some View {
        ProjectSplit(model: model)
            // 窗口右上角的界面切换按钮：不放工具栏，挂在右边这一栏上（挂在外层会被系统的分栏视图盖住），见 LayoutSwitchCorner
            .overlay(alignment: .topTrailing) { LayoutSwitchCorner(model: model) }
            // 装了带新版界面的版本：右上角按钮下面提示一次（NewLayoutTour.swift）
            .overlay(alignment: .topTrailing) { NewLayoutAnnouncement() }
    }
}

/// 窗口右上角的「新版界面 / 经典界面」切换：浮在内容最上面工具栏那一带，样子同工具栏按钮（玻璃胶囊，高 36，在那一带里上下居中）。
/// 不放进窗口工具栏：放进去要在前面垫一个弹性空位才推得到最右边，而这个空位在工具栏里是一整块横跨右侧的视图，
/// 分屏标签栏铺进工具栏那一带时，标签上的 ×、「+」按下去被它接走、没有反应（11-20 反馈：经典界面关不掉标签、新增列点了没反应；
/// 有会话组时标签行被顶上那排组标签压低，整行落在它上面，最明显）。标签栏右边按这个按钮实际多宽让位。
/// 用法：`.overlay(alignment: .topTrailing) { LayoutSwitchCorner(model:) }` 挂在贴着窗口右上角的那一栏自己身上——
/// 两套界面的分栏都是系统的分栏视图（NSSplitView），挂在窗口最外层的浮层会被它盖住，看不见也点不着
struct LayoutSwitchCorner: KLView {
    @ObservedObject var model: KitelineModel
    /// 按钮底下是标签栏（要让位）。新版界面最右一栏是文件侧栏这类时按钮落在那一栏上方，标签栏不用让（keyuanchuangmei-56 发现多让了 112）
    var overTabs = true
    @State private var hovering = false
    @State private var width: CGFloat = 0

    var klBody: some View {
        LayoutSwitch(model: model)
            .buttonStyle(CornerButtonStyle(hovering: hovering))
            .tourAnchor("layoutSwitch")
            .onHover { hovering = $0 }
            // 右上角那一块标签栏让出：按钮宽 + 右边 6 + 和标签栏按钮之间留 8（中英文字数不同，按实际宽度）
            .klOnGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0; reserve() }
            .klOnChange(of: overTabs) { reserve() }
            .frame(height: TitlebarInset.band)   // 在标题栏 + 工具栏那一带里上下居中，同工具栏上的按钮
            .padding(.trailing, 6)
            .ignoresSafeArea(.container, edges: .top)
    }

    private func reserve() { KitelineKit.reserveTitlebarTrailing(overTabs ? ceil(width) + 14 : 0) }

    private struct CornerButtonStyle: ButtonStyle {
        var hovering: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 13))
                .imageScale(.large)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0)))
                .contentShape(Capsule())
                .tarsGlass(cornerRadius: 18)
        }
    }
}

/// 主窗口两套界面共用的：纸鸢、浏览器、翻译宿主、各种面板
struct MainChrome: KLViewModifier {
    @ObservedObject var model: KitelineModel

    func klBody(content: Content) -> some View {
        content
        // 会话之间互发消息：纸鸢从发信会话飞到收信会话（开在分屏里时在标签之间飞），侧栏左边的风筝线连起最近有往来的会话
        .overlay { KitelineKit.PeerStageView(order: model.filtered.map(\.id)) }
        // 会话浏览器放到「整个应用 / 全屏」：盖满整个窗口
        .overlay { KitelineKit.BrowserAppView() }
        // 系统翻译的常驻宿主（看不见）：对话里所有消息的系统翻译排队交给它
        .background { TranslateAppleHost() }
        .frame(minWidth: 820, minHeight: 520)
        .sheetPanel(isPresented: $model.showNewTask) { NewTaskSheet() }
        .sheetPanel(isPresented: $model.showShare) { ShareSheet() }   // 系统共享菜单发来的：发送到会话（ShareInbox.swift）
        .sheetPanel(isPresented: $model.showBatchRestart) { KitelineKit.BatchRestartView() }   // 能拖动、改大小的面板，在窗口正中
        .sheetPanel(isPresented: $model.showOpenProject) { OpenProjectSheet() }
        .sheetPanel(isPresented: $model.showLayoutSetup) { LayoutSetupSheet() }
        // 新版界面：今日动态、用量开成能拖动、改大小的弹窗（见 KitelineModel.selection）
        .sheetPanel(isPresented: Binding(get: { model.popupPage != nil }, set: { if !$0 { model.popupPage = nil } })) {
            Group {
                if model.popupPage == KitelineModel.todayID { TodayView() } else { UsageReportView() }
            }
            .frame(minWidth: 760, idealWidth: 960, maxWidth: .infinity, minHeight: 520, idealHeight: 760, maxHeight: .infinity)
        }
        .sheetPanel(isPresented: Binding(get: { model.agentDetail != nil }, set: { if !$0 { model.agentDetail = nil } })) {
            if let key = model.agentDetail { TarsAgentInfoView(key: key) }
        }
        .sheetPanel(isPresented: Binding(get: { model.machineDetail != nil }, set: { if !$0 { model.machineDetail = nil } })) {
            if let source = model.machineDetail { TarsMachineInfoView(sourceId: source) }
        }
        // 拉群：右键「拉群协作」、把一个会话拖到另一个上；建好打开群聊页
        .sheetPanel(isPresented: Binding(get: { model.groupSeed != nil }, set: { if !$0 { model.groupSeed = nil } })) {
            if let keys = model.groupSeed { TarsGroupPicker(keys: keys) { id in model.selection = KitelineModel.groupID(id) } }
        }
        // 新建标签组面板（⌃⌘N、会话右键「新建标签组」）
        .modifier(TarsTabGroupPickerHost())
        .tint(.tarsBrand)   // 选中、开关、链接都用品牌橙，不跟系统的强调色（默认蓝）
    }
}

// MARK: - 侧栏

struct SidebarView: KLView {
    @ObservedObject var model: KitelineModel
    /// 新版界面里当「会话」那一栏用：不带顶上几格入口和底栏（入口在图标栏上，来源、手机数在窗口底部的状态栏里）
    var embedded = false
    /// 分组、排序、筛选（同手机，存的键也一样）：分组 none / source / project；排序 started / recent / status / name；
    /// 状态 all / busy / waiting / error；设备 = 来源 id（空 = 全部设备）；项目 = 项目名（目录最后一级；空 = 全部项目）
    @AppStorage("listGrouping") private var grouping = "none"
    @AppStorage("listSorting") private var sorting = "started"
    @AppStorage("listFilter") private var statusFilter = "all"
    @AppStorage("listSource") private var sourceFilter = ""
    @AppStorage("listProject") private var projectFilter = ""
    /// 左边栏现在看的页签：sessions 会话 / groups 群
    @AppStorage("listTab") private var listTab = "sessions"
    /// 设备、项目两排胶囊展开着（平时收成一行，只写着选的是哪个）
    @State private var scopeOpen = false

    /// 这台电脑支持会话群，才有「群」页签
    private var groupsOn: Bool { KitelineKit.groupsSupported }

    /// 现在看的页签（存的是「群」但这台电脑不支持群时回到「会话」）
    private var currentTab: String {
        switch listTab {
        case "groups" where groupsOn, "tabgroups": return listTab
        default: return "sessions"
        }
    }

    var klBody: some View {
        // 先按设备、项目，再按状态筛（搜索词在 model.filtered 里已经筛过），最后分组
        let base = scoped(model.sortedSessions(sorting))
        let shown = base.filter { matches($0, status) }
        // 不用列表自带的选中（见 SidebarRowHighlight），选中靠 model.selection
        List {
            if model.query.isEmpty, !embedded {
                SidebarTiles(model: model).klSelectionDisabled()
            }
            // 「会话」「群」「标签组」三个页签（11-10 起分开）：状态 / 设备 / 项目筛选和「显示方式」只在「会话」里，
            // 「建群」在「群」里，「新建标签组」在「标签组」里。搜索时不分页签：会话和名字对得上的群一起列，免得搜群名还要先切过去
            let searching = !model.query.isEmpty
            let tab = searching ? "sessions" : currentTab
            let groupsTab = tab == "groups"
            let allGroups = TarsGroupFilter(keys: nil, markedOnly: false, query: "")
            // 改版说明（看过一次就不再出）：会话列表去哪了、会话 / 群 / 会话组有什么不同
            if !searching {
                ListTabsGuide(groups: groupsOn) { withAnimation(.klSnappy) { listTab = "tabgroups" } }
                    .padding(.top, 8)
                    .klSelectionDisabled()
            }
            controls(base, count: shown.count, tab: tab).klSelectionDisabled()
            if tab == "tabgroups" {
                // 标签组：一个阶段的几个会话一组，切到哪组右边就多列显示哪组（KitelineKit/Views/TabGroups.swift）
                TarsTabGroupSection(headerless: true).klSelectionDisabled()
            } else if groupsTab {
                if !KitelineKit.groupSectionShown(allGroups) {
                    Label("还没有会话群。点「建群」，或把一个会话拖到另一个会话上，让它们互相沟通。", systemImage: "person.2")
                        .font(.app(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)   // 侧栏列表默认只排一行，这里要看全
                        .klSelectionDisabled()
                }
                TarsGroupSidebarSection(selection: $model.selection, filter: allGroups, headerless: true).klSelectionDisabled()
            } else if model.sessions.isEmpty {
                Label("没有运行中的会话。在 VS Code 中打开 Claude Code，或在终端运行 claude。", systemImage: "moon.stars")
                    .font(.app(size: 11.5)).foregroundStyle(.secondary)
                    .klSelectionDisabled()
                if searching { TarsGroupSidebarSection(selection: $model.selection, filter: groupFilter(shown)).klSelectionDisabled() }
            } else {
                // 搜索时（或这台电脑不支持群、没有「群」页签时）群还列在会话前面
                let groupScope = groupFilter(shown)
                let mixed = searching || !groupsOn
                if mixed { TarsGroupSidebarSection(selection: $model.selection, filter: groupScope).klSelectionDisabled() }
                let headed = mixed && KitelineKit.groupSectionShown(groupScope)
                ForEach(groups(shown), id: \.key) { group in
                    if let name = group.name ?? (headed ? L("会话") : nil) {
                        Section {
                            rows(group.items)
                        } header: {
                            // 排一行（同手机）：组名、机器名，机器名右边是这台机器的 CPU、内存；放不下时截短组名
                            HStack(spacing: 6) {
                                if group.marked { Image(systemName: "star.fill").foregroundStyle(Color.tarsBrand) }
                                if let agent = group.agent { AgentGlyph(agent, size: 12) }
                                Text(name).lineLimit(1).layoutPriority(embedded ? 1 : 0)   // 窄时先缩 CPU、内存，别把设备名挤没
                                if let sub = group.sub { Text(sub).foregroundStyle(.tertiary).lineLimit(1).fixedSize() }
                                if let source = group.source {
                                    // 点 CPU、内存看这台机器的设备详情（同手机）
                                    Button { model.machineDetail = source } label: {
                                        KitelineKit.MachineStatsRow(sourceId: source).font(.app(size: 10.5)).klFontWeight(.regular).padding(.leading, 2)
                                    }
                                    .buttonStyle(.plain)
                                    .help(L("设备详情"))
                                }
                                Spacer(minLength: 4)
                                Text("\(group.items.count)").monospacedDigit().foregroundStyle(.tertiary)
                            }
                            // 新版界面：节标题左边系统给了 14、右边几乎贴边（11-21 量过），对到侧栏的 16 点对齐线
                            .padding(.leading, embedded ? 2 : 0).padding(.trailing, embedded ? 12 : 0)
                        }
                    } else {
                        rows(group.items)
                    }
                }
                // 筛得一个不剩（搜索没搜到的另有提示）
                if shown.isEmpty, !(model.query.isEmpty == false && model.filtered.isEmpty) { emptyFilter }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.filtered.isEmpty && !model.query.isEmpty {
                KLUnavailableView("没有匹配的会话", systemImage: "magnifyingglass")
            }
        }
        .safeAreaInset(edge: .bottom) { if !embedded { SidebarFooter(model: model) } }
    }

    private func rows(_ items: [SessionItem]) -> some View {
        ForEach(items) { item in
            SessionRow(item: item, pinned: model.isPinned(item.id), marked: model.isMarked(item.id),
                       onMark: { withAnimation(.klSnappy) { model.toggleMark(item.id) } },
                       onClose: item.canReply && item.can("close") ? { model.close(item.id, confirmed: true) } : nil, avatar: !embedded)
                .modifier(SidebarRowHighlight(selected: model.selection == item.id) { model.pick(item.id) })
                // 新版界面：系统侧栏列表每边自带 16 点，行的框要离栏边 8（侧栏规范 SideMetric），减回去
                .listRowInsets(embedded ? EdgeInsets(top: 1, leading: SideMetric.edge - 16, bottom: 1, trailing: SideMetric.edge - 16) : nil)
                .sessionDraggable(item)
                // 把另一个会话拖到这一行上松开：拉这两个会话建群
                .tarsGroupDrop(key: item.id) { dragged in model.groupSeed = [dragged, item.id] }
                .contextMenu { SessionMenu(model: model, item: item) }
        }
    }

    /// 「会话群」一组跟着会话的筛选走：筛着设备、项目、状态或在搜索时，只留有成员在筛出来的会话里的群
    private func groupFilter(_ shown: [SessionItem]) -> TarsGroupFilter {
        let filtering = isFiltering || !model.query.isEmpty
        return TarsGroupFilter(keys: filtering && status != "marked" ? Set(shown.map(\.id)) : nil, markedOnly: status == "marked", query: model.query)
    }

    // MARK: 分组、排序、筛选（同手机首页）

    private static var groupOptions: [(String, String)] { [("none", L("不分组")), ("source", L("按来源")), ("project", L("按项目")), ("agent", L("按 Agent"))] }
    private static var sortOptions: [(String, String)] { [("started", L("开始时间")), ("recent", L("最近活动")), ("status", L("状态优先")), ("name", L("名称"))] }

    private struct StatusOption {
        let id: String
        let title: String
        let color: Color?
    }

    private static var statusOptions: [StatusOption] { [
        StatusOption(id: "all", title: L("全部"), color: nil),
        // 标记的会话（主题色星星）：多任务时找得到暂停、等着的会话（10-27 起放在「工作中」左边）
        StatusOption(id: "marked", title: L("标记"), color: .tarsBrand),
        StatusOption(id: "busy", title: L("工作中"), color: .tarsBrand),
        StatusOption(id: "waiting", title: L("待确认"), color: .tarsOrange),
        StatusOption(id: "error", title: L("出错"), color: .red),
    ] }

    /// 当前的状态筛选（手机上才有的「新消息」等不认识的值当「全部」）
    private var status: String { Self.statusOptions.contains { $0.id == statusFilter } ? statusFilter : "all" }

    /// 筛着的那台机器（机器已经不在了就当没筛）
    private var activeSource: SourceItem? {
        sourceFilter.isEmpty ? nil : model.sources.first { $0.id == sourceFilter }
    }

    /// 分组、排序都是默认的
    private var isDefaultView: Bool { effectiveGrouping == "none" && sorting == "started" }

    /// 选了某个项目时按项目、按来源分都只剩一组：不分组（项目选「全部」时才有「按项目」这些分组）
    private var effectiveGrouping: String { activeProject == nil ? grouping : "none" }

    /// 筛着的那个项目（运行中的会话里已经没有它就当没筛）
    private var activeProject: String? {
        projectFilter.isEmpty || !model.sessions.contains(where: { $0.folder == projectFilter }) ? nil : projectFilter
    }

    private var isFiltering: Bool { status != "all" || activeSource != nil || activeProject != nil }

    private func clearFilters() {
        statusFilter = "all"
        sourceFilter = ""
        projectFilter = ""
    }

    private func matches(_ item: SessionItem, _ filter: String) -> Bool {
        switch filter {
        case "marked": return model.isMarked(item.id)
        case "busy": return item.activity == .busy
        case "waiting": return item.activity == .waiting
        case "error": return item.failed
        default: return true
        }
    }

    /// 在筛着的设备、项目里的
    private func scoped(_ items: [SessionItem]) -> [SessionItem] {
        let source = activeSource?.id, project = activeProject
        return items.filter { (source == nil || $0.sourceId == source) && (project == nil || $0.folder == project) }
    }

    /// 设备那排：有会话的设备（筛着的那台没会话了也列着），个数跟着项目筛选走
    private var sourceOptions: [ScopeBar.Option] {
        let project = activeProject
        let inProject = model.filtered.filter { project == nil || $0.folder == project }
        let busy = Set(model.sessions.map(\.sourceId))
        return model.sources.filter { busy.contains($0.id) || $0.id == activeSource?.id }.map { source in
            ScopeBar.Option(id: source.id, title: source.name, count: inProject.filter { $0.sourceId == source.id }.count)
        }
    }

    /// 项目那排：按列表里的先后，个数跟着设备筛选走
    private var projectOptions: [ScopeBar.Option] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        let source = activeSource?.id
        for item in model.sortedSessions(sorting) where !item.folder.isEmpty && (source == nil || item.sourceId == source) {
            if counts[item.folder] == nil { order.append(item.folder) }
            counts[item.folder, default: 0] += 1
        }
        return order.map { ScopeBar.Option(id: $0, title: $0, count: counts[$0] ?? 0) }
    }

    /// 最上面一行「会话 9 | 群 1 | 标签组 2」三个页签，右边是这个页签自己的按钮（会话：显示方式；群：建群；标签组：新建）。
    /// 「会话」页签下面一排状态筛选：全部 · 标记 · 工作中 · 待确认 常驻，出错有的时候才出现；数字跟着设备、项目筛选走。
    /// 再下面设备、项目收成一行（只写着选的是哪个），点开才是两排胶囊，选完自动收起
    private func controls(_ base: [SessionItem], count: Int, tab: String) -> some View {
        let projects = projectOptions
        let sources = sourceOptions
        let bySource = sources.count > 1 || activeSource != nil
        // 项目那排看全部会话有没有不止一个项目，不看选了哪台设备：那台只有一个项目时也照样显示（11-23 反馈：选了设备项目筛选就没了）
        let byProject = Set(model.sessions.map(\.folder).filter { !$0.isEmpty }).count > 1 || activeProject != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if model.query.isEmpty {
                    SidebarTabs(selection: Binding(get: { tab }, set: { new in withAnimation(.klSnappy) { listTab = new } }), tabs: [
                        SidebarTabs.Tab(id: "sessions", title: L("会话"), count: count),
                    ] + (groupsOn ? [SidebarTabs.Tab(id: "groups", title: L("群"), count: KitelineKit.liveGroupCount)] : []) + [
                        SidebarTabs.Tab(id: "tabgroups", title: L("会话组"), count: KitelineKit.tabGroupCount, alert: KitelineKit.tabGroupsWaiting),
                    ])
                } else {
                    Text("会话").font(.app(size: 13, weight: .semibold))
                    Text("\(count)").font(.app(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                if tab == "tabgroups" {
                    TarsTabGroupNewButton { SidebarTabButton(symbol: "plus", title: L("新建")) }
                } else if tab == "groups" {
                    // 建群：弹面板勾选要拉进来的会话（至少两个）
                    if model.sessions.count > 1 {
                        Button { model.groupSeed = [] } label: { SidebarTabButton(symbol: "person.2.badge.plus", title: L("建群")) }
                            .buttonStyle(.plain)
                            .help("把几个会话拉进一个群，让它们互相沟通")
                    }
                }
            }
            if tab == "sessions" {
                if model.sessions.count > 1 || isFiltering {
                    FilterBar(bleed: 0) {
                        ForEach(Self.statusOptions, id: \.id) { option in
                            let n = base.filter { matches($0, option.id) }.count
                            if option.id != "error" || n > 0 || status == option.id {
                                FilterChip(title: option.title, count: n, dot: option.color, symbol: option.id == "marked" ? "star.fill" : nil,
                                           selected: status == option.id) {
                                    withAnimation(.klSnappy) { statusFilter = status == option.id && option.id != "all" ? "all" : option.id }
                                }
                            }
                        }
                    }
                }
                // 设备 · 项目那一行（收起的），右边「显示方式」（分组、排序）：都只管会话，所以放在「会话」页签里（11-10）
                let showsView = model.sessions.count > 1 || !isDefaultView
                if bySource || byProject || showsView {
                    HStack(spacing: 6) {
                        if bySource || byProject {
                            // 先让这一行写得下选的设备、项目，「显示方式」放不下时自己截短
                            scopeSummary(bySource: bySource, byProject: byProject).layoutPriority(1)
                        }
                        Spacer(minLength: 0)
                        if showsView { viewMenu }
                    }
                }
                if bySource || byProject {
                    if scopeOpen {
                        if bySource {
                            ScopeBar(symbol: "desktopcomputer", allTitle: L("全部设备"), options: sources,
                                     selection: Binding(get: { activeSource?.id ?? "" }, set: { sourceFilter = $0; if !byProject { collapseScope() } }), bleed: 0)
                        }
                        if byProject {
                            ScopeBar(symbol: "folder", allTitle: L("全部项目"), options: projects,
                                     selection: Binding(get: { activeProject ?? "" }, set: { projectFilter = $0; collapseScope() }), bleed: 0)
                        }
                    }
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// 收起时的一行：「🖥 全部设备 · 📁 ccpulse ⌄」；筛着的那项用品牌色。点一下展开 / 收起两排胶囊
    private func scopeSummary(bySource: Bool, byProject: Bool) -> some View {
        return Button {
            withAnimation(.klSnappy) { scopeOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                // 不画设备、文件夹两个小图标：侧栏宽 270 时「全部设备 · 全部项目」放不下，设备被截成「全部…」（11-21 自测）
                if bySource {
                    Text(activeSource?.name ?? L("全部设备")).lineLimit(1)
                        .foregroundStyle(activeSource == nil ? Color.primary : Color.tarsBrand)
                }
                if bySource && byProject { Text("·").foregroundStyle(.tertiary) }
                if byProject {
                    Text(activeProject ?? L("全部项目")).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(activeProject == nil ? Color.primary : Color.tarsBrand)
                }
                Image(systemName: scopeOpen ? "chevron.up" : "chevron.down").font(.app(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            // 按钮样式规范（KiteButtonStyle 的外观）：同旁边的筛选；筛着的那项字是品牌色
            .kiteLook()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(scopeOpen ? L("收起设备、项目筛选") : L("按设备、项目筛选会话"))
    }

    /// 在展开的胶囊里选好了：稍等一下再收起（让选中的样子先闪一下）
    private func collapseScope() {
        Task { @MainActor in
            try? await Task.sleep(milliseconds: 250)
            withAnimation(.klSnappy) { scopeOpen = false }
        }
    }

    /// 「显示方式」：分组、排序放在一个菜单里；按钮上写着现在怎么分、怎么排，改过默认的用品牌色。
    /// 项目选了某一个时没有分组（只剩排序）
    private var viewMenu: some View {
        Menu {
            if activeProject == nil {
                Picker("分组", selection: $grouping.animation(.klSnappy)) {
                    ForEach(Self.groupOptions, id: \.0) { option in Text(option.1).tag(option.0) }
                }
                .pickerStyle(.inline)
            }
            Picker("排序", selection: $sorting.animation(.klSnappy)) {
                ForEach(Self.sortOptions, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.inline)
            if !isDefaultView || isFiltering {
                Divider()
                Button("恢复默认") {
                    withAnimation(.klSnappy) { grouping = "none"; sorting = "started"; clearFilters() }
                }
            }
        } label: {
            ViewMenuLabel(summary: viewSummary, isDefault: isDefaultView, compact: true)
        }
        .klMenuButtonStyle()
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("会话的分组与排序") + "：" + viewSummary)
    }

    /// 按钮上的字：分组 · 排序（默认的不写）
    private var viewSummary: String {
        var parts: [String] = []
        if effectiveGrouping != "none" { parts.append(Self.groupOptions.first { $0.0 == grouping }?.1 ?? "") }
        if sorting != "started" { parts.append(Self.sortOptions.first { $0.0 == sorting }?.1 ?? "") }
        return parts.isEmpty ? L("显示方式") : parts.joined(separator: " · ")
    }

    private struct SessionGroup {
        var key: String
        var name: String? = nil
        var sub: String? = nil
        /// 按 Agent 分组时组名前画它的标志
        var agent: String? = nil
        /// 组头上写着机器名时（按来源分组；按项目分组、会话来自不止一台机器）是哪台：机器名右边跟着它的 CPU、内存
        var source: String? = nil
        /// 最上面「标记」一组（组名前一颗星）
        var marked = false
        var items: [SessionItem]
    }

    /// 按来源 / 按项目 / 按 Agent 分组（同手机）：组的先后跟着组里最靠前的会话走；按来源时照来源列表的顺序。
    /// 标记的会话不进各组，单独一组「标记」排在最上面（不分组时它们本来就排在最前）
    private func groups(_ all: [SessionItem]) -> [SessionGroup] {
        let grouping = effectiveGrouping
        guard model.query.isEmpty, grouping != "none", model.sessions.count > 1 else { return [SessionGroup(key: "all", items: all)] }
        let starred = all.filter { model.isMarked($0.id) }
        let items = all.filter { !model.isMarked($0.id) }
        let bySource = grouping == "source"
        let byAgent = grouping == "agent"
        let multi = Set(model.sessions.map(\.sourceId)).count > 1
        var order: [String] = []
        var map: [String: SessionGroup] = [:]
        for item in items {
            let key = byAgent ? item.agent : bySource ? item.sourceId : "\(item.sourceId)\n\(item.cwd)"
            if map[key] == nil {
                order.append(key)
                if byAgent {
                    map[key] = SessionGroup(key: key, name: Agents.info(item.agent).name, agent: item.agent, items: [])
                } else {
                    map[key] = SessionGroup(key: key, name: bySource ? (item.sourceName.isEmpty ? L("未知来源") : item.sourceName) : (item.folder.isEmpty ? L("（未知目录）") : item.folder),
                                            sub: !bySource && multi ? item.sourceName : nil, source: bySource || multi ? item.sourceId : nil, items: [])
                }
            }
            map[key]?.items.append(item)
        }
        var result = order.compactMap { map[$0] }
        if bySource {
            let ids = model.sources.map(\.id)
            result.sort { (ids.firstIndex(of: $0.key) ?? ids.count) < (ids.firstIndex(of: $1.key) ?? ids.count) }
        } else if sorting == "name" {
            result.sort { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
        }
        if !starred.isEmpty { result.insert(SessionGroup(key: "\u{1}marked", name: L("标记"), marked: true, items: starred), at: 0) }
        return result
    }

    /// 筛得一个不剩：说清楚是哪一类没有，给个「显示全部」
    private var emptyFilter: some View {
        let title = Self.statusOptions.first { $0.id == status && $0.id != "all" }?.title
        let place = (activeSource.map { L("%@上", "\($0.name)") } ?? "") + (activeProject.map { L("「%@」项目里", $0) } ?? "")
        let name = place + (title.map { L("%@的会话", "\($0)") } ?? L("的会话"))
        return VStack(spacing: 8) {
            Text("暂无\(name)").font(.app(size: 12)).foregroundStyle(.secondary)
            Button("显示全部") { withAnimation(.klSnappy) { clearFilters() } }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .klSelectionDisabled()
    }
}

/// 左边栏这一列共用的外壳（经典版、新版都挂）：窗口工具栏上的新任务 / 世界 / 数据流三个按钮，把这一列的宽度报给顶上的纸鸢
struct SidebarChrome: KLViewModifier {
    @ObservedObject var model: KitelineModel

    func klBody(content: Content) -> some View {
        content
            // 把侧栏宽度报给顶上的纸鸢（它飞在侧栏这一段上方；侧栏收起时不飞）。只报出去、不参与排版，不会互相撑
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { KiteOverlay.shared.sidebarWidth = geometry.size.width }
                        .klOnChange(of: geometry.size.width) { _, width in KiteOverlay.shared.sidebarWidth = width }
                }
            }
            .onDisappear { KiteOverlay.shared.sidebarWidth = 0 }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.newTask() } label: { Label("新任务", systemImage: "square.and.pencil") }
                        .help("在指定项目中新建 Claude Code 会话")
                }
                // 世界模式的入口：像素地球（鼠标移上去会转）；再点一下回到会话
                ToolbarItem(placement: .primaryAction) {
                    let on = model.worldMode && model.worldPage == "world"
                    Button { model.toggleWorld(page: "world") } label: {
                        Label { Text("世界") } icon: { WorldGlobeIcon(active: on) }
                    }
                    .help(on ? L("离开世界模式，回到会话（⇧⌘E）") : L("世界模式：机房、卫星和像素小人，一眼看全所有会话（⇧⌘E）"))
                }
                // 数据流大屏：所有会话读了什么、做了什么、产出去了哪，一块屏连成线（和世界共用一个网页宿主）
                ToolbarItem(placement: .primaryAction) {
                    let on = model.worldMode && model.worldPage == "flow"
                    Button { model.toggleWorld(page: "flow") } label: {
                        Label { Text("数据流") } icon: { Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(on ? Color.tarsBrand : .secondary) }
                    }
                    .help(on ? L("离开数据流大屏，回到会话（⇧⌘D）") : L("数据流大屏：所有会话读了什么、做了什么、产出去了哪，连成一块屏（⇧⌘D）"))
                }
                // AR 模式：界面变透明，所有会话漂在桌面前的 3D 空间里（WASD 走动、拖动转向、指着放大、点开回复）
                ToolbarItem(placement: .primaryAction) {
                    Button { model.toggleAR() } label: {
                        Label { Text("AR") } icon: { Image(systemName: "cube.transparent").foregroundStyle(model.arMode ? Color.tarsBrand : .secondary) }
                    }
                    .help(L("AR 模式：界面变为透明，所有会话悬浮在桌面前方的空间中；WASD 移动、拖动转向（⇧⌘A）"))
                }
            }
    }
}

/// 左边栏顶上「会话 9 | 群 1 | 标签组 2」三个页签：选中的那个字重、下面一条品牌色短线，没选中的淡字；同一行右边放这个页签的按钮
private struct SidebarTabs: KLView {
    struct Tab {
        let id: String
        let title: String
        let count: Int
        /// 右上角橙点：这个页签里有等你确认的
        var alert = false
    }

    @Binding var selection: String
    let tabs: [Tab]

    var klBody: some View {
        HStack(spacing: 14) {
            ForEach(tabs, id: \.id) { tab in
                let on = selection == tab.id
                Button { selection = tab.id } label: {
                    HStack(spacing: 4) {
                        Text(tab.title).font(.app(size: 13, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                        Text("\(tab.count)").font(.app(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .overlay(alignment: .topTrailing) {
                        if tab.alert { Circle().fill(Color.tarsOrange).frame(width: 6, height: 6).offset(x: 5, y: 1) }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    // 选中：整块淡染主题色（不画下面那道色条，11-21 反馈：单边色条是 AI 样式）
                    .background(on ? Color.tarsBrand.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

/// 页签那一行右边的小按钮（建群、新建标签组）：图标 + 两个字，样子同「显示方式」默认态但更紧凑，三个页签放下了也不挤
struct SidebarTabButton: KLView {
    let symbol: String
    let title: String

    var klBody: some View {
        KiteLabel(title, symbol: symbol).lineLimit(1)
            .kiteLook()
        .fixedSize()
    }
}

/// 左边栏会话行的选中、悬停：同上面的入口格子，淡品牌色底 + 细边。不用列表自带的选中——键盘焦点在列表上时它是一整块饱和的强调色，
/// 行里的橙色状态字也被吃掉（10-23 反馈太突兀）；另外会话现在开成标签页，按方向键一路选下去会给经过的每个会话都开一个标签
struct SidebarRowHighlight: KLViewModifier {
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false
    /// 新版界面的侧栏里：框里的边距、圆角照侧栏规范（SideMetric）；经典版不变
    @Environment(\.sideColumn) private var side

    func klBody(content: Content) -> some View {
        let scheme = Look.shared.scheme
        let shape = RoundedRectangle(cornerRadius: side ? SideMetric.radius : scheme == nil ? 10 : 4, style: .continuous)
        let fill: Color = if let scheme { selected ? scheme.listActiveColor : (hovering ? scheme.listHoverColor : .clear) }
            else { selected ? Color.tarsBrand.opacity(0.14) : Color.primary.opacity(hovering ? 0.05 : 0) }
        content
            .padding(.horizontal, side ? SideMetric.pad : 7)
            .background(fill, in: shape)
            // VS Code 配色方案下选中行没有描边（同 VS Code 的列表）
            .overlay { if selected, scheme == nil { shape.strokeBorder(Color.tarsBrand.opacity(0.32), lineWidth: 1) } }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onTapGesture(perform: select)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
    }
}

/// 左边栏顶上的入口（同手机首页的汇总卡片）：小方块图标、右上角的数、名字、一行小字。
/// 两列排；小字一格放不下的占一整行，落单的也撑满一行（TileGrid），排得整齐
struct SidebarTiles: KLView {
    @ObservedObject var model: KitelineModel
    @ObservedObject private var today = TodayModel.shared
    @State private var usage: (cost: Double, output: Double, requests: Double, tokens: Double)?
    /// 各台电脑的订阅额度（Limits.collect 的 JSON，交给 KitelineKit 画额度条）
    @State private var limits: Data?
    /// 卡片上的刷新按钮转圈
    @State private var limitsBusy = false

    var klBody: some View {
        let todos = KitelineKit.todoCounts
        let running = Set(model.sessions.map { "\($0.sourceId)\n\($0.cwd)" }).count
        let waiting = Set(model.sessions.filter { $0.activity == .waiting }.map { "\($0.sourceId)\n\($0.cwd)" }).count
        let totals = today.range == .today ? today.report?.totals : nil
        // 今日用量一张大卡片（各台电脑的额度条）；历史会话、今日动态一行；待办、项目、收藏一行小格
        // （10-27 起的格子，10-31 改：今日用量和今日动态对调位置和大小）
        VStack(spacing: 8) {
            SidebarLimitsTile(limits: TarsLimitsBoard(json: limits),
                              tokens: (usage?.tokens ?? 0) > 0 ? L("%@ token", UsageInfo.compact(Int(usage!.tokens))) : "",
                              fallback: Text(usage.map { L("%@ · %@ 输出 · %@ 次", UsageReportModel.money($0.cost), UsageInfo.compact(Int($0.output)), "\(Int($0.requests))") }
                                             ?? L("Claude Code 回复后显示 5 小时与本周额度")),
                              busy: limitsBusy, refresh: refreshLimits,
                              selection: $model.selection)
            HStack(spacing: 8) {
                SidebarTile(id: KitelineModel.historyID, symbol: "clock.arrow.circlepath", title: L("历史会话"),
                            sub: Text("浏览 · 搜索 · 恢复"), selection: $model.selection)
                SidebarTile(id: KitelineModel.todayID, symbol: "sun.max.fill", title: L("今日动态"),
                            value: (totals?.prompts ?? 0) > 0 ? "\(totals!.prompts)" : "", unit: L("轮"),
                            sub: todaySub(totals), selection: $model.selection)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SidebarTile(id: KitelineModel.todosID, symbol: "checklist", title: L("待办"),
                            value: todos.open > 0 ? "\(todos.open)" : "", badge: todos.suggested, compact: true,
                            sub: Text(""), selection: $model.selection)
                SidebarTile(id: KitelineModel.projectsID, symbol: "folder.fill", title: L("项目"),
                            value: running > 0 ? "\(running)" : "", valueColor: waiting > 0 ? Color.tarsOrange : nil, compact: true,
                            sub: Text(""), selection: $model.selection)
                SidebarTile(id: KitelineModel.favoritesID, symbol: "star.fill", title: L("收藏"),
                            value: KitelineKit.favoriteCount > 0 ? "\(KitelineKit.favoriteCount)" : "", compact: true,
                            sub: Text(""), selection: $model.selection)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        // 侧栏一直开着：来源连上 / 断开时、每 5 分钟重新汇总一次，不然一直是刚启动时那份
        .liveReload(every: 300) {
            if today.range == .today || today.report == nil { today.load() }
            UsageReport.collect(days: 1) { setUsage($0) }
        }
        // 额度每次回复都在变：一分钟问一次各台电脑
        .liveReload(every: 60) {
            Limits.collect { payload in limits = try? JSONSerialization.data(withJSONObject: payload) }
        }
    }

    private func setUsage(_ payload: [String: Any]) {
        let t = payload["totals"] as? [String: Any] ?? [:]
        usage = (Digest.number(t["cost"]), Digest.number(t["output"]), Digest.number(t["requests"]),
                 ["input", "output", "cacheRead", "cacheWrite"].reduce(0) { $0 + Digest.number(t[$1]) })
    }

    /// 卡片上的刷新按钮（11-03）：额度、今天的 token 数都跳过缓存当场问各台电脑
    private func refreshLimits() {
        guard !limitsBusy else { return }
        limitsBusy = true
        let group = DispatchGroup()
        group.enter()
        Limits.collect(fresh: true) { payload in
            limits = try? JSONSerialization.data(withJSONObject: payload)
            group.leave()
        }
        group.enter()
        UsageReport.collect(days: 1, fresh: true) { payload in
            setUsage(payload)
            group.leave()
        }
        group.notify(queue: .main) {
            limitsBusy = false
            KitelineKit.flash(TarsLimitsBoard(json: limits).refreshedNote)
        }
    }

    /// 「12 个会话 · 30 个文件」，测试有失败的话最前面标红
    private func todaySub(_ t: DigestTotals?) -> Text {
        guard let t else { return Text("今日各项目工作汇总") }
        if t.sessions == 0 { return Text("今日暂无动态") }
        let rest = ([L("%lld 个会话", count: t.sessions)] + (t.files > 0 ? [L("%lld 个文件", count: t.files)] : [])).joined(separator: " · ")
        if t.testFailed > 0 { return Text("\(Text("测试失败 \(t.testFailed) 次").foregroundStyle(Color.red)) · \(rest)") }
        return Text(rest)
    }
}

/// 「今日用量」大卡片（同手机首页）：右上角今天的 token 总数，下面是各台电脑各家 agent 的 5 小时 / 本周额度条，花费这些明细点进去看；
/// 还没有额度读数时退回一行今天的花费。底色、选中样式同其它格子
private struct SidebarLimitsTile: KLView {
    let limits: TarsLimitsBoard
    /// 右上角：今天各台电脑一共用了多少 token
    let tokens: String
    let fallback: Text
    /// 标题后面的刷新按钮：拉的时候转圈
    let busy: Bool
    let refresh: () -> Void
    @Binding var selection: String?
    @State private var hovering = false

    var klBody: some View {
        let selected = selection == KitelineModel.usageID
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button { selection = KitelineModel.usageID } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    DuoIcon(symbol: "chart.bar.fill", size: 28)
                    Text("今日用量").font(.app(size: 13, weight: .semibold)).lineLimit(1)
                    // 刷新按钮的空位：真按钮从外面盖上来（按钮里再放按钮点起来不可靠）
                    Color.clear.frame(width: 22, height: 22).padding(.leading, -2)
                        .anchorPreference(key: RefreshSlot.self, value: .bounds) { $0 }
                    Spacer(minLength: 6)
                    if !tokens.isEmpty { Text(tokens).font(.app(size: 13, weight: .semibold).monospacedDigit()).lineLimit(1) }
                    Image(systemName: "chevron.right").font(.app(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
                if limits.isEmpty {
                    fallback.font(.app(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    limits
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(selected ? Color.tarsBrand.opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0.05), in: shape)
            .overlay { if selected { shape.strokeBorder(Color.tarsBrand.opacity(0.4), lineWidth: 1) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlayPreferenceValue(RefreshSlot.self) { slot in
            GeometryReader { geo in
                if let slot {
                    let rect = geo[slot]
                    Button(action: refresh) {
                        Group {
                            if busy {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.app(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: rect.width, height: rect.height)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .help(L("刷新额度"))
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        // 悬停算上刷新按钮：移到按钮上卡片底色不跳
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private struct RefreshSlot: PreferenceKey {
        static var defaultValue: Anchor<CGRect>? { nil }
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
    }
}

/// 一个入口格子：左上小方块图标（有新东西时右上角红色数字），右上角的数，下面名字和一行小字；选中时淡品牌色底
private struct SidebarTile: KLView {
    let id: String
    let symbol: String
    let title: String
    var value = ""
    var unit = ""
    var valueColor: Color? = nil
    var badge = 0
    /// 一行三个的小格：只有图标、数字和名字，没有那行小字
    var compact = false
    let sub: Text
    @Binding var selection: String?
    @State private var hovering = false

    var klBody: some View {
        let selected = selection == id
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button { selection = id } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    DuoIcon(symbol: symbol, size: 28)
                        .overlay(alignment: .topTrailing) {
                            if badge > 0 {
                                Text(badge > 99 ? "99+" : "\(badge)")
                                    .font(.app(size: 10, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Color.red, in: Capsule())
                                    .offset(x: 6, y: -6)
                            }
                        }
                    Spacer(minLength: 6)
                    if !value.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(value).font(.app(size: compact ? 15 : 18, weight: .bold).monospacedDigit()).foregroundStyle(valueColor ?? .primary)
                            if !unit.isEmpty { Text(unit).font(.app(size: 11)).foregroundStyle(.secondary) }
                        }
                        .lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.app(size: 13, weight: .semibold))
                    if !compact { sub.font(.app(size: 11)).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Color.tarsBrand.opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0.05), in: shape)
            .overlay { if selected { shape.strokeBorder(Color.tarsBrand.opacity(0.4), lineWidth: 1) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 入口格子的排法：两列；每格先问内容要多宽，一格放不下的占一整行；落单的（下一个占整行、或排在最后）也撑满一行，
/// 不留半行空。同一行的格子一样高
@available(macOS 13, *)
struct TileGrid: Layout {
    var spacing: CGFloat = 8

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[Int]] {
        let cell = (width - spacing) / 2
        let wide = subviews.map { $0.sizeThatFits(.unspecified).width > cell + 0.5 }
        var rows: [[Int]] = []
        var i = 0
        while i < subviews.count {
            if !wide[i], i + 1 < subviews.count, !wide[i + 1] {
                rows.append([i, i + 1])
                i += 2
            } else {
                rows.append([i])
                i += 1
            }
        }
        return rows
    }

    private func cellWidth(_ row: [Int], _ width: CGFloat) -> CGFloat { row.count == 2 ? (width - spacing) / 2 : width }

    private func height(_ row: [Int], _ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        let w = cellWidth(row, width)
        return row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
    }

    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        if let width = proposal.width, width.isFinite { return width }
        return (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0) * 2 + spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(proposal, subviews)
        let rows = rows(width, subviews)
        let total = rows.reduce(0) { $0 + height($1, width, subviews) } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 按父视图给的同一个宽度排（同 sizeThatFits），不用 bounds.width：取整后差零点几可能让某格换成占整行
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? bounds.width
        var y = bounds.minY
        for row in rows(width, subviews) {
            let w = cellWidth(row, width), h = height(row, width, subviews)
            for (k, index) in row.enumerated() {
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(k) * (w + spacing), y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: w, height: h))
            }
            y += h + spacing
        }
    }
}

/// 会话卡片上点「×」后，挨着按钮弹出的确认气泡（同原来的确认框：标题、关了会怎样、取消 / 关闭会话；回车关、Esc 取消）
struct CloseConfirm: KLView {
    let key: String
    let onCancel: () -> Void
    let onClose: () -> Void

    var klBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("关闭此会话？")).font(.app(size: 13, weight: .semibold))
            if let note = KitelineModel.shared.closeNote(key) {
                Text(note).font(.app(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("取消"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("关闭会话"), role: .destructive, action: onClose).keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 270)
    }
}

struct SessionRow: KLView {
    let item: SessionItem
    var pinned = false
    /// 标记了：标题后一颗主题色实心星，点了取消；没标记的鼠标移上来时右上角出一颗空心星，点了标记
    var marked = false
    var onMark: (() -> Void)? = nil
    /// 右上角的关闭：鼠标移到卡片上时，时间的位置换成「×」（不占宽度、列表不跳），点了先确认再关；不能关的会话不给
    var onClose: (() -> Void)? = nil
    /// 左边画不画头像：新版界面的会话列表不要（11-20 反馈：会话侧栏里去掉会话头像），状态看第二行的字
    var avatar = true
    /// 第三行写不写项目名：项目里的会话列表不写（选了项目进来的，都是这个项目的，11-20 用户），只写设备
    var folder = true
    @State private var hovering = false
    @State private var confirmingClose = false
    /// 自测截图：标题是这个的卡片画成鼠标停在上面（截不到真的悬停）
    static var captureHover: String?

    var klBody: some View {
        HStack(alignment: .top, spacing: 10) {
            if avatar {
                SessionAvatar(key: item.id, title: item.title, activity: item.activity, size: 34)
                    .tarsPeerAnchor(item.id)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    // 标题前是这个会话所属 agent 的小标志（同手机），几个 agent 混着用时一眼分得清
                    // 正在工作的会话：agent 标志亮成主题色（11-20 反馈：亮起来，绿色或主题色——界面少用颜色，取主题色），一眼看出哪几个在跑
                    AgentGlyph(item.agent, size: 12).foregroundStyle(item.activity == .busy ? AnyShapeStyle(Color.tarsBrand) : AnyShapeStyle(.secondary))
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                        .help(Agents.info(item.agent).name)
                    // 新版界面：标题不加粗、小一号，一行放得下更多字（11-20）
                    Text(item.title).font(.app(size: avatar ? 13 : SideMetric.Text.row, weight: avatar ? .semibold : .regular)).lineLimit(1)
                    if marked, let onMark {
                        Button(action: onMark) {
                            Image(systemName: "star.fill").font(.app(size: 10)).foregroundStyle(Color.tarsBrand)
                        }
                        .buttonStyle(.plain)
                        .hoverTip(L("已标记，点按取消标记"))
                    }
                    // 置顶的排在最前（同手机），标题后面一个小图钉
                    if pinned {
                        Image(systemName: "pin.fill").font(.app(size: 9)).foregroundStyle(.tertiary).help("已置顶")
                    }
                    if AppState.shared.config.mobile.mutedSessions.contains(item.id) {
                        Image(systemName: "bell.slash").font(.app(size: 10)).foregroundStyle(.tertiary).help("已静音：仅在需要确认时提醒")
                    }
                    // 已经开成标签的会话（11-20）：标题后一个小标签页图标；再点这一行不会再开，切过去并让那个标签闪
                    TarsOpenedTabMark(key: item.id)
                    Spacer(minLength: 4)
                    // 鼠标移上来时，时间的位置换成「☆」「×」。按钮一直在、只切换显隐，而且盖在上面不参与排版（宽度事先按按钮留好）：
                    // 悬停既不改卡片高度、也不增删控件。原来悬停时插进两个比时间高的按钮，卡片变高几点，
                    // 触控板滚动时行从鼠标底下滑过，列表一微调悬停就来回翻转，按钮增删又让焦点存储每轮都变，
                    // 窗口排版停不下来——转盘，转到系统上限就闪退（11-01）
                    let canMark = onMark != nil && !marked
                    Text(Format.short(item.updatedAt)).font(.app(size: 10.5)).foregroundStyle(.tertiary)
                        .opacity(showsClose || showsMark ? 0 : 1)
                        .frame(minWidth: (canMark ? 17 : 0) + (onClose != nil ? 17 : 0) + (canMark && onClose != nil ? 4 : 0), alignment: .trailing)
                        .overlay(alignment: .trailing) {
                            HStack(spacing: 4) {
                                if let onMark, canMark {
                                    Button(action: onMark) {
                                        Image(systemName: "star")
                                            .font(.app(size: 9.5, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 17, height: 17)
                                            .background(Color.primary.opacity(0.1), in: Circle())
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .hoverTip(L("标记：排在所有列表的最上面"))
                                }
                                if let onClose {
                                    // 点了在按钮旁边弹气泡确认（11-21 反馈：弹到屏幕中间不方便，应该弹在关闭按钮附近）
                                    Button { confirmingClose = true } label: {
                                        Image(systemName: "xmark")
                                            .font(.app(size: 8.5, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 17, height: 17)
                                            .background(Color.primary.opacity(0.1), in: Circle())
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .hoverTip(L("关闭会话…"))
                                    .popover(isPresented: $confirmingClose, arrowEdge: .trailing) {
                                        CloseConfirm(key: item.id) { confirmingClose = false } onClose: {
                                            confirmingClose = false
                                            onClose()
                                        }
                                    }
                                }
                            }
                            .opacity(showsClose || showsMark ? 1 : 0)
                            .allowsHitTesting(showsClose || showsMark)
                        }
                }
                // 新版界面：空闲的不写「空闲」（11-20 反馈：没必要），有目标、阶段的照样显示
                if avatar || !idleOnly {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // 设了目标的：目标到哪了（鼠标停上去看目标原文）
                    if let goal = item.goal {
                        GoalBadge(state: goal.state, round: goal.round, size: 10.5).hoverTip(goal.text)
                    }
                    // 正在做的会话：这一轮做到第几步（主题色小标识，几个会话各到哪一步一眼看清）
                    if let stage = item.stage {
                        StageBadge(step: stage.step, total: stage.total, label: stage.label, part: stage.part, dots: stage.dots, size: 10.5)
                            .hoverTip(stage.tip)
                    }
                    // 只说状态（回复内容点开会话看；截短的两行看了也看不全，11-10 用户）
                    if avatar || !isIdleStatus {
                        Text(item.status)
                            .font(.app(size: avatar ? 11.5 : SideMetric.Text.caption))   // 新版界面（不画头像）照侧栏规范
                            .foregroundStyle(lineColor)
                            .lineLimit(1)
                            .help(item.line)
                    }
                }
                }
                HStack(spacing: 4) {
                    Image(systemName: item.kind == .ssh ? "server.rack" : (item.kind == .kiteline ? "desktopcomputer" : "laptopcomputer"))
                    Text(folder ? "\(item.sourceName) · \(item.folder)" : item.sourceName).lineLimit(1)
                    if let usage = item.usage, usage.percent >= 70 {
                        Spacer(minLength: 4)
                        Text("上下文 \(usage.percent)%")
                            .foregroundStyle(usage.percent >= 90 ? Color.red : Color.tarsOrange)
                    }
                }
                .font(.app(size: 10.5))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .onHover { hovering = $0 }
    }

    /// 状态就是「空闲」（没出错、没在忙、不等确认）
    private var isIdleStatus: Bool { item.activity == .idle && !item.failed && item.status == L("空闲") }
    /// 第二行除了「空闲」什么都没有（没有目标、阶段）：新版界面整行不画
    private var idleOnly: Bool { isIdleStatus && item.goal == nil && item.stage == nil }

    /// 气泡开着时「×」留着（鼠标移进气泡，卡片就不算悬停了，按钮一隐气泡就没了依附）
    private var showsClose: Bool { onClose != nil && (hovering || confirmingClose || Self.captureHover == item.title) }
    private var showsMark: Bool { onMark != nil && !marked && (hovering || Self.captureHover == item.title) }

    private var lineColor: Color {
        if item.failed { return .red }
        switch item.activity {
        case .waiting: return .tarsOrange
        case .busy: return .tarsBrand
        default: return .secondary
        }
    }
}

extension View {
    /// 左边栏的会话拖得动：拖到右边哪一块的哪一边就放到哪（拖着时有半透明的会话卡片跟着，落点上也画一张）
    @MainActor
    func sessionDraggable(_ item: SessionItem) -> some View {
        let status = [Activity.waiting: L("待确认"), .busy: L("正在工作"), .idle: L("空闲")][item.activity] ?? ""
        let card = SessionCard(title: item.title, status: status, line: item.line, detail: "\(item.sourceName) · \(item.folder)", dot: item.activity.color)
        return onDrag { KitelineKit.dragProvider(key: item.id, card: card) } preview: { card.opacity(0.92) }
    }
}

struct SessionMenu: KLView {
    @ObservedObject var model: KitelineModel
    let item: SessionItem

    var klBody: some View {
        Button("在 VS Code 中打开") { model.jump(item.id) }
        if !KitelineKit.panes.keys.contains(item.id) {
            // 把右边当前那块一分为二放这个会话（同把它拖到右边那块的右边 / 下边）
            Button("在右侧分屏打开") { openSplit(down: false) }
            Button("在下方分屏打开") { openSplit(down: true) }
        }
        Button(model.isMarked(item.id) ? "取消标记" : "标记") { withAnimation(.klSnappy) { model.toggleMark(item.id) } }
        Button(AppState.shared.config.mobile.pinnedSessions.contains(item.id) ? "取消置顶" : "置顶") { model.togglePin(item.id) }
        Button("在此项目中新建会话…") { model.newTask(in: item) }
        TarsTabGroupMenu(key: item.id)
        if KitelineKit.groupsSupported, item.canReply {
            Button("拉群协作…") { model.groupSeed = [item.id] }
        }
        let muted = AppState.shared.config.mobile.mutedSessions.contains(item.id)
        Button(muted ? "取消静音" : "静音（仅在需要确认时提醒）") {
            AppState.shared.updatePreferences { config in
                config.mobile.mutedSessions.removeAll { $0 == item.id }
                if !muted { config.mobile.mutedSessions.append(item.id) }
            }
            model.refresh()
        }
        // 权限模式、换模型、压缩、子 agent：这个 agent 有才给（caps）
        if item.canReply {
            if item.can("mode") { Button("权限模式…") { KitelineKit.perform(.mode, key: item.id) } }
            if item.can("model") {
                Button(item.tune.isEmpty ? "模型和思考等级…" : "模型和思考等级（\(item.tune)）…") { KitelineKit.perform(.model, key: item.id) }
            }
            if item.can("compact") {
                Button("压缩上下文（/compact）\(item.usage.map { " · 已用 \($0.percent)%" } ?? "")…") { model.compact(item.id) }
            }
        }
        if item.activity == .busy { Button("中断 \(Agents.info(item.agent).speaker)") { model.press("esc", on: item.id) } }
        // 关闭会话（caps 有 close，目前是 Claude Code）：关掉 VS Code 里的标签页 / 终端里 /exit
        // 重启会话：关掉再接着这段对话打开，让 Agent 读到新的设置和技能（如 Kiteline 浏览器）；正在工作的等这一轮做完
        if item.canReply, item.can("close") {
            Button("重启会话") { model.restart([item.id]) }
            Button("批量重启会话…") { model.showBatchRestart = true }
        }
        if item.canReply, item.can("close") { Button("关闭会话…") { model.close(item.id) } }
        Divider()
        if item.can("subagents") {
            Button(item.subagents > 0 ? "子 agent（已派出 \(item.subagents) 个）…" : "子 agent…") { KitelineKit.perform(.agents, key: item.id) }
        }
        Button("在对话里搜索…") { KitelineKit.perform(.search, key: item.id) }
        Button("会话信息") { KitelineKit.perform(.info, key: item.id) }
        Button("Agent 详情…") { model.agentDetail = item.id }
        Divider()
        Button("复制工作目录") { copy(item.cwd) }
        Button("复制会话名") { copy(item.name) }
    }

    private func openSplit(down: Bool) {
        if KitelineKit.openSplit(item.id, down: down) {
            model.selection = item.id
        } else {
            KitelineKit.flash(L("右侧空间不足，无法继续分屏：请先关闭一个分屏，或放大窗口"))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SidebarFooter: KLView {
    @ObservedObject var model: KitelineModel
    @ObservedObject private var screen = VirtualScreen.shared

    var klBody: some View {
        // 每一项都是按钮（至少 32×32，鼠标移上去有浅底），点了打开对应的设置页：来源 → 来源，手机数、二维码 → 手机访问，齿轮 → 设置首页（通用）
        HStack(spacing: 2) {
            FooterButton(help: L("来源：点击管理")) { SettingsWindowController.shared.show(tab: .sources) } label: {
                HStack(spacing: 6) {
                    Circle().fill(model.onlineSources > 0 ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text("\(model.onlineSources)/\(model.sources.count) 来源")
                }
                .fixedSize()   // 底栏挤的时候（有更新箭头）也不折成两行
            }
            FooterButton(help: L("已连接的手机：点击打开手机访问")) { SettingsWindowController.shared.show(tab: .phone) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "iphone").font(.system(size: 14, weight: .medium))
                    Text("\(model.phoneClients)").monospacedDigit()
                }
            }
            // 有新版本时：手机数和右边几个图标中间一个绿色向上箭头（没有更新时不占地方）。侧栏最窄 260 时也放得下：两边不留最小间隔
            Spacer(minLength: 0)
            UpdateButton(size: 24)
            Spacer(minLength: 0)
            if VirtualScreen.supported {
                FooterButton(help: screen.helpText) { screen.toggle() } label: {
                    Image(systemName: "display").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(screen.isOn ? Color.tarsBrand : Color.secondary)
                        .accessibilityLabel("虚拟屏幕")
                }
            }
            FooterButton(help: L("手机访问")) { SettingsWindowController.shared.show(tab: .phone) } label: {
                Image(systemName: "qrcode").font(.system(size: 16, weight: .medium))
            }
            FooterButton(help: L("设置")) { SettingsWindowController.shared.show(tab: .general) } label: {
                Image(systemName: "gearshape").font(.system(size: 16, weight: .medium))
            }
        }
        .font(.app(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .tarsGlass(cornerRadius: 18)
        .padding(10)
    }
}

/// 侧栏底栏的一个按钮：至少 32×32 好点中，鼠标移上去有浅底
private struct FooterButton<Content: View>: KLView {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Content
    @State private var hovering = false

    var klBody: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            label
                .padding(.horizontal, 8)
                .frame(minWidth: 32, minHeight: 32)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverTip(help)
    }
}

// MARK: - 右侧

struct DetailView: KLView {
    @ObservedObject var model: KitelineModel

    var klBody: some View {
        if model.worldMode {
            WorldView(model: model)
        } else if model.selection == KitelineModel.todayID {
            TodayView()
        } else if model.selection == KitelineModel.historyID {
            HistoryView()
        } else if model.selection == KitelineModel.usageID {
            UsageReportView()
        } else if model.selection == KitelineModel.projectsID {
            ProjectsView()
        } else if model.selection == KitelineModel.todosID {
            TarsTodosView()
        } else if model.selection == KitelineModel.favoritesID {
            TarsFavoritesView()
        } else if model.selection == KitelineModel.groupsID {
            TarsGroupsView()
        } else if model.selection != nil || !KitelineKit.panes.isPristine {
            // 选中的是会话、群；或者右边分屏的当前块还空着（一分为二出来、还没选会话）
            ConversationDetail(model: model, key: model.selection)
        } else {
            WelcomeView(model: model)
                .navigationTitle("Kiteline")
        }
    }
}

/// 会话（正在跑的、已经结束的）：可以像 VS Code 一样分屏，左右、上下随便分（KitelineKit/Views/ChatPanes.swift）。
/// 每块顶上是一张标签（同浏览器），会话自己的按钮（文件、改动、测试、在 VS Code 中打开、更多）在各自的标签栏上；
/// macOS 15 起最上面一排标签栏铺进窗口工具栏那一带，窗口不再另有一条标题栏（10-23 起：上下文用量在每块底下已经有了，按钮都跟会话走）。
/// 左边栏选中的就是当前块的会话，「会话」菜单也对它；在右边点了另一块，左边栏跟着选中（空块 = 不选）
struct ConversationDetail: KLView {
    @ObservedObject var model: KitelineModel
    let key: String?

    /// 工具栏去掉标题、底色透明要 macOS 15；更早的系统标签栏排在工具栏下面，工具栏照旧写当前会话的标题
    private static var fillsTitlebar: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    /// 只建一份：这一页跟着整个 KitelineModel 重算（每台电脑每秒推一次状态），每次新建的话分屏比不出没变，
    /// 几列对话的环境全要重传一遍（10-26 反馈开到 4 列卡得要命）
    static let accessory = TarsPaneAccessory(buttons: { key in AnyView(PaneButtons(model: KitelineModel.shared, key: key)) },
                                                     menu: { key, folded in AnyView(PaneMenu(model: KitelineModel.shared, key: key, folded: folded)) })

    var klBody: some View {
        TarsPanesView(fillsTitlebar: Self.fillsTitlebar, accessory: Self.accessory)
            .equatable()
            // 窗口标题（「窗口」菜单、调度中心里看得到）仍是当前块的会话，只是不画在工具栏上
            .navigationTitle(title)
            .modifier(TitlebarTabs(subtitle: subtitle))
            // 读现在的值，不用送来的：当前块一下子连变两次时（点「一分为二」= 先切到这块、再切到新的一块），
            // 先送来的是过时的，拿它去设左边栏又会把当前块切回去
            .klOnChange(of: KitelineKit.panes.focused) { _, _ in
                let focused = KitelineKit.panes.focused
                if focused != model.selection { model.selection = focused }
            }
    }

    private var title: String {
        guard let key else { return L("选择会话") }
        if let group = KitelineKit.groupTitle(key) { return group.title }
        if let code = KitelineKit.codeTabTitle(key) { return code.title }
        return model.session(key)?.title ?? HistoryModel.shared.past(key)?.displayTitle ?? L("会话已结束")
    }

    private var subtitle: String {
        guard let key else { return L("选择会话放入右侧空白分屏，或从左侧拖入") }
        if let group = KitelineKit.groupTitle(key) { return group.subtitle }
        if let code = KitelineKit.codeTabTitle(key) { return code.subtitle }
        if let item = model.session(key) {
            let status = [Activity.waiting: L("待确认"), .busy: L("正在工作"), .idle: L("空闲")][item.activity] ?? ""
            // 只读（Proma 这类）在状态后标出来
            return [status, item.readOnly ? L("只读") : "", item.sourceName, item.folder].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let past = HistoryModel.shared.past(key) { return L("已结束 · %@ · %@", "\(past.sourceName)", "\(past.folder)") }
        return L("已结束")
    }
}

/// 工具栏那一带让给标签栏：不画标题、底色透明（macOS 15 起）；更早的系统照旧写标题和小字
private struct TitlebarTabs: KLViewModifier {
    let subtitle: String

    func klBody(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.navigationSubtitle(subtitle)
        }
    }
}

/// 标签栏上会话自己的按钮（原来在窗口标题栏上）：正在跑的 = 文件、改动、测试、在 VS Code 中打开；已结束的 = 文件、在 VS Code 中恢复。
/// 中断在输入框旁边（红色停止键）和「更多」菜单里；上下文用量在输入框下面那排
struct PaneButtons: KLView {
    @ObservedObject var model: KitelineModel
    let key: String

    var klBody: some View {
        if let item = model.session(key) {
            let marked = model.isMarked(item.id)
            TarsPaneButton(marked ? "star.fill" : "star", help: marked ? L("已标记，点按取消标记") : L("标记：排在所有列表的最上面")) {
                withAnimation(.klSnappy) { model.toggleMark(item.id) }
            }
            .foregroundStyle(marked ? AnyShapeStyle(Color.tarsBrand) : AnyShapeStyle(.primary))
            TarsPaneButton("folder", help: L("文件：浏览此项目的文件（只读）")) { KitelineKit.perform(.files, key: item.id) }
            TarsPaneButton("plusminus.circle", help: L("改动：此项目的文件改动与最近提交")) { KitelineKit.perform(.changes, key: item.id) }
            TarsPaneButton("checkmark.seal", help: L("测试：Claude 运行过的测试及结果")) { KitelineKit.perform(.tests, key: item.id) }
            TarsPaneButton("arrow.up.forward.app", help: L("在 VS Code 中打开：切换到此会话所在的 VS Code 窗口")) { model.jump(item.id) }
        } else if let past = HistoryModel.shared.past(key) {
            TarsPaneButton("folder", help: L("文件：浏览此项目的文件（只读）")) { KitelineKit.perform(.files, key: past.key) }
            TarsPaneButton("arrow.uturn.forward.circle", help: L("在 VS Code 中恢复此对话并继续（也可直接在下方输入框发送消息）")) { HistoryModel.shared.resume(past) }
        }
    }
}

/// 标签栏的「更多」菜单、右键标签的菜单：会话的全部操作（同左边栏右键）；folded = 块太窄、标签栏上的按钮折进来了，排在最前面
struct PaneMenu: KLView {
    @ObservedObject var model: KitelineModel
    let key: String
    let folded: Bool

    var klBody: some View {
        if let item = model.session(key) {
            if folded {
                Button("文件") { KitelineKit.perform(.files, key: item.id) }
                Button("改动") { KitelineKit.perform(.changes, key: item.id) }
                Button("测试") { KitelineKit.perform(.tests, key: item.id) }
                Divider()
            }
            SessionMenu(model: model, item: item)
        } else if let past = HistoryModel.shared.past(key) {
            if folded { Button("文件") { KitelineKit.perform(.files, key: past.key) } }
            Button("在 VS Code 中恢复") { HistoryModel.shared.resume(past) }
            Button("历史会话") { model.selection = KitelineModel.historyID }
            Divider()
            Button("复制工作目录") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(past.cwd, forType: .string)
            }
        }
    }
}

struct WelcomeView: KLView {
    @ObservedObject var model: KitelineModel

    var klBody: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            VStack(spacing: 6) {
                Text("Kiteline").font(.app(size: 30, weight: .bold, design: .rounded))
                Text(model.summary).font(.app(size: 15)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let first = model.sessions(.waiting).first ?? model.sessions(.busy).first ?? model.sessions(.idle).first {
                    Button { model.selection = first.id } label: {
                        Label("打开「\(first.title)」", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .tarsButton(prominent: true)
                }
                Button { SettingsWindowController.shared.show(tab: .phone) } label: {
                    Label("在手机上使用", systemImage: "iphone.gen3")
                }
                .tarsButton()
                Button { OnboardingWindowController.shared.show() } label: {
                    Label("新手引导", systemImage: "list.number")
                }
                .tarsButton()
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 对话（原生，和 iOS App 同一套代码：KitelineKit，编成 KitelineKit 模块）

/// 原生对话页连本机的 Kiteline 服务（和手机走同一套接口），对话里点到的别的会话、页面交给左边栏和设置窗口
enum NativeConversation {
    @MainActor
    static func setUp() {
        let mobile = AppState.shared.config.mobile
        // 明文 HTTP 只开在本机（见 MobileServer.start）
        guard let url = URL(string: "http://127.0.0.1:\(mobile.port)") else { return }
        KitelineKit.connect(baseURL: url, token: mobile.token)
        KitelineKit.openSession = { key in KitelineModel.shared.selection = key }
        KitelineKit.openPage = { page in
            if page.hasPrefix("group:") { KitelineModel.shared.selection = KitelineModel.groupID(String(page.dropFirst("group:".count))); return }
            if page == "groups" { KitelineModel.shared.selection = KitelineModel.groupsID; return }
            // 新版界面：待办、收藏、项目在左边栏里看（右边的会话不动）
            if KitelineModel.shared.newLayout, KitelineModel.sideTabs.contains(page) { KitelineModel.shared.showSideTab(page); return }
            KitelineModel.shared.selection = ["today": KitelineModel.todayID, "usage": KitelineModel.usageID, "todos": KitelineModel.todosID,
                                          "favorites": KitelineModel.favoritesID,
                                          "history": KitelineModel.historyID, "projects": KitelineModel.projectsID][page] ?? KitelineModel.shared.selection
        }
        KitelineKit.openQuickReplies = { SettingsWindowController.shared.show(tab: .phrases) }
        KitelineKit.log = { Log.write($0) }
        KitelineKit.hoverTip = { text in if let text { HoverTipPanel.show(text) } else { HoverTipPanel.hide() } }
    }
}
