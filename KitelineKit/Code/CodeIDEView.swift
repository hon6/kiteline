import SwiftUI

/// 宽屏的代码 IDE（Mac 面板、iPad）：左边活动栏（资源管理器 / 源代码管理 / 分支与会话 / 历史），侧栏，右边标签页编辑区和状态栏 —— 照 VS Code 的布局
struct CodeIDEView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @Environment(\.colorScheme) private var scheme
    let key: String
    let start: CodeStart
    @State private var ws: CodeWorkspace?
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.defaultFontSize
    @AppStorage(EditorPrefs.wrapKey) private var wrap = false
    @AppStorage(EditorPrefs.minimapKey) private var minimap = true

    private var options: EditorOptions { EditorOptions(dark: scheme == .dark, fontSize: fontSize, wrap: wrap, minimap: minimap) }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // 顶上一条细线把内容和标题栏隔开：内容不贴着工具栏的边，macOS 26 的侧栏列表、背景色就不会伸进标题栏（标题栏左右一种颜色）
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            #endif
            if let ws {
                IDELayout(ws: ws, options: options)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(ws?.repo.overview?.name ?? ws?.explorer.rootName ?? L("代码"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // 当前分支（和远端差几个提交）：点开分支与会话
            if let ws, let overview = ws.repo.overview, overview.repo != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { ws.activity = .branches } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(overview.branch ?? "HEAD").lineLimit(1)
                            if overview.ahead > 0 { Text("↑\(overview.ahead)").monospacedDigit() }
                            if overview.behind > 0 { Text("↓\(overview.behind)").monospacedDigit() }
                        }
                    }
                    .help(L("分支与会话"))
                    .panelToolbarItem()
                }
            }
        }
        // Mac 面板关掉（红色按钮、⌘W）前：有没保存的文件先问
        .panelCloseGuard {
            guard let ws, !ws.unsavedTabs.isEmpty else { return true }
            ws.quitting = true
            return false
        }
        .task {
            guard ws == nil else { return }
            let workspace = CodeWorkspace(key: key, model: model)
            workspace.options = options
            ws = workspace
            await workspace.begin(start)
        }
        .onChange(of: options) { _, value in
            ws?.options = value
            ws?.editor.setOptions(value)
        }
    }
}

/// IDE 里的一个标签
struct CodeTab: Identifiable, Hashable {
    enum Kind: Hashable {
        case file(String)
        case diff(path: String, mode: String, commit: String?, oldPath: String?)
        case history(String?)
        case commit(String)
    }
    var kind: Kind

    var id: String {
        switch kind {
        case .file(let path): "file:" + path
        case .diff(let path, let mode, let commit, _): "diff:\(mode):\(commit ?? ""):\(path)"
        case .history(let path): "history:" + (path ?? "")
        case .commit(let hash): "commit:" + hash
        }
    }

    var title: String {
        switch kind {
        case .file(let path): CodePaths.name(path)
        case .diff(let path, let mode, let commit, _):
            CodePaths.name(path) + (commit != nil ? " (\(commit!.prefix(7)))" : mode == "staged" ? L("（已暂存）") : L("（工作区）"))
        case .history(let path): path.map { L("「%@」的历史", CodePaths.name($0)) } ?? L("提交历史")
        case .commit(let hash): String(hash.prefix(8))
        }
    }

    var symbol: String {
        switch kind {
        case .file(let path): FileGlyph.symbol(CodePaths.name(path))
        case .diff: "plusminus"
        case .history: "clock.arrow.circlepath"
        case .commit: "smallcircle.filled.circle"
        }
    }

    /// 编辑区用不用网页编辑器
    var usesEditor: Bool {
        switch kind {
        case .file, .diff: true
        default: false
        }
    }
}

/// 宽屏 IDE 的状态：开着的标签、哪个在前面、侧栏显示什么
@MainActor @Observable
final class CodeWorkspace {
    enum Activity: String { case explorer, scm, branches }

