import AppKit
import SwiftUI
import KitelineKit

/// 历史会话里的一条（会话列表或搜索结果）
struct PastItem: Identifiable, Hashable {
    struct Hit: Hashable { var id: String; var ts: Double; var who: String; var snippet: String }
    var key: String
    var sessionId: String
    var sourceId: String
    var sourceName: String
    var cwd: String
    var title: String?
    var firstPrompt: String?
    var lastActive: Double
    var live: Bool
    var hits: [Hit] = []
    /// 搜到它是因为项目名（project）或标题（title）里有搜索词（可能没有正文片段）
    var match: [String] = []
    var id: String { key }
    var folder: String { (cwd as NSString).lastPathComponent }
    var displayTitle: String {
        if let title = title, !title.isEmpty { return title }
        if let prompt = firstPrompt, !prompt.isEmpty { return String(prompt.prefix(40)) }
        return folder.isEmpty ? L("会话") : folder
    }

    init?(_ item: [String: Any]) {
        guard let key = item["key"] as? String, let sessionId = item["sessionId"] as? String else { return nil }
        self.key = key
        self.sessionId = sessionId
        sourceId = item["sourceId"] as? String ?? ""
        sourceName = ServerLang.machine(item["sourceName"] as? String ?? "")
        cwd = item["cwd"] as? String ?? ""
        title = item["title"] as? String
        firstPrompt = item["firstPrompt"] as? String
        lastActive = Digest.number(item["lastActive"])
        live = item["live"] as? Bool ?? false
        hits = ((item["hits"] as? [[String: Any]]) ?? []).map {
            Hit(id: $0["id"] as? String ?? "", ts: Digest.number($0["ts"]),
                who: ($0["t"] as? String) == "user" ? Profile.displayName(AppState.shared.config.mobile) : "Claude", snippet: $0["snippet"] as? String ?? "")
        }
        match = item["match"] as? [String] ?? []
    }
}

final class HistoryModel: ObservableObject {
    static let shared = HistoryModel()
    @Published private(set) var sessions: [PastItem] = []
    @Published private(set) var results: [PastItem]?
    @Published private(set) var loading = false
    @Published var query = ""
    /// 打开过的已结束会话：右侧显示对话时用它的标题和目录
    private(set) var known: [String: PastItem] = [:]
    private var seq = 0
    /// 按项目筛着的那个项目名：它的会话另外取全并进列表（各机器只列最近 120 个，老一些的项目不全）
    private var project = ""
    private var pendingSearch: DispatchWorkItem?
    /// 自测渲染注入了示例数据：不再从来源读（页面一出现就读，会把示例清空）
    private var frozen = false

    func load() {
        guard !frozen else { return }
        seq += 1
        let current = seq
        loading = true
        PastSessions.list { [weak self] payload in
            guard let self = self, current == self.seq else { return }
            self.sessions = ((payload["sessions"] as? [[String: Any]]) ?? []).compactMap(PastItem.init)
            self.results = nil
            self.loading = false
            self.loadProject()
        }
    }

    /// 换了项目筛选：把这个项目的会话取全（fetch: false 只记下，等 load 读完列表再取）
    func setProject(_ name: String, fetch: Bool = true) {
        guard name != project else { return }
        project = name
        if fetch { loadProject() }
    }

    private func loadProject() {
        let name = project
        guard !name.isEmpty, !frozen else { return }
        PastSessions.list(project: name) { [weak self] payload in
            guard let self = self, name == self.project else { return }
            let have = Set(self.sessions.map(\.key))
            let extra = ((payload["sessions"] as? [[String: Any]]) ?? []).compactMap(PastItem.init).filter { !have.contains($0.key) }
            guard !extra.isEmpty else { return }
            self.sessions = (self.sessions + extra).sorted { $0.lastActive > $1.lastActive }
        }
    }

