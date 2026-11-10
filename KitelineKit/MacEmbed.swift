#if KITELINE_MAC
import SwiftUI

/// Mac App 主窗口里的原生对话页：和手机 App 同一套代码（这个文件只在给 Mac 编的时候编进来）。
/// Mac App 只用这里公开的几样：连上本机服务、某个会话的对话页、标题栏按钮要做的事
@MainActor
public enum KitelineKit {
    static var model: AppModel?

    /// 对话里点了别的会话：交给 Mac App 在左边栏选中它
    public static var openSession: (String) -> Void = { _ in }
    /// 对话里点了今日动态 / 用量 / 历史 / 项目：交给 Mac App 切到左边栏对应那一项（today / usage / history / projects）
    public static var openPage: (String) -> Void = { _ in }
    /// 常用语后面的铅笔：交给 Mac App 打开设置里的常用语
    public static var openQuickReplies: () -> Void = {}
    /// 写进 Mac App 的日志（排查界面问题时留个记录）
    public static var log: (String) -> Void = { _ in }

    /// 连本机的 Kiteline 服务（Mac App 自己起的那个）；地址或令牌变了就换一个重新连
    public static func connect(baseURL: URL, token: String) {
        if let model, model.api.token == token, model.api.base == baseURL { return }
        let next = AppModel(mac: PairedMac(name: L("本机"), addresses: [baseURL], token: token, caCertificate: nil, remote: nil), embedded: true)
        model = next
        tabGroups.attach(next.tabGroupShared)   // 标签组和电脑上存的那份同步
        next.start()
    }

    /// 标题栏上的按钮
    public enum Action: String, Sendable {
        case files, changes, tests, agents, search, stop, mode, model, goal, compact, info, agentInfo, newTask, bottom, terminal, group
    }

    /// 自测用：往某个会话的输入框里填字（测试实例按脚本截图时用）
    public static func setDraft(key: String, _ text: String) {
        model?.setDraft(key, text)
    }

    /// 自测用：和在输入框里打完字点发送一样（测试实例是 dry-run，不真的投递）；群（@group:<id>）连同附着的图发到群里
    public static func send(key: String, _ text: String) {
        guard let model else { return }
        if let id = GroupKey.id(key) {
            let chat = model.chat(key)
            model.send(ComposeGroup(id: id, recipients: .constant([])), text: text, images: chat.attachments.map { ($0.name, $0.data, $0.preview) })
            chat.attachments = []
            return
        }
        model.send(key, text: text, images: [])
    }

    /// 自测用：往输入栏附几张图（同粘贴截图、点「+」选的）
    public static func attach(key: String, _ images: [Data]) {
        guard let model else { return }
        MacComposer.attach(images, to: model.chat(key))
    }

    /// 自测用：这个会话还没回显的消息各是什么状态
    public static func pendingStates(key: String) -> String {
        guard let model else { return "-" }
        let list = model.chat(key).pending.map { "\($0.text.prefix(12))=\($0.state)" }
        return list.isEmpty ? "无" : list.joined(separator: "，")
    }

    /// 自测用：和在「模型和思考等级」里点某一档一样（level 是 auto / low / … / max）；返回现在显示的档位和发出去的 /effort 条数
    public static func setEffort(key: String, _ level: String) -> String {
        guard let model else { return "-" }
        model.setEffort(key, level: level, EffortLevel.name(level))
        return L("显示 %@，已发 /effort %@ 条", "\(model.currentEffort(key) ?? "auto")", "\(model.chat(key).pending.filter { $0.text.hasPrefix("/effort") }.count)")
    }

    /// 标题栏按钮：交给这个会话的对话页去做（打开面板、确认后中断……）
    public static func perform(_ action: Action, key: String) {
        guard let model else { return }
        let mapped: SessionAction = switch action {
        case .files: .files
        case .changes: .changes
        case .tests: .tests
        case .agents: .agents
        case .search: .search
        case .stop: .stop
        case .mode: .mode
        case .model: .model
        case .goal: .goal
        case .compact: .compact
        case .info: .info
        case .agentInfo: .agentInfo
        case .newTask: .newTask
        case .bottom: .bottom
        case .terminal: .terminal
        case .group: .group
        }
        model.externalAction = (key, mapped, UUID())
    }

