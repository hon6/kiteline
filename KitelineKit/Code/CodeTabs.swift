import SwiftUI

// 代码标签（Mac 新版界面，11-20 反馈：像 VS Code 那样自由布局——左边选项目、看会话和文件，点了在中间开成标签，
// 会话标签和文件标签能上下、左右随便分）。文件、改动对比、提交历史、某次提交都是分屏里的一个标签，和会话标签放在同一套分屏里
// （ChatPanes），能拖、能分屏、能和会话混排。标签的 key 是一串字（分屏按 key 记标签、存盘、拖动）：
//   @code:<种类>:<会话 key>|<参数>
// 会话 key 用来找文件在哪台电脑、哪个目录（文件、Git 接口都按会话找）；会话 key 里不会有「|」（电脑端拿它拼 cid 时就用「|」隔开）

enum CodeTabKey {
    static let prefix = "@code:"

    enum Kind: String {
        /// 一个文件（编辑器）
        case file
        /// 一处改动的对比（参数见 diffArg）
        case diff
        /// 提交历史（参数是文件路径，空 = 整个仓库）
        case history
        /// 某次提交（参数是提交号）
        case commit
    }

    struct Parts: Hashable {
        let kind: Kind
        let session: String
        let arg: String

        /// 对比的参数：mode、commit、oldPath、path 用换行隔开
        var diff: (mode: String, commit: String?, oldPath: String?, path: String) {
            let bits = arg.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard bits.count == 4 else { return ("unstaged", nil, nil, arg) }
            return (bits[0], bits[1].isEmpty ? nil : bits[1], bits[2].isEmpty ? nil : bits[2], bits[3])
        }
    }

    static func make(_ kind: Kind, session: String, _ arg: String) -> String { prefix + kind.rawValue + ":" + session + "|" + arg }

    static func diff(session: String, path: String, mode: String, commit: String? = nil, oldPath: String? = nil) -> String {
        make(.diff, session: session, [mode, commit ?? "", oldPath ?? "", path].joined(separator: "\n"))
    }

    /// 是代码标签就拆开，不是（会话、群）给 nil
    static func parse(_ key: String?) -> Parts? {
        guard let key, key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":"), let kind = Kind(rawValue: String(rest[..<colon])) else { return nil }
        let tail = rest[rest.index(after: colon)...]
        guard let bar = tail.firstIndex(of: "|") else { return nil }
        return Parts(kind: kind, session: String(tail[..<bar]), arg: String(tail[tail.index(after: bar)...]))
    }

    static func isCode(_ key: String?) -> Bool { key?.hasPrefix(prefix) == true }

    /// 标签上写的
    static func title(_ parts: Parts) -> String {
        switch parts.kind {
        case .file: return CodePaths.name(parts.arg)
        case .diff:
            let d = parts.diff
            return CodePaths.name(d.path) + (d.commit != nil ? " (\(d.commit!.prefix(7)))" : d.mode == "staged" ? L("（已暂存）") : L("（工作区）"))
        case .history: return parts.arg.isEmpty ? L("提交历史") : L("「%@」的历史", CodePaths.name(parts.arg))
        case .commit: return String(parts.arg.prefix(8))
        }
    }

    /// 标签最前面的小图标
    static func symbol(_ parts: Parts) -> String {
        switch parts.kind {
        case .file: return FileGlyph.symbol(CodePaths.name(parts.arg))
        case .diff: return "plusminus"
        case .history: return "clock.arrow.circlepath"
        case .commit: return "smallcircle.filled.circle"
        }
    }

    /// 指着标签看的：路径 · 哪个项目
    @MainActor static func help(_ parts: Parts, model: AppModel) -> String {
        let place = model.session(parts.session)?.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        let what: String
        switch parts.kind {
        case .file: what = parts.arg
        case .diff: what = parts.diff.path
        case .history: what = parts.arg.isEmpty ? L("提交历史") : parts.arg
        case .commit: what = L("提交 %@", String(parts.arg.prefix(8)))
        }
        return [what, place].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 从项目的文件 / Git 侧栏要打开的东西（IDE 里的 CodeTab）换成分屏标签的 key
    static func from(_ tab: CodeTab, session: String) -> String {
        switch tab.kind {
        case .file(let path): return make(.file, session: session, path)
        case .diff(let path, let mode, let commit, let oldPath): return diff(session: session, path: path, mode: mode, commit: commit, oldPath: oldPath)
        case .history(let path): return make(.history, session: session, path ?? "")
        case .commit(let hash): return make(.commit, session: session, hash)
        }
    }
}

