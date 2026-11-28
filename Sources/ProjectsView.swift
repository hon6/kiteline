import SwiftUI
import KitelineKit

/// 项目总览里的一个项目（某台机器上的一个工作目录）
struct ProjectItem: Identifiable, Hashable {
    struct Git: Hashable {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changed = 0
        var untracked = 0
        var lastHash: String?
        var lastSubject: String?
        var lastTs: Double = 0
        /// git 读超时（多半是 macOS 在等用户授权访问「文稿」/ 网络卷）
        var timeout = false
        var dirty: Bool { changed > 0 || untracked > 0 }
    }

    var sourceId: String
    var sourceName: String
    var cwd: String
    var name: String
    var sessionId: String?
    var exists: Bool
    var lastActive: Double
    var sessions: Int
    var today: Int
    var title: String?
    var git: Git?
    var id: String { "\(sourceId)\n\(cwd)" }

    init?(_ item: [String: Any]) {
        guard let sourceId = item["sourceId"] as? String, let cwd = item["cwd"] as? String else { return nil }
        self.sourceId = sourceId
        self.cwd = cwd
        sourceName = ServerLang.machine(item["sourceName"] as? String ?? sourceId)
        name = item["name"] as? String ?? (cwd as NSString).lastPathComponent
        sessionId = item["sessionId"] as? String
        exists = item["exists"] as? Bool ?? true
        lastActive = Digest.number(item["lastActive"])
        sessions = Int(Digest.number(item["sessions"]))
        today = Int(Digest.number(item["today"]))
        title = item["title"] as? String
        if let g = item["git"] as? [String: Any] {
            let last = g["last"] as? [String: Any]
            git = Git(branch: g["branch"] as? String, upstream: g["upstream"] as? String,
                      ahead: Int(Digest.number(g["ahead"])), behind: Int(Digest.number(g["behind"])),
                      changed: Int(Digest.number(g["changed"])), untracked: Int(Digest.number(g["untracked"])),
                      lastHash: last?["hash"] as? String, lastSubject: last?["subject"] as? String, lastTs: Digest.number(last?["ts"]),
                      timeout: g["timeout"] as? Bool ?? false)
        }
    }
}

final class ProjectsModel: ObservableObject {
    static let shared = ProjectsModel()
    @Published private(set) var projects: [ProjectItem] = []
    @Published private(set) var errors: [String] = []
    @Published private(set) var loading = false
    /// 读回来过一次（之前列表空着是「正在读取」）
    @Published private(set) var loaded = false
    @Published private(set) var cost7: [String: Double] = [:]
    /// 每个项目今天用了多少（各家 agent 合计）：token 总数（输入 + 输出 + 读写缓存）和花费。项目栏顶上那行用量用
    @Published private(set) var today: [String: (tokens: Double, cost: Double)] = [:]
    @Published private(set) var past: [String: [PastItem]] = [:]
    @Published var filter = "all"
    @Published var expanded: String?
    private var seq = 0

    // 上次读到的项目、最近的会话记在磁盘上：重启后先显示它，再后台刷新（11-21 反馈：每次重启项目列表都要转好久）
    private static var cacheFile: URL { AppConfig.directoryURL.appendingPathComponent("projects-cache.json") }
    private var rawProjects: [[String: Any]] = []
    private var rawPast: [String: [[String: Any]]] = [:]
    private var emptyRetries = 0