    let key: String
    @ObservationIgnored weak var model: AppModel?
    let editor = EditorController()
    let repo: RepoStore
    let explorer: ExplorerStore
    var tabs: [CodeTab] = []
    var active: String?
    var activity: Activity = .explorer
    var files: [String: FileSession] = [:]
    var diffs: [String: DiffPayload] = [:]
    var diffErrors: [String: String] = [:]
    var split = true
    /// 关标签时有没保存的：问一声
    var closing: CodeTab?
    /// 关整个 IDE（Mac 面板）时有没保存的：问一声
    var quitting = false
    @ObservationIgnored var options = EditorOptions(dark: true, fontSize: 13, wrap: false, minimap: true)
    /// 已经在网页里打开过的文件标签（切回来时只要 show）
    @ObservationIgnored private var loaded: Set<String> = []

    init(key: String, model: AppModel) {
        self.key = key
        self.model = model
        repo = CodeStores.repo(key, model)
        explorer = CodeStores.explorer(key, model)
        explorer.onRenamed = { [weak self] old, new in self?.renamed(old, new) }
        explorer.onDeleted = { [weak self] paths in self?.deleted(paths) }
        explorer.onChanged = { [weak self] in Task { await self?.repo.refresh() } }
        editor.onSave = { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }), case .file(let path) = tab.kind else { return }
            Task { await self.files[path]?.save(from: self.editor, id: id) }
        }
    }

    var activeTab: CodeTab? { tabs.first { $0.id == active } }

    func begin(_ start: CodeStart) async {
        async let overview: Void = repo.refresh()
        async let root: Void = explorer.listings[""] == nil ? explorer.load("") : ()
        _ = await (overview, root)
        switch start {
        case .explorer(let path):
            activity = .explorer
            if !path.isEmpty { await explorer.reveal(path + "/x") }
        case .file(let path):
            activity = .explorer
            openFile(path)
            await explorer.reveal(path)
        case .scm:
            activity = .scm
        case .history:
            activity = .scm
            openTab(CodeTab(kind: .history(nil)))
        case .branches:
            activity = .branches
        }
    }

    // MARK: 标签

    func openTab(_ tab: CodeTab) {
        if !tabs.contains(where: { $0.id == tab.id }) {
            // 新标签放在当前标签右边
            let index = tabs.firstIndex { $0.id == active }.map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: index)
        }
        activate(tab.id)
    }

    func openFile(_ path: String, line: Int? = nil) {
        openTab(CodeTab(kind: .file(path)))
        if let line { editor.gotoLine(line) }
    }

    func openDiff(_ change: RepoChange, mode: String, commit: String? = nil) {
        openTab(CodeTab(kind: .diff(path: change.path, mode: mode, commit: commit, oldPath: change.oldPath)))
    }

    func activate(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        active = id
        switch tab.kind {
        case .file(let path):
            let session = files[path] ?? FileSession(key: key, path: path, model: model!)
            files[path] = session
            if loaded.contains(id) {
                editor.show(id)
            } else {
                loaded.insert(id)
                Task { await session.load(into: editor, id: id, readOnly: false, options: options) }
            }
        case .diff(let path, let mode, let commit, let oldPath):
            if let payload = diffs[id] {
                render(payload)
            } else {
                Task { await loadDiff(id: id, path: path, mode: mode, commit: commit, oldPath: oldPath) }
            }
        default:
            break
        }
    }

    func loadDiff(id: String, path: String, mode: String, commit: String?, oldPath: String?) async {
        guard let model else { return }
        do {
            let payload = try await CodeAPI.diff(model, key: key, path: path, mode: mode, commit: commit, oldPath: oldPath)
            diffs[id] = payload
            diffErrors[id] = nil
            if active == id { render(payload) }
        } catch {
            diffErrors[id] = error.localizedDescription
        }
    }

    func render(_ payload: DiffPayload) {
        guard let original = payload.original, let modified = payload.modified else { return }
        editor.diff(original: original, modified: modified, path: payload.path, split: split,
                    options: EditorOptions(dark: options.dark, fontSize: options.fontSize, wrap: options.wrap, minimap: false))
    }

    /// 重新拉当前对比（暂存了一个区块之后）
    func reloadActiveDiff() async {
        guard let tab = activeTab, case .diff(let path, let mode, let commit, let oldPath) = tab.kind else { return }
        diffs[tab.id] = nil
        await loadDiff(id: tab.id, path: path, mode: mode, commit: commit, oldPath: oldPath)
    }

    func requestClose(_ tab: CodeTab) {
        if editor.dirty.contains(tab.id) { closing = tab } else { close(tab) }
    }

    var unsavedTabs: [CodeTab] { tabs.filter { editor.dirty.contains($0.id) } }

    /// 没保存的都存一遍；有一个没存成（冲突、出错）就是 false
    func saveAll() async -> Bool {
        for tab in unsavedTabs {
            guard case .file(let path) = tab.kind, await files[path]?.save(from: editor, id: tab.id) == true else { return false }
        }
        return true
    }

    func close(_ tab: CodeTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if tab.usesEditor { editor.close(tab.id) }
        loaded.remove(tab.id)
        diffs[tab.id] = nil
        if case .file(let path) = tab.kind { files[path] = nil }
        if active == tab.id {
            active = nil
            if !tabs.isEmpty { activate(tabs[min(index, tabs.count - 1)].id) }
        }
    }

    func closeOthers(_ keep: CodeTab) {
        for tab in tabs where tab.id != keep.id && !editor.dirty.contains(tab.id) { close(tab) }
        activate(keep.id)
    }

    private func renamed(_ old: String, _ new: String) {
        for (index, tab) in tabs.enumerated() {
            guard case .file(let path) = tab.kind, path == old || path.hasPrefix(old + "/") else { continue }
            let moved = new + path.dropFirst(old.count)
            let wasActive = active == tab.id
            editor.close(tab.id)
            loaded.remove(tab.id)
            files[path] = nil
            tabs[index] = CodeTab(kind: .file(moved))
            if wasActive { activate(tabs[index].id) }
        }
    }

    private func deleted(_ paths: [String]) {
        for tab in tabs {
            guard case .file(let path) = tab.kind, paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            close(tab)
        }
    }
}

