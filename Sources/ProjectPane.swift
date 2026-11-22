import AppKit
import SwiftUI
import KitelineKit

// 11-20 起的改版：待办、项目、收藏不再占右边，和「会话」并成左边栏的四个页签；「项目」页签里点一个项目，看它的
// 文件、Git、会话（同 VS Code 的侧边栏）；还能「打开项目」——选文件夹、选 Agent 直接打开。
// 项目的内容放哪：先做的是左边栏右边多出一列（二级侧边栏），用户当天觉得两个侧栏并排占地方、交互打架，
// 改成默认「在左边栏里点进去」——整列换成这个项目（顶上能返回、能直接换项目），不多占宽度；想要单独一列的点项目头上的按钮拆出去
// （偏好 projectPaneSplit）。同类产品（DPlex、Claude 桌面版、Superset）也都只留一个侧栏。
// 这个文件：左边栏的项目列表（SidebarProjects）、项目的内容（ProjectPaneView / ProjectSessions）、右边怎么排（ProjectSplit）、
// 「打开项目」面板（OpenProjectSheet）。文件树、Git、编辑区是共用代码（KitelineKit/Code，经 TarsProjectSide / TarsProjectEditor）

// MARK: - 左边栏「项目」页签

/// 各台电脑上的项目：一行一个（在跑的会话、分支和未提交的改动），点一个打开它的二级侧边栏，再点一下收起
struct SidebarProjects: View {
    @ObservedObject var model: KitelineModel
    /// 行的框离栏两边多远：plain 列表自己左边已经留了 8（11-21 量过），行再给 0 = 框离栏边 SideMetric.edge
    static let inset: CGFloat = 0
    /// 左边栏顶上那几格：列表的第一行，跟着一起滚
    let header: AnyView
    @ObservedObject private var projects = ProjectsModel.shared

