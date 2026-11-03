import SwiftUI

/// 一行消息：头像 + 气泡（同微信：时间不跟在每条下面，隔 5 分钟以上才在中间显示一次）。
/// 同一个人连着说的几条，只有第一条显示头像，气泡的小尖角也只在那条上
struct MessageRow<Content: View>: View {
    enum Side { case me, bot }
    let side: Side
    let first: Bool
    /// Mac 上（同网页版）：每条下面一行小字时间
    var time: Double? = nil
    /// Mac 上：Claude 的文字回复，时间旁边一个小喇叭，点了朗读
    var speak: (text: String, id: String)? = nil
    @ViewBuilder let content: Content

    #if os(macOS)
    // 照网页版 Mac 样式：头像 30，两边留 24，我的气泡最宽约七成；头像和气泡隔 12
    private let avatarSize: CGFloat = 30, gap: CGFloat = 12, edge: CGFloat = 24, meRoom: CGFloat = 200, meRatio: CGFloat = 0.23
    // 每条上下各 10（两条之间 20，下面的时间和自己那条只隔 6，看得出归属）；换人说话时上面留 20，合起来 30
    private let rowGap: CGFloat = 10, turnGap: CGFloat = 20
    #else
    // 头像 30（同 Mac）：字照 VS Code 改成 13 以后，40 的头像比一行气泡高出一截
    // 头像 40、间隔 9（同微信）：对话正文和列表一样 17 号，一行气泡差不多 40 高
    private let avatarSize: CGFloat = 40, gap: CGFloat = 9, edge: CGFloat = 10, meRoom: CGFloat = 52, meRatio: CGFloat = 0.13
    // 照 VS Code：每条上下各 8（两条之间 16）；换人说话时上面多留，合起来 24（同它一轮对话开头）
    private let rowGap: CGFloat = 8, turnGap: CGFloat = 16
    #endif
    /// 对话区多宽：分列时一列可能很窄，我的气泡左边留的空按宽度比例缩，不然只剩几个字宽
    @Environment(\.chatWidth) private var chatWidth
    @Environment(\.chatAgent) private var chatAgent
    @Environment(\.chatFace) private var chatFace
    @Environment(\.openAgentInfo) private var openAgentInfo

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            if side == .me { Spacer(minLength: chatWidth > 0 ? min(meRoom, chatWidth * meRatio) : meRoom) } else { avatar }
            VStack(alignment: side == .me ? .trailing : .leading, spacing: 6) {
                content
                #if os(macOS)
                footer
                #endif
            }
            .environment(\.bubbleTail, first)
            if side == .me { avatar } else { Spacer(minLength: 0) }
        }
        .padding(.horizontal, edge)
        .padding(.top, ChatType.px(first ? turnGap : rowGap))
        .padding(.bottom, ChatType.px(rowGap))
    }

    @ViewBuilder private var avatar: some View {
        if first {
            if side == .bot { botAvatar } else { MyAvatar(size: avatarSize) }
        } else {
            Color.clear.frame(width: avatarSize, height: 1)
        }
    }

    /// 助手的头像（用户设过的头像，没设是 agent 的标志）：点了打开 Agent 详情
    @ViewBuilder private var botAvatar: some View {
        let face = AgentFaceView(agent: chatAgent, face: chatFace, size: avatarSize)
        if let openAgentInfo {
            Button { openAgentInfo() } label: { face.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Agent 详情"))
                .help(chatFace.map { $0.name.isEmpty ? L("Agent 详情") : $0.name } ?? L("Agent 详情"))
        } else {
            face
        }
    }

    #if os(macOS)
    @ViewBuilder private var footer: some View {
        if let time {
            HStack(spacing: 6) {
                Text(Format.clock(time))
                if let speak {
                    Button { Speaker.shared.toggle(speak.text, id: speak.id) } label: {
                        Image(systemName: Speaker.shared.speaking == speak.id ? "speaker.wave.2.fill" : "speaker.wave.2")
                    }
                    .buttonStyle(.plain)
                    .help(Speaker.shared.speaking == speak.id ? L("停止朗读") : L("朗读这条"))
                }
            }
            .font(.app(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
        }
    }
    #endif
}

extension EnvironmentValues {
    /// 这条气泡画不画小尖角（只有带头像的那条画）
    @Entry var bubbleTail = false
    @Entry var openRoute = OpenRoute { _ in }
    /// 只读的对话（子 agent 的完整记录）：长按菜单里不给「引用」「再发一次」
    @Entry var chatReadOnly = false
}

/// 列表里整行是按钮的：保持原来的文字颜色（系统默认会把整行染成强调色），按下变淡
struct RowButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // 被拖过的那一下不触发（弹窗里拖动时手指按在行上，见 TouchTravel）
        Button(role: configuration.role) { if TouchTravel.isTap { configuration.trigger() } } label: { configuration.label }
            .buttonStyle(Look())
    }

    private struct Look: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .hoverHighlight()
                .opacity(configuration.isPressed ? 0.45 : 1)
        }
    }
}

