import SwiftUI

/// 源代码管理（同 VS Code 左边那一栏）：当前分支和同步、进行中的合并 / 变基、提交信息、冲突 / 暂存 / 未暂存的改动。
/// 宽屏是 IDE 的侧栏，手机是一页；点改动看对比、点文件打开都交给外面（宽屏开标签，手机推一页）
struct SourceControlPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: RepoStore
    var openDiff: (RepoChange, String) -> Void
    var openFile: (String) -> Void
    var openBranches: () -> Void
    var openHistory: () -> Void
    @State private var message = ""
    @State private var ask: CodeAsk?
    @State private var nameAsk: NameAsk?
    @FocusState private var editing: Bool

    var body: some View {
        Group {
            if let overview = store.overview {
                if overview.repo == nil {
                    notRepo(overview)
                } else {
                    content(overview)
                }
            } else if let error = store.loadError {
                LoadFailed(error: error) { await store.refresh() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .codeAsks($ask, $nameAsk)
    }

    private func notRepo(_ overview: RepoOverview) -> some View {
        ContentUnavailableView {
            Label("不是 Git 仓库", systemImage: "arrow.triangle.branch")
        } description: {
            Text(overview.reason ?? L("此目录还没有使用 Git 管理。"))
        } actions: {
            Button("初始化仓库") {
                Task { await store.perform("init", label: L("正在初始化"), done: L("已初始化 Git 仓库")) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func content(_ o: RepoOverview) -> some View {
        List {
            Section {
                BranchSyncBar(store: store, overview: o, openBranches: openBranches, ask: $ask, nameAsk: $nameAsk)
                if let state = o.state { stateBanner(state, o) }
                if o.identityMissing {
                    Label(L("这台电脑还未设置 Git 提交者（user.name / user.email），提交会失败。请先在电脑上设置。"), systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.ui(.footnote)).foregroundStyle(.orange)
                }
                commitBox(o)
            }
            if !o.conflicts.isEmpty {
                Section {
                    ForEach(o.conflicts) { change in
                        ChangeRow(change: change, mode: "unstaged", store: store, openDiff: openDiff, openFile: openFile, ask: $ask)
                    }
                } header: {
                    sectionHeader(L("合并冲突"), count: o.conflicts.count)
                }
            }
            if !o.staged.isEmpty {
                Section {
                    ForEach(o.staged) { change in
                        ChangeRow(change: change, mode: "staged", store: store, openDiff: openDiff, openFile: openFile, ask: $ask)
                    }
                } header: {
                    sectionHeader(L("暂存的更改"), count: o.staged.count) {
                        Button { Task { await store.perform("unstage_all", label: L("正在取消暂存")) } } label: {
                            Image(systemName: "minus")
                        }
                        .help(L("全部取消暂存"))
                    }
                }
            }
            Section {
                if o.changes.isEmpty && o.staged.isEmpty && o.conflicts.isEmpty {
                    Text("工作区干净，无未提交的更改").font(.ui(.footnote)).foregroundStyle(.secondary)
                }
                ForEach(o.changes) { change in
                    ChangeRow(change: change, mode: change.status == "?" ? "untracked" : "unstaged", store: store, openDiff: openDiff, openFile: openFile, ask: $ask)
                }
                if o.untrackedCount > o.untracked.count {
                    Text(L("另有 %lld 个未跟踪的文件未列出", count: o.untrackedCount - o.untracked.count)).font(.ui(.caption)).foregroundStyle(.secondary)
                }
            } header: {
                sectionHeader(L("更改"), count: o.changes.count + max(0, o.untrackedCount - o.untracked.count)) {
                    if !o.changes.isEmpty {
                        Button {
                            ask = CodeAsk(message: L("丢弃全部 %lld 个文件的更改？已修改的文件会恢复原样，新文件会移到废纸篓。", count: o.changes.count),
                                          confirm: L("全部丢弃"), destructive: true) {
                                Task { await store.perform("discard", ["paths": o.changes.map(\.path)], label: L("正在丢弃"), done: L("已丢弃更改")) }
                            }
                        } label: { Image(systemName: "arrow.uturn.backward") }
                        .help(L("全部丢弃"))
                        Button { Task { await store.perform("stage_all", label: L("正在暂存")) } } label: { Image(systemName: "plus") }
                            .help(L("全部暂存"))
                    }
                }
            }
            if !o.stashes.isEmpty {
                Section {
                    ForEach(o.stashes.prefix(5)) { stash in
                        StashRow(stash: stash, store: store, ask: $ask)
                    }
                } header: {
                    sectionHeader(L("贮藏"), count: o.stashes.count)
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .refreshable { await store.refresh() }
    }

    // MARK: 进行中的合并 / 变基

    @ViewBuilder
    private func stateBanner(_ state: String, _ o: RepoOverview) -> some View {
        let title = switch state {
        case "rebase": L("正在变基")
        case "cherry-pick": L("正在拣选")
        case "revert": L("正在还原")
        default: L("正在合并")
        }
        VStack(alignment: .leading, spacing: 8) {
            Label(title + (o.conflicts.isEmpty ? L("：冲突已全部解决，可以继续") : L("：还有 %lld 个冲突", count: o.conflicts.count)),
                  systemImage: o.conflicts.isEmpty ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .font(.ui(.subheadline).weight(.semibold))
                .foregroundStyle(o.conflicts.isEmpty ? Theme.added : .orange)
            HStack(spacing: 8) {
                Button("继续") { Task { await store.perform("continue", label: L("正在继续"), done: L("已完成")) } }
                    .buttonStyle(.borderedProminent).disabled(!o.conflicts.isEmpty)
                if state != "merge" {
                    Button("跳过此提交") { Task { await store.perform("skip", label: L("正在跳过")) } }.buttonStyle(.bordered)
                }
                Button("中止", role: .destructive) {
                    ask = CodeAsk(message: L("放弃这次操作？仓库会回到开始之前的状态。"), confirm: L("中止"), destructive: true) {
                        Task { await store.perform("abort", label: L("正在放弃"), done: L("已放弃")) }
                    }
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: 提交

    private func commitBox(_ o: RepoOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("提交信息（在「%@」上提交）", o.branch ?? "HEAD"), text: $message, axis: .vertical)
                .lineLimit(2...8)
                .font(.ui(.body))
                .textFieldStyle(.plain)
                .focused($editing)
                .padding(8)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(editing ? Theme.claude.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1))
                .onSubmit { commit() }
            #if os(iOS)
            HoldToDictate { text in message = message.isEmpty ? text : message + (message.hasSuffix("\n") ? "" : " ") + text }
            #endif
            HStack(spacing: 8) {
                Button {
                    commit()
                } label: {
                    HStack(spacing: 6) {
                        if store.busy == L("正在提交") { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark") }
                        Text(o.staged.isEmpty && !o.changes.isEmpty ? L("提交全部") : L("提交改动"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.busy != nil || (o.staged.isEmpty && o.changes.isEmpty) || o.state == "rebase")
                Menu {
                    Button { commit(push: true) } label: { Label("提交并推送", systemImage: "arrow.up.circle") }
                    Button { commit(all: true) } label: { Label("提交全部更改（含未暂存）", systemImage: "tray.full") }
                    Button { commit(amend: true) } label: { Label("修改上一次提交", systemImage: "pencil.circle") }
                    if model.session(store.key)?.canReply == true {
                        Divider()
                        Button {
                            model.send(store.key, text: ChangesView.GitAsk.commit.text, images: [])
                            model.flash(L("已发送给 Claude"))
                        } label: { Label("让 Claude 写提交信息并提交", systemImage: "sparkles") }
                    }
                } label: {
                    Image(systemName: "chevron.down").frame(width: 16)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
    }

    private func commit(push: Bool = false, all: Bool = false, amend: Bool = false) {
        guard let o = store.overview else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && !amend {
            model.flash(L("请先填写提交信息"))
            editing = true
            return
        }
        // 没暂存任何东西：同 VS Code，提交全部（先说一声）
        let everything = all || (o.staged.isEmpty && !amend)
        Task {
            var body: [String: Any] = ["message": text]
            if everything { body["all"] = true }
            if amend { body["amend"] = true }
            guard await store.perform("commit", body, label: L("正在提交"), done: push ? nil : (amend ? L("已修改上一次提交") : L("已提交"))) != nil else { return }
            message = ""
            if push { await store.perform("push", label: L("正在推送"), done: L("已提交并推送")) }
        }
    }

    private func sectionHeader(_ title: String, count: Int, @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.sectionHeader)
            Text("\(count)").font(.ui(.caption2).weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.tile, in: Capsule())
            Spacer()
            actions().buttonStyle(.borderless).font(.ui(.footnote).weight(.semibold))
        }
        .textCase(nil)
    }
}

/// 分支和同步：⎇ 当前分支（点开分支与会话）、领先 / 落后、获取 / 拉取 / 推送、更多
struct BranchSyncBar: View {
    @Environment(AppModel.self) private var model
    let store: RepoStore
    let overview: RepoOverview
    var openBranches: () -> Void
    @Binding var ask: CodeAsk?
    @Binding var nameAsk: NameAsk?

    var body: some View {
        let o = overview
        let sessions = store.currentTree.map { store.sessions(inTree: $0.path) } ?? []
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：当前分支（点开「分支与会话」）和这个目录里有几个会话
            Button(action: openBranches) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.ui(.footnote).weight(.semibold)).foregroundStyle(Theme.claude)
                    Text(o.branch ?? (o.oid.map { "(\($0.prefix(8)))" } ?? L("（无提交）")))
                        .font(.ui(.subheadline).weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                    if let upstream = o.upstream {
                        Text("→ " + upstream).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if !sessions.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(sessions.prefix(3)) { SessionDot(session: $0, size: 7) }
                            Text(L("%lld 个会话", count: sessions.count)).font(.ui(.caption2)).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                    Image(systemName: "chevron.right").font(.ui(.caption2).weight(.bold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 第二行：同步
            HStack(spacing: 8) {
                if store.busy != nil {
                    ProgressView().controlSize(.small)
                    Text(store.busy ?? "").font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                } else {
                    syncButtons(o)
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func syncButtons(_ o: RepoOverview) -> some View {
        let hasRemote = !o.remotes.isEmpty
        if hasRemote {
            Button { Task { await store.perform("pull", label: L("正在拉取"), done: L("已拉取")) } } label: {
                Label(o.behind > 0 ? L("拉取 %@", "\(o.behind)") : L("拉取"), systemImage: "arrow.down")
            }
            .help(L("拉取"))
            Button {
                Task { await store.perform("push", label: L("正在推送"), done: o.upstream == nil ? L("已推送并关联远端分支") : L("已推送")) }
            } label: {
                Label(o.ahead > 0 ? L("推送 %@", "\(o.ahead)") : (o.upstream == nil ? L("发布分支") : L("推送到远端")), systemImage: "arrow.up")
            }
            .help(o.upstream == nil ? L("推送并关联远端分支") : L("推送到远端"))
        } else {
            Text("未配置远端仓库").font(.ui(.caption)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Menu {
            if hasRemote {
                Button { Task { await store.perform("fetch", label: L("正在获取"), done: L("已获取远端更新")) } } label: { Label("获取", systemImage: "arrow.clockwise.icloud") }
                Button { Task { await store.perform("pull", ["rebase": false], label: L("正在拉取"), done: L("已拉取")) } } label: { Label("拉取（合并）", systemImage: "arrow.down") }
                Button { Task { await store.perform("pull", ["rebase": true], label: L("正在拉取"), done: L("已拉取")) } } label: { Label("拉取（变基）", systemImage: "arrow.down.to.line") }
                Button {
                    ask = CodeAsk(message: L("强制推送会用本地的「%@」覆盖远端分支（使用 --force-with-lease：远端有别人新推的提交时会拒绝）。确定吗？", o.branch ?? ""),
                                  confirm: L("强制推送"), destructive: true) {
                        Task { await store.perform("push", ["force": true], label: L("正在推送"), done: L("已强制推送")) }
                    }
                } label: { Label("强制推送", systemImage: "exclamationmark.arrow.triangle.2.circlepath") }
                Divider()
            }
            Button { Task { await store.perform("stash_save", label: L("正在贮藏"), done: L("已贮藏更改")) } } label: { Label("贮藏更改", systemImage: "archivebox") }
            Button { Task { await store.perform("stash_save", ["untracked": true], label: L("正在贮藏"), done: L("已贮藏更改")) } } label: { Label("贮藏（含未跟踪的文件）", systemImage: "archivebox.fill") }
            if !o.stashes.isEmpty {
                Button { Task { await store.perform("stash_pop", ["ref": "stash@{0}"], label: L("正在恢复"), done: L("已恢复最近的贮藏")) } } label: { Label("恢复最近的贮藏", systemImage: "tray.and.arrow.up") }
            }
            Divider()
            Button {
                nameAsk = NameAsk(title: L("新建分支"), message: L("从当前位置新建并切换过去"), placeholder: "feature/name", confirm: L("创建")) { name in
                    Task { await store.perform("branch_create", ["name": name], label: L("正在创建分支"), done: L("已切换到新分支「%@」", name)) }
                }
            } label: { Label("新建分支…", systemImage: "plus") }
            Button(action: openBranches) { Label("分支与会话", systemImage: "arrow.triangle.branch") }
            Divider()
            Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 一个改动：状态字母、文件名、所在目录、增删行数；点开看对比。手机左滑暂存 / 右滑丢弃，Mac 鼠标移上去出按钮
struct ChangeRow: View {
    @Environment(AppModel.self) private var model
    let change: RepoChange
    /// staged / unstaged / untracked（冲突的按 unstaged）
    let mode: String
    let store: RepoStore
    var openDiff: (RepoChange, String) -> Void
    var openFile: (String) -> Void
    @Binding var ask: CodeAsk?
    @State private var hover = false

    var body: some View {
        Button { change.status == "U" ? openFile(change.path) : openDiff(change, mode) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(change.name).font(.ui(.subheadline)).foregroundStyle(change.status == "D" ? .secondary : .primary)
                        .strikethrough(change.status == "D").lineLimit(1)
                    if !change.folder.isEmpty || change.oldPath != nil {
                        Text(change.oldPath.map { L("由 %@ 重命名", $0) } ?? change.folder)
                            .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                #if os(macOS)
                if hover { actions.buttonStyle(.borderless).labelStyle(.iconOnly) }
                #endif
                if change.add + change.del > 0 {
                    (Text("+\(change.add)").foregroundColor(Theme.added) + Text(" −\(change.del)").foregroundColor(Theme.removed))
                        .font(.ui(.caption2).monospacedDigit())
                }
                ChangeBadge(status: change.status)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu { actions; Divider(); commonActions }
        #if os(iOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if mode == "staged" {
                Button { Task { await store.perform("unstage", ["paths": [change.path]], label: L("正在取消暂存")) } } label: { Label("取消暂存", systemImage: "minus") }
                    .tint(.gray)
            } else {
                Button { Task { await store.perform(change.status == "U" ? "resolve" : "stage", change.status == "U" ? ["path": change.path] : ["paths": [change.path]], label: L("正在暂存")) } } label: {
                    Label(change.status == "U" ? L("标记已解决") : L("暂存"), systemImage: "plus")
                }
                .tint(Theme.added)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if mode != "staged" && change.status != "U" {
                Button(role: .destructive) { discard() } label: { Label("丢弃", systemImage: "arrow.uturn.backward") }
            }
        }
        #endif
    }

    @ViewBuilder
    private var actions: some View {
        if change.status == "U" {
            Button { openFile(change.path) } label: { Label("打开文件解决冲突", systemImage: "doc.text") }
            Button { Task { await store.perform("resolve", ["path": change.path, "side": "ours"], label: L("正在解决"), done: L("已使用当前分支的版本")) } } label: {
                Label("使用当前分支的版本", systemImage: "arrow.left.circle")
            }
            Button { Task { await store.perform("resolve", ["path": change.path, "side": "theirs"], label: L("正在解决"), done: L("已使用传入的版本")) } } label: {
                Label("使用传入的版本", systemImage: "arrow.right.circle")
            }
            Button { Task { await store.perform("resolve", ["path": change.path], label: L("正在解决"), done: L("已标记为已解决")) } } label: {
                Label("标记为已解决（暂存）", systemImage: "checkmark.circle")
            }
        } else if mode == "staged" {
            Button { openFile(change.path) } label: { Label("打开文件", systemImage: "doc.text") }
            Button { Task { await store.perform("unstage", ["paths": [change.path]], label: L("正在取消暂存")) } } label: { Label("取消暂存", systemImage: "minus") }
        } else {
            if change.status != "D" { Button { openFile(change.path) } label: { Label("打开文件", systemImage: "doc.text") } }
            Button { discard() } label: { Label("丢弃更改", systemImage: "arrow.uturn.backward") }
            Button { Task { await store.perform("stage", ["paths": [change.path]], label: L("正在暂存")) } } label: { Label("暂存", systemImage: "plus") }
        }
    }

    @ViewBuilder
    private var commonActions: some View {
        Button { Clipboard.copy(change.path) } label: { Label("拷贝相对路径", systemImage: "doc.on.doc") }
        if model.session(store.key)?.canReply == true {
            Button {
                let draft = model.drafts[store.key] ?? ""
                model.setDraft(store.key, (draft.trimmingCharacters(in: .whitespaces).isEmpty ? "" : draft.trimmingCharacters(in: .whitespaces) + " ") + "@\(change.path) ")
                model.flash(L("已填入对话输入框"))
            } label: { Label("在对话中引用", systemImage: "quote.opening") }
        }
    }

    private func discard() {
        let message = change.status == "?" ? L("删除未跟踪的文件「%@」？文件会移到废纸篓。", change.name)
            : L("丢弃「%@」的更改？文件会恢复到暂存区（或上一次提交）的样子，此操作无法撤销。", change.name)
        ask = CodeAsk(message: message, confirm: change.status == "?" ? L("移到废纸篓") : L("丢弃更改"), destructive: true) {
            Task { await store.perform("discard", ["paths": [change.path]], label: L("正在丢弃"), done: L("已丢弃更改")) }
        }
    }
}

struct StashRow: View {
    let stash: RepoStash
    let store: RepoStore
    @Binding var ask: CodeAsk?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(stash.title).font(.ui(.subheadline)).lineLimit(1)
                Text([stash.ref, stash.ts.map { Bytes.relative($0) }].compactMap { $0 }.joined(separator: " · ")).font(.ui(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contextMenu {
            Button { Task { await store.perform("stash_apply", ["ref": stash.ref], label: L("正在应用"), done: L("已应用贮藏")) } } label: { Label("应用", systemImage: "tray.and.arrow.down") }
            Button { Task { await store.perform("stash_pop", ["ref": stash.ref], label: L("正在恢复"), done: L("已恢复并删除贮藏")) } } label: { Label("恢复并删除", systemImage: "tray.and.arrow.up") }
            Button(role: .destructive) {
                ask = CodeAsk(message: L("删除贮藏「%@」？此操作无法撤销。", stash.title), confirm: L("删除"), destructive: true) {
                    Task { await store.perform("stash_drop", ["ref": stash.ref], label: L("正在删除"), done: L("已删除贮藏")) }
                }
            } label: { Label("删除", systemImage: "trash") }
        }
        #if os(iOS)
        .swipeActions(edge: .leading) {
            Button { Task { await store.perform("stash_pop", ["ref": stash.ref], label: L("正在恢复"), done: L("已恢复并删除贮藏")) } } label: { Label("恢复贮藏", systemImage: "tray.and.arrow.up") }
                .tint(Theme.added)
        }
        #endif
    }
}