/// 代码标签各自的编辑器（网页编辑器一个标签一份）：标签切走、分屏重排时视图会重建，编辑器连同没保存的修改、滚动位置留在这里，
/// 回来时原样接上；标签关了（不在任何一块的标签里了）就扔掉
@MainActor
enum CodeTabStore {
    @MainActor final class Entry {
        let editor = EditorController()
        var file: FileSession?
        var diff: DiffPayload?
        var diffError: String?
        var split = true
        var loaded = false
    }

    private static var entries: [String: Entry] = [:]

    static func entry(_ key: String) -> Entry {
        if let entry = entries[key] { return entry }
        let entry = Entry()
        entries[key] = entry
        return entry
    }

    /// 还有没保存修改的文件标签
    static func isDirty(_ key: String) -> Bool { entries[key].map { !$0.editor.dirty.isEmpty } ?? false }

    /// 分屏里还开着的标签之外的都扔掉（编辑器是网页，留着占内存）
    static func prune(keeping open: Set<String>) {
        for key in entries.keys where !open.contains(key) { entries[key] = nil }
    }

    /// 关标签前选了「保存」：存好回 true
    static func save(_ key: String) async -> Bool {
        guard let entry = entries[key], let file = entry.file else { return true }
        return await file.save(from: entry.editor, id: "file:" + file.path)
    }

    /// 选了「不保存」：编辑器扔掉，下次打开重读
    static func discard(_ key: String) { entries[key] = nil }

    /// 标签上要不要加「●」：只看这一个标签（观察它自己编辑器的 dirty）
    static func dirtyMark(_ key: String) -> Bool { entries[key].map { !$0.editor.dirty.isEmpty } ?? false }
}