    /// 打字时停一下再搜（回车立刻搜）
    func searchSoon() {
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.search() }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func search() {
        pendingSearch?.cancel()
        guard !frozen else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = nil; return }
        seq += 1
        let current = seq
        loading = true
        PastSessions.search(q) { [weak self] payload in
            guard let self = self, current == self.seq else { return }
            self.results = ((payload["results"] as? [[String: Any]]) ?? []).compactMap(PastItem.init)
            self.loading = false
        }
    }

    @MainActor
    func open(_ item: PastItem, hit: String? = nil) {
        known[item.key] = item
        if let hit = hit { KitelineKit.jump(key: item.key, itemId: hit) }
        KitelineModel.shared.selection = item.key
    }

    func past(_ key: String?) -> PastItem? { key.flatMap { known[$0] } }

    /// 自测渲染用：results、query 给了就是搜索结果的样子
    func inject(_ items: [PastItem], results: [PastItem]? = nil, query: String = "") {
        frozen = true
        sessions = items
        self.results = results
        self.query = query
        loading = false
    }

    /// 在 VS Code 里恢复这段对话（不发消息）。点的人要去 VS Code 里看，前台不还回来；
    /// VS Code 在虚拟屏幕上时看不到它，留在 Kiteline 里接着聊
    func resume(_ item: PastItem) {
        guard let source = AppState.shared.config.sources.first(where: { $0.id == item.sourceId }) else { return }
        // 按钮写明了「在 VS Code 中恢复」：远端项目也开 VS Code，不走后台托管（在输入框里发消息恢复的才走后台）
        NewSession.start(source: source, cwd: item.cwd, prompt: "", submit: false, sessionId: item.sessionId,
                         returnFocus: VirtualScreen.shared.isOn, inEditor: true) { outcome in
            if !outcome.ok { KitelineModel.alert(L("恢复失败"), outcome.message) }
        }
    }
}

