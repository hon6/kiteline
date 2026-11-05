import SwiftUI

/// Agent map（同 VS Code 里那张图，从底部弹出）：左边主 agent，连线到它派出的子 agent（子 agent 还能再派）；
/// 下面是后台跑着的命令。点子 agent 看它的任务、工具调用、交回的结果和完整记录；点后台任务看输出。
struct AgentMapSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let key: String
    @State private var reply: AgentsReply?
    @State private var error: String?
    @State private var path: [AgentPage] = []

    /// Mac：往里点是往前（新页面从右边滑进来），返回是往后（从左边滑回来）
    @State private var forward = true

    var body: some View {
        #if os(macOS)
        // Mac 小窗不用系统的导航（推进去没有滑动、工具栏里也不画返回键）：自己叠页面，左右滑动切换；
        // 宽度固定、高度跟着当前页面的内容走（11-05 反馈：点子 agent 在弹窗里左滑出新内容，弹窗高度自适应）
        NavigationStack {
            ZStack(alignment: .top) {
                if let page = path.last {
                    subpage(page).id(page).transition(slide)
                } else {
                    mapPage.transition(slide)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipped()
            .toolbar {
                if !path.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button { back() } label: { Image(systemName: "chevron.left") }
                            .keyboardShortcut("[", modifiers: .command)
                            .help(L("返回"))
                            .panelToolbarItem()
                    }
                }
            }
            .doneButton { dismiss() }
        }
        .environment(\.openAgentPage) { push($0) }
        .task { await refresh() }
        .panelFrame(width: 640)
        #else
        NavigationStack(path: $path) {
            mapPage
                .navigationBarTitleDisplayMode(.inline)
                .doneButton { dismiss() }
                .navigationDestination(for: AgentPage.self) { subpage($0) }
                .task { await refresh() }
        }
        .environment(\.openAgentPage) { path.append($0) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var mapPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let reply {
                    let agents = reply.agents
                    Text(agents.isEmpty ? "尚未派出子 agent" : "\(agents.count) 个子 agent · 轻点查看详情")
                        .font(.ui(.footnote)).foregroundStyle(.secondary)
                    AgentBranch(node: mainNode, children: children(of: "main", in: agents), all: agents, key: key)
                    if !reply.tasks.isEmpty {
                        let running = reply.tasks.filter(\.running).count
                        Text(L("%lld 个后台任务", count: reply.tasks.count) + (running > 0 ? L("（%@ 个运行中）", "\(running)") : "") + L(" · 轻点查看详情"))
                            .font(.ui(.footnote)).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(reply.tasks) { task in
                            Button { if TouchTravel.isTap { push(.task(task)) } } label: { TaskCard(task: task) }
                                .buttonStyle(PressableStyle())
                        }
                    }
                } else if let error {
                    LoadFailed(error: error) { await load() }.padding(.top, 40)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle("Agent map")
    }

    @ViewBuilder
    private func subpage(_ page: AgentPage) -> some View {
        switch page {
        case .agent(let agent): AgentDetailView(key: key, agent: agent, all: reply?.agents ?? [])
        case .task(let task): TaskDetailView(key: key, task: task)
        case .transcript(let agent): SubagentTranscriptView(key: key, agent: agent)
        }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading), removal: .move(edge: forward ? .leading : .trailing))
    }

    private func push(_ page: AgentPage) {
        #if os(macOS)
        forward = true
        withAnimation(.snappy(duration: 0.28)) { path.append(page) }
        #else
        path.append(page)
        #endif
    }

    private func back() {
        guard !path.isEmpty else { return }
        forward = false
        withAnimation(.snappy(duration: 0.28)) { _ = path.removeLast() }
    }

    /// 开着时每 4 秒刷新一次：子 agent 做完、后台命令结束能马上看到
    private func refresh() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private var mainNode: AgentNode {
        let session = model.session(key)
        let context = session?.usage?.context.map { " · \(AgentFormat.tokens($0)) tokens in context" } ?? ""
        return AgentNode(title: session?.title ?? model.pastMeta[key]?.title ?? L("主 agent"),
                         sub: modelName(session?.usage?.model) + context,
                         running: session?.isBusy == true, failed: session?.error != nil, agent: nil)
    }

    private func children(of parent: String, in agents: [SubagentInfo]) -> [SubagentInfo] {
        agents.filter { $0.parent == parent }.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    }

    private func load() async {
        do {
            reply = try await model.api.get(AgentsReply.self, "/api/agents", ["key": key])
            error = nil
        } catch {
            if reply == nil { self.error = error.localizedDescription }
        }
    }
}