    /// 自测用：直接打开对话里的某一页（"file:src/app.js"、"diff:src/app.js"、"files:src"），和在对话里点进去一样
    public static func show(_ page: String, key: String) {
        guard let model else { return }
        let parts = page.split(separator: ":", maxSplits: 1).map(String.init)
        let path = parts.count > 1 ? parts[1] : ""
        let route: Route? = switch parts[0] {
        case "file": .file(key: key, path: path)
        case "diff": .diff(key: key, path: path, commit: nil, title: (path as NSString).lastPathComponent)
        case "files": .files(key: key, path: path)
        case "changes": .changes(key)
        case "branches": .code(key: key, start: .branches)
        case "history": .code(key: key, start: .history)
        case "commit": .commit(key: key, hash: path)
        case "codediff": .codeDiff(key: key, path: path, mode: nil, commit: nil, oldPath: nil)
        default: nil
        }
        if let route { model.externalRoute = (key, route, UUID()) }
    }

    /// 自测用：在当前块打开看大图（本机的一张图），之后用 zoom 调缩放
    public static let previewImageNote = Notification.Name("TarsPreviewImage")
    public static func previewImage(_ data: [Data]) {
        NotificationCenter.default.post(name: previewImageNote, object: data)
    }

    /// 自测用：调开着的看大图的缩放（in / out / fit / actual / 倍数），返回现在的倍数
    public static func zoom(_ command: String) -> String {
        guard let control = ZoomControl.current else { return "没有开着的看大图" }
        switch command {
        case "in": control.zoomIn()
        case "out": control.zoomOut()
        case "fit": control.fit()
        case "actual": control.actualSize()
        default: if let value = Double(command) { control.set(CGFloat(value)) }
        }
        return "\(control.percent)\(control.fitting ? "（适合窗口）" : "")"
    }

    /// 自测用：弹一条底部小提示
    public static func flash(_ text: String) { model?.flash(text) }
    /// 自测用：模拟的滑动直接交给滚动视图、不经过事件队列，先记成「人在滚」（见 MacScrollInput）
    public static func noteScrollInput() { MacScrollInput.note() }
    /// 自测截图用：正显示着的底部小提示
    public static var toastView: NSView? { MacToast.view }

    /// 历史搜索点了某条命中：打开对话后滚到那条
    public static func jump(key: String, itemId: String) {
        model?.jumpRequests[key] = itemId
    }

    /// 自测用：收藏这个会话里最后一条文字回复、最后一条带图的消息（同在对话里点「收藏」），返回收藏了哪几条
    public static func favoriteLatest(key: String) -> String {
        guard let model else { return "-" }
        let items = model.chat(key).items.values.sorted(by: ChatItem.ordered)
        var picked: [String] = []
        if let text = items.last(where: { $0.t == "text" && !($0.text ?? "").isEmpty }) {
            model.addFavorite(key: key, item: text, mine: false)
            picked.append(text.id)
        }
        if let image = items.last(where: { !($0.images ?? []).isEmpty }) {
            model.addFavorite(key: key, item: image, mine: image.t == "user")
            picked.append(image.id)
        }
        return picked.joined(separator: ", ")
    }

    /// 消息翻译的设置存在哪份偏好里（App 的 AppConfig.defaults：测试实例是隔离的那份）
    public nonisolated static func useTranslatorDefaults(_ defaults: UserDefaults) {
        // 只在主线程调用（启动、换外观时的 AppAppearance.apply）
        nonisolated(unsafe) let store = defaults
        MainActor.assumeIsolated { Translator.shared.use(store) }
    }

    /// 自测用：点这个会话最后一条文字回复下面的「翻译」（configured = 跳过第一次的设置弹窗；engine 换翻译服务），返回点的是哪条
    public static func translateLatest(key: String, configured: Bool = true, engine: String? = nil) -> String {
        guard let model else { return "-" }
        let items = model.chat(key).items.values.sorted(by: ChatItem.ordered)
        guard let item = items.last(where: { BotText.translatable($0) != nil }), let text = item.text else { return "-" }
        let translator = Translator.shared
        if let engine, let value = Translator.Engine(rawValue: engine) { translator.engine = value }
        translator.configured = configured
        translator.tap(item.id, text: text)
        return item.id
    }

    /// 自测用：打开 / 关闭「自动翻译」（engine 换翻译服务）
    public static func setAutoTranslate(_ on: Bool, engine: String? = nil) {
        if let engine, let value = Translator.Engine(rawValue: engine) { Translator.shared.engine = value }
        Translator.shared.configured = true
        Translator.shared.auto = on
    }

