#if os(iOS)
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// 别的 App（微信、企业微信、文件、邮件……）里「用其他应用打开」选了 Kiteline：文件先拷进来，弹出「发送到会话」面板，
/// 补充几句话，发给一个已有会话，或者选个项目新建会话（同电脑上把文件拖进 Claude 的输入框）。
/// 图片照对话里发图那样发（压缩后显示在对话里）；PDF、Excel 这类原样传到会话所在的电脑，Claude 收到的是文件路径。
/// Info.plist 声明了能打开任何文件（CFBundleDocumentTypes，Alternate：只出现在「用其他应用打开」里，不抢默认打开方式）
@MainActor @Observable
final class InboundFiles {
    static let shared = InboundFiles()

    struct Item: Identifiable {
        let id = UUID()
        /// 拷进 App 临时目录的副本
        let url: URL
        let name: String
        let size: Int
        var thumbnail: UIImage?
        var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
    }

    /// 电脑那头一个文件最多收 25 MB；一次请求的总量也有上限（转成 base64 后要在 40 MB 以内）
    static let maxFile = 25 * 1024 * 1024
    static let maxTotal = 28 * 1024 * 1024

    private(set) var items: [Item] = []
    /// 面板开着（再收到的文件加进同一个面板）
    var showing = false

    /// onOpenURL 收到的文件、面板里「添加文件」选的文件
    func receive(_ url: URL) {
        guard url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Inbound", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent(url.lastPathComponent)
            try fm.copyItem(at: url, to: copy)
            // 系统替我们拷进 Documents/Inbox 的那份不留，不然越积越多
            if url.path.contains("/Documents/Inbox/") { try? fm.removeItem(at: url) }
            let size = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let item = Item(url: copy, name: copy.lastPathComponent, size: size)
            items.append(item)
            Task { await thumbnail(item) }
        } catch {
            ToastWindow.flash(L("无法读取文件：%@", error.localizedDescription))
        }
    }

    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
        items.removeAll { $0.id == id }
    }

    /// 发完、取消：拷进来的副本删掉
    func clear() {
        for item in items { try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent()) }
        items = []
    }

    private func thumbnail(_ item: Item) async {
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 96, height: 96), scale: 3, representationTypes: .thumbnail)
        guard let found = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].thumbnail = found.uiImage
    }

    /// 读文件、压图放到后台做（几十 MB 的文件别卡住界面）
    nonisolated static func load(_ items: [Item]) async -> (images: [(name: String, data: Data, preview: Data)], files: [(name: String, data: Data)]) {
        prepare(items)
    }

    /// 读出来分成图和文件：图照对话里发图那样压缩（解不开的图当文件发）
    nonisolated static func prepare(_ items: [Item]) -> (images: [(name: String, data: Data, preview: Data)], files: [(name: String, data: Data)]) {
        var images: [(name: String, data: Data, preview: Data)] = []
        var files: [(name: String, data: Data)] = []
        for item in items {
            guard let data = try? Data(contentsOf: item.url) else { continue }
            if item.isImage, let prepared = ImagePrep.prepare(data) {
                let base = (item.name as NSString).deletingPathExtension
                images.append(((base.isEmpty ? "image" : base) + ".jpg", prepared.jpeg, prepared.preview))
            } else {
                files.append((item.name, data))
            }
        }
        return (images, files)
    }
}

/// 主界面上挂着：收到文件就弹出发送面板（从最上面那层弹，设置、新任务这些面板开着也弹得出来）
struct InboundShareHost: ViewModifier {
    let model: AppModel
    @State private var inbox = InboundFiles.shared

    func body(content: Content) -> some View {
        content.onChange(of: inbox.items.count, initial: true) { _, count in
            guard count > 0, !inbox.showing else { return }
            inbox.showing = true
            Task {
                // 冷启动时等启动页飞走、界面搭好再弹
                try? await Task.sleep(for: .milliseconds(700))
                present()
            }
        }
        #if DEBUG || SNAPSHOT
        // 调试遥控：openfile / sharefile <会话 key> <路径> = 当作在消息里点了这个文件路径 / 长按「转发文件」
        .onReceive(NotificationCenter.default.publisher(for: DebugRemote.command)) { note in
            guard let line = note.object as? String else { return }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == "openfile" || parts[0] == "sharefile" else { return }
            FileOpener.shared.open(model, key: parts[1], path: parts[2], share: parts[0] == "sharefile")
        }
        #endif
    }

    private func present() {
        guard let top = SystemShare.top else { inbox.showing = false; return }
        weak var presented: UIViewController?
        let host = UIHostingController(rootView: InboundShareView(close: { done in presented?.dismiss(animated: true, completion: done) })
            .environment(model).lookRoot())
        presented = host
        // 有文件时不让下拉关掉（一不小心就得回微信重新选），要点「取消」
        host.isModalInPresentation = true
        top.present(host, animated: true)
    }
}