    private init() {
        if let data = try? Data(contentsOf: Self.cacheFile),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            rawProjects = root["projects"] as? [[String: Any]] ?? []
            rawPast = root["past"] as? [String: [[String: Any]]] ?? [:]
            projects = rawProjects.compactMap(ProjectItem.init)
            past = rawPast.mapValues { $0.compactMap(PastItem.init) }
        }
    }

    private func saveCache() {
        let root: [String: Any] = ["projects": rawProjects, "past": rawPast]
        guard JSONSerialization.isValidJSONObject(root), let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
        try? data.write(to: Self.cacheFile, options: .atomic)
    }

    func load() {
        seq += 1
        let current = seq
        loading = true
        Projects.collect(detail: true) { [weak self] payload in
            guard let self = self, current == self.seq else { return }
            let rawFound = (payload["projects"] as? [[String: Any]]) ?? []
            // 一台电脑都还没连上时读回来是空的：别拿空的盖掉缓存
            if !rawFound.isEmpty { self.rawProjects = rawFound; self.saveCache() }
            // 电脑还没连上时读回来是空的：留着缓存里的，等连上再刷新
            // 刚启动时各台电脑还没连好，读回来是空的：留着缓存里的，过几秒再读（11-21 自测：重启后列表被空结果冲掉）
            if rawFound.isEmpty, !self.projects.isEmpty, self.emptyRetries < 15 {
                self.emptyRetries += 1
                self.loading = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.load() }
                return
            }
            let found = rawFound.compactMap(ProjectItem.init)
                .filter { $0.exists || self.live($0).count > 0 }
            // 「打开项目」刚选的：各台电脑报上来的里面有了就不用再记，还没有的接着排在最前面
            self.adopted.removeAll { item in found.contains { $0.id == item.id } }
            self.projects = self.adopted + found
            self.errors = payload["errors"] as? [String] ?? []
            self.loading = false
            self.loaded = true
        }
        UsageReport.collect(days: 7) { [weak self] payload in
            var map: [String: Double] = [:]
            for item in payload["projects"] as? [[String: Any]] ?? [] {
                map["\(item["sourceId"] as? String ?? "")\n\(item["cwd"] as? String ?? "")"] = Digest.number(item["cost"])
            }
            self?.cost7 = map
        }
        UsageReport.collect(days: 1) { [weak self] payload in
            var map: [String: (tokens: Double, cost: Double)] = [:]
            for item in payload["projects"] as? [[String: Any]] ?? [] {
                let tokens = ["input", "output", "cacheRead", "cacheWrite"].reduce(0.0) { $0 + Digest.number(item[$1]) }
                map["\(item["sourceId"] as? String ?? "")\n\(item["cwd"] as? String ?? "")"] = (tokens, Digest.number(item["cost"]))
            }
            self?.today = map
        }
    }

    func toggle(_ project: ProjectItem) {
        expanded = expanded == project.id ? nil : project.id
        guard expanded != nil else { return }
        PastSessions.list(sourceId: project.sourceId, cwd: project.cwd) { [weak self] payload in
            let running = Set(KitelineModel.shared.sessions.map(\.id))
            self?.past[project.id] = ((payload["sessions"] as? [[String: Any]]) ?? []).compactMap(PastItem.init).filter { !running.contains($0.key) }
        }
    }

    // MARK: 左边栏「项目」页签、二级侧边栏（ProjectPane.swift）

    /// 「打开项目」刚选的文件夹：还没有会话记录、各台电脑报上来的项目里还没有它，先自己记着排在最前面
    private var adopted: [ProjectItem] = []

    /// 「打开项目」刚开的项目：二级侧边栏先看「会话」一栏（平时先看文件）；它的会话一出现右边就打开
    var startOnSessions: Set<String> = []
    var selectWhenReady: Set<String> = []

    /// 项目的 id 拆回哪台电脑、哪个目录
    static func place(_ id: String) -> (sourceId: String, cwd: String)? {
        let parts = id.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static func id(sourceId: String, cwd: String) -> String { "\(sourceId)\n\(cwd)" }

    func project(_ id: String) -> ProjectItem? { projects.first { $0.id == id } }

    /// 「打开项目」选了一个列表里没有的文件夹：先放进列表（它的会话开出来、下次刷新时就是正经的一项了）
    func adopt(sourceId: String, sourceName: String, cwd: String) {
        let id = Self.id(sourceId: sourceId, cwd: cwd)
        guard project(id) == nil, let item = ProjectItem(["sourceId": sourceId, "sourceName": sourceName, "cwd": cwd, "exists": true,
                                                          "lastActive": Date().timeIntervalSince1970 * 1000]) else { return }
        adopted.insert(item, at: 0)
        projects.insert(item, at: 0)
    }

    /// 二级侧边栏的文件、Git 按会话找电脑和目录：用这个项目里正在跑的会话，没有就用它最近的一次会话。
    /// 定下来就不换（换了右边开着的代码标签要重开）；一个会话都还没有（刚打开的新项目，会话还在启动）返回 nil
    private var codeKeys: [String: String] = [:]

    func codeKey(_ id: String) -> String? {
        if let key = codeKeys[id] { return key }
        guard let place = Self.place(id) else { return nil }
        let key = KitelineModel.shared.sessions.first { $0.sourceId == place.sourceId && $0.projectCwd == place.cwd }?.id
            ?? project(id)?.sessionId.map { "\(place.sourceId)#\($0)" }
        if let key { codeKeys[id] = key }
        return key
    }

    /// 项目栏「最近的会话」：合成一项的几台设备上的都拉来，按时间合在一起（键是这一项的 id）
    func loadPast(_ id: String, attempt: Int = 0) {
        let places = members(id).map { ($0.sourceId, $0.cwd) }
        let list = places.isEmpty ? [Self.place(id)].compactMap { $0 } : places
        var got: [[PastItem]] = []
        var rawGot: [[String: Any]] = []
        var failed = false
        for place in list {
            PastSessions.list(sourceId: place.0, cwd: place.1) { [weak self] payload in
                // 只去掉列表里正显示着的会话：电脑端记着的会话不止在跑的（一天里开过的都在），按「记着」去掉的话，
                // 当天用得多的项目最近 40 个全被去掉，「最近的会话」是空的（11-21 自测 ccpulse 一直空）
                let running = Set(KitelineModel.shared.sessions.map(\.id))
                let raw = ((payload["sessions"] as? [[String: Any]]) ?? []).filter { !running.contains($0["key"] as? String ?? "") }
                if !((payload["errors"] as? [String]) ?? []).isEmpty { failed = true }
                rawGot += raw
                got.append(raw.compactMap(PastItem.init))
                guard let self, got.count == list.count else { return }
                let merged = got.flatMap { $0 }.sorted { $0.lastActive > $1.lastActive }
                // 一台电脑都没连上时读回来是空的：已有缓存就先留着
                // 有电脑没答上来（刚启动、连接还没好）：别拿空的盖掉，过几秒再取
                if merged.isEmpty, failed || self.past[id]?.isEmpty == false {
                    if attempt < 5 { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.loadPast(id, attempt: attempt + 1) } }
                    if self.past[id] == nil, attempt >= 5 { self.past[id] = [] }
                    return
                }
                self.rawPast[id] = Array(rawGot.prefix(40)); self.saveCache()
                self.past[id] = merged
            }
        }
    }

    // MARK: 同一个项目挂在几台设备上（新版界面合成一项，11-20 用户）

    /// 是不是同一个项目：不同设备、文件夹名一样，路径末尾至少三级对得上（同一个文件夹经 sshfs / 网络盘挂到虚拟机上：
    /// /Users/u/Documents/x/app 和 /home/u/mnt/Users/u/Documents/x/app）。只比末尾，两台机器上碰巧都叫 ~/projects/app 的不会被合起来
    /// （「projects/app」只有两级，用户名那一级也得一样）
    static func same(_ a: ProjectItem, _ b: ProjectItem) -> Bool {
        guard a.sourceId != b.sourceId, a.name == b.name else { return false }
        func parts(_ path: String) -> [Substring] { path.split(whereSeparator: { $0 == "/" || $0 == "\\" }) }
        let x = parts(a.cwd), y = parts(b.cwd)
        let n = min(x.count, y.count)
        guard n >= 3 else { return false }
        var matched = 0
        while matched < n, x[x.count - 1 - matched] == y[y.count - 1 - matched] { matched += 1 }
        return matched >= 3
    }

    /// 合成一项的几个（第一个是这一项的 id：几个里 id 最小的，排序变了也不换）
    private var groupCache: (source: [ProjectItem], groups: [[ProjectItem]])?

    var groups: [[ProjectItem]] {
        if let cache = groupCache, cache.source == projects { return cache.groups }
        var groups: [[ProjectItem]] = []
        for item in projects {
            if let at = groups.firstIndex(where: { group in group.contains { Self.same($0, item) } }) { groups[at].append(item) }
            else { groups.append([item]) }
        }
        groups = groups.map { $0.sorted { $0.id < $1.id } }
        groupCache = (projects, groups)
        return groups
    }

    /// 这一项（或其中任一个）合在一起的几个；还没读回来的（刚「打开项目」）就它自己
    func members(_ id: String) -> [ProjectItem] {
        groups.first { $0.contains { $0.id == id } } ?? project(id).map { [$0] } ?? []
    }

    /// 某个项目所在那一项的 id
    func groupID(_ id: String) -> String { members(id).first?.id ?? id }

    /// 新版界面的项目列表：合成后的每项（第一个当代表），按「有待确认 > 有在忙 > 有会话 > 最近用过」排
    var groupedShown: [[ProjectItem]] {
        groups.filter { group in group.contains { matches($0, filter) } }
            .sorted { a, b in
                let ra = a.map(rank).max() ?? 0, rb = b.map(rank).max() ?? 0
                return ra != rb ? ra > rb : (a.map(\.lastActive).max() ?? 0) > (b.map(\.lastActive).max() ?? 0)
            }
    }

    /// 这一项在几台设备上正在跑的会话
    func live(group: [ProjectItem]) -> [SessionItem] { group.flatMap(live) }

    /// 文件、Git 看哪台设备上的那份：用户选过就用选的，否则有会话在跑的那台，再否则第一个
    @Published var fileSource: [String: String] = [:]

    func fileMember(_ id: String) -> ProjectItem? {
        let group = members(id)
        if let chosen = fileSource[groupID(id)], let item = group.first(where: { $0.id == chosen }) { return item }
        return group.first { !live($0).isEmpty } ?? group.first
    }

    /// 这个项目里正在跑的会话（实时的，跟着侧栏变）
    func live(_ project: ProjectItem) -> [SessionItem] {
        KitelineModel.shared.sessions.filter { $0.sourceId == project.sourceId && $0.projectCwd == project.cwd }
    }

    func rank(_ project: ProjectItem) -> Int {
        let sessions = live(project)
        if sessions.contains(where: { $0.activity == .waiting }) { return 3 }
        if sessions.contains(where: { $0.activity == .busy }) { return 2 }
        return sessions.isEmpty ? 0 : 1
    }

    /// 筛选：active 有活动（有会话在跑、今天开过会话）/ dirty 有改动（没提交的、没推送的）/ 别的 = 全部
    func matches(_ project: ProjectItem, _ filter: String) -> Bool {
        switch filter {
        case "active": return !live(project).isEmpty || project.today > 0
        case "dirty": return project.git.map { $0.dirty || $0.ahead > 0 } ?? false
        default: return true
        }
    }

    var shown: [ProjectItem] {
        projects.filter { matches($0, filter) }
        .sorted { a, b in rank(a) != rank(b) ? rank(a) > rank(b) : a.lastActive > b.lastActive }
    }

    var summary: String {
        let running = projects.filter { live($0).contains { $0.activity == .busy } }.count   // 只数在干活的
        let waiting = projects.filter { live($0).contains { $0.activity == .waiting } }.count
        let dirty = projects.filter { $0.git?.dirty ?? false }.count
        let unpushed = projects.filter { ($0.git?.ahead ?? 0) > 0 }.count
        return [L("%lld 个项目", count: projects.count), L("%lld 个进行中", count: running), waiting > 0 ? L("%lld 个待确认", count: waiting) : nil,
                dirty > 0 ? L("%lld 个有未提交改动", count: dirty) : nil, unpushed > 0 ? L("%lld 个未推送", count: unpushed) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// 自测渲染用
    func inject(_ items: [ProjectItem], cost: [String: Double] = [:], expanded: String? = nil, past: [String: [PastItem]] = [:]) {
        projects = items
        cost7 = cost
        self.expanded = expanded
        self.past = past
        loading = false
    }
}

/// 主窗口右侧的「项目」：所有机器上的项目，在跑的会话、未提交的改动、没推送的提交、最近一次提交
struct ProjectsView: KLView {
    @ObservedObject var model = ProjectsModel.shared
    @ObservedObject var tars = KitelineModel.shared

    var klBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LookSegmented(selection: $model.filter, options: [("all", L("全部")), ("active", L("有活动")), ("dirty", L("有改动"))])
                    .frame(width: Lang.shared.isEnglish ? 330 : 240)   // 英文「Has Activity」放不进 240
                Text(model.summary).font(.app(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.loading, model.loaded { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            if model.projects.isEmpty, !model.loaded {
                SkeletonPage("正在读取各设备上的项目…", style: .projects(7))
            } else {
            List {
                ForEach(model.shown) { project in
                    ProjectCard(project: project, live: model.live(project), cost: model.cost7[project.id] ?? 0,
                                expanded: model.expanded == project.id, past: model.past[project.id])
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { model.toggle(project) } }
                }
                if model.shown.isEmpty && !model.loading {
                    Text(model.projects.isEmpty ? "暂无使用过 Claude Code 的项目。" : "没有符合条件的项目。").foregroundStyle(.secondary)
                }
                ForEach(model.errors, id: \.self) { Label(ServerLang.ui($0), systemImage: "exclamationmark.triangle").font(.app(size: 11.5)).foregroundStyle(.secondary) }
            }
            .listStyle(.inset)
            }
        }
        .animation(.skeletonFade, value: model.loaded)   // 读回来时骨架淡出、内容淡入
        .modifier(PageChrome(title: L("项目"), subtitle: model.summary) {
            Button { model.load() } label: { Label("刷新", systemImage: "arrow.clockwise") }.help(L("刷新"))
        })
        .liveReload(every: 120) { model.load() }
    }
}

struct ProjectCard: KLView {
    let project: ProjectItem
    let live: [SessionItem]
    let cost: Double
    let expanded: Bool
    let past: [PastItem]?

    var klBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                SessionAvatar(key: project.id, title: project.name, activity: state, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.app(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(project.sourceName) · \(Format.shortPath(project.cwd))").font(.app(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let tag = tag {
                    Text(tag.0).font(.app(size: 10.5, weight: .medium)).foregroundStyle(tag.1)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(tag.1.opacity(0.13), in: Capsule())
                }
                Text(Format.short(project.lastActive)).font(.app(size: 10.5)).foregroundStyle(.tertiary)
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.app(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let git = project.git {
                    gitLine(git)
                    if let subject = git.lastSubject {
                        HStack(spacing: 6) {
                            Text(git.lastHash ?? "").font(.app(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            Text(subject).font(.app(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            Text(Format.short(git.lastTs)).font(.app(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                } else if let title = project.title {
                    Text(title).font(.app(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                let foot = [project.today > 0 ? L("今天 %@ 个会话", "\(project.today)") : nil, project.sessions > 0 ? L("共 %@ 个", "\(project.sessions)") : nil,
                            cost > 0 ? L("7 天 %@", "\(UsageReportModel.money(cost))") : nil].compactMap { $0 }
                if !foot.isEmpty { Text(foot.joined(separator: " · ")).font(.app(size: 11)).foregroundStyle(.tertiary) }
            }
            .padding(.leading, 40)
            if expanded { detail.padding(.leading, 40).padding(.top, 4) }
        }
        .padding(.vertical, 4)
    }

    private var state: Activity {
        if live.contains(where: { $0.activity == .waiting }) { return .waiting }
        if live.contains(where: { $0.activity == .busy }) { return .busy }
        return live.isEmpty ? .unknown : .idle
    }

    private var tag: (String, Color)? {
        let waiting = live.filter { $0.activity == .waiting }.count
        let busy = live.filter { $0.activity == .busy }.count
        if waiting > 0 { return (waiting > 1 ? L("%lld 个待确认", count: waiting) : L("待确认"), .orange) }
        if busy > 0 { return (busy > 1 ? L("%lld 个进行中", count: busy) : L("进行中"), .tarsBrand) }
        // 只开着、没在干活的不标（11-29 反馈：做完好几天的还显示「运行中」）
        return nil
    }

    private func gitLine(_ git: ProjectItem.Git) -> some View {
        if git.timeout {
            return (Text("git 状态读取超时").foregroundColor(.orange).bold() + Text(" · 可能需要允许 Kiteline 访问该文件夹（系统设置 → 隐私与安全性 → 文件与文件夹）").foregroundColor(.secondary))
                .font(.app(size: 12)).lineLimit(1)
        }
        var text = Text("⎇ \(git.branch ?? "(无分支)")").foregroundColor(.secondary)
        if git.ahead > 0 { text = text + Text(" ↑\(git.ahead)").foregroundColor(.tarsBrand).bold() }
        if git.behind > 0 { text = text + Text(" ↓\(git.behind)").foregroundColor(.red).bold() }
        if git.changed > 0 { text = text + Text(" · ").foregroundColor(.secondary) + Text("\(git.changed) 个改动").foregroundColor(.orange).bold() }
        if git.untracked > 0 { text = text + Text(" · \(git.untracked) 个新文件").foregroundColor(.secondary) }
        if !git.dirty { text = text + Text(" · ").foregroundColor(.secondary) + Text("已全部提交").foregroundColor(.green) }
        return text.font(.app(size: 12)).lineLimit(1)
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if project.exists {
                    Button { KitelineModel.shared.newTask(sourceId: project.sourceId, cwd: project.cwd) } label: {
                        Label("在此新建任务", systemImage: "square.and.pencil")
                    }
                }
                if let git = project.git, let upstream = git.upstream {
                    Text(git.ahead == 0 && git.behind == 0 ? L("和 %@ 一致", "\(upstream)")
                         : [git.ahead > 0 ? L("领先 %@ 个提交（未推送）", "\(git.ahead)") : nil, git.behind > 0 ? L("落后 %@ 个", "\(git.behind)") : nil]
                            .compactMap { $0 }.joined(separator: "，"))
                        .font(.app(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            if !live.isEmpty {
                Text("未关闭的会话").font(.app(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(live) { session in
                    HStack(spacing: 8) {
                        Circle().fill(session.activity.color).frame(width: 6, height: 6)
                        Text(session.title).font(.app(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(session.activity.sectionTitle).font(.app(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { KitelineModel.shared.selection = session.id }
                }
            }
            Text("最近的会话").font(.app(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
            if let past = past {
                if past.isEmpty { Text("没有已结束的会话").font(.app(size: 12)).foregroundStyle(.tertiary) }
                ForEach(past.prefix(8)) { item in
                    PastRow(item: item).contentShape(Rectangle()).onTapGesture { HistoryModel.shared.open(item) }
                }
            } else {
                SkeletonShape(style: .list(3))
            }
        }
    }
}

