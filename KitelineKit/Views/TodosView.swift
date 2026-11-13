import PhotosUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 我的待办：Claude 说要你做的事（你点了「加入待办」的）、自己记的。按出自哪条消息分组，组头就是来源，点一下跳回那条消息；
/// 做完点左边的圈打勾。最上面是 Claude 刚说的、还没决定加不加的提示
struct TodosView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @AppStorage("todosShowDone") private var showDone = false
    @State private var adding: AddTodosRequest?
    /// 记一条 / 修改：多行文字、按住说话、附截图（TodoEditor）
    @State private var editor: TodoEditor.Target?
    /// 「创建会话」：打开新建会话，内容带上这条待办
    @State private var creating: TodoItem?
    @State private var confirmClear = false
    /// 「收起久未更新的 N 条」的确认
    @State private var confirmStale = false
    /// agent 的待办怎么分组、排序、只看哪台机器（同会话列表的「显示方式」）；分组没选过就跟会话列表一样
    @AppStorage("listGrouping") private var listGrouping = "none"
    @AppStorage("todosGrouping") private var groupingChoice: String?
    @AppStorage("todosSorting") private var sorting = "status"
    @AppStorage("todosSource") private var sourceFilter = ""

    var body: some View {
        let state = model.todos
        // 我的待办（只有你能做的、你自己记的）和 agent 的待办（它自己会做，你只看进度）分开两块
        let pending = state.items.filter { !$0.done && !$0.agentTask }
        let agentAll = state.items.filter { !$0.done && $0.agentTask }
        let agentTasks = sortedAgentTasks(agentAll.filter { activeSource == nil || model.todoPlace($0).sourceId == activeSource?.id })
        let done = state.items.filter(\.done).sorted { ($0.doneAt ?? 0) > ($1.doneAt ?? 0) }
        List {
            if !state.suggestions.isEmpty {
                Section {
                    ForEach(state.suggestions.sorted { $0.at > $1.at }) { suggestionRow($0) }
                } header: {
                    HStack {
                        sectionTitle(L("需要你处理"))
                        Spacer(minLength: 8)
                        if state.suggestions.count > 1 {
                            Button { withAnimation(.snappy) { model.dismissAllAsks() } } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "xmark").font(.ui(.caption).weight(.bold))
                                    Text("全部忽略").font(.ui(.subheadline).weight(.semibold))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14).frame(height: 32)
                                .background(Theme.field, in: Capsule())
                                .overlay(Capsule().hairlineBorder(.primary.opacity(0.12)))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.steady(.plain))
                            .textCase(nil)
                        }
                    }
                }
            }
            // 我的待办（11-13 反馈难看重做，同「提醒事项」）：一组、行间细线，不再每条上面一行出处 + 一张卡；
            // 出处写在每条下面一行淡色小字（整行点一下跳到原消息），「回到会话」是这行右边的文字链接（不再是带底色的胶囊）。
            // 顺序照旧按出自哪条消息排在一起
            if !pending.isEmpty {
                Section {
                    ForEach(groups(pending).flatMap(\.items)) { row($0, showSource: true) }
                } header: {
                    if !agentAll.isEmpty || !state.suggestions.isEmpty { sectionTitle(L("我的待办")) }
                }
            }
            if !agentAll.isEmpty {
                let groups = agentGroups(agentTasks, all: agentAll)
                if groups.count == 1, groups[0].name == nil {
                    Section {
                        ForEach(agentTasks) { agentRow($0) }
                        if agentTasks.isEmpty { filteredOut }
                    } header: {
                        agentHeader(agentAll)
                    }
                } else {
                    Section {} header: { agentHeader(agentAll) }
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { agentRow($0) }
                        } header: {
                            agentGroupHeader(group)
                        }
                    }
                }
            }
            if !done.isEmpty {
                Section {
                    if showDone { ForEach(done) { row($0, showSource: true) } }
                } header: {
                    HStack {
                        Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                            HStack(spacing: 4) {
                                Text("已完成 \(done.count)")
                                Image(systemName: "chevron.right").font(.ui(.caption2).weight(.semibold))
                                    .rotationEffect(.degrees(showDone ? 90 : 0))
                            }
                        }
                        .buttonStyle(.steady(.plain))
                        Spacer()
                        if showDone { Button("清空") { confirmClear = true }.buttonStyle(.steady(.plain)) }
                    }
                    .font(.ui(.footnote).weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                }
            }
        }
        .tabBarScrollWatch()
        .overlay { if state.items.isEmpty, state.suggestions.isEmpty { emptyState } }
        // 别处（电脑、网页）勾掉 / 加了一条，推过来时行平滑挪动，不是一下跳过去
        .animation(.snappy, value: state.items.map { "\($0.id)\($0.done)" } + state.suggestions.map(\.id) + agentTasks.map(\.id))
        .navigationTitle("待办")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = .new } label: { Image(systemName: "plus") }
                    .help("新建待办")
            }
        }
        .task { await model.refreshTodos() }
        .refreshable { await model.refreshTodos() }
        .sheetPanel(item: $adding) { AddTodosSheet(request: $0) }
        .sheetPanel(item: $editor) { TodoEditor(target: $0) }
        .sheetPanel(item: $creating) { item in NewTaskView(initialText: item.task, match: model.todoOrigin(item)) }
        .confirmPanel(L("删除所有已完成的待办？"), isPresented: $confirmClear, confirm: L("清空已完成"), destructive: true) { model.clearDoneTodos() }
        // 一键收起久未更新的 agent 待办（11-13：很多早做完、早过期了，agent 没勾）：只在你确认后改
        .confirmPanel(L("把 %lld 条 3 天以上没更新的 agent 待办标为已完成？", count: staleAgentTasks.count), isPresented: $confirmStale,
                      confirm: L("全部标为已完成")) {
            for item in staleAgentTasks { model.setTodoDone(item, true) }
        }
    }

    // MARK: 一条待办

    private func row(_ item: TodoItem, showSource: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { withAnimation(.snappy) { model.setTodoDone(item, !item.done) } } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(item.done ? Theme.wechatGreen : Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.steady(.plain))
            .help(item.done ? "标为未完成" : "标为已完成")
            VStack(alignment: .leading, spacing: 4) {
                TodoContent(item: item)
                if let detail = item.detail, !detail.isEmpty, !item.done {
                    Text(detail).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(3)
                }
                if showSource, let source = item.source {
                    // 出处一行淡色小字；右边「回到会话」：打开原会话、输入框里先写好「已处理好：…」，确认后发给 agent（点整行只是跳到原消息）
                    HStack(spacing: 12) {
                        Text(sourceLine(source)).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if !item.done {
                            Button { model.replyDone(key: source.key, text: item.text, open: open) } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrowshape.turn.up.backward").font(.ui(.caption2).weight(.semibold))
                                    Text("回到会话")
                                }
                                .font(.ui(.footnote).weight(.medium))
                                .foregroundStyle(Theme.claude)
                                .padding(.vertical, 2).padding(.leading, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.steady(.plain))
                        }
                    }
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { tap(item) }
        }
        .contextMenu { menu(item) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.deleteTodos([item.id]) } label: { Label("删除", systemImage: "trash") }
            Button { edit(item) } label: { Label("修改", systemImage: "pencil") }.tint(.gray)
        }
        .swipeActions(edge: .leading) {
            Button { model.setTodoDone(item, !item.done) } label: {
                Label(item.done ? "未完成" : "已完成", systemImage: item.done ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(Theme.wechatGreen)
        }
    }

    @ViewBuilder
    private func menu(_ item: TodoItem) -> some View {
        if let handler = item.handler, item.agentTask {
            Button { open(.chat(handler.key)) } label: { Label("打开处理它的会话", systemImage: "bubble.left.and.text.bubble.right") }
        }
        if let source = item.source {
            if !item.agentTask, !item.done {
                Button { model.replyDone(key: source.key, text: item.text, open: open) } label: { Label("回到会话", systemImage: "arrowshape.turn.up.backward") }
            }
            Button { jump(source) } label: { Label("跳转到原消息", systemImage: "text.bubble") }
        }
        if item.suggestsSession {
            Button { creating = item } label: { Label("创建会话", systemImage: "plus.bubble") }
        }
        Button { model.setTodoDone(item, !item.done) } label: {
            Label(item.done ? "标为未完成" : "标为已完成", systemImage: item.done ? "circle" : "checkmark.circle")
        }
        Button { edit(item) } label: { Label("修改", systemImage: "pencil") }
        Button { Clipboard.copy(item.text) } label: { Label("复制", systemImage: "doc.on.doc") }
        Button(role: .destructive) { model.deleteTodos([item.id]) } label: { Label("删除", systemImage: "trash") }
    }

    /// 点一条：有来源就跳回那条消息；自己记的就改字
    private func tap(_ item: TodoItem) {
        if let source = item.source { jump(source) } else { edit(item) }
    }

    private func edit(_ item: TodoItem) {
        editor = .edit(item)
    }

    private func jump(_ source: TodoSource) {
        model.openSource(key: source.key, itemId: source.itemId, open: open)
    }

    // MARK: 按出自哪条消息分组

    private struct TodoGroup: Identifiable {
        let id: String
        let source: TodoSource?
        var items: [TodoItem]
        var latest: Double
    }

    /// 同一条消息里的放一组（组里按加进来的先后）；组按最近加的在上；自己记的单独一组
    private func groups(_ items: [TodoItem]) -> [TodoGroup] {
        var order: [String] = []
        var map: [String: TodoGroup] = [:]
        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) {
            let id = item.source.map { "\($0.key)|\($0.itemId)" } ?? "manual"
            if map[id] == nil {
                order.append(id)
                map[id] = TodoGroup(id: id, source: item.source, items: [], latest: 0)
            }
            map[id]?.items.append(item)
            if let latest = map[id]?.latest, latest < item.createdAt { map[id]?.latest = item.createdAt }
        }
        return order.compactMap { map[$0] }.sorted { $0.latest > $1.latest }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.ui(.footnote).weight(.medium)).foregroundStyle(.secondary).textCase(nil)
    }

    private func sourceLine(_ source: TodoSource) -> String {
        [source.title, source.ts.map { Format.listTime($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: agent 的待办：分组、排序（同会话列表的「显示方式」）

    /// 不分组 / 按来源 / 按项目 / 按 Agent，同会话列表；排序换成待办的说法
    private static var groupOptions: [(String, String)] { [("none", L("不分组")), ("source", L("按来源")), ("project", L("按项目")), ("agent", L("按 Agent"))] }
    private static var sortOptions: [(String, String)] { [("status", L("状态优先")), ("recent", L("最近更新")), ("started", L("记录时间")), ("name", L("名称"))] }

    /// 不认识的值（老版本、别处写坏的）都按默认处理
    private var grouping: String {
        let value = groupingChoice ?? listGrouping
        return Self.groupOptions.contains { $0.0 == value } ? value : "none"
    }
    private var sortKey: String { Self.sortOptions.contains { $0.0 == sorting } ? sorting : "status" }

    /// 分组、排序、机器都是默认的
    private var isDefaultView: Bool { grouping == "none" && sortKey == "status" && activeSource == nil }

    /// 筛着的那台机器（机器已经不在了就当没筛）
    private var activeSource: SourceInfo? {
        sourceFilter.isEmpty ? nil : model.sources.first { $0.id == sourceFilter }
    }

    /// 状态优先：在做的在前，没人做了的（会话已结束）垫底；最近更新 / 记录时间：新的在上；名称：按标题。最后按 id 定死先后，刷新时不互换
    private func sortedAgentTasks(_ items: [TodoItem]) -> [TodoItem] {
        func rank(_ item: TodoItem) -> Int { model.todoOrphaned(item) ? 2 : item.status == "doing" ? 0 : 1 }
        func updated(_ item: TodoItem) -> Double { item.updatedAt ?? item.createdAt }
        return items.sorted { a, b in
            switch sortKey {
            case "recent":
                if updated(a) != updated(b) { return updated(a) > updated(b) }
            case "started":
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            case "name":
                let c = a.text.localizedStandardCompare(b.text)
                if c != .orderedSame { return c == .orderedAscending }
            default:
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                if updated(a) != updated(b) { return updated(a) > updated(b) }
            }
            return a.id < b.id
        }
    }

    private struct AgentGroup: Identifiable {
        var id: String
        var name: String?
        /// 按项目分组、待办来自不止一台机器时：组名后面写哪台
        var sub: String?
        /// 按 Agent 分组时组名前画它的标志；按来源 / 按项目时画电脑 / 文件夹
        var agent: String?
        var symbol: String?
        var items: [TodoItem]
    }

    /// 组的先后跟着组里最靠前的那条走（同会话列表）；按来源时照机器的顺序，按名称排时组也按名称排
    private func agentGroups(_ items: [TodoItem], all: [TodoItem]) -> [AgentGroup] {
        guard grouping != "none", !items.isEmpty else { return [AgentGroup(id: "all", items: items)] }
        let bySource = grouping == "source"
        let byAgent = grouping == "agent"
        let multi = Set(all.map { model.todoPlace($0).sourceId }).count > 1
        var order: [String] = []
        var map: [String: AgentGroup] = [:]
        for item in items {
            let place = model.todoPlace(item)
            let key = byAgent ? (place.agent ?? "") : bySource ? place.sourceId : "\(place.sourceId)\n\(place.cwd ?? "")"
            if map[key] == nil {
                order.append(key)
                let machine = place.machine ?? L("未知来源")
                map[key] = byAgent
                    ? AgentGroup(id: key, name: place.agent.map { Agents.info($0).name } ?? L("未知 Agent"), agent: place.agent,
                                 symbol: place.agent == nil ? "questionmark.circle" : nil, items: [])
                    : bySource
                        ? AgentGroup(id: key, name: machine, symbol: "desktopcomputer", items: [])
                        : AgentGroup(id: key, name: place.cwd.flatMap(Self.folder) ?? L("（未知目录）"),
                                     sub: multi ? machine : nil, symbol: "folder", items: [])
            }
            map[key]?.items.append(item)
        }
        var result = order.compactMap { map[$0] }
        if bySource {
            let ids = model.sources.map(\.id)
            result.sort { (ids.firstIndex(of: $0.id) ?? ids.count) < (ids.firstIndex(of: $1.id) ?? ids.count) }
        } else if sortKey == "name" {
            result.sort { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
        }
        return result
    }

    /// 目录的最后一节（Windows 电脑上的路径是反斜杠）
    private static func folder(_ path: String) -> String? {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
    }

    /// 「agent 的待办」这一块的标题，右边是「显示方式」（两条以上、或改过默认的才出现）
    private func agentHeader(_ all: [TodoItem]) -> some View {
        HStack(spacing: 8) {
            sectionTitle(L("agent 的待办 · 它会自己处理")).lineLimit(1)
            Spacer(minLength: 8)
            let stale = all.filter(Self.isStale).count
            if stale > 0 {
                // 收起久未更新的：确认后全部标为已完成（agent 那边 todo list 也会看到）
                Button { confirmStale = true } label: {
                    Text(L("收起久未更新的 %lld 条", count: stale)).font(.ui(.footnote).weight(.medium)).foregroundStyle(Theme.claude)
                }
                .buttonStyle(.steady(.plain))
                .textCase(nil)
            }
            if all.count > 1 || !isDefaultView { viewMenu(all) }
        }
    }

    /// 3 天以上没更新、还没做完的 agent 待办（记下、开始、进度都算更新）
    static func isStale(_ item: TodoItem) -> Bool {
        !item.done && staleDays(item) >= 3
    }

    static func staleDays(_ item: TodoItem) -> Int {
        Int(max(0, Date().timeIntervalSince1970 * 1000 - (item.updatedAt ?? item.createdAt)) / 86_400_000)
    }

    private var staleAgentTasks: [TodoItem] { model.todos.items.filter { $0.agentTask && Self.isStale($0) } }

    private func agentGroupHeader(_ group: AgentGroup) -> some View {
        HStack(spacing: 6) {
            if let agent = group.agent {
                AgentGlyph(agent, size: 13)
            } else if let symbol = group.symbol {
                Image(systemName: symbol).font(.ui(.caption))
            }
            Text(group.name ?? "").lineLimit(1)
            if let sub = group.sub { Text(sub).font(.ui(.caption)).lineLimit(1).fixedSize() }
            Spacer(minLength: 4)
            Text("\(group.items.count)").font(.ui(.caption).monospacedDigit())
        }
        .font(.ui(.footnote).weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    /// 筛着的机器上一条都没有
    private var filteredOut: some View {
        HStack(spacing: 8) {
            Text(L("%@上没有 agent 的待办", activeSource?.name ?? "")).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(L("显示全部")) { withAnimation(.snappy) { sourceFilter = "" } }
                .buttonStyle(.steady(.plain)).foregroundStyle(Theme.claude)
        }
        .font(.ui(.footnote))
    }

    /// 「显示方式」：分组、排序、机器放在一个菜单里（同会话列表）；按钮上写着现在怎么分、怎么排，改过默认的用品牌色
    private func viewMenu(_ all: [TodoItem]) -> some View {
        Menu {
            // 系统单选菜单：选中的那项左边打对号
            Picker("分组", selection: Binding(get: { grouping }, set: { value in withAnimation(.snappy) { groupingChoice = value } })) {
                ForEach(Self.groupOptions, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.inline)
            Picker("排序", selection: Binding(get: { sortKey }, set: { value in withAnimation(.snappy) { sorting = value } })) {
                ForEach(Self.sortOptions, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.inline)
            if model.sources.count > 1 {
                Picker("机器", selection: Binding(get: { activeSource?.id ?? "" }, set: { id in withAnimation(.snappy) { sourceFilter = id } })) {
                    Text("全部机器").tag("")
                    ForEach(model.sources, id: \.id) { source in
                        Text("\(source.name)（\(all.filter { model.todoPlace($0).sourceId == source.id }.count)）").tag(source.id)
                    }
                }
                .pickerStyle(.inline)
            }
            if !isDefaultView {
                Section {
                    Button { withAnimation(.snappy) { groupingChoice = "none"; sorting = "status"; sourceFilter = "" } } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        } label: {
            ViewMenuLabel(summary: viewSummary, isDefault: isDefaultView)
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("agent 待办的分组、排序与机器筛选")
        #endif
        .accessibilityLabel("显示方式：\(viewSummary)")
    }

    /// 按钮上的字：分组 · 排序（默认的不写）
    private var viewSummary: String {
        var parts: [String] = []
        if grouping != "none" { parts.append(Self.groupOptions.first { $0.0 == grouping }?.1 ?? "") }
        if sortKey != "status" { parts.append(Self.sortOptions.first { $0.0 == sortKey }?.1 ?? "") }
        if let source = activeSource { parts.append(source.name) }
        return parts.isEmpty ? L("显示方式") : parts.joined(separator: " · ")
    }

    // MARK: 还没加的提示

    /// agent 的待办：状态、进度、哪个会话在处理；点一下打开那个会话（你不用勾，agent 做完自己标）。
    /// 那个会话已经结束的标出来：没人在做了，做完了左滑勾掉，没做完长按「创建会话」接着做
    private func agentRow(_ item: TodoItem) -> some View {
        let orphaned = model.todoOrphaned(item)
        let doing = item.status == "doing" && !orphaned
        let where_ = item.handler?.title ?? item.source?.title
        return Button {
            if let key = item.handler?.key ?? item.source?.key { open(.chat(key)) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: doing ? "arrow.triangle.2.circlepath" : "circle.dashed")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(doing ? Theme.claude : Color.secondary)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.text).font(.ui(.body)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    if let progress = item.progress, !progress.isEmpty {
                        Text(progress).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(3)
                    } else if let detail = item.detail, !detail.isEmpty {
                        Text(detail).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 4) {
                        Text(orphaned ? L("会话已结束") : doing ? L("进行中") : L("待处理"))
                            .foregroundStyle(orphaned ? Color.orange : doing ? Theme.claude : Color.secondary)
                        if let where_ { Text(verbatim: "·"); Text(L("「%@」", where_)).lineLimit(1) }
                        Text(verbatim: "·")
                        Text(Format.listTime(item.updatedAt ?? item.createdAt))
                        if Self.isStale(item) {
                            // 很久没动了：多半早做完 / 过期了，agent 没勾（标出来，组头可以一键收起）
                            Text(verbatim: "·")
                            Text(L("%lld 天没更新", count: Self.staleDays(item))).foregroundStyle(.orange)
                        }
                    }
                    .font(.ui(.caption))
                    .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.steady(.plain))
        .contextMenu { menu(item) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.deleteTodos([item.id]) } label: { Label("删除", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            // agent 忘了关、或者你知道已经做完了：替它勾掉（agent 那边 todo list 也会看到已完成）
            Button { model.setTodoDone(item, true) } label: { Label("已完成", systemImage: "checkmark") }
                .tint(Theme.wechatGreen)
        }
    }

    private func suggestionRow(_ s: TodoSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.openSource(key: s.key, itemId: s.itemId, open: open) } label: {
                HStack(spacing: 6) {
                    Text(s.title).font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.listTime(s.ts ?? s.at)).font(.ui(.caption)).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").font(.ui(.caption2).weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.steady(.plain))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(s.asks.prefix(4).enumerated()), id: \.offset) { _, ask in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("·")
                        Text(ask).lineLimit(2)
                    }
                }
                if s.asks.count > 4 { Text("另有 \(s.asks.count - 4) 项").foregroundStyle(.tertiary) }
            }
            .font(.ui(.footnote))
            .foregroundStyle(.secondary)
            if let detail = s.detail, !detail.isEmpty {
                Text(detail).font(.ui(.footnote)).foregroundStyle(.tertiary).lineLimit(4)
            }
            // agent 提醒你做的事：现在处理（打开那个会话，不加进待办），或加入待办稍后处理
            HStack(spacing: 14) {
                Button {
                    if s.asks.count == 1 { Task { await model.addSuggestion(s) } }
                    else { adding = AddTodosRequest(key: s.key, itemId: s.itemId, title: s.title, ts: s.ts, candidates: s.asks) }
                } label: {
                    Text("加入待办").font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Theme.wechatGreen, in: Capsule())
                }
                .buttonStyle(.steady(.plain))
                Button("现在处理") { withAnimation(.snappy) { model.handleNow(key: s.key, itemId: s.itemId, open: open) } }
                    .buttonStyle(.steady(.plain))
                    .font(.ui(.subheadline).weight(.medium))
                    .foregroundStyle(Theme.claude)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无待办", systemImage: "checklist")
        } description: {
            Text("编程 agent 遇到只有你能做的事（如注册账号、申请密钥）时会提醒你，可以现在处理或加入待办；它自己以后要做的事会记在「agent 的待办」中。长按任意消息也可手动加入。")
        }
    }
}

// MARK: - 一条待办的内容：截图 + 文字

/// 一张截图：左边正方形缩略图、右边文字；两张以上：九宫格在上、文字在下。点图全屏看（左右滑切换）
struct TodoContent: View {
    let item: TodoItem
    @State private var viewing: Int?

    #if os(macOS)
    private let single: CGFloat = 72, gridWidth: CGFloat = 300
    #else
    private let single: CGFloat = 64, gridWidth: CGFloat = 240
    #endif

    var body: some View {
        Group {
            if item.images.count == 1 {
                HStack(alignment: .top, spacing: 10) {
                    thumb(0).frame(width: single, height: single)
                    text
                }
            } else if item.images.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                        ForEach(item.images.indices, id: \.self) { index in
                            thumb(index).aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .frame(maxWidth: gridWidth)
                    text
                }
            } else {
                text
            }
        }
        #if os(macOS)
        .sheetPanel(item: Binding(get: { viewing.map(TodoViewerIndex.init) }, set: { viewing = $0?.index })) { start in
            MacImageViewer(key: "todos", images: item.images, index: start.index, path: TodoItem.mediaPath)
        }
        #else
        .fullScreenCover(item: Binding(get: { viewing.map(TodoViewerIndex.init) }, set: { viewing = $0?.index })) { start in
            ImageViewer(key: "todos", images: item.images, index: start.index, path: TodoItem.mediaPath)
        }
        #endif
    }

    private var text: some View {
        Text(item.text)
            .font(.ui(.body))
            .strikethrough(item.done)
            .foregroundStyle(item.done ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 格子大小由底色块定，图盖在上面填满再裁掉：宽图、长图都是正方形
    private func thumb(_ index: Int) -> some View {
        Color.primary.opacity(0.06)
            .overlay { RemoteImage(path: TodoItem.mediaPath, query: TodoItem.mediaQuery(item.images[index].ref), variant: .square) }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(item.done ? 0.55 : 1)
            .contentShape(Rectangle())
            .onTapGesture { guard TouchTravel.isTap else { return }; viewing = index }
    }
}

private struct TodoViewerIndex: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - 记一条 / 修改

/// 记一条待办、修改一条：多行文字（长句子整段看得见）、按住说话转文字接在后面、附截图（相册选，或刚截的图点一下附上）
struct TodoEditor: View {
    enum Target: Identifiable {
        case new
        /// 从某条消息加一条（长按「加入待办」、只认出一件事）：带着那条消息的来源
        case fromMessage(AddTodosRequest)
        case edit(TodoItem)
        var id: String {
            switch self {
            case .new: "new"
            case .fromMessage(let request): request.id.uuidString
            case .edit(let item): item.id
            }
        }
    }

    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let target: Target
    @State private var text: String
    @State private var shots: [TodoShot]
    @State private var picks: [PhotosPickerItem] = []
    @State private var busy = false
    @State private var confirmDiscard = false
    @FocusState private var focused: Bool
    /// 剪贴板里有图：截图区多一行「粘贴」（系统输入框只粘贴文字）
    @State private var clipboardImage = false
    #if os(macOS)
    /// Mac 的截图一般在桌面 / 剪贴板，不在「照片」里：另给「选择图片文件…」
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    /// 正拖着图片经过面板：截图区描一圈强调色
    @State private var dropTargeted = false
    @State private var inputHeight: CGFloat = 96
    /// 变一下就把光标放进文字框（打开时、听写转好文字后）
    @State private var focusToken = 0
    #endif
    #if os(iOS)
    @State private var recent: RecentScreenshot.Shot?
    #endif
    /// 打开时的样子：改过了（打了字、说了话、加减了截图）就不让一划关掉，取消时问一句
    private let initialText: String
    private let initialShots: [String]

    static let maxShots = 9

    /// attach：打开时就带上的图（自测截图用）
    init(target: Target, attach: [Data] = []) {
        self.target = target
        let start: (text: String, shots: [TodoShot])
        switch target {
        case .edit(let item): start = (item.text, item.images.map { .saved($0) })
        case .fromMessage(let request): start = (request.candidates.first ?? "", [])
        case .new: start = ("", [])
        }
        initialText = start.text
        initialShots = start.shots.map(\.id)
        _text = State(initialValue: start.text)
        _shots = State(initialValue: start.shots + attach.compactMap { ImagePrep.prepare($0) }
            .map { TodoShot.new(ComposeAttachment(name: "image.jpg", data: $0.jpeg, preview: $0.preview)) })
    }

    private var dirty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != initialText.trimmingCharacters(in: .whitespacesAndNewlines)
            || shots.map(\.id) != initialShots
    }

    private var editing: TodoItem? {
        if case .edit(let item) = target { return item }
        return nil
    }

    private var request: AddTodosRequest? {
        if case .fromMessage(let request) = target { return request }
        return nil
    }

    /// 出自哪条消息（修改的取这条待办的，从消息加的取那条消息的）
    private var sourceText: String? {
        if let source = editing?.source { return L("出自「%@」", "\(source.title)") + (source.ts.map { " · " + Format.listTime($0) } ?? "") }
        if let request, let title = request.title, !title.isEmpty {
            return L("出自「%@」", "\(title)") + (request.ts.map { " · " + Format.listTime($0) } ?? "")
        }
        return nil
    }

    private var title: String { editing != nil ? L("修改待办") : (request != nil ? L("加入待办") : L("新建待办")) }
    private var confirmTitle: String { editing == nil ? L("加入") : L("保存") }

    private var canSave: Bool { !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func cancel() { if dirty { confirmDiscard = true } else { dismiss() } }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        NavigationStack {
            Form {
                Section {
                    TextField("待办内容", text: $text, axis: .vertical)
                        .lineLimit(4...14)
                        .focused($focused)
                    // 说出来转成文字接在后面（同新任务、对话页的「转文字」）
                    HoldToDictate { said in text = Dictation.append(said, to: text) }
                        .listRowSeparator(.hidden)
                } footer: { Group {
                        if let sourceText { Text(request != nil ? sourceText + "，加入后轻点即可跳转到原消息" : sourceText) }
                    }
                    .font(.ui(.footnote))
                }
                Section {
                    if !shots.isEmpty { strip }
                    if let recent, shots.count < Self.maxShots { recentRow(recent) }
                    if clipboardImage, shots.count < Self.maxShots { pasteRow }
                    PhotosPicker(selection: $picks, maxSelectionCount: max(1, Self.maxShots - shots.count), matching: .images) {
                        Label(shots.isEmpty ? "附截图" : "继续添加", systemImage: "photo.on.rectangle")
                    }
                    .disabled(shots.count >= Self.maxShots)
                } header: {
                    Text("截图").font(.sectionHeader)
                } footer: {
                    Text("最多 \(Self.maxShots) 张。单张时显示在文字左侧，多张时以九宫格排列于文字下方；轻点图片可放大查看。")
                        .font(.ui(.footnote))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                        .confirmationDialog(editing == nil ? "放弃这条待办？" : "放弃所做的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                            Button(editing == nil ? "放弃" : "放弃修改", role: .destructive) { dismiss() }
                            Button("继续编辑", role: .cancel) {}
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button(confirmTitle) { save() }.fontWeight(.semibold).disabled(!canSave)
                    }
                }
            }
            .onChange(of: picks) { _, items in
                guard !items.isEmpty else { return }
                picks = []
                Task { await load(items) }
            }
            // 把图拖进来（iPad 从别的 App 拖）
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                Task { add(await DroppedImages.load(providers)) }
                return true
            }
            .onAppear { clipboardImage = ClipboardImage.available }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in clipboardImage = ClipboardImage.available }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in clipboardImage = ClipboardImage.available }
            .task {
                // 刚截了图（3 分钟内）：同发消息时一样，提示一下，点一下就附上。没给过相册权限就不找（不为这个弹授权）
                #if !SNAPSHOT
                if editing == nil || shots.isEmpty { recent = await RecentScreenshot.find(ask: false) }
                #endif
            }
            .onAppear { if case .new = target { focused = true } }
        }
        // 改过了不让往下一划就关（打了一大段字、刚说完话，手一滑全丢）：要关点「取消」，会问一句
        .interactiveDismissDisabled(busy || dirty)
        #endif
    }

    #if os(macOS)
    // MARK: Mac 的排法

    /// 手机那套 Form 到了 Mac 是左右两栏的表单：左边的标签被裁、输入框和说明往右溢出、上面空一大块（10-23）。Mac 单独排：
    /// 标题和出处在上；整段文字框，底下一条放「听写」和快捷键；截图一栏（拖进来、⌘V、选文件、从「照片」）；最下面取消、加入。
    /// 回车照常换行，⌘回车加入，Esc 取消
    private var macBody: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.ui(.title3).weight(.semibold))
                    if let sourceText {
                        Label(sourceText, systemImage: "text.bubble")
                            .font(.ui(.footnote)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.bottom, 14)

                VStack(spacing: 0) {
                    MacInputField(text: $text, height: $inputHeight, placeholder: L("需要做的事"), enabled: !busy, focusToken: focusToken,
                                  onSubmit: { if canSave { save() } }, onPasteImages: add,
                                  minHeight: 96, maxHeight: 240, returnSubmits: false)
                        // 面板拉高时多出来的高度给输入框
                        .frame(minHeight: inputHeight, idealHeight: inputHeight, maxHeight: .infinity)
                    HStack(spacing: 8) {
                        MacDictateButton { said in
                            text = Dictation.append(said, to: text)
                            focusToken += 1
                        }
                        Spacer(minLength: 8)
                        Text(L("⌘V 粘贴截图 · ⌘↩ %@", "\(confirmTitle)")).font(.ui(.caption)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).hairlineBorder(MacPalette.separator))

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("截图")).font(.ui(.subheadline).weight(.medium))
                    Text("\(shots.count)/\(Self.maxShots)").font(.ui(.caption)).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer(minLength: 8)
                    HStack(spacing: 14) {
                        if clipboardImage {
                            Button(L("粘贴")) {
                                ClipboardImage.handled = ClipboardImage.changeCount
                                clipboardImage = false
                                let images = InputTextView.pasteboardImages()
                                if images.isEmpty { model.flash(L("无法读取剪贴板里的图片")) } else { add(images) }
                            }
                            .help(L("粘贴剪贴板里的图片"))
                        }
                        Button(L("选择文件…")) { choosingFiles = true }
                        Button(L("从「照片」选择…")) { choosingPhotos = true }
                    }
                    .font(.ui(.footnote))
                    .buttonStyle(.borderless)
                    .disabled(shots.count >= Self.maxShots)
                }
                .padding(.top, 18).padding(.bottom, 8)

                macShots
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)

            Divider()
            HStack(spacing: 10) {
                if request != nil, sourceText != nil {
                    Text(L("加入后点击即可跳转到原消息")).font(.ui(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                Button(L("取消"), action: cancel).keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                Button(confirmTitle) { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).tint(Theme.wechatGreen)
                    .disabled(!canSave)
            }
            .controlSize(.large)
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        // 打开时 560 宽、高度跟着内容走；能拖边改大小
        .frame(minWidth: 440, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        .confirmPanel(editing == nil ? L("放弃这条待办？") : L("放弃所做的修改？"), isPresented: $confirmDiscard,
                      confirm: editing == nil ? L("放弃") : L("放弃修改"), destructive: true, cancel: L("继续编辑")) { dismiss() }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            Task { await load(items) }
        }
        // 把图拖进来（从访达、桌面拖截图）：拖到面板任何地方都行，经过时截图区描边
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Task { add(await DroppedImages.load(providers)) }
            return true
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $picks, maxSelectionCount: max(1, Self.maxShots - shots.count), matching: .images)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            add(urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            })
        }
        .onAppear { clipboardImage = ClipboardImage.offer }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in clipboardImage = ClipboardImage.offer }
        // 打开就能打字（从消息加的、修改的，光标放在末尾）
        .task { focusToken += 1 }
    }

    /// 截图区：没图时是一块虚线框（点一下选文件）；有图时一格格缩略图，最后一格「+」接着加
    private var macShots: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if shots.isEmpty {
                Button { choosingFiles = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                        Text(L("将截图拖到此处，或在文字框中按 ⌘V 粘贴")).font(.ui(.footnote)).foregroundStyle(.secondary)
                        Text(L("最多 %@ 张", "\(Self.maxShots)")).font(.ui(.caption)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .help(L("点击选择图片文件"))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 76), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(shots) { shot in
                        MacShotTile(remove: { withAnimation(.snappy) { shots.removeAll { $0.id == shot.id } } }) { shotThumb(shot) }
                            .zoomableOnClick(shots.map(\.viewerImage), index: shots.firstIndex { $0.id == shot.id } ?? 0)
                    }
                    if shots.count < Self.maxShots {
                        Button { choosingFiles = true } label: {
                            Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(.secondary)
                                .frame(width: 76, height: 76)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(MacPalette.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("添加图片文件"))
                    }
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03), in: shape)
        .overlay(shape.strokeBorder(dropTargeted ? Color.accentColor : MacPalette.separator,
                                    style: StrokeStyle(lineWidth: dropTargeted ? 1.5 : 1, dash: shots.isEmpty || dropTargeted ? [5, 4] : [])))
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }
    #endif

    /// 已经附上的截图：一排正方形，右上角 ✕ 去掉
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shots) { shot in
                    shotThumb(shot)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { withAnimation(.snappy) { shots.removeAll { $0.id == shot.id } } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    // 叉只有 18 点：点的范围放大到 30（叉画的位置不变）
                                    .frame(width: 30, height: 30).contentShape(Rectangle())
                            }
                            .buttonStyle(.steady(.plain))
                            .accessibilityLabel("移除截图")
                            .offset(x: 10, y: -10)
                        }
                        .padding(.top, 4)
                }
            }
            .padding(.trailing, 4)
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)   // 图多了别把一排的总宽往上报
    }

    @ViewBuilder
    private func shotThumb(_ shot: TodoShot) -> some View {
        switch shot {
        case .saved(let image):
            Color.primary.opacity(0.06)
                .overlay { RemoteImage(path: TodoItem.mediaPath, query: TodoItem.mediaQuery(image.ref), variant: .square) }
        case .new(let item):
            if let image = PlatformImage(data: item.preview) {
                Image(platform: image).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.06)
            }
        }
    }

    #if os(iOS)
    private func recentRow(_ shot: RecentScreenshot.Shot) -> some View {
        Button {
            Task {
                guard let data = await RecentScreenshot.data(shot.asset), let prepared = ImagePrep.prepare(data) else {
                    model.flash(L("无法获取此截图"))
                    return
                }
                withAnimation(.snappy) {
                    shots.append(.new(ComposeAttachment(name: "screenshot.jpg", data: prepared.jpeg, preview: prepared.preview)))
                    recent = nil
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(uiImage: shot.thumb).resizable().scaledToFill().frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("最新截图").font(.ui(.subheadline)).foregroundStyle(.primary)
                    Text("轻点添加").font(.ui(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.wechatGreen)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
    #endif

    /// 剪贴板里有图：系统的「粘贴」按钮（点它取图，iPhone 上不弹「允许粘贴」）
    private var pasteRow: some View {
        HStack(spacing: 10) {
            Label("剪贴板里有图片", systemImage: "doc.on.clipboard").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            PasteButton(supportedContentTypes: [.image]) { providers in
                Task {
                    ClipboardImage.handled = ClipboardImage.changeCount
                    clipboardImage = false
                    let images = await DroppedImages.load(providers)
                    if images.isEmpty { model.flash(L("无法读取剪贴板里的图片")) } else { add(images) }
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
    }

    /// 粘贴、拖进来、选文件加的图：同发消息，长边缩到 2048、转 JPEG
    private func add(_ list: [Data]) {
        for data in list where shots.count < Self.maxShots {
            guard let prepared = ImagePrep.prepare(data) else { continue }
            withAnimation(.snappy) { shots.append(.new(ComposeAttachment(name: "image.jpg", data: prepared.jpeg, preview: prepared.preview))) }
        }
    }

    /// 和发消息一样：长边缩到 2048、转 JPEG
    private func load(_ items: [PhotosPickerItem]) async {
        for item in items where shots.count < Self.maxShots {
            guard let raw = try? await item.loadTransferable(type: Data.self), let prepared = ImagePrep.prepare(raw) else { continue }
            shots.append(.new(ComposeAttachment(name: "image.jpg", data: prepared.jpeg, preview: prepared.preview)))
        }
    }

    private func save() {
        busy = true
        Task {
            let ok: Bool
            if let editing {
                ok = await model.editTodo(editing, text: text, shots: shots)
            } else if let request {
                ok = await model.addTodos([text], key: request.key, itemId: request.itemId, title: request.title, ts: request.ts, shots: shots)
            } else {
                ok = await model.addTodos([text], shots: shots)
            }
            busy = false
            if ok { dismiss() }
        }
    }
}

#if os(macOS)
/// Mac 面板里一张已附上的截图：鼠标指上去右上角出现 ✕，右键也能移除
extension TodoShot {
    /// Mac 看大图里的这一张：已存的经接口取，刚加的直接看
    var viewerImage: ViewerImage {
        switch self {
        case .saved(let image): .remote(path: TodoItem.mediaPath, query: TodoItem.mediaQuery(image.ref))
        case .new(let item): .local(item.data)
        }
    }
}

private struct MacShotTile<Content: View>: View {
    let remove: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).hairlineBorder(MacPalette.separator))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                            .foregroundStyle(.white, .black.opacity(0.65))
                            .padding(4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("移除截图"))
                    .transition(.opacity)
                }
            }
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
            .contextMenu { Button(L("移除"), role: .destructive, action: remove) }
    }
}
#endif

/// 说出来的话接在已经写的后面：中文直接接上，英文、数字之间隔一个空格
enum Dictation {
    static func append(_ said: String, to text: String) -> String {
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return text }
        guard let last = text.last else { return said }
        if last.isWhitespace { return text + said }
        if last.isASCII, last.isLetter || last.isNumber, said.first?.isASCII == true { return text + " " + said }
        return text + said
    }
}

// MARK: - 加入待办的面板

/// 要加哪几条：带 key + itemId 的记下出自哪条消息
struct AddTodosRequest: Identifiable {
    let id = UUID()
    var key: String?
    var itemId: String?
    var title: String?
    var ts: Double?
    var candidates: [String]
}

/// 「加入待办」：列出认出来的几件事，默认全选，可以去掉几条、改改字，再一起加进来
struct AddTodosSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let request: AddTodosRequest
    @State private var texts: [String]
    @State private var picked: Set<Int>
    @State private var busy = false
    @FocusState private var focusedRow: Int?

    init(request: AddTodosRequest) {
        self.request = request
        _texts = State(initialValue: request.candidates)
        _picked = State(initialValue: Set(request.candidates.indices))
    }

    var body: some View {
        // 只有一件事（长按整条消息加、只认出一件）：用记一条的面板，多行、按住说话、附截图
        if request.candidates.count == 1 {
            TodoEditor(target: .fromMessage(request))
        } else {
            list
        }
    }

    private var list: some View {
        FitSheet(title: L("加入待办"), cancel: true) {
            VStack(alignment: .leading, spacing: 12) {
                if let title = request.title, !title.isEmpty {
                    #if os(macOS)
                    Text(L("出自「%@」，加入后点击即可跳转到原消息", "\(title)"))
                        .font(.ui(.footnote)).foregroundStyle(.secondary)
                    #else
                    Text("出自「\(title)」，加入后轻点即可跳转到原消息")
                        .font(.ui(.footnote)).foregroundStyle(.secondary)
                    #endif
                }
                VStack(spacing: 0) {
                    ForEach(texts.indices, id: \.self) { i in
                        HStack(alignment: .top, spacing: 10) {
                            Button { toggle(i) } label: {
                                Image(systemName: picked.contains(i) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .light))
                                    .foregroundStyle(picked.contains(i) ? Theme.wechatGreen : Color.secondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(picked.contains(i) ? "不加入这一项" : "加入这一项")
                            TextField("待办内容", text: $texts[i], axis: .vertical)
                                .font(.ui(.body))
                                .textFieldStyle(.plain)
                                .focused($focusedRow, equals: i)
                                .foregroundStyle(picked.contains(i) ? .primary : .secondary)
                                .padding(.top, 2)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        if i < texts.count - 1 { Divider().padding(.leading, 46) }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                #if os(iOS)
                HoldToDictate(done: dictated)
                Text("如需为某项附加截图，请在加入后轻点该项进行编辑。").font(.ui(.caption)).foregroundStyle(.secondary)
                #else
                HStack(spacing: 10) {
                    MacDictateButton(done: dictated)
                    Text(L("如需为某项附加截图，请在加入后点击该项进行编辑。")).font(.ui(.caption)).foregroundStyle(.secondary)
                }
                #endif
                Button { add() } label: {
                    Text(picked.isEmpty ? "请至少选择一项" : (texts.count == 1 ? "加入待办" : "加入 \(picked.count) 项"))
                        .font(.ui(.body).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Theme.wechatGreen.opacity(picked.isEmpty || busy ? 0.4 : 1),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(picked.isEmpty || busy)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func toggle(_ i: Int) {
        if picked.contains(i) { picked.remove(i) } else { picked.insert(i) }
        Haptics.select()
    }

    /// 说出来的话：接在正在改的那条后面；没在改哪条就新加一条
    private func dictated(_ said: String) {
        if let i = focusedRow, texts.indices.contains(i) {
            texts[i] = Dictation.append(said, to: texts[i])
            picked.insert(i)
        } else {
            texts.append(said)
            picked.insert(texts.count - 1)
        }
    }

    private func add() {
        let chosen = texts.indices.filter { picked.contains($0) }.map { texts[$0] }
        busy = true
        Task {
            let ok = await model.addTodos(chosen, key: request.key, itemId: request.itemId, title: request.title, ts: request.ts)
            busy = false
            if ok { dismiss() }
        }
    }
}

// MARK: - 对话里：这条回复下面问一句

/// Claude 这条回复里有要你做的事：气泡下面一张小卡片「有 N 件事需要你来做 · 加入待办」；
/// 加过了变成一行「已加入待办 · N 项」（点开待办），说过不用的只留一个小小的「加入待办」
struct AskPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    /// 只读的对话（子 agent 的完整记录）里不问
    @Environment(\.chatReadOnly) private var readOnly
    let key: String
    let item: ChatItem
    let asks: [String]
    @State private var adding: AddTodosRequest?

    var body: some View {
        if !readOnly {
            let added = model.todos.added(key: key, itemId: item.id)
            let handled = model.todos.isHandled(key: key, itemId: item.id)
            content(added: added, handled: handled)
                .sheetPanel(item: $adding) { AddTodosSheet(request: $0) }
        }
    }

    @ViewBuilder
    private func content(added: Int, handled: Bool) -> some View {
        if added > 0 {
            Button { open(.todos) } label: {
                Label("已加入待办 · \(added) 项", systemImage: "checkmark.circle.fill")
                    .font(.ui(.footnote)).foregroundStyle(.secondary)
            }
            .buttonStyle(.steady(.plain))
            .padding(.leading, 2)
        } else if handled {
            Button { add() } label: {
                Label("加入待办", systemImage: "plus.circle").font(.ui(.footnote)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.steady(.plain))
            .padding(.leading, 2)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "checklist").font(.ui(.subheadline).weight(.semibold)).foregroundStyle(Theme.claude)
                VStack(alignment: .leading, spacing: 1) {
                    Text("有 \(asks.count) 项事项需要你处理").font(.ui(.subheadline).weight(.semibold))
                    Text("加入待办，完成后勾选").font(.ui(.caption)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                Button("忽略") { withAnimation(.snappy) { model.dismissAsks(key: key, itemId: item.id) } }
                    .buttonStyle(.steady(.plain))
                    .font(.ui(.subheadline))
                    .foregroundStyle(.secondary)
                Button { add() } label: {
                    Text("加入").font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Theme.wechatGreen, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, ChatType.padH).padding(.vertical, ChatType.padV + ChatType.px(2))
            .frame(maxWidth: ChatType.px(360), alignment: .leading)
            .background(Theme.botBubble, in: RoundedRectangle(cornerRadius: ChatType.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ChatType.radius, style: .continuous).strokeBorder(Theme.claude.opacity(0.25)))
            // 点卡片任意位置和点「加入」一样：弹出事项清单，先看清是哪几项再决定（「忽略」「加入」按钮优先响应）
            .contentShape(RoundedRectangle(cornerRadius: ChatType.radius, style: .continuous))
            .onTapGesture { add() }
            .accessibilityAction(named: "查看事项") { add() }
        }
    }

    private func add() {
        let title = model.session(key)?.title ?? model.pastMeta[key]?.title
        adding = AddTodosRequest(key: key, itemId: item.id, title: title, ts: item.ts, candidates: asks)
    }
}

// MARK: - 首页入口

/// 首页右上角：待办。角标（红色，同通知铃铛）：有 Claude 刚说的、还没决定加不加的就是那几件，没有就是还有几件没做完
struct TodoBarButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open

    var body: some View {
        let fresh = model.todos.suggestions.reduce(0) { $0 + $1.asks.count }
        let pending = model.todos.openCount
        let count = fresh > 0 ? fresh : pending
        Button { open(.todos) } label: {
            Image(systemName: "checklist")
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.appFixed(size: 10, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(Theme.removed, in: Capsule())   // 同通知铃铛的角标
                            .offset(x: 9, y: -8)
                    }
                }
                .barIcon()
        }
        .accessibilityLabel(fresh > 0 ? "待办，新增 \(fresh) 项" : (pending > 0 ? "待办，\(pending) 项未完成" : "待办"))
    }
}

/// 首页卡片下面一条：Claude 说有几件事要你做，还没加进待办
struct TodoSuggestStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open

    var body: some View {
        let list = model.todos.suggestions
        if !list.isEmpty {
            let count = list.reduce(0) { $0 + $1.asks.count }
            Button { open(.todos) } label: {
                HStack(spacing: 10) {
                    TarsIcon(symbol: "checklist", size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("有 \(count) 项事项需要你处理").font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.primary)
                        Text(list.count == 1 ? "来自「\(list[0].title)」· 加入待办？" : "来自 \(list.count) 个回复 · 加入待办？")
                            .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
    }
}
