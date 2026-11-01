import SwiftUI

/// 代码 IDE 的入口页：宽（Mac 面板、iPad）就是 VS Code 那样的工作区，窄（iPhone）是分页的「文件 / 改动 / 历史 / 分支」，点进去一层层推
struct CodeRootView: View {
    let key: String
    let start: CodeStart

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 760 {
                CodeIDEView(key: key, start: start)
            } else if case .file(let path) = start {
                CodeFileScreen(key: key, path: path)
            } else {
                CodeHomeView(key: key, start: start)
            }
        }
    }
}

/// 手机上的代码首页：上面分段切「文件 / 源代码管理 / 历史 / 分支」，点文件、改动、提交推下一页
struct CodeHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let key: String
    let start: CodeStart
    @State private var tab = 0
    @State private var repo: RepoStore?
    @State private var explorer: ExplorerStore?

    var body: some View {
        VStack(spacing: 0) {
            LookSegmented(selection: $tab, options: [(0, L("文件")), (1, changesLabel), (2, L("历史")), (3, L("分支"))])
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
            if let repo, let explorer {
                switch tab {
                case 0:
                    ExplorerTree(explorer: explorer, activePath: nil, openFile: { open(.codeFile(key: key, path: $0)) },
                                 openHistory: { open(.fileHistory(key: key, path: $0)) })
                case 1:
                    SourceControlPanel(store: repo, openDiff: { change, mode in
                        open(.codeDiff(key: key, path: change.path, mode: mode, commit: nil, oldPath: change.oldPath))
                    }, openFile: { open(.codeFile(key: key, path: $0)) }, openBranches: { tab = 3 }, openHistory: { tab = 2 })
                case 2:
                    GitHistoryView(store: repo, openCommit: { open(.commit(key: key, hash: $0)) })
                default:
                    GitBranchesView(store: repo, openCommit: { open(.commit(key: key, hash: $0)) })
                }
            } else {
                Spacer()
            }
        }
        .navigationTitle(repo?.overview?.name ?? explorer?.rootName ?? L("代码"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .gitFailureAlertIfReady(repo)
        .task {
            if repo == nil {
                repo = CodeStores.repo(key, model)
                explorer = CodeStores.explorer(key, model)
                switch start {
                case .explorer(let path):
                    tab = 0
                    if !path.isEmpty, let explorer { await explorer.reveal(path + "/x") }
                case .scm: tab = 1
                case .history: tab = 2
                case .branches: tab = 3
                case .file: tab = 0
                }
            }
            await repo?.refresh()
        }
        .onAppear { if let repo { Task { await repo.refresh() } } }
    }

    private var changesLabel: String {
        let count = repo?.overview?.changeCount ?? 0
        return count > 0 ? L("改动 %@", "\(count)") : L("改动")
    }
}

extension View {
    @ViewBuilder
    func gitFailureAlertIfReady(_ store: RepoStore?) -> some View {
        if let store { gitFailureAlert(store) } else { self }
    }
}

/// 手机上编辑一个文件：默认只读（不会一点就弹键盘），点「编辑」再改；改了没保存，返回时问一声
struct CodeFileScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let key: String
    let path: String
    var line: Int? = nil
    @State private var editor = EditorController()
    @State private var session: FileSession?
    @State private var editing = false
    @State private var keyboard = false
    @State private var leaving = false
    @State private var preview = false
    @State private var showEdits = false
    @State private var nameAsk: NameAsk?
    @State private var ask: CodeAsk?
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.defaultFontSize
    @AppStorage(EditorPrefs.wrapKey) private var wrap = false

    private var id: String { "file:" + path }
    private var dirty: Bool { editor.dirty.contains(id) }
    private var options: EditorOptions { EditorOptions(dark: scheme == .dark, fontSize: fontSize, wrap: wrap, minimap: false) }
    private var ext: String { (path as NSString).pathExtension.lowercased() }

    var body: some View {
        VStack(spacing: 0) {
            if let session, let file = session.file {
                if !session.isText {
                    FileView(key: key, path: path)
                } else {
                    if !file.editable {
                        notice(file.truncated ? L("文件超过 4MB，只读取了前面部分，不能在这里编辑。") : L("文件不是 UTF-8 编码，为免损坏只能查看。"))
                    }
                    ZStack {
                        CodeWebView(controller: editor).opacity(preview ? 0 : 1)
                        if preview, let text = file.text {
                            ScrollView { MarkdownView(text).padding(14) }.background(Theme.chatBackground)
                        }
                    }
                    #if os(iOS)
                    if keyboard && editing { CodeKeyBar(controller: editor) }
                    #endif
                    if !keyboard {
                        EditorStatusBar(editor: editor, branch: model.session(key)?.branch, eol: file.eol) { open(.code(key: key, start: .branches)) }
                    }
                }
            } else if let error = session?.error {
                LoadFailed(error: error) { await load() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle((dirty ? "● " : "") + CodePaths.name(path))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(dirty)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
        #endif
        .toolbar { toolbar }
        .task {
            editor.onSave = { _ in Task { await save() } }
            if session == nil { await load() }
        }
        .onChange(of: options) { _, value in editor.setOptions(value) }
        // 没读到（刚连上电脑之前、网络断过）：连上了自动再读
        .onChange(of: model.connected) { _, connected in
            if connected, session?.file == nil { Task { await load() } }
        }
        .confirmationDialog(L("「%@」有未保存的修改", CodePaths.name(path)), isPresented: $leaving, titleVisibility: .visible) {
            Button("保存") { Task { if await save() { dismiss() } } }
            Button("不保存", role: .destructive) { editor.close(id); dismiss() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(L("电脑上的「%@」在你打开之后被修改过（可能是 Claude 改的）", CodePaths.name(path)),
                            isPresented: Binding(get: { session?.conflict == true }, set: { if !$0 { session?.conflict = false } }), titleVisibility: .visible) {
            Button("用我的版本覆盖", role: .destructive) { Task { await save(force: true) } }
            Button("放弃我的修改，载入电脑上的版本") { Task { await session?.reloadFromDisk(into: editor, id: id) } }
            Button("取消", role: .cancel) {}
        }
        .sheetPanel(isPresented: $showEdits) {
            NavigationStack {
                ScrollView { FileChanges(key: key, path: path).padding(14) }
                    .navigationTitle(L("Claude 的改动记录"))
                    .doneButton { showEdits = false }
            }
        }
        .codeAsks($ask, $nameAsk)
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.ui(.caption)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.orange.opacity(0.08))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        if dirty {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { leaving = true } label: { Image(systemName: "chevron.backward") }
            }
        }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            if session?.file?.editable == true && session?.isText == true {
                if editing || dirty {
                    Button {
                        Task { await save() }
                    } label: {
                        if session?.saving == true { ProgressView().controlSize(.small) } else { Text("保存").fontWeight(.semibold) }
                    }
                    .disabled(!dirty)
                } else {
                    Button { setEditing(true) } label: { Image(systemName: "square.and.pencil") }
                        .help(L("编辑"))
                }
            }
            Menu { menu } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if session?.isText == true {
            Button { editor.command("find") } label: { Label("查找和替换", systemImage: "magnifyingglass") }
            Button {
                nameAsk = NameAsk(title: L("跳到行"), placeholder: L("行号"), confirm: L("跳转")) { text in
                    if let n = Int(text) { editor.gotoLine(n) }
                }
            } label: { Label("跳到行…", systemImage: "arrow.down.to.line") }
            if editing { Button { setEditing(false) } label: { Label("只读查看", systemImage: "eye") } }
            Toggle(isOn: $wrap) { Label("自动换行", systemImage: "text.word.spacing") }
            Menu {
                Button("放大") { fontSize = min(24, fontSize + 1) }
                Button("缩小") { fontSize = max(9, fontSize - 1) }
                Button("默认大小") { fontSize = EditorPrefs.defaultFontSize }
            } label: { Label(L("字号 %@", "\(Int(fontSize))"), systemImage: "textformat.size") }
            if ext == "md" || ext == "markdown" {
                Button { preview.toggle() } label: { Label(preview ? L("查看源码") : L("预览"), systemImage: preview ? "chevron.left.forwardslash.chevron.right" : "doc.richtext") }
            }
            Divider()
        }
        Button { open(.codeDiff(key: key, path: path, mode: "unstaged", commit: nil, oldPath: nil)) } label: { Label("查看未提交的改动", systemImage: "plusminus") }
        Button { open(.fileHistory(key: key, path: path)) } label: { Label("文件历史", systemImage: "clock.arrow.circlepath") }
        Button { showEdits = true } label: {
            let edits = FileChanges.edits(model, key, path).count
            Label(edits > 0 ? L("Claude 的改动记录（%@）", "\(edits)") : L("Claude 的改动记录"), systemImage: "list.bullet.rectangle")
        }
        Divider()
        if model.session(key)?.canReply == true {
            Button {
                let draft = model.drafts[key] ?? ""
                model.setDraft(key, (draft.trimmingCharacters(in: .whitespaces).isEmpty ? "" : draft.trimmingCharacters(in: .whitespaces) + " ") + "@\(path) ")
                model.flash(L("已填入对话输入框"))
            } label: { Label("在对话中引用", systemImage: "quote.opening") }
        }
        Button { Clipboard.copy(path); model.flash(L("已拷贝相对路径")) } label: { Label("拷贝相对路径", systemImage: "link") }
        Button { FileOpener.shared.open(model, key: key, path: path, share: true) } label: { Label("分享…", systemImage: "square.and.arrow.up") }
        Button { FileOpener.shared.open(model, key: key, path: path) } label: { Label("用其他应用打开", systemImage: "arrow.up.forward.app") }
        Button {
            if dirty {
                ask = CodeAsk(message: L("重新载入会丢掉未保存的修改。"), confirm: L("重新载入"), destructive: true) { Task { await load() } }
            } else {
                Task { await load() }
            }
        } label: { Label("重新载入", systemImage: "arrow.clockwise") }
    }

    private func setEditing(_ on: Bool) {
        editing = on
        editor.setReadOnly(!on)
        if on { editor.command("focus") } else { editor.command("blur") }
    }

    private func load() async {
        let session = self.session ?? FileSession(key: key, path: path, model: model)
        self.session = session
        await session.load(into: editor, id: id, readOnly: !editing, options: options, line: line)
        // 刚连上 / 网络换路时第一次可能失败：自动再试一次，别让人先看到「加载失败」
        if session.error != nil, session.file == nil {
            try? await Task.sleep(for: .milliseconds(1200))
            await session.load(into: editor, id: id, readOnly: !editing, options: options, line: line)
        }
    }

    @discardableResult
    private func save(force: Bool = false) async -> Bool {
        guard let session else { return false }
        return await session.save(from: editor, id: id, force: force)
    }
}

/// 一个文件的改动对比（VS Code 的 diff 编辑器）：手机上下合在一起，宽屏并排；按区块暂存 / 取消暂存 / 丢弃
struct GitDiffScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @Environment(\.colorScheme) private var scheme
    let key: String
    let path: String
    /// unstaged / staged / untracked / commit；空 = 自动（先看工作区，没有再看暂存区）
    var mode: String?
    var commit: String?
    var oldPath: String?
    @State private var editor = EditorController()
    @State private var payload: DiffPayload?
    @State private var error: String?
    /// 用户点过「并排 / 行内」就按用户的，否则按宽度：900 以上并排
    @State private var chosenSplit: Bool?
    @State private var width: CGFloat = 0
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.defaultFontSize

    private var split: Bool { chosenSplit ?? (width >= 900) }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if let payload {
                    DiffToolbar(key: key, payload: payload, editor: editor,
                                split: Binding(get: { split }, set: { chosenSplit = $0 }), wide: geo.size.width >= 700,
                                openFile: payload.mode == "commit" ? nil : { open(.codeFile(key: key, path: path)) }) { await load() }
                    Divider()
                    if payload.binary {
                        ContentUnavailableView(L("二进制文件"), systemImage: "doc", description: Text("无法显示二进制文件的差异。"))
                    } else if payload.original == nil {
                        ScrollView { Text(payload.diff).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding() }
                    } else {
                        CodeWebView(controller: editor)
                    }
                } else if let error {
                    LoadFailed(error: error) { await load() }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, value in
                let before = split
                width = value
                if split != before { render() }
            }
        }
        .navigationTitle(CodePaths.name(path))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .onChange(of: model.connected) { _, connected in
            if connected, payload == nil { Task { await load() } }
        }
        .onChange(of: chosenSplit) { _, _ in render() }
        .onChange(of: scheme) { _, _ in render() }
    }

    private func load() async {
        do {
            var result = try await CodeAPI.diff(model, key: key, path: path, mode: mode ?? "unstaged", commit: commit, oldPath: oldPath)
            if mode == nil && result.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = try await CodeAPI.diff(model, key: key, path: path, mode: "staged")
            }
            payload = result
            error = nil
            render()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func render() {
        guard let payload, let original = payload.original, let modified = payload.modified else { return }
        editor.diff(original: original, modified: modified, path: path, split: split,
                    options: EditorOptions(dark: scheme == .dark, fontSize: fontSize, wrap: false, minimap: false))
    }
}

/// 对比页顶上一条：哪种改动、上一处 / 下一处、并排切换、按区块或整个文件暂存 / 丢弃
struct DiffToolbar: View {
    @Environment(AppModel.self) private var model
    let key: String
    let payload: DiffPayload
    let editor: EditorController
    @Binding var split: Bool
    var wide: Bool
    var openFile: (() -> Void)?
    var reload: () async -> Void
    @State private var ask: CodeAsk?
    @State private var nameAsk: NameAsk?

    private var store: RepoStore { CodeStores.repo(key, model) }

    var body: some View {
        HStack(spacing: 10) {
            Text(modeLabel).font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.tile, in: Capsule())
            if editor.diffChunks > 0 {
                Text(L("%lld 处改动", count: editor.diffChunks)).font(.ui(.caption)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Group {
                Button { editor.nextChange(-1) } label: { Image(systemName: "chevron.up") }.help(L("上一处改动"))
                Button { editor.nextChange(1) } label: { Image(systemName: "chevron.down") }.help(L("下一处改动"))
                if wide {
                    Button { split.toggle() } label: { Image(systemName: split ? "rectangle.split.2x1.fill" : "rectangle.split.2x1") }
                        .help(split ? L("改为行内对比") : L("改为并排对比"))
                }
                if let openFile { Button(action: openFile) { Image(systemName: "doc.text") }.help(L("打开文件")) }
                if payload.mode != "commit" { stageMenu }
            }
            .buttonStyle(.borderless)
        }
        .font(.ui(.subheadline))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .codeAsks($ask, $nameAsk)
    }

    private var modeLabel: String {
        switch payload.mode {
        case "staged": L("已暂存")
        case "untracked": L("新文件")
        case "commit": L("提交中的改动")
        default: L("工作区")
        }
    }

    private var stageMenu: some View {
        Menu {
            if payload.mode == "staged" {
                Button { Task { await fileOp("unstage") } } label: { Label("取消暂存整个文件", systemImage: "minus") }
            } else {
                Button { Task { await fileOp("stage") } } label: { Label("暂存整个文件", systemImage: "plus") }
                Button(role: .destructive) {
                    ask = CodeAsk(message: L("丢弃「%@」的全部更改？", CodePaths.name(payload.path)), confirm: L("丢弃更改"), destructive: true) {
                        Task { await fileOp("discard") }
                    }
                } label: { Label("丢弃整个文件的更改", systemImage: "arrow.uturn.backward") }
            }
            if !payload.hunks.isEmpty && payload.mode != "untracked" {
                Divider()
                ForEach(Array(payload.hunks.enumerated()), id: \.offset) { index, header in
                    Menu(L("区块 %@：%@", "\(index + 1)", Self.short(header))) {
                        if payload.mode == "staged" {
                            Button(L("取消暂存此区块")) { Task { await hunk("unstage_hunk", index, header) } }
                        } else {
                            Button(L("暂存此区块")) { Task { await hunk("stage_hunk", index, header) } }
                            Button(L("丢弃此区块"), role: .destructive) {
                                ask = CodeAsk(message: L("丢弃这一块改动？此操作无法撤销。"), confirm: L("丢弃"), destructive: true) {
                                    Task { await hunk("discard_hunk", index, header) }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(payload.mode == "staged" ? L("取消暂存") : L("暂存"), systemImage: payload.mode == "staged" ? "minus.circle" : "plus.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 「@@ -12,7 +12,9 @@ func foo()」→「第 12 行 func foo()」
    static func short(_ header: String) -> String {
        let parts = header.components(separatedBy: "@@")
        let range = parts.count > 1 ? parts[1] : header
        let line = range.split(separator: "+").last.flatMap { $0.split(separator: ",").first }.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let context = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        return L("第 %@ 行", line) + (context.isEmpty ? "" : " " + String(context.prefix(30)))
    }

    private func fileOp(_ op: String) async {
        let done: String = switch op {
        case "stage": L("已暂存")
        case "unstage": L("已取消暂存")
        default: L("已丢弃更改")
        }
        if await store.perform(op, ["paths": [payload.path]], label: L("正在处理"), done: done) != nil { await reload() }
    }

    private func hunk(_ op: String, _ index: Int, _ header: String) async {
        let done: String = switch op {
        case "stage_hunk": L("已暂存此区块")
        case "unstage_hunk": L("已取消暂存此区块")
        default: L("已丢弃此区块")
        }
        if await store.perform(op, ["path": payload.path, "hunk": index, "header": header], label: L("正在处理"), done: done) != nil { await reload() }
    }
}

/// 一个提交的详情页（手机上从历史推进来）
struct CommitScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let key: String
    let hash: String

    var body: some View {
        let store = CodeStores.repo(key, model)
        CommitDetailView(store: store, hash: hash, openDiff: { file, _ in
            open(.codeDiff(key: key, path: file.path, mode: "commit", commit: hash, oldPath: file.oldPath))
        }, openCommit: { open(.commit(key: key, hash: $0)) })
        .gitFailureAlert(store)
    }
}

/// 一个文件的历史（手机）
struct FileHistoryScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let key: String
    let path: String

    var body: some View {
        let store = CodeStores.repo(key, model)
        GitHistoryView(store: store, openCommit: { open(.commit(key: key, hash: $0)) }, path: path)
            .navigationTitle(L("「%@」的历史", CodePaths.name(path)))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .gitFailureAlert(store)
    }
}
