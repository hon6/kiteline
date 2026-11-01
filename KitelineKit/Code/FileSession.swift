import SwiftUI

/// 代码 IDE 的入口：从哪开始（资源管理器的某个目录、某个文件、源代码管理、提交历史、分支与会话）
enum CodeStart: Hashable {
    case explorer(String)
    case file(String)
    case scm
    case history
    case branches
}

/// 同一个会话的仓库状态、文件树在几页之间共用一份（手机上从首页推进文件、对比、提交页，回来时不用重新拉）
@MainActor
enum CodeStores {
    private static var repos: [String: RepoStore] = [:]
    private static var explorers: [String: ExplorerStore] = [:]

    static func repo(_ key: String, _ model: AppModel) -> RepoStore {
        if let store = repos[key] { store.model = model; return store }
        let store = RepoStore(key: key, model: model)
        repos[key] = store
        return store
    }

    static func explorer(_ key: String, _ model: AppModel) -> ExplorerStore {
        if let store = explorers[key] { store.model = model; return store }
        let store = ExplorerStore(key: key, model: model)
        explorers[key] = store
        return store
    }
}

/// 打开的一个文件：读进来的内容、磁盘上那份的指纹（保存时核对有没有被别人改过）、能不能改
@MainActor @Observable
final class FileSession {
    let key: String
    var path: String
    @ObservationIgnored weak var model: AppModel?
    var file: EditableFile?
    var error: String?
    var loading = false
    var saving = false
    /// 保存时发现电脑上的文件已经变了（多半是 Claude 刚改过）
    var conflict = false
    @ObservationIgnored var sha: String?

    init(key: String, path: String, model: AppModel) {
        self.key = key
        self.path = path
        self.model = model
    }

    var name: String { CodePaths.name(path) }
    var isText: Bool { file?.text != nil && file?.secret != true }

    /// 读文件，交给编辑器（id 是标签号）；顺带取暂存区里的版本给行号旁边的改动竖条
    func load(into editor: EditorController, id: String, readOnly: Bool, options: EditorOptions, line: Int? = nil, reveal: Bool = false) async {
        guard let model else { return }
        loading = true
        defer { loading = false }
        do {
            let file = try await CodeAPI.open(model, key: key, path: path, reveal: reveal)
            self.file = file
            sha = file.sha
            error = nil
            guard let text = file.text, !file.secret else { return }
            editor.open(id: id, path: path, text: text, readOnly: readOnly || !file.editable, line: line, options: options)
            if let diff = try? await CodeAPI.diff(model, key: key, path: path, mode: "unstaged"), diff.original != nil || diff.modified != nil {
                // 未跟踪的新文件没有底稿：整个文件都算新增
                editor.setBaseline(diff.original ?? "")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 保存；电脑上的文件在打开后又被改过就停下来问（force 覆盖）
    @discardableResult
    func save(from editor: EditorController, id: String, force: Bool = false) async -> Bool {
        guard let model, !saving, let text = await editor.text(id) else { return false }
        saving = true
        defer { saving = false }
        do {
            var body: [String: Any] = ["path": path, "text": text]
            if let sha { body["base"] = sha }
            if force { body["force"] = true }
            let result = try await CodeAPI.fs(model, key: key, "write", body)
            if result["conflict"] as? Bool == true {
                conflict = true
                return false
            }
            sha = result["sha"] as? String
            conflict = false
            editor.markSaved(id, text: text)
            model.flash(L("已保存「%@」", name))
            Task { await CodeStores.repo(key, model).refresh() }
            return true
        } catch {
            model.flash(error.localizedDescription)
            return false
        }
    }

    /// 放弃这边的修改，换成电脑上的最新内容
    func reloadFromDisk(into editor: EditorController, id: String) async {
        guard let model, let file = try? await CodeAPI.open(model, key: key, path: path), let text = file.text else { return }
        self.file = file
        sha = file.sha
        conflict = false
        editor.replaceAll(text)
        editor.markSaved(id, text: text)
    }
}

/// 编辑器下面那条状态栏（同 VS Code）：分支、行列、选中、缩进、语言、换行符
struct EditorStatusBar: View {
    let editor: EditorController
    var branch: String?
    var eol: String?
    var openBranches: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            if let branch {
                Button { openBranches?() } label: {
                    Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 6)
            Text(L("行 %@，列 %@", "\(editor.line)", "\(editor.column)") + (editor.selected > 0 ? L("（已选 %@）", "\(editor.selected)") : ""))
            if !editor.indent.isEmpty { Text(editor.indent) }
            Text(eol == "crlf" ? "CRLF" : "LF")
            Text("UTF-8")
            if !editor.language.isEmpty { Text(editor.language) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.tile)
    }
}