/// 主窗口右侧的「历史会话」：所有项目的对话（包括已结束的），可按设备、项目筛，按标题、项目名和对话内容搜
struct HistoryView: View {
    @ObservedObject var model = HistoryModel.shared
    /// 分组：none 按日期 / source 按来源 / project 按项目（和手机上一样）
    @AppStorage("historyGrouping", store: AppConfig.defaults) private var grouping = "none"
    /// 按状态筛：all / live 进行中 / ended 已结束（同手机、同会话列表的筛选条）
    @AppStorage("historyFilter", store: AppConfig.defaults) private var statusFilter = "all"
    /// 只看某台设备（来源名；空 = 全部设备）
    @AppStorage("historySource", store: AppConfig.defaults) private var sourceFilter = ""
    /// 只看某个项目（项目名 = 目录最后一级，几台设备上同名的算一个；空 = 全部项目）
    @AppStorage("historyProject", store: AppConfig.defaults) private var projectFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索会话标题、项目名称和对话内容", text: $model.query)
                    .textFieldStyle(.plain)
                    .onSubmit { model.search() }
                    // 打字停一下就搜，清空了马上回到列表
                    .onChange(of: model.query) { _, value in
                        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.search() } else { model.searchSoon() }
                    }
                if model.loading { ProgressView().controlSize(.small) }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                        .help("清除搜索")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .tarsGlass(cornerRadius: 12)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
            if !model.sessions.isEmpty || isFiltering { filterRows }
            if let results = model.results {
                searchList(results)
            } else if filtered(model.sessions).isEmpty, !model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("暂无\(filterName)", systemImage: "line.3.horizontal.decrease")
                } actions: {
                    Button("显示全部") { withAnimation(.snappy) { clearFilters() } }
                }
                .frame(maxHeight: .infinity)
            } else {
                sessionList
            }
        }
        .navigationTitle("历史会话")
        .navigationSubtitle(model.results.map { L("找到 %lld 个会话", count: filtered($0).count) } ?? L("%lld 个会话", count: model.sessions.count))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.query = ""; model.load() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        // 切过来、来源连上 / 断开时重新拉（不定时拉：列表一变会回到顶上，翻着看时别打扰）
        .liveReload { model.setProject(projectFilter, fetch: false); model.load() }
        .onChange(of: projectFilter) { _, name in model.setProject(name) }
    }

    // MARK: 筛选、显示方式（和手机上、会话列表一样：状态筛选条在左，「显示方式」菜单在右；下面是设备、项目两排胶囊）

    private static var statusOptions: [(String, String, Color?)] { [
        ("all", L("全部"), nil), ("live", L("进行中"), Color.tarsBrand), ("ended", L("已结束"), Color.secondary),
    ] }
    private static var groupOptions: [(String, String)] { [("none", L("按日期")), ("source", L("按来源")), ("project", L("按项目"))] }

    private func matches(_ item: PastItem, _ filter: String) -> Bool {
        switch filter {
        case "live": return item.live
        case "ended": return !item.live
        default: return true
        }
    }

    /// 在筛着的设备、项目里
    private func inScope(_ item: PastItem) -> Bool {
        (activeSource == nil || item.sourceName == activeSource) && (projectFilter.isEmpty || item.folder == projectFilter)
    }

    /// 按设备、项目、状态筛过的
    private func filtered(_ items: [PastItem]) -> [PastItem] {
        items.filter { inScope($0) && matches($0, statusFilter) }
    }

    /// 读到的会话来自几台设备（一台就不给按设备筛）
    private var sourceNames: [String] {
        var seen = Set<String>()
        return model.sessions.map(\.sourceName).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 筛着的那台设备（读到的会话里已经没有它就当没筛）
    private var activeSource: String? {
        sourceFilter.isEmpty || !sourceNames.contains(sourceFilter) ? nil : sourceFilter
    }

    private var isFiltering: Bool { statusFilter != "all" || activeSource != nil || !projectFilter.isEmpty }

    /// 选了某个项目时按项目、按来源分都只剩一组：不给分组，按日期排（项目选「全部」时才有「按项目」）
    private var effectiveGrouping: String { projectFilter.isEmpty ? grouping : "none" }

    private func clearFilters() {
        statusFilter = "all"
        sourceFilter = ""
        projectFilter = ""
    }

    /// 「虚拟机上 ccpulse 项目里已结束的会话」
    private var filterName: String {
        let status = statusFilter == "all" ? "" : Self.statusOptions.first { $0.0 == statusFilter }?.1 ?? ""
        let place = (activeSource.map { L("%@上", $0) } ?? "") + (projectFilter.isEmpty ? "" : L("「%@」项目里", projectFilter))
        return place + L("%@的会话", status)
    }

    /// 设备那排：个数跟着项目筛选走
    private func sourceOptions(_ items: [PastItem]) -> [ScopeBar.Option] {
        let inProject = items.filter { projectFilter.isEmpty || $0.folder == projectFilter }
        return sourceNames.map { name in ScopeBar.Option(id: name, title: name, count: inProject.filter { $0.sourceName == name }.count) }
    }

    /// 项目那排：最近有动静的在前，个数跟着设备筛选走；筛着的项目这会儿一个都没有也列着
    private func projectOptions(_ items: [PastItem]) -> [ScopeBar.Option] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items.sorted(by: { $0.lastActive > $1.lastActive }) where activeSource == nil || item.sourceName == activeSource {
            guard !item.folder.isEmpty else { continue }
            if counts[item.folder] == nil { order.append(item.folder) }
            counts[item.folder, default: 0] += 1
        }
        if !projectFilter.isEmpty, counts[projectFilter] == nil { order.insert(projectFilter, at: 0) }
        return order.map { ScopeBar.Option(id: $0, title: $0, count: counts[$0] ?? 0) }
    }

    private var filterRows: some View {
        // 搜着的时候数字是搜到的里面的
        let all = model.results ?? model.sessions
        let base = all.filter(inScope)
        let projects = projectOptions(all)
        let bySource = sourceNames.count > 1 || activeSource != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FilterBar(bleed: 20, trailingBleed: 0) {
                    ForEach(Self.statusOptions, id: \.0) { option in
                        FilterChip(title: option.1, count: base.filter { matches($0, option.0) }.count, dot: option.2,
                                   selected: statusFilter == option.0) {
                            withAnimation(.snappy) { statusFilter = statusFilter == option.0 && option.0 != "all" ? "all" : option.0 }
                        }
                    }
                }
                if projectFilter.isEmpty { viewMenu }
            }
            // 不止一台设备、不止一个项目时才有（筛着的时候也留着，好点回全部）
            if bySource {
                ScopeBar(symbol: "desktopcomputer", allTitle: L("全部设备"), options: sourceOptions(all), selection: $sourceFilter, bleed: 20)
            }
            if projects.count > 1 || !projectFilter.isEmpty {
                ScopeBar(symbol: "folder", allTitle: L("全部项目"), options: projects, selection: $projectFilter, bleed: 20)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 6)
    }

    /// 「显示方式」：分组放在一个菜单里，按钮上写着现在怎么分
    private var viewMenu: some View {
        Menu {
            Picker("分组", selection: $grouping) {
                ForEach(Self.groupOptions, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.inline)
            if grouping != "none" || isFiltering {
                Divider()
                Button("恢复默认") { grouping = "none"; clearFilters() }
            }
        } label: {
            ViewMenuLabel(summary: grouping == "none" ? L("显示方式") : Self.groupOptions.first { $0.0 == grouping }?.1 ?? L("显示方式"),
                          isDefault: grouping == "none")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("历史会话的分组方式")
    }

    private var sessionList: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        PastRow(item: item).contentShape(Rectangle()).onTapGesture { model.open(item) }
                    }
                }
            }
        }
        .listStyle(.inset)
        // 读完一次重建列表：系统列表给读完后才插进来的行算高度时会算成一行字高，头像被切掉、几行挤在一起
        .id(listIdentity)
    }

    private var listIdentity: String {
        [grouping, statusFilter, sourceFilter, projectFilter].joined(separator: "|") + "|" + model.sessions.map(\.key).joined(separator: ",")
    }

    private struct Group { var title: String; var items: [PastItem] }

    /// 不分组 = 按最后活动的那天；按来源 / 按项目 = 组的先后跟着组里最近的那个会话走，标题带个数（同手机）
    private var sections: [Group] {
        let sorted = filtered(model.sessions).sorted { $0.lastActive > $1.lastActive }
        let grouping = effectiveGrouping
        guard grouping != "none" else {
            let days = Dictionary(grouping: sorted) { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: $0.lastActive / 1000)) }
            return days.keys.sorted(by: >).map { Group(title: Self.dayLabel($0), items: days[$0] ?? []) }
        }
        let bySource = grouping == "source"
        let multi = Set(sorted.map(\.sourceName)).count > 1
        var order: [String] = []
        var map: [String: [PastItem]] = [:]
        var names: [String: String] = [:]
        for item in sorted {
            let key = bySource ? item.sourceName : "\(item.sourceName)\n\(item.cwd)"
            if map[key] == nil {
                order.append(key)
                let project = item.folder.isEmpty ? L("（未知目录）") : item.folder
                names[key] = bySource ? (item.sourceName.isEmpty ? L("未知来源") : item.sourceName) : (multi && !item.sourceName.isEmpty ? "\(project) · \(item.sourceName)" : project)
            }
            map[key, default: []].append(item)
        }
        return order.map { Group(title: "\(names[$0] ?? $0)（\(map[$0]?.count ?? 0)）", items: map[$0] ?? []) }
    }

    private func searchList(_ all: [PastItem]) -> some View {
        let results = filtered(all)
        return List {
            if results.isEmpty && !model.loading {
                if all.isEmpty {
                    Text("未找到「\(model.query)」").foregroundStyle(.secondary)
                } else {
                    // 搜到了，只是不在筛着的设备、项目、状态里
                    HStack(spacing: 10) {
                        Text("\(filterName)中未找到「\(model.query)」，其他会话中有 \(all.count) 个").foregroundStyle(.secondary)
                        Button("在全部会话中搜索") { withAnimation(.snappy) { clearFilters() } }.controlSize(.small)
                    }
                }
            }
            ForEach(results) { item in
                Section {
                    PastRow(item: item).contentShape(Rectangle()).onTapGesture { model.open(item) }
                    // 因为项目名、标题搜到的（没有正文片段）：说一声是哪样对上的
                    if item.hits.isEmpty, let note = Self.matchNote(item, model.query) {
                        Text(note).font(.app(size: 12)).foregroundStyle(.secondary).padding(.leading, 40)
                    }
                    ForEach(item.hits, id: \.self) { hit in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(hit.who).font(.appFixed(size: 11)).foregroundStyle(.tertiary).lineLimit(1).frame(width: 44, alignment: .leading)
                            Text(Self.highlighted(hit.snippet, model.query)).font(.app(size: 12.5)).lineLimit(3)
                            Spacer(minLength: 4)
                            Text(Format.short(hit.ts)).font(.app(size: 10.5)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.open(item, hit: hit.id) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .id("search|" + results.map(\.key).joined(separator: ","))   // 同上：搜出来的行也是后插进来的
    }

    /// 「项目名称包含「kite」」「标题包含「世界模式」」
    static func matchNote(_ item: PastItem, _ query: String) -> AttributedString? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if item.match.contains("project") { return highlighted(L("项目名称：%@", item.folder), q) }
        if item.match.contains("title") { return highlighted(L("标题：%@", item.displayTitle), q) }
        return nil
    }

    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L("今天") }
        if calendar.isDateInYesterday(day) { return L("昨天") }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(day, equalTo: Date(), toGranularity: .year) ? L("M月d日 EEEE") : L("yyyy年M月d日")
        formatter.locale = Lang.shared.locale   // 跟着界面语言：英文是「Thursday, Oct 23」
        return formatter.string(from: day)
    }

    static func highlighted(_ text: String, _ query: String) -> AttributedString {
        var out = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let range = out.range(of: q, options: .caseInsensitive) {
            out[range].backgroundColor = Color.tarsBrand.opacity(0.28)
            out[range].font = .app(size: 12.5, weight: .semibold)
        }
        return out
    }
}

struct PastRow: View {
    let item: PastItem

    var body: some View {
        HStack(spacing: 10) {
            SessionAvatar(key: item.key, title: item.displayTitle, activity: item.live ? .busy : .unknown, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).font(.app(size: 13, weight: .semibold)).lineLimit(1)
                Text([item.sourceName, item.folder, item.title != nil ? (item.firstPrompt ?? "") : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.app(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if item.live {
                Text("进行中").font(.app(size: 10.5, weight: .medium)).foregroundStyle(Color.tarsBrand)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.tarsTile, in: Capsule())
            }
            Text(Format.short(item.lastActive)).font(.app(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