/// 按下去变淡一点（卡片式按钮用）
struct PressableStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) { if TouchTravel.isTap { configuration.trigger() } } label: { configuration.label }
            .buttonStyle(Look())
    }

    private struct Look: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.55 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// 头像的圆角比例：手机上同微信（0.2），Mac 上照网页版（30 的头像圆角 8）
#if os(macOS)
let avatarCorner: CGFloat = 0.27
#else
let avatarCorner: CGFloat = 0.2
#endif

/// Claude Code 的头像：强调色方块里白色的 Claude Code 标志（同别的 agent 用各自的标志，不再用 ✳︎ 字符）
struct ClaudeAvatar: View {
    var size: CGFloat = 40
    var body: some View {
        AgentGlyph(Agents.defaultID, size: size * 0.6).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.claude, in: RoundedRectangle(cornerRadius: size * avatarCorner, style: .continuous))
    }
}

/// 对话里助手的头像：Claude Code 是强调色方块里它的白色标志，别的 agent 是石墨底上它的白色标志（不用各家的品牌色）
struct AgentAvatar: View {
    let agent: String
    var size: CGFloat = 40
    var body: some View {
        if agent == Agents.defaultID {
            ClaudeAvatar(size: size)
        } else {
            AgentGlyph(agent, size: size * 0.56).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: size * avatarCorner, style: .continuous))
        }
    }
}

/// 我的头像：Mac 账户头像（或在设置里换的），没有图就显示名字首字
struct MyAvatar: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 40

    var body: some View {
        let name = model.me?.name ?? L("我")
        if let path = model.me?.avatar, !path.isEmpty, let parts = URLComponents(string: path) {
            RemoteImage(path: parts.path, query: Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first }))
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * avatarCorner, style: .continuous))
        } else {
            Avatar(text: Format.initials(name), size: size)
        }
    }
}

/// 长按气泡弹出的一项操作
struct MenuAction: Identifiable {
    let title: String
    let symbol: String
    let run: () -> Void
    var id: String { title }
}

/// 气泡（同微信）：带小尖角；长按弹出深色横排菜单——复制、引用、朗读、分享、选择文字……
struct Bubble<Content: View>: View {
    var mine: Bool
    /// 有文字的气泡自动带上「复制」「分享」「选择文字」
    var text: String? = nil
    var actions: [MenuAction] = []
    @ViewBuilder let content: Content
    @Environment(\.bubbleTail) private var tail
    @State private var showMenu = false
    @State private var selecting = false

    private var color: Color { mine ? Theme.meBubble : Theme.botBubble }

    // 内边距、圆角见 ChatType.padV / padH / radius；小尖角对着第一行字
    private var radius: CGFloat { ChatType.radius }
    /// 尖角（高 12）对着第一行字的中间：上内边距 + 半行（行高 1.5 倍字号）− 尖角一半
    private var tailY: CGFloat { ChatType.padV + ChatType.size * 0.75 - 6 }

    var body: some View {
        content
            .padding(.horizontal, ChatType.padH)
            .padding(.vertical, ChatType.padV)
            .background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(alignment: mine ? .topTrailing : .topLeading) {
                if tail {
                    BubbleTail(left: !mine).fill(color).frame(width: 6, height: 12).offset(x: mine ? 5 : -5, y: tailY)
                }
            }
            .foregroundStyle(mine ? Theme.meText : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            #if os(macOS)
            // Mac：右键菜单（复制、引用、朗读……），文字可以直接选
            .textSelection(.enabled)
            .contextMenu {
                ForEach(menu) { action in Button(action.title, systemImage: action.symbol, action: action.run) }
            }
            #else
            .onLongPressGesture(minimumDuration: 0.4) {
                guard !menu.isEmpty else { return }
                Haptics.tap()
                showMenu = true
            }
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                MessageMenu(actions: menu) { showMenu = false }
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(Theme.menuBackground)
            }
            #endif
            .sheetPanel(isPresented: $selecting) { SelectTextSheet(text: text ?? "") }
    }

