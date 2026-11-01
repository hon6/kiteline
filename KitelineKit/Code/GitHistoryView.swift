import SwiftUI

/// 提交历史：提交图（每条分支一种颜色的线，汇合 / 分叉一眼看出）+ 分支 / 标签胶囊 + 分支上有几个会话。
/// 点一行看提交详情；右键（长按）检出、建分支、打标签、拣选、还原、重置
struct GitHistoryView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: RepoStore
    var openCommit: (String) -> Void
    /// 只看某个文件的历史
    var path: String? = nil
    var wide = false
    @State private var commits: [CommitRow] = []
    @State private var width = 0
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var onlyCurrent = false
    @State private var ask: CodeAsk?
    @State private var nameAsk: NameAsk?

    private var rowHeight: CGFloat { wide ? 30 : 52 }
    private var lane: CGFloat { wide ? 13 : 12 }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(commits) { commit in
                        row(commit)
                            .onAppear { if commit.id == commits.last?.id, more, !loading { Task { await load(more: true) } } }
                    }
                    if loading {
                        ProgressView().padding()
                    } else if commits.isEmpty, error == nil {
                        Text(query.isEmpty ? L("还没有任何提交") : L("没有匹配的提交")).foregroundStyle(.secondary).padding(30)
                    }
                    if let error { LoadFailed(error: error) { await load() }.padding(.top, 30) }
                }
            }
        }
        .task(id: "\(query)|\(onlyCurrent)|\(store.revision)|\(path ?? "")") {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .codeAsks($ask, $nameAsk)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.ui(.caption)).foregroundStyle(.secondary)
                TextField(L("搜索提交信息或提交号"), text: $query).textFieldStyle(.plain).font(.ui(.subheadline))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if path == nil {
                Picker("", selection: $onlyCurrent) {
                    Text("全部分支").tag(false)
                    Text("当前分支").tag(true)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func load(more next: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            let page = try await CodeAPI.log(model, key: store.key, skip: next ? commits.count : 0, limit: 200, path: path, query: query,
                                             ref: onlyCurrent ? "HEAD" : nil)
            if next {
                // 提交图是从头算的：第二页的线和第一页接得上
                commits += page.commits
            } else {
                commits = page.commits
            }
            width = max(width, page.width)
            if !next { width = page.width }
            more = page.more
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: 一行

    @ViewBuilder
    private func row(_ c: CommitRow) -> some View {
        let graphWidth = c.graph == nil ? 0 : CGFloat(max(1, width)) * lane + 6
        Button { openCommit(c.hash) } label: {
            HStack(spacing: 6) {
                if let graph = c.graph {
                    GraphCell(graph: graph, lane: lane, height: rowHeight, head: c.refs.contains { $0.current }, merge: c.parents.count > 1)
                        .frame(width: graphWidth, height: rowHeight)
                }
                if wide {
                    HStack(spacing: 6) {
                        refs(c)
                        Text(c.subject).font(.ui(.subheadline)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(c.author).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
                        Text(c.ts.map { Bytes.relative($0) } ?? "").font(.ui(.caption)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        Text(c.short).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 64, alignment: .leading)
                    }
                    .padding(.trailing, 10)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            refs(c)
                            Text(c.subject).font(.ui(.subheadline)).lineLimit(1)
                        }
                        Text("\(c.author) · \(c.ts.map { Bytes.relative($0) } ?? "") · \(c.short)")
                            .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.trailing, 10)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { CommitActions(store: store, hash: c.hash, short: c.short, subject: c.subject, ask: $ask, nameAsk: $nameAsk) }
    }

    @ViewBuilder
    private func refs(_ c: CommitRow) -> some View {
        if !c.refs.isEmpty {
            HStack(spacing: 3) {
                ForEach(c.refs.prefix(wide ? 4 : 2), id: \.self) { ref in
                    RefChip(ref: ref, sessions: ref.type == "branch" ? store.sessions(onBranch: ref.name).count : 0)
                }
                if c.refs.count > (wide ? 4 : 2) { Text("+\(c.refs.count - (wide ? 4 : 2))").font(.ui(.caption2)).foregroundStyle(.secondary) }
            }
            .fixedSize()
        }
    }
}

/// 提交图的一格：服务端算好的线段照着画（竖线直画，换列的画成平滑的 S 形），圆点在本提交那一列
struct GraphCell: View {
    let graph: GraphRow
    let lane: CGFloat
    let height: CGFloat
    var head = false
    var merge = false

    var body: some View {
        Canvas { context, size in
            let ys: [CGFloat] = [0, height / 2, height]
            func x(_ col: Int) -> CGFloat { CGFloat(col) * lane + lane / 2 + 3 }
            for seg in graph.segs where seg.count >= 5 {
                var path = Path()
                let start = CGPoint(x: x(seg[0]), y: ys[min(2, max(0, seg[1]))])
                let end = CGPoint(x: x(seg[2]), y: ys[min(2, max(0, seg[3]))])
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let mid = (start.y + end.y) / 2
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: mid), control2: CGPoint(x: end.x, y: mid))
                }
                context.stroke(path, with: .color(GraphPalette.color(seg[4])), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            let center = CGPoint(x: x(graph.col), y: height / 2)
            let r: CGFloat = head ? 5 : 4
            let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            let color = GraphPalette.color(graph.color)
            if merge {
                // 合并提交：空心圆
                context.fill(dot, with: .color(color.opacity(0.22)))
                context.stroke(dot, with: .color(color), lineWidth: 1.8)
            } else {
                context.fill(dot, with: .color(color))
            }
            if head {
                let ring = Path(ellipseIn: CGRect(x: center.x - r - 2.5, y: center.y - r - 2.5, width: (r + 2.5) * 2, height: (r + 2.5) * 2))
                context.stroke(ring, with: .color(color.opacity(0.45)), lineWidth: 1.5)
            }
        }
    }
}

/// 一个提交能做的事（提交图里右键 / 长按、提交详情的工具栏）
struct CommitActions: View {
    @Environment(AppModel.self) private var model
    let store: RepoStore
    let hash: String
    let short: String
    let subject: String
    @Binding var ask: CodeAsk?
    @Binding var nameAsk: NameAsk?

    var body: some View {
        Button { Clipboard.copy(hash); model.flash(L("已拷贝提交号")) } label: { Label("拷贝提交号", systemImage: "number") }
        Button { Clipboard.copy(subject) } label: { Label("拷贝提交信息", systemImage: "doc.on.doc") }
        Divider()
        Button {
            nameAsk = NameAsk(title: L("从此提交新建分支"), message: short, placeholder: "feature/name", confirm: L("创建并切换")) { name in
                Task { await store.perform("branch_create", ["name": name, "from": hash], label: L("正在创建分支"), done: L("已切换到新分支「%@」", name)) }
            }
        } label: { Label("新建分支…", systemImage: "arrow.triangle.branch") }
        Button {
            nameAsk = NameAsk(title: L("新建标签"), message: short, placeholder: "v1.0.0", confirm: L("创建")) { name in
                Task { await store.perform("tag_create", ["name": name, "ref": hash], label: L("正在创建标签"), done: L("已创建标签「%@」", name)) }
            }
        } label: { Label("新建标签…", systemImage: "tag") }
        Button {
            ask = CodeAsk(message: L("检出提交 %@？会进入「游离 HEAD」状态，在这里的新提交不属于任何分支（可以随后新建分支保存）。", short), confirm: L("检出")) {
                Task { await store.perform("checkout", ["ref": hash, "detach": true], label: L("正在检出"), done: L("已检出 %@", short)) }
            }
        } label: { Label("检出此提交", systemImage: "arrow.uturn.down") }
        Divider()
        Button {
            Task { await store.perform("cherry_pick", ["ref": hash], label: L("正在拣选"), done: L("已拣选到当前分支")) }
        } label: { Label("拣选到当前分支", systemImage: "arrow.turn.down.right") }
        Button {
            ask = CodeAsk(message: L("新建一个提交来撤销 %@ 的改动？", short), confirm: L("还原")) {
                Task { await store.perform("revert", ["ref": hash], label: L("正在还原"), done: L("已还原")) }
            }
        } label: { Label("还原此提交", systemImage: "arrow.uturn.backward") }
        Menu {
            Button(L("软重置（保留改动并暂存）")) { reset("soft") }
            Button(L("混合重置（保留改动，不暂存）")) { reset("mixed") }
            Button(L("硬重置（丢弃所有改动）"), role: .destructive) { reset("hard") }
        } label: { Label("将当前分支重置到这里", systemImage: "clock.arrow.circlepath") }
    }

    private func reset(_ mode: String) {
        let branch = store.overview?.branch ?? "HEAD"
        let message = mode == "hard"
            ? L("把「%@」硬重置到 %@？之后的提交和所有未提交的更改都会丢失，此操作无法撤销。", branch, short)
            : L("把「%@」重置到 %@？之后的提交会被撤出分支，文件改动保留在工作区。", branch, short)
        ask = CodeAsk(message: message, confirm: L("重置"), destructive: mode == "hard") {
            Task { await store.perform("reset", ["ref": hash, "mode": mode], label: L("正在重置"), done: L("已重置到 %@", short)) }
        }
    }
}

/// 提交详情：提交信息、作者时间、父提交、所在分支、改了哪些文件（点开看对比）
struct CommitDetailView: View {
    @Environment(AppModel.self) private var model
    let store: RepoStore
    let hash: String
    var openDiff: (RepoChange, String) -> Void
    var openCommit: (String) -> Void
    @State private var info: CommitInfo?
    @State private var error: String?
    @State private var ask: CodeAsk?
    @State private var nameAsk: NameAsk?

    var body: some View {
        List {
            if let info {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(info.subject).font(.ui(.headline)).textSelection(.enabled)
                        let body = info.message.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !body.isEmpty { Text(body).font(.ui(.subheadline)).foregroundStyle(.secondary).textSelection(.enabled) }
                        if !info.refs.isEmpty {
                            HStack(spacing: 4) { ForEach(info.refs, id: \.self) { RefChip(ref: $0) } }
                        }
                    }
                    .padding(.vertical, 4)
                    LabeledContent("作者") { Text("\(info.author) <\(info.email)>").textSelection(.enabled).multilineTextAlignment(.trailing) }
                    if let ts = info.ts { LabeledContent("时间", value: Self.date(ts)) }
                    if !info.committer.isEmpty && info.committer != info.author { LabeledContent("提交者", value: info.committer) }
                    LabeledContent("提交号") {
                        Button { Clipboard.copy(info.hash); model.flash(L("已拷贝提交号")) } label: {
                            Text(String(info.hash.prefix(12))).font(.system(.footnote, design: .monospaced))
                        }
                        .buttonStyle(.plain)
                    }
                    if !info.parents.isEmpty {
                        LabeledContent(info.parents.count > 1 ? "父提交（合并）" : "父提交") {
                            HStack(spacing: 6) {
                                ForEach(info.parents, id: \.self) { parent in
                                    Button(String(parent.prefix(8))) { openCommit(parent) }.font(.system(.footnote, design: .monospaced))
                                }
                            }
                        }
                    }
                    if !info.branches.isEmpty {
                        LabeledContent("所在分支") { Text(info.branches.prefix(6).joined(separator: ", ")).multilineTextAlignment(.trailing) }
                    }
                }
                Section {
                    ForEach(info.files) { file in
                        Button { openDiff(file, "commit") } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name).font(.ui(.subheadline)).lineLimit(1)
                                    if !file.folder.isEmpty { Text(file.folder).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                                }
                                Spacer()
                                if file.add + file.del > 0 {
                                    (Text("+\(file.add)").foregroundColor(Theme.added) + Text(" −\(file.del)").foregroundColor(Theme.removed)).font(.ui(.caption2).monospacedDigit())
                                }
                                ChangeBadge(status: file.status)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L("%lld 个文件", count: info.files.count) + " · ").font(.sectionHeader)
                        + Text("+\(info.files.reduce(0) { $0 + $1.add })").foregroundColor(Theme.added).font(.sectionHeader)
                        + Text(" −\(info.files.reduce(0) { $0 + $1.del })").foregroundColor(Theme.removed).font(.sectionHeader)
                }
            }
        }
        .overlay { if info == nil { if let error { LoadFailed(error: error) { await load() } } else { ProgressView() } } }
        .navigationTitle(info.map { String($0.hash.prefix(8)) } ?? L("提交详情"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let info {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        CommitActions(store: store, hash: info.hash, short: String(info.hash.prefix(8)), subject: info.subject, ask: $ask, nameAsk: $nameAsk)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task(id: hash) { await load() }
        .codeAsks($ask, $nameAsk)
    }

    private func load() async {
        do { info = try await CodeAPI.commit(model, key: store.key, hash: hash); error = nil } catch { self.error = error.localizedDescription }
    }

    static func date(_ ms: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
