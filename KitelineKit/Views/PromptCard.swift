import SwiftUI

/// Claude 停下来等你时，输入框上方的卡片：权限确认、批准计划、回答提问
struct PromptCard: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    /// 横着的 iPhone：卡片收紧——字小一档、按钮常规大小、计划里的标题按正文大小（10-27：省地方多看内容）
    @Environment(\.verticalSizeClass) private var verticalSize
    private var compact: Bool { verticalSize == .compact }
    #else
    private let compact = false
    #endif
    let session: SessionInfo
    let chat: ChatStore

    var body: some View {
        let tool = chat.openTool
        let signature = "\(session.key)|\(tool?.id ?? "-")|\(session.blocking ?? "")"
        if session.isWaiting, session.canReply, chat.answeredPrompt != signature {
            Group {
                if let tool, tool.name == "AskUserQuestion", !(tool.input?["questions"]?.array ?? []).isEmpty {
                    QuestionCard(session: session, chat: chat, tool: tool, signature: signature)
                } else if let tool, tool.name == "ExitPlanMode" {
                    PlanCard(session: session, chat: chat, plan: tool.input?["plan"]?.string ?? "", signature: signature)
                } else if let tool {
                    PermissionCard(session: session, chat: chat, tool: tool, signature: signature)
                } else {
                    ConfirmCard(session: session, chat: chat, signature: signature)
                }
            }
            .padding(compact ? 10 : 14)
            .environment(\.markdownFlatHeadings, compact)
            .transformEnvironment(\.dynamicTypeSize) { size in
                guard compact, let index = DynamicTypeSize.allCases.firstIndex(of: size), index > 0 else { return }
                size = DynamicTypeSize.allCases[index - 1]
            }
            #if os(macOS)
            // 照网页版 Mac 样式：最宽 832、居中，圆角 16，细边 + 阴影
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).hairlineBorder(MacPalette.separator).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            .frame(maxWidth: 832)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            #else
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
            .padding(.horizontal, 10)
            #endif
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 卡片上的按键：发给 Mac，成功后这张卡片先收起，等 Mac 的状态更新。
/// 按钮由电脑端给（插件的 pendingOptions）就照它画：拒绝 + 主按钮并排，其余排在下面；没给就是调用处写的老三样
private struct KeyButtons: View {
    @Environment(AppModel.self) private var model
    let session: SessionInfo
    let chat: ChatStore
    let signature: String
    let options: [PendingOption]
    @State private var busy = false

    init(session: SessionInfo, chat: ChatStore, signature: String, options: [PendingOption]) {
        self.session = session
        self.chat = chat
        self.signature = signature
        self.options = options
    }

    init(session: SessionInfo, chat: ChatStore, signature: String, cancel: (label: String, key: String), confirm: (label: String, key: String),
         extra: (label: String, key: String)? = nil) {
        self.init(session: session, chat: chat, signature: signature,
                  options: session.pendingOptions ?? ([PendingOption(key: cancel.key, label: cancel.label, style: "destructive"),
                                                       PendingOption(key: confirm.key, label: confirm.label, style: "primary")]
                                                      + (extra.map { [PendingOption(key: $0.key, label: $0.label, style: "normal")] } ?? [])))
    }

    var body: some View {
        let cancel = options.firstIndex { $0.style == "destructive" }
        let confirm = options.firstIndex { $0.style == "primary" }
        VStack(spacing: 8) {
            if let cancel, let confirm {
                ButtonPair {
                    Button { press(options[cancel]) } label: {
                        Text(options[cancel].label).font(PromptFonts.button).foregroundStyle(Theme.removed).lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .cardButton(prominent: false)
                } primary: {
                    Button { press(options[confirm]) } label: {
                        Text(options[confirm].label).font(PromptFonts.button).lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .cardButton(prominent: true)
                }
                ForEach(Array(options.enumerated()).filter { $0.offset != cancel && $0.offset != confirm }, id: \.offset) { _, option in
                    Button(option.label) { press(option) }.font(.ui(.subheadline))
                        .buttonStyle(.steady(.plain)).foregroundStyle(option.style == "destructive" ? Theme.removed : Theme.claude)
                }
            } else {
                // 没有「拒绝 + 主按钮」这一对（比如全是并列的选项）：一个一行
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button { press(option) } label: {
                        if option.style == "destructive" {
                            Text(option.label).font(PromptFonts.button).foregroundStyle(Theme.removed).lineLimit(2).frame(maxWidth: .infinity)
                        } else {
                            Text(option.label).font(PromptFonts.button).lineLimit(2).frame(maxWidth: .infinity)
                        }
                    }
                    .cardButton(prominent: option.style == "primary")
                }
            }
        }
        .disabled(busy)
        #if SNAPSHOT
        .task {
            guard let want = Snapshot.press else { return }
            try? await Task.sleep(for: .seconds(2))
            if let pick = options.first(where: { $0.key == want }) { press(pick) }
        }
        #endif
    }

    private func press(_ option: PendingOption) {
        // 点的这一下 Claude 那边刚好换成了下一个确认：不按，免得批准了没看过的命令
        guard PromptCard.current(model, session.key, chat) == signature else {
            model.flash(L("%@ 的确认请求已更新，请查看后再操作", "\(session.speaker)"))
            return
        }
        busy = true
        Haptics.tap()
        Task {
            if await model.press(session.key, option.key, label: L("已选择：%@", "\(option.label)")) {
                withAnimation(.snappy) { chat.answeredPrompt = signature }
            }
            busy = false
        }
    }
}

private struct CardTitle: View {
    let symbol: String
    let text: String
    var body: some View {
        Label { Text(text).font(PromptFonts.title) } icon: { Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(Theme.claude) }
    }
}

private struct PermissionCard: View {
    let session: SessionInfo
    let chat: ChatStore
    let tool: ChatItem
    let signature: String

    var body: some View {
        let input = tool.input
        let command = ["command", "file_path", "url", "pattern"].lazy.compactMap { input?[$0]?.string }.first { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(symbol: "exclamationmark.triangle.fill", text: L("%@ 想使用 %@", "\(session.speaker)", "\(Tools.displayName(tool.name))"))
            Text(session.blocking ?? input?["description"]?.string ?? L("需要你的授权")).font(.ui(.subheadline)).foregroundStyle(.secondary)
            if let command {
                Text(command).font(.app(size: 13, design: .monospaced)).fontDesign(nil).lineLimit(5)
                    .padding(10).padding(.trailing, CopyCorner.reserve).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .copyCorner(command, inset: 5)
            }
            KeyButtons(session: session, chat: chat, signature: signature, cancel: (L("拒绝"), "esc"), confirm: (L("允许"), "1"),
                       extra: Agents.info(session.agent).allowsAlways ? (L("允许，且本会话不再询问"), "2") : nil)
        }
    }
}

private struct PlanCard: View {
    /// 横着的 iPhone：计划框矮一点
    @Environment(\.markdownFlatHeadings) private var flat
    let session: SessionInfo
    let chat: ChatStore
    let plan: String
    let signature: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(symbol: "map.fill", text: L("%@ 已拟定计划，等待你批准", "\(session.speaker)"))
            if !plan.isEmpty {
                CappedScroll(maxHeight: flat ? 130 : 280) { MarkdownView(plan).padding(flat ? 8 : 12).font(PromptFonts.plan) }
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            KeyButtons(session: session, chat: chat, signature: signature, cancel: (L("继续规划"), "esc"), confirm: (L("批准执行"), "1"))
        }
    }
}

private struct ConfirmCard: View {
    let session: SessionInfo
    let chat: ChatStore
    let signature: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(symbol: "exclamationmark.triangle.fill", text: L("需要确认"))
            Text(session.blocking ?? session.reason ?? "").font(.ui(.subheadline)).foregroundStyle(.secondary)
            KeyButtons(session: session, chat: chat, signature: signature, cancel: (L("取消"), "esc"), confirm: (L("确认"), "enter"))
        }
    }
}