    private var menu: [MenuAction] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return actions }
        var list = [MenuAction(title: L("复制"), symbol: "doc.on.doc") { Clipboard.copy(text) }]
        list += actions
        #if os(iOS)
        list.append(MenuAction(title: L("分享"), symbol: "square.and.arrow.up") { SystemShare.present(text) })
        list.append(MenuAction(title: L("选择文字"), symbol: "text.cursor") { selecting = true })
        #endif
        return list
    }
}

/// 气泡边上的小尖角，尖朝头像
struct BubbleTail: Shape {
    let left: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if left {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// 长按菜单：深灰底、白色图标 + 小字，一排（同微信）
struct MessageMenu: View {
    let actions: [MenuAction]
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    dismiss()
                    // 等菜单收起再做（要弹面板的操作才弹得出来）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { action.run() }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: action.symbol).font(.system(size: 18))
                        Text(action.title).font(.appFixed(size: 11)).lineLimit(1).fixedSize()
                    }
                    .frame(minWidth: 52)
                    .padding(.horizontal, 4)
                    .frame(height: 62)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.steady(.plain))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
    }
}

/// 「选择文字」：全屏大字，可以拖动选一部分（同微信双击消息的效果）
struct SelectTextSheet: View {
    @PanelDismiss private var dismiss
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.ui(.title3))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("选择文字")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("全部复制") { Clipboard.copy(text); dismiss() }.panelToolbarButton() }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).panelToolbarButton() }
            }
        }
    }
}

enum Quote {
    /// 引用回复取哪几行：代码块换成「（代码）」，去掉表格分隔线，最多 6 行、300 字（和网页版一样）
    static func make(_ text: String) -> String {
        let noCode = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: "（代码）", options: .regularExpression)
        let lines = noCode.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.range(of: "^\\|?\\s*:?-{3,}", options: .regularExpression) == nil }
        var quoted = lines.prefix(6).joined(separator: "\n")
        if quoted.count > 300 { quoted = String(quoted.prefix(300)) + "…" } else if lines.count > 6 { quoted += "\n…" }
        return quoted
    }
}