/// Agent map 里点进去的页面。用按钮 + 路径而不用 NavigationLink：弹窗被拖动时手指一直按在卡片上，
/// 松手 NavigationLink 就当点了，滚完会自己跳进详情；按钮能先看手指挪没挪（TouchTravel）
enum AgentPage: Hashable {
    case agent(SubagentInfo)
    case task(BackgroundTask)
    case transcript(SubagentInfo)
}

extension EnvironmentValues {
    @Entry var openAgentPage: (AgentPage) -> Void = { _ in }
}

/// 树里的一个节点（主 agent 或子 agent）
struct AgentNode {
    var title: String
    var sub: String
    var running: Bool
    var failed: Bool
    var agent: SubagentInfo?
}

/// 一个节点 + 下面缩进的孩子们（递归）：手机屏幕窄，树竖着长，一屏看全
struct AgentBranch: View {
    let node: AgentNode
    let children: [SubagentInfo]
    let all: [SubagentInfo]
    let key: String
    @Environment(\.openAgentPage) private var open

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agent = node.agent {
                Button { if TouchTravel.isTap { open(.agent(agent)) } } label: { AgentCard(node: node) }
                    .buttonStyle(PressableStyle())
            } else {
                AgentCard(node: node)
            }
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                HStack(alignment: .top, spacing: 0) {
                    TreeGuide(last: index == children.count - 1)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                        .frame(width: 22)
                    AgentBranch(node: AgentNode(title: child.description,
                                                sub: [child.duration, child.tokens > 0 ? "\(AgentFormat.tokens(child.tokens)) tokens" : nil]
                                                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                                running: !child.finished, failed: false, agent: child),
                                children: all.filter { $0.parent == child.id }.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) },
                                all: all, key: key)
                }
            }
        }
    }
}

/// 树的连线（├─ / └─）：竖线把兄弟串起来，横线连到卡片中间
struct TreeGuide: Shape {
    let last: Bool
    /// 卡片中间的高度（卡片高约 56）
    var mid: CGFloat = 28

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + 9
        // 往上多画 8，接上和上一个兄弟之间的空隙
        path.move(to: CGPoint(x: x, y: rect.minY - 8))
        path.addLine(to: CGPoint(x: x, y: last ? rect.minY + mid : rect.maxY))
        path.move(to: CGPoint(x: x, y: rect.minY + mid))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + mid))
        return path
    }
}

struct AgentCard: View {
    let node: AgentNode

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(running: node.running, failed: node.failed).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title).font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                if !node.sub.isEmpty { Text(node.sub).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}

/// 状态点：在跑绿色（会呼吸），做完灰色，出错红色
struct StatusDot: View {
    let running: Bool
    var failed = false

    var body: some View {
        if running && !failed {
            PulseDot(color: Theme.added, size: 8, low: 0.35, period: 0.9)
        } else {
            Circle()
                .fill(failed ? Theme.removed : Color.secondary.opacity(0.6))
                .frame(width: 8, height: 8)
        }
    }
}

