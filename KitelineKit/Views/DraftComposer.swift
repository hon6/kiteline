#if KITELINE_MAC
import AppKit
import SwiftUI

// 新会话标签（Mac 主程序 Sources/NewSessionDraft.swift）底部的输入区：和普通对话页的输入区（MacComposer）一样的输入框、
// ⌘V 粘贴截图（缩略图排在输入框上面）、绿色「发送」，下面一排权限模式、模型和思考等级、目标、终端（11-22 反馈：新建会话要和普通会话交互一样）。
// 还没有会话，所以选的这些先记在草稿上，发第一句时带过去（后台运行的 Claude Code 当启动参数，见 watcher hosted_launch_flags；
// 在 VS Code 里开的等会话出来再切，见 KitelineKit.afterDraftStart）；目标是第一句发 /goal。
// 终端：主程序预先定好新会话的编号（futureKey = 设备#编号），终端就开在这个编号名下，会话开出来后同一个终端还在那个会话里

/// 草稿上选的设置（按草稿标签的 key 记，切走再回来还在）
@MainActor @Observable
final class DraftSettings {
    static let shared = DraftSettings()

    struct Options: Equatable {
        var mode: PermissionMode?
        var model: String?
        var effort: String?
        var goal: String?
    }

    var options: [String: Options] = [:]
}

/// 发第一句时交给主程序的内容
public struct DraftLaunch {
    public let text: String
    public let images: [(name: String, data: Data)]
    /// 权限模式（default / acceptEdits / plan / auto）、模型 id、思考等级（low … max）；没选的为空（照 Claude Code 自己的默认）
    public let mode: String?
    public let model: String?
    public let effort: String?
    /// 目标：第一句发「/goal 目标」
    public let goal: String?
}

extension KitelineKit {
    /// 新会话标签的输入区。draftKey：草稿标签的 key（文字、图片、选的设置记在它上面）；futureKey：新会话开出来以后的 key（终端记在它上面），
    /// terminal 为 false 时（没法预先定编号：在 VS Code 里开、别家 agent、老版本电脑端）不出终端按钮
    public struct DraftComposer: View {
        let draftKey: String
        let futureKey: String
        let sourceId: String
        let cwd: String
        let agent: String
        let placeholder: String
        let busy: Bool
        let terminal: Bool
        let available: CGFloat
        let onSend: (DraftLaunch) -> Void

        public init(draftKey: String, futureKey: String, sourceId: String, cwd: String, agent: String, placeholder: String,
                    busy: Bool, terminal: Bool, available: CGFloat, onSend: @escaping (DraftLaunch) -> Void) {
            self.draftKey = draftKey
            self.futureKey = futureKey
            self.sourceId = sourceId
            self.cwd = cwd
            self.agent = agent
            self.placeholder = placeholder
            self.busy = busy
            self.terminal = terminal
            self.available = available
            self.onSend = onSend
        }

        public var body: some View {
            if let model = KitelineKit.model {
                DraftComposerBody(draftKey: draftKey, futureKey: futureKey, sourceId: sourceId, cwd: cwd, agent: agent,
                                  placeholder: placeholder, busy: busy, terminal: terminal, available: available, onSend: onSend)
                    .font(.ui(.body))
                    .tint(Theme.claude)
                    .environment(model)
            }
        }
    }

    /// 发出去了：清掉草稿上的字、图、选的设置
    public static func clearDraft(_ draftKey: String) {
        guard let model else { return }
        model.setDraft(draftKey, "")
        model.chat(draftKey).attachments = []
        DraftSettings.shared.options[draftKey] = nil
    }

    // 自测用（SelfTest 的 draftfill / draftattach / draftopt / draftsend）：往草稿里写字、加图、选设置，再按草稿现在的样子发

    public static func testDraft(_ draftKey: String, text: String? = nil, image: Data? = nil, option: String? = nil) {
        guard let model else { return }
        if let text { model.setDraft(draftKey, text) }
        if let image { MacComposer.attach([image], to: model.chat(draftKey)) }
        if let option, let eq = option.firstIndex(of: "=") {
            let name = String(option[..<eq]), value = String(option[option.index(after: eq)...])
            var next = DraftSettings.shared.options[draftKey] ?? DraftSettings.Options()
            switch name {
            case "mode": next.mode = PermissionMode(rawValue: value)
            case "model": next.model = value.isEmpty ? nil : value
            case "effort": next.effort = value.isEmpty || value == "auto" ? nil : value
            case "goal": next.goal = value.isEmpty ? nil : value
            default: return
            }
            DraftSettings.shared.options[draftKey] = next
        }
    }

