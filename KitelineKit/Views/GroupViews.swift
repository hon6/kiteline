import SwiftUI
import UniformTypeIdentifiers

// 会话群的界面（手机、iPad、Mac 主窗口同一套；数据见 Model/Groups.swift）：
// 列表里的群行和群头像、群聊页（成员、往来消息、在群里发话）、拉群 / 加成员的面板、全部群（进行中 + 历史群）、
// 把一个会话拖到另一个会话上拉群（groupDrop）

// MARK: - 头像

/// 成员的小头像：会话换过头像就画它，没换是标题首字（同会话列表）
struct GroupMemberFace: View {
    @Environment(AppModel.self) private var model
    let member: GroupMember
    var size: CGFloat = 36

    var body: some View {
        if let face = model.faces.sessions[member.key], !face.avatar.isEmpty {
            AgentFaceView(agent: member.agent ?? Agents.defaultID, face: face, size: size, corner: 0.23)
        } else {
            Avatar(text: Format.initials(model.title(of: member)), size: size)
        }
    }
}

/// 群头像（同微信）：成员头像拼在一个圆角方块里，两个并排、三个上一下二、四个以上田字格
struct GroupAvatar: View {
    let members: [GroupMember]
    var size: CGFloat = 48
    /// 历史群：淡一点
    var dim = false

