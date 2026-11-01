import SwiftUI

/// 一个仓库在界面上的状态：概览（改动、分支、远端、标签、贮藏、工作树、会话在哪个分支）、正在做的操作、出错信息。
/// 源代码管理、提交历史、分支与会话几页共用一份，做完操作统一刷新
@MainActor @Observable
final class RepoStore {
    let key: String
    @ObservationIgnored weak var model: AppModel?
    var overview: RepoOverview?
    var loadError: String?
    /// 正在做的操作（按钮转圈、别的操作先等等）
    var busy: String?
    /// Git 报错：弹窗显示，原话可展开
    var failure: GitError?
    /// 历史页、分支页做完操作后要重新拉提交图
    var revision = 0

    init(key: String, model: AppModel) {
        self.key = key
        self.model = model
    }

    var isRepo: Bool { overview?.repo != nil }
    /// 会话所在的那台电脑（认会话用）
    var sourceId: String? { model?.session(key)?.sourceId ?? model?.sessions.first { $0.key == key }?.sourceId }

    func refresh() async {
        guard let model else { return }
        do {
            overview = try await CodeAPI.overview(model, key: key)
            loadError = nil
        } catch {
            if overview == nil { loadError = error.localizedDescription }
        }
    }

    /// 做一个会改仓库的操作；成功了提示一句（done 为空就不提示）、刷新；冲突了提示去解决
    @discardableResult
    func perform(_ op: String, _ body: [String: Any] = [:], label: String, done: String? = nil) async -> [String: Any]? {
        guard let model, busy == nil else { return nil }
        busy = label
        defer { busy = nil }
        do {
            let result = try await CodeAPI.run(model, key: key, op, body)
            if result["conflict"] as? Bool == true {
                model.flash(L("有冲突需要解决：在「源代码管理」里处理后选择继续"))
            } else if let done {
                model.flash(done)
            }
            await refresh()
            revision += 1
            return result
        } catch let error as GitError {
            failure = error
            await refresh()
            revision += 1
        } catch {
            failure = GitError(message: error.localizedDescription, detail: nil)
        }
        return nil
    }

    // MARK: 会话在哪个分支

    /// 这个仓库里正在跑的会话，按工作树分组（主工作树在前）
    func sessionGroups() -> [(tree: RepoWorktree?, branch: String?, sessions: [SessionInfo])] {
        guard let overview, let model else { return [] }
        let source = sourceId
        var byTree: [String: [SessionInfo]] = [:]
        var branchOf: [String: String?] = [:]
        for link in overview.sessions {
            guard let session = model.sessions.first(where: { $0.sessionId == link.sessionId && (source == nil || $0.sourceId == source) }) else { continue }
            let tree = Self.normalize(link.worktree)
            byTree[tree, default: []].append(session)
            branchOf[tree] = link.branch ?? link.detached.map { "(\($0))" }
        }
        var groups: [(tree: RepoWorktree?, branch: String?, sessions: [SessionInfo])] = []
        for tree in overview.worktrees {
            let path = Self.normalize(tree.path)
            let sessions = byTree.removeValue(forKey: path) ?? []
            groups.append((tree, tree.branch ?? (tree.detached ? "(\(tree.head.prefix(8)))" : nil), sessions))
        }
        for (path, sessions) in byTree {   // 工作树列表里没有的（比如刚建的）也列上
            groups.append((nil, branchOf[path] ?? nil, sessions))
        }
        return groups
    }

    /// 某个分支上有哪些会话（提交图的分支标签旁边、分支列表里显示）
    func sessions(onBranch name: String) -> [SessionInfo] {
        sessionGroups().filter { $0.branch == name }.flatMap(\.sessions)
    }

    /// 某个工作树里有哪些会话（切换分支、删工作树前提醒）
    func sessions(inTree path: String) -> [SessionInfo] {
        sessionGroups().first { $0.tree.map { Self.normalize($0.path) } == Self.normalize(path) }?.sessions ?? []
    }

    /// 当前会话所在的工作树（这个 IDE 打开的目录）
    var currentTree: RepoWorktree? {
        guard let overview, let repo = overview.repo else { return nil }
        return overview.worktrees.first { Self.normalize($0.path) == Self.normalize(repo) }
    }

    static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.lowercased().hasPrefix("/private/") ? String(p.dropFirst(8)) : p
    }
}

/// 会话的状态点：运行中（强调色）/ 待确认（橙）/ 空闲（灰）
struct SessionDot: View {
    let session: SessionInfo
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }

    private var color: Color {
        if session.isWaiting { return .orange }
        if session.isBusy { return Theme.claude }
        return Color.secondary.opacity(0.5)
    }
}

extension SessionInfo {
    /// 状态的一句话（分支与会话页里用）
    var stateLabel: String {
        if isWaiting { return L("待确认") }
        if isBusy { return activityText ?? L("运行中") }
        return L("空闲")
    }
}

/// Git 报错的弹窗内容：一句话 + 可展开的原话
struct GitFailureAlert: ViewModifier {
    @Bindable var store: RepoStore

    func body(content: Content) -> some View {
        content.alert(store.failure?.message ?? "", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
            if let detail = store.failure?.detail, !detail.isEmpty {
                Button("拷贝 Git 输出") { Clipboard.copy(detail) }
            }
            Button("好", role: .cancel) {}
        } message: {
            if let detail = store.failure?.detail, !detail.isEmpty {
                Text(String(detail.suffix(600)))
            }
        }
    }
}

extension View {
    func gitFailureAlert(_ store: RepoStore) -> some View { modifier(GitFailureAlert(store: store)) }
}
