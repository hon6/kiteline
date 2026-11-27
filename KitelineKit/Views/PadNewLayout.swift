#if os(iOS)
import SwiftUI

// iPad 新版界面（同 Mac 新版，见 Sources/NewLayout.swift / ProjectPane.swift）：左栏最左一条图标栏（会话、项目、待办、收藏，
// 下面概览、世界、数据流、AR、设置、切回经典界面），旁边一栏放选中的那一项；项目里点一个项目，同一栏换成它的会话（上）和
// 文件 / Git（下），点文件、改动在右边的分屏里开成标签，和会话标签混排。右边对话分屏照旧。
// 经典界面原样保留、仍是默认；`padNewLayout` 开关在经典界面顶栏、新版图标栏最下面。只在 iPad 横着用（左右分栏并排）时生效

extension EnvironmentValues {
    /// 新版界面左栏顶上「收起侧栏」按钮的动作（MainView 给：收起左栏只留右边）
    @Entry var padSidebar: (() -> Void)? = nil
    /// 会话行画不画头像（iPad 新版界面不画，同 Mac 新版）
    @Entry var rowAvatar = true
}

/// 新版左栏的边距（同 Mac 的 SideMetric，和项目里的文件列表一致）：选中框离栏边 8、框里 8，字离栏边 16
enum PadSide {
    static let frame: CGFloat = 8
    static let inner: CGFloat = 8
    static let text: CGFloat = 16
}

/// 左栏里一节的小标题（会话 7、活动中……），字对齐 16
struct PadSectionTitle: KLView {
    let text: String
    var klBody: some View {
        Text(text).font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, PadSide.text).padding(.top, 10).padding(.bottom, 6)
    }
}

enum PadLayout {
    static let key = "padNewLayout"
    /// 只在 iPad 上有新版界面
    static var available: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}

/// 新版界面的左栏：图标栏 + 一栏内容
struct PadNewSidebar: KLView {
    @EnvModel private var model
    @Environment(\.openRoute) private var open
    @AppStorage("padRail") private var rail = "sessions"
    @AppStorage(PadLayout.key) private var newLayout = false
    @State private var world: SessionListView.WorldCover?
    @State private var settings = false
    @State private var overview = false
    /// 项目栏里打开着的项目（id = 设备 + 目录）
    @AppStorage("padProject") private var projectID = ""

