import PhotosUI
import SwiftUI

#if os(iOS)
/// 新会话（iPhone / iPad，2026-11-20 起）：新建任务不再弹面板，推进一个和对话页一样的页面。
/// 中间是「在哪儿开」：从项目页、对话页、待办、提示词链接进来的，项目已经定了，直接显示、不用再选；
/// 没定的（从会话列表进来）在中间挑设备和项目（会话列表正筛着的设备、项目带进来）。
/// 底下是和对话页一样的输入栏：语音 / 键盘切换、输入框、「+」（相册、拍摄），写了字换成绿色「发送」，点了就开始。
/// 发出去以后中间出现这条消息和进展，新会话一出现就换成那个会话的对话页（MainView 的 pendingOpen）。
/// Mac 的面板（待办「创建会话」、项目详情的新任务）照旧用 ProjectPages.swift 的 NewTaskView。
struct NewSessionPage: KLView {
    @EnvModel private var model
    @Environment(\.dismiss) private var dismiss
    let seed: NewTaskSeed

    // 项目
    @State private var projects: [ProjectInfo]?
    @State private var loadError: String?
    @State private var picked: ProjectInfo?
    /// 项目是进来时就定了的（项目页、对话页、待办、链接带来的）：不给换
    @State private var fixed = false
    @State private var query = ""
    /// 设备、项目两排胶囊（同会话列表）：带入会话列表正筛着的，在这里改不影响会话列表
    @State private var sourceFilter = ""
    @State private var projectFilter = ""
    @AppStorage("listSource") private var listSource = ""
    @AppStorage("listProject") private var listProject = ""
    /// 「打开其他文件夹」：在哪台电脑上一层层点
    @State private var browsing: SourceInfo?

    // 选项（同 ComposeTask）
    @State private var scheduleOn = false
    @State private var repeatMode = ComposeTask.initialRepeat
    @State private var date = Date().addingTimeInterval(86400)
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var every = 2
    @State private var until = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var isolated = false
    @State private var canIsolate = false
    @State private var worktrees = 0
    @State private var agents: [ComposeTask.LaunchableAgent] = []
    @State private var agent = "claude-code"

    // 输入栏（同对话页的 Composer）
    @State private var attachments: [ComposeAttachment] = []
    @State private var picks: [KLPhotoItem] = []
    @State private var panelOpen = false
    @State private var showCamera = false
    @State private var clipboardImage = false
    /// 「你可能要发送的截图」：点开「+」时刚截过图，在「+」上方弹个小气泡（同对话页）
    @State private var recentShot: RecentScreenshot.Shot?
    @AppStorage("voiceMode") private var voiceMode = false
    @FocusState private var focused: Bool

    // 发出去以后
    @State private var sent: Sent?
    @State private var overCap: String?
    /// 对话区多高：项目定了时卡片放在中间
    @State private var viewport: CGFloat = 0
    /// 进来时的预选、预填只做一次（读失败点重试时不再来一遍）
    @State private var started = false

    /// 发出去的那条：显示在中间（同对话里我发的消息），下面一行进展
    struct Sent: Identifiable {
        enum Phase: Hashable { case sending, waiting, done }
        let id = UUID()
        var text: String
        var previews: [Data]
        var status: String
        var phase = Phase.sending
    }

    private var scheduled: Bool { seed.scheduleOnly || scheduleOn }
    private var otherAgent: ComposeTask.LaunchableAgent? { scheduled ? nil : agents.first { $0.id == agent } }
    /// 还没选项目时写的字先放在这里，选好项目再挪过去
    private static let looseDraft = "new:"
    private var draftKey: String { picked.map(ComposeTask.draftKey) ?? Self.looseDraft }
    private var draft: String { model.drafts[draftKey] ?? "" }
    private var text: Binding<String> { Binding(get: { model.drafts[draftKey] ?? "" }, set: { model.setDraft(draftKey, $0) }) }
    private var empty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
    /// 发出去了、正等新会话：输入栏先停用（再发会又开一个会话），会话开出来后在它的对话页里接着说
    private var locked: Bool { sent != nil && sent?.phase != .done }
    private var talking: Bool { voiceMode && RemoteConfig.shared.isOn(.voice) }

