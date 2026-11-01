import SwiftUI

/// 分支与会话：最上面一眼看清「几个会话、各在哪个分支 / 工作树上」，下面是本地分支、远端分支、标签、贮藏、工作树和各自的操作
struct GitBranchesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @Bindable var store: RepoStore
    var openCommit: (String) -> Void
    @State private var ask: CodeAsk?
    @State private var nameAsk: NameAsk?
    @State private var query = ""

    var body: some View {
        Group {
            if let o = store.overview, o.repo != nil {
                list(o)
            } else if let o = store.overview {
                ContentUnavailableView(L("不是 Git 仓库"), systemImage: "arrow.triangle.branch", description: Text(o.reason ?? ""))
            } else if let error = store.loadError {
                LoadFailed(error: error) { await store.refresh() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .codeAsks($ask, $nameAsk)
    }

    private func matches(_ name: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    private func list(_ o: RepoOverview) -> some View {
        let groups = store.sessionGroups()
        let sessionCount = groups.reduce(0) { $0 + $1.sessions.count }
        let branchCount = Set(groups.filter { !$0.sessions.isEmpty }.map { $0.branch ?? "" }).count
        return List {
            Section {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    treeCard(group.tree, branch: group.branch, sessions: group.sessions, o: o)
                }
            } header: {
                HStack {
                    Text("会话与分支").font(.sectionHeader)
                    Spacer()
                    Text(sessionCount == 0 ? L("此仓库暂无运行中的会话")
                         : L("%lld 个会话", count: sessionCount) + L("分布在 %lld 个分支上", count: branchCount))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                }
                .textCase(nil)
            } footer: {
                if o.worktrees.count > 1 || sessionCount > 0 {
                    Text("每个工作树是一个独立目录，可以同时检出不同的分支；在不同分支上并行工作的会话互不干扰。").font(.ui(.caption))
                }
            }
            let local = o.branches.filter { matches($0.name) }
            Section {
                ForEach(local) { branch in branchRow(branch, o: o) }
            } header: {
                header(L("本地分支"), count: o.branches.count) {
                    Button {
                        nameAsk = NameAsk(title: L("新建分支"), message: L("从当前位置新建并切换过去"), placeholder: "feature/name", confirm: L("创建")) { name in
                            Task { await store.perform("branch_create", ["name": name], label: L("正在创建分支"), done: L("已切换到新分支「%@」", name)) }
                        }
                    } label: { Image(systemName: "plus") }
                    .help(L("新建分支"))
                }
            }
            let remotes = o.remoteBranches.filter { matches($0.name) }
            if !o.remoteBranches.isEmpty {
                ForEach(Array(Dictionary(grouping: remotes, by: \.remote).sorted { $0.key < $1.key }), id: \.key) { remote, branches in
                    Section {
                        ForEach(branches) { remoteRow($0, o: o) }
                    } header: {
                        header(L("远端 %@", remote), count: branches.count) {
                            Button { Task { await store.perform("fetch", label: L("正在获取"), done: L("已获取远端更新")) } } label: { Image(systemName: "arrow.clockwise") }
                                .help(L("获取"))
                        }
                    }
                }
            }
            let tags = o.tags.filter { matches($0.name) }
            if !o.tags.isEmpty {
                Section {
                    ForEach(tags.prefix(query.isEmpty ? 30 : 200)) { tagRow($0) }
                } header: {
                    header(L("标签"), count: o.tags.count)
                }
            }
            if !o.stashes.isEmpty {
                Section {
                    ForEach(o.stashes) { StashRow(stash: $0, store: store, ask: $ask) }
                } header: {
                    header(L("贮藏"), count: o.stashes.count)
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .panelSearch($query, prompt: L("筛选分支和标签"))
        .refreshable { await store.refresh() }
    }

    // MARK: 会话与分支

    @ViewBuilder
    private func treeCard(_ tree: RepoWorktree?, branch: String?, sessions: [SessionInfo], o: RepoOverview) -> some View {
        let local = branch.flatMap { name in o.branches.first { $0.name == name } }
        let isHere = tree.map { RepoStore.normalize($0.path) == RepoStore.normalize(o.repo ?? "") } ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.ui(.footnote).weight(.semibold)).foregroundStyle(Theme.claude)
                Text(branch ?? L("（未知分支）")).font(.ui(.subheadline).weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if let local, local.ahead + local.behind > 0 {
                    Text([local.ahead > 0 ? "↑\(local.ahead)" : nil, local.behind > 0 ? "↓\(local.behind)" : nil].compactMap { $0 }.joined(separator: " "))
                        .font(.ui(.caption2).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if isHere { tag(L("此目录")) }
                if let tree { tag(tree.main ? L("主工作树") : L("工作树 %@", tree.name)) }
            }
            if sessions.isEmpty {
                Text("暂无会话").font(.ui(.caption)).foregroundStyle(.tertiary).padding(.leading, 20)
            } else {
                ForEach(sessions) { session in
                    Button { open(.chat(session.key)) } label: {
                        HStack(spacing: 8) {
                            SessionDot(session: session)
                            Text(session.title).font(.ui(.subheadline)).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(session.stateLabel).font(.ui(.caption)).foregroundStyle(session.isWaiting ? .orange : .secondary).lineLimit(1)
                            Image(systemName: "chevron.right").font(.ui(.caption2).weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let tree, !tree.main, sessions.isEmpty {
                Text(tree.path).font(.ui(.caption2)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head).padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let tree, !tree.main {
                Button { Clipboard.copy(tree.path) } label: { Label("拷贝工作树路径", systemImage: "doc.on.doc") }
                Button(role: .destructive) {
                    if !sessions.isEmpty {
                        model.flash(L("这个工作树里还有会话在运行，请先结束它们"))
                        return
                    }
                    ask = CodeAsk(message: L("移除工作树「%@」？目录会被删除（分支保留）。有未提交的更改时会拒绝。", tree.name), confirm: L("移除"), destructive: true) {
                        Task { await store.perform("worktree_remove", ["path": tree.path], label: L("正在移除"), done: L("已移除工作树")) }
                    }
                } label: { Label("移除工作树", systemImage: "trash") }
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Theme.tile, in: Capsule())
    }

    // MARK: 本地分支

    private func branchRow(_ b: RepoBranch, o: RepoOverview) -> some View {
        let sessions = store.sessions(onBranch: b.name)
        let elsewhere = b.worktree.map { RepoStore.normalize($0) != RepoStore.normalize(o.repo ?? "") } ?? false
        return HStack(spacing: 8) {
            Image(systemName: b.current ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .font(.ui(.footnote).weight(.semibold)).foregroundStyle(b.current ? Theme.claude : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(b.name).font(.ui(.subheadline).weight(b.current ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    if b.ahead > 0 { Text("↑\(b.ahead)").font(.ui(.caption2).monospacedDigit()).foregroundStyle(Theme.claude) }
                    if b.behind > 0 { Text("↓\(b.behind)").font(.ui(.caption2).monospacedDigit()).foregroundStyle(.orange) }
                }
                Text([b.upstream.map { b.gone ? L("%@（远端已删除）", $0) : $0 }, b.ts.map { Bytes.relative($0) }, b.subject].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !sessions.isEmpty {
                HStack(spacing: -4) { ForEach(sessions.prefix(3)) { SessionDot(session: $0, size: 9).overlay(Circle().stroke(Theme.card, lineWidth: 1.5)) } }
                Text("\(sessions.count)").font(.ui(.caption2)).foregroundStyle(.secondary)
            }
            if elsewhere { Image(systemName: "folder.badge.gearshape").font(.ui(.caption)).foregroundStyle(.secondary).help(L("已在另一个工作树中检出")) }
        }
        .contentShape(Rectangle())
        .contextMenu { branchActions(b, o: o, elsewhere: elsewhere) }
        #if os(iOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !b.current && !elsewhere {
                Button { checkout(b.name, o: o) } label: { Label("切换", systemImage: "arrow.right.circle") }.tint(Theme.claude)
            }
        }
        .swipeActions(edge: .trailing) {
            if !b.current && !elsewhere {
                Button(role: .destructive) { deleteBranch(b) } label: { Label("删除", systemImage: "trash") }
            }
        }
        #endif
        .onTapGesture(count: 2) { if !b.current && !elsewhere { checkout(b.name, o: o) } }
    }

    @ViewBuilder
    private func branchActions(_ b: RepoBranch, o: RepoOverview, elsewhere: Bool) -> some View {
        if !b.current && !elsewhere {
            Button { checkout(b.name, o: o) } label: { Label("切换到此分支", systemImage: "arrow.right.circle") }
        }
        Button { openCommit(b.hash) } label: { Label("查看最新提交", systemImage: "smallcircle.filled.circle") }
        if !b.current {
            Button {
                ask = CodeAsk(message: L("把「%@」合并到当前分支「%@」？", b.name, o.branch ?? "HEAD"), confirm: L("合并")) {
                    Task { await store.perform("merge", ["ref": b.name], label: L("正在合并"), done: L("已合并「%@」", b.name)) }
                }
            } label: { Label("合并到当前分支", systemImage: "arrow.triangle.merge") }
            Button {
                ask = CodeAsk(message: L("把当前分支「%@」变基到「%@」上？当前分支的提交会被改写。", o.branch ?? "HEAD", b.name), confirm: L("变基")) {
                    Task { await store.perform("rebase", ["ref": b.name], label: L("正在变基"), done: L("已变基到「%@」", b.name)) }
                }
            } label: { Label("将当前分支变基到此", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
        }
        Divider()
        Button {
            nameAsk = NameAsk(title: L("从「%@」新建分支", b.name), placeholder: "feature/name", confirm: L("创建并切换")) { name in
                Task { await store.perform("branch_create", ["name": name, "from": b.name], label: L("正在创建分支"), done: L("已切换到新分支「%@」", name)) }
            }
        } label: { Label("从此新建分支…", systemImage: "plus") }
        if !elsewhere && !b.current {
            Button {
                ask = CodeAsk(message: L("为「%@」新建一个工作树？会在仓库旁的「-worktrees」目录里检出这个分支，方便另开会话并行工作。", b.name), confirm: L("新建工作树")) {
                    Task { await store.perform("worktree_add", ["branch": b.name], label: L("正在新建工作树"), done: L("已新建工作树")) }
                }
            } label: { Label("在新工作树中检出", systemImage: "folder.badge.plus") }
        }
        Button {
            nameAsk = NameAsk(title: L("重命名分支"), placeholder: b.name, text: b.name, confirm: L("重命名")) { name in
                Task { await store.perform("branch_rename", ["name": b.name, "to": name], label: L("正在重命名"), done: L("已重命名为「%@」", name)) }
            }
        } label: { Label("重命名…", systemImage: "pencil") }
        if b.current && !o.remotes.isEmpty {
            Button { Task { await store.perform("push", label: L("正在推送"), done: L("已推送")) } } label: { Label("推送到远端", systemImage: "arrow.up") }
        }
        Button { Clipboard.copy(b.name) } label: { Label("拷贝分支名", systemImage: "doc.on.doc") }
        if !b.current && !elsewhere {
            Divider()
            Button(role: .destructive) { deleteBranch(b) } label: { Label("删除分支…", systemImage: "trash") }
        }
    }

    private func checkout(_ name: String, o: RepoOverview) {
        let here = store.currentTree.map { store.sessions(inTree: $0.path) } ?? []
        let running = here.filter { $0.isBusy || $0.isWaiting }
        let run = { Task { await store.perform("checkout", ["ref": name], label: L("正在切换"), done: L("已切换到「%@」", name)) } }
        if here.isEmpty {
            _ = run()
        } else {
            let names = here.prefix(3).map { "「\($0.title)」" }.joined(separator: "、")
            let lead = running.isEmpty ? L("此目录中有 %lld 个会话", count: here.count) : L("此目录中有 %lld 个会话正在运行", count: running.count)
            ask = CodeAsk(message: lead + L("（%@）。", names)
                          + L("切换分支会改变它们看到的文件。如需并行工作，建议「在新工作树中检出」。仍要切换吗？"),
                          confirm: L("仍然切换"), destructive: !running.isEmpty) { _ = run() }
        }
    }

    private func deleteBranch(_ b: RepoBranch) {
        ask = CodeAsk(message: L("删除分支「%@」？", b.name), confirm: L("删除"), destructive: true) {
            Task {
                guard await store.perform("branch_delete", ["name": b.name], label: L("正在删除"), done: L("已删除分支「%@」", b.name)) == nil,
                      store.failure?.detail?.contains("not fully merged") == true else { return }
                store.failure = nil
                ask = CodeAsk(message: L("「%@」还有未合并到其他分支的提交，删除后这些提交将难以找回。仍要强制删除吗？", b.name), confirm: L("强制删除"), destructive: true) {
                    Task { await store.perform("branch_delete", ["name": b.name, "force": true], label: L("正在删除"), done: L("已删除分支「%@」", b.name)) }
                }
            }
        }
    }

    // MARK: 远端分支、标签

    private func remoteRow(_ r: RepoRemoteBranch, o: RepoOverview) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud").font(.ui(.footnote)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.branch).font(.ui(.subheadline)).lineLimit(1).truncationMode(.middle)
                Text([r.ts.map { Bytes.relative($0) }, r.subject].compactMap { $0 }.joined(separator: " · ")).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            let sessions = store.sessions(onBranch: r.branch)
            if !sessions.isEmpty { Text(L("%lld 个会话", count: sessions.count)).font(.ui(.caption2)).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { Task { await store.perform("checkout", ["ref": r.name, "remote": true], label: L("正在检出"), done: L("已切换到「%@」", r.branch)) } } label: {
                Label("检出（建立本地跟踪分支）", systemImage: "arrow.down.circle")
            }
            Button { openCommit(r.hash) } label: { Label("查看最新提交", systemImage: "smallcircle.filled.circle") }
            Button {
                ask = CodeAsk(message: L("把「%@」合并到当前分支「%@」？", r.name, o.branch ?? "HEAD"), confirm: L("合并")) {
                    Task { await store.perform("merge", ["ref": r.name], label: L("正在合并"), done: L("已合并「%@」", r.name)) }
                }
            } label: { Label("合并到当前分支", systemImage: "arrow.triangle.merge") }
            Button { Clipboard.copy(r.name) } label: { Label("拷贝分支名", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) {
                ask = CodeAsk(message: L("从远端「%@」上删除分支「%@」？其他人也将看不到这个分支。", r.remote, r.branch), confirm: L("删除远端分支"), destructive: true) {
                    Task { await store.perform("remote_branch_delete", ["remote": r.remote, "branch": r.branch], label: L("正在删除"), done: L("已删除远端分支")) }
                }
            } label: { Label("删除远端分支…", systemImage: "trash") }
        }
    }

    private func tagRow(_ t: RepoTag) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tag").font(.ui(.footnote)).foregroundStyle(Color(hex: 0xB08800)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name).font(.ui(.subheadline)).lineLimit(1)
                Text([t.ts.map { Bytes.relative($0) }, t.subject].compactMap { $0 }.joined(separator: " · ")).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { openCommit(t.hash) } label: { Label("查看提交", systemImage: "smallcircle.filled.circle") }
            Button { Task { await store.perform("checkout", ["ref": t.name, "detach": true], label: L("正在检出"), done: L("已检出标签「%@」", t.name)) } } label: {
                Label("检出", systemImage: "arrow.uturn.down")
            }
            Button { Clipboard.copy(t.name) } label: { Label("拷贝标签名", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) {
                ask = CodeAsk(message: L("删除本地标签「%@」？", t.name), confirm: L("删除"), destructive: true) {
                    Task { await store.perform("tag_delete", ["name": t.name], label: L("正在删除"), done: L("已删除标签")) }
                }
            } label: { Label("删除标签", systemImage: "trash") }
        }
    }

    private func header(_ title: String, count: Int, @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.sectionHeader)
            Text("\(count)").font(.ui(.caption2).weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.tile, in: Capsule())
            Spacer()
            actions().buttonStyle(.borderless).font(.ui(.footnote).weight(.semibold))
        }
        .textCase(nil)
    }
}