    /// draftopt:terminal：打开草稿里的终端面板（futureKey 由主程序给）
    public static func testDraftTerminal(_ futureKey: String) {
        model?.chat(futureKey).terminalOpen = true
    }

    public static func testDraftLaunch(_ draftKey: String) -> DraftLaunch? {
        guard let model else { return nil }
        let options = DraftSettings.shared.options[draftKey] ?? DraftSettings.Options()
        return DraftLaunch(text: (model.drafts[draftKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           images: model.chat(draftKey).attachments.map { ($0.name, $0.data) },
                           mode: options.mode?.rawValue, model: options.model, effort: options.effort, goal: options.goal)
    }

    /// 新会话出来以后：启动时没带上的设置在会话里切（在 VS Code 里开的、老版本电脑端），再发第一句以外要接着发的话（设了目标时，
    /// 第一句是 /goal，输入框里写的话在这里发）。等 KitelineKit 这边也看到这个会话（最多 15 秒）
    /// carried：启动时已经带上了（后台运行的 Claude Code）：不再切，只让输入框下面那排先按选的显示——Claude 回话前记录里还没有模型，
    /// 思考等级只在发过 /effort 时才记，不这样的话会显示成「模型 自动」
    public static func afterDraftStart(key: String, carried: Bool, mode: String?, modelId: String?, effort: String?, followUp: String?) {
        guard let model, mode != nil || modelId != nil || effort != nil || !(followUp ?? "").isEmpty else { return }
        if carried {
            let chat = model.chat(key)
            if let modelId { chat.modelOverride = (modelId, nil, "launch") }
            if let effort { chat.effortOverride = (effort, nil, "launch") }
        }
        Task { @MainActor in
            for _ in 0..<60 {
                if model.session(key)?.canReply == true { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard model.session(key)?.canReply == true else { return }
            if !carried {
                if let mode, let target = PermissionMode(rawValue: mode) { await model.setPermissionMode(key, target) }
                if let modelId { model.setModel(key, modelId, modelName(modelId)) }
                if let effort { model.setEffort(key, level: effort, EffortLevel.name(effort)) }
            }
            if let followUp, !followUp.isEmpty { _ = model.send(key, text: followUp, images: []) }
        }
    }
}

private struct DraftComposerBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chipHeight) private var chipHeight
    let draftKey: String
    let futureKey: String
    let sourceId: String
    let cwd: String
    let agent: String
    let placeholder: String
    let busy: Bool
    let terminal: Bool
    let available: CGFloat
    let onSend: (DraftLaunch) -> Void

    @State private var focusToken = 0
    @State private var inputHeight: CGFloat = 38
    @State private var goalEditing = false
    @State private var goalText = ""
    /// 目标框里的字是从输入框带过去的（设好目标后把输入框清掉）
    @State private var goalFromDraft = false

    private var settings: DraftSettings { DraftSettings.shared }
    private var options: DraftSettings.Options { settings.options[draftKey] ?? DraftSettings.Options() }
    private var isClaude: Bool { agent == Agents.defaultID }
    private var chat: ChatStore { model.chat(draftKey) }
    private var draft: String { model.drafts[draftKey] ?? "" }
    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.attachments.isEmpty || options.goal != nil
    }

    /// 终端面板记在新会话的 key 上：会话开出来以后它照样开着
    private var futureChat: ChatStore { model.chat(futureKey) }

    /// 给终端按钮、终端面板用的占位会话（只用到 key 和终端个数）
    private var placeholderSession: SessionInfo? {
        let raw: [String: Any] = ["key": futureKey, "title": "", "sourceId": sourceId, "sourceName": "", "activity": "idle",
                                  "canReply": true, "agent": agent, "terminals": 0, "cwd": cwd]
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(SessionInfo.self, from: data)
    }

    var body: some View {
        Group {
            if terminal, futureChat.terminalOpen, let session = placeholderSession {
                TerminalPanel(key: futureKey, session: session, chat: futureChat, available: available)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                composer
            }
        }
        .onAppear {
            seed()
            if terminal { model.terminals.pendingCwd[futureKey] = cwd }
            focusToken += 1
        }
        .onChange(of: futureKey) { _, key in if terminal { model.terminals.pendingCwd[key] = cwd } }
        .onChange(of: cwd) { _, value in if terminal { model.terminals.pendingCwd[futureKey] = value } }
    }

    private var composer: some View {
        VStack(spacing: Bar.spacing) {
            if !chat.attachments.isEmpty { attachRow }
            HStack(alignment: .bottom, spacing: Bar.spacing - Bar.iconInset) {
                MacInputField(text: Binding(get: { model.drafts[draftKey] ?? "" }, set: { model.setDraft(draftKey, $0) }),
                              height: $inputHeight, placeholder: placeholder, enabled: !busy, focusToken: focusToken,
                              onSubmit: send, onPasteImages: add)
                    .frame(height: inputHeight)
                    .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).hairlineBorder(MacPalette.separator))
                    .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
                if busy {
                    ProgressView().controlSize(.small).frame(width: 38, height: 38)
                } else if hasContent {
                    Button(action: send) {
                        Text(L("发送")).font(.app(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 38)
                            .background(Theme.wechatGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.trailing, -Bar.iconInset)
            chipRow
        }
        .frame(maxWidth: 832)
        .padding(.horizontal, Bar.spacing).padding(.bottom, Bar.spacing)
        .frame(maxWidth: .infinity)
    }

    // MARK: 输入框下面那排

    private var chipRow: some View {
        KiteHScroll {
            HStack(spacing: Bar.spacing) {
                if isClaude {
                    modeChip
                    modelChip
                    goalChip
                } else {
                    HStack(spacing: 5) {
                        AgentGlyph(agent, size: 12)
                        Text(Agents.info(agent).name).foregroundStyle(.primary.opacity(0.75))
                    }
                    .font(.chip).lineLimit(1)
                    .chipFace(height: chipHeight)
                }
                if terminal, let session = placeholderSession {
                    TerminalChip(session: session, chat: futureChat)
                        .help(L("在这个项目所在的电脑上打开终端，会话开出来后终端仍在这个会话里"))
                }
            }
            .padding(.top, Bar.badgeRoom)
        }
        .padding(.top, -Bar.badgeRoom)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
    }

    private var modeChip: some View {
        let mode = options.mode
        return Menu {
            ForEach(PermissionMode.cycle) { item in
                Button { update { $0.mode = item } } label: {
                    if item == mode { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
                .help(item.detail)
            }
            Divider()
            Button { update { $0.mode = nil } } label: {
                if mode == nil { Label(L("照 Claude Code 的默认设置"), systemImage: "checkmark") } else { Text(L("照 Claude Code 的默认设置")) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode?.symbol ?? "shield").font(.app(size: 11, weight: .semibold))
                Text(mode?.title ?? L("默认模式")).font(.chip).lineLimit(1)
            }
            .foregroundStyle(.primary.opacity(0.75))
            .chipFace(height: chipHeight)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(mode?.detail ?? L("权限模式：新会话开出来时用的模式"))
    }

    private var modelChip: some View {
        let current = options.model
        let effort = options.effort
        let choices = ModelChoice.choices(seen: model.sessions.map { $0.usage?.model }, current: current)
        let name = current.map(modelName) ?? L("默认模型")
        return Menu {
            Section(L("模型")) {
                ForEach(choices, id: \.id) { choice in
                    Button { update { $0.model = choice.id } } label: {
                        if current.map(modelName) == choice.name { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                    }
                }
                Button { update { $0.model = nil } } label: {
                    if current == nil { Label(L("默认模型"), systemImage: "checkmark") } else { Text(L("默认模型")) }
                }
            }
            Section(L("思考等级")) {
                ForEach(EffortLevel.all, id: \.id) { level in
                    let on = (effort ?? "auto") == level.id
                    Button { update { $0.effort = level.id == "auto" ? nil : level.id } } label: {
                        if on { Label(level.name, systemImage: "checkmark") } else { Text(level.name) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(name).foregroundStyle(.primary.opacity(0.75))
                Text(EffortLevel.name(effort)).foregroundStyle(.secondary)
            }
            .font(.chip).lineLimit(1)
            .chipFace(height: chipHeight)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(L("模型和思考等级：新会话开出来时用的"))
    }

    private var goalChip: some View {
        let goal = options.goal
        return Button {
            goalText = goal ?? ""
            goalFromDraft = false
            let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            // 同普通会话的目标面板：输入框里已经写了字，直接拿来当目标
            if goal == nil, !typed.isEmpty { goalText = typed; goalFromDraft = true }
            goalEditing = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: GoalText.symbol("active")).font(.app(size: 11, weight: .semibold))
                Text(goal == nil ? L("目标") : L("已设目标")).font(.chip).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(goal == nil ? AnyShapeStyle(.primary.opacity(0.75)) : AnyShapeStyle(GoalText.tint("active")))
            .kiteLook()
        }
        .buttonStyle(PressableStyle())
        .help(goal.map { L("目标：%@", $0) } ?? L("设定目标：%@ 围绕目标持续工作，确认达成才停", "Claude"))
        .popover(isPresented: $goalEditing, arrowEdge: .top) { goalEditor }
    }

    private var goalEditor: some View {
        let trimmed = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            Text("目标").font(.app(size: 13, weight: .semibold))
            TextEditor(text: $goalText)
                .font(.app(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(width: 360, height: 120)
                .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).hairlineBorder(MacPalette.separator))
            Text(L("会话开出来后第一句发 /goal，Claude 围绕目标持续工作，确认达成才停。输入框里写的话接着发。"))
                .font(.app(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360, alignment: .leading)
            HStack(spacing: 8) {
                if options.goal != nil {
                    Button(L("清除目标")) { update { $0.goal = nil }; goalEditing = false }
                        .kiteButton()
                }
                Spacer()
                Button(L("取消")) { goalEditing = false }.kiteButton().keyboardShortcut(.cancelAction)
                Button(L("设为目标")) {
                    update { $0.goal = String(trimmed.prefix(GoalSheet.limit)) }
                    if goalFromDraft { model.setDraft(draftKey, "") }
                    goalEditing = false
                    focusToken += 1
                }
                .kiteButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(14)
    }

    // MARK: 附图

    private var attachRow: some View {
        HStack(spacing: 10) {
            ForEach(chat.attachments) { item in
                ZStack(alignment: .topTrailing) {
                    if let image = NSImage(data: item.preview) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).hairlineBorder(MacPalette.separator))
                            .zoomableOnClick(chat.attachments.map { .local($0.data) }, index: chat.attachments.firstIndex { $0.id == item.id } ?? 0)
                    }
                    Button { chat.attachments.removeAll { $0.id == item.id } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(Color.black.opacity(0.72), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -7)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 7)
    }

    private func add(_ list: [Data]) {
        MacComposer.attach(list, to: chat)
        focusToken += 1
    }

    // MARK: 设置

    private func update(_ change: (inout DraftSettings.Options) -> Void) {
        var next = options
        change(&next)
        settings.options[draftKey] = next
    }

    /// 第一次打开：照这个项目（没有就这台电脑）最近一个 Claude Code 会话的模式、模型、思考等级，和接着在那边开一个一样
    private func seed() {
        guard settings.options[draftKey] == nil, isClaude else { return }
        let claude = model.sessions.filter { $0.sourceId == sourceId && $0.agent == Agents.defaultID }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        guard let recent = claude.first(where: { $0.cwd == cwd }) ?? claude.first else { return }
        settings.options[draftKey] = DraftSettings.Options(mode: recent.permissionMode.flatMap { PermissionMode(rawValue: $0) },
                                                           model: recent.usage?.model,
                                                           effort: recent.effort.flatMap { $0 == "auto" ? nil : $0 },
                                                           goal: nil)
    }

    private func send() {
        guard !busy else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !chat.attachments.isEmpty || options.goal != nil else { return }
        let opts = isClaude ? options : DraftSettings.Options()
        onSend(DraftLaunch(text: text, images: chat.attachments.map { ($0.name, $0.data) },
                           mode: opts.mode?.rawValue, model: opts.model, effort: opts.effort, goal: opts.goal))
    }
}
#endif
