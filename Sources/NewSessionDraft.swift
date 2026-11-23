import AppKit
import CryptoKit
import SwiftUI
import KitelineKit

// 新会话标签页（11-20 反馈：标签页旁边的「+」里最上面加「新建会话」，按当前窗口带好项目、设备、agent，直接开一个标签页，
// 发消息后新的会话自动接到这个标签页上——和 VS Code 里新开 Claude Code 对话标签一样）。
// 标签的 key 是「@new:<随机号>|<设备>|<agent>|<目录>」：分屏会记住标签，重开 App 后草稿还在、带的东西也在。
// 标签里的界面（NewSessionDraftView）：顶上项目 / 设备 / Agent 三个下拉，中间一句说明，底下输入框；
// 发出去就在那台电脑那个目录开会话（NewSession.start / MobileServer.startAgent，同新任务），等它出现在会话列表里，
// 把这个标签换成那个会话（KitelineKit.panes.replace）

enum NewDraftKey {
    static let prefix = "@new:"

    struct Place: Equatable {
        var sourceId: String
        var cwd: String
        var agent: String
    }

    static func make(_ place: Place) -> String {
        prefix + String(UUID().uuidString.prefix(8)).lowercased() + "|" + place.sourceId + "|" + place.agent + "|" + place.cwd
    }

    static func parse(_ key: String) -> Place? {
        guard key.hasPrefix(prefix) else { return nil }
        let bits = key.dropFirst(prefix.count).split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard bits.count == 4 else { return nil }
        return Place(sourceId: bits[1], cwd: bits[3], agent: bits[2].isEmpty ? "claude-code" : bits[2])
    }

    /// 按现在的窗口带：「项目」里开着项目就是那个项目（文件看的那台设备）；否则开「+」之前这块显示的会话、再否则当前块的会话所在的项目；
    /// agent 跟那个会话（项目里有会话在跑就跟它）。一个会话都没有就用本机、主目录
    @MainActor
    static func context(previous: String?) -> Place? {
        let model = KitelineModel.shared
        let projects = ProjectsModel.shared
        if model.newLayout, model.sideTab == "projects", let id = model.projectPane, let member = projects.fileMember(id) {
            let agent = projects.live(group: projects.members(id)).first?.agent ?? "claude-code"
            return Place(sourceId: member.sourceId, cwd: member.cwd, agent: agent)
        }
        for key in [previous, KitelineKit.panes.focused, model.selection].compactMap({ $0 }) {
            if let session = model.session(key) { return Place(sourceId: session.sourceId, cwd: session.cwd, agent: session.agent) }
        }
        if let session = model.sessions.first { return Place(sourceId: session.sourceId, cwd: session.cwd, agent: session.agent) }
        guard let source = AppState.shared.liveSources.first?.config else { return nil }
        return Place(sourceId: source.id, cwd: source.kind == .local ? NSHomeDirectory() : "~", agent: "claude-code")
    }