    /// 自测用：翻译状态（每条：working / done / failed:原因 / original）
    public static var translateStates: String { Translator.shared.debugStates }

    /// 自测用：点收藏页第 index 条的「原消息」
    public static func openFavorite(_ index: Int) -> String {
        guard let model else { return "-" }
        let items = model.favorites.items.sorted { $0.at > $1.at }
        guard items.indices.contains(index) else { return "没有第 \(index) 条" }
        let item = items[index]
        model.openSource(key: item.key, itemId: item.itemId, open: OpenRoute { route in if case .chat(let key) = route { openSession(key) } })
        return "\(item.title) / \(item.itemId)"
    }

    /// 左边栏「收藏」那一格：收藏了几条
    public static var favoriteCount: Int { model?.favorites.items.count ?? 0 }

    /// 左边栏「待办」那一行：几件没做完、几件 Claude 刚说要你做还没加的
    public static var todoCounts: (open: Int, suggested: Int) {
        guard let model else { return (0, 0) }
        return (model.todos.openCount, model.todos.suggestions.reduce(0) { $0 + $1.asks.count })
    }
}

/// 左边栏「今日用量」大卡片、用量页顶上的额度条（同手机首页）：传 Limits.collect 汇总出的 JSON
public struct TarsLimitsBoard: View {
    private let devices: [LimitDevice]
    private let compact: Bool
    private let wide: Bool

    /// compact：侧栏那样的窄处，字小一号；wide：用量页那样的宽页面，一台电脑一栏并排放
    public init(json: Data?, compact: Bool = true, wide: Bool = false) {
        devices = json.flatMap { try? JSONDecoder().decode(LimitsPayload.self, from: $0) }?.devices ?? []
        self.compact = compact
        self.wide = wide
    }

    /// 哪台电脑都还没有额度读数（没用订阅登录、电脑端插件还没装上）
    public var isEmpty: Bool { devices.isEmpty }

    /// 手动刷新后的提示（有电脑一阵子没回复、读数没变时说明一句）
    public var refreshedNote: String { LimitsPayload.refreshedNote(devices) }

    public var body: some View {
        LimitsBoard(devices: devices, compact: compact, wide: wide).tint(Theme.claude)
    }
}

/// 左边栏「待办」页：和手机同一个页面；点来源 = 左边栏选中那个会话、滚到那条消息
public struct TarsTodosView: View {
    public init() {}

    public var body: some View {
        if let model = KitelineKit.model {
            NavigationStack {
                TodosView()
                    .font(.ui(.body))
                    .tint(Theme.claude)
            }
            .environment(model)
            .environment(\.openRoute, OpenRoute { route in
                if case .chat(let key) = route { KitelineKit.openSession(key) }
            })
            .panelAnchor(key: "todos")   // 加待办、改待办、看截图的面板对着待办页居中
        } else {
            ProgressView()
        }
    }
}

/// 设置 → 来源里「后台运行 Claude Code」：按设备检测出口 IP、确认开启（和手机、会话页提示点开的同一个面板）；sourceId = 只看这一台
public struct TarsHostedSetupView: View {
    let sourceId: String?
    public init(sourceId: String? = nil) { self.sourceId = sourceId }

    public var body: some View {
        if let model = KitelineKit.model {
            HostedSetupSheet(sourceId: sourceId)
                .font(.ui(.body))
                .tint(Theme.claude)
                .environment(model)
        } else {
            ProgressView().padding(40)
        }
    }
}

/// 左边栏「收藏」页：和手机同一个页面；点「原消息」= 左边栏选中那个会话、滚到那条消息
public struct TarsFavoritesView: View {
    public init() {}

    public var body: some View {
        if let model = KitelineKit.model {
            NavigationStack {
                FavoritesView()
                    .font(.ui(.body))
                    .tint(Theme.claude)
            }
            .environment(model)
            .environment(\.openRoute, OpenRoute { route in
                if case .chat(let key) = route { KitelineKit.openSession(key) }
            })
            .panelAnchor(key: "favorites")   // 看大图的面板对着收藏页居中
        } else {
            ProgressView()
        }
    }
}

// MARK: - 会话群（Views/GroupViews.swift）

