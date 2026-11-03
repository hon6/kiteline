import AppKit
import SwiftUI
import KitelineKit

/// Mac 上的「新任务」：选项目 + 写要求，在这个项目的 VS Code 窗口里新建一个 Claude Code 会话
struct NewTaskSheet: View {
    struct Project: Identifiable, Hashable {
        var sourceId: String
        var sourceName: String
        var kind: String
        var cwd: String
        var name: String
        var title: String?
        var live: Int
        var open: Bool
        var lastActive: Double
        var id: String { "\(sourceId)\n\(cwd)" }

        init?(_ item: [String: Any]) {
            guard let sourceId = item["sourceId"] as? String, let cwd = item["cwd"] as? String,
                  item["exists"] as? Bool != false else { return nil }
            self.sourceId = sourceId
            self.cwd = cwd
            sourceName = ServerLang.machine(item["sourceName"] as? String ?? "")
            kind = item["kind"] as? String ?? "local"
            name = item["name"] as? String ?? (cwd as NSString).lastPathComponent
            title = item["title"] as? String
            live = item["live"] as? Int ?? 0
            open = item["open"] as? Bool ?? false
            lastActive = Digest.number(item["lastActive"])
        }
    }

    @ObservedObject var model = KitelineModel.shared
    @State private var projects: [Project] = []
    @State private var selection: Project.ID?
    /// 从链接、会话带进来的选中项：列表长、它排在下面时滚到眼前（不然看着像没选中）
    @State private var reveal: Project.ID?
    @State private var query = ""
    /// 设备（来源 id）、项目（项目名 = 目录最后一级）筛选，空 = 全部：打开时带入侧栏会话列表正筛着的，在这里改不影响侧栏
    @State private var sourceFilter = ""
    @State private var projectFilter = ""
    @AppStorage("listSource") private var listSource = ""
    @AppStorage("listProject") private var listProject = ""
    @State private var text = ""
    /// 附的图：开始时先传到那台机器（watcher 的 inbox），任务里附上路径，Claude 自己去读（同手机新任务、发消息）
    @State private var images: [TarsTaskImage] = []
    @State private var loading = true
    @State private var sending = false
    @State private var message: String?
    /// 超过每日花费上限时，再点一次「开始」才真的开
    @State private var capConfirmed = false
    /// 在独立分支（git worktree）里做
    @State private var isolated = false
    /// now / daily / weekdays / once
    @State private var timing = "now"
    @State private var when = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86400)) ?? Date()

    init(attach: [TarsTaskImage] = []) {
        _images = State(initialValue: attach)
    }

    private var selected: Project? { projects.first { $0.id == selection } }
    /// 搜索词筛过的（设备、项目两排的个数按它算）
    private var searched: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return projects }
        return projects.filter { "\($0.name) \($0.cwd) \($0.sourceName) \($0.title ?? "")".lowercased().contains(q) }
    }
    private var shown: [Project] {
        searched.filter { (sourceFilter.isEmpty || $0.sourceId == sourceFilter) && (projectFilter.isEmpty || $0.name == projectFilter) }
    }

    /// 设备那排：有项目的设备，按侧栏的先后；个数跟着项目筛选走
    private var sourceOptions: [ScopeBar.Option] {
        let rank = Dictionary(model.sources.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var names: [String: String] = [:]
        for project in projects where names[project.sourceId] == nil { names[project.sourceId] = project.sourceName }
        let inProject = searched.filter { projectFilter.isEmpty || $0.name == projectFilter }
        return names.keys.sorted { (rank[$0] ?? .max, names[$0] ?? "") < (rank[$1] ?? .max, names[$1] ?? "") }.map { id in
            ScopeBar.Option(id: id, title: names[id] ?? id, count: inProject.filter { $0.sourceId == id }.count)
        }
    }

    /// 项目那排：按列表里的先后（最近用过的在前），个数跟着设备筛选走；筛着的那个这台设备上没有也列着
    private var projectOptions: [ScopeBar.Option] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for project in searched where sourceFilter.isEmpty || project.sourceId == sourceFilter {
            if counts[project.name] == nil { order.append(project.name) }
            counts[project.name, default: 0] += 1
        }
        if !projectFilter.isEmpty, counts[projectFilter] == nil { order.insert(projectFilter, at: 0) }
        return order.map { ScopeBar.Option(id: $0, title: $0, count: counts[$0] ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题「新任务」在面板的标题栏里（同别的弹窗）；这一行是说明和搜索
            HStack(alignment: .center, spacing: 12) {
                Text("选择项目并填写任务内容，可附截图。将在该项目的 VS Code 窗口中新建会话（窗口未打开时将先打开）。")
                    .font(.app(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                TextField("搜索项目", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            .panelDragBackground()   // 这一行的空白处按住能拖动面板
            scopeBars
            ScrollViewReader { proxy in
                List(shown, selection: $selection) { project in
                    row(project).tag(project.id)
                }
                .onChange(of: reveal) { _, id in
                    guard let id else { return }
                    reveal = nil
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(minHeight: 140, idealHeight: 220, maxHeight: .infinity)   // 面板拉高时多出来的给项目列表
            .overlay {
                if loading { ProgressView() } else if projects.isEmpty {
                    Text("暂无使用过 Claude Code 的项目").foregroundStyle(.secondary)
                } else if shown.isEmpty {
                    Text("没有匹配的项目").foregroundStyle(.secondary)
                }
            }
            // 选中的被筛掉了就不选；筛得只剩一个时直接选上
            .onChange(of: shown.map(\.id)) { _, ids in
                if let current = selection, !ids.contains(current) { selection = nil }
                if selection == nil, ids.count == 1 { selection = ids[0] }
            }
            // 多行文字（⌘V 贴截图）、听写、图片一栏（拖进来、粘贴、选文件、从「照片」）：同 Mac 的「加入待办」
            TarsTaskInput(text: $text, images: $images,
                          placeholder: selected.map { L("请描述需要 Claude 在「%@」中完成的任务", "\($0.name)") } ?? L("请先在上方选择项目"),
                          enabled: !sending, submitTitle: timing == "now" ? L("开始") : L("创建"), onSubmit: start)
            HStack(spacing: 10) {
                LookSegmented(selection: $timing, options: [("now", L("现在开始")), ("daily", L("每天")), ("weekdays", L("工作日")), ("once", L("仅一次"))])
                .labelsHidden()
                .frame(width: Lang.shared.isEnglish ? 340 : 280)   // 英文「Start Now」「Weekdays」放不进 280
                if timing != "now" {
                    DatePicker("", selection: $when, displayedComponents: timing == "once" ? [.date, .hourAndMinute] : [.hourAndMinute])
                        .labelsHidden()
                }
                Spacer()
                Toggle("在独立分支中进行（git worktree）", isOn: $isolated)
                    .toggleStyle(.checkbox)
                    .font(.app(size: 12))
                    .disabled(timing != "now")
                    .help("在仓库旁新建 worktree 及以 tars/ 开头的分支，Claude 仅在其中修改，不影响主目录中正在进行的改动")
            }
            HStack {
                if let message = message {
                    Label(message, systemImage: "exclamationmark.triangle").font(.app(size: 11.5)).foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let project = selected {
                    Text(project.open || project.live > 0 ? "在已打开的 VS Code 窗口里新建会话"
                         : "将先打开此项目的 VS Code 窗口\(project.kind == "ssh" ? "（Remote-SSH，要十几秒）" : "")")
                        .font(.app(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { close() }.keyboardShortcut(.cancelAction).tarsButton()
                // 文字框里回车是换行（任务常常是一整段），⌘回车开始
                Button(sending ? "正在新建…" : (timing == "now" ? "开始" : "创建定时任务")) { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .tarsButton(prominent: true)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        // 打开时 600 宽，能拖边改大小
        .frame(minWidth: 520, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L("新任务"))   // 放进面板的标题栏
        .onAppear(perform: load)
    }

    /// 选了项目、写了字或附了图（只附图时 Claude 收到「请查看我发来的图片」，同手机）
    private var canStart: Bool {
        !sending && selected != nil && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    /// 设备、项目两排胶囊（同侧栏会话列表）：不止一台设备、不止一个项目时才有
    @ViewBuilder private var scopeBars: some View {
        let sources = sourceOptions
        let names = projectOptions
        if sources.count > 1 || !sourceFilter.isEmpty || names.count > 1 || !projectFilter.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if sources.count > 1 || !sourceFilter.isEmpty {
                    ScopeBar(symbol: "desktopcomputer", allTitle: L("全部设备"), options: sources, selection: $sourceFilter, bleed: 0)
                }
                if names.count > 1 || !projectFilter.isEmpty {
                    ScopeBar(symbol: "folder", allTitle: L("全部项目"), options: names, selection: $projectFilter, bleed: 0)
                }
            }
        }
    }

    private func row(_ project: Project) -> some View {
        HStack(spacing: 10) {
            SessionAvatar(key: project.id, title: project.name, activity: .idle, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.app(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(project.sourceName) · \(project.cwd)").font(.app(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if project.live > 0 {
                tag(L("%lld 个会话", count: project.live), .tarsBrand)
            } else if project.open {
                tag(L("已打开"), .green)
            }
            if project.lastActive > 0 {
                Text(Format.short(project.lastActive)).font(.app(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.app(size: 10.5, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func load() {
        // 从提示词链接来的：提示词先填进去（用户看过、改好再开始）
        let link = model.newTaskLink
        model.newTaskLink = nil
        if let link, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = link.prompt }
        Projects.collect { payload in
            projects = ((payload["projects"] as? [[String: Any]]) ?? []).compactMap(Project.init)
            loading = false
            // 带入侧栏正筛着的设备、项目（侧栏当没筛的——机器不在了、项目里已没有运行中的会话——这里也不筛）
            if model.sources.contains(where: { $0.id == listSource }), projects.contains(where: { $0.sourceId == listSource }) {
                sourceFilter = listSource
            }
            if model.sessions.contains(where: { $0.folder == listProject }), projects.contains(where: { $0.name == listProject }) {
                projectFilter = listProject
            }
            if let preset = model.newTaskPreset, let project = projects.first(where: { $0.sourceId == preset.sourceId && $0.cwd == preset.cwd }) {
                // 指定了项目（从某个会话、项目页来的）：筛选和它对不上的那一项放开，免得选中的看不见
                if !sourceFilter.isEmpty, sourceFilter != project.sourceId { sourceFilter = "" }
                if !projectFilter.isEmpty, projectFilter != project.name { projectFilter = "" }
                selection = project.id
                reveal = project.id
            }
            // 链接里写了项目：只对上一个就选中，几台电脑上都有就筛出来让你挑
            if let hint = link?.project {
                let found = projects.filter { PromptLink.matches(hint, cwd: $0.cwd, name: $0.name) }
                if found.count == 1 {
                    sourceFilter = ""
                    projectFilter = ""
                    selection = found[0].id
                    reveal = found[0].id
                } else if let first = found.first {
                    sourceFilter = ""
                    projectFilter = first.name
                }
            }
        }
    }

    private func start() {
        guard canStart, let project = selected,
              let source = AppState.shared.config.sources.first(where: { $0.id == project.sourceId }) else { return }
        sending = true
        message = nil
        // 现在开始的先看今天的花费上限（定时的到点才花钱，不查）
        guard timing != "now" || capConfirmed else {
            SpendGuard.check { reason in
                capConfirmed = true
                if let reason = reason {
                    sending = false
                    message = L("%@。再次点击「开始」仍将新建。", "\(reason)")
                } else {
                    submit(project, source)
                }
            }
            return
        }
        submit(project, source)
    }

    /// 附的图先传到那台机器，任务正文后面附上路径（定时任务也是现在传好：inbox 里的图不会被清掉，到点照样读得到）
    private func submit(_ project: Project, _ source: SourceConfig) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = images.map { Delivery.Attachment(name: $0.name, data: $0.data) }
        Delivery.stage(attachments, via: AppState.shared.source(withId: project.sourceId)) { staged in
            switch staged {
            case .success(let paths): create(project, source, prompt: Delivery.compose(text: text, paths: paths))
            case .failure(let error):
                sending = false
                message = L("图片传送失败：%@", "\(error.description)")
            }
        }
    }

    private func create(_ project: Project, _ source: SourceConfig, prompt: String) {
        if timing != "now" {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
            let time = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
            let date = String(format: "%04d-%02d-%02d", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
            switch Scheduler.shared.add(sourceId: project.sourceId, cwd: project.cwd, prompt: prompt, repeatMode: timing, time: time, date: date) {
            case .success: close()
            case .failure(let error):
                sending = false
                message = error.message
            }
            return
        }
        func launch(_ cwd: String, _ prompt: String) {
            NewSession.start(source: source, cwd: cwd, prompt: prompt, submit: true) { outcome in
                sending = false
                if outcome.ok { close() } else { message = outcome.message }
            }
        }
        guard isolated else { launch(project.cwd, prompt); return }
        guard let connection = AppState.shared.source(withId: project.sourceId) else {
            sending = false; message = L("目标机器离线"); return
        }
        Worktree.prepare(connection, cwd: project.cwd, prompt: prompt) { result in
            switch result {
            case .success(let prepared): launch(prepared.cwd, prepared.prompt)
            case .failure(let error): sending = false; message = L("独立分支创建失败：%@", "\(error.description)")
            }
        }
    }

    private func close() {
        model.newTaskPreset = nil
        model.showNewTask = false
    }
}