/// Claude 用 AskUserQuestion 问你：单选 / 多选，也可以自己写
private struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let session: SessionInfo
    let chat: ChatStore
    let tool: ChatItem
    let signature: String
    @State private var busy = false
    /// 正在写哪道题的「其他」：那道题下面出「按住 说话」
    @FocusState private var otherFocused: Int?

    private var questions: [JSONValue] { tool.input?["questions"]?.array ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(symbol: "questionmark.bubble.fill", text: L("%@ 提问", "\(session.speaker)"))
            CappedScroll(maxHeight: 380) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionBlock(index, question)
                    }
                }
            }
            ButtonPair {
                Button { skip() } label: {
                    Text("跳过").font(PromptFonts.button).foregroundStyle(Theme.removed).lineLimit(1).frame(maxWidth: .infinity)
                }
                .cardButton(prominent: false)
            } primary: {
                Button { submit() } label: { Text("确定").font(PromptFonts.button).lineLimit(1).frame(maxWidth: .infinity) }
                    .cardButton(prominent: true)
                    .disabled(!complete)
            }
            .disabled(busy)
        }
    }

    private var answers: [QuestionAnswer] {
        let saved = chat.answers[tool.id] ?? []
        return questions.indices.map { saved.indices.contains($0) ? saved[$0] : QuestionAnswer() }
    }

    private func update(_ index: Int, _ change: (inout QuestionAnswer) -> Void) {
        var all = answers
        change(&all[index])
        chat.answers[tool.id] = all
    }

    private var complete: Bool {
        answers.allSatisfy { !$0.picked.isEmpty || !$0.other.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private func questionBlock(_ index: Int, _ question: JSONValue) -> some View {
        let multi = question["multiSelect"]?.bool == true
        let answer = answers[index]
        VStack(alignment: .leading, spacing: 8) {
            if let header = question["header"]?.string, !header.isEmpty {
                Text(header).font(.ui(.caption).weight(.semibold)).foregroundStyle(Theme.claude)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.iconTile, in: Capsule())
            }
            Text(question["question"]?.string ?? "").font(PromptFonts.question).fixedSize(horizontal: false, vertical: true)
            ForEach(Array((question["options"]?.array ?? []).enumerated()), id: \.offset) { _, option in
                let label = option["label"]?.string ?? ""
                let on = answer.picked.contains(label)
                Button {
                    Haptics.tap()
                    update(index) { a in
                        if multi {
                            if on { a.picked.remove(label) } else { a.picked.insert(label) }
                        } else {
                            a.picked = [label]
                            a.other = ""
                        }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: on ? (multi ? "checkmark.square.fill" : "checkmark.circle.fill") : (multi ? "square" : "circle"))
                            .foregroundStyle(on ? Theme.wechatGreen : .secondary)
                            .font(.ui(.title3))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(PromptFonts.option).foregroundStyle(.primary)
                            if let desc = option["description"]?.string, !desc.isEmpty {
                                Text(desc).font(PromptFonts.note).foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(on ? Theme.wechatGreen.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.steady(.plain))
            }
            HStack(spacing: 6) {
                TextField("其他（自定义）", text: Binding(get: { answers[index].other }, set: { value in
                    update(index) { a in
                        a.other = value
                        if !multi, !value.trimmingCharacters(in: .whitespaces).isEmpty { a.picked = [] }
                    }
                }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(PromptFonts.option)
                .lineLimit(1...4)
                .focused($otherFocused, equals: index)
                #if os(macOS)
                // Mac：框右边一个麦克风，点一下开始听写，转好的字接在后面
                MacDictateButton(compact: true) { said in dictated(said, into: index, multi: multi) }
                #endif
            }
            #if os(macOS)
            .padding(.horizontal, 10).padding(.vertical, 6)
            #else
            .padding(10)
            #endif
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            #if os(iOS)
            // 点进「其他」时：按住说话，转成文字接在后面（不点进来不占地方）
            if otherFocused == index {
                HoldToDictate { said in dictated(said, into: index, multi: multi) }
            }
            #endif
        }
    }

    /// 听写转好的字接在「其他」后面；单选题写了「其他」就不再选别的项
    private func dictated(_ said: String, into index: Int, multi: Bool) {
        update(index) { a in
            a.other = Dictation.append(said, to: a.other)
            if !multi { a.picked = [] }
        }
    }

    private func submit() {
        guard PromptCard.current(model, session.key, chat) == signature else {
            model.flash(L("%@ 的确认请求已更新，请查看后再操作", "\(session.speaker)"))
            return
        }
        busy = true
        Haptics.tap()
        let payload: [[String: Any]] = questions.enumerated().map { index, question in
            ["question": question["question"]?.string ?? "", "picked": Array(answers[index].picked), "other": answers[index].other]
        }
        Task {
            if await model.answer(session.key, tool: tool, answers: payload) {
                withAnimation(.snappy) { chat.answeredPrompt = signature }
            }
            busy = false
        }
    }

    private func skip() {
        guard PromptCard.current(model, session.key, chat) == signature else {
            model.flash(L("%@ 的确认请求已更新，请查看后再操作", "\(session.speaker)"))
            return
        }
        busy = true
        Task {
            if await model.press(session.key, "esc", label: L("已跳过")) {
                withAnimation(.snappy) { chat.answeredPrompt = signature }
            }
            busy = false
        }
    }
}

extension PromptCard {
    /// 这个会话现在等你确认的是哪一个（和卡片上的 signature 同一个算法）：按之前核对
    @MainActor
    static func current(_ model: AppModel, _ key: String, _ chat: ChatStore) -> String {
        "\(key)|\(chat.openTool?.id ?? "-")|\(model.session(key)?.blocking ?? "")"
    }
}

/// 内容少时按内容高度显示，多了才在 maxHeight 以内滚动
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0
    /// 分屏里一块很矮时，对话页给的上限（见 ChatView.promptCap）
    @Environment(\.promptCap) private var cap

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: min(max(height, 1), min(maxHeight, cap)))
        .scrollBounceBehavior(.basedOnSize)
    }
}

enum Haptics {
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// 手指滑到另一个选项上（按住说话时滑到取消 / 转文字）
    static func select() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

/// 卡片字号：iPhone 用系统档位；Mac 照网页版（标题 15、计划正文 15、按钮 16，都加粗）。都跟着设置里的字体、字号走，所以每次现取
extension EnvironmentValues {
    /// 确认卡片里能滚的那段最多多高（分屏里矮的一块才有，默认不限）
    @Entry var promptCap: CGFloat = .infinity
}

/// 卡片底下的两个大按钮：放得下就左右并排；太窄（分列时窄的一列）就上下叠，主按钮在上，免得字被挤成一列
private struct ButtonPair<Secondary: View, Primary: View>: View {
    @ViewBuilder let secondary: Secondary
    @ViewBuilder let primary: Primary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { secondary; primary }
            VStack(spacing: 8) { primary; secondary }
        }
    }
}

enum PromptFonts {
    #if os(macOS)
    static var title: Font { .app(size: 15, weight: .semibold) }
    static var plan: Font { .app(size: 15) }
    static var button: Font { .app(size: 16, weight: .semibold) }
    static var question: Font { .app(size: 16, weight: .semibold) }
    static var option: Font { .app(size: 15) }
    static var note: Font { .app(size: 13) }
    #else
    static var title: Font { .ui(.headline) }
    static var plan: Font { .ui(.body) }
    static var button: Font { .ui(.body).weight(.semibold) }
    static var question: Font { .ui(.body).weight(.semibold) }
    static var option: Font { .ui(.body) }
    static var note: Font { .ui(.footnote) }
    #endif
}