    var klBody: some View {
        HStack(spacing: 0) {
            railColumn
            // 分隔线只到顶栏下沿：别伸到搜索框后面（11-22 反馈：搜索框下面的线重叠）
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.rowAvatar, false)
        .fullScreenCover(item: $world) { cover in WorldScreen(page: cover.id).environment(\.appModelSlot, model) }
        .sheet(isPresented: $settings) { SettingsView().environment(\.appModelSlot, model) }
        .sheet(isPresented: $overview) {
            KLNavigationStack {
                OverviewPage()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { overview = false } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
                        }
                    }
            }
            // 概览里点了会话、项目……：关掉弹窗，照常在右边打开
            .environment(\.openRoute, OpenRoute { route in
                overview = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { open(route) }
            })
            .environment(\.appModelSlot, model)
            .presentationSizing(.page)
        }
    }

    @ViewBuilder private var content: some View {
        switch rail {
        case "projects": PadProjectsColumn(projectID: $projectID)
        case "todos": TodosView()
        case "favorites": FavoritesView()
        default: SessionListView()
        }
    }

    // MARK: 图标栏

    private var railColumn: some View {
        VStack(spacing: 6) {
            RailIcon(symbol: "square.and.pencil", title: L("新建会话"), on: false) { open(.newTask(NewTaskSeed())) }
                .padding(.bottom, 6)
            RailIcon(symbol: "bubble.left.and.bubble.right", title: L("会话"), on: rail == "sessions", badge: attention) { rail = "sessions" }
            RailIcon(symbol: "folder", title: L("项目"), on: rail == "projects") { rail = "projects" }
            RailIcon(symbol: "checklist", title: L("待办"), on: rail == "todos", badge: todoBadge) { rail = "todos" }
            RailIcon(symbol: "star", title: L("收藏"), on: rail == "favorites") { rail = "favorites" }
            Spacer(minLength: 12)
            // 概览弹窗显示（11-22），不占右边的标签页
            RailIcon(symbol: "square.grid.2x2", title: L("概览"), on: overview) { overview = true }
            RailIcon(symbol: "globe.asia.australia", title: L("世界"), on: false) { world = .init(id: "world") }
            RailIcon(symbol: "point.3.connected.trianglepath.dotted", title: L("数据流"), on: false) { world = .init(id: "flow") }
            RailIcon(symbol: "cube.transparent", title: L("AR 模式"), on: false) { world = .init(id: "ar") }
            RailIcon(symbol: "gearshape", title: L("设置"), on: false) { settings = true }
            RailIcon(symbol: "rectangle.split.2x1", title: L("切换到经典界面"), on: false) {
                withAnimation(.klSnappy) { newLayout = false }
            }
        }
        .padding(.vertical, 12)
        .frame(width: 60)
        .frame(maxHeight: .infinity)
    }

    /// 会话图标上的数：等你确认的 + 出错的
    private var attention: Int { model.sessions.filter { $0.isWaiting }.count }

    /// 待办图标上的数（同会话列表顶栏的待办按钮）：Claude 刚说的、还未决定是否加入的；没有就是未完成的件数
    private var todoBadge: Int {
        let fresh = model.todos.suggestions.reduce(0) { $0 + $1.asks.count }
        return fresh > 0 ? fresh : model.todos.openCount
    }
}

/// 图标栏的一格：选中时整格淡淡的主题色底（不加单边色条），右上角数字角标
private struct RailIcon: KLView {
    let symbol: String
    let title: String
    let on: Bool
    var badge = 0
    let action: () -> Void

    var klBody: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.claude : Color.secondary)
                .frame(width: 44, height: 44)
                .background(on ? Theme.claude.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(Color.red, in: Capsule())
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .hoverEffect(.highlight)
        .contextMenu { Text(title) }
    }
}

// MARK: - 项目

/// 项目栏：没打开项目时是项目列表（活动中 / 其他项目），打开了一个就换成它的会话 + 文件 / Git
struct PadProjectsColumn: KLView {
    @EnvModel private var model
    @Binding var projectID: String

    var klBody: some View {
        if let project = model.home.projects.first(where: { $0.id == projectID }) {
            PadProjectPane(project: project) { withAnimation(.klSnappy) { projectID = "" } }
                .id(project.id)
        } else {
            PadProjectList { projectID = $0.id }
                .task { await model.home.refresh(model.api) }
        }
    }
}

/// 项目列表：「活动中」（有会话开着的）在上、带「打开项目」；「其他项目」能收起
private struct PadProjectList: KLView {
    @EnvModel private var model
    @Environment(\.openRoute) private var open
    @AppStorage("padProjects.rest.open") private var restOpen = true
    let pick: (ProjectInfo) -> Void