/// 宽屏 IDE 的整体布局
private struct IDELayout: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var closePanel
    @Bindable var ws: CodeWorkspace
    let options: EditorOptions
    @State private var sidebarWidth: CGFloat = 280
    @State private var dragStart: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            activityBar
            Divider()
            sidebar.frame(width: sidebarWidth)
            // 拖这条线改侧栏宽度
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                .overlay(Color.clear.frame(width: 8).contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in
                        if dragStart == nil { dragStart = sidebarWidth }
                        sidebarWidth = min(520, max(200, (dragStart ?? 280) + value.translation.width))
                    }.onEnded { _ in dragStart = nil }))
                #if os(macOS)
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                #endif
            editorArea
                .confirmationDialog(L("有 %@ 个文件未保存，关闭后修改会丢失。", "\(ws.unsavedTabs.count)"), isPresented: $ws.quitting, titleVisibility: .visible) {
                    Button("全部保存并关闭") { Task { if await ws.saveAll() { closePanel() } } }
                    Button("不保存并关闭", role: .destructive) { closePanel() }
                    Button("取消", role: .cancel) {}
                }
        }
        .gitFailureAlert(ws.repo)
        .confirmationDialog(L("「%@」有未保存的修改", ws.closing?.title ?? ""), isPresented: Binding(get: { ws.closing != nil }, set: { if !$0 { ws.closing = nil } }), titleVisibility: .visible) {
            Button("保存") {
                guard let tab = ws.closing, case .file(let path) = tab.kind else { return }
                ws.closing = nil
                Task { if await ws.files[path]?.save(from: ws.editor, id: tab.id) == true { ws.close(tab) } }
            }
            Button("不保存", role: .destructive) { if let tab = ws.closing { ws.closing = nil; ws.close(tab) } }
            Button("取消", role: .cancel) { ws.closing = nil }
        }
    }

    // MARK: 活动栏

    private var activityBar: some View {
        VStack(spacing: 4) {
            activityButton(.explorer, symbol: "doc.on.doc", help: L("资源管理器"))
            activityButton(.scm, symbol: "arrow.triangle.branch", help: L("源代码管理"), badge: ws.repo.overview?.changeCount ?? 0)
            activityButton(.branches, symbol: "point.3.connected.trianglepath.dotted", help: L("分支与会话"),
                           badge: ws.repo.overview?.sessions.count ?? 0, badgeMuted: true)
            Button { ws.openTab(CodeTab(kind: .history(nil))) } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 17)).frame(width: 40, height: 38)
                    .foregroundStyle(ws.activeTab?.kind == .history(nil) ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(L("提交历史"))
            Spacer()
        }
        .padding(.top, 8)
        .frame(width: 44)
        .background(Theme.tile.opacity(0.6))
    }

    private func activityButton(_ value: CodeWorkspace.Activity, symbol: String, help: String, badge: Int = 0, badgeMuted: Bool = false) -> some View {
        Button { ws.activity = value } label: {
            Image(systemName: symbol).font(.system(size: 17))
                .frame(width: 40, height: 38)
                .foregroundStyle(ws.activity == value ? Color.primary : Color.secondary)
                .overlay(alignment: .leading) {
                    if ws.activity == value { Capsule().fill(Theme.claude).frame(width: 2.5, height: 22) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if badge > 0 {
                        Text("\(min(badge, 99))").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                            .background(badgeMuted ? Color.secondary : Theme.claude, in: Capsule()).offset(x: -2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 侧栏

    @ViewBuilder
    private var sidebar: some View {
        switch ws.activity {
        case .explorer:
            ExplorerTree(explorer: ws.explorer, activePath: { if case .file(let p) = ws.activeTab?.kind { return p } else { return nil } }(),
                         openFile: { ws.openFile($0) }, openHistory: { ws.openTab(CodeTab(kind: .history($0))) })
        case .scm:
            SourceControlPanel(store: ws.repo, openDiff: { change, mode in ws.openDiff(change, mode: mode) },
                               openFile: { ws.openFile($0) }, openBranches: { ws.activity = .branches },
                               openHistory: { ws.openTab(CodeTab(kind: .history(nil))) })
        case .branches:
            GitBranchesView(store: ws.repo, openCommit: { ws.openTab(CodeTab(kind: .commit($0))) })
        }
    }

    // MARK: 编辑区

    private var editorArea: some View {
        VStack(spacing: 0) {
            if !ws.tabs.isEmpty {
                tabBar
                Divider()
            }
            ZStack {
                // 网页编辑器一直留着（切到历史这类标签时只是藏起来），撤销历史、滚动位置都在
                CodeWebView(controller: ws.editor)
                    .opacity(showsEditor ? 1 : 0)
                    .allowsHitTesting(showsEditor)
                    .safeAreaInset(edge: .top, spacing: 0) { if showsEditor { editorHeader } }
                if let tab = ws.activeTab {
                    nativeContent(tab)
                } else {
                    welcome
                }
            }
            if case .file(let path) = ws.activeTab?.kind, ws.files[path]?.isText == true {
                EditorStatusBar(editor: ws.editor, branch: ws.repo.overview?.branch, eol: ws.files[path]?.file?.eol) { ws.activity = .branches }
            }
        }
    }

    private var showsEditor: Bool {
        guard let tab = ws.activeTab else { return false }
        switch tab.kind {
        case .file(let path): return ws.files[path]?.isText == true
        case .diff: return ws.diffs[tab.id]?.original != nil
        default: return false
        }
    }

    @ViewBuilder
    private func nativeContent(_ tab: CodeTab) -> some View {
        switch tab.kind {
        case .file(let path):
            if let session = ws.files[path] {
                if let error = session.error {
                    LoadFailed(error: error) { await session.load(into: ws.editor, id: tab.id, readOnly: false, options: ws.options) }
                } else if session.file == nil {
                    ProgressView()
                } else if !session.isText {
                    FileView(key: ws.key, path: path).background(Theme.chatBackground)
                }
            }
        case .diff:
            if let error = ws.diffErrors[tab.id] {
                LoadFailed(error: error) { await ws.reloadActiveDiff() }
            } else if let payload = ws.diffs[tab.id] {
                if payload.original == nil {
                    VStack(spacing: 0) {
                        diffBar(payload)
                        Divider()
                        if payload.binary {
                            ContentUnavailableView(L("二进制文件"), systemImage: "doc", description: Text("无法显示二进制文件的差异。"))
                        } else {
                            ScrollView { Text(payload.diff).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding() }
                        }
                    }
                    .background(Theme.chatBackground)
                }
            } else {
                ProgressView()
            }
        case .history(let path):
            GitHistoryView(store: ws.repo, openCommit: { ws.openTab(CodeTab(kind: .commit($0))) }, path: path, wide: true)
                .background(Theme.chatBackground)
        case .commit(let hash):
            CommitDetailView(store: ws.repo, hash: hash, openDiff: { file, _ in ws.openDiff(file, mode: "commit", commit: hash) },
                             openCommit: { ws.openTab(CodeTab(kind: .commit($0))) })
                .background(Theme.chatBackground)
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text(ws.repo.overview?.name ?? ws.explorer.rootName).font(.ui(.title3).weight(.semibold))
            if let overview = ws.repo.overview, overview.repo != nil {
                Text(L("分支「%@」", overview.branch ?? "HEAD") + " · " + (overview.changeCount > 0 ? L("%lld 个文件有改动", count: overview.changeCount) : L("工作区干净")))
                    .font(.ui(.subheadline)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { ws.activity = .scm } label: { Label("源代码管理", systemImage: "arrow.triangle.branch") }
                Button { ws.openTab(CodeTab(kind: .history(nil))) } label: { Label("提交历史", systemImage: "clock.arrow.circlepath") }
                Button { ws.activity = .branches } label: { Label("分支与会话", systemImage: "point.3.connected.trianglepath.dotted") }
            }
            .buttonStyle(.bordered)
            Text("从左侧选择文件开始编辑；⌘S 保存，⌘F 查找。").font(.ui(.caption)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chatBackground)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(ws.tabs) { tab in
                    let isActive = tab.id == ws.active
                    let dirty = ws.editor.dirty.contains(tab.id)
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(tab.title).font(.system(size: 12.5)).lineLimit(1)
                            .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        Button { ws.requestClose(tab) } label: {
                            Image(systemName: dirty ? "circle.fill" : "xmark")
                                .font(.system(size: dirty ? 7 : 9, weight: .bold))
                                .frame(width: 16, height: 16)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("关闭"))
                    }
                    .padding(.leading, 12).padding(.trailing, 6)
                    .frame(height: 34)
                    .background(isActive ? Theme.chatBackground : Color.clear)
                    .overlay(alignment: .top) { if isActive { Rectangle().fill(Theme.claude).frame(height: 2) } }
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
                    .contentShape(Rectangle())
                    .onTapGesture { ws.activate(tab.id) }
                    .contextMenu {
                        Button("关闭") { ws.requestClose(tab) }
                        Button("关闭其他标签") { ws.closeOthers(tab) }
                        if case .file(let path) = tab.kind {
                            Divider()
                            Button("拷贝相对路径") { Clipboard.copy(path) }
                            Button("在资源管理器中显示") { ws.activity = .explorer; Task { await ws.explorer.reveal(path) } }
                            Button("查看文件历史") { ws.openTab(CodeTab(kind: .history(path))) }
                        }
                    }
                }
            }
        }
        .frame(height: 34)
        .background(Theme.tile.opacity(0.6))
    }

    // MARK: 编辑区顶上那条（路径 + 操作）

    @ViewBuilder
    private var editorHeader: some View {
        if let tab = ws.activeTab {
            switch tab.kind {
            case .file(let path): fileBar(path, tab: tab)
            case .diff: if let payload = ws.diffs[tab.id] { diffBar(payload) }
            default: EmptyView()
            }
        }
    }

    private func fileBar(_ path: String, tab: CodeTab) -> some View {
        let dirty = ws.editor.dirty.contains(tab.id)
        let session = ws.files[path]
        return HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(Array(path.split(separator: "/").enumerated()), id: \.offset) { index, part in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
                    Text(part).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .lineLimit(1)
            if session?.file?.editable == false {
                Text(session?.file?.truncated == true ? L("只读：文件过大") : L("只读：非 UTF-8")).font(.ui(.caption2)).foregroundStyle(.orange)
            }
            Spacer(minLength: 6)
            Group {
                if dirty {
                    Button { Task { await session?.save(from: ws.editor, id: tab.id) } } label: {
                        if session?.saving == true { ProgressView().controlSize(.mini) } else { Text("保存").font(.system(size: 12, weight: .semibold)) }
                    }
                    .help(L("保存（⌘S）"))
                }
                Button { ws.editor.command("find") } label: { Image(systemName: "magnifyingglass") }.help(L("查找和替换（⌘F）"))
                Button {
                    ws.openDiff(RepoChange.simple(path), mode: (ws.repo.overview?.staged.contains { $0.path == path } == true
                                                               && ws.repo.overview?.unstaged.contains { $0.path == path } != true) ? "staged" : "unstaged")
                } label: { Image(systemName: "plusminus") }.help(L("查看未提交的改动"))
                Menu {
                    IDEFileMenu(ws: ws, path: path, tab: tab)
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .confirmationDialog(L("电脑上的「%@」在你打开之后被修改过（可能是 Claude 改的）", CodePaths.name(path)),
                            isPresented: Binding(get: { session?.conflict == true }, set: { if !$0 { session?.conflict = false } }), titleVisibility: .visible) {
            Button("用我的版本覆盖", role: .destructive) { Task { await session?.save(from: ws.editor, id: tab.id, force: true) } }
            Button("放弃我的修改，载入电脑上的版本") { Task { await session?.reloadFromDisk(into: ws.editor, id: tab.id) } }
            Button("取消", role: .cancel) {}
        }
    }

    private func diffBar(_ payload: DiffPayload) -> some View {
        DiffToolbar(key: ws.key, payload: payload, editor: ws.editor, split: Binding(get: { ws.split }, set: { ws.split = $0; ws.render(payload) }),
                    wide: true, openFile: payload.mode == "commit" ? nil : { ws.openFile(payload.path) }) { await ws.reloadActiveDiff() }
            .background(.bar)
    }
}

/// 编辑区「…」菜单
private struct IDEFileMenu: View {
    @Environment(AppModel.self) private var model
    let ws: CodeWorkspace
    let path: String
    let tab: CodeTab
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.defaultFontSize
    @AppStorage(EditorPrefs.wrapKey) private var wrap = false
    @AppStorage(EditorPrefs.minimapKey) private var minimap = true

    var body: some View {
        Button("撤销") { ws.editor.command("undo") }
        Button("重做") { ws.editor.command("redo") }
        Button("全部折叠") { ws.editor.command("foldAll") }
        Button("全部展开") { ws.editor.command("unfoldAll") }
        Button("切换注释") { ws.editor.command("toggleComment") }
        Divider()
        Toggle("自动换行", isOn: $wrap)
        Toggle("小地图", isOn: $minimap)
        Menu(L("字号 %@", "\(Int(fontSize))")) {
            Button("放大") { fontSize = min(24, fontSize + 1) }
            Button("缩小") { fontSize = max(9, fontSize - 1) }
            Button("默认大小") { fontSize = EditorPrefs.defaultFontSize }
        }
        Divider()
        Button("查看文件历史") { ws.openTab(CodeTab(kind: .history(path))) }
        Button("在资源管理器中显示") { ws.activity = .explorer; Task { await ws.explorer.reveal(path) } }
        if model.session(ws.key)?.canReply == true {
            Button("在对话中引用") {
                let draft = model.drafts[ws.key] ?? ""
                model.setDraft(ws.key, (draft.trimmingCharacters(in: .whitespaces).isEmpty ? "" : draft.trimmingCharacters(in: .whitespaces) + " ") + "@\(path) ")
                model.flash(L("已填入对话输入框"))
            }
        }
        Button("拷贝相对路径") { Clipboard.copy(path) }
        Button("用其他应用打开") { FileOpener.shared.open(model, key: ws.key, path: path) }
        Divider()
        Button("重新载入") {
            if let session = ws.files[path] { Task { await session.reloadFromDisk(into: ws.editor, id: tab.id) } }
        }
    }
}

extension RepoChange {
    /// 只知道路径时（从编辑器里点「查看改动」）
    static func simple(_ path: String) -> RepoChange {
        let json = (try? JSONSerialization.data(withJSONObject: ["path": path, "status": "M"])) ?? Data()
        return (try? JSONDecoder().decode(RepoChange.self, from: json))!
    }
}