    var body: some View {
        // 不分筛选页签（11-21）：同下面的会话，分「活动中」「其他项目」两节；活动中 = 有会话在跑或今天动过
        let all = projects.groupedShown
        let active = all.filter { group in group.contains { projects.matches($0, "active") } }
        let rest = all.filter { group in !group.contains { projects.matches($0, "active") } }
        List {
            header.listRowInsets(EdgeInsets())
            if !inPanel {
                titleRow.padding(.top, 10).padding(.bottom, 4).selectionDisabled()
                    .listRowInsets(EdgeInsets(top: 0, leading: SideMetric.pad, bottom: 0, trailing: SideMetric.pad - 2))
                    .listRowSeparator(.hidden)
            }
            if projects.projects.isEmpty, !projects.loaded {
                SkeletonShape(style: .list(5)).selectionDisabled()
            }
            Section {
                if active.isEmpty, projects.loaded {
                    Text("没有活动中的项目").font(.app(size: 11.5)).foregroundStyle(.secondary).padding(.leading, SideMetric.inset - 8)
                }
                rows(active)
            } header: {
                HStack(spacing: SideMetric.gap) {
                    PanelSectionTitle(title: L("活动中"), count: active.count)
                    if projects.loading, projects.loaded { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 4)
                    // 打开项目放在这一节标题右边（11-21 用户；同会话的「新会话」）
                    Button { model.showOpenProject = true } label: { KiteLabel(L("打开项目"), symbol: "folder.badge.plus") }
                        .kiteButton(prominent: true)
                        .textCase(nil)
                        .tourAnchor("openProject")
                        .help("打开项目：选择文件夹和 Agent，直接打开")
                }
                .padding(.leading, SideMetric.inset - 8).padding(.trailing, -2).padding(.top, 6)
                .padding(.bottom, 6)
            }
            .listSectionSeparator(.hidden)
            if !rest.isEmpty {
                Section {
                    if collapse.has("projects.rest.open") { rows(rest) }
                } header: {
                    Button { withAnimation(.snappy(duration: 0.18)) { collapse.toggle("projects.rest.open") } } label: {
                        HStack(spacing: 4) {
                            PanelSectionTitle(title: L("其他项目"), count: rest.count)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(collapse.has("projects.rest.open") ? 90 : 0))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, SideMetric.inset - 8).padding(.vertical, 4)
                }
                .listSectionSeparator(.hidden)
            }
            if all.isEmpty, projects.loaded {
                Text(L("暂无项目。点「打开项目」选择一个文件夹，用 Claude Code 或其他 Agent 打开。"))
                    .font(.app(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .selectionDisabled()
            }
            ForEach(projects.errors, id: \.self) {
                Label(ServerLang.ui($0), systemImage: "exclamationmark.triangle").font(.app(size: 11.5)).foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        // 不用系统侧栏样式：它每行左右再自带十几点，内容对不齐侧栏的 16 点对齐线（11-21 量过）
        .listStyle(.plain)
        .onAppear { if projects.filter != "all" { projects.filter = "all" } }   // 筛选页签去掉了：别留着之前选的
        .liveReload(every: 120) { projects.load() }
    }

    @ObservedObject private var collapse = PanelCollapse.shared

    /// 同一个项目挂在几台设备上的合成一项（11-20）：会话、用量合在一起，会话上写着是哪台设备的
    private func rows(_ groups: [[ProjectItem]]) -> some View {
        ForEach(groups, id: \.first!.id) { group in
            let project = group[0]
            SidebarProjectRow(project: project, members: group, live: projects.live(group: group),
                              kind: model.sources.first { $0.id == project.sourceId }?.kind ?? .local)
                .modifier(SidebarRowHighlight(selected: model.projectPane == project.id) { model.toggleProject(project.id) })
                .contextMenu { menu(project) }
                // 每节第一行离标题 6（加在选中框外面：选中时框不贴着标题，11-22 截图；同会话列表）
                .padding(.top, group[0].id == groups.first?.first?.id ? 6 : 0)
                // 行的框离栏边 8、框里 8（侧栏规范 SideMetric；11-20 反馈：项目列表左右边距太大）
                .listRowInsets(EdgeInsets(top: 1, leading: Self.inset, bottom: 1, trailing: Self.inset - 2))
                .listRowSeparator(.hidden)
        }
    }

    @Environment(\.sidebarInPanel) private var inPanel

    private var titleRow: some View {
            HStack(spacing: 6) {
                Text("项目").font(.app(size: SideMetric.Text.title, weight: .semibold))
                if !projects.projects.isEmpty {
                    Text("\(projects.groups.count)").font(.app(size: SideMetric.Text.row).monospacedDigit()).foregroundStyle(.tertiary)
                }
                if projects.loading, projects.loaded { ProgressView().controlSize(.mini) }
                Spacer(minLength: 6)
                // 「打开项目」在下面「活动中」那一节的标题右边，这里不重复（11-21）
            }
    }

    @ViewBuilder private func menu(_ project: ProjectItem) -> some View {
        Button("打开文件、Git 与会话") { model.openProject(project.id) }
        if project.exists {
            Button("在此新建任务…") { model.newTask(sourceId: project.sourceId, cwd: project.cwd) }
        }
        Divider()
        Button("复制工作目录") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.cwd, forType: .string)
        }
    }
}

/// 项目列表的一行（样子同会话行）：头像、项目名、时间；第二行在跑的会话和 Git 概况；第三行哪台电脑、哪个目录
struct SidebarProjectRow: View {
    let project: ProjectItem
    /// 合成一项的几台设备上的同一个项目（只有一台时就是 [project]）
    var members: [ProjectItem] = []
    let live: [SessionItem]
    let kind: SourceKind

    private var all: [ProjectItem] { members.isEmpty ? [project] : members }

    var body: some View {
        HStack(alignment: .top, spacing: SideMetric.gap) {
            // 文件夹图标（11-20 反馈：项目去掉头像，显示文件夹标识）；有会话在忙 / 等确认时文件夹是主题色 / 橙色
            ProjectFolderMark(state: state, size: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(project.name).font(.app(size: SideMetric.Text.row, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let last = all.map(\.lastActive).max(), last > 0 {
                        Text(Format.short(last)).font(.app(size: SideMetric.Text.meta)).foregroundStyle(.tertiary)
                    }
                }
                status.font(.app(size: SideMetric.Text.caption)).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: kind == .ssh ? "server.rack" : (kind == .kiteline ? "desktopcomputer" : "laptopcomputer"))
                    // 几台设备上都有：写设备名（「本机 · 虚拟机」），路径各不相同就不写了；只有一台：设备 · 路径
                    Text(all.count > 1 ? all.map(\.sourceName).joined(separator: " · ") : "\(project.sourceName) · \(Format.shortPath(project.cwd))")
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.app(size: SideMetric.Text.meta))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, SideMetric.rowPad)
    }

    private var state: Activity {
        if live.contains(where: { $0.activity == .waiting }) { return .waiting }
        if live.contains(where: { $0.activity == .busy }) { return .busy }
        return live.isEmpty ? .unknown : .idle
    }

    /// 「1 个待确认 · ⎇ main ↑2 · 3 个改动」：在跑的会话在前（待确认橙色、进行中品牌色），后面是分支、没推送的提交、没提交的改动
    private var status: Text {
        var parts: [Text] = []
        let waiting = live.filter { $0.activity == .waiting }.count
        let busy = live.filter { $0.activity == .busy }.count
        if waiting > 0 {
            parts.append(Text(L("%lld 个待确认", count: waiting)).foregroundColor(.tarsOrange))
        } else if busy > 0 {
            parts.append(Text(L("%lld 个进行中", count: busy)).foregroundColor(.tarsBrand))
        } else if !live.isEmpty {
            parts.append(Text(L("%lld 个会话", count: live.count)).foregroundColor(.secondary))
        }
        if let git = all.compactMap(\.git).first {
            if git.timeout {
                parts.append(Text("git 状态读取超时").foregroundColor(.orange))
            } else {
                var branch = Text("⎇ \(git.branch ?? L("(无分支)"))").foregroundColor(.secondary)
                if git.ahead > 0 { branch = branch + Text(" ↑\(git.ahead)").foregroundColor(.tarsBrand) }
                if git.behind > 0 { branch = branch + Text(" ↓\(git.behind)").foregroundColor(.red) }
                parts.append(branch)
                let changed = git.changed + git.untracked
                if changed > 0 { parts.append(Text(L("%lld 个改动", count: changed)).foregroundColor(.orange)) }
            }
        } else if live.isEmpty, let title = project.title, !title.isEmpty {
            parts.append(Text(title).foregroundColor(.secondary))
        }
        guard var text = parts.first else { return Text("暂无会话").foregroundColor(.secondary) }
        for part in parts.dropFirst() { text = text + Text(" · ").foregroundColor(.secondary) + part }
        return text
    }
}

/// 项目的标识：一个文件夹（不用头像）。有会话等确认是橙色、在忙是主题色，别的是次要色
struct ProjectFolderMark: View {
    let state: Activity
    var size: CGFloat = 16

    var body: some View {
        let color: Color = state == .waiting ? .tarsOrange : state == .busy ? .tarsBrand : .secondary
        Image(systemName: state == .unknown ? "folder" : "folder.fill")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
            .frame(width: size + 6, height: size + 4)
    }
}

// MARK: - 右边：二级侧边栏 + 会话 / 编辑区

/// 主窗口右边那一大块。平时就是 DetailView；左边栏「项目」里点开了项目时，左边多一列二级侧边栏（文件、Git、会话）；
/// 在里面点了文件、改动、提交历史，右边换成编辑区——会话那几列只是藏起来，不拆（拆了重建要大半秒，回来还得重新滚到底）
struct ProjectSplit: View {
    @ObservedObject var model: KitelineModel
    @ObservedObject private var projects = ProjectsModel.shared
    /// 项目的内容拆成单独一列（二级侧边栏）；默认不拆，在左边栏里看（SidebarView）
    @AppStorage("projectPaneSplit", store: AppConfig.defaults) private var split = false

    var body: some View {
        // 新版界面不再有「拆成单独一栏」（会话列表、文件侧栏是布局里自己的块）
        let pane = model.worldMode || !split || model.newLayout ? nil : model.projectPane
        let codeKey = model.worldMode ? nil : model.projectPane.flatMap { model.projectShowsCode ? projects.codeKey($0) : nil }
        HStack(spacing: 0) {
            if let pane { ProjectPaneView(model: model, id: pane).id(pane) }
            ZStack {
                DetailView(model: model)
                    .opacity(codeKey == nil ? 1 : 0)
                    .allowsHitTesting(codeKey == nil)
                if let codeKey {
                    TarsProjectEditor(key: codeKey).id(codeKey)
                        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
                }
            }
        }
    }
}

/// 一个项目的内容（同 VS Code 的侧边栏）：顶上一行项目名和按钮，下面文件、Git、会话几栏换着看。两种放法：
/// inline（默认）= 在左边栏那一列里，整列都是它，页签横着排在上面，顶上「‹」回项目列表；
/// 不是 inline = 左边栏右边单独一列（二级侧边栏），左边一条竖的活动栏，右边缘能拖着改宽度
struct ProjectPaneView: View {
    @ObservedObject var model: KitelineModel
    let id: String
    var inline = false
    @ObservedObject private var projects = ProjectsModel.shared
    @AppStorage("projectPaneWidth", store: AppConfig.defaults) private var width = 300.0
    @AppStorage("projectPaneSplit", store: AppConfig.defaults) private var split = false
    @State private var dragStart: Double?

    /// 文件、Git、新任务用的那一份（合成一项的几台设备里选的那台，见 ProjectsModel.fileMember）
    private var place: (sourceId: String, cwd: String) {
        projects.fileMember(id).map { ($0.sourceId, $0.cwd) } ?? ProjectsModel.place(id) ?? ("", "")
    }

    var body: some View {
        let place = place
        let members = projects.members(id)
        // 会话：几台设备上的都列（会话上写着是哪台设备的）
        let live = model.recentFirst(members.count > 1 ? projects.live(group: members)
            : model.sessions.filter { $0.sourceId == place.sourceId && $0.cwd == place.cwd })
        let key = projects.codeKey(ProjectsModel.id(sourceId: place.sourceId, cwd: place.cwd))
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header(live, key: key)
                usageLine
                if !inline { Divider() }
                if inline {
                    // 新版界面的导航栏里：只有项目名、用量这一头；会话列表、文件侧栏是布局里单独的两块（ProjectBlock），
                    // 放在哪一栏、上下怎么叠由用户在「布局」里摆。点会话、文件都在标签页区域开成标签
                    Spacer(minLength: 0)
                } else if let key {
                    TarsProjectSide(key: key, sessions: AnyView(ProjectSessions(model: model, id: id, live: live, place: place)), sessionCount: live.count,
                                    barOnTop: inline) { show in
                        // 开了文件 / 改动的标签：右边换成编辑区；标签全关了：回到会话
                        if model.projectPane == id, model.projectShowsCode != show { model.projectShowsCode = show }
                    }
                    .id(key)
                    .task(id: key) {
                        // 「打开项目」刚开的：先看会话那一栏（会话正在启动），平时先看文件
                        if projects.startOnSessions.remove(id) != nil { KitelineKit.projectActivity(key: key, "sessions") }
                    }
                } else {
                    // 一个会话都还没有（刚打开的新项目，会话还在启动）：文件、Git 要等会话出现才读得到
                    ProjectSessions(model: model, id: id, live: live, place: place, starting: true)
                }
            }
            .frame(width: inline ? nil : width)
            .frame(maxWidth: inline ? .infinity : nil)
            if !inline {
                // 拖这条线改宽度
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                    .overlay(Color.clear.frame(width: 8).contentShape(Rectangle())
                        .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                            if dragStart == nil { dragStart = width }
                            width = min(560, max(240, (dragStart ?? 300) + value.translation.width))
                        }.onEnded { _ in dragStart = nil })
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } })
            }
        }
        // 单独一列时底色一直铺到窗口顶上：右边会话的标签栏铺进标题栏那一带时，这一列顶上不露出别的颜色
        .background { if !inline { Color(nsColor: .windowBackgroundColor).ignoresSafeArea(edges: .top) } }
        .task(id: id) {
            projects.loadPast(id)
            if !projects.loaded { projects.load() }   // 从别处直接点开项目（没进过项目列表）：用量、分支这些要先读一遍
        }
        // 「打开项目」开的会话出现了：右边直接打开它
        .onChange(of: live.map(\.id)) { old, new in
            guard projects.selectWhenReady.contains(id), let fresh = new.first(where: { !old.contains($0) }) else { return }
            projects.selectWhenReady.remove(id)
            model.selection = fresh
        }
    }

    /// 项目名下面一行：这个项目的 agent 用量（11-20）——今天的 token 和花费、近 7 天的花费；点了看用量报表。还没有数就不占地方
    @ViewBuilder private var usageLine: some View {
        // 几台设备上的同一个项目：用量加在一起
        let members = projects.members(id).map(\.id)
        let ids = members.isEmpty ? [id] : members
        let parts = ids.compactMap { projects.today[$0] }
        let today: (tokens: Double, cost: Double)? = parts.isEmpty ? nil : (parts.reduce(0) { $0 + $1.tokens }, parts.reduce(0) { $0 + $1.cost })
        let week = ids.reduce(0.0) { $0 + (projects.cost7[$1] ?? 0) }
        if (today?.tokens ?? 0) > 0 || week > 0 {
            Button { model.selection = KitelineModel.usageID } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chart.bar.fill").font(.app(size: 9.5)).foregroundStyle(Color.tarsBrand)
                    if let today, today.tokens > 0 {
                        Text(L("今日 %@", L("%@ token", UsageInfo.compact(Int(today.tokens)))))
                        if today.cost > 0 { Text(verbatim: "· " + UsageReportModel.money(today.cost)) }
                    } else {
                        Text("今日暂无用量")
                    }
                    Spacer(minLength: 6)
                    if week > 0 { Text(L("7 天 %@", "\(UsageReportModel.money(week))")) }
                }
                .font(.app(size: SideMetric.Text.caption).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, SideMetric.pad)
                .frame(height: SideMetric.control)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: SideMetric.radius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, inline ? SideMetric.edge : 12)
            .padding(.bottom, SideMetric.edge)
            .help("此项目的 Agent 用量：点击查看用量报表")
        }
    }

    private func header(_ live: [SessionItem], key: String?) -> some View {
        let project = projects.project(id)
        let members = projects.members(id)
        let name = project?.name ?? (place.cwd as NSString).lastPathComponent
        let source = members.count > 1 ? members.map(\.sourceName).joined(separator: " · ")
            : project?.sourceName ?? model.sources.first { $0.id == place.sourceId }?.name ?? ""
        let state: Activity = live.contains { $0.activity == .waiting } ? .waiting
            : live.contains { $0.activity == .busy } ? .busy : live.isEmpty ? .unknown : .idle
        return HStack(spacing: inline ? 4 : 8) {
            if inline {
                PaneHeadButton(symbol: "chevron.left", help: L("返回项目列表")) {
                    // 新版：只是回到项目列表，当前项目和中间的标签不变
                    if model.newLayout { model.projectListShown = true } else { model.toggleProject(id) }
                }
            }
            // 项目名点开直接换到别的项目（在几个项目之间来回切不用先退回列表）
            Menu {
                ForEach(projects.groupedShown, id: \.first!.id) { group in
                    Button { model.openProject(group[0].id) } label: {
                        Text(verbatim: group[0].name + (group.count > 1 ? "（" + group.map(\.sourceName).joined(separator: " · ") + "）" : "")
                             + (group[0].id == id ? "  ✓" : ""))
                    }
                }
                // 几台设备上都有：文件、Git 看哪一台的
                if members.count > 1 {
                    Divider()
                    Section("文件和 Git 显示") {
                        ForEach(members) { member in
                            Button { projects.fileSource[projects.groupID(id)] = member.id } label: {
                                Text(verbatim: member.sourceName + (member.id == projects.fileMember(id)?.id ? "  ✓" : ""))
                            }
                        }
                    }
                }
                Divider()
                Button("打开项目…") { model.showOpenProject = true }
            } label: {
                HStack(spacing: 8) {
                    ProjectFolderMark(state: state, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(name).font(.app(size: SideMetric.Text.title, weight: .semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.app(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                        }
                        Text(members.count > 1 ? source : "\(source) · \(Format.shortPath(place.cwd))").font(.app(size: SideMetric.Text.meta)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("切换到其他项目")
            Spacer(minLength: 4)
            // 开着代码标签时：右边在编辑区和会话之间换
            if let key, KitelineKit.projectCodeTabs(key: key) > 0 {
                PaneHeadButton(symbol: model.projectShowsCode ? "bubble.left.and.bubble.right" : "chevron.left.forwardslash.chevron.right",
                               help: model.projectShowsCode ? L("右侧显示会话") : L("右侧显示打开的文件")) {
                    model.projectShowsCode.toggle()
                }
            }
            if project?.exists ?? true {
                PaneHeadButton(symbol: "square.and.pencil", help: L("在此项目中新建任务")) {
                    model.newTask(sourceId: place.sourceId, cwd: place.cwd)
                }
            }
            // 新版界面：调布局（会话列表、文件侧栏放哪）
            if inline {
                PaneHeadButton(symbol: "rectangle.3.group", help: L("布局：调整各个板块的位置")) { model.showLayoutSetup = true }
            } else {
                PaneHeadButton(symbol: "sidebar.left", help: L("收回左侧栏中显示")) { split.toggle() }
            }
            if !inline {
                PaneHeadButton(symbol: "xmark", help: L("收起")) { model.toggleProject(id) }
            }
        }
        // 两头的图标按钮是框：离栏边 8（侧栏规范）
        .padding(.leading, inline ? SideMetric.edge : 12)
        .padding(.trailing, SideMetric.edge)
        .frame(height: 44)
    }
}

/// 二级侧边栏顶上那行的小按钮：28×28，鼠标移上去有浅底
private struct PaneHeadButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.app(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: SideMetric.control, height: SideMetric.control)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: SideMetric.radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverTip(help)
        .accessibilityLabel(help)
    }
}

/// 二级侧边栏的「会话」一栏：这个项目里正在运行的会话（同左边栏的会话行，点了右边打开）、最近结束的会话（点了看记录、能恢复）
struct ProjectSessions: View {
    @ObservedObject var model: KitelineModel
    let id: String
    let live: [SessionItem]
    /// 新任务开在哪台设备、哪个目录（几台设备上的同一个项目：文件、Git 看的那一台）
    var place: (sourceId: String, cwd: String)? = nil
    /// 刚打开的新项目，会话还在启动
    var starting = false
    @ObservedObject private var projects = ProjectsModel.shared
    @ObservedObject private var collapse = PanelCollapse.shared

    var body: some View {
        let place = self.place ?? ProjectsModel.place(id) ?? ("", "")
        List {
            Section {
                if live.isEmpty {
                    if starting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在打开会话，文件和 Git 稍后显示…").font(.app(size: 11.5)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("没有运行中的会话").font(.app(size: 11.5)).foregroundStyle(.secondary).padding(.leading, SideMetric.inset - 8)
                    }
                }
                ForEach(live) { item in
                    SessionRow(item: item, pinned: model.isPinned(item.id), marked: model.isMarked(item.id),
                               onMark: { withAnimation(.snappy) { model.toggleMark(item.id) } },
                               onClose: item.canReply && item.can("close") ? { model.close(item.id, confirmed: true) } : nil, avatar: false, folder: false)
                        .modifier(SidebarRowHighlight(selected: model.selection == item.id && !model.projectShowsCode) { model.pick(item.id) })
                        // 第一行和上面的标题条之间空 6（标题条的底色是连着的，内边距加在条里看不出空隙；11-21 用户反复指出）
                        .padding(.top, item.id == live.first?.id ? 6 : 0)
                        // plain 列表自己左边留 8、右边 10（11-21 量过）：行左 0、右 -2 = 框离栏边 8
                        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: -2))
                        .listRowSeparator(.hidden)
                        .sessionDraggable(item)
                        .contextMenu { SessionMenu(model: model, item: item) }
                }
            } header: {
                HStack(spacing: SideMetric.gap) {
                    PanelSectionTitle(title: L("正在运行"), count: live.count)
                    Spacer(minLength: 4)
                    // 新会话（11-20 反馈：创建会话按钮大一点；同 VS Code 新开对话标签）：在中间开一个新会话标签，项目、设备、agent 带好
                    Button {
                        let agent = live.first?.agent ?? "claude-code"
                        model.selection = NewDraftKey.make(.init(sourceId: place.0, cwd: place.1, agent: agent))
                    } label: {
                        KiteLabel(L("新会话"), symbol: "plus")
                    }
                    .kiteButton(prominent: true)
                    .textCase(nil)
                    .help("在此项目中新建会话（在中间新开一个标签页）")
                }
                // 标题字对到 16 点对齐线（列表已留 8），按钮右边离栏边 8（列表已留 10）
                .padding(.leading, SideMetric.inset - 8).padding(.trailing, -2).padding(.top, 6)
                .padding(.bottom, 6)
            }
            .listSectionSeparator(.hidden)
            Section {
                if !collapse.has("recent.open") {
                    EmptyView()
                } else if let past = projects.past[id] {
                    if past.isEmpty { Text("没有已结束的会话").font(.app(size: 11.5)).foregroundStyle(.secondary).padding(.leading, SideMetric.inset - 8).padding(.top, 4) }
                    ForEach(past.prefix(30)) { item in
                        PastRow(item: item, avatar: false)
                            .modifier(SidebarRowHighlight(selected: model.selection == item.key && !model.projectShowsCode) {
                                HistoryModel.shared.open(item)
                            })
                            .padding(.top, item.id == past.first?.id ? 6 : 0)
                            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: -2))
                            .listRowSeparator(.hidden)
                    }
                } else {
                    SkeletonShape(style: .list(3))
                }
            } header: {
                // 「最近的会话」能收起，默认收起（11-21）：点标题展开 / 收起，记住
                Button { withAnimation(.snappy(duration: 0.18)) { collapse.toggle("recent.open") } } label: {
                    HStack(spacing: 4) {
                        PanelSectionTitle(title: L("最近的会话"), count: projects.past[id]?.count ?? 0)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapse.has("recent.open") ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, SideMetric.inset - 8)
            }
            .listSectionSeparator(.hidden)
        }
        // 同项目列表：plain 样式，边距全按侧栏规范自己给
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - 新版界面：项目的会话列表、文件侧栏（布局里各是一块，放在哪一栏由 KitelineModel.layoutColumns 定）

/// 项目里的一块：sessions 这个项目的会话，files 文件侧栏（顶部图标切文件 / Git / 分支 / 提交历史）。
/// 「项目」里没开着项目时不画（这一块所在的位置让给同一栏的别的块）
struct ProjectBlock: View {
    @ObservedObject var model: KitelineModel
    let block: String
    @ObservedObject private var projects = ProjectsModel.shared

    /// 现在能不能画（开着项目、没在世界模式、没在搜索）
    static func visible(_ model: KitelineModel) -> Bool {
        // 选了项目就有（不管左边导航栏看的是哪一栏），没选项目、世界模式、搜索时没有
        !model.worldMode && model.query.isEmpty && model.projectPane != nil
    }

    var body: some View {
        if Self.visible(model), let id = model.projectPane {
            let place = projects.fileMember(id).map { ($0.sourceId, $0.cwd) } ?? ProjectsModel.place(id) ?? ("", "")
            let members = projects.members(id)
            // 按最近活动排（行上显示的就是这个时间；11-21 反馈：昨天的排在中间不对），标记、置顶的在前
            let live = model.recentFirst(members.count > 1 ? projects.live(group: members)
                : model.sessions.filter { $0.sourceId == place.0 && $0.cwd == place.1 })
            let key = projects.codeKey(ProjectsModel.id(sourceId: place.0, cwd: place.1))
            Group {
                if block == "sessions" {
                    ProjectSessions(model: model, id: id, live: live, place: place, starting: key == nil)
                } else if let key {
                    TarsProjectSide(key: key, sessions: nil, sessionCount: 0, barOnTop: true, open: { tab in
                        projects.startOnSessions.remove(id)
                        model.selection = tab   // 开在分屏里（KitelineModel.selection → panes.show），右边是整页时也回到分屏
                    }) { _ in }
                    .id(key)
                } else {
                    Text("正在打开会话，文件和 Git 稍后显示…").font(.app(size: 11.5)).foregroundStyle(.secondary)
                        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .scrollContentBackground(.hidden)
            .modifier(SidebarPanel(title: block == "sessions" ? L("会话") : L("文件")))
            .id(id)
            // 最近的会话：新版界面里这一块自己去取（原来只有旧的项目二级栏取，这里一直是占位）
            .task(id: id) {
                if block == "sessions" { projects.loadPast(id) }
                if !projects.loaded { projects.load() }
            }
        }
    }
}

// MARK: - 打开项目

/// 「打开项目」（11-20）：选电脑和文件夹、选 Agent，直接打开——在那个文件夹里开好一个会话等你说话，
/// 左边切到这个项目的二级侧边栏。不用先写任务（要先写好任务再开的，用「新任务」）
struct OpenProjectSheet: View {
    @ObservedObject private var model = KitelineModel.shared
    @AppStorage("listSource") private var listSource = ""
    @State private var sourceId = ""
    @State private var path = ""
    @State private var agent = "claude-code"
    /// 每台电脑上除了 Claude Code 还能后台运行哪几家（问过的记着）
    @State private var launchable: [String: [NewTaskSheet.LaunchAgent]] = [:]
    @State private var browsing: Browse?
    @State private var opening = false
    @State private var message: String?

    struct Browse: Identifiable {
        let source: SourceConfig
        let start: String
        var id: String { source.id }
    }

    private var targets: [SourceConfig] { AppState.shared.liveSources.map(\.config) }
    private var source: SourceConfig? { targets.first { $0.id == sourceId } }
    private var agents: [NewTaskSheet.LaunchAgent] {
        [NewTaskSheet.LaunchAgent(id: "claude-code", name: Agents.info("claude-code").name, viaUI: false)] + (launchable[sourceId] ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择项目所在的文件夹和要使用的 Agent，Kiteline 会在其中打开一个会话；项目的文件、Git 和会话显示在左侧栏中。")
                .font(.app(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
                if targets.count > 1 {
                    GridRow {
                        Text("电脑").foregroundStyle(.secondary)
                        Picker("电脑", selection: $sourceId) {
                            ForEach(targets, id: \.id) { Text(verbatim: ServerLang.machine($0.displayName)).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                GridRow {
                    Text("文件夹").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(path.isEmpty ? Color.secondary : Color.tarsBrand)
                        Text(verbatim: path.isEmpty ? L("未选择") : path)
                            .foregroundStyle(path.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 6)
                        Button(path.isEmpty ? L("选择…") : L("更换…")) { browse() }.tarsButton()
                    }
                }
                GridRow(alignment: .top) {
                    Text("Agent").foregroundStyle(.secondary).padding(.top, 7)
                    VStack(spacing: 4) {
                        ForEach(agents) { choice in
                            let on = agent == choice.id
                            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                            Button { agent = choice.id } label: {
                                HStack(spacing: 8) {
                                    AgentGlyph(choice.id, size: 15)
                                    Text(verbatim: choice.name).lineLimit(1)
                                    Spacer(minLength: 6)
                                    if on { Image(systemName: "checkmark").font(.app(size: 11, weight: .bold)).foregroundStyle(Color.tarsBrand) }
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(on ? Color.tarsBrand.opacity(0.14) : Color.primary.opacity(0.05), in: shape)
                                .overlay { if on { shape.strokeBorder(Color.tarsBrand.opacity(0.32), lineWidth: 1) } }
                                .contentShape(shape)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
            .font(.app(size: 13))
            if let message {
                Text(message).font(.app(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { model.showOpenProject = false }.keyboardShortcut(.cancelAction).tarsButton()
                Button(opening ? L("正在打开…") : L("打开")) { open() }
                    .keyboardShortcut(.defaultAction)
                    .tarsButton(prominent: true)
                    .disabled(opening || path.isEmpty || source == nil)
            }
        }
        .padding(DialogMetric.pad)   // 弹窗边距规范
        .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity, alignment: .top)
        .navigationTitle(L("打开项目"))   // 放进面板的标题栏
        .onAppear {
            // 左边栏正筛着的那台电脑优先，其次本机
            let live = targets
            sourceId = (live.first { $0.id == listSource } ?? live.first { $0.kind == .local } ?? live.first)?.id ?? ""
            askAgents()
            // 少点一下：面板一开就让你选文件夹（测试实例不自动弹，系统的选文件夹框会出现在用户屏幕上）
            if !AppConfig.isolated { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if path.isEmpty, browsing == nil { browse() } } }
        }
        .onChange(of: sourceId) { old, _ in
            if !old.isEmpty { path = "" }   // 换了电脑：原来选的文件夹不在这台上
            if !agents.contains(where: { $0.id == agent }) { agent = "claude-code" }
            askAgents()
        }
        .sheetPanel(item: $browsing) { target in
            TarsFolderPicker(sourceId: target.source.id, machine: ServerLang.machine(target.source.displayName), start: target.start) { picked in
                path = picked
            }
        }
    }

    /// 这台电脑上还能选哪几家 agent（装着、能在后台运行的）：问一次记着
    private func askAgents() {
        let id = sourceId
        guard !id.isEmpty, launchable[id] == nil else { return }
        Hosted.launchable(sourceId: id) { rows in
            let found = rows.compactMap { row -> NewTaskSheet.LaunchAgent? in
                guard let agent = row["id"] as? String, !agent.isEmpty, agent != "claude-code" else { return nil }
                // 经它自己的界面新建的桌面应用要有一句话才开得出会话，这里只列能直接在后台开起来的
                guard row["via"] as? String != "ui" else { return nil }
                return NewTaskSheet.LaunchAgent(id: agent, name: row["name"] as? String ?? agent, viaUI: false)
            }
            DispatchQueue.main.async { launchable[id] = found }
        }
    }

    /// 本机：系统的选文件夹框（能新建文件夹）；远端：Kiteline 自己的浏览面板。都从这台电脑常放项目的文件夹开始（同「新任务」）
    private func browse() {
        guard let source else { return }
        let start = FolderStart.usual(ProjectsModel.shared.projects.filter { $0.sourceId == source.id }.map(\.cwd))
        let inApp = AppConfig.isolated && ProcessInfo.processInfo.environment["CCPULSE_TEST_BROWSE_LOCAL"] == "1"
        guard source.kind == .local, !inApp else {
            browsing = Browse(source: source, start: start)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("选择")
        panel.message = L("选择项目所在的文件夹")
        if !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { path = url.path }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// 在选的文件夹里开一个会话（不带任务，等你说话），开出来就收起面板、左边切到这个项目的二级侧边栏
    private func open() {
        guard let source, !path.isEmpty, !opening else { return }
        opening = true
        message = nil
        let cwd = path
        let finish: (NewSession.Outcome) -> Void = { outcome in
            opening = false
            guard outcome.ok else { message = outcome.message; return }
            let projects = ProjectsModel.shared
            let id = ProjectsModel.id(sourceId: source.id, cwd: cwd)
            projects.adopt(sourceId: source.id, sourceName: source.displayName, cwd: cwd)
            projects.startOnSessions.insert(id)
            projects.selectWhenReady.insert(id)
            model.showOpenProject = false
            model.openProject(id)
        }
        if agent == "claude-code" {
            NewSession.start(source: source, cwd: cwd, prompt: "", submit: false, completion: finish)
        } else {
            MobileServer.startAgent(source, cwd: cwd, prompt: "", submit: false, sessionId: nil, agent: agent, accepted: { _ in }) { outcome in
                DispatchQueue.main.async { finish(outcome) }
            }
        }
    }
}