    var klBody: some View {
        let all = model.home.projects.sorted { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }
        let active = all.filter { !lives($0).isEmpty }
        let rest = all.filter { lives($0).isEmpty }
        // 边距同项目里的会话、文件列表（PadSide）：不用系统侧栏列表，它每行左右自带十几点
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("活动中 \(active.count)").font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { open(.newTask(NewTaskSeed())) } label: {
                        Label("打开项目", systemImage: "folder.badge.plus").font(.ui(.footnote).weight(.medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(.leading, PadSide.text).padding(.trailing, PadSide.frame).padding(.top, 8).padding(.bottom, 8)
                ForEach(active) { row($0) }
                if active.isEmpty {
                    Text("暂无活动中的项目").font(.ui(.footnote)).foregroundStyle(.secondary).padding(.horizontal, PadSide.text).padding(.vertical, 6)
                }
                if !rest.isEmpty {
                    Button { withAnimation(.klSnappy(duration: 0.18)) { restOpen.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text("其他项目 \(rest.count)")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(restOpen ? 90 : 0))
                            Spacer(minLength: 0)
                        }
                        .font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, PadSide.text).padding(.top, 14).padding(.bottom, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if restOpen { ForEach(rest) { row($0) } }
                }
            }
            .padding(.bottom, 8)
        }
        .navigationTitle("项目")
        .refreshable { await model.home.refresh(model.api, force: true) }
        .overlay {
            if all.isEmpty { KLUnavailableView("暂无项目", systemImage: "folder", description: Text("在电脑上用 Claude Code 打开过的文件夹会显示在这里")) }
        }
    }

    private func lives(_ p: ProjectInfo) -> [SessionInfo] { model.sessions.filter { $0.sourceId == p.sourceId && $0.projectCwd == p.cwd } }

    private func row(_ p: ProjectInfo) -> some View {
        Button { pick(p) } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.claude.opacity(0.85))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.ui(.body)).lineLimit(1)
                    // 设备名完整显示，只截路径（拼在一起截时设备名被截掉）
                    HStack(spacing: 0) {
                        Text("\(p.sourceName) · ").fixedSize()
                        Text(Bytes.shortPath(p.cwd)).lineLimit(1).truncationMode(.head)
                    }
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                let count = lives(p).count
                if count > 0 {
                    Text("\(count)").font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .fixedSize()
                }
            }
            .padding(.horizontal, PadSide.inner).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, PadSide.frame)
    }
}

/// 打开着的项目：顶上返回 + 项目名；上面是这个项目的会话（点了在右边分屏里开），下面是文件 / Git（同 Mac 新版的文件侧栏，
/// 点文件、改动开成右边分屏里的标签）
private struct PadProjectPane: KLView {
    @EnvModel private var model
    @Environment(\.openRoute) private var open
    @AppStorage("padProject.sessionsShare") private var share = 0.4
    @State private var dragStart: Double?
    @Environment(\.listSelection) private var selection
    /// 最近的会话（这个项目里已经关掉的），同 Mac 新版：默认收起
    @AppStorage("padProject.recentOpen") private var recentOpen = false
    let project: ProjectInfo
    let back: () -> Void

    var klBody: some View {
        let lives = model.sessions.filter { $0.sourceId == project.sourceId && $0.projectCwd == project.cwd }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        let codeKey = lives.first?.key ?? project.sessionKey
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                Divider()
                sessions(lives).frame(height: max(120, (geo.size.height - 60) * share))
                splitter(total: geo.size.height - 60)
                Group {
                    if let codeKey {
                        CodePart(key: codeKey, part: .side, barOnTop: true, openTab: { tab in
                            open(.chat(CodeTabKey.from(tab, session: codeKey)))
                        })
                        .id(codeKey)
                    } else {
                        Text("这个项目还没有会话，开一个会话后显示文件和 Git").font(.ui(.footnote)).foregroundStyle(.secondary)
                            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(project.name)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回项目列表")
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.ui(.headline)).lineLimit(1)
                HStack(spacing: 0) {
                    Text("\(project.sourceName) · ").fixedSize()
                    Text(Bytes.shortPath(project.cwd)).lineLimit(1).truncationMode(.head)
                }
                .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { open(.newTask(NewTaskSeed(preset: project))) } label: {
                Image(systemName: "plus.bubble").font(.system(size: 17)).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.claude)
            .accessibilityLabel("在这个项目里新建会话")
        }
        // 返回箭头、右边按钮的图标对齐 16 点（同下面列表的字）
        .padding(.horizontal, PadSide.text - 12)
        .frame(height: 59)
    }