extension KitelineKit {
    /// 连着的 Kiteline 服务能拉群（左边栏、右键菜单按它给入口）
    public static var groupsSupported: Bool { model?.supportsGroups ?? false }

    /// 自测用：现在的群（新的在前）
    public static var groupIDs: [String] { model?.groups.items.map(\.id) ?? [] }

    /// 自测用：之后打开的群聊页直接展开成员面板
    public static func showGroupMembersOnOpen() { GroupChatView.startWithMembers = true }

    /// 自测用：和点标签栏上群的按钮一样（members / add / rename / disband）
    public static func groupAction(_ id: String, _ name: String) {
        let action: GroupAction? = ["members": .members, "add": .add, "rename": .rename, "disband": .disband][name]
        if let action { model?.groupAction = (id, action, UUID()) }
    }

    /// 对话页、群聊页里点了会话 / 群：会话交给左边栏选中，群切到群聊页（选中值 @group:<id>）
    static var groupRoutes: OpenRoute {
        OpenRoute { route in
            switch route {
            case .chat(let key): KitelineKit.openSession(key)
            case .group(let id): KitelineKit.openPage("group:" + id)
            case .groups: KitelineKit.openPage("groups")
            default: break
            }
        }
    }
}

/// 左边栏会话列表里的「会话群」一组（同「标记」、按项目分的组，排在会话前面）：进行中的群一行一个，点了同会话一样开成右边分屏的一个标签
///（选中值 @group:<id>），拖到右边哪一块的哪一边就放到哪；把会话拖到群上 = 加进这个群。成员都关了的收成「历史群」一行。
/// 筛着设备、项目、状态或在搜索时：只留有成员在筛出来的会话里的群（搜索也认群名）；筛「标记」时只留标记的群
public struct TarsGroupSidebarSection: View {
    @Binding var selection: String?
    let filter: TarsGroupFilter
    /// 「群」页签里：不要「会话群」组头（页签已经写着了）
    let headerless: Bool

    public init(selection: Binding<String?>, filter: TarsGroupFilter, headerless: Bool = false) {
        _selection = selection
        self.filter = filter
        self.headerless = headerless
    }

    public var body: some View {
        if let model = KitelineKit.model {
            GroupSidebarRows(selection: $selection, filter: filter, headerless: headerless).environment(model)
        }
    }
}

/// 左边栏怎么筛群：keys = 筛出来的会话（nil = 没在筛）；markedOnly = 筛着「标记」；query = 搜索词
public struct TarsGroupFilter: Equatable {
    let keys: Set<String>?
    let markedOnly: Bool
    let query: String

    public init(keys: Set<String>?, markedOnly: Bool, query: String) {
        self.keys = keys
        self.markedOnly = markedOnly
        self.query = query.trimmingCharacters(in: .whitespaces)
    }

    var active: Bool { keys != nil || markedOnly || !query.isEmpty }

    func keeps(_ group: GroupInfo) -> Bool {
        if markedOnly && !group.marked { return false }
        if !query.isEmpty && group.name.localizedCaseInsensitiveContains(query) { return true }
        guard let keys else { return query.isEmpty }
        return markedOnly || group.members.contains { keys.contains($0.key) }
    }
}

extension KitelineKit {
    /// 左边栏这样筛时「会话群」一组有没有东西（有的话下面不分组的会话也写个「会话」组头，免得看着像群里的）
    /// 进行中的群有几个（「群」页签上的数字）
    public static var liveGroupCount: Int {
        guard let model else { return 0 }
        return model.groups.items.filter { model.isLive($0) }.count
    }

    public static func groupSectionShown(_ filter: TarsGroupFilter) -> Bool {
        guard let model, model.supportsGroups else { return false }
        return model.groups.items.contains { filter.active ? model.isLive($0) && filter.keeps($0) : true }
    }