struct UserMessage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chatReadOnly) private var readOnly
    let key: String
    let item: ChatItem
    /// 长按「转发文件」时消息里有好几个文件：先选一个
    @State private var picking: [String]?

    var body: some View {
        let text = item.text ?? ""
        let chat = model.chat(key)
        // 手机发过去的文件（PDF、Excel……）是消息末尾的「[附件] 路径」行：拆出来画成文件卡片，轻点取回预览
        let (shown, files) = FileLink.splitAttached(text)
        VStack(alignment: .trailing, spacing: 4) {
            if let clip = chat.voices[text.trimmingCharacters(in: .whitespacesAndNewlines)], !text.isEmpty {
                // 用语音发的：（跟着一起发的图）+ 语音条 + 下面一块转写的文字（同微信「转文字」）
                if let images = item.images, !images.isEmpty {
                    Bubble(mine: true, actions: [model.forwardImagesAction(key: key, images: images),
                                                 model.favoriteAction(key: key, item: item, mine: true)].compactMap { $0 }) { MessageImages(key: key, images: images) }
                }
                VoiceBubble(id: clip.id, duration: clip.duration, mine: true)
                TranscriptBox(text: text)
            } else {
                Bubble(mine: true, text: shown.isEmpty ? nil : shown, actions: actions(text, files: files)) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let images = item.images, !images.isEmpty { MessageImages(key: key, images: images) }
                        if !files.isEmpty { AttachedFiles(key: key, paths: files) }
                        if !shown.isEmpty { Text(shown).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            if item.queued == true {
                Text("Claude 工作时插入").font(.ui(.caption2)).foregroundStyle(.secondary)
            }
        }
        .sheetPanel(item: Binding(get: { picking.map(MentionedFiles.init) }, set: { picking = $0?.paths })) { FilePickSheet(key: key, paths: $0.paths) }
    }

    private func actions(_ text: String, files: [String]) -> [MenuAction] {
        let favorite = [model.favoriteAction(key: key, item: item, mine: true)].compactMap { $0 }
        let forward = [model.forwardImagesAction(key: key, images: item.images ?? []),
                       model.forwardFilesAction(key: key, paths: files) { picking = files }].compactMap { $0 }
        let prompt = FileLink.splitAttached(text).text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 把这句要求做成提示词链接（发给同事、贴进 PR 评论）：对方用 Kiteline 打开就是填好的「新任务」，项目按这个会话的目录名对
        let link = prompt.isEmpty ? [] : [MenuAction(title: L("复制为提示词链接"), symbol: "link") {
            let cwd = model.session(key)?.cwd ?? model.pastMeta[key]?.cwd
            Clipboard.copy(PromptLink.make(prompt: prompt, project: cwd.map { ($0 as NSString).lastPathComponent }))
        }]
        guard !text.isEmpty, !readOnly else { return forward + link + favorite }
        return [
            MenuAction(title: L("引用"), symbol: "quote.opening") { model.chat(key).quote = Quote.make(FileLink.splitAttached(text).text) },
            MenuAction(title: L("重新发送"), symbol: "arrow.clockwise") { model.send(key, text: text, images: []) },
        ] + forward + link + favorite
    }
}

struct BotText: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chatReadOnly) private var readOnly
    let key: String
    let item: ChatItem
    @State private var adding: AddTodosRequest?
    @State private var picking: [String]?

    var body: some View {
        let text = item.text ?? ""
        let files = FileLink.mentions(in: text)
        Bubble(mine: false, text: text, actions: (readOnly ? [] : [
            MenuAction(title: L("引用"), symbol: "quote.opening") { model.chat(key).quote = Quote.make(text) },
            MenuAction(title: L("加入待办"), symbol: "checklist") { addTodo(text) },
        ]) + [model.forwardFilesAction(key: key, paths: files) { picking = files },
              model.favoriteAction(key: key, item: item, mine: false)].compactMap { $0 } + [
            MenuAction(title: Speaker.shared.speaking == item.id ? L("停止朗读") : L("朗读"), symbol: "speaker.wave.2") {
                Speaker.shared.toggle(text, id: item.id)
            },
        ]) {
            // 气泡贴着字走（同微信）：一两句的回复不再拉成一整行的灰条；有代码块、分隔线的照样撑满
            MarkdownView(text, fill: false)
        }
        .sheetPanel(item: $adding) { AddTodosSheet(request: $0) }
        .sheetPanel(item: Binding(get: { picking.map(MentionedFiles.init) }, set: { picking = $0?.paths })) { FilePickSheet(key: key, paths: $0.paths) }
    }

    /// 长按「加入待办」：认出了要你做的事就列那几件，没认出来就把这条消息（摘头几句）当一条，可以改
    private func addTodo(_ text: String) {
        let asks = item.asks ?? []
        let whole = String(Quote.make(text).replacingOccurrences(of: "\n", with: " ").prefix(200))
        adding = AddTodosRequest(key: key, itemId: item.id, title: model.session(key)?.title ?? model.pastMeta[key]?.title,
                                 ts: item.ts, candidates: asks.isEmpty ? [whole] : asks)
    }
}

struct AgentImageMessage: View {
    @Environment(AppModel.self) private var model
    let key: String
    let item: ChatItem

    var body: some View {
        Bubble(mine: false, text: item.text, actions: [model.forwardImagesAction(key: key, images: item.images ?? []),
                                                        model.favoriteAction(key: key, item: item, mine: false)].compactMap { $0 }) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("%@ 发来图片", model.sessionSlot(key).speaker), systemImage: "photo").font(.ui(.caption)).foregroundStyle(.secondary)
                if let images = item.images { MessageImages(key: key, images: images) }
                if let text = item.text, !text.isEmpty { MarkdownView(text) }
            }
            .frame(maxWidth: 360, alignment: .leading)   // 气泡贴着图走，不撑满一行
        }
    }
}

/// agent 发来的网页（agent_page，watcher 的 send-page）：一张卡片，轻点打开（手机上在 App 里，电脑上用浏览器），下面是一句说明
struct AgentPageMessage: View {
    @Environment(AppModel.self) private var model
    let key: String
    let item: ChatItem

    var body: some View {
        Bubble(mine: false, text: item.text, actions: [model.favoriteAction(key: key, item: item, mine: false)].compactMap { $0 }) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("%@ 发来网页", model.sessionSlot(key).speaker), systemImage: "doc.richtext").font(.ui(.caption)).foregroundStyle(.secondary)
                Button { PageOpener.shared.open(model, key: key, item: item) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(Theme.claude)
                            .frame(width: 36, height: 40)
                            .background(Theme.claude.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? L("网页")).font(.ui(.subheadline)).fontWeight(.semibold).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            #if os(macOS)
                            Text(L("在浏览器中打开")).font(.ui(.caption2)).opacity(0.7)
                            #else
                            Text(L("轻点打开，可缩放、可交互")).font(.ui(.caption2)).opacity(0.7)
                            #endif
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.ui(.caption)).foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.steady(.plain))
                if let caption = item.caption, !caption.isEmpty { MarkdownView(caption) }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
    }
}

