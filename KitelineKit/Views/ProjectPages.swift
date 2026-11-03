import PhotosUI
import SwiftUI

/// 项目详情、改动报告、对比、测试报告、项目文件（只读）、新任务（和手机网页版一样）

// MARK: 项目详情

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let project: ProjectInfo
    @State private var past: [PastSession]?
    @State private var pastError: String?
    @State private var showNew = false

    private var lives: [SessionInfo] { model.sessions.filter { $0.sourceId == project.sourceId && $0.cwd == project.cwd } }
    private var key: String? { lives.first?.key ?? project.sessionKey }

    var body: some View {
        let p = project
        List {
            Section {
                HStack(spacing: 12) {
                    Avatar(text: Format.initials(p.name), size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.ui(.title3).weight(.semibold))
                        Text("\(p.sourceName) · \(Bytes.shortPath(p.cwd))").font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                HStack(spacing: 10) {
                    if p.exists { ActionTile(title: L("新建任务"), symbol: "square.and.pencil") { showNew = true } }
                    if let key, p.hasGit, !p.gitTimeout { ActionTile(title: L("查看改动"), symbol: "arrow.triangle.branch") { open(.changes(key)) } }
                    if let key, p.exists { ActionTile(title: L("浏览文件"), symbol: "folder") { open(.files(key: key, path: "")) } }
                    if let key, p.hasGit, !p.gitTimeout { ActionTile(title: L("分支"), symbol: "point.3.connected.trianglepath.dotted") { open(.code(key: key, start: .branches)) } }
                }
                .buttonStyle(PressableStyle())
            }
            if p.gitTimeout {
                Section {
                    Text(HostPlatform.isMac ? "读取 Git 状态超时：位于「文稿」「桌面」或网络磁盘中的项目，需先在电脑上允许 Kiteline 访问该文件夹（系统设置 → 隐私与安全性 → 文件与文件夹）。" : "读取 Git 状态超时：项目可能位于网络磁盘中，或电脑响应缓慢，请稍后重试。")
                        .font(.ui(.footnote)).foregroundStyle(.orange)
                }
            } else if p.hasGit {
                Section {
                    LabeledContent("分支", value: (p.branch ?? L("(无分支)")) + (p.upstream.map { " → \($0)" } ?? L("（无远端）")))
                    LabeledContent("未提交", value: p.changed + p.untracked > 0
                                   ? [p.changed > 0 ? L("%lld 个改动", count: p.changed) : nil, p.untracked > 0 ? L("%lld 个新文件", count: p.untracked) : nil].compactMap { $0 }.joined(separator: " · ")
                                   : L("无，已全部提交"))
                    if p.upstream != nil {
                        LabeledContent("与远端对比", value: p.ahead + p.behind > 0
                                       ? [p.ahead > 0 ? L("领先 %@ 个提交（未推送）", "\(p.ahead)") : nil, p.behind > 0 ? L("落后 %@ 个", "\(p.behind)") : nil].compactMap { $0 }.joined(separator: "，")
                                       : L("一致"))
                    }
                    if let commit = p.lastCommit {
                        LabeledContent("最近提交") {
                            Text(commit + (p.lastCommitAt.map { " · \(Bytes.relative($0))" } ?? "")).multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Git").font(.sectionHeader)
                }
            } else {
                Section { Text("此目录不是 Git 仓库（或该机器未安装 Git）。").font(.ui(.footnote)).foregroundStyle(.secondary) }
            }
            if !lives.isEmpty {
                Section {
                    ForEach(lives) { s in
                        // 各在哪个分支上干活（同一项目里几个会话并行时一眼看清）
                        Button { open(.chat(s.key)) } label: {
                            SessionMini(title: s.title, sub: (s.branch.map { "⎇ \($0) · " } ?? "") + (s.liveStage.map { "\($0.short) · " } ?? "")
                                        + (s.activityText ?? s.preview ?? ""), time: s.updatedAt, live: true)
                        }
                            .buttonStyle(RowButtonStyle())
                    }
                } header: {
                    Text("正在运行").font(.sectionHeader)
                }
            }
            Section {
                if let past {
                    let ended = past.filter { !$0.live }
                    if ended.isEmpty { Text(lives.isEmpty ? "暂无会话记录" : "暂无已结束的会话").foregroundStyle(.secondary) }
                    ForEach(ended) { s in
                        Button { open(.chat(s.key)) } label: { SessionMini(title: s.title, sub: s.firstPrompt ?? "", time: s.lastActive, live: false) }
                            .buttonStyle(RowButtonStyle())
                    }
                } else {
                    Text(pastError ?? L("读取中…")).foregroundStyle(.secondary)
                }
            } header: {
                Text(p.sessions > 0 ? "会话（共 \(p.sessions) 个\(p.today > 0 ? "，今天 \(p.today) 个" : "")）" : "会话").font(.sectionHeader)
            }
        }
        .navigationTitle(p.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await loadPast() }
        .refreshable { await loadPast() }
        .sheetPanel(isPresented: $showNew) { NewTaskView(preset: p) }
    }

    private func loadPast() async {
        do {
            past = try await model.api.get(PastSessionsReply.self, "/api/sessions", ["source": project.sourceId, "cwd": project.cwd]).sessions
            pastError = nil
        } catch { pastError = error.localizedDescription }
    }
}

/// 会话的一行（项目详情里用）
struct SessionMini: View {
    let title: String
    let sub: String
    let time: Double?
    let live: Bool

    var body: some View {
        HStack(spacing: 10) {
            Avatar(text: Format.initials(title), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if live {
                        Text("进行中").font(.ui(.caption2)).foregroundStyle(Theme.claude)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.tile, in: Capsule())
                    }
                    Spacer()
                    Text(Format.listTime(time)).font(.ui(.caption)).foregroundStyle(.tertiary)
                }
                if !sub.isEmpty { Text(sub).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

/// 等宽的操作格子：图标在上、字在下（项目详情顶上）
struct ActionTile: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                TarsIcon(symbol: symbol, size: 32)
                Text(title).font(.ui(.caption).weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// 一排操作按钮里的一个（浅色胶囊）
struct ActionChip: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.ui(.footnote).weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.tile, in: Capsule())
        }
    }
}

// MARK: 改动报告

struct ChangesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let key: String
    @State private var report: GitReport?
    @State private var error: String?
    @State private var asking: GitAsk?

    enum GitAsk: String, Identifiable {
        case commit, push
        var id: String { rawValue }
        var label: String { self == .commit ? L("让 Claude 提交") : L("让 Claude 推送") }
        var confirm: String { self == .commit ? L("让 Claude 把当前改动提交到 Git（只提交，不推送）") : L("让 Claude 把已提交的改动推送到远端（不会强推）") }
        /// 交给 Claude 去做（它会看 diff、写提交信息），手机上不直接动仓库（和网页版同样的话）
        var text: String {
            self == .commit
                ? L("请把当前的改动提交到 git：先看 git status 和 git diff，只提交和这次任务相关的文件，写一条简洁的中文提交信息，然后 git commit。先不要推送，提交完告诉我提交号和改了哪些文件。")
                : L("请把已经提交的改动推送到远端：先用 git status -sb 确认当前分支和要推的远端，然后 git push。推送失败或需要强推时先停下来告诉我，不要自行使用 --force。")
        }
    }

    var body: some View {
        List {
            if let r = report {
                if r.repo == nil {
                    Text(r.reason ?? L("此会话的目录不是 Git 仓库")).foregroundStyle(.secondary)
                } else {
                    Section {
                        HStack {
                            Text("⎇ \(r.branch ?? "(无分支)")" + (r.upstream.map { " → \($0)" } ?? "") + (r.ahead > 0 ? " · ↑\(r.ahead)" : "") + (r.behind > 0 ? " · ↓\(r.behind)" : ""))
                                .font(.ui(.footnote).monospaced()).fontDesign(nil)
                            Spacer()
                            Text((r.repo.map { ($0 as NSString).lastPathComponent }) ?? "").font(.ui(.footnote)).foregroundStyle(.secondary)
                        }
                        Group {
                            if r.files.isEmpty { Text("工作区干净，无未提交的改动") }
                            else { Text("\(r.files.count) 个文件改动 · ") + Text("+\(r.totalAdd)").foregroundColor(Theme.added) + Text(" −\(r.totalDel)").foregroundColor(Theme.removed) }
                        }
                        .font(.ui(.subheadline))
                        if r.untrackedCount > 0 { Text("\(r.untrackedCount) 个新文件").font(.ui(.subheadline)) }
                        if model.session(key)?.canReply == true, !r.files.isEmpty || r.untrackedCount > 0 || r.ahead > 0 {
                            HStack(spacing: 10) {
                                if !r.files.isEmpty || r.untrackedCount > 0 { ActionChip(title: L("让 Claude 提交"), symbol: "checkmark.circle") { asking = .commit } }
                                if r.ahead > 0 { ActionChip(title: L("让 Claude 推送（↑%@）", "\(r.ahead)"), symbol: "arrow.up.circle") { asking = .push } }
                            }
                            .buttonStyle(.steady(.plain))
                        }
                    }
                    if !r.files.isEmpty || !r.untracked.isEmpty {
                        Section {
                            ForEach(r.files, id: \.path) { f in
                                fileRow(f.path, status: f.status, add: f.add ?? 0, del: f.del ?? 0)
                            }
                            ForEach(r.untracked, id: \.self) { path in fileRow(path, status: "??", add: 0, del: 0) }
                        } header: {
                            Text("未提交的改动").font(.sectionHeader)
                        }
                    }
                    if !r.commits.isEmpty {
                        Section {
                            ForEach(r.commits, id: \.hash) { c in
                                Button { open(.diff(key: key, path: nil, commit: c.hash, title: c.subject)) } label: {
                                    HStack(spacing: 8) {
                                        Text(c.hash).font(.ui(.caption).monospaced()).fontDesign(nil).foregroundStyle(.secondary)
                                        Text(c.subject).foregroundStyle(.primary).lineLimit(1)
                                        Spacer()
                                        Text(Bytes.relative(c.ts)).font(.ui(.caption)).foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(RowButtonStyle())
                            }
                        } header: {
                            Text("最近提交").font(.sectionHeader)
                        }
                    }
                }
            }
        }
        .overlay { if report == nil { if let error { LoadFailed(error: error) { await load() } } else { ProgressView() } } }
        .navigationTitle("改动报告")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
        .confirmPanel(asking?.confirm ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), confirm: asking?.label ?? "") {
            guard let ask = asking else { return }
            model.send(key, text: ask.text, images: [])
            model.flash(L("已发送给 Claude"))
        }
    }

    private func fileRow(_ path: String, status: String, add: Int, del: Int) -> some View {
        let name = (path as NSString).lastPathComponent
        let dir = String(path.dropLast(name.count))
        let mark = ["M": L("改"), "A": L("增"), "D": L("删"), "R": L("名"), "C": L("复"), "U": L("冲"), "??": L("新")][status] ?? status
        let color: Color = status == "D" ? Theme.removed : (status == "??" || status == "A" ? Theme.added : .orange)
        return Button { open(.diff(key: key, path: path, commit: nil, title: name)) } label: {
            HStack(spacing: 8) {
                Text(mark).font(.ui(.caption2).weight(.bold)).foregroundStyle(color)
                    .frame(width: 20, height: 20).background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                (Text(dir).foregroundColor(.secondary) + Text(name).foregroundColor(.primary))
                    .font(.ui(.footnote).monospaced()).fontDesign(nil).lineLimit(1).truncationMode(.head)
                Spacer()
                if add + del > 0 {
                    (Text("+\(add)").foregroundColor(Theme.added) + Text(" −\(del)").foregroundColor(Theme.removed)).font(.ui(.caption).monospacedDigit())
                }
            }
        }
        .buttonStyle(RowButtonStyle())
    }

    private func load() async {
        do { report = try await model.api.get(GitReport.self, "/api/git", ["key": key]); error = nil } catch { self.error = error.localizedDescription }
    }
}

// MARK: 对比（diff）

struct GitDiffView: View {
    @Environment(AppModel.self) private var model
    let key: String
    let path: String?
    let commit: String?
    let title: String
    @State private var lines: [String]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let lines {
                if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    PageNote(text: L("无差异")).padding()
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            let (fg, bg) = colors(line)
                            Text(line.isEmpty ? " " : line)
                                .font(.app(size: 12, design: .monospaced)).fontDesign(nil)
                                .foregroundStyle(fg)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(bg)
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else if let error {
                LoadFailed(error: error) { await load() }.padding(.top, 40)
            } else {
                ProgressView().padding(.top, 60)
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        // Claude 还在改：下拉刷新看最新的改动
        .refreshable { await load() }
    }

    private func load() async {
        do {
            var query = ["key": key]
            if let path { query["path"] = path }
            if let commit { query["commit"] = commit }
            let reply = try await model.api.get("/api/git/diff", query)
            lines = Array((reply["diff"] as? String ?? "").components(separatedBy: "\n").prefix(4000))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func colors(_ line: String) -> (Color, Color) {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("new file") {
            return (.secondary, .clear)
        }
        if line.hasPrefix("@@") { return (.secondary, Color.primary.opacity(0.05)) }
        if line.hasPrefix("+") { return (.primary, Theme.added.opacity(0.14)) }
        if line.hasPrefix("-") { return (.primary, Theme.removed.opacity(0.12)) }
        return (.primary, .clear)
    }
}

// MARK: 测试报告

struct TestsView: View {
    @Environment(AppModel.self) private var model
    let key: String
    @State private var runs: [TestRunInfo]?
    @State private var error: String?

    var body: some View {
        List {
            if let runs {
                if runs.isEmpty {
                    // 空状态照系统样式（图标 + 标题 + 说明），不塞在卡片里
                    ContentUnavailableView {
                        Label("尚未运行测试", systemImage: "checkmark.seal")
                    } description: {
                        Text("Claude 在此会话中运行 pytest、jest、vitest、go test、cargo test、npm test 等命令后，结果会显示在这里。")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    let ok = runs.filter { $0.ok == true }.count
                    let bad = runs.filter { $0.ok == false }.count
                    Section {
                        ForEach(runs) { run in
                            NavigationLink { TestRunDetail(run: run) } label: { row(run) }
                        }
                    } header: {
                        Text(L("最近 %@ 次 · %@ 次通过", "\(runs.count)", "\(ok)") + (bad > 0 ? L(" · %@ 次失败", "\(bad)") : "")).textCase(nil).font(.sectionHeader)
                    }
                }
            }
        }
        .overlay { if runs == nil { if let error { LoadFailed(error: error) { await load() } } else { ProgressView() } } }
        .navigationTitle("测试报告")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        // 刚跑完一轮测试：下拉刷新，不用退出重进
        .refreshable { await load() }
    }

    private func load() async {
        do { runs = try await model.api.get(TestsReply.self, "/api/tests", ["key": key]).runs; error = nil } catch { self.error = error.localizedDescription }
    }

    private func row(_ run: TestRunInfo) -> some View {
        HStack(spacing: 10) {
            Group {
                if run.running { Image(systemName: "hourglass").foregroundStyle(Theme.claude) }
                else { Text(run.ok == true ? "✓" : (run.ok == false ? "✗" : "•")) }
            }
            .font(.ui(.headline)).foregroundStyle(run.ok == true ? Theme.added : (run.ok == false ? Theme.removed : .secondary))
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).lineLimit(1)
                let counts = run.passed.map { L("%@ 通过", "\($0)") + ((run.failed ?? 0) > 0 ? L(" · %@ 失败", "\(run.failed!)") : "") } ?? (run.summary ?? "")
                Text([Bytes.relative(run.ts), counts].filter { !$0.isEmpty }.joined(separator: " · ")).font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
    }
}

struct TestRunDetail: View {
    let run: TestRunInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: L("命令"))
                MonoBlock(text: run.command)
                if let summary = run.summary, !summary.isEmpty {
                    SectionLabel(text: L("结果"))
                    PageNote(text: summary)
                }
                SectionLabel(text: L("输出（末尾）"))
                MonoBlock(text: run.output?.isEmpty == false ? run.output! : L("（无输出）"), error: run.ok == false)
            }
            .padding(16)
        }
        .navigationTitle(String(run.title.prefix(40)))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: 项目文件（只读）

struct FilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let key: String
    @State var path: String
    @State private var list: FileList?
    @State private var error: String?
    @State private var query = ""
    @State private var found: FindReply?

    var body: some View {
        List {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                if let found {
                    Section {
                        ForEach(found.results, id: \.self) { rel in
                            Button { open(.file(key: key, path: rel)) } label: {
                                FileRowLabel(name: (rel as NSString).lastPathComponent, sub: (rel as NSString).deletingLastPathComponent.isEmpty ? "./" : (rel as NSString).deletingLastPathComponent, dir: false, git: nil)
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                    } header: {
                        Text(found.results.isEmpty ? L("未找到文件名包含「%@」的文件", "\(query)") : L("找到 %@ 个文件", "\(found.results.count)") + (found.truncated ? L("（仅列出部分结果）") : "")).textCase(nil).font(.sectionHeader)
                    }
                } else {
                    Text("正在搜索…").foregroundStyle(.secondary)
                }
            } else if let list {
                Section {
                    if list.entries.isEmpty { Text("空目录").foregroundStyle(.secondary) }
                    ForEach(list.entries, id: \.name) { e in
                        let rel = list.path.isEmpty ? e.name : "\(list.path)/\(e.name)"
                        Button {
                            if e.type == "dir" { path = rel } else { open(.file(key: key, path: rel)) }
                        } label: {
                            FileRowLabel(name: e.name + (e.link ? " ↪︎" : ""), sub: (e.type == "dir" ? "" : Bytes.size(e.size) + " · ") + Bytes.relative(e.mtime),
                                         dir: e.type == "dir", git: e.git)
                                .opacity(e.name.hasPrefix(".") ? 0.55 : 1)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                } header: {
                    // 当前路径当组头（单独一张卡片只放一个目录名太空）；路径深了左右滑
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            crumb((list.root as NSString).lastPathComponent.isEmpty ? L("项目") : (list.root as NSString).lastPathComponent, target: "")
                            let parts = list.path.split(separator: "/").map(String.init)
                            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                                Text("/").foregroundStyle(.tertiary)
                                crumb(part, target: parts.prefix(index + 1).joined(separator: "/"))
                            }
                        }
                    }
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)   // 路径深了别把一排的总宽往上报
                    .textCase(nil)
                } footer: { Group {
                        if list.truncated { Text("此目录文件过多，仅列出前 2000 个。") }
                    }
                    .font(.ui(.footnote))
                }
            }
        }
        // 去掉分组列表给第一组留的那一大截上边距：路径紧跟在搜索框下面
        .contentMargins(.top, 4, for: .scrollContent)
        .overlay { if list == nil, query.isEmpty { if let error { LoadFailed(error: error) { await load() } } else { ProgressView() } } }
        .panelSearch($query, prompt: L("按文件名搜索（多个关键词以空格分隔）"))
        .navigationTitle("项目文件")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: path) { await load() }
        // Claude 刚建了 / 删了文件：下拉刷新当前目录
        .refreshable { await load() }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            found = nil
            guard !q.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            found = try? await model.api.get(FindReply.self, "/api/files/find", ["key": key, "q": q])
        }
    }

    private func crumb(_ label: String, target: String) -> some View {
        Button(label) { path = target }
            .font(.ui(.footnote).weight(target == path ? .semibold : .regular))
            .foregroundStyle(target == path ? Color.primary : Theme.claude)
            .buttonStyle(.steady(.plain))
    }

    private func load() async {
        do { list = try await model.api.get(FileList.self, "/api/files", ["key": key, "path": path]); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct FileRowLabel: View {
    let name: String
    let sub: String
    let dir: Bool
    let git: String?

    var body: some View {
        HStack(spacing: 10) {
            if dir {
                TarsIcon(symbol: "folder.fill", size: 30)
            } else {
                // 文件：扩展名写在淡橙底上（和图标同一种双色）
                let ext = String(((name as NSString).pathExtension.isEmpty ? "·" : (name as NSString).pathExtension).prefix(4))
                Text(ext).font(.appFixed(size: 9, weight: .bold)).foregroundStyle(Theme.claude)
                    .frame(width: 30, height: 30).background(Theme.iconTile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let git, let mark = ["M": L("改"), "A": L("增"), "D": L("删"), "R": L("名"), "?": L("新"), "•": "•"][git] {
                Text(mark).font(.ui(.caption2).weight(.bold)).foregroundStyle(git == "D" ? Theme.removed : (git == "?" || git == "A" ? Theme.added : .orange))
            }
            if dir { Image(systemName: "chevron.right").font(.ui(.caption).weight(.semibold)).foregroundStyle(.tertiary) }
        }
    }
}

struct FileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: String
    let path: String
    @State private var content: FileContent?
    @State private var error: String?
    @State private var showSource = false
    /// 0 = 内容，1 = 改动记录
    @State private var tab = 0

    private var name: String { (path as NSString).lastPathComponent }
    private var ext: String { (name as NSString).pathExtension.lowercased() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(path).font(.ui(.caption).monospaced()).fontDesign(nil).foregroundStyle(.secondary)
                if let c = content {
                    Text([Bytes.size(c.size), c.lines > 0 ? L("%@ 行", "\(c.lines)") : "", Bytes.relative(c.mtime)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                    let edits = FileChanges.edits(model, key, path).count
                    LookSegmented(selection: $tab, options: [(0, L("内容")), (1, edits > 0 ? L("改动记录 %@", "\(edits)") : L("改动记录"))])
                    if tab == 1 {
                        FileChanges(key: key, path: path)
                    } else {
                    HStack(spacing: 10) {
                        if model.session(key)?.canReply == true {
                            ActionChip(title: L("在对话中引用"), symbol: "quote.opening") {
                                // Claude Code 认 @路径：把文件加进上下文
                                let draft = model.drafts[key] ?? ""
                                model.setDraft(key, (draft.trimmingCharacters(in: .whitespaces).isEmpty ? "" : draft.trimmingCharacters(in: .whitespaces) + " ") + "@\(path) ")
                                model.flash(L("已填入对话输入框"))
                            }
                        }
                        if let text = c.text { ActionChip(title: L("复制内容"), symbol: "doc.on.doc") { Clipboard.copy(text) } }
                        if ext == "md", c.text != nil { ActionChip(title: showSource ? L("查看预览") : L("查看源码"), symbol: "chevron.left.forwardslash.chevron.right") { showSource.toggle() } }
                    }
                    .buttonStyle(.steady(.plain))
                    body(c)
                    }
                } else if let error {
                    LoadFailed(error: error) { await load(reveal: false) }.padding(.top, 40)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(14)
        }
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load(reveal: false) }
        // Claude 刚改过这个文件：下拉刷新（看过的密钥文件刷新后重新遮住）
        .refreshable { await load(reveal: false) }
    }

    @ViewBuilder
    private func body(_ c: FileContent) -> some View {
        if c.secret {
            PageNote(text: L("此文件可能包含密钥或密码（.env、证书、私钥等），默认不显示。"), color: .orange)
            Button("仍然查看") { Task { await load(reveal: true) } }
        } else if c.image, let data = c.data.flatMap({ Data(base64Encoded: $0) }), ImageDisk.tooLarge(data) {
            // 文件不大、声明的像素却极多的图（见 ImageDisk.maxPixels）：整张解码会把手机内存吃光
            PageNote(text: L("图片尺寸过大（超过 6000 万像素），无法在手机上查看。"))
        } else if c.image, let data = c.data.flatMap({ Data(base64Encoded: $0) }), let image = PlatformImage(data: data) {
            Image(platform: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
                #if os(macOS)
                .frame(maxWidth: min(image.size.width, .infinity), alignment: .leading)   // 小图不拉大
                .zoomableOnClick([.local(data)], name: name)   // 点开能放大缩小、拖着看
                #endif
        } else if c.binary || c.tooLarge {
            PageNote(text: c.binary ? L("二进制文件，无法直接查看。") : L("图片过大（超过 6MB），无法在手机上查看。"))
        } else if let text = c.text {
            if ext == "md", !showSource {
                MarkdownView(text)
            } else {
                CodeView(text: text, hashComments: ["py", "sh", "bash", "zsh", "rb", "yml", "yaml", "toml", "conf", "ini", "r", "pl"].contains(ext) || name == "Dockerfile" || name == "Makefile")
            }
            if c.truncated { PageNote(text: L("文件超过 512KB，仅读取了前面部分")) }
        }
    }

    private func load(reveal: Bool) async {
        do {
            var query = ["key": key, "path": path]
            if reveal { query["reveal"] = "1" }
            content = try await model.api.get(FileContent.self, "/api/file", query)
        } catch { self.error = error.localizedDescription }
    }
}

/// 带行号、简单着色的代码（关键字、字符串、注释、数字）
struct CodeView: View {
    let text: String
    let hashComments: Bool

    private static let keywords: Set<String> = Set(("const let var function return if else for while do switch case break continue new class extends import from export default async await try catch finally throw typeof instanceof in of null undefined true false this super static public private protected interface type enum implements def lambda None True False self elif pass raise with as yield func guard struct protocol extension init nil package go defer chan range fn mut impl pub use mod match where crate then end local fi esac done echo").split(separator: " ").map(String.init))

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let shown = Array(lines.prefix(3000))
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)").foregroundStyle(.tertiary).frame(minWidth: 28, alignment: .trailing)
                    Text(highlight(line)).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.app(size: 12, design: .monospaced)).fontDesign(nil)
            }
        }
        .padding(10)
        .background(Theme.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .copyCorner(text)
        if lines.count > shown.count { PageNote(text: L("仅显示前 3000 行（共 %@ 行）", "\(lines.count)")) }
    }

    // 代码高亮：深色模式下用亮一档的颜色（浅色的那几种压在深底上只有 3:1 左右，看不清）
    private static let stringColor = Theme.dynamic(light: 0xC2410C, dark: 0xFB923C)
    private static let numberColor = Theme.dynamic(light: 0x7C3AED, dark: 0xA78BFA)
    private static let keywordColor = Theme.dynamic(light: 0xBE185D, dark: 0xF472B6)

    // 分词的正则编译一次反复用：原来每一行都重新编译，几千行的文件打开、滑动都慢
    private static let hashTokens = try? NSRegularExpression(pattern: #"(#.*$|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b\d+(?:\.\d+)?\b|\b[A-Za-z_]\w*\b)"#)
    private static let slashTokens = try? NSRegularExpression(pattern: #"(//.*$|/\*.*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b|\b[A-Za-z_]\w*\b)"#)

    private func highlight(_ line: String) -> AttributedString {
        var out = AttributedString(line.isEmpty ? " " : line)
        guard let regex = hashComments ? Self.hashTokens : Self.slashTokens else { return out }
        let ns = line as NSString
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            let color: Color?
            if token.hasPrefix("//") || token.hasPrefix("/*") || token.hasPrefix("#") { color = .secondary }
            else if token.hasPrefix("\"") || token.hasPrefix("'") || token.hasPrefix("`") { color = Self.stringColor }
            else if token.first?.isNumber == true { color = Self.numberColor }
            else if Self.keywords.contains(token) { color = Self.keywordColor }
            else { color = nil }
            guard let color, let range = Range(match.range, in: line),
                  let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].foregroundColor = color
        }
        return out
    }
}

// MARK: 新任务

/// 新任务从哪个项目来（待办「创建会话」：原会话所在的机器和目录）
struct TaskOrigin: Equatable {
    var sourceId: String
    var cwd: String
}

struct NewTaskView: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    var preset: ProjectInfo? = nil
    /// 从「定时任务」进来：只能建定时任务
    var scheduleOnly = false
    /// 从待办「创建会话」进来：任务内容先填好（选了哪个项目都带进去，用户看过、改好再开始），能找到原项目就直接选中
    var initialText: String? = nil
    var match: TaskOrigin? = nil
    /// 从提示词链接进来：链接里写的项目（目录名、路径或 owner/repo）。只对上一个就直接选中，几台电脑上都有就筛出来让你挑
    var hint: String? = nil
    @State private var projects: [ProjectInfo]?
    @State private var error: String?
    @State private var query = ""
    @State private var picked: ProjectInfo?
    /// 设备（来源 id）、项目（项目名 = 目录最后一级）筛选，空 = 全部：打开时带入会话列表正筛着的，在这里改不影响会话列表
    @State private var sourceFilter = ""
    @State private var projectFilter = ""
    @AppStorage("listSource") private var listSource = ""
    @AppStorage("listProject") private var listProject = ""

    var body: some View {
        NavigationStack {
            Group {
                if let picked {
                    ComposeTask(project: picked, scheduleOnly: scheduleOnly, change: { self.picked = nil }) { dismiss() }
                } else {
                    projectList
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.panelToolbarButton() } }
        }
        .task {
            if let preset { picked = preset }
            do {
                let reply = try await model.api.get(ProjectsReply.self, "/api/projects")
                projects = reply.projects.filter(\.exists)
                if picked == nil, let match, let found = projects?.first(where: { $0.sourceId == match.sourceId && $0.cwd == match.cwd }) {
                    picked = found
                }
                carryFilters()
                if picked == nil, let hint {
                    let found = projects?.filter { PromptLink.matches(hint, cwd: $0.cwd, name: $0.name) } ?? []
                    if found.count == 1 {
                        picked = found[0]
                    } else if let first = found.first {
                        sourceFilter = ""
                        projectFilter = first.name
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: picked?.id) { _, _ in fill() }
        .onAppear { fill() }
        .paywallHost()
        #if os(macOS)
        .panelFrame(width: 600, height: 640)
        #endif
    }

    /// 选中项目时把带来的内容填进它的草稿（那个项目已经有草稿就不盖掉）
    private func fill() {
        guard let initialText, !initialText.isEmpty, let picked else { return }
        let key = ComposeTask.draftKey(picked)
        if (model.drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.setDraft(key, initialText) }
    }

    /// 带入会话列表正筛着的设备、项目（列表当没筛的——机器不在了、项目里已没有运行中的会话——这里也不筛）；
    /// 已经定了项目（从项目页、待办来的）时，和它对不上的那一项放开，回来换项目时看得见它
    private func carryFilters() {
        let all = projects ?? []
        if model.sources.contains(where: { $0.id == listSource }), all.contains(where: { $0.sourceId == listSource }) {
            sourceFilter = listSource
        }
        if model.sessions.contains(where: { $0.cwd.map { ($0 as NSString).lastPathComponent } == listProject }),
           all.contains(where: { $0.name == listProject }) {
            projectFilter = listProject
        }
        if let picked {
            if !sourceFilter.isEmpty, sourceFilter != picked.sourceId { sourceFilter = "" }
            if !projectFilter.isEmpty, projectFilter != picked.name { projectFilter = "" }
        }
    }

    /// 设备那排：有项目的设备，按会话列表的先后；个数跟着项目筛选走
    private func sourceOptions(_ searched: [ProjectInfo]) -> [ScopeBar.Option] {
        let rank = Dictionary(model.sources.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var names: [String: String] = [:]
        for p in projects ?? [] where names[p.sourceId] == nil { names[p.sourceId] = p.sourceName }
        let inProject = searched.filter { projectFilter.isEmpty || $0.name == projectFilter }
        return names.keys.sorted { (rank[$0] ?? .max, names[$0] ?? "") < (rank[$1] ?? .max, names[$1] ?? "") }.map { id in
            ScopeBar.Option(id: id, title: names[id] ?? id, count: inProject.filter { $0.sourceId == id }.count)
        }
    }

    /// 项目那排：按列表里的先后（最近用过的在前），个数跟着设备筛选走；筛着的那个这台设备上没有也列着
    private func projectOptions(_ searched: [ProjectInfo]) -> [ScopeBar.Option] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for p in searched where sourceFilter.isEmpty || p.sourceId == sourceFilter {
            if counts[p.name] == nil { order.append(p.name) }
            counts[p.name, default: 0] += 1
        }
        if !projectFilter.isEmpty, counts[projectFilter] == nil { order.insert(projectFilter, at: 0) }
        return order.map { ScopeBar.Option(id: $0, title: $0, count: counts[$0] ?? 0) }
    }

    private var projectList: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searched = (projects ?? []).filter { p in q.isEmpty || "\(p.name) \(p.cwd) \(p.sourceName) \(p.title ?? "")".lowercased().contains(q) }
        let shown = searched.filter { (sourceFilter.isEmpty || $0.sourceId == sourceFilter) && (projectFilter.isEmpty || $0.name == projectFilter) }
        let sources = sourceOptions(searched)
        let names = projectOptions(searched)
        let bySource = sources.count > 1 || !sourceFilter.isEmpty
        let byProject = names.count > 1 || !projectFilter.isEmpty
        return List {
            // 设备、项目两排胶囊（同会话列表）：不止一台设备、不止一个项目时才有
            if bySource || byProject {
                VStack(alignment: .leading, spacing: 8) {
                    if bySource {
                        ScopeBar(symbol: "desktopcomputer", allTitle: L("全部设备"), options: sources, selection: $sourceFilter)
                    }
                    if byProject {
                        ScopeBar(symbol: "folder", allTitle: L("全部项目"), options: names, selection: $projectFilter)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(shown) { p in
                    Button { picked = p } label: { ProjectPickRow(project: p) }.buttonStyle(RowButtonStyle())
                }
                if projects != nil, shown.isEmpty {
                    Text(projects?.isEmpty == true ? "暂无使用过 Claude Code 的项目" : "无匹配的项目").foregroundStyle(.secondary)
                }
            } footer: { Group {
                    Text("各机器上最近使用过 Claude Code 的目录、正在运行的会话，以及电脑上已打开的 VS Code 窗口。")
                }
                .font(.ui(.footnote))
            }
        }
        .overlay { if projects == nil { if let error { Text(error).foregroundStyle(.secondary) } else { ProgressView("正在读取项目…") } } }
        .panelSearch($query, prompt: L("搜索项目"))
        .navigationTitle(scheduleOnly ? "定时任务 · 选择项目" : "新任务 · 选择项目")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct ProjectPickRow: View {
    let project: ProjectInfo

    var body: some View {
        let p = project
        HStack(spacing: 10) {
            Avatar(text: Format.initials(p.name), size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).foregroundStyle(.primary).lineLimit(1)
                Text("\(p.sourceName) · \(Bytes.shortPath(p.cwd))").font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if p.live > 0 { Text("\(p.live) 个会话").font(.ui(.caption2)).foregroundStyle(Theme.added) }
                else if p.open { Text("已打开").font(.ui(.caption2)).foregroundStyle(Theme.claude) }
                Text(Bytes.relative(p.lastActive)).font(.ui(.caption2)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// 写新任务：现在开始（可附图、可放进独立分支）或定时
struct ComposeTask: View {
    @Environment(AppModel.self) private var model
    let project: ProjectInfo
    let scheduleOnly: Bool
    let change: () -> Void
    let done: () -> Void
    @State private var when = "now"
    @State private var repeatMode = "daily"
    @State private var date = Date().addingTimeInterval(86400)
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var isolated = false
    @State private var canIsolate = false
    @State private var worktrees = 0
    @State private var picks: [PhotosPickerItem] = []
    @State private var attachments: [ComposeAttachment] = []
    /// 剪贴板里有图：附图那一栏多一行「粘贴」
    @State private var clipboardImage = false
    @State private var busy = false
    @State private var overCap: String?
    @FocusState private var focused: Bool

    static func draftKey(_ project: ProjectInfo) -> String { "new:\(project.sourceId)\n\(project.cwd)" }
    private var draftKey: String { Self.draftKey(project) }
    private var text: Binding<String> { Binding(get: { model.drafts[draftKey] ?? "" }, set: { model.setDraft(draftKey, $0) }) }
    private var ready: Bool { project.open || project.live > 0 }
    private var scheduled: Bool { scheduleOnly || when == "sched" }

    var body: some View {
        Form {
            Section {
                Button(action: change) { ProjectPickRow(project: project) }.buttonStyle(RowButtonStyle())
                if !scheduleOnly {
                    Picker("执行时间", selection: $when) {
                        Text("现在开始").tag("now")
                        Text("定时").tag("sched")
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section {
                TextField("请描述需要 Claude 在此项目中完成的任务", text: text, axis: .vertical)
                    .lineLimit(5...12)
                    .focused($focused)
                #if os(iOS)
                // 说出来转成文字接在后面（同对话页的「转文字」），改好再点开始
                HoldToDictate { said in text.wrappedValue = Dictation.append(said, to: text.wrappedValue) }
                    .listRowSeparator(.hidden)
                #else
                MacDictateButton { said in text.wrappedValue = Dictation.append(said, to: text.wrappedValue) }
                #endif
            }
            if scheduled {
                Section {
                    Picker("重复", selection: $repeatMode) {
                        Text("每天").tag("daily")
                        Text("工作日（周一至周五）").tag("weekdays")
                        Text("仅一次").tag("once")
                    }
                    if repeatMode == "once" { DatePicker("日期", selection: $date, displayedComponents: .date) }
                    DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                } footer: { Group {
                        Text("到达设定时间后，Kiteline 将在该项目的 VS Code 窗口中新建会话并发送任务（电脑需保持开机；因睡眠错过的任务会在 1 小时内补执行）。")
                    }
                    .font(.ui(.footnote))
                }
            } else {
                Section {
                    PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .images) { Label("附图片", systemImage: "photo") }
                    // 剪贴板里有图（刚截的屏、别处拷的图）：系统输入框只粘贴文字，另给一个「粘贴」（同发消息、加待办）
                    if clipboardImage, attachments.count < 6 {
                        HStack(spacing: 10) {
                            Label("剪贴板里有图片", systemImage: "doc.on.clipboard").foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            PasteButton(supportedContentTypes: [.image]) { providers in
                                Task {
                                    ClipboardImage.handled = ClipboardImage.changeCount
                                    clipboardImage = false
                                    let images = await DroppedImages.load(providers)
                                    if images.isEmpty { model.flash(L("无法读取剪贴板里的图片")) }
                                    for raw in images where attachments.count < 6 {
                                        guard let prepared = ImagePrep.prepare(raw) else { continue }
                                        attachments.append(ComposeAttachment(name: "image-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
                                    }
                                }
                            }
                            .labelStyle(.titleAndIcon)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                        }
                    }
                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(attachments) { item in
                                    if let image = PlatformImage(data: item.preview) {
                                        Image(platform: image).resizable().scaledToFill().frame(width: 60, height: 60)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(alignment: .topTrailing) {
                                                Button { attachments.removeAll { $0.id == item.id } } label: {
                                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                                        .frame(width: 30, height: 30, alignment: .topTrailing).contentShape(Rectangle())
                                                }
                                                .buttonStyle(.steady(.plain))
                                                .accessibilityLabel("移除图片")
                                            }
                                    }
                                }
                            }
                        }
                        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)   // 图多了别把一排的总宽往上报
                    }
                    if canIsolate {
                        Toggle(isOn: $isolated) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("在独立分支里做")
                                Text(L("新建 Git worktree（分支以 tars/ 开头），Claude 仅在其中修改，不影响主目录中正在进行的改动") + (worktrees > 0 ? L("（此仓库已有 %@ 个 Kiteline 分支）", "\(worktrees)") : ""))
                                    .font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: { Group {
                        Text(isolated ? L("会在电脑上为新分支打开一个新的 VS Code 窗口") + (project.kind == "ssh" ? L("（Remote-SSH，约需十余秒）") : "")
                             : (ready ? L("在已打开的 VS Code 窗口里新建会话") : L("将先在电脑上打开此项目的 VS Code 窗口") + (project.kind == "ssh" ? L("（Remote-SSH，约需十余秒）") : "")))
                    }
                    .font(.ui(.footnote))
                }
            }
            Section {
                Button {
                    Task { await go(override: false) }
                } label: {
                    Text(busy ? (scheduled ? "正在创建…" : (ready ? "正在新建会话…" : "正在打开 VS Code…")) : (scheduled ? "创建定时任务" : "开始"))
                        .font(.ui(.headline)).frame(maxWidth: .infinity)
                }
                .disabled(busy)
            }
        }
        .navigationTitle(scheduled ? "定时任务" : "新任务")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            focused = true
            clipboardImage = ClipboardImage.offer
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in clipboardImage = ClipboardImage.offer }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in clipboardImage = ClipboardImage.offer }
        #endif
        .task {
            guard let info = try? await model.api.get("/api/repo-info", ["sourceId": project.sourceId, "cwd": project.cwd]),
                  info["repo"] as? String != nil || info["repo"] as? Bool == true else { return }
            canIsolate = true
            worktrees = (info["worktrees"] as? [Any])?.count ?? 0
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            Task {
                for item in items {
                    if let raw = try? await item.loadTransferable(type: Data.self), let prepared = ImagePrep.prepare(raw) {
                        attachments.append(ComposeAttachment(name: "image-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
                    }
                }
            }
        }
        .confirmPanel(overCap.map { L("%@。仍要开始吗？", $0) } ?? "", isPresented: Binding(get: { overCap != nil }, set: { if !$0 { overCap = nil } }),
                      confirm: L("仍然开始")) { Task { await go(override: true) } }
    }

    private func go(override: Bool) async {
        let prompt = (model.drafts[draftKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || (!scheduled && !attachments.isEmpty) else { model.flash(L("请先填写任务内容")); focused = true; return }
        busy = true
        defer { busy = false }
        if scheduled {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            let d = Calendar.current.dateComponents([.year, .month, .day], from: date)
            do {
                let reply = try await model.api.post("/api/schedules", body: [
                    "sourceId": project.sourceId, "cwd": project.cwd, "prompt": prompt, "repeat": repeatMode,
                    "time": String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0),
                    "date": String(format: "%04d-%02d-%02d", d.year ?? 2026, d.month ?? 1, d.day ?? 1),
                ])
                model.setDraft(draftKey, "")
                model.flash(L("已创建：%@", "\((reply["schedule"] as? [String: Any])?["label"] as? String ?? "定时任务")"))
                done()
            } catch { model.show(error) }
            return
        }
        Haptics.tap()
        do {
            let reply = try await model.api.post("/api/new-session", body: [
                "sourceId": project.sourceId, "cwd": project.cwd, "text": prompt,
                "images": attachments.map { ["name": $0.name, "data": $0.data.base64EncodedString()] },
                "override": override, "worktree": isolated && canIsolate,
            ])
            model.setDraft(draftKey, "")
            model.awaitNewSession(sourceId: project.sourceId, cwd: reply["cwd"] as? String ?? project.cwd)
            if let branch = reply["branch"] as? String { model.flash(L("已在独立分支 %@ 开始", "\(branch)")) }
            else { model.flash(reply["submitted"] as? Bool == true ? L("已开始，等待新会话出现…") : (reply["message"] as? String ?? L("已新建会话"))) }
            done()
        } catch let error as APIError where error.data["capExceeded"] as? Bool == true {
            overCap = error.message
        } catch {
            model.show(error)
        }
    }
}

/// 文件的改动记录：Git 里还没提交的改动，加上这次对话里 Claude 对它的每一次修改（新的在上）
struct FileChanges: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let key: String
    /// 相对会话目录的路径
    let path: String
    @State private var git: GitReport?
    @State private var loaded = false
    @State private var expanded: Set<String> = []

    /// 对话里改这个文件的那些步骤（Edit / MultiEdit / Write），新的在前
    @MainActor
    static func edits(_ model: AppModel, _ key: String, _ path: String) -> [ChatItem] {
        let cwd = model.session(key)?.cwd ?? model.pastMeta[key]?.cwd
        let full = cwd.map { ($0 as NSString).appendingPathComponent(path) }
        return model.chat(key).items.values
            .filter { item in
                guard item.t == "tool", ["Edit", "MultiEdit", "Write"].contains(item.name ?? ""),
                      let target = item.input?["file_path"]?.string else { return false }
                if let full { return (target as NSString).standardizingPath == (full as NSString).standardizingPath }
                return target == path || target.hasSuffix("/" + path)
            }
            .sorted { ChatItem.ordered($1, $0) }
    }

    var body: some View {
        let edits = Self.edits(model, key, path)
        VStack(alignment: .leading, spacing: 12) {
            gitSection
            if edits.isEmpty {
                PageNote(text: L("已加载的对话中，Claude 未修改过此文件。"))
            } else {
                Text("本次对话中修改了 \(edits.count) 次").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.secondary)
                ForEach(edits) { item in editCard(item) }
            }
        }
        .task {
            git = try? await model.api.get(GitReport.self, "/api/git", ["key": key])
            loaded = true
        }
    }

    /// 相对仓库根目录的路径（Git 那边认这个；会话目录可能是仓库里的子目录）
    private var repoPath: String {
        guard let repo = git?.repo, let cwd = model.session(key)?.cwd ?? model.pastMeta[key]?.cwd else { return path }
        let full = ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
        let root = (repo as NSString).standardizingPath + "/"
        return full.hasPrefix(root) ? String(full.dropFirst(root.count)) : path
    }

    @ViewBuilder
    private var gitSection: some View {
        let rel = repoPath
        let changed = git?.files.first { $0.path == rel }
        let untracked = git?.untracked.contains(rel) == true
        if changed != nil || untracked {
            Button { open(.diff(key: key, path: rel, commit: nil, title: (path as NSString).lastPathComponent)) } label: {
                HStack(spacing: 10) {
                    TarsIcon(symbol: "arrow.triangle.branch", size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(untracked ? "新文件，尚未提交" : "有尚未提交的改动").foregroundStyle(.primary)
                        if let changed, changed.add != nil || changed.del != nil {
                            HStack(spacing: 6) {
                                Text("+\(changed.add ?? 0)").foregroundStyle(Theme.added)
                                Text("−\(changed.del ?? 0)").foregroundStyle(Theme.removed)
                            }
                            .font(.ui(.caption).monospacedDigit())
                        }
                    }
                    Spacer()
                    Text("查看 diff").font(.ui(.subheadline)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.ui(.caption).weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(RowButtonStyle())
        } else if loaded, git?.repo != nil {
            PageNote(text: L("此文件在 Git 中无未提交的改动。"))
        }
    }

    private func editCard(_ item: ChatItem) -> some View {
        let open = expanded.contains(item.id)
        let stat = Tools.diffStat(item)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { if open { expanded.remove(item.id) } else { expanded.insert(item.id) } }
            } label: {
                HStack(spacing: 8) {
                    Text(item.name == "Write" ? "写入整个文件" : (item.name == "MultiEdit" ? "多处修改" : "修改")).foregroundStyle(.primary)
                    if let stat {
                        Text("+\(stat.added)").foregroundStyle(Theme.added)
                        Text("−\(stat.removed)").foregroundStyle(Theme.removed)
                    }
                    Spacer()
                    if let ts = item.ts { Text(Format.messageTime(ts)).foregroundStyle(.secondary) }
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.ui(.caption).weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.ui(.subheadline).monospacedDigit())
                .contentShape(Rectangle())
            }
            .buttonStyle(.steady(.plain))
            if open { ToolInput(item: item) }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