    var body: some View {
        let shown = Array(members.prefix(4))
        let gap = max(1.5, size * 0.04)
        let cell = (size - gap * 3) / 2
        ZStack {
            Theme.tile
            VStack(spacing: gap) {
                if shown.count >= 3 {
                    row(Array(shown.prefix(shown.count == 3 ? 1 : 2)), cell: cell, gap: gap)
                    row(Array(shown.suffix(2)), cell: cell, gap: gap)
                } else {
                    row(shown, cell: cell, gap: gap)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .opacity(dim ? 0.55 : 1)
    }

    private func row(_ list: [GroupMember], cell: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(list) { GroupMemberFace(member: $0, size: cell) }
        }
    }
}

// MARK: - 列表里的一行

/// 会话列表、全部群里的一行（同会话行的样子）：群头像，群名（人数）+ 时间，下面是最后一条群消息；历史群标「历史」
struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: GroupInfo
    var compact = false

    var body: some View {
        let live = model.isLive(group)
        HStack(spacing: compact ? 10 : 12) {
            GroupAvatar(members: group.members, size: compact ? 32 : 48, dim: !live)
            VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "person.2.fill").font(.app(size: compact ? 10 : 12)).foregroundStyle(.secondary)
                    Text(group.name).font(.app(size: compact ? 13 : 17)).lineLimit(1)
                    Text("(\(group.members.count))").font(.app(size: compact ? 11.5 : 14)).foregroundStyle(.secondary).fixedSize()
                    if group.marked { MarkStar() }
                    Spacer(minLength: 4)
                    Text(Format.listTime(group.updatedAt)).font(.app(size: compact ? 10.5 : 12)).foregroundStyle(.tertiary).fixedSize()
                }
                HStack(spacing: 6) {
                    preview(live).font(.app(size: compact ? 11.5 : 14)).lineLimit(1)
                    Spacer(minLength: 0)
                    if group.muted {
                        Image(systemName: "bell.slash").font(.app(size: compact ? 10.5 : 12)).foregroundStyle(.tertiary)
                    }
                    if !live {
                        Text("历史").font(.ui(.caption2)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
        .padding(.vertical, compact ? 5 : 10)
    }

    private func preview(_ live: Bool) -> Text {
        if group.paused {
            return Text("\(Text("[已暂停转发]").foregroundStyle(.orange)) \(Text("轻点查看").foregroundStyle(.secondary))")
        }
        guard let last = group.last, !last.system else {
            let names = group.members.map { model.title(of: $0) }.joined(separator: L("、"))
            return Text(names).foregroundStyle(.secondary)
        }
        let who = last.mine ? L("我") : (group.member(last.from).map { model.title(of: $0) } ?? last.fromTitle)
        let text = last.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return Text("\(who)：\(text)").foregroundStyle(.secondary)
    }
}

// MARK: - 群聊页

struct GroupChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    /// 开在分屏里（同会话一样是一个标签）：群名、成员按钮、菜单在标签栏 / 标题条上（GroupPaneButtons），不往导航栏放
    @Environment(\.chatPane) private var pane
    let id: String
    /// 只发给这几个成员（空 = 全部）
    @State private var recipients: Set<String> = []
    @State private var showAdd = false
    @State private var showRename = false
    @State private var confirmDelete = false
    @State private var removing: GroupMember?
    /// 别的会话正拖在群聊页上（松开 = 进群）
    @State private var dropping = false
    /// 截图、自测用：打开群聊页时直接展开成员面板（iPhone 截图版 TARS_DEMO_GROUP_MEMBERS=1，Mac 自测步骤 group:members）
    nonisolated(unsafe) static var startWithMembers = ProcessInfo.processInfo.environment["TARS_DEMO_GROUP_MEMBERS"] == "1"
    #if os(iOS)
    /// 按住说话（同会话的输入栏）：录音层盖住整页，松开转成文字发到群里
    @State private var voice = VoiceSession()
    @State private var homeBottom: CGFloat = 0
    #endif
    @State private var chatWidth: CGFloat = 0

    /// 右边滑出的成员面板（同 QQ 群）：记在 model 上，标签栏上的成员按钮跟着变实心
    private var showMembers: Bool {
        get { model.groupDrawers.contains(id) }
        nonmutating set { if newValue { model.groupDrawers.insert(id) } else { model.groupDrawers.remove(id) } }
    }

    /// 往导航栏上放群名、成员按钮、菜单：单独推进来的页面；iPad 分屏里只有当前块放。Mac 分屏里这些都在标签栏上
    private var ownsBar: Bool {
        #if KITELINE_MAC
        pane == nil
        #else
        pane?.ownsBar ?? true
        #endif
    }

    var body: some View {
        if let group = model.groups.group(id) {
            page(group)
        } else {
            ContentUnavailableView(L("群已解散"), systemImage: "person.2.slash")
        }
    }

    private func page(_ group: GroupInfo) -> some View {
        let live = model.isLive(group)
        let messages = model.groups.messages[id] ?? []
        return ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let topic = group.topic, !topic.isEmpty, messages.isEmpty {
                            Text(topic).font(.ui(.footnote)).foregroundStyle(.secondary)
                        }
                        ForEach(messages) { message in
                            GroupMessageRow(group: group, message: message).id(message.id)
                        }
                        ForEach(Array((model.groups.sending[id] ?? []).enumerated()), id: \.offset) { _, text in
                            GroupBubbleMine(text: text, footnote: L("发送中…"), failed: false)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    // 正文字号、行高同会话的对话页（见 ChatType）：不套的话气泡里落回系统默认字，和会话里看着不一样
                    .font(ChatType.body)
                    .lineSpacing(ChatType.lineSpacing)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.groups.sending[id]?.count ?? 0) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                // 输入区同会话的对话页：贴在底部，消息滚到它下面
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        notice(group, live: live)
                        composer
                    }
                    .environment(\.chatWidth, chatWidth)
                }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chatWidth = $0 }
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { homeBottom = $0 }
        .environment(\.homeBottom, homeBottom)
        .overlay { if voice.active { VoiceOverlay(voice: voice) } }
        #endif
        #if KITELINE_MAC
        // 把图拖进群聊页：加进要发的图（同会话的对话页）
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            let chat = model.chat(GroupKey.make(id))
            Task { @MainActor in MacComposer.attach(await DroppedImages.load(providers), to: chat) }
            return true
        }
        #endif
        .background(Theme.chatBackground)
        // 成员：右边滑出来的面板（同 QQ 群），盖在对话上
        .overlay { drawer(group) }
        // 把别的会话拖进群聊页：松开直接进群（开在分屏里时由分屏接：拖到中间进群、拖到四边分屏，见 PaneView）
        .overlay { if dropping { dropHint(group) } }
        .modifier(GroupJoinDrop(enabled: pane == nil, dropping: $dropping) { join($0) })
        .navigationTitle(ownsBar ? group.name : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if ownsBar {
                ToolbarItem(placement: .primaryAction) {
                    // 群成员：人形图标 + 人数，点开右边滑出成员面板
                    Button { withAnimation(.snappy(duration: 0.28)) { showMembers.toggle() } } label: {
                        HStack(spacing: 3) {
                            Image(systemName: showMembers ? "person.2.fill" : "person.2")
                            Text("\(group.members.count)").font(.ui(.subheadline).monospacedDigit())
                        }
                    }
                    .accessibilityLabel(L("群成员"))
                }
                ToolbarItem(placement: .primaryAction) { menu(group) }
            }
        }
        // 标签栏、标题条上点的成员、添加成员、改群名、解散：在这里弹
        .onChange(of: model.groupAction?.token) { _, _ in
            guard let request = model.groupAction, request.id == id else { return }
            model.groupAction = nil
            switch request.action {
            case .members: withAnimation(.snappy(duration: 0.28)) { showMembers.toggle() }
            case .add: showAdd = true
            case .rename: showRename = true
            case .disband: confirmDelete = true
            }
        }
        .task(id: id) { await model.groups.loadMessages(id, api: model.api) }
        .onAppear {
            model.viewingGroup = id
            if Self.startWithMembers { showMembers = true }
        }
        .onDisappear { if model.viewingGroup == id { model.viewingGroup = nil } }
        .sheetPanel(isPresented: $showAdd) { GroupPickerSheet(mode: .add(id)) { _ in }.environment(model) }
        .sheetPanel(isPresented: $showRename) { GroupRenameSheet(id: id, name: group.name).environment(model) }
        .confirmPanel(GroupDisband.message, isPresented: $confirmDelete, confirm: L("解散群"), destructive: true) {
            Task { await model.deleteGroup(id) }
        }
        .confirmPanel(L("将「%@」移出群？之后它收不到群消息。", removing.map { model.title(of: $0) } ?? ""),
                      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), confirm: L("移出"), destructive: true) {
            if let key = removing?.key { Task { await model.removeFromGroup(id, key: key) } }
        }
    }

    private func menu(_ group: GroupInfo) -> some View {
        Menu {
            Button { showAdd = true } label: { Label(L("添加成员"), systemImage: "person.badge.plus") }
            Button { showRename = true } label: { Label(L("修改群名"), systemImage: "pencil") }
            Button { model.markGroup(id, !group.marked) } label: {
                Label(group.marked ? L("取消标记") : L("标记"), systemImage: group.marked ? "star.slash" : "star")
            }
            Button { model.muteGroup(id, !group.muted) } label: {
                Label(group.muted ? L("取消免打扰") : L("免打扰"), systemImage: group.muted ? "bell" : "bell.slash")
            }
            if group.paused {
                Button { Task { await model.pauseGroup(id, false) } } label: { Label(L("继续转发"), systemImage: "play") }
            } else {
                Button { Task { await model.pauseGroup(id, true) } } label: { Label(L("暂停转发"), systemImage: "pause") }
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label(L("解散群"), systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L("群设置"))
    }

    /// 拖进来的会话进群（已经在群里的不重复加；拖来的是群不算）
    private func join(_ key: String) {
        guard GroupKey.id(key) == nil else { return }
        guard let group = model.groups.group(id), group.member(key) == nil else {
            model.flash(L("已在群里")); return
        }
        Task {
            if await model.addToGroup(id, keys: [key]) { model.flash(L("已加入群：%@", model.session(key)?.title ?? key)) }
        }
    }

    /// 拖着会话停在群聊页上：整页一层淡色、中间「松开加入群「名」」
    private func dropHint(_ group: GroupInfo) -> some View {
        ZStack {
            Theme.claude.opacity(0.08)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.claude, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .padding(10)
            Label(L("松开加入群「%@」", group.name), systemImage: "person.2.fill")
                .font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.claude, in: Capsule())
        }
        .allowsHitTesting(false)
    }

    /// 成员面板（同 QQ 群）：从群聊页右边滑出的一张液态玻璃卡片，只占群聊这一块（不盖标题栏、不贴满整个窗口）。
    /// 成员一行一个（头像、标题、在跑没有、哪台电脑哪个项目），轻点打开那个会话，右键 / 长按移出；顶上「+」加别的会话。点卡片外面收起
    @ViewBuilder
    private func drawer(_ group: GroupInfo) -> some View {
        if showMembers {
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy(duration: 0.28)) { showMembers = false } }
                        .transition(.opacity)
                    members(group)
                        .frame(width: min(300, geometry.size.width * 0.82))
                        .frame(maxHeight: .infinity)
                        .drawerGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.16), radius: 18, y: 4)
                        .padding(.vertical, 8).padding(.trailing, 8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private func members(_ group: GroupInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("群成员").font(.ui(.headline))
                Text("\(group.members.count)").font(.ui(.subheadline).monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button { withAnimation(.snappy(duration: 0.28)) { showMembers = false } } label: {
                    Image(systemName: "xmark").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("收起"))
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Button { showAdd = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.ui(.body).weight(.medium)).foregroundStyle(Theme.claude)
                                .frame(width: 36, height: 36)
                                .background(Theme.iconTile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text("添加成员").font(.ui(.subheadline))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    ForEach(group.members) { member in memberRow(member) }
                    #if os(macOS)
                    Text("把左边的会话拖到群聊里即可加入。").font(.ui(.caption)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 10)
                    #endif
                }
                .padding(.horizontal, 6).padding(.bottom, 16)
            }
        }
    }

    private func memberRow(_ member: GroupMember) -> some View {
        let session = model.session(member.key)
        let status = session == nil ? L("已结束") : (session!.isBusy ? L("工作中") : (session!.isWaiting ? L("待确认") : L("空闲")))
        let dot = session == nil ? Color.secondary.opacity(0.5) : (session!.isBusy ? Theme.claude : (session!.isWaiting ? Color.orange : Theme.added))
        return Button { open(.chat(member.key)) } label: {
            HStack(spacing: 10) {
                GroupMemberFace(member: member, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title(of: member)).font(.ui(.subheadline).weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(dot).frame(width: 6, height: 6)
                        Text(member.place.isEmpty ? status : "\(status) · \(member.place)").lineLimit(1)
                    }
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu {
            Button { open(.chat(member.key)) } label: { Label(L("打开会话"), systemImage: "bubble.left") }
            Button(role: .destructive) { removing = member } label: { Label(L("移出群"), systemImage: "person.badge.minus") }
        }
    }

    /// 输入框上方的说明：转发暂停了（点继续）；成员都关了（发话会恢复它们）
    @ViewBuilder
    private func notice(_ group: GroupInfo, live: Bool) -> some View {
        if group.paused {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                Text("agent 之间往来较多，已暂停转发。").font(.ui(.footnote))
                Spacer(minLength: 4)
                Button(L("继续转发")) { Task { await model.pauseGroup(id, false) } }.font(.ui(.footnote).weight(.semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.orange.opacity(0.12))
        } else if !live {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text("成员会话都已关闭。发消息后会在原来的项目里恢复它们，接着协作。").font(.ui(.footnote)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.primary.opacity(0.04))
        }
    }

    /// 输入栏：就是会话的输入栏（发图、粘贴截图、常用语、按住说话都一样），发到群里；下面那排是「发给全部成员 ⌄」
    @ViewBuilder
    private var composer: some View {
        let target = ComposeGroup(id: id, recipients: $recipients)
        #if os(iOS)
        if voice.converting { ConvertingHint() }
        Composer(key: target.key, session: nil, chat: model.chat(target.key), voice: voice, group: target)
        #elseif KITELINE_MAC
        MacComposer(key: target.key, session: nil, chat: model.chat(target.key), group: target)
            .padding(.top, 8)
            .background(Theme.chatBackground)
        #endif
    }
}

/// 群里的一条：系统提示居中小字；我说的在右边；agent 说的在左边（头像、名字、在哪台电脑哪个项目），下面一行写投递到了没有
struct GroupMessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let group: GroupInfo
    let message: GroupMessage

    var body: some View {
        if message.system {
            Text(message.eventText).font(.ui(.caption)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
                .frame(maxWidth: .infinity)
        } else if message.mine {
            GroupBubbleMine(text: message.text, footnote: delivery, failed: failed, time: message.ts, group: group.id,
                            images: message.images, files: message.files)
        } else {
            agent
        }
    }

    private var agent: some View {
        let member = group.member(message.from)
        return HStack(alignment: .top, spacing: 8) {
            Button { open(.chat(message.from)) } label: {
                if let member { GroupMemberFace(member: member, size: 36) } else { Avatar(text: Format.initials(message.fromTitle), size: 36) }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(member.map { model.title(of: $0) } ?? message.fromTitle).font(.ui(.caption).weight(.semibold)).lineLimit(1)
                    if let place = member?.place, !place.isEmpty { Text(place).font(.ui(.caption2)).foregroundStyle(.tertiary).lineLimit(1) }
                    if let to = message.to, !to.isEmpty {
                        Text(L("→ %@", to.compactMap { group.member($0).map { model.title(of: $0) } }.joined(separator: L("、"))))
                            .font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(Format.listTime(message.ts)).font(.ui(.caption2)).foregroundStyle(.tertiary).fixedSize()
                }
                // 同会话里 agent 的气泡（内边距、圆角、菜单都一样）
                Bubble(mine: false, text: message.text, actions: [
                    MenuAction(title: L("打开这个会话"), symbol: "bubble.left") { open(.chat(message.from)) },
                ]) {
                    MarkdownView(message.text, fill: false)
                }
                if !delivery.isEmpty {
                    Text(delivery).font(.ui(.caption2)).foregroundStyle(failed ? Theme.removed : Color.secondary)
                }
            }
            Spacer(minLength: 40)
        }
    }

    private var failed: Bool { message.states.values.contains("failed") }

    /// 「已送达 A、B」「A 已关闭，恢复时补上」「未送达 A：原因」……
    private var delivery: String {
        let name: (String) -> String = { key in group.member(key).map { model.title(of: $0) } ?? L("会话") }
        var parts: [String] = []
        let by = Dictionary(grouping: message.states.keys.sorted(), by: { message.states[$0] ?? "" })
        if let keys = by["sent"], !keys.isEmpty { parts.append(L("已送达 %@", keys.map(name).joined(separator: L("、")))) }
        if let keys = by["filled"], !keys.isEmpty { parts.append(L("已填入 %@ 的输入框，未提交", keys.map(name).joined(separator: L("、")))) }
        if let keys = by["pending"], !keys.isEmpty {
            let resuming = keys.filter { message.notes[$0] != nil }
            // 在等你确认的会话：确认完才投（回车会替你点允许）
            let held = keys.filter { message.notes[$0] == nil && model.session($0)?.isWaiting == true }
            let waiting = keys.filter { message.notes[$0] == nil && model.session($0)?.isWaiting != true }
            if !waiting.isEmpty { parts.append(L("正在送达 %@", waiting.map(name).joined(separator: L("、")))) }
            if !held.isEmpty { parts.append(L("%@ 确认后送达", held.map(name).joined(separator: L("、")))) }
            if !resuming.isEmpty { parts.append(L("正在恢复 %@", resuming.map(name).joined(separator: L("、")))) }
        }
        if let keys = by["paused"], !keys.isEmpty { parts.append(L("暂停转发，未送达 %@", keys.map(name).joined(separator: L("、")))) }
        if let keys = by["ended"], !keys.isEmpty {
            let notes = keys.compactMap { message.notes[$0] }
            parts.append(L("%@ 已关闭，恢复时补上", keys.map(name).joined(separator: L("、"))) + (notes.first.map { L("（%@）", L($0)) } ?? ""))
        }
        if let keys = by["failed"], !keys.isEmpty {
            parts.append(L("未送达 %@", keys.map(name).joined(separator: L("、"))) + (keys.compactMap { message.notes[$0] }.first.map { L("：%@", L($0)) } ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}

/// 我在群里说的（右边的绿气泡；带的图在气泡上面、文件一个一张卡片，同会话里我发的），下面一行投递情况
struct GroupBubbleMine: View {
    @Environment(AppModel.self) private var model
    let text: String
    var footnote: String
    var failed: Bool
    var time: Double? = nil
    var group: String? = nil
    var images: [GroupMedia] = []
    var files: [GroupMedia] = []

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if let time { Text(Format.listTime(time)).font(.ui(.caption2)).foregroundStyle(.tertiary) }
                if let group, !images.isEmpty {
                    MessageImages(key: GroupKey.make(group), images: images.map { ChatImage(ref: $0.ref, mime: nil, name: $0.name) },
                                  path: "/api/groups/media")
                }
                if let group {
                    ForEach(files, id: \.ref) { file in
                        FileChip(name: file.name, size: file.size, mine: true)
                            .foregroundStyle(Theme.meText)
                            .padding(.horizontal, ChatType.padH).padding(.vertical, ChatType.padV)
                            .background(Theme.meBubble, in: RoundedRectangle(cornerRadius: ChatType.radius, style: .continuous))
                            .onTapGesture { guard TouchTravel.isTap else { return }; FileOpener.shared.openGroupFile(model, group: group, file: file) }
                            .accessibilityAddTraits(.isButton)
                    }
                }
                if !text.isEmpty {
                    Bubble(mine: true, text: text) { Text(text).fixedSize(horizontal: false, vertical: true) }
                }
                if !footnote.isEmpty {
                    Text(footnote).font(.ui(.caption2)).foregroundStyle(failed ? Theme.removed : Color.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

extension View {
    /// 成员面板的底：iOS 26 / macOS 26 起是液态玻璃，更早的系统用磨砂材质 + 细边
    @ViewBuilder
    fileprivate func drawerGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.6))
        }
    }
}

// MARK: - 改群名

struct GroupRenameSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let id: String
    @State var name: String

    var body: some View {
        FitSheet(title: L("修改群名"), cancel: true) {
            VStack(alignment: .leading, spacing: 12) {
                TextField(L("群名"), text: $name)
                    .textFieldStyle(.plain).font(.ui(.body))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onSubmit(save)
                Text("改过之后，agent 不会再自动起名。").font(.ui(.caption)).foregroundStyle(.secondary)
                Button(action: save) {
                    Text("保存").font(.ui(.body).weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Theme.wechatGreen.opacity(blank ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(blank)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var blank: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func save() {
        guard !blank else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await model.renameGroup(id, value)
            dismiss()
        }
    }
}

// MARK: - 拉群 / 加成员

struct GroupPickerSheet: View {
    enum Mode: Hashable {
        /// 新建：先勾上的会话（拖到一起的两个、右键点的那个）
        case create([String])
        /// 往这个群里加
        case add(String)
    }

    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let mode: Mode
    /// 建好 / 加进了哪个群（交给弹出它的地方打开群聊页）
    let done: (String) -> Void
    @State private var picked: Set<String> = []
    @State private var topic = ""
    @State private var busy = false
    /// 只列某台设备 / 某个项目的会话（空 = 全部；同会话列表的筛选）。筛掉的已勾选的照样算在里面
    @State private var sourceFilter = ""
    @State private var projectFilter = ""

    init(mode: Mode, done: @escaping (String) -> Void) {
        self.mode = mode
        self.done = done
        if case .create(let keys) = mode { _picked = State(initialValue: Set(keys)) }
    }

    private var groupId: String? { if case .add(let id) = mode { id } else { nil } }
    private var existing: Set<String> { Set(groupId.flatMap { model.groups.group($0) }?.members.map(\.key) ?? []) }

    var body: some View {
        FitSheet(title: groupId == nil ? L("拉群协作") : L("添加成员"), cancel: true) {
            VStack(alignment: .leading, spacing: 14) {
                if groupId == nil {
                    Text("把几个会话拉进一个群，它们可以在不同设备、不同项目里互相发消息协作；你在群里能看到全部往来，也能直接发话。")
                        .font(.ui(.footnote)).foregroundStyle(.secondary)
                    joinable
                }
                filters
                sessions
                if groupId == nil { topicEditor }
            }
        } bottom: {
            // 浮在面板底部：会话再多、往下滚，建群按钮一直在
            Button(action: commit) {
                Text(buttonTitle).font(.ui(.body).weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Theme.wechatGreen.opacity(ready && !busy ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .disabled(!ready || busy)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// 能选的会话（筛选前）
    private var candidates: [SessionInfo] { model.sessions }

    private static func project(_ session: SessionInfo) -> String { session.cwd.map { ($0 as NSString).lastPathComponent } ?? "" }

    /// 筛着的设备、项目（列表里已经没有它就当没筛）
    private var activeSource: String? {
        sourceFilter.isEmpty || !candidates.contains(where: { $0.sourceId == sourceFilter }) ? nil : sourceFilter
    }
    private var activeProject: String? {
        projectFilter.isEmpty || !candidates.contains(where: { Self.project($0) == projectFilter }) ? nil : projectFilter
    }

    /// 项目那排：按列表里的先后（筛着设备时只列这台设备上的）
    private func projectNames(_ source: String?) -> [String] {
        var names: [String] = []
        for session in candidates where source == nil || session.sourceId == source {
            let name = Self.project(session)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// 设备、项目两排胶囊（同会话列表）：不止一台设备 / 不止一个项目时才有；个数跟着另一排的筛选走
    @ViewBuilder
    private var filters: some View {
        let source = activeSource, project = activeProject
        let machines = candidates.reduce(into: [(id: String, name: String)]()) { list, s in
            if !list.contains(where: { $0.id == s.sourceId }) { list.append((s.sourceId, s.sourceName)) }
        }
        let projects = projectNames(source)
        if machines.count > 1 || projects.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                if machines.count > 1 {
                    ScopeBar(symbol: "desktopcomputer", allTitle: L("全部设备"),
                             options: machines.map { m in
                                 ScopeBar.Option(id: m.id, title: m.name.isEmpty ? L("未知设备") : m.name,
                                                 count: candidates.filter { $0.sourceId == m.id && (project == nil || Self.project($0) == project) }.count)
                             },
                             selection: $sourceFilter)
                }
                if projects.count > 1 || project != nil {
                    ScopeBar(symbol: "folder", allTitle: L("全部项目"),
                             options: projects.map { name in
                                 ScopeBar.Option(id: name, title: name,
                                                 count: candidates.filter { Self.project($0) == name && (source == nil || $0.sourceId == source) }.count)
                             },
                             selection: $projectFilter)
                }
            }
        }
    }

    private var fresh: [String] { picked.filter { !existing.contains($0) }.sorted() }
    private var ready: Bool { groupId == nil ? picked.count >= 2 : !fresh.isEmpty }
    private var buttonTitle: String {
        if groupId != nil { return fresh.isEmpty ? L("请选择要添加的会话") : L("添加 %lld 个会话", count: fresh.count) }
        return picked.count >= 2 ? L("建群（%lld 个会话）", count: picked.count) : L("至少选择两个会话")
    }

    /// 只拖 / 点了一个会话：它还没在的进行中的群，可以直接加进去
    @ViewBuilder
    private var joinable: some View {
        if case .create(let keys) = mode, keys.count == 1, let key = keys.first {
            let groups = model.groups.items.filter { model.isLive($0) && $0.member(key) == nil }
            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("加入已有的群").font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            Button {
                                busy = true
                                Task {
                                    let ok = await model.addToGroup(group.id, keys: [key])
                                    busy = false
                                    if ok { dismiss(); done(group.id) }
                                }
                            } label: {
                                GroupRow(group: group, compact: true).padding(.horizontal, 12).contentShape(Rectangle())
                            }
                            .buttonStyle(RowButtonStyle())
                            if group.id != groups.last?.id { Divider().padding(.leading, 54) }
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("或者新建一个群：").font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                }
            }
        }
    }

    /// 在跑的会话，按电脑分开列（不止一台时）；只读的会话收不到群消息，不能选。上面筛了设备、项目的只列筛剩的
    private var sessions: some View {
        let source = activeSource, project = activeProject
        let all = candidates.filter { (source == nil || $0.sourceId == source) && (project == nil || Self.project($0) == project) }
        let machines = all.reduce(into: [(id: String, name: String)]()) { list, s in
            if !list.contains(where: { $0.id == s.sourceId }) { list.append((s.sourceId, s.sourceName)) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            if all.isEmpty {
                Text(candidates.isEmpty ? L("没有运行中的会话") : L("没有符合筛选条件的会话")).font(.ui(.footnote)).foregroundStyle(.secondary)
            }
            ForEach(machines, id: \.id) { machine in
                VStack(alignment: .leading, spacing: 6) {
                    if machines.count > 1 {
                        Label(machine.name.isEmpty ? L("未知设备") : machine.name, systemImage: "desktopcomputer")
                            .font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
                    }
                    let list = all.filter { $0.sourceId == machine.id }
                    VStack(spacing: 0) {
                        ForEach(list) { session in
                            row(session)
                            if session.key != list.last?.key { Divider().padding(.leading, 82) }
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func row(_ session: SessionInfo) -> some View {
        let member = existing.contains(session.key)
        let enabled = !member && session.canReply
        let on = member || picked.contains(session.key)
        return Button {
            guard enabled else { return }
            if picked.contains(session.key) { picked.remove(session.key) } else { picked.insert(session.key) }
            Haptics.select()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(on ? Theme.wechatGreen.opacity(enabled ? 1 : 0.45) : Color.secondary)
                    .frame(width: 24)
                if let face = model.faces.sessions[session.key], !face.avatar.isEmpty {
                    AgentFaceView(agent: session.agent, face: face, size: 34, corner: 0.23)
                } else {
                    Avatar(text: Format.initials(session.title), size: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        AgentGlyph(session.agent, size: 12).foregroundStyle(.secondary)
                        Text(session.title).font(.ui(.subheadline)).lineLimit(1)
                    }
                    Text(member ? L("已在群里") : (!session.canReply ? L("只读，收不到群消息")
                                                    : [session.cwd.map { ($0 as NSString).lastPathComponent }, session.isBusy ? L("工作中") : nil]
                                                        .compactMap { $0 }.joined(separator: " · ")))
                        .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .opacity(enabled || member ? 1 : 0.5)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    private var topicEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("要它们协作什么（可选）").font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
            TextField(L("例如：右边用完虚拟机后告诉左边，左边再开始搬迁"), text: $topic, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.plain).font(.ui(.body))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            #if os(iOS)
            HoldToDictate { said in topic = Dictation.append(said, to: topic) }
            #else
            MacDictateButton { said in topic = Dictation.append(said, to: topic) }
            #endif
            Text("填写后作为第一条群消息发给所有成员；不填就等你在群里发话。群名会由 agent 按协作的事自动起。")
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }

    private func commit() {
        busy = true
        Task {
            if let groupId {
                let ok = await model.addToGroup(groupId, keys: fresh)
                busy = false
                if ok { dismiss(); done(groupId) }
            } else if let id = await model.createGroup(keys: Array(picked), topic: topic.trimmingCharacters(in: .whitespacesAndNewlines)) {
                busy = false
                dismiss()
                done(id)
            } else {
                busy = false
            }
        }
    }
}

/// 单独的群聊页接住拖来的会话（松开 = 进群）。开在分屏里时不挂：交给分屏算落点（中间进群、四边分屏），不然这一层把落点截走
private struct GroupJoinDrop: ViewModifier {
    let enabled: Bool
    @Binding var dropping: Bool
    let join: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [PaneDrag.type], isTargeted: $dropping) { providers in
                guard let provider = providers.first else { return false }
                provider.loadDataRepresentation(forTypeIdentifier: PaneDrag.type.identifier) { data, _ in
                    guard let data, let drag = PaneDrag.decode(data) else { return }
                    DispatchQueue.main.async { join(drag.key) }
                }
                return true
            }
        } else {
            content
        }
    }
}

// MARK: - 群聊页的输入栏（就是会话的输入栏 Composer / MacComposer，带上 group）

/// 输入栏发到群里：发给哪几个成员（空 = 全部）。和会话的输入栏一样能发图、常用语、语音；
/// 输入框下面那排没有权限模式、模型、上下文，换成「发给全部成员 ⌄」
struct ComposeGroup {
    let id: String
    let recipients: Binding<Set<String>>

    /// 草稿、附图、「+」面板开没开记在这个 key 上（同会话按会话 key 记）
    var key: String { GroupKey.make(id) }
}

extension AppModel {
    /// 输入栏里点了发送（文字、常用语、语音转好的字）：发到群里；没发出去把字放回输入框
    func send(_ target: ComposeGroup, text: String, images: [(name: String, data: Data, preview: Data)] = [], files: [(name: String, data: Data)] = []) {
        let to = target.recipients.wrappedValue.isEmpty ? nil : Array(target.recipients.wrappedValue)
        Task {
            if !(await sendToGroup(target.id, text: text, to: to, images: images, files: files)), !text.isEmpty, (drafts[target.key] ?? "").isEmpty {
                setDraft(target.key, text)
            }
        }
    }
}

/// 输入框下面那排的「发给全部成员 ⌄」（样子同会话那排的小按钮）：选只发给哪几个成员
struct GroupRecipientsChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chipHeight) private var height
    let target: ComposeGroup

    var body: some View {
        if let group = model.groups.group(target.id) {
            let recipients = target.recipients
            let picked = group.members.filter { recipients.wrappedValue.contains($0.key) }
            Menu {
                Button { recipients.wrappedValue = [] } label: {
                    if picked.isEmpty { Label(L("全部成员"), systemImage: "checkmark") } else { Text(L("全部成员")) }
                }
                Divider()
                ForEach(group.members) { member in
                    Button {
                        if recipients.wrappedValue.contains(member.key) { recipients.wrappedValue.remove(member.key) } else { recipients.wrappedValue.insert(member.key) }
                    } label: {
                        if recipients.wrappedValue.contains(member.key) { Label(model.title(of: member), systemImage: "checkmark") } else { Text(model.title(of: member)) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: picked.isEmpty ? "person.2" : "person").font(.app(size: 11, weight: .semibold))
                    Text(picked.isEmpty ? L("发给全部成员") : L("只发给 %@", picked.map { model.title(of: $0) }.joined(separator: L("、"))))
                        .font(.ui(.caption)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.app(size: 9, weight: .semibold))
                }
                .foregroundStyle(picked.isEmpty ? Color.primary.opacity(0.75) : Theme.claude)
                .padding(.horizontal, 9).frame(height: height)
                .background(Theme.field, in: Capsule())
                .contentShape(Capsule())
            }
            #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.plain)
            #endif
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L("选择发给哪些成员"))
        }
    }
}

// MARK: - 分屏里的群（同会话一样是一个标签）

/// 标签栏右边 / 横着的 iPhone 标题条上群的按钮：标记、成员（人形 + 人数，点开右边滑出成员面板）。点了交给群聊页去做
struct GroupPaneButtons: View {
    @Environment(AppModel.self) private var model
    let id: String
    /// 块窄了：只留成员按钮（标记折进「更多」）
    var membersOnly = false

    var body: some View {
        if let group = model.groups.group(id) {
            let open = model.groupDrawers.contains(id)
            #if os(macOS)
            if !membersOnly {
                TarsPaneButton(group.marked ? "star.fill" : "star", help: group.marked ? L("已标记，点按取消标记") : L("标记：排在所有列表的最上面")) {
                    withAnimation(.snappy) { model.markGroup(id, !group.marked) }
                }
                .foregroundStyle(group.marked ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(.primary))
            }
            GroupMembersButton(count: group.members.count, open: open) { model.groupAction = (id, .members, UUID()) }
            #else
            HStack(spacing: 0) {
                Button { model.groupAction = (id, .members, UUID()) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: open ? "person.2.fill" : "person.2")
                        Text("\(group.members.count)").monospacedDigit()
                    }
                    .frame(height: 30).padding(.horizontal, 6).contentShape(Rectangle())
                }
                .accessibilityLabel(L("群成员"))
                Menu { GroupPaneMenu(id: id, folded: false) } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel(L("群设置"))
            }
            .font(.ui(.subheadline))
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
            #endif
        }
    }
}

#if os(macOS)
/// 标签栏上的成员按钮：人形 + 人数（成员面板开着时实心），样子同旁边的小图标按钮
private struct GroupMembersButton: View {
    let count: Int
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: open ? "person.2.fill" : "person.2").font(.system(size: 12, weight: .medium))
                Text("\(count)").font(.system(size: 11.5, weight: .medium).monospacedDigit())
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 26, minHeight: 24)
            .background(Color.primary.opacity(hovering ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("群成员"))
        .accessibilityLabel(L("群成员"))
    }
}
#endif

/// 群的「更多」菜单（标签栏的 ⋯、右键标签）：folded = 块太窄、标签栏上的按钮折进来了，成员排最前面
struct GroupPaneMenu: View {
    @Environment(AppModel.self) private var model
    let id: String
    let folded: Bool

    var body: some View {
        if let group = model.groups.group(id) {
            if folded {
                Button { model.groupAction = (id, .members, UUID()) } label: { Label(L("群成员"), systemImage: "person.2") }
            }
            Button { model.groupAction = (id, .add, UUID()) } label: { Label(L("添加成员"), systemImage: "person.badge.plus") }
            Button { model.groupAction = (id, .rename, UUID()) } label: { Label(L("修改群名"), systemImage: "pencil") }
            Button { model.markGroup(id, !group.marked) } label: {
                Label(group.marked ? L("取消标记") : L("标记"), systemImage: group.marked ? "star.slash" : "star")
            }
            Button { model.muteGroup(id, !group.muted) } label: {
                Label(group.muted ? L("取消免打扰") : L("免打扰（群消息不推送）"), systemImage: group.muted ? "bell" : "bell.slash")
            }
            if group.paused {
                Button { Task { await model.pauseGroup(id, false) } } label: { Label(L("继续转发"), systemImage: "play") }
            } else {
                Button { Task { await model.pauseGroup(id, true) } } label: { Label(L("暂停转发"), systemImage: "pause") }
            }
            Divider()
            Button(role: .destructive) { model.groupAction = (id, .disband, UUID()) } label: { Label(L("解散群"), systemImage: "trash") }
        }
    }
}

extension AppModel {
    /// 会话拖到显示着群的那块中间：还不在群里、能回复的会话松开就进群（同原来拖进群聊页），返回那个群；
    /// 已经在群里的、拖的是群、拖到四边的照常开标签、分屏
    func joinableGroup(_ key: String?, into paneKey: String?) -> GroupInfo? {
        guard let key, GroupKey.id(key) == nil, let id = GroupKey.id(paneKey), let group = groups.group(id),
              group.member(key) == nil, session(key)?.canReply == true else { return nil }
        return group
    }

    /// 能进就进群，返回 true；不能进返回 false（交回去照常放）
    func joinDropped(_ key: String, into paneKey: String?) -> Bool {
        guard let group = joinableGroup(key, into: paneKey) else { return false }
        Task {
            if await addToGroup(group.id, keys: [key]) { flash(L("已加入群：%@", session(key)?.title ?? key)) }
        }
        return true
    }
}

extension SessionCard {
    /// 拖着群走的卡片：群名、几个成员、最后一句
    init(group: GroupInfo, model: AppModel) {
        let line = group.last.map { $0.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) } ?? ""
        self.init(title: group.name, status: L("%lld 个成员", group.members.count), line: line,
                  detail: group.members.map { model.title(of: $0) }.joined(separator: L("、")), dot: Theme.claude)
    }
}

// MARK: - 全部群

/// 「会话群」页：进行中的群在上，成员都关了的历史群在下
struct GroupsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @State private var showPicker = false
    @State private var deleting: GroupInfo?

    var body: some View {
        let live = model.groups.items.filter { model.isLive($0) }
        let past = model.groups.items.filter { !model.isLive($0) }
        List {
            if !live.isEmpty {
                Section(L("进行中")) { ForEach(live) { row($0) } }
            }
            if !past.isEmpty {
                Section {
                    ForEach(past) { row($0) }
                } header: {
                    Text("历史群")
                } footer: {
                    Text("成员会话都已关闭的群。在群里发消息，会在原来的项目里恢复它们接着协作。")
                }
            }
        }
        .overlay {
            if model.groups.items.isEmpty {
                ContentUnavailableView {
                    Label(L("还没有会话群"), systemImage: "person.2")
                } description: {
                    Text("把一个会话拖到另一个会话上，或在会话的菜单里选「拉群协作」，让不同设备、不同项目里的会话互相沟通。")
                } actions: {
                    Button(L("拉群协作")) { showPicker = true }
                }
            }
        }
        .navigationTitle(L("会话群"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showPicker = true } label: { Label(L("拉群协作"), systemImage: "person.2.badge.plus") }
            }
        }
        .task { await model.groups.load(model.api) }
        // 面板里显式带上 model：从推进来的页面弹出时，系统不一定把环境里的对象传进面板（截图版实测会崩）
        .sheetPanel(isPresented: $showPicker) { GroupPickerSheet(mode: .create([])) { open(.group($0)) }.environment(model) }
        .confirmPanel(GroupDisband.message,
                      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), confirm: L("解散群"), destructive: true) {
            if let id = deleting?.id { Task { await model.deleteGroup(id) } }
        }
    }

    private func row(_ group: GroupInfo) -> some View {
        Button { open(.group(group.id)) } label: { GroupRow(group: group).contentShape(Rectangle()) }
            .buttonStyle(RowButtonStyle())
            .groupRowActions(group) { deleting = group }
    }
}

/// 解散群的确认文字（各处同一句）
enum GroupDisband {
    static var message: String { L("解散后群里的消息记录一并删除，成员会话不受影响。") }
}

/// 群那一行的标记、免打扰、解散（长按菜单里、Mac 侧栏右键菜单里）；解散先交给列表弹确认
struct GroupMenuItems: View {
    @Environment(AppModel.self) private var model
    let group: GroupInfo
    let disband: () -> Void

    var body: some View {
        Button { model.markGroup(group.id, !group.marked) } label: {
            Label(group.marked ? L("取消标记") : L("标记"), systemImage: group.marked ? "star.slash" : "star")
        }
        Button { model.muteGroup(group.id, !group.muted) } label: {
            Label(group.muted ? L("取消免打扰") : L("免打扰（群消息不推送）"), systemImage: group.muted ? "bell" : "bell.slash")
        }
        Divider()
        Button(role: .destructive, action: disband) { Label(L("解散群"), systemImage: "trash") }
    }
}

extension View {
    /// 群那一行的左右滑和长按菜单，交互同会话行：右滑标记（主题色）/ 取消标记（红，要点）；左滑解散（红）、免打扰（橙）
    func groupRowActions(_ group: GroupInfo, split: ((Bool) -> Void)? = nil, disband: @escaping () -> Void) -> some View {
        modifier(GroupRowActions(group: group, split: split, disband: disband))
    }
}

private struct GroupRowActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let group: GroupInfo
    /// 左右分栏、群还没开在右边：长按菜单里「在右侧 / 下方分屏打开」（参数 = 往下分）
    var split: ((Bool) -> Void)?
    let disband: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(action: disband) { Text("解散") }
                    .tint(Theme.removed)
                Button { model.muteGroup(group.id, !group.muted) } label: { Text(group.muted ? "取消免打扰" : "免打扰") }
                    .tint(Color(hex: 0xF2A33A))
            }
            .swipeActions(edge: .leading, allowsFullSwipe: !group.marked) {
                Button { model.markGroup(group.id, !group.marked) } label: {
                    Label(group.marked ? "取消标记" : "标记", systemImage: group.marked ? "star.slash.fill" : "star.fill")
                }
                .tint(group.marked ? Theme.removed : Theme.claude)
            }
            .contextMenu {
                if let split {
                    Button { split(false) } label: { Label("在右侧分屏打开", systemImage: "square.split.2x1") }
                    #if os(iOS)
                    if !ChatPanes.sideBySideOnly {
                        Button { split(true) } label: { Label("在下方分屏打开", systemImage: "square.split.1x2") }
                    }
                    #endif
                    Divider()
                }
                GroupMenuItems(group: group, disband: disband)
            }
    }
}

/// 列表里的群拖得进右边的分屏（只在左右分栏时）
struct GroupRowDrag: ViewModifier {
    let enabled: Bool
    let key: String
    let card: SessionCard

    func body(content: Content) -> some View {
        if enabled { content.sessionDrag(key: key, card: card) } else { content }
    }
}

// MARK: - 拖到一起拉群

/// 会话行接住拖过来的另一个会话：松开 = 拉这两个会话建群（弹面板确认、可写要协作的事）。拖着经过时画虚线框和「松开拉群」
struct GroupDropTarget: ViewModifier {
    let key: String
    var label = L("松开拉群")
    let perform: (String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                // 拖的是群（拖进分屏用的）：不画「松开拉群」
                if targeted, GroupKey.id(PaneDrag.current?.key) == nil {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.claude, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .overlay(alignment: .trailing) {
                            Label(label, systemImage: "person.2.fill")
                                .font(.ui(.caption).weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.claude, in: Capsule())
                                .padding(.trailing, 8)
                        }
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [PaneDrag.type], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                let target = key
                provider.loadDataRepresentation(forTypeIdentifier: PaneDrag.type.identifier) { data, _ in
                    guard let data, let drag = PaneDrag.decode(data), drag.key != target, GroupKey.id(drag.key) == nil else { return }
                    DispatchQueue.main.async { perform(drag.key) }
                }
                return true
            }
    }
}

extension View {
    /// 把别的会话拖到这一行上拉群（电脑端不支持会话群时不接）
    @ViewBuilder
    func groupDrop(key: String, enabled: Bool, label: String = L("松开拉群"), perform: @escaping (String) -> Void) -> some View {
        if enabled { modifier(GroupDropTarget(key: key, label: label, perform: perform)) } else { self }
    }
}

/// 列表里「拉群」面板要先勾上的会话（拖到一起的两个 / 右键点的那个）
struct GroupSeed: Identifiable {
    let id = UUID()
    let keys: [String]
}

// MARK: - 会话对话里的群消息

/// 电脑送进会话的群消息（Sources/Groups.swift 的 compose）认出来：群名、带没带群说明、一条条谁说了什么。
/// 格式：可选的「【Kiteline 会话群「名」】……」说明段（到空行为止），然后每条「【群「名」· 谁】」一行 + 内容，最后可能有「（回复群里：…）」
enum GroupText {
    struct Part: Hashable {
        var who: String
        var text: String
    }

    struct Inbound: Hashable {
        var name: String
        var brief: Bool
        var parts: [Part]
    }

    static func parse(_ text: String) -> Inbound? {
        guard text.hasPrefix("【Kiteline 会话群「") || text.hasPrefix("【群「") else { return nil }
        var name = ""
        var brief = false
        var inBrief = false
        var parts: [Part] = []
        var current: Part?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("【Kiteline 会话群「") {
                name = between(line, "「", "」")
                brief = true
                inBrief = true
                continue
            }
            if inBrief {
                if line.isEmpty { inBrief = false }
                continue
            }
            if line.hasPrefix("【群「"), let close = line.range(of: "】") {
                if let current { parts.append(current) }
                let head = String(line[..<close.lowerBound])
                if name.isEmpty { name = between(head, "「", "」") }
                let who = head.range(of: "」· ").map { String(head[$0.upperBound...]) } ?? ""
                let rest = String(line[close.upperBound...])
                current = Part(who: who, text: rest.hasPrefix("（只发给你）") ? "" : rest)
                continue
            }
            if line.hasPrefix("（回复群里：") { continue }
            if current != nil {
                current!.text += (current!.text.isEmpty ? "" : "\n") + raw
            }
        }
        if let current { parts.append(current) }
        guard !name.isEmpty else { return nil }
        return Inbound(name: name, brief: brief, parts: parts.map { Part(who: $0.who, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }

    private static func between(_ text: String, _ open: String, _ close: String) -> String {
        guard let a = text.range(of: open), let b = text.range(of: close, range: a.upperBound..<text.endIndex) else { return "" }
        return String(text[a.upperBound..<b.lowerBound])
    }
}

/// 找群：按 id，老 watcher 没带 id 的按这个会话在的群、群名
private extension AppModel {
    func groupFor(_ key: String, id: String?, name: String?) -> GroupInfo? {
        if let id, !id.isEmpty, let group = groups.group(id) { return group }
        let mine = groups.groups(containing: key)
        return mine.first { $0.name == name } ?? mine.first
    }
}

/// 卡片顶上一行：群标志、「发到群 / 来自群」+ 群名，轻点打开群聊页
private struct GroupCardHead: View {
    @Environment(\.openRoute) private var open
    let label: String
    let name: String
    let group: GroupInfo?

    var body: some View {
        Button {
            if let group { open(.group(group.id)) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2.fill").font(.ui(.caption2))
                Text(label).foregroundStyle(.secondary)
                Text(name).fontWeight(.semibold).lineLimit(1)
                if group != nil { Image(systemName: "chevron.right").font(.ui(.caption2)).foregroundStyle(.tertiary) }
            }
            .font(.ui(.caption))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// agent 发到群里的（group say）：一张「发到群」卡片，正文、只发给了谁
struct GroupSayMessage: View {
    @Environment(AppModel.self) private var model
    let key: String
    let item: ChatItem

    var body: some View {
        let group = model.groupFor(key, id: item.group, name: nil)
        Bubble(mine: false, text: item.text) {
            VStack(alignment: .leading, spacing: 8) {
                GroupCardHead(label: L("发到群"), name: group?.name ?? item.group ?? L("会话群"), group: group)
                if let to = item.to, !to.isEmpty, let group {
                    Text(L("只发给 %@", to.compactMap { group.member($0).map { model.title(of: $0) } }.joined(separator: L("、"))))
                        .font(.ui(.caption2)).foregroundStyle(.secondary)
                }
                MarkdownView(item.text ?? "", fill: false)
            }
        }
    }
}

/// Kiteline 送进这个会话的群消息（对话记录里是一条用户消息）：居中一张「来自群」卡片，一条条谁说了什么；
/// 群说明、回复方法是写给 agent 看的，这里只标一句
struct GroupInboundMessage: View {
    @Environment(AppModel.self) private var model
    let key: String
    let item: ChatItem
    let inbound: GroupText.Inbound

    var body: some View {
        let group = model.groupFor(key, id: nil, name: inbound.name)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                GroupCardHead(label: L("来自群"), name: inbound.name, group: group)
                Spacer(minLength: 6)
                if let ts = item.ts { Text(Format.listTime(ts)).font(.ui(.caption2)).foregroundStyle(.tertiary) }
            }
            if inbound.brief {
                Text("已附上群说明：成员、所在设备与项目、发群消息的方法").font(.ui(.caption2)).foregroundStyle(.secondary)
            }
            ForEach(Array(inbound.parts.enumerated()), id: \.offset) { _, part in
                VStack(alignment: .leading, spacing: 3) {
                    Text(part.who).font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
                    MarkdownView(part.text, fill: false).textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).hairlineBorder(Color.primary.opacity(0.08)))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .contextMenu { Button { Clipboard.copy(item.text ?? "") } label: { Label(L("复制"), systemImage: "doc.on.doc") } }
    }
}
