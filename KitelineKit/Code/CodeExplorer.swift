import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 资源管理器：项目文件树（点文件夹展开，同 VS Code）+ 文件操作（新建、改名、复制剪切粘贴、创建副本、删除到废纸篓、上传、拷贝路径、在对话中引用）
@MainActor @Observable
final class ExplorerStore {
    let key: String
    @ObservationIgnored weak var model: AppModel?
    /// 目录 → 里面的东西（展开过才有）
    var listings: [String: [CodeEntry]] = [:]
    var expanded: Set<String> = [""]
    var loading: Set<String> = []
    var errors: [String: String] = [:]
    var rootName = ""
    /// 复制 / 剪切下来、等着粘贴的
    var clipboard: (paths: [String], cut: Bool)?
    /// 搜索文件名
    var query = ""
    var found: [String]?
    /// 文件操作后告诉 IDE（改了名的标签跟着改、删了的关掉）
    @ObservationIgnored var onRenamed: ((String, String) -> Void)?
    @ObservationIgnored var onDeleted: (([String]) -> Void)?
    @ObservationIgnored var onChanged: (() -> Void)?

    init(key: String, model: AppModel) {
        self.key = key
        self.model = model
    }

    struct Row: Identifiable, Hashable {
        var path: String
        var entry: CodeEntry
        var depth: Int
        var id: String { path }
    }

    /// 展开的文件夹摊成一列
    var rows: [Row] {
        var out: [Row] = []
        func walk(_ folder: String, _ depth: Int) {
            for entry in listings[folder] ?? [] {
                let path = CodePaths.join(folder, entry.name)
                out.append(Row(path: path, entry: entry, depth: depth))
                if entry.isDir && expanded.contains(path) { walk(path, depth + 1) }
            }
        }
        walk("", 0)
        return out
    }

    func load(_ folder: String) async {
        guard let model else { return }
        loading.insert(folder)
        defer { loading.remove(folder) }
        do {
            let list = try await CodeAPI.list(model, key: key, path: folder)
            listings[folder] = list.entries
            if folder.isEmpty { rootName = (list.root as NSString).lastPathComponent }
            errors[folder] = nil
        } catch {
            errors[folder] = error.localizedDescription
        }
    }

    func toggle(_ folder: String) {
        if expanded.contains(folder) {
            expanded.remove(folder)
        } else {
            expanded.insert(folder)
            if listings[folder] == nil { Task { await load(folder) } }
        }
    }

    /// 打开某个文件时把它所在的文件夹一路展开
    func reveal(_ path: String) async {
        var folder = ""
        for part in CodePaths.folder(path).split(separator: "/") {
            folder = CodePaths.join(folder, String(part))
            expanded.insert(folder)
            if listings[folder] == nil { await load(folder) }
        }
    }

    /// 刷新所有展开的文件夹（Claude 刚建了 / 删了文件）
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for folder in expanded where folder.isEmpty || listings[folder] != nil {
                group.addTask { await self.load(folder) }
            }
        }
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let model else { found = nil; return }
        let reply = try? await model.api.get("/api/files/find", ["key": key, "q": q])
        found = reply?["results"] as? [String] ?? []
    }

    // MARK: 文件操作

    /// 做一个文件操作；失败了提示原因，成功了刷新相关的文件夹
    @discardableResult
    func run(_ op: String, _ body: [String: Any], refresh folders: [String], done: String? = nil) async -> [String: Any]? {
        guard let model else { return nil }
        do {
            let result = try await CodeAPI.fs(model, key: key, op, body)
            for folder in Set(folders) where listings[folder] != nil || folder.isEmpty { await load(folder) }
            if let done { model.flash(done) }
            onChanged?()
            return result
        } catch {
            model.flash(error.localizedDescription)
            return nil
        }
    }

    func create(in folder: String, name: String, dir: Bool) async -> String? {
        let path = CodePaths.join(folder, name)
        guard let result = await run("create", ["path": path, "kind": dir ? "dir" : "file"], refresh: [folder, CodePaths.folder(path)]) else { return nil }
        expanded.insert(folder)
        if dir { expanded.insert(path) }
        return result["path"] as? String
    }

    func rename(_ path: String, to name: String) async {
        guard let result = await run("rename", ["path": path, "name": name], refresh: [CodePaths.folder(path)]),
              let renamed = result["path"] as? String else { return }
        onRenamed?(path, renamed)
    }

    func duplicate(_ path: String) async {
        await run("copy", ["paths": [path], "dest": CodePaths.folder(path)], refresh: [CodePaths.folder(path)], done: L("已创建副本"))
    }

    func paste(into folder: String) async {
        guard let clip = clipboard else { return }
        let sources = clip.paths.map(CodePaths.folder)
        if await run(clip.cut ? "move" : "copy", ["paths": clip.paths, "dest": folder], refresh: [folder] + sources,
                     done: clip.cut ? L("已移动") : L("已粘贴")) != nil {
            if clip.cut {
                for path in clip.paths { onRenamed?(path, CodePaths.join(folder, CodePaths.name(path))) }
                clipboard = nil
            }
            expanded.insert(folder)
        }
    }

    func delete(_ paths: [String]) async {
        if await run("delete", ["paths": paths], refresh: paths.map(CodePaths.folder), done: L("已移到废纸篓")) != nil {
            onDeleted?(paths)
        }
    }

    func upload(_ files: [(name: String, data: Data)], into folder: String) async {
        for file in files {
            await run("upload", ["dest": folder, "name": file.name, "data": file.data.base64EncodedString()], refresh: [folder])
        }
        model?.flash(L("已上传 %lld 个文件", count: files.count))
        expanded.insert(folder)
    }
}