    /// 「shop-app · 本机 · Claude Code」
    @MainActor
    static func label(_ place: Place) -> String {
        let source = KitelineModel.shared.sources.first { $0.id == place.sourceId }?.name ?? place.sourceId
        return [(place.cwd as NSString).lastPathComponent, source, Agents.info(place.agent).name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 装到分屏上（启动时一次）
    @MainActor
    static func install() {
        KitelineKit.newSessionDraft = { previous in context(previous: previous).map(make) }
        KitelineKit.newSessionDraftLabel = { key in parse(key).map(label) ?? L("新会话") }
        KitelineKit.newSessionDraftView = { key in AnyView(NewSessionDraftView(key: key)) }
    }
}

/// 自测用（SelfTest 的 draftfill / draftattach / draftopt / draftsend 步骤）：把文字、图片、发送送进草稿输入框，走的还是真的输入框和发送逻辑
extension Notification.Name {
    static let draftTestFill = Notification.Name("kiteline.draftTestFill")
}

/// 草稿标签里改过的项目 / 设备 / agent（key 里的是开的时候带的；改了记在这里，标签切走再回来还在）
@MainActor
final class NewDrafts: ObservableObject {
    static let shared = NewDrafts()
    static var places: [String: NewDraftKey.Place] = [:]
    /// 发送中 / 等会话开出来 / 出错提示：记在这里而不是视图的 @State。发送期间切到别的项目再切回来，标签视图会重建，
    /// 状态留在视图里就丢了（回来是个空草稿、发出去的会话没接到这个标签上，11-23 反馈）；等会话出现的任务也不跟视图走
    @Published var sending: Set<String> = []
    @Published var waiting: Set<String> = []
    @Published var messages: [String: String] = [:]

    /// 等新会话出现（最多 3 分钟，远端开 VS Code 要一阵），出现了就把这个草稿标签换成它。不依赖标签视图还在不在
    @MainActor
    static func adopt(key: String, place: NewDraftKey.Place, before: Set<String>, preId: String?, followUp: String?, draft: DraftLaunch) {
        let model = KitelineModel.shared
        let drafts = NewDrafts.shared
        let expected = preId.map { place.sourceId + "#" + $0 }
        Task { @MainActor in
            for _ in 0..<360 {
                let fresh = expected.flatMap { id in model.sessions.first { $0.id == id } }
                    ?? model.sessions.first(where: { $0.sourceId == place.sourceId && $0.cwd == place.cwd && !before.contains($0.id) })
                if let fresh {
                    NewDrafts.places[key] = nil
                    // 发送期间切到了别的项目：草稿标签在存起来的那套里，会话接到那里去。绝不能显示到现在这个项目的标签下（11-23）；
                    // 找不到草稿标签（用户自己关了）就不显示，会话在项目里、会话列表里都有
                    KitelineKit.projectSpaces.replaceTab(key, with: fresh.id)
                    drafts.waiting.remove(key)
                    if KitelineKit.panes.focused == fresh.id { model.selection = fresh.id }
                    let carried = fresh.id == expected
                    KitelineKit.afterDraftStart(key: fresh.id, carried: carried, mode: draft.mode, modelId: draft.model,
                                            effort: draft.effort, followUp: followUp)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            drafts.waiting.remove(key)
            drafts.messages[key] = L("消息已发出，但新会话还没有出现在列表中。可以在左侧会话列表中查看，或稍后再试。")
        }
    }
}

struct NewSessionDraftView: View {
    let key: String
    @ObservedObject private var model = KitelineModel.shared
    @ObservedObject private var projects = ProjectsModel.shared
    @State private var place: NewDraftKey.Place?
    /// 整页多高（终端面板最高占到它的八成五，同会话页）
    @State private var height: CGFloat = 600
    @ObservedObject private var drafts = NewDrafts.shared
    private var sending: Bool {
        get { drafts.sending.contains(key) }
        nonmutating set { if newValue { drafts.sending.insert(key) } else { drafts.sending.remove(key) } }
    }
    private var waiting: Bool { drafts.waiting.contains(key) }
    private var message: String? {
        get { drafts.messages[key] }
        nonmutating set { drafts.messages[key] = newValue }
    }
    /// 每台电脑上除了 Claude Code 还能后台运行哪几家（问过的记着）
    @State private var launchable: [String: [NewTaskSheet.LaunchAgent]] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 14) {
                Image(systemName: "plus.bubble").font(.system(size: 34, weight: .light)).foregroundStyle(Color.tarsBrand)
                Text("新会话").font(.app(size: 20, weight: .semibold))
                Text(waiting ? L("已发送，正在等会话开出来…") : L("发送第一条消息即开始新的会话，开出来后就显示在这个标签页里。"))
                    .font(.app(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let place { pickers(place).disabled(sending || waiting) }
                if let message {
                    Text(message).font(.app(size: 12)).foregroundStyle(.red).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            Spacer(minLength: 20)
            // 输入区和会话页的是同一套（边距、宽度都一样），从新会话标签换成会话时输入框不跳
            if let place { composer(place, available: height) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { proxy in Color.clear.onAppear { height = proxy.size.height }.onChange(of: proxy.size.height) { _, value in height = value } })
        .background(Look.shared.scheme?.editorColor ?? Color(nsColor: .windowBackgroundColor))
        .task(id: key) {
            place = NewDrafts.places[key] ?? NewDraftKey.parse(key)
            if !projects.loaded { projects.load() }
            askAgents()
        }
        .onChange(of: place) { _, value in
            if let value { NewDrafts.places[key] = value }
            askAgents()
        }
        .onReceive(NotificationCenter.default.publisher(for: .draftTestFill)) { note in
            let info = note.userInfo ?? [:]
            if let typed = info["text"] as? String { KitelineKit.testDraft(key, text: typed) }
            if let path = info["image"] as? String, let data = FileManager.default.contents(atPath: path) { KitelineKit.testDraft(key, image: data) }
            if let option = info["option"] as? String {
                if option == "terminal", let place { KitelineKit.testDraftTerminal(place.sourceId + "#" + futureSessionId) } else { KitelineKit.testDraft(key, option: option) }
            }
            if info["send"] as? Bool == true, let launch = KitelineKit.testDraftLaunch(key) { send(launch) }
        }
    }

    // MARK: 项目、设备、Agent

    /// 项目、设备、Agent 三个下拉：放得下排一行；会话区窄了竖着排；再窄（单个都放不下）就把名字截短。
    /// 不能一律 fixedSize 排一行：三个加起来四百来点宽，窄的分屏里会把整页撑宽，连输入框一起被裁掉（11-22）
    private func pickers(_ place: NewDraftKey.Place) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { pickerMenus(place, fixed: true) }
            VStack(spacing: 6) { pickerMenus(place, fixed: true) }
            VStack(spacing: 6) { pickerMenus(place, fixed: false) }
        }
    }

    @ViewBuilder
    private func pickerMenus(_ place: NewDraftKey.Place, fixed: Bool) -> some View {
        let groups = projects.groupedShown
        let current = projects.groups.first { group in group.contains { $0.sourceId == place.sourceId && $0.cwd == place.cwd } }
        let devices = current ?? []
        let sourceName = model.sources.first { $0.id == place.sourceId }?.name ?? place.sourceId
        Menu {
            ForEach(groups, id: \.first!.id) { group in
                Button(group[0].name + (group.count > 1 ? "（" + group.map(\.sourceName).joined(separator: " · ") + "）" : "")) {
                    // 换项目：设备尽量不变（这个项目在现在这台设备上也有就用它）
                    let pick = group.first { $0.sourceId == place.sourceId } ?? group[0]
                    self.place = .init(sourceId: pick.sourceId, cwd: pick.cwd, agent: place.agent)
                }
            }
        } label: { chip("folder", (place.cwd as NSString).lastPathComponent) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: fixed, vertical: true)
        .help(place.cwd)
        Menu {
            if devices.count > 1 {
                ForEach(devices) { member in
                    Button(member.sourceName) { self.place = .init(sourceId: member.sourceId, cwd: member.cwd, agent: place.agent) }
                }
            } else {
                Text("这个项目只在「\(sourceName)」上")
            }
        } label: { chip("desktopcomputer", sourceName) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: fixed, vertical: true)
        Menu {
            ForEach(agents(place.sourceId)) { agent in
                Button(agent.name) { self.place = .init(sourceId: place.sourceId, cwd: place.cwd, agent: agent.id) }
            }
        } label: {
            HStack(spacing: 5) {
                AgentGlyph(place.agent, size: 12)
                Text(Agents.info(place.agent).name).lineLimit(1)
                Image(systemName: "chevron.down").font(.app(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .modifier(ChipStyle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: fixed, vertical: true)
    }

    private func chip(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.app(size: 11, weight: .medium))
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.app(size: 8, weight: .bold)).foregroundStyle(.tertiary)
        }
        .modifier(ChipStyle())
    }

    private struct ChipStyle: ViewModifier {
        func body(content: Content) -> some View {
            content.kiteLook()
        }
    }

    private func agents(_ sourceId: String) -> [NewTaskSheet.LaunchAgent] {
        [NewTaskSheet.LaunchAgent(id: "claude-code", name: Agents.info("claude-code").name, viaUI: false)] + (launchable[sourceId] ?? [])
    }

    private func askAgents() {
        guard let id = place?.sourceId, launchable[id] == nil else { return }
        Hosted.launchable(sourceId: id) { rows in
            let found = rows.compactMap { row -> NewTaskSheet.LaunchAgent? in
                guard let agent = row["id"] as? String, !agent.isEmpty, agent != "claude-code", row["via"] as? String != "ui" else { return nil }
                return NewTaskSheet.LaunchAgent(id: agent, name: row["name"] as? String ?? agent, viaUI: false)
            }
            DispatchQueue.main.async { launchable[id] = found }
        }
    }

    // MARK: 输入框

    /// 新会话开出来以后的编号：按草稿标签的 key 算出来（重开 App 也是同一个），后台运行 Claude Code 时用它开（watcher 的 newSessionId），
    /// 草稿里开的终端记在它名下，会话开出来后终端还在
    private var futureSessionId: String {
        let digest = Array(SHA256.hash(data: Data(key.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40   // 版本 4
        bytes[8] = (bytes[8] & 0x3f) | 0x80   // RFC 4122
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    /// 能不能预先定编号、带着设置起：Claude Code、这台电脑开着后台运行、电脑上的组件认 hosted_opts（在 VS Code 里开的带不了，会话出来后再切）
    private func preassigned(_ place: NewDraftKey.Place) -> Bool {
        guard place.agent == Agents.defaultID, let source = AppState.shared.config.sources.first(where: { $0.id == place.sourceId }),
              Hosted.wanted(source), let connection = AppState.shared.source(withId: place.sourceId) else { return false }
        return connection.hostFeatures.contains("hosted_opts")
    }

    /// 输入区和普通会话页一样（KitelineKit.DraftComposer，同 MacComposer）：⌘V 粘贴截图、回车发送，下面一排权限模式、模型和思考等级、目标、终端
    private func composer(_ place: NewDraftKey.Place, available: CGFloat) -> some View {
        KitelineKit.DraftComposer(draftKey: key, futureKey: place.sourceId + "#" + futureSessionId, sourceId: place.sourceId, cwd: place.cwd,
                              agent: place.agent,
                              placeholder: L("请描述需要 %@ 在「%@」中完成的任务", Agents.info(place.agent).name, (place.cwd as NSString).lastPathComponent),
                              busy: sending || waiting, terminal: preassigned(place), available: available, onSend: send)
    }

    /// 在选的电脑、目录用选的 agent 开会话，第一句话就是输入的（有图先传到那台电脑，路径拼进消息，同新建任务）；
    /// 设了目标的第一句是「/goal 目标」，输入框里的话等会话出来再发。开出来以后把这个标签换成那个会话
    private func send(_ draft: DraftLaunch) {
        guard let place, !sending, !waiting else { return }
        guard let source = AppState.shared.config.sources.first(where: { $0.id == place.sourceId }) else {
            message = L("这台电脑现在没有连上")
            return
        }
        sending = true
        message = nil
        let attachments = draft.images.map { Delivery.Attachment(name: $0.name, data: $0.data) }
        Delivery.stage(attachments, via: AppState.shared.source(withId: place.sourceId)) { staged in
            switch staged {
            case .success(let paths):
                let body = Delivery.compose(text: draft.text, paths: paths)
                if let goal = draft.goal {
                    launch(place: place, source: source, prompt: "/goal " + goal, followUp: body, draft: draft)
                } else {
                    launch(place: place, source: source, prompt: body, followUp: nil, draft: draft)
                }
            case .failure(let error):
                sending = false
                message = L("图片传送失败：%@", "\(error.description)")
            }
        }
    }

    private func launch(place: NewDraftKey.Place, source: SourceConfig, prompt: String, followUp: String?, draft: DraftLaunch) {
        // 先记下这个目录里已经有的会话：新出现的那个就是这次开的
        let before = Set(model.sessions.filter { $0.sourceId == place.sourceId && $0.cwd == place.cwd }.map(\.id))
        let preId = preassigned(place) ? futureSessionId : nil
        let finish: (NewSession.Outcome) -> Void = { outcome in
            sending = false
            guard outcome.ok else { message = outcome.message; return }
            KitelineKit.clearDraft(key)
            NewDrafts.shared.waiting.insert(key)
            NewDrafts.adopt(key: key, place: place, before: before, preId: preId, followUp: followUp, draft: draft)
        }
        if place.agent == Agents.defaultID {
            var options: [String: String] = [:]
            if let mode = draft.mode { options["mode"] = mode }
            if let model = draft.model { options["model"] = model }
            if let effort = draft.effort { options["effort"] = effort }
            NewSession.start(source: source, cwd: place.cwd, prompt: prompt, submit: true, launch: options, newSessionId: preId, completion: finish)
        } else {
            MobileServer.startAgent(source, cwd: place.cwd, prompt: prompt, submit: true, sessionId: nil, agent: place.agent, accepted: { _ in }) { outcome in
                DispatchQueue.main.async { finish(outcome) }
            }
        }
    }
}