    /// 分屏标签是群时：群名、小字（几个成员，历史群标出来）；不是群给 nil
    public static func groupTitle(_ key: String) -> (title: String, subtitle: String)? {
        guard let id = GroupKey.id(key), let model else { return nil }
        guard let group = model.groups.group(id) else { return (L("群已解散"), "") }
        return (group.name, [L("会话群 · %lld 个成员", group.members.count), model.isLive(group) ? "" : L("历史群")]
            .filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

private struct GroupSidebarRows: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    let filter: TarsGroupFilter
    var headerless = false
    /// 右键点了「解散群」、等确认的那个
    @State private var disbanding: String?

    var body: some View {
        if model.supportsGroups, !model.groups.items.isEmpty {
            let live = model.groups.items.filter { model.isLive($0) && filter.keeps($0) }
            let past = filter.active ? 0 : model.groups.items.filter { !model.isLive($0) }.count
            if !live.isEmpty || past > 0 {
                Section {
                    ForEach(live) { row($0) }
                    if past > 0 {
                        Button { selection = "@groups" } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text(L("历史群 %lld 个", count: past))
                                Spacer()
                            }
                            .font(.app(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("成员会话都已关闭的群。在群里发消息，会在原来的项目里恢复它们接着协作。"))
                    }
                } header: {
                    // 同别的组头（「标记」、按项目分的组）：图标、组名，右边个数
                    if !headerless {
                        HStack(spacing: 6) {
                            Image(systemName: "person.2.fill")
                            Text("会话群").lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(live.count)").monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func row(_ group: GroupInfo) -> some View {
        let key = GroupKey.make(group.id)
        let card = SessionCard(group: group, model: model)
        return GroupRow(group: group, compact: true)
            .modifier(GroupRowHighlight(selected: selection == key) { selection = key })
            // 同会话行：拖到右边哪一块的哪一边就放到哪
            .onDrag { PaneDrag.provider(key: key, card: card) } preview: { card.opacity(0.92) }
            .groupDrop(key: "", enabled: true, label: L("松开加入群")) { dragged in
                if group.member(dragged) == nil { Task { await model.addToGroup(group.id, keys: [dragged]) } }
            }
            .contextMenu {
                Button(L("打开群聊")) { selection = key }
                if !KitelineKit.panes.keys.contains(key) {
                    Button(L("在右侧分屏打开")) { openSplit(key, down: false) }
                    Button(L("在下方分屏打开")) { openSplit(key, down: true) }
                }
                Divider()
                GroupMenuItems(group: group) { disbanding = group.id }
            }
            .confirmPanel(GroupDisband.message, isPresented: Binding(get: { disbanding == group.id }, set: { if !$0 { disbanding = nil } }),
                          confirm: L("解散群"), destructive: true) {
                Task { await model.deleteGroup(group.id) }
            }
    }

    private func openSplit(_ key: String, down: Bool) {
        if KitelineKit.openSplit(key, down: down) {
            selection = key
        } else {
            KitelineKit.flash(L("右侧空间不足，无法继续分屏：请先关闭一个分屏，或放大窗口"))
        }
    }
}

/// 群那一行的选中、悬停：同左边栏会话行（淡品牌色底 + 细边，指着浅浅一层）
private struct GroupRowHighlight: ViewModifier {
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .padding(.horizontal, 7)
            .background(selected ? Theme.claude.opacity(0.14) : Color.primary.opacity(hovering ? 0.05 : 0), in: shape)
            .overlay { if selected { shape.hairlineBorder(Theme.claude.opacity(0.32), width: 1) } }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onTapGesture(perform: select)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
    }
}

/// 分屏里的一个群（同会话一样是一个标签）：群聊页 + 点到的会话、群交给左边栏；弹的面板对着这一块居中
struct MacGroupPane: View {
    let id: String

    var body: some View {
        GroupChatView(id: id)
            .font(.ui(.body))
            .tint(Theme.claude)
            .environment(\.openRoute, KitelineKit.groupRoutes)
            .panelAnchor(key: GroupKey.make(id))
    }
}

/// 右边的「会话群」页（进行中 + 历史群；左边栏选中 @groups）
public struct TarsGroupsView: View {
    public init() {}

    public var body: some View {
        if let model = KitelineKit.model {
            NavigationStack {
                GroupsView().font(.ui(.body)).tint(Theme.claude)
            }
            .environment(model)
            .environment(\.openRoute, KitelineKit.groupRoutes)
            .panelAnchor(key: "groups")
        } else {
            ProgressView()
        }
    }
}

/// 拉群面板（左边栏右键「拉群协作」、把会话拖到另一个会话上）：keys 是先勾上的会话；建好后 done(群 id)
public struct TarsGroupPicker: View {
    let keys: [String]
    let done: (String) -> Void

    public init(keys: [String], done: @escaping (String) -> Void) {
        self.keys = keys
        self.done = done
    }

    public var body: some View {
        if let model = KitelineKit.model {
            GroupPickerSheet(mode: .create(keys), done: done).environment(model).tint(Theme.claude)
        }
    }
}

extension View {
    /// 左边栏的会话行：别的会话拖到它上面松开 = 拉这两个会话建群（交给 perform(拖来的会话)）
    public func tarsGroupDrop(key: String, perform: @escaping (String) -> Void) -> some View {
        groupDrop(key: key, enabled: KitelineKit.groupsSupported, perform: perform)
    }
}

/// 更新记录窗口：和手机同一个时间轴页面（ChangelogTimeline）；Mac 直接给 App 里打包的 CHANGELOG.md，不经网络、不开浏览器
/// 自测截图用：「加入待办」面板（从某条消息加一条），可带几张图
public struct TarsTodoEditorPreview: View {
    let text: String
    let source: String
    let images: [Data]

    public init(text: String, source: String, images: [Data] = []) {
        self.text = text
        self.source = source
        self.images = images
    }

    public var body: some View {
        if let model = KitelineKit.model {
            let request = AddTodosRequest(key: "preview", itemId: "preview", title: source, ts: (Date().timeIntervalSince1970 - 600) * 1000, candidates: [text])
            TodoEditor(target: .fromMessage(request), attach: images)
                .font(.ui(.body))
                .tint(Theme.claude)
                .environment(model)
        }
    }
}

public struct TarsChangelogView: View {
    let releases: [ChangelogRelease]
    let version: String

    public init(markdown: String, version: String) {
        releases = Changelog.parse(markdown)
        self.version = version
    }

    public var body: some View {
        if releases.isEmpty {
            ContentUnavailableView(L("此版本未包含更新记录"), systemImage: "doc.text")
        } else {
            ScrollView {
                ChangelogTimeline(releases: releases, current: version)
                    .padding(.horizontal, 40)
                    .padding(.top, 32)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .font(.ui(.body))
            .tint(Theme.claude)
        }
    }
}

/// 某个会话的对话页（正在跑的、已经结束的都行）
public struct TarsConversationView: View {
    let key: String

    public init(key: String) { self.key = key }

    public var body: some View {
        if let model = KitelineKit.model {
            MacConversation(key: key).environment(model).id(key)
        } else {
            ProgressView()
        }
    }
}

/// 世界模式左下角对话框（网页里）的私聊：发消息、听写都交给这里，和会话页同一套（排队、回显、失败重试、本机语音识别）
@MainActor
public enum TarsWorldChat {
    private static var recorder: VoiceRecorder?

    /// 发一条；images 是原图（粘贴的截图），同会话页压成 JPEG，最多 6 张
    public static func send(key: String, text: String, images: [Data]) -> Bool {
        guard let model = KitelineKit.model else { return false }
        let list = images.prefix(6).compactMap { ImagePrep.prepare($0) }.enumerated()
            .map { (name: "image-\($0.offset + 1).jpg", data: $0.element.jpeg, preview: $0.element.preview) }
        return model.send(key, text: text, images: list) != nil
    }

    /// 开始听写（第一次会弹麦克风授权）
    public static func startDictation() async -> Bool {
        let current = recorder ?? VoiceRecorder()
        recorder = current
        return await current.start()
    }

    public static var recording: Bool { recorder?.recording ?? false }
    public static var level: Double { recorder?.levels.last ?? 0 }
    public static var elapsed: Double { recorder?.elapsed ?? 0 }

    /// 结束听写并转成文字：nil = 放弃或没录上；空 = 太短或没听清
    public static func finishDictation(cancel: Bool) async -> String? {
        guard let current = recorder, let clip = current.stop(cancel: cancel), !cancel else { return nil }
        guard clip.duration >= 0.8 else { return "" }
        return await KitelineKit.model?.transcribe(clip.data) ?? ""
    }
}

/// 世界模式里浮着的那一个会话：自己一份只有一块的分屏（不动主窗口的分屏布局），只放这一个会话；
/// 标题条、按钮、对话排版和主窗口右边完全一样。换了会话外面用 .id(key) 重建
public struct TarsSessionCard: View {
    let key: String
    let accessory: TarsPaneAccessory?
    @State private var panes: ChatPanes

    public init(key: String, accessory: TarsPaneAccessory?) {
        self.key = key
        self.accessory = accessory
        let panes = ChatPanes()
        panes.show(key)
        _panes = State(initialValue: panes)
    }

    public var body: some View {
        if let model = KitelineKit.model {
            ChatPanesView(panes: panes) { key in
                TarsConversationView(key: key)
            }
            .environment(\.paneAccessory, accessory)
            .environment(model)
        } else {
            ProgressView()
        }
    }
}

/// 对话页 + 弹出的面板（文件、改动、测试……，打开时 640 宽，能拖动、改大小），面板里还能再点进去
private struct MacConversation: View {
    let key: String
    @Environment(AppModel.self) private var model
    /// 分屏时：底部小提示、「仍然要发吗」只由当前块弹（不然几块各弹一个）
    @Environment(\.chatPane) private var pane
    @State private var panel: Panel?
    @State private var chatFrame: CGRect = .zero
    /// 自测用：直接看一张本机的图（KitelineKit.previewImage）
    @State private var preview: PreviewImage?

    struct Panel: Identifiable {
        let id = UUID()
        let route: Route
    }

    struct PreviewImage: Identifiable {
        let id = UUID()
        let data: [Data]
    }

    var body: some View {
        ChatView(key: key)
            .font(.ui(.body))   // 没写字号的字（正文、我发的消息）：Mac 上默认 13，照网页版用 14
            // 没指定样式的按钮：Mac 默认是带边框的系统按钮，照手机 / 网页版改成一行品牌橙的字。
            // 不用系统的 .borderless：挂在整页上时，整页消息里的字都选不中、复制不了（10-24 实测）
            .buttonStyle(ChatLinkButtonStyle())
            .tint(Theme.claude)
            .environment(\.openRoute, OpenRoute { route in
                switch route {
                case .chat(let other): KitelineKit.openSession(other)
                case .today: KitelineKit.openPage("today")
                case .usage: KitelineKit.openPage("usage")
                case .history: KitelineKit.openPage("history")
                case .projects: KitelineKit.openPage("projects")
                case .todos: KitelineKit.openPage("todos")
                case .favorites: KitelineKit.openPage("favorites")
                case .groups: KitelineKit.openPage("groups")
                case .group(let id): KitelineKit.openPage("group:" + id)
                default: panel = Panel(route: route)
                }
            })
            .onChange(of: model.externalRoute?.id) { _, _ in
                guard let request = model.externalRoute, request.key == key else { return }
                model.externalRoute = nil
                panel = Panel(route: request.route)
            }
            .sheetPanel(item: $panel) { panel in
                PanelStack(root: panel.route).environment(model)
            }
            .onReceive(NotificationCenter.default.publisher(for: KitelineKit.previewImageNote)) { note in
                guard pane?.isFocused ?? true, let list = note.object as? [Data], !list.isEmpty else { return }
                preview = PreviewImage(data: list)
            }
            .sheetPanel(item: $preview) { MacImageViewer(images: $0.data.map { .local($0) }, name: $0.data.count == 1 ? "preview.png" : nil) }
            // 底部小提示（「已拷贝」「已发送 /effort」……）：放在浮在窗口上面的小窗里，面板开着时也看得见
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { chatFrame = $0 }
            .onChange(of: model.toast) { _, toast in if pane?.isFocused ?? true { MacToast.show(toast, over: chatFrame) } }
            .onDisappear { MacToast.show(nil, over: .zero) }
            // 今天的花费超了上限：问一句仍然要发吗
            .confirmPanel(model.capPrompt.map { L("%@。仍要发送吗？", "\($0.message)") } ?? "",
                          isPresented: Binding(get: { model.capPrompt != nil && pane?.isFocused ?? true }, set: { if !$0 { model.capPrompt = nil } }),
                          confirm: L("仍然发送")) {
                if let prompt = model.capPrompt { model.retry(prompt.key, prompt.id, override: true) }
                model.capPrompt = nil
            }
            // 这块会话里弹的面板（文件、改动、看大图、确认……）都对着它居中
            .panelAnchor(key: key)
    }
}

/// 对话页里没指定样式的按钮：一行强调色的字，按下变淡（样子同系统的 .borderless，但是纯 SwiftUI 画的，不挡消息里的字被选中）
struct ChatLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration)
    }

    private struct LinkLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .opacity(configuration.isPressed ? 0.55 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// 底部小提示的小窗：无边框、点不着、挂在主窗口上跟着走，压在面板（sheet）上面；对着对话区居中，离底 110（输入区上方）
@MainActor
enum MacToast {
    private static var panel: NSPanel?
    private static let host = NSHostingController(rootView: ToastBubble(text: ""))
    private static var generation = 0

    static func show(_ text: String?, over area: CGRect) {
        generation += 1
        let current = generation
        guard let text, let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            guard let panel, panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    guard current == generation else { return }   // 渐隐时又来了一条：别把新的收掉
                    panel.parent?.removeChildWindow(panel)
                    panel.orderOut(nil)
                }
            }
            return
        }
        let panel = panel ?? make()
        host.rootView = ToastBubble(text: text)
        let fit = host.sizeThatFits(in: NSSize(width: 520, height: 400))   // 长的提示最宽 520，再长换行
        let size = NSSize(width: ceil(fit.width), height: ceil(fit.height))
        let chat = area.width > 0 ? area : CGRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height)
        // 横向对着对话区居中（SwiftUI 的 global 坐标以窗口左上角为原点）
        let x = window.frame.minX + chat.midX - size.width / 2
        let y = window.frame.minY + 110   // 对话区一直铺到窗口底
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        // 每次重新挂一下：后挂的子窗口排在前面，盖得住刚弹出来的面板
        panel.parent?.removeChildWindow(panel)
        window.addChildWindow(panel, ordered: .above)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        }
    }

    private static func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        host.sizingOptions = []
        panel.contentView = host.view
        self.panel = panel
        return panel
    }