/// 文件树
struct ExplorerTree: View {
    @Environment(AppModel.self) private var model
    @Bindable var explorer: ExplorerStore
    /// 当前打开的文件（高亮）
    var activePath: String?
    var openFile: (String) -> Void
    var openHistory: ((String) -> Void)? = nil
    @State private var ask: CodeAsk?
    @State private var nameAsk: NameAsk?
    @State private var uploadTarget: String?
    @State private var importing = false
    @State private var photoTarget: String?
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        List {
            if let found = explorer.found {
                Section {
                    if found.isEmpty { Text(L("未找到文件名包含「%@」的文件", explorer.query)).foregroundStyle(.secondary) }
                    ForEach(found, id: \.self) { path in
                        Button { openFile(path) } label: {
                            HStack(spacing: 8) {
                                FileGlyph(name: CodePaths.name(path), dir: false)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(CodePaths.name(path)).font(.ui(.subheadline)).lineLimit(1)
                                    Text(CodePaths.folder(path).isEmpty ? "./" : CodePaths.folder(path)).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Section {
                    ForEach(explorer.rows) { row in
                        rowView(row)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowBackground(row.path == activePath ? Theme.claude.opacity(0.14) : Color.clear)
                    }
                    if explorer.listings[""] == nil {
                        if let error = explorer.errors[""] {
                            LoadFailed(error: error) { await explorer.load("") }
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    } else if explorer.listings[""]?.isEmpty == true {
                        Text("空目录").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 10) {
                        Text(explorer.rootName.isEmpty ? L("项目") : explorer.rootName).font(.sectionHeader).lineLimit(1)
                        Spacer()
                        Group {
                            Button { newItem(in: "", dir: false) } label: { Image(systemName: "doc.badge.plus") }.help(L("新建文件"))
                            Button { newItem(in: "", dir: true) } label: { Image(systemName: "folder.badge.plus") }.help(L("新建文件夹"))
                            Button { Task { await explorer.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }.help(L("刷新"))
                            Button { explorer.expanded = [""] } label: { Image(systemName: "rectangle.compress.vertical") }.help(L("全部折叠"))
                        }
                        .buttonStyle(.borderless)
                        .font(.ui(.footnote).weight(.semibold))
                    }
                    .textCase(nil)
                    .contextMenu { folderMenu("") }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
        #else
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 38)
        #endif
        .panelSearch($explorer.query, prompt: L("按文件名搜索"))
        .task(id: explorer.query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await explorer.search()
        }
        .task { if explorer.listings[""] == nil { await explorer.load("") } }
        .refreshable { await explorer.refreshAll() }
        .codeAsks($ask, $nameAsk)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, let folder = uploadTarget else { return }
            let files: [(name: String, data: Data)] = urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return (try? Data(contentsOf: url)).map { (url.lastPathComponent, $0) }
            }
            Task { await explorer.upload(files, into: folder) }
        }
        .photosPicker(isPresented: Binding(get: { photoTarget != nil }, set: { if !$0 { photoTarget = nil } }), selection: $photos, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty, let folder = photoTarget ?? uploadTarget else { return }
            photos = []
            Task {
                var files: [(name: String, data: Data)] = []
                for (index, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        let stamp = Int(Date().timeIntervalSince1970)
                        files.append(("image-\(stamp)\(items.count > 1 ? "-\(index + 1)" : "").\(ext)", data))
                    }
                }
                await explorer.upload(files, into: folder)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ExplorerStore.Row) -> some View {
        let e = row.entry
        Button {
            if e.isDir { explorer.toggle(row.path) } else { openFile(row.path) }
        } label: {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(explorer.expanded.contains(row.path) ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .opacity(e.isDir ? 1 : 0)
                FileGlyph(name: e.name, dir: e.isDir, open: explorer.expanded.contains(row.path))
                Text(e.name + (e.link ? " ↪︎" : ""))
                    .font(.ui(.subheadline))
                    .foregroundStyle(nameColor(e))
                    .lineLimit(1)
                    .opacity(e.name.hasPrefix(".") ? 0.6 : 1)
                if explorer.clipboard?.cut == true && explorer.clipboard?.paths.contains(row.path) == true {
                    Image(systemName: "scissors").font(.ui(.caption2)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if explorer.loading.contains(row.path) { ProgressView().controlSize(.mini) }
                if let mark = e.git {
                    Text(mark == "?" ? "U" : mark).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(nameColor(e))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { e.isDir ? AnyView(folderMenu(row.path)) : AnyView(fileMenu(row.path)) }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { confirmDelete([row.path]) } label: { Label("删除", systemImage: "trash") }
            Button { rename(row.path) } label: { Label("重命名", systemImage: "pencil") }.tint(.gray)
        }
        #endif
        .draggable(row.path)
        .dropDestination(for: String.self) { items, _ in
            guard e.isDir else { return false }
            let moving = items.filter { $0 != row.path && CodePaths.folder($0) != row.path }
            guard !moving.isEmpty else { return false }
            Task {
                explorer.clipboard = (moving, true)
                await explorer.paste(into: row.path)
            }
            return true
        }
    }

    private func nameColor(_ e: CodeEntry) -> Color {
        switch e.git {
        case "?", "A": Theme.added
        case "M", "•", "R": Color(hex: 0xD29922)
        case "D": Theme.removed
        default: .primary
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: String) -> some View {
        Button { newItem(in: folder, dir: false) } label: { Label("新建文件…", systemImage: "doc.badge.plus") }
        Button { newItem(in: folder, dir: true) } label: { Label("新建文件夹…", systemImage: "folder.badge.plus") }
        if let clip = explorer.clipboard {
            Button { Task { await explorer.paste(into: folder) } } label: {
                Label(clip.cut ? L("移动到这里（%lld 项）", count: clip.paths.count) : L("粘贴（%lld 项）", count: clip.paths.count), systemImage: "doc.on.clipboard")
            }
        }
        Button { uploadTarget = folder; importing = true } label: { Label("上传文件到这里…", systemImage: "square.and.arrow.up") }
        #if os(iOS)
        Button { uploadTarget = folder; photoTarget = folder } label: { Label("从照片上传…", systemImage: "photo") }
        #endif
        if !folder.isEmpty {
            Divider()
            Button { explorer.clipboard = ([folder], false); model.flash(L("已复制，在目标文件夹上选择「粘贴」")) } label: { Label("复制", systemImage: "doc.on.doc") }
            Button { explorer.clipboard = ([folder], true); model.flash(L("已剪切，在目标文件夹上选择「移动到这里」")) } label: { Label("剪切", systemImage: "scissors") }
            Button { Task { await explorer.duplicate(folder) } } label: { Label("创建副本", systemImage: "plus.square.on.square") }
            Button { rename(folder) } label: { Label("重命名…", systemImage: "pencil") }
            pathItems(folder)
            Divider()
            Button(role: .destructive) { confirmDelete([folder]) } label: { Label("删除", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func fileMenu(_ path: String) -> some View {
        Button { openFile(path) } label: { Label("打开", systemImage: "doc.text") }
        if let openHistory {
            Button { openHistory(path) } label: { Label("查看文件历史", systemImage: "clock.arrow.circlepath") }
        }
        Button { FileOpener.shared.open(model, key: explorer.key, path: path) } label: { Label("用其他应用打开", systemImage: "arrow.up.forward.app") }
        Button { FileOpener.shared.open(model, key: explorer.key, path: path, share: true) } label: { Label("分享…", systemImage: "square.and.arrow.up") }
        Divider()
        Button { explorer.clipboard = ([path], false); model.flash(L("已复制，在目标文件夹上选择「粘贴」")) } label: { Label("复制", systemImage: "doc.on.doc") }
        Button { explorer.clipboard = ([path], true); model.flash(L("已剪切，在目标文件夹上选择「移动到这里」")) } label: { Label("剪切", systemImage: "scissors") }
        Button { Task { await explorer.duplicate(path) } } label: { Label("创建副本", systemImage: "plus.square.on.square") }
        Button { rename(path) } label: { Label("重命名…", systemImage: "pencil") }
        pathItems(path)
        Divider()
        Button(role: .destructive) { confirmDelete([path]) } label: { Label("删除", systemImage: "trash") }
    }

    @ViewBuilder
    private func pathItems(_ path: String) -> some View {
        Button { Clipboard.copy(path); model.flash(L("已拷贝相对路径")) } label: { Label("拷贝相对路径", systemImage: "link") }
        if let root = model.session(explorer.key)?.cwd {
            Button { Clipboard.copy((root as NSString).appendingPathComponent(path)); model.flash(L("已拷贝路径")) } label: { Label("拷贝完整路径", systemImage: "link.badge.plus") }
        }
        if model.session(explorer.key)?.canReply == true {
            Button {
                let draft = model.drafts[explorer.key] ?? ""
                model.setDraft(explorer.key, (draft.trimmingCharacters(in: .whitespaces).isEmpty ? "" : draft.trimmingCharacters(in: .whitespaces) + " ") + "@\(path) ")
                model.flash(L("已填入对话输入框"))
            } label: { Label("在对话中引用", systemImage: "quote.opening") }
        }
    }

    private func newItem(in folder: String, dir: Bool) {
        nameAsk = NameAsk(title: dir ? L("新建文件夹") : L("新建文件"),
                          message: folder.isEmpty ? L("位置：项目根目录") : L("位置：%@", folder),
                          placeholder: dir ? L("文件夹名") : L("文件名（可带子目录，如 src/app.js）"), confirm: L("创建")) { name in
            Task {
                guard let created = await explorer.create(in: folder, name: name, dir: dir) else { return }
                if !dir {
                    await explorer.reveal(created)
                    openFile(created)
                }
            }
        }
    }

    private func rename(_ path: String) {
        let name = CodePaths.name(path)
        nameAsk = NameAsk(title: L("重命名"), placeholder: name, text: name, confirm: L("重命名")) { newName in
            guard newName != name else { return }
            Task { await explorer.rename(path, to: newName) }
        }
    }

    private func confirmDelete(_ paths: [String]) {
        let message = paths.count == 1 ? L("删除「%@」？会移到电脑的废纸篓，可以从那里恢复。", CodePaths.name(paths[0]))
            : L("删除 %lld 项？会移到电脑的废纸篓，可以从那里恢复。", count: paths.count)
        ask = CodeAsk(message: message, confirm: L("移到废纸篓"), destructive: true) {
            Task { await explorer.delete(paths) }
        }
    }
}

/// 文件 / 文件夹的图标：按扩展名挑一个 SF Symbol，单色（文件夹用强调色）
struct FileGlyph: View {
    let name: String
    let dir: Bool
    var open = false

    var body: some View {
        Image(systemName: dir ? (open ? "folder" : "folder.fill") : Self.symbol(name))
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(dir ? Theme.claude : Color.secondary)
            .frame(width: 18)
    }

    static func symbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "cc", "m", "mm", "cs", "php", "lua", "sh", "bash", "zsh", "ps1", "dart", "scala", "vue":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "ini", "conf", "cfg", "plist", "xml", "lock": return "curlybraces"
        case "md", "markdown", "txt", "rst", "rtf": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "ico", "icns", "bmp", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "tar": return "doc.zipper"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return "waveform"
        case "mp4", "mov", "m4v", "webm", "avi": return "film"
        case "html", "htm", "css", "scss", "less": return "globe"
        case "sql", "db", "sqlite": return "cylinder.split.1x2"
        default:
            if name.hasPrefix(".") || ["Dockerfile", "Makefile", "LICENSE"].contains(name) { return "gearshape" }
            return "doc"
        }
    }
}