/// agent 经待办技能记的一条（agent_todo）。两种（10-27 起的）：
/// - forUser：只有你能做的事 → 「现在处理」（不加进待办）或「加入待办」；处理过的给「已处理好」：输入框里先写好，确认后发给 agent
/// - 不是 forUser：agent 自己以后要做的事 → 显示状态和进度（它自己更新），点一下看待办
struct AgentTodoMessage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let key: String
    let item: ChatItem

    var body: some View {
        let todos = model.todos
        let speaker = model.sessionSlot(key).speaker
        let mine = todos.items.first { $0.source?.key == key && $0.source?.itemId == item.id }
        Bubble(mine: false, text: item.text) {
            VStack(alignment: .leading, spacing: 6) {
                Label(item.forUser == true ? L("需要你来做") : L("%@ 的待办", speaker),
                      systemImage: item.forUser == true ? "hand.raised" : "checklist")
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                Text(item.text ?? "").font(.ui(.body)).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).font(.ui(.footnote)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if item.forUser == true {
                    userActions(added: mine != nil, handled: todos.isHandled(key: key, itemId: item.id), speaker: speaker)
                } else if let mine {
                    Button { open(.todos) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mine.done ? "checkmark.circle.fill" : (mine.status == "doing" ? "arrow.triangle.2.circlepath" : "circle.dashed"))
                            Text(mine.done ? L("已完成") : (mine.status == "doing" ? L("进行中") : L("待处理")))
                            if let progress = mine.progress, !progress.isEmpty { Text(verbatim: "· " + progress).lineLimit(2) }
                        }
                        .font(.ui(.footnote)).foregroundStyle(mine.status == "doing" && !mine.done ? Theme.claude : .secondary)
                    }
                    .buttonStyle(.steady(.plain))
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    @ViewBuilder
    private func userActions(added: Bool, handled: Bool, speaker: String) -> some View {
        if added {
            Button { open(.todos) } label: {
                Label("已加入待办", systemImage: "checkmark.circle.fill").font(.ui(.footnote)).foregroundStyle(.secondary)
            }
            .buttonStyle(.steady(.plain))
        } else if handled {
            // 选了「现在处理」：处理好后在这里告诉 agent
            HStack(spacing: 10) {
                Text(L("处理好后告诉 %@", speaker)).font(.ui(.footnote)).foregroundStyle(.secondary)
                Button { model.replyDone(key: key, text: item.text ?? "", open: open) } label: {
                    Text("已处理好").font(.ui(.footnote).weight(.semibold)).foregroundStyle(Theme.claude)
                }
                .buttonStyle(.steady(.plain))
            }
        } else {
            HStack(spacing: 10) {
                Button { model.handleNow(key: key, itemId: item.id, open: nil) } label: {
                    Text("现在处理").font(.ui(.footnote).weight(.semibold)).foregroundStyle(Theme.claude)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Theme.claude.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.claude.opacity(0.25)))
                }
                .buttonStyle(.steady(.plain))
                Button {
                    Task {
                        if let s = model.todos.suggestions.first(where: { $0.key == key && $0.itemId == item.id }) { await model.addSuggestion(s) }
                        else { await model.addTodos([item.text ?? ""], key: key, itemId: item.id, ts: item.ts, detail: item.detail, forUser: true, agent: true) }
                    }
                } label: {
                    Text("加入待办").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.steady(.plain))
            }
        }
    }
}

/// agent 发来的关键信息（agent_key：账号密码、密钥、地址）：一项一行，能单独复制；密码这类默认遮住，点眼睛才显示；下面一键收藏
struct AgentKeyMessage: View {
    @Environment(AppModel.self) private var model
    let key: String
    let item: ChatItem
    @State private var shown: Set<Int> = []