struct TaskCard: View {
    let task: BackgroundTask

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(running: task.running, failed: task.status == "failed").padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.description).font(.ui(.subheadline).weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text("shell · \(task.duration)" + (task.running ? "" : " · \(task.statusText)")).font(.ui(.caption)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.ui(.caption).weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: 子 agent 详情

struct AgentDetailView: View {
    let key: String
    let agent: SubagentInfo
    let all: [SubagentInfo]
    @Environment(\.openAgentPage) private var openPage
    @State private var showPrompt = false
    @State private var showTools = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusDot(running: !agent.finished)
                    Text(agent.description).font(.ui(.title3).weight(.semibold))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text([agent.finished ? L("已完成") : L("进行中"), agent.agentType, modelName(agent.model).isEmpty ? nil : modelName(agent.model),
                          agent.requestShape == "background" ? L("后台") : nil].compactMap { $0 }.joined(separator: " · "))
                    Text(agent.parent == "main" ? "由主 agent 派出" : "由「\(all.first { $0.id == agent.parent }?.description ?? L("另一个子 agent"))」派出")
                    Text([agent.duration, agent.tokens > 0 ? "\(AgentFormat.tokens(agent.tokens)) tokens" : nil].compactMap { $0 }.joined(separator: " · "))
                }
                .font(.ui(.footnote)).foregroundStyle(.secondary)
                if !agent.report.isEmpty {
                    MarkdownView(agent.report)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if !agent.finished {
                    PageNote(text: L("正在执行，完成后返回的结果将显示在此处。"))
                }
                DisclosureGroup(isExpanded: $showPrompt) {
                    Text(agent.prompt.isEmpty ? L("（无记录）") : agent.prompt)
                        .font(.ui(.callout)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: { Text("分配的任务").font(.ui(.subheadline).weight(.medium)) }
                DisclosureGroup(isExpanded: $showTools) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(agent.tools.enumerated()), id: \.offset) { _, tool in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(tool.name).font(.ui(.caption).weight(.semibold).monospaced()).fontDesign(nil)
                                Text((tool.brief ?? "").replacingOccurrences(of: "\(tool.name): ", with: ""))
                                    .font(.ui(.caption).monospaced()).fontDesign(nil).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: { Text("调用的工具（\(agent.tools.count)）").font(.ui(.subheadline).weight(.medium)) }
                Button {
                    if TouchTravel.isTap { openPage(.transcript(agent)) }
                } label: {
                    Text("查看完整记录").font(.ui(.subheadline).weight(.medium)).frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(16)
        }
        .navigationTitle("子 agent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 子 agent 的完整记录：和对话页一样的排版，只读
struct SubagentTranscriptView: View {
    @Environment(AppModel.self) private var model
    let key: String
    let agent: SubagentInfo
    @State private var error: String?

    private var chatKey: String { "\(key)|agent:\(agent.id)" }

    var body: some View {
        let chat = model.chat(chatKey)
        let rows = chat.rows(session: nil)
        ScrollView {
            VStack(spacing: 0) {
                if chat.loading { ProgressView().padding(20) }
                if let error { PageNote(text: error).padding() }
                ForEach(rows) { row in ChatRowView(key: chatKey, row: row) }
                Color.clear.frame(height: 12)
            }
            // 和对话页一样照 VS Code 的字号、行高
            .font(ChatType.body)
            .lineSpacing(ChatType.lineSpacing)
        }
        .defaultScrollAnchor(.bottom)
        .background(Theme.chatBackground)
        .environment(\.chatReadOnly, true)
        .navigationTitle(agent.description)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        // 子 agent 还在干活：下拉刷新看它新做的
        .refreshable { await load() }
    }

    private func load() async {
        let chat = model.chat(chatKey)
        chat.loading = true
        defer { chat.loading = false }
        do {
            let page = try await model.api.get(HistoryPage.self, "/api/history", ["key": key, "agent": agent.id, "limit": "400"])
            chat.reset()
            chat.add(page.items)
            chat.loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: 后台任务详情

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let key: String
    @State var task: BackgroundTask
    @State private var output = ""
    @State private var truncated = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusDot(running: task.running, failed: task.status == "failed")
                    Text(task.description).font(.ui(.title3).weight(.semibold))
                }
                Text("shell · \(task.statusText) · \(task.duration)").font(.ui(.footnote)).foregroundStyle(.secondary)
                if let summary = task.summary, !summary.isEmpty { PageNote(text: summary) }
                SectionLabel(text: L("命令"))
                MonoBlock(text: task.command)
                SectionLabel(text: truncated ? L("输出（末尾）") : L("输出"))
                if let error {
                    PageNote(text: error)
                } else {
                    MonoBlock(text: output.isEmpty ? L("（暂无输出）") : output, error: task.status == "failed")
                }
            }
            .padding(16)
        }
        .navigationTitle("后台任务")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // 还在跑：每 3 秒刷一下输出
            repeat {
                await load()
                try? await Task.sleep(for: .seconds(3))
            } while task.running && !Task.isCancelled
        }
    }

    private func load() async {
        do {
            let reply = try await model.api.get("/api/task-output", ["key": key, "task": task.id])
            output = reply["text"] as? String ?? ""
            truncated = reply["truncated"] as? Bool ?? false
            if let raw = reply["task"], let data = try? JSONSerialization.data(withJSONObject: raw),
               let updated = try? JSONDecoder().decode(BackgroundTask.self, from: data) {
                task = updated
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