/// 分屏里一个代码标签的内容
struct CodeTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let key: String
    let parts: CodeTabKey.Parts
    /// 在别的标签里打开（历史里点了某次提交、提交里点了某个文件、对比里点「打开文件」）
    let open: (String) -> Void
    @AppStorage(EditorPrefs.fontSizeKey) private var fontSize = EditorPrefs.defaultFontSize
    @AppStorage(EditorPrefs.wrapKey) private var wrap = false
    @AppStorage(EditorPrefs.minimapKey) private var minimap = true
    @State private var entry: CodeTabStore.Entry?
    @State private var tick = 0

    private var options: EditorOptions { EditorOptions(dark: scheme == .dark, fontSize: fontSize, wrap: wrap, minimap: minimap) }
    private var store: RepoStore { CodeStores.repo(parts.session, model) }

    var body: some View {
        Group {
            switch parts.kind {
            case .file: fileBody
            case .diff: diffBody
            case .history:
                GitHistoryView(store: store, openCommit: { open(CodeTabKey.make(.commit, session: parts.session, $0)) },
                               path: parts.arg.isEmpty ? nil : parts.arg, wide: true)
            case .commit:
                CommitDetailView(store: store, hash: parts.arg,
                                 openDiff: { file, _ in open(CodeTabKey.diff(session: parts.session, path: file.path, mode: "commit", commit: parts.arg, oldPath: file.oldPath)) },
                                 openCommit: { open(CodeTabKey.make(.commit, session: parts.session, $0)) })
            }
        }
        .background(Theme.chatBackground)
        .gitFailureAlert(store)
        .task(id: key) { await begin() }
        .onChange(of: options) { _, value in entry?.editor.setOptions(value) }
    }

    // MARK: 文件

    @ViewBuilder private var fileBody: some View {
        let session = entry?.file
        VStack(spacing: 0) {
            if let entry, let session {
                if let error = session.error {
                    LoadFailed(error: error) { await reload() }
                } else if session.file == nil {
                    SkeletonPage(nil, style: .code(20))
                } else if !session.isText {
                    FileView(key: parts.session, path: parts.arg)
                } else {
                    fileBar(entry, session)
                    Divider()
                    CodeWebView(controller: entry.editor)
                    EditorStatusBar(editor: entry.editor, branch: store.overview?.branch, eol: session.file?.eol) {}
                }
            } else {
                SkeletonPage(nil, style: .code(20))
            }
        }
    }

    private func fileBar(_ entry: CodeTabStore.Entry, _ session: FileSession) -> some View {
        let id = "file:" + parts.arg
        let dirty = entry.editor.dirty.contains(id)
        return HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(Array(parts.arg.split(separator: "/").enumerated()), id: \.offset) { index, part in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
                    Text(part).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .lineLimit(1)
            if session.file?.editable == false {
                Text(session.file?.truncated == true ? L("只读：文件过大") : L("只读：非 UTF-8")).font(.ui(.caption2)).foregroundStyle(.orange)
            }
            Spacer(minLength: 6)
            Group {
                if dirty {
                    Button { Task { await session.save(from: entry.editor, id: id) } } label: {
                        if session.saving { ProgressView().controlSize(.mini) } else { Text("保存").font(.system(size: 12, weight: .semibold)) }
                    }
                    .help(L("保存（⌘S）"))
                }
                Button { entry.editor.command("find") } label: { Image(systemName: "magnifyingglass") }.help(L("查找和替换（⌘F）"))
                Button {
                    let staged = store.overview?.staged.contains { $0.path == parts.arg } == true && store.overview?.unstaged.contains { $0.path == parts.arg } != true
                    open(CodeTabKey.diff(session: parts.session, path: parts.arg, mode: staged ? "staged" : "unstaged"))
                } label: { Image(systemName: "plusminus") }.help(L("查看未提交的改动"))
                Button { open(CodeTabKey.make(.history, session: parts.session, parts.arg)) } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help(L("查看文件历史"))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .confirmationDialog(L("电脑上的「%@」在你打开之后被修改过（可能是 Claude 改的）", CodePaths.name(parts.arg)),
                            isPresented: Binding(get: { session.conflict }, set: { if !$0 { session.conflict = false } }), titleVisibility: .visible) {
            Button("用我的版本覆盖", role: .destructive) { Task { await session.save(from: entry.editor, id: id, force: true) } }
            Button("放弃我的修改，载入电脑上的版本") { Task { await session.reloadFromDisk(into: entry.editor, id: id) } }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 对比

    @ViewBuilder private var diffBody: some View {
        VStack(spacing: 0) {
            if let entry {
                if let error = entry.diffError {
                    LoadFailed(error: error) { await reload() }
                } else if let payload = entry.diff {
                    DiffToolbar(key: parts.session, payload: payload, editor: entry.editor,
                                split: Binding(get: { entry.split }, set: { entry.split = $0; render(entry, payload); tick += 1 }),
                                wide: true, openFile: payload.mode == "commit" ? nil : { open(CodeTabKey.make(.file, session: parts.session, payload.path)) }) {
                        await reload()
                    }
                    .background(.bar)
                    Divider()
                    if payload.original != nil {
                        CodeWebView(controller: entry.editor)
                    } else if payload.binary {
                        ContentUnavailableView(L("二进制文件"), systemImage: "doc", description: Text("无法显示二进制文件的差异。"))
                    } else {
                        ScrollView { Text(payload.diff).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding() }
                    }
                } else {
                    SkeletonPage(nil, style: .code(20))
                }
            } else {
                SkeletonPage(nil, style: .code(20))
            }
        }
        .id(tick)
    }

    private func render(_ entry: CodeTabStore.Entry, _ payload: DiffPayload) {
        guard let original = payload.original, let modified = payload.modified else { return }
        entry.editor.diff(original: original, modified: modified, path: payload.path, split: entry.split,
                          options: EditorOptions(dark: options.dark, fontSize: options.fontSize, wrap: options.wrap, minimap: false))
    }

    // MARK: 读

    /// 第一次显示这个标签时读一遍；之后切回来编辑器还在（CodeTabStore），不重读
    private func begin() async {
        let entry = CodeTabStore.entry(key)
        self.entry = entry
        guard !entry.loaded else { return }
        entry.loaded = true
        await load(entry)
    }

    private func reload() async {
        guard let entry else { return }
        await load(entry)
    }

    private func load(_ entry: CodeTabStore.Entry) async {
        switch parts.kind {
        case .file:
            let session = entry.file ?? FileSession(key: parts.session, path: parts.arg, model: model)
            entry.file = session
            entry.editor.onSave = { id in Task { await session.save(from: entry.editor, id: id) } }
            tick += 1
            await session.load(into: entry.editor, id: "file:" + parts.arg, readOnly: false, options: options)
            if store.overview == nil { await store.refresh() }
        case .diff:
            let d = parts.diff
            do {
                let payload = try await CodeAPI.diff(model, key: parts.session, path: d.path, mode: d.mode, commit: d.commit, oldPath: d.oldPath)
                entry.diff = payload
                entry.diffError = nil
                render(entry, payload)
            } catch {
                entry.diffError = error.localizedDescription
            }
            tick += 1
        case .history, .commit:
            if store.overview == nil { await store.refresh() }
        }
    }
}