    var klBody: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let picked { projectCard(picked) } else { pickSection }
                if let sent { sentBubble(sent) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            // 项目定了：卡片在对话区正中（像一段还没开始的对话）；挑项目时从上往下排
            .frame(minHeight: picked != nil && sent == nil ? viewport : 0, alignment: .center)
        }
        // 去掉标题栏、输入栏、键盘那几块：键盘弹出来时卡片跟着挪到键盘上方的正中
        .klOnGeometryChange(for: CGFloat.self) { max(0, $0.size.height - $0.safeAreaInsets.top - $0.safeAreaInsets.bottom) } action: { viewport = $0 }
        .klScrollDismissesKeyboard(.interactively)
        .background(Theme.chatBackground)
        // 点对话区：收起键盘和「+」面板（同对话页）
        .simultaneousGesture(TapGesture().onEnded {
            Keyboard.hide()
            if panelOpen { withAnimation(.klSnappy(duration: 0.2)) { panelOpen = false } }
        })
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .navigationTitle(seed.scheduleOnly ? "新建定时任务" : "新会话")
        .navigationBarTitleDisplayMode(.inline)
        .klNavigationDestination(item: $browsing) { source in
            FolderPicker(sourceId: source.id, machine: source.name,
                         start: FolderStart.usual((projects ?? []).filter { $0.sourceId == source.id }.map(\.cwd))) { path in
                adopt(path, source: source)
            }
        }
        .task { await loadProjects() }
        .task(id: picked?.id) { await loadOptions() }
        .onAppear { checkClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in checkClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in checkClipboard() }
        .klOnChange(of: focused) { _, on in
            if on, panelOpen { withAnimation(.klSnappy(duration: 0.2)) { panelOpen = false } }
            if on { checkClipboard() }
        }
        .klOnChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            panelOpen = false
            Task {
                for item in items {
                    if let raw = try? await item.loadTransferable(type: Data.self), let prepared = ImagePrep.prepare(raw), attachments.count < 6 {
                        attachments.append(ComposeAttachment(name: "image-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
                    }
                }
            }
        }
        .task(id: sent.map { "\($0.id)-\($0.phase)" }) {
            // 等新会话最多 3 分钟（同 awaitNewSession）：还没出现就说明一下，不一直转圈
            guard let id = sent?.id, sent?.phase == .waiting else { return }
            try? await Task.sleep(seconds: 180)
            guard !Task.isCancelled, sent?.id == id, sent?.phase == .waiting else { return }
            sent?.status = L("尚未检测到新会话，可稍后在会话列表中查看")
            sent?.phase = .done
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.9), let prepared = ImagePrep.prepare(data), attachments.count < 6 {
                    attachments.append(ComposeAttachment(name: "photo-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
                }
            }
            .ignoresSafeArea()
        }
        .confirmPanel(overCap.map { L("%@。仍要开始吗？", $0) } ?? "", isPresented: Binding(get: { overCap != nil }, set: { if !$0 { overCap = nil } }),
                      confirm: L("仍然开始")) { send(override: true) }
        .paywallHost()
    }

    // MARK: 中间：项目