    /// 会话和最近的会话：不用系统列表（侧栏样式每行左右自带十几点，和下面文件列表对不齐，11-22 截图），
    /// 边距全按 PadSide：选中框离栏边 8、字离栏边 16，同下面的文件列表
    private func sessions(_ lives: [SessionInfo]) -> some View {
        let live = Set(lives.map(\.key))
        let recent = (PadRecent.shared.past[project.id] ?? []).filter { !live.contains($0.key) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                PadSectionTitle(text: L("会话 %lld", count: lives.count))
                ForEach(lives) { s in
                    Button { open(.chat(s.key)) } label: { SessionRow(session: s).padding(.horizontal, PadSide.inner) }
                        .buttonStyle(.plain)
                        .background(selection.key == s.key ? Theme.claude.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, PadSide.frame)
                }
                if lives.isEmpty {
                    Text("没有开着的会话").font(.ui(.footnote)).foregroundStyle(.secondary).padding(.horizontal, PadSide.text).padding(.vertical, 6)
                }
                if !recent.isEmpty {
                    Button { withAnimation(.klSnappy(duration: 0.18)) { recentOpen.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(L("最近的会话 %lld", count: recent.count))
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(recentOpen ? 90 : 0))
                            Spacer(minLength: 0)
                        }
                        .font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, PadSide.text).padding(.top, 14).padding(.bottom, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if recentOpen {
                        ForEach(recent.prefix(40)) { item in
                            Button {
                                model.rememberPast(item)
                                open(.chat(item.key))
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.ui(.subheadline)).lineLimit(1)
                                    Text(item.lastActive.map { Format.listTime($0) } ?? "").font(.ui(.caption)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, PadSide.inner).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, PadSide.frame)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        // 最近的会话：这个项目（这台电脑上这个目录）里关掉的；老版本电脑不认 cwd 时按目录再筛一遍
        .onAppear { PadRecent.shared.load(project, api: model.api) }
    }

    /// 上下两块之间：拖动改比例（记住）
    private func splitter(total: CGFloat) -> some View {
        ZStack {
            Divider()
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 36, height: 4)
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard total > 0 else { return }
                let base = dragStart ?? share
                dragStart = base
                share = min(0.75, max(0.2, base + value.translation.height / total))
            }
            .onEnded { _ in dragStart = nil })
    }
}
/// 项目里「最近的会话」：单独存一份（不跟视图走：打开项目时视图会重建几次，挂在视图上的请求被取消、取到的也丢了），
/// 一分钟内不重取。先按这台电脑 + 目录取；取到空的（老版本电脑不认这两个参数）再按项目名取、按目录筛
@MainActor 
final class PadRecent: KLObservable {
    let _klRegistrar = KLRegistrar.make()
    static let shared = PadRecent()
    @Tracked private(set) var past: [String: [PastSession]] = [:]
    @Tracked private var loadedAt: [String: Date] = [:]
    @Tracked private var loading: Set<String> = []

    func load(_ project: ProjectInfo, api: MacAPI) {
        let id = project.id
        if loading.contains(id) { return }
        if let at = loadedAt[id], Date().timeIntervalSince(at) < 60 { return }
        loading.insert(id)
        Task {
            defer { loading.remove(id) }
            var list: [PastSession] = []
            if let reply = try? await api.getCaching(PastSessionsReply.self, "/api/sessions", ["source": project.sourceId, "cwd": project.cwd]) {
                list = reply.sessions.filter { $0.cwd == nil || ProjectRoot.of($0.cwd) == project.cwd }
            }
            if list.isEmpty, let reply = try? await api.get(PastSessionsReply.self, "/api/sessions", ["project": project.name]) {
                list = reply.sessions.filter { ProjectRoot.of($0.cwd) == project.cwd }
            }
            if !list.isEmpty || past[id] == nil { past[id] = list.sorted { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) } }
            if !list.isEmpty { loadedAt[id] = Date() }
        }
    }
}
#endif