    var body: some View {
        let saved = model.favorites.contains(key: key, itemId: item.id)
        let fields = item.fields ?? []
        Bubble(mine: false, text: item.text, actions: [model.favoriteAction(key: key, item: item, mine: false)].compactMap { $0 }) {
            VStack(alignment: .leading, spacing: 8) {
                Label("关键信息", systemImage: "key.fill").font(.ui(.caption)).foregroundStyle(.secondary)
                Text(item.title ?? "").font(.ui(.body)).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                ForEach(fields.indices, id: \.self) { index in
                    fieldRow(fields[index], index: index)
                }
                if let note = item.note, !note.isEmpty {
                    Text(note).font(.ui(.footnote)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    if saved { model.removeFavorite(key: key, itemId: item.id) } else { model.addFavorite(key: key, item: item, mine: false) }
                } label: {
                    Label(saved ? L("已收藏") : L("收藏"), systemImage: saved ? "star.fill" : "star")
                        .font(.ui(.footnote).weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.steady(.plain))
                .padding(.top, 2)
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    private func fieldRow(_ field: KeyField, index: Int) -> some View {
        let value = field.value ?? ""
        let hidden = field.secret == true && !shown.contains(index)
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let name = field.name, !name.isEmpty { Text(name).font(.ui(.caption)).foregroundStyle(.secondary) }
                Text(hidden ? String(repeating: "•", count: min(max(value.count, 6), 12)) : value)
                    .font(ChatType.detail).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if field.secret == true {
                Button {
                    if shown.contains(index) { shown.remove(index) } else { shown.insert(index) }
                } label: {
                    Image(systemName: hidden ? "eye" : "eye.slash").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.steady(.plain)).foregroundStyle(.secondary)
                .accessibilityLabel(hidden ? L("显示") : L("隐藏"))
            }
            Button {
                Clipboard.copy(value)
                model.flash(L("已复制"))
            } label: {
                Image(systemName: "doc.on.doc").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.steady(.plain)).foregroundStyle(.secondary)
            .accessibilityLabel(L("复制"))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 语音条（同微信）：时长越长越宽，点一下播放 / 停止
struct VoiceBubble: View {
    @Environment(AppModel.self) private var model
    let id: String?
    let duration: Double
    let mine: Bool

    var body: some View {
        let seconds = max(1, Int(duration.rounded()))
        let playing = id != nil && VoicePlayer.shared.playing == id
        Bubble(mine: mine) {
            HStack(spacing: 6) {
                if mine {
                    Spacer(minLength: 0)
                    Text("\(seconds)″").font(.ui(.body))
                    Image(systemName: "wave.3.left").symbolEffect(.variableColor.iterative, isActive: playing)
                } else {
                    Image(systemName: "wave.3.right").symbolEffect(.variableColor.iterative, isActive: playing)
                    Text("\(seconds)″").font(.ui(.body))
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 44 + CGFloat(min(seconds, 60)) * 2.6)
        }
        .onTapGesture {
            guard TouchTravel.isTap else { return }
            if let id { VoicePlayer.shared.toggle(id, api: model.api) }
        }
    }
}

/// 语音转出来的文字：放在语音条下面的浅色块里（同微信「转文字」）
struct TranscriptBox: View {
    let text: String
    @State private var selecting = false

    var body: some View {
        Text(text.isEmpty ? L("转写中…") : text)
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, ChatType.padH)
            .padding(.vertical, ChatType.padV)
            .background(Theme.botBubble, in: RoundedRectangle(cornerRadius: ChatType.radius, style: .continuous))
            .contextMenu {
                if !text.isEmpty {
                    Button { Clipboard.copy(text) } label: { Label("复制", systemImage: "doc.on.doc") }
                }
            }
    }
}

/// 任务清单（TodoWrite）
struct TodoCard: View {
    let todos: [JSONValue]

    var body: some View {
        let done = todos.filter { $0["status"]?.string == "completed" }.count
        VStack(alignment: .leading, spacing: ChatType.px(4)) {
            HStack {
                Label("任务清单", systemImage: "checklist").fontWeight(.bold)
                Spacer()
                Text("\(done)/\(todos.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                let status = todo["status"]?.string ?? ""
                let text = status == "in_progress" ? (todo["activeForm"]?.string ?? todo["content"]?.string ?? "") : (todo["content"]?.string ?? "")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: status == "completed" ? "checkmark.circle.fill" : (status == "in_progress" ? "circle.dotted.circle" : "circle"))
                        .foregroundStyle(status == "completed" ? Theme.added : (status == "in_progress" ? Theme.claude : .secondary))
                    Text(text)
                        .strikethrough(status == "completed")
                        .foregroundStyle(status == "completed" ? .secondary : .primary)
                        .fontWeight(status == "in_progress" ? .semibold : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, ChatType.padH)
        .padding(.vertical, ChatType.padV + ChatType.px(2))
        .frame(maxWidth: ChatType.px(340), alignment: .leading)
        .background(Theme.botBubble, in: RoundedRectangle(cornerRadius: ChatType.radius, style: .continuous))
    }
}

/// 系统提示（用量到上限、子任务回报、上下文已压缩……），居中小字；带详情的轻点查看
struct EventRow: View {
    let item: ChatItem
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 4) {
            // 目标的那几行（设定、每轮检查、达成……）前面带个小图标，达成的写上用了几轮、多久
            if let goal = item.goal { Image(systemName: GoalText.eventSymbol(goal)).imageScale(.small) }
            Text(text)
            if let stats = item.goalStats {
                let summary = GoalText.stats(turns: stats.turns, seconds: stats.durationMs.map { Int($0 / 1000) }, tokens: stats.tokens)
                if !summary.isEmpty { Text("· " + summary).monospacedDigit() }
            }
            if item.detail != nil { Image(systemName: "chevron.right").imageScale(.small) }
        }
            .font(.ui(.caption))
            .foregroundStyle(item.level == "error" ? Theme.removed : .secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.vertical, 10)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
            .onTapGesture { guard TouchTravel.isTap else { return }; if item.detail != nil { showDetail = true } }
            .sheetPanel(isPresented: $showDetail) {
                FitSheet(title: item.text ?? "", background: Theme.card) { MonoBlock(text: item.detail ?? "") }
            }
    }

    private var text: String {
        let base = item.text ?? ""
        guard let reset = item.resetAt else { return base }
        return reset > Date().timeIntervalSince1970 * 1000 ? L("%@，%@ 恢复", "\(base)", "\(Format.resetTime(reset))") : L("%@（%@ 已恢复）", "\(base)", "\(Format.resetTime(reset))")
    }
}

/// 发出去还没在对话里回显的消息
struct PendingMessage: View {
    @Environment(AppModel.self) private var model
    let key: String
    let pending: PendingSend

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let seconds = pending.voice {
                // 按住说话前选了图：图和语音一起发，图单独一块显示在语音条上面
                if !pending.previews.isEmpty {
                    Bubble(mine: true) { PreviewStrip(previews: pending.previews) }.opacity(pending.state == .sending ? 0.7 : 1)
                }
                VoiceBubble(id: nil, duration: seconds, mine: true).opacity(pending.state == .sending ? 0.7 : 1)
                if !pending.isFailed || !pending.text.isEmpty { TranscriptBox(text: pending.text) }
            } else {
                Bubble(mine: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !pending.previews.isEmpty { PreviewStrip(previews: pending.previews) }
                        ForEach(Array(pending.files.enumerated()), id: \.offset) { _, file in FileChip(name: file.name, size: file.size, mine: true) }
                        if !pending.text.isEmpty { Text(pending.text).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                .opacity(pending.state == .sending ? 0.7 : 1)
            }
            status
        }
    }

    @ViewBuilder private var status: some View {
        switch pending.state {
        case .sending: ProgressView().controlSize(.small)
        case .sent: EmptyView()
        case .filled: Text("已填入 VS Code 输入框，未提交").font(.ui(.caption2)).foregroundStyle(.orange)
        case .queued: Text("离线，连接后自动发送").font(.ui(.caption2)).foregroundStyle(.orange)
        case .unconfirmed:
            // 电脑报了已提交，对话里却一直没出现。不给「重新发送」：老版本电脑端不核对输入框，文字可能还留在里面，再发一次会和它拼在一起
            // （新版粘贴落空、回车没提交上会直接报出来，走 failed / filled）
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("对话中未出现这条消息，请在电脑上查看").multilineTextAlignment(.trailing)
                }
                .font(.ui(.caption2))
                .foregroundStyle(.orange)
                Button { withAnimation(.snappy(duration: 0.2)) { model.discard(key, pending.id) } } label: {
                    Text("移除").font(.ui(.caption2).weight(.medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.steady(.plain))
                .accessibilityLabel("移除这条消息")
            }
        case .failed(let message):
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Button { model.retry(key, pending.id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.removed)
                        Text("\(message)　轻点重新发送").font(.ui(.caption2)).foregroundStyle(Theme.removed).multilineTextAlignment(.trailing)
                    }
                }
                .buttonStyle(.steady(.plain))
                // 不想再发了：从对话里拿掉，别一直挂在最底下
                Button { withAnimation(.snappy(duration: 0.2)) { model.discard(key, pending.id) } } label: {
                    Text("移除").font(.ui(.caption2).weight(.medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.steady(.plain))
                .accessibilityLabel("移除这条未发送的消息")
            }
        }
    }
}

/// 还没发到 Mac 的图（本地缩略图）
struct PreviewStrip: View {
    let previews: [Data]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(previews.enumerated()), id: \.offset) { _, data in
                if let image = PlatformImage(data: data) {
                    Image(platform: image).resizable().scaledToFill().frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }
}

/// 等宽文字块（命令、输出、思考原文）
struct MonoBlock: View {
    let text: String
    var error = false

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.app(size: 12.5, design: .monospaced)).fontDesign(nil)
            .foregroundStyle(error ? Theme.removed : .primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .padding(.trailing, CopyCorner.reserve)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.code, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .copyCorner(text, inset: 5)
    }
}

enum Clipboard {
    static func read() -> String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    /// 「复制」（iPhone）/「拷贝」（Mac）：照各自系统的叫法
    static var verb: String {
        #if os(macOS)
        L("拷贝")
        #else
        L("复制")
        #endif
    }

    /// 复制，并在底部提示「已复制」：复制本身没有任何动静，不提示的话不知道成没成。
    /// 自己显示「已复制」这类状态的地方（按钮变成「已复制」）传 feedback: false
    @MainActor
    static func copy(_ text: String, feedback: Bool = true) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        guard feedback else { return }
        #if KITELINE_MAC
        KitelineKit.model?.flash(L("已拷贝"))
        #elseif canImport(UIKit)
        ToastWindow.flash(L("已复制"))
        #endif
    }
}

/// 右上角的拷贝小钮（同 VS Code 的代码块）：Mac 上指着这一块才出现，iPhone / iPad 没有悬停、一直显示；
/// 点了图标换成对勾一会儿（不另外弹「已拷贝」）
struct CopyCorner: ViewModifier {
    let text: String
    var inset: CGFloat = 6
    @State private var hovering = false
    @State private var copied = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if Self.alwaysShown || Self.captureShown || hovering || copied {
                    Button {
                        Clipboard.copy(text, feedback: false)
                        #if canImport(UIKit)
                        Haptics.tap()
                        #endif
                        withAnimation(.snappy(duration: 0.15)) { copied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            withAnimation(.snappy(duration: 0.2)) { copied = false }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(copied ? Theme.added : Color.secondary)
                            .frame(width: 26, height: 24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.steady(.plain))
                    .help(copied ? L("已拷贝") : Clipboard.verb)
                    .accessibilityLabel(Clipboard.verb)
                    .padding(inset)
                    .transition(.opacity)
                }
            }
            #if os(macOS)
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
            #endif
    }

    #if os(macOS)
    private static let alwaysShown = false
    #else
    private static let alwaysShown = true
    #endif
    /// 字的右边让出多少：iPhone / iPad 上钮一直在，别压住第一行末尾；Mac 只在指着时浮在上面（同 VS Code），不让
    static let reserve: CGFloat = alwaysShown ? 28 : 0
    /// 自测截图：画成指着的样子（在打开会话之前设）
    nonisolated(unsafe) static var captureShown = false
}

extension View {
    /// 右上角加拷贝小钮（代码块、命令、思考……），见 CopyCorner
    func copyCorner(_ text: String, inset: CGFloat = 6) -> some View { modifier(CopyCorner(text: text, inset: inset)) }
}

/// 系统分享面板（文字、图片……）：从最上面那层页面弹出（全屏看图、面板里也弹得出来；SwiftUI 的 ShareLink 在全屏弹出的页面里弹不出来）
enum SystemShare {
    @MainActor static func present(_ text: String) { present([text]) }

    @MainActor static func present(_ items: [Any]) {
        #if canImport(UIKit)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let top else { return }
        // iPad 上分享面板是浮窗，要有落点：放在页面正中、不带箭头（不给落点会直接崩）
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
        #endif
    }

    #if canImport(UIKit)
    /// 现在最上面那层页面（全屏看图、面板里也弹得出来）：分享面板、文件预览从它弹出
    @MainActor static var top: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #endif
}

extension EnvironmentValues {
    /// 对话区的宽度（对话页量好往下传；0 = 不知道）
    @Entry var chatWidth: CGFloat = 0
    /// 这段对话是哪个 agent 的（助手头像用）
    @Entry var chatAgent: String = Agents.defaultID
}