    /// 项目定了：一张卡片写着在哪台电脑的哪个项目里开，下面是这次可选的（Agent、定时、独立分支）
    private func projectCard(_ p: ProjectInfo) -> some View {
        VStack(spacing: 10) {
            // 同 Mac 的新会话标签页：图标、一句说明（「新会话」已经写在标题栏上）
            if sent == nil {
                VStack(spacing: 8) {
                    Image(systemName: scheduled ? "alarm" : "plus.bubble")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(Theme.claude)
                    Text(scheduled ? "写好任务内容后点「创建」" : "发送第一条消息即开始新的会话")
                        .font(.ui(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.bottom, 6)
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Avatar(text: Format.initials(p.name), size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.ui(.headline)).lineLimit(1)
                        Text("\(p.sourceName) · \(Bytes.shortPath(p.cwd))").font(.ui(.caption)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    if !fixed, sent == nil {
                        Button { change() } label: { Text("更换").font(.ui(.subheadline)) }
                            .buttonStyle(.steady(.plain))
                            .foregroundStyle(Theme.claude)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                if sent == nil { options(p) }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if sent == nil {
                Text(footnote(p)).font(.ui(.footnote)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder private func options(_ p: ProjectInfo) -> some View {
        if !scheduled, !agents.isEmpty {
            row {
                Text("Agent")
                Spacer(minLength: 8)
                Picker("Agent", selection: $agent) {
                    Text(verbatim: "Claude Code").tag("claude-code")
                    ForEach(agents) { Text(verbatim: $0.name).tag($0.id) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
        }
        if !seed.scheduleOnly {
            row { Toggle("定时执行", isOn: $scheduleOn.animation(.klSnappy)) }
                .klOnChange(of: scheduleOn) { _, on in if on { panelOpen = false } }
        }
        if scheduled {
            row {
                Text("重复")
                Spacer(minLength: 8)
                Picker("重复", selection: $repeatMode) {
                    Text("每天").tag("daily")
                    Text("工作日（周一至周五）").tag("weekdays")
                    Text("每隔几小时").tag("hourly")
                    Text("仅一次").tag("once")
                }
                .pickerStyle(.menu).labelsHidden()
            }
            if repeatMode == "once" { row { DatePicker("日期", selection: $date, displayedComponents: .date) } }
            if repeatMode == "hourly" {
                row {
                    Text("间隔")
                    Spacer(minLength: 8)
                    Picker("间隔", selection: $every) {
                        ForEach([1, 2, 3, 4, 6, 8, 12], id: \.self) { hours in Text(L("每 %lld 小时", count: hours)).tag(hours) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                row { DatePicker("开始时间", selection: $time, displayedComponents: .hourAndMinute) }
                row { DatePicker("结束时间", selection: $until, displayedComponents: .hourAndMinute) }
            } else {
                row { DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute) }
            }
        } else if canIsolate {
            row {
                Toggle(isOn: $isolated) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("在独立分支里做")
                        Text(L("新建 Git worktree（分支以 tars/ 开头），Claude 仅在其中修改，不影响主目录中正在进行的改动") + (worktrees > 0 ? L("（此仓库已有 %@ 个 Kiteline 分支）", "\(worktrees)") : ""))
                            .font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 卡片里的一行：上面一条细分隔线（同分组列表）
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .frame(minHeight: 30)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .overlay(alignment: .top) { Divider().padding(.leading, 14) }
    }

    private func footnote(_ p: ProjectInfo) -> String {
        if scheduled {
            return L("到达设定时间后，Kiteline 将在该项目的 VS Code 窗口中新建会话并发送任务（电脑需保持开机；因睡眠错过的任务会在 1 小时内补执行）。")
        }
        if let otherAgent {
            return otherAgent.viaUI ? L("将在电脑上的 %@ 中新建任务并发送（会短暂切到 %@）", otherAgent.name, otherAgent.name)
                : L("将在电脑后台运行 %@，可在手机上查看和操作", otherAgent.name)
        }
        let ssh = p.kind == "ssh" ? L("（Remote-SSH，约需十余秒）") : ""
        if isolated, canIsolate { return L("会在电脑上为新分支打开一个新的 VS Code 窗口") + ssh }
        return p.open || p.live > 0 ? L("在已打开的 VS Code 窗口里新建会话") : L("将先在电脑上打开此项目的 VS Code 窗口") + ssh
    }

    // MARK: 中间：挑项目（项目没定时）

    @ViewBuilder private var pickSection: some View {
        let all = projects ?? []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searched = all.filter { p in q.isEmpty || "\(p.name) \(p.cwd) \(p.sourceName) \(p.title ?? "")".lowercased().contains(q) }
        let shown = searched.filter { (sourceFilter.isEmpty || $0.sourceId == sourceFilter) && (projectFilter.isEmpty || $0.name == projectFilter) }
        let sources = sourceOptions(searched)
        let names = projectOptions(searched)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("选择项目").font(.ui(.headline))
                Text(seed.scheduleOnly ? "定时任务将在所选项目中运行" : "新会话将在所选电脑的项目目录中开始")
                    .font(.ui(.footnote)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            if projects == nil {
                if let loadError {
                    Button { Task { await loadProjects() } } label: {
                        Text(L("%@　点此重试", loadError)).font(.ui(.subheadline)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(RowButtonStyle())
                } else {
                    SkeletonPage("正在读取项目…", style: .list(5, trail: .none), padded: false)
                }
            } else {
                if all.count > 8 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索项目", text: $query).submitLabel(.search)
                    }
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(Theme.card, in: Capsule())
                }
                if sources.count > 1 || !sourceFilter.isEmpty {
                    ScopeBar(symbol: "desktopcomputer", allTitle: L("全部设备"), options: sources, selection: $sourceFilter, bleed: 12)
                }
                if names.count > 1 || !projectFilter.isEmpty {
                    ScopeBar(symbol: "folder", allTitle: L("全部项目"), options: names, selection: $projectFilter, bleed: 12)
                }
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, p in
                        Button { pick(p) } label: {
                            ProjectPickRow(project: p).padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                        .overlay(alignment: .top) { if index > 0 { Divider().padding(.leading, 62) } }
                    }
                    if shown.isEmpty {
                        Text(all.isEmpty ? "暂无使用过 Claude Code 的项目" : "无匹配的项目").font(.ui(.subheadline)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(16)
                    }
                    if model.hostFeatures.contains("dirs") {
                        otherFolderRow.padding(.horizontal, 14).padding(.vertical, 9)
                            .overlay(alignment: .top) { Divider().padding(.leading, 14) }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("各机器上最近使用过 Claude Code 的目录、正在运行的会话，以及电脑上已打开的 VS Code 窗口。")
                    .font(.ui(.footnote)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    /// 最后一行「打开其他文件夹…」（同 NewTaskView）：筛着某台设备就在它上面选；没筛、在线的不止一台时先挑电脑
    @ViewBuilder private var otherFolderRow: some View {
        let online = model.sources.filter(\.online)
        let targets = online.filter { $0.id == sourceFilter }.isEmpty ? online : online.filter { $0.id == sourceFilter }
        let label = HStack(spacing: 10) {
            Image(systemName: "plus").font(.ui(.body).weight(.semibold)).foregroundStyle(Theme.claude)
                .frame(width: 38, height: 38)
                .background(Circle().strokeBorder(Theme.claude.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            VStack(alignment: .leading, spacing: 2) {
                Text("打开其他文件夹…").foregroundStyle(Theme.claude).lineLimit(1)
                Text(targets.count == 1 ? L("在「%@」上选择任意文件夹，在其中新建会话", targets[0].name) : L("选择任意电脑上的任意文件夹，在其中新建会话"))
                    .font(.ui(.caption)).foregroundStyle(Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        if targets.count > 1 {
            Menu {
                ForEach(targets, id: \.id) { source in Button(source.name) { browsing = source } }
            } label: { label }
        } else {
            Button { browsing = targets.first } label: { label }
                .buttonStyle(RowButtonStyle())
                .disabled(targets.isEmpty)
        }
    }

    private func sourceOptions(_ searched: [ProjectInfo]) -> [ScopeBar.Option] {
        let rank = Dictionary(model.sources.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var names: [String: String] = [:]
        for p in projects ?? [] where names[p.sourceId] == nil { names[p.sourceId] = p.sourceName }
        let inProject = searched.filter { projectFilter.isEmpty || $0.name == projectFilter }
        return names.keys.sorted { (rank[$0] ?? .max, names[$0] ?? "") < (rank[$1] ?? .max, names[$1] ?? "") }.map { id in
            ScopeBar.Option(id: id, title: names[id] ?? id, count: inProject.filter { $0.sourceId == id }.count)
        }
    }

    private func projectOptions(_ searched: [ProjectInfo]) -> [ScopeBar.Option] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for p in searched where sourceFilter.isEmpty || p.sourceId == sourceFilter {
            if counts[p.name] == nil { order.append(p.name) }
            counts[p.name, default: 0] += 1
        }
        if !projectFilter.isEmpty, counts[projectFilter] == nil { order.insert(projectFilter, at: 0) }
        return order.map { ScopeBar.Option(id: $0, title: $0, count: counts[$0] ?? 0) }
    }

    // MARK: 发出去以后

    private func sentBubble(_ s: Sent) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !s.previews.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(s.previews.enumerated()), id: \.offset) { _, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
            if !s.text.isEmpty {
                Text(s.text).foregroundStyle(Theme.meText)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.meBubble, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            HStack(spacing: 6) {
                if s.phase != .done { ProgressView().controlSize(.small) }
                Text(s.status).font(.ui(.footnote)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: 底部输入栏（样子、按钮同对话页的 Composer）

    private var inputBar: some View {
        VStack(spacing: 0) {
            if !attachments.isEmpty { attachmentStrip }
            if clipboardImage, !talking, focused || panelOpen, attachments.count < 6 { pasteRow.transition(.opacity) }
            HStack(alignment: .bottom, spacing: Bar.spacing - Bar.iconInset) {
                if RemoteConfig.shared.isOn(.voice) {
                    RoundIcon(symbol: voiceMode ? "keyboard" : "waveform", label: voiceMode ? L("切换到键盘输入") : L("切换到语音输入")) {
                        voiceMode.toggle()
                        panelOpen = false
                        focused = !voiceMode
                    }
                }
                if talking {
                    // 说完转成文字接在后面，切回键盘，改好再发（新会话还没有，不能像对话页那样直接发语音）
                    HoldToDictate { said in
                        text.wrappedValue = Dictation.append(said, to: text.wrappedValue)
                        voiceMode = false
                        focused = true
                    }
                } else {
                    field
                }
                if !empty, !talking {
                    Button { send() } label: {
                        Text(scheduled ? "创建" : "发送").font(.app(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 56, height: 34)
                            .background(Theme.wechatGreen, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .frame(width: Bar.iconWidth + 26, height: Bar.rowHeight)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if !scheduled {   // 定时任务只带文字：不给「+」
                    RoundIcon(symbol: "plus", label: panelOpen ? L("收起更多功能") : L("更多功能")) {
                        focused = false
                        withAnimation(.klSnappy(duration: 0.25)) { panelOpen.toggle() }
                        if panelOpen, attachments.count < 6 {
                            Task {
                                let shot = await RecentScreenshot.find()
                                withAnimation(.klSnappy) { recentShot = shot }
                            }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let recentShot {
                            RecentShotBubble(shot: recentShot, current: $recentShot) { prepared in
                                guard attachments.count < 6 else { return }
                                attachments.append(ComposeAttachment(name: "screenshot-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
                                withAnimation(.klSnappy(duration: 0.25)) { panelOpen = false }
                            }
                            .fixedSize()
                            .offset(y: -(Bar.rowHeight + 6))
                            .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                        }
                    }
                }
            }
            .padding(.horizontal, Bar.edge - Bar.iconInset)
            .padding(.vertical, Bar.spacing)
            .animation(.klSnappy(duration: 0.2), value: empty)
            if panelOpen { panel.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .background(Theme.inputBar)
        .overlay(alignment: .top) { Divider() }
        .disabled(locked)
    }

    private var field: some View {
        KLTextField(locked ? L("会话开始后可继续发送")
                  : picked == nil ? L("选好项目后，描述要完成的任务")
                  : (otherAgent.map { L("描述要 %@ 完成的任务", $0.name) } ?? L("描述要 Claude 完成的任务")),
                  text: text, axis: .vertical)
            .klLineLimit(1...6)
            .focused($focused)
            .submitLabel(.send)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .klOnChange(of: draft) { old, new in
                // 换行键 = 发送（同对话页）：只认「在末尾多打了一个换行」，粘贴进来的多行文字不算
                if new == old + "\n" {
                    model.setDraft(draftKey, old)
                    send()
                }
            }
    }

    private var attachmentStrip: some View {
        KiteHScroll {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    ZStack(alignment: .topTrailing) {
                        if let image = UIImage(data: item.preview) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        Button { attachments.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6)).font(.ui(.title3))
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("移除图片")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
    }

    /// 剪贴板里有图：一条提示 + 系统的「粘贴」（同对话页）
    private var pasteRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            Text("剪贴板里有图片").font(.ui(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            PasteButton(supportedContentTypes: [.image]) { providers in
                Task {
                    ClipboardImage.handled = ClipboardImage.changeCount
                    clipboardImage = false
                    let images = await DroppedImages.load(providers)
                    if images.isEmpty { model.flash(L("无法读取剪贴板里的图片")) }
                    for raw in images where attachments.count < 6 {
                        guard let prepared = ImagePrep.prepare(raw) else { continue }
                        attachments.append(ComposeAttachment(name: "image-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
                    }
                    panelOpen = false
                }
            }
            .labelStyle(.titleAndIcon)
            .klButtonBorderShape(.capsule)
            .controlSize(.small)
            .tint(Theme.wechatGreen)
            Button {
                ClipboardImage.handled = ClipboardImage.changeCount
                withAnimation(.klSnappy) { clipboardImage = false }
            } label: {
                Image(systemName: "xmark").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.steady(.plain))
            .accessibilityLabel("不粘贴")
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .padding(.top, 8)
    }

    /// 「+」面板：相册、拍摄（新会话只能带图）
    private var panel: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        return LazyVGrid(columns: columns, spacing: 18) {
            KLPhotosPicker(selection: $picks, maxSelectionCount: max(1, 6 - attachments.count)) {
                PanelTile(symbol: "photo", title: L("相册"))
            }
            .buttonStyle(.steady(.plain))
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { panelOpen = false; showCamera = true } label: { PanelTile(symbol: "camera", title: L("拍摄")) }
                    .buttonStyle(.steady(.plain))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .overlay(alignment: .top) { Divider() }
    }

    private func checkClipboard() {
        let offer = ClipboardImage.offer
        if offer != clipboardImage { withAnimation(.klSnappy) { clipboardImage = offer } }
    }

    // MARK: 数据

    private func loadProjects() async {
        if !started {
            started = true
            if let preset = seed.preset {
                picked = preset
                fixed = true
                focusSoon()
            }
            fillInitial()
        }
        // 先用上次取到的列表（项目不常变），马上能选；后台再取新的换上
        if projects == nil, let cached = model.api.cached(ProjectsReply.self, "/api/projects") { adoptProjects(cached.projects, first: true) }
        do {
            let reply = try await model.api.getCaching(ProjectsReply.self, "/api/projects")
            adoptProjects(reply.projects, first: projects == nil)
            loadError = nil
        } catch { if projects == nil { loadError = error.localizedDescription } }
    }

    /// 列表到了。first：头一次到才按待办 / 链接预选、带入筛选；后面换新列表时不动已经筛的、选的
    private func adoptProjects(_ list: [ProjectInfo], first: Bool) {
        projects = list.filter(\.exists)
        guard first, picked == nil else { return }
        let all = projects ?? []
        if let match = seed.match, let found = all.first(where: { $0.sourceId == match.sourceId && $0.cwd == match.cwd }) {
            pick(found, fixed: true)
            return
        }
        if let hint = seed.hint {
            let found = all.filter { PromptLink.matches(hint, cwd: $0.cwd, name: $0.name) }
            if found.count == 1 { pick(found[0], fixed: true); return }
            if let first = found.first { projectFilter = first.name; return }
        }
        // 带入会话列表正筛着的设备、项目（列表当没筛的这里也不筛）
        if model.sources.contains(where: { $0.id == listSource }), all.contains(where: { $0.sourceId == listSource }) { sourceFilter = listSource }
        if model.sessions.contains(where: { $0.projectName == listProject }),
           all.contains(where: { $0.name == listProject }) { projectFilter = listProject }
        // 筛着某个项目、只对上一个：环境已经说明了在哪儿开，直接选上（可以换）
        if !projectFilter.isEmpty {
            let only = all.filter { $0.name == projectFilter && (sourceFilter.isEmpty || $0.sourceId == sourceFilter) }
            if only.count == 1 { pick(only[0]) }
        }
    }

    /// 选上一个项目：没选项目时写的字跟过去，键盘弹出来接着写
    private func pick(_ p: ProjectInfo, fixed: Bool = false) {
        let loose = (model.drafts[Self.looseDraft] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ComposeTask.draftKey(p)
        if !loose.isEmpty, (model.drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.setDraft(key, model.drafts[Self.looseDraft] ?? "")
            model.setDraft(Self.looseDraft, "")
        }
        withAnimation(.klSnappy) { picked = p }
        self.fixed = fixed
        focusSoon()
    }

    /// 换项目：写了的字先放回「没选项目」那一份，选好再跟过去
    private func change() {
        if let picked {
            let key = ComposeTask.draftKey(picked)
            let current = model.drafts[key] ?? ""
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.setDraft(Self.looseDraft, current)
                model.setDraft(key, "")
            }
        }
        focused = false
        withAnimation(.klSnappy) { picked = nil }
    }

    /// 待办、链接带来的内容：进来时填进当前这份草稿（已经有草稿就不盖掉）；还没选项目的，选好时跟过去
    private func fillInitial() {
        guard let initial = seed.initialText, !initial.isEmpty,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.setDraft(draftKey, initial)
    }

    private func focusSoon() {
        guard !talking else { return }
        Task {
            try? await Task.sleep(milliseconds: 450)   // 等推进来的动画走完再弹键盘
            focused = true
        }
    }

    /// 打开其他文件夹选好的：放进列表最前面并选上
    private func adopt(_ path: String, source: SourceInfo) {
        let project = projects?.first { $0.sourceId == source.id && $0.cwd == path } ?? ProjectInfo(picked: path, source: source)
        if projects?.contains(where: { $0.id == project.id }) == false { projects?.insert(project, at: 0) }
        browsing = nil
        pick(project)
    }

    /// 这个项目能不能放独立分支、这台电脑上还能选哪几家 agent（同 ComposeTask）
    private func loadOptions() async {
        canIsolate = false
        worktrees = 0
        isolated = false
        agents = []
        agent = "claude-code"
        guard let p = picked else { return }
        async let repo = try? model.api.get("/api/repo-info", ["sourceId": p.sourceId, "cwd": p.cwd])
        async let launchable = try? model.api.get("/api/launchable", ["sourceId": p.sourceId])
        let (info, reply) = await (repo, launchable)
        guard picked?.id == p.id else { return }
        if let info, info["repo"] as? String != nil || info["repo"] as? Bool == true {
            canIsolate = true
            worktrees = (info["worktrees"] as? [Any])?.count ?? 0
        }
        agents = ((reply?["agents"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, id != "claude-code" else { return nil }
            return ComposeTask.LaunchableAgent(id: id, name: row["name"] as? String ?? id, viaUI: row["via"] as? String == "ui")
        }
    }

    // MARK: 发送

    private func send(override: Bool = false) {
        guard !locked else { return }
        guard let project = picked else {
            model.flash(L("请先选择项目"))
            focused = false
            return
        }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || (!scheduled && !attachments.isEmpty) else { model.flash(L("请先填写任务内容")); focused = true; return }
        let images = scheduled ? [] : attachments
        let key = draftKey
        Haptics.tap()
        focused = false
        panelOpen = false
        withAnimation(.klSnappy) {
            sent = Sent(text: prompt, previews: images.map(\.preview),
                        status: scheduled ? L("正在创建…") : (project.open || project.live > 0 || otherAgent != nil ? L("正在新建会话…") : L("正在打开 VS Code…")))
        }
        model.setDraft(key, "")
        attachments = []
        Task { await go(project: project, prompt: prompt, images: images, draftKey: key, override: override) }
    }

    /// 没发成：字和图放回输入栏，中间那条拿掉
    private func restore(_ prompt: String, _ images: [ComposeAttachment], _ key: String) {
        model.setDraft(key, prompt)
        attachments = images
        withAnimation(.klSnappy) { sent = nil }
    }

    private func go(project: ProjectInfo, prompt: String, images: [ComposeAttachment], draftKey key: String, override: Bool) async {
        if scheduled {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            let d = Calendar.current.dateComponents([.year, .month, .day], from: date)
            var body: [String: Any] = [
                "sourceId": project.sourceId, "cwd": project.cwd, "prompt": prompt, "repeat": repeatMode,
                "time": String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0),
                "date": String(format: "%04d-%02d-%02d", d.year ?? 2026, d.month ?? 1, d.day ?? 1),
            ]
            if repeatMode == "hourly" {
                let last = Calendar.current.dateComponents([.hour, .minute], from: until)
                body["every"] = every
                body["until"] = String(format: "%02d:%02d", last.hour ?? 23, last.minute ?? 0)
            }
            do {
                let reply = try await model.api.post("/api/schedules", body: body)
                model.flash(L("已创建：%@", "\((reply["schedule"] as? [String: Any])?["label"] as? String ?? "定时任务")"))
                dismiss()
            } catch {
                restore(prompt, images, key)
                model.show(error)
            }
            return
        }
        do {
            var body: [String: Any] = [
                "sourceId": project.sourceId, "cwd": project.cwd, "text": prompt,
                "images": images.map { ["name": $0.name, "data": $0.data.base64EncodedString()] },
                "override": override, "worktree": isolated && canIsolate,
            ]
            if let otherAgent { body["agent"] = otherAgent.id }
            // 带请求编号：电脑按编号去重，等不到回应时重发一次也只开一个会话（勾了独立分支要先建分支、开新窗口，常要十几秒）。
            // 老版本电脑端不认编号，重发会开出两个，所以只对声明了 newSessionOnce 的带
            if model.hostFeatures.contains("newSessionOnce") { body["cid"] = UUID().uuidString }
            let reply = try await model.api.post("/api/new-session", body: body)
            // 新会话一出现就打开它（MainView 看到 pendingOpen 把这一页换成那个会话）
            model.awaitNewSession(sourceId: project.sourceId, cwd: reply["cwd"] as? String ?? project.cwd)
            let status: String
            var phase = Sent.Phase.waiting
            if let branch = reply["branch"] as? String { status = L("已在独立分支 %@ 开始，等待新会话出现…", branch) }
            else if reply["submitted"] as? Bool == true { status = L("已开始，等待新会话出现…") }
            else { status = reply["message"] as? String ?? L("已新建会话"); phase = .done }
            withAnimation(.klSnappy) {
                sent?.status = status
                sent?.phase = phase
            }
        } catch let error as APIError where error.data["capExceeded"] as? Bool == true {
            restore(prompt, images, key)
            overCap = error.message
        } catch {
            restore(prompt, images, key)
            model.show(error)
        }
    }
}

extension NewTaskSeed {
    /// 对话页「在此项目中新建会话」：项目就是这个会话所在的（项目列表里还没有的也照样定下）
    @MainActor
    static func session(_ key: String, model: AppModel) -> NewTaskSeed {
        guard let session = model.session(key), let cwd = session.cwd else { return NewTaskSeed() }
        let project = model.home.projects.first { $0.sourceId == session.sourceId && $0.cwd == cwd }
            ?? model.sources.first { $0.id == session.sourceId }.map { ProjectInfo(picked: cwd, source: $0) }
        return NewTaskSeed(preset: project)
    }
}
#endif
