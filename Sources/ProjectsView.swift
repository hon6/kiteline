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
    @Published private(set) var cost7: [String: Double] = [:]
    @Published private(set) var past: [String: [PastItem]] = [:]
    @Published var filter = "all"
    @Published var expanded: String?
    private var seq = 0

    func load() {
        seq += 1
        let current = seq
        loading = true
        Projects.collect(detail: true) { [weak self] payload in
            guard let self = self, current == self.seq else { return }
            self.projects = ((payload["projects"] as? [[String: Any]]) ?? []).compactMap(ProjectItem.init)
                .filter { $0.exists || self.live($0).count > 0 }
            self.errors = payload["errors"] as? [String] ?? []
            self.loading = false
        }
        UsageReport.collect(days: 7) { [weak self] payload in
            var map: [String: Double] = [:]
            for item in payload["projects"] as? [[String: Any]] ?? [] {
                map["\(item["sourceId"] as? String ?? "")\n\(item["cwd"] as? String ?? "")"] = Digest.number(item["cost"])
            }
            self?.cost7 = map
        }
    }

    func toggle(_ project: ProjectItem) {
        expanded = expanded == project.id ? nil : project.id
        guard expanded != nil else { return }
        PastSessions.list(sourceId: project.sourceId, cwd: project.cwd) { [weak self] payload in
            self?.past[project.id] = ((payload["sessions"] as? [[String: Any]]) ?? []).compactMap(PastItem.init).filter { !$0.live }
        }
    }

    /// 这个项目里正在跑的会话（实时的，跟着侧栏变）
    func live(_ project: ProjectItem) -> [SessionItem] {
        KitelineModel.shared.sessions.filter { $0.sourceId == project.sourceId && $0.cwd == project.cwd }
    }

    private func rank(_ project: ProjectItem) -> Int {
        let sessions = live(project)
        if sessions.contains(where: { $0.activity == .waiting }) { return 3 }
        if sessions.contains(where: { $0.activity == .busy }) { return 2 }
        return sessions.isEmpty ? 0 : 1
    }

    var shown: [ProjectItem] {
        projects.filter { project in
            switch filter {
            case "active": return !live(project).isEmpty || project.today > 0
            case "dirty": return project.git.map { $0.dirty || $0.ahead > 0 } ?? false
            default: return true
            }
        }
        .sorted { a, b in rank(a) != rank(b) ? rank(a) > rank(b) : a.lastActive > b.lastActive }
    }

    var summary: String {
        let running = projects.filter { !live($0).isEmpty }.count
        let waiting = projects.filter { live($0).contains { $0.activity == .waiting } }.count
        let dirty = projects.filter { $0.git?.dirty ?? false }.count
        let unpushed = projects.filter { ($0.git?.ahead ?? 0) > 0 }.count
        return [L("%lld 个项目", count: projects.count), L("%lld 个运行中", count: running), waiting > 0 ? L("%lld 个待确认", count: waiting) : nil,
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
struct ProjectsView: View {
    @ObservedObject var model = ProjectsModel.shared
    @ObservedObject var tars = KitelineModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LookSegmented(selection: $model.filter, options: [("all", L("全部")), ("active", L("有活动")), ("dirty", L("有改动"))])
                    .frame(width: Lang.shared.isEnglish ? 330 : 240)   // 英文「Has Activity」放不进 240
                Text(model.summary).font(.app(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
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
        .navigationTitle("项目")
        .navigationSubtitle(model.summary)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.load() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .liveReload(every: 120) { model.load() }
    }
}

struct ProjectCard: View {
    let project: ProjectItem
    let live: [SessionItem]
    let cost: Double
    let expanded: Bool
    let past: [PastItem]?

    var body: some View {
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
        if !live.isEmpty { return (L("%lld 个会话运行中", count: live.count), .green) }
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
                Text("正在运行").font(.app(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
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
                ProgressView().controlSize(.small)
            }
        }
    }
}