    /// 自测截图用：小提示现在的样子
    static var view: NSView? { panel?.isVisible == true ? host.view : nil }
}

private struct ToastBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.app(size: 13))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

/// 面板：自己的导航栈，点文件 → 文件内容 → 改动记录……一层层往里推
private struct PanelStack: View {
    let root: Route
    @PanelDismiss private var dismiss
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            page(root)
                .navigationDestination(for: Route.self) { page($0) }
        }
        .environment(\.openRoute, OpenRoute { route in
            if case .chat(let other) = route {
                dismiss()
                KitelineKit.openSession(other)
            } else {
                path.append(route)
            }
        })
        .modifier(PanelChrome(window: root.wideIDE) { dismiss() })
        .tint(Theme.claude)
        // 打开时 640 宽（代码 IDE 按 VS Code 那样的大小，最窄也保持宽屏布局：窄了会换成手机的分页、开着的标签就没了），之后能拖边改大小
        .frame(minWidth: root.wideIDE ? 780 : 420, idealWidth: root.wideIDE ? min(1240, MacSheetLimit.size.width) : 640, maxWidth: .infinity,
               minHeight: root.wideIDE ? 480 : 320, idealHeight: min(root.wideIDE ? 820 : 640, MacSheetLimit.size.height), maxHeight: .infinity)
    }

    /// 代码 IDE 当成正经窗口（红黄绿钮关闭、缩放），别的面板右上角「完成」
    private struct PanelChrome: ViewModifier {
        let window: Bool
        let done: () -> Void

        @ViewBuilder
        func body(content: Content) -> some View {
            if window { content.panelWindowStyle() } else { content.doneButton(done) }
        }
    }

    @ViewBuilder
    private func page(_ route: Route) -> some View {
        switch route {
        case .project(let project): ProjectDetailView(project: project)
        case .changes(let key): CodeRootView(key: key, start: .scm)
        case .diff(let key, let path, let commit, _):
            if let path { GitDiffScreen(key: key, path: path, mode: commit != nil ? "commit" : nil, commit: commit) }
            else { CommitScreen(key: key, hash: commit ?? "HEAD") }
        case .tests(let key): TestsView(key: key)
        case .files(let key, let path): CodeRootView(key: key, start: .explorer(path))
        case .file(let key, let path): CodeRootView(key: key, start: .file(path))
        case .code(let key, let start): CodeRootView(key: key, start: start)
        case .codeFile(let key, let path): CodeFileScreen(key: key, path: path)
        case .codeDiff(let key, let path, let mode, let commit, let oldPath): GitDiffScreen(key: key, path: path, mode: mode, commit: commit, oldPath: oldPath)
        case .commit(let key, let hash): CommitScreen(key: key, hash: hash)
        case .fileHistory(let key, let path): FileHistoryScreen(key: key, path: path)
        case .inbox: InboxView()
        default: ContentUnavailableView(L("在侧边栏中打开"), systemImage: "sidebar.left")
        }
    }
}
#endif