/// 发送面板：文件 + 补充说明（可以说）+ 发到哪儿（已有会话 / 新建会话选项目）
struct InboundShareView: View {
    @Environment(AppModel.self) private var model
    /// 关掉面板；关完了再做的事（进对话页：面板还在往下收时推进去，对话停在最上面，不在最新那条）
    let close: (_ then: (() -> Void)?) -> Void
    @State private var inbox = InboundFiles.shared
    @State private var text = ""
    @State private var target = Target.session
    @State private var sessions: [PastSession]?
    @State private var projects: [ProjectInfo]?
    @State private var pickedSession: String?
    @State private var pickedProject: ProjectInfo?
    @State private var query = ""
    @State private var busy = false
    @State private var importing = false
    @State private var loadError: String?
    @FocusState private var focused: Bool

    enum Target: Hashable { case session, project }

    private var total: Int { inbox.items.reduce(0) { $0 + $1.size } }
    private var tooLarge: Bool { inbox.items.contains { $0.size > InboundFiles.maxFile && !$0.isImage } || total > InboundFiles.maxTotal }
    private var ready: Bool {
        !inbox.items.isEmpty && !tooLarge && !busy && (target == .session ? pickedSession != nil : pickedProject != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                filesSection
                Section {
                    TextField("补充说明（可选），例如：核对这份报价单的金额", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                    // 说出来转成文字接在后面（同新任务、对话页的「转文字」）
                    HoldToDictate { said in text = Dictation.append(said, to: text) }
                        .listRowSeparator(.hidden)
                }
                Section {
                    Picker("发送到", selection: $target) {
                        Text("已有会话").tag(Target.session)
                        Text("新建会话").tag(Target.project)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if target == .session { sessionRows } else { projectRows }
            }
            .panelSearch($query, prompt: target == .session ? L("搜索会话") : L("搜索项目"))
            .navigationTitle("发送到会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { inbox.showing = false; inbox.clear(); close(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("发送") { Task { await send() } }.fontWeight(.semibold).disabled(!ready)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach { inbox.receive($0) } }
        }
        .task { await load() }
        #if DEBUG || SNAPSHOT
        // 调试遥控：inboundsend session|project <补充说明> = 选好发到哪、填上说明后点「发送」
        .onReceive(NotificationCenter.default.publisher(for: DebugRemote.command)) { note in
            guard let line = note.object as? String, line.hasPrefix("inboundsend ") else { return }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            target = parts.count > 1 && parts[1] == "project" ? .project : .session
            text = parts.count > 2 ? parts[2] : ""
            if target == .project, pickedProject == nil { pickedProject = projects?.first }
            Task { await send() }
        }
        #endif
        .onChange(of: inbox.items.isEmpty) { _, empty in
            // 文件全移除了：没东西可发，关掉（取消、发完是自己关的，showing 已经放下）
            if empty, !busy, inbox.showing { inbox.showing = false; close(nil) }
        }
    }

    // MARK: 文件

    private var filesSection: some View {
        Section {
            ForEach(inbox.items) { item in
                HStack(spacing: 12) {
                    Group {
                        if let thumb = item.thumbnail {
                            // 照片铺满裁掉；文档整页缩进来（只截一角是一片小字）
                            if item.isImage { Image(uiImage: thumb).resizable().scaledToFill() }
                            else { Image(uiImage: thumb).resizable().scaledToFit().padding(3) }
                        } else {
                            Image(systemName: FileLink.symbol(item.name)).font(.system(size: 20)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.ui(.subheadline)).lineLimit(2).truncationMode(.middle)
                        if item.size > InboundFiles.maxFile && !item.isImage {
                            Text("超过 25 MB，无法发送").font(.ui(.caption)).foregroundStyle(Theme.removed)
                        } else {
                            Text(item.isImage ? L("图片 · %@", Bytes.size(item.size)) : "\(FileLink.ext(item.name).uppercased()) · \(Bytes.size(item.size))")
                                .font(.ui(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Button { withAnimation(.snappy) { inbox.remove(item.id) } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.tertiary)
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.steady(.plain))
                    .accessibilityLabel("移除")
                }
            }
            if inbox.items.count < 9 {
                Button { importing = true } label: { Label("添加文件", systemImage: "plus") }
            }
        } header: {
            Text("文件")
        } footer: {
            if total > InboundFiles.maxTotal {
                Text("文件总大小超过 28 MB，请分批发送。").foregroundStyle(Theme.removed)
            } else {
                Text(L("将传到会话所在的电脑，%@ 会收到文件路径并自行读取；图片会直接显示在对话中。", model.sessionSlot(pickedSession ?? "").speaker))
            }
        }
    }

    // MARK: 已有会话

    @ViewBuilder private var sessionRows: some View {
        let shown = filteredSessions
        Section {
            ForEach(shown) { s in
                Button { pickedSession = s.key } label: {
                    HStack(spacing: 8) {
                        PastRow(session: s, searching: false)
                        Image(systemName: pickedSession == s.key ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20)).foregroundStyle(pickedSession == s.key ? Theme.claude : Color.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(RowButtonStyle())
            }
            if sessions != nil, shown.isEmpty {
                Text(query.isEmpty ? "暂无会话" : "无匹配的会话").foregroundStyle(.secondary)
            }
        } footer: {
            Text("已结束的会话会先在电脑上的 VS Code 中恢复，再发送。")
        }
        .overlay { if sessions == nil { loadingView } }
    }

    private var filteredSessions: [PastSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // 只读的会话（比如只能看不能发的 agent）发不了，不列
        let all = (sessions ?? []).filter { model.session($0.key)?.canReply != false }
        let hits = all.filter { s in q.isEmpty || "\(s.title) \(s.cwd ?? "") \(s.sourceName) \(s.firstPrompt ?? "")".lowercased().contains(q) }
        return Array(hits.prefix(60))
    }

    // MARK: 新建会话

    @ViewBuilder private var projectRows: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = (projects ?? []).filter { p in q.isEmpty || "\(p.name) \(p.cwd) \(p.sourceName) \(p.title ?? "")".lowercased().contains(q) }
        Section {
            ForEach(shown) { p in
                Button { pickedProject = p } label: {
                    HStack(spacing: 8) {
                        ProjectPickRow(project: p)
                        Image(systemName: pickedProject?.id == p.id ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20)).foregroundStyle(pickedProject?.id == p.id ? Theme.claude : Color.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(RowButtonStyle())
            }
            if projects != nil, shown.isEmpty {
                Text(projects?.isEmpty == true ? "暂无使用过 Claude Code 的项目" : "无匹配的项目").foregroundStyle(.secondary)
            }
        } footer: {
            Text("在所选项目中新建 Claude Code 会话，并把文件和说明作为第一条消息发送。")
        }
        .overlay { if projects == nil { loadingView } }
    }

    @ViewBuilder private var loadingView: some View {
        if let loadError { Text(loadError).foregroundStyle(.secondary).padding() } else { ProgressView().padding() }
    }

    // MARK: 取数据、发送

    private func load() async {
        // 先选上正在看的那个会话（多半就是要发给它），和它所在的项目
        let current = model.current
        async let pastReply = try? model.api.get(PastSessionsReply.self, "/api/sessions")
        async let projectReply = try? model.api.get(ProjectsReply.self, "/api/projects")
        let past = await pastReply
        let found = await projectReply
        sessions = past?.sessions ?? []
        projects = found?.projects.filter(\.exists) ?? []
        if past == nil || found == nil { loadError = model.connected ? L("读取失败，请稍后重试") : L("未连接到电脑") }
        if pickedSession == nil {
            pickedSession = current.flatMap { key in sessions?.contains { $0.key == key } == true ? key : nil } ?? filteredSessions.first?.key
        }
        if pickedProject == nil, let cwd = current.flatMap({ model.session($0)?.cwd }) {
            pickedProject = projects?.first { $0.cwd == cwd }
        }
    }

    private func send() async {
        guard ready else { return }
        busy = true
        defer { busy = false }
        let items = inbox.items
        let (images, files) = await InboundFiles.load(items)
        guard !images.isEmpty || !files.isEmpty else { model.flash(L("无法读取文件")); return }
        if !files.isEmpty, !model.hostFeatures.contains("files") {
            model.flash(L("电脑上的 Kiteline 版本较旧，暂不支持接收文件。请先在电脑上更新到最新版本"))
            return
        }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Haptics.tap()
        switch target {
        case .session:
            guard let key = pickedSession else { return }
            // 和在对话里发一样：先挂在对话底下（发送中 / 失败可重发），已结束的会话 Mac 会先恢复再发
            model.send(key, text: message, images: images, files: files)
            finish { model.pendingOpen = key }
        case .project:
            guard let project = pickedProject else { return }
            do {
                let reply = try await model.api.post("/api/new-session", body: [
                    "sourceId": project.sourceId, "cwd": project.cwd, "text": message,
                    "images": images.map { ["name": $0.name, "data": $0.data.base64EncodedString()] },
                    "files": files.map { ["name": $0.name, "data": $0.data.base64EncodedString()] },
                ])
                model.awaitNewSession(sourceId: project.sourceId, cwd: reply["cwd"] as? String ?? project.cwd)
                model.flash(reply["submitted"] as? Bool == true ? L("已开始，等待新会话出现…") : (reply["message"] as? String ?? L("已新建会话")))
                finish()
            } catch {
                model.show(error)
            }
        }
    }

    private func finish(then: (() -> Void)? = nil) {
        inbox.showing = false
        inbox.clear()
        close(then)
    }
}
#endif
