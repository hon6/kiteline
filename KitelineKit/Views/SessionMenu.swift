import SwiftUI

/// 对话页右上角「⋯」：从底部弹出的会话菜单（和网页版一样）——顶上一排常用工具，下面分组列表，开关就地切换
struct SessionMenuSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let key: String
    /// 关掉菜单以后再做（推页面、弹别的面板）
    let perform: (SessionAction) -> Void

    var body: some View {
        let session = model.session(key)
        let past = model.pastMeta[key]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session?.title ?? past?.title ?? L("会话")).font(.ui(.headline)).lineLimit(1)
                    Text([session?.sourceName ?? past?.sourceName, session?.cwdShort ?? (session?.cwd ?? past?.cwd).map(Bytes.shortPath),
                          session == nil ? L("已结束") : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    MenuTile(symbol: "magnifyingglass", title: L("搜索")) { run(.search) }
                    MenuTile(symbol: "folder.fill", title: L("文件")) { run(.files) }
                    if session != nil {
                        MenuTile(symbol: "arrow.triangle.branch", title: L("改动")) { run(.changes) }
                    }
                    // 测试记录、子 agent 图是从对话记录里认的，电脑端说这个 agent 有才给（caps）；已结束的会话照旧给子 agent 图
                    if let session, session.can("tests") { MenuTile(symbol: "checkmark", title: L("测试")) { run(.tests) } }
                    if session?.can("subagents") ?? true {
                        MenuTile(symbol: "point.3.connected.trianglepath.dotted", title: L("子 agent")) { run(.agents) }
                    }
                }
                if let session {
                    MenuGroup {
                        if session.isBusy, session.canReply {
                            MenuRow(symbol: "stop.fill", title: L("中断 %@", "\(session.speaker)"), note: session.isClaude ? L("等同于在 VS Code 中按 Esc") : L("停在当前步骤"),
                                    danger: true) { run(.stop) }
                        }
                        // 权限模式、模型、压缩：电脑端说这个 agent 有才给（caps；Claude Code 是按 ⇧Tab、发 /model、/compact 实现的）
                        if session.canReply {
                            if session.can("mode") {
                                MenuRow(symbol: model.permissionMode(key)?.symbol ?? "hand.raised", title: L("权限模式"),
                                        value: model.permissionMode(key)?.title ?? L("跳过所有确认"), chevron: true) { run(.mode) }
                            }
                            if session.can("model") {
                                MenuRow(symbol: "cpu", title: L("模型和思考等级"),
                                        value: ModelLabel.text(model, key), chevron: true) { run(.model) }
                            }
                            if session.can("compact") {
                                MenuRow(symbol: "arrow.down.right.and.arrow.up.left", title: L("压缩上下文"), chevron: true,
                                        trailing: session.usage?.percent.map { AnyView(ContextBar(percent: $0)) }) { run(.compact) }
                            }
                        }
                        MenuToggle(symbol: "speaker.wave.2.fill", title: L("朗读新回复"),
                                   isOn: Binding(get: { Speaker.shared.autoRead }, set: { Speaker.shared.autoRead = $0 }))
                        MenuToggle(symbol: "bell.slash.fill", title: L("静音"), note: L("仅推送需要确认的消息"),
                                   isOn: Binding(get: { model.muted.contains(key) }, set: { model.setMuted(key, $0) }))
                    }
                }
                MenuGroup {
                    if let session, session.cwd != nil {
                        MenuRow(symbol: "plus", title: L("在此项目中新建会话")) { run(.newTask) }
                        // 会话群：和别的设备、别的项目里的会话互相发消息（电脑端支持才有）
                        if model.supportsGroups, session.canReply {
                            let joined = model.groups.groups(containing: key)
                            MenuRow(symbol: "person.2.fill", title: L("拉群协作"),
                                    note: joined.isEmpty ? L("和其他设备、其他项目里的会话互相沟通") : L("已在 %@", joined.map { L("「%@」", $0.name) }.joined(separator: L("、"))),
                                    chevron: true) { run(.group) }
                        }
                        MenuRow(symbol: model.isMarked(key) ? "star.slash.fill" : "star.fill",
                                title: model.isMarked(key) ? L("取消标记") : L("标记"), note: model.isMarked(key) ? nil : L("排在所有列表的最上面，关闭会话时自动取消")) {
                            model.setMarked(key, !model.isMarked(key)); dismiss()
                        }
                        MenuRow(symbol: model.pinned.contains(key) ? "pin.slash.fill" : "pin.fill",
                                title: model.pinned.contains(key) ? L("取消置顶") : L("置顶")) { model.setPinned(key, !model.pinned.contains(key)); dismiss() }
                        MenuRow(symbol: "info", title: L("会话信息")) { run(.info) }
                        MenuRow(symbol: "person.crop.circle", title: L("Agent 详情"), note: L("头像、昵称，所在设备的 IP 和配置")) { run(.agentInfo) }
                    }
                    // 关闭会话（电脑端给 close 才有，目前是 Claude Code）：关掉电脑上 VS Code 里的标签页（终端里 /exit），会话进历史
                    if let session, session.canReply, session.can("close") {
                        MenuRow(symbol: "xmark", title: L("关闭会话"), note: L("结束此会话，之后可在历史会话中恢复"), danger: true) { run(.close) }
                    }
                    if let cwd = session?.cwd ?? past?.cwd {
                        MenuRow(symbol: "doc.on.doc", title: L("复制工作目录")) { Clipboard.copy(cwd); dismiss() }
                    }
                    MenuRow(symbol: "arrow.down.to.line", title: L("跳到最新消息")) { run(.bottom) }
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func run(_ action: SessionAction) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { perform(action) }
    }
}

/// 关闭会话的确认说明：Claude Code 是关掉 VS Code 里的标签页 / 终端 /exit；别家 agent 由插件关（退出它的界面或在它里面归档）
enum CloseSessionText {
    static func message(_ session: SessionInfo?) -> String {
        guard let session, !session.isClaude else {
            return L("关闭会话将关闭它在电脑上 VS Code 中的标签页（终端中的会话发送 /exit），Claude 随之结束此会话，正在进行的工作会中断。之后可在「历史会话」中恢复")
        }
        return L("关闭会话将结束此 %@ 会话，并关闭或归档它在电脑上的窗口，正在进行的工作会中断。之后可在 %@ 中找回", session.speaker, session.speaker)
    }
}

/// menu、speak：横着的 iPhone 没有导航栏，分屏标题条上的「⋯」「朗读」经 externalAction 交给对话页
enum SessionAction { case search, files, changes, tests, agents, stop, mode, model, compact, newTask, info, agentInfo, bottom, close, menu, speak, terminal, group }

struct MenuTile: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                TarsIcon(symbol: symbol, size: 32)
                Text(title).font(.ui(.caption)).foregroundStyle(.primary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

struct MenuGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 菜单里的一行：彩色圆角图标 + 名字（+ 小字）+ 右边的值 / 箭头
struct MenuRow: View {
    let symbol: String
    let title: String
    var note: String? = nil
    var value: String? = nil
    var danger = false
    var chevron = false
    var trailing: AnyView? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                TarsIcon(symbol: symbol, tint: danger ? Theme.removed : Theme.claude)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(danger ? Theme.removed : .primary)
                    if let note { Text(note).font(.ui(.caption)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                if let trailing { trailing }
                if let value { Text(value).font(.ui(.subheadline)).foregroundStyle(.secondary).lineLimit(1) }
                if chevron { Image(systemName: "chevron.right").font(.ui(.caption).weight(.semibold)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

struct MenuToggle: View {
    let symbol: String
    let title: String
    var note: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SwitchRow(isOn: $isOn) {
            HStack(spacing: 12) {
                TarsIcon(symbol: symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let note { Text(note).font(.ui(.caption)).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// 上下文占用：一小条 + 百分比（70% 以上变橙，90% 以上变红）
struct ContextBar: View {
    let percent: Int
    var body: some View {
        let color: Color = percent >= 90 ? Theme.removed : (percent >= 70 ? .orange : Theme.added)
        HStack(spacing: 6) {
            Capsule().fill(Color.primary.opacity(0.1)).frame(width: 46, height: 5)
                .overlay(alignment: .leading) { Capsule().fill(color).frame(width: 46 * CGFloat(min(percent, 100)) / 100, height: 5) }
            Text("\(percent)%").font(.ui(.caption).monospacedDigit()).foregroundStyle(color)
        }
    }
}

// MARK: 模式（同 VS Code 里输入框下面的模式菜单）

struct ModeSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let key: String
    @State private var busy = false

    var body: some View {
        let session = model.session(key)
        let current = model.permissionMode(key)
        FitSheet(title: L("权限模式")) {
            SheetSection(footer: current == nil ? L("此会话当前为「跳过所有确认」模式，不在 ⇧Tab 的切换范围内，需在电脑上修改。")
                         : L("切换操作等同于在 Claude Code 中按 ⇧Tab 切换到该模式。下一条消息发出后，记录中将显示新模式。")) {
                ForEach(Array(PermissionMode.cycle.enumerated()), id: \.element) { index, mode in
                    if index > 0 { SheetDivider(inset: 52) }
                    Button {
                        guard !busy else { return }
                        busy = true
                        Task {
                            await model.setPermissionMode(key, mode)
                            busy = false
                            dismiss()
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            TarsIcon(symbol: mode.symbol, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title).font(.ui(.body).weight(.medium))
                                Text(mode.detail).font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if mode == current { Image(systemName: "checkmark").font(.ui(.body).weight(.semibold)).foregroundStyle(Theme.wechatGreen) }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .disabled(session?.canReply != true)
        }
    }
}

// MARK: 模型和思考等级（同 VS Code 输入框下面的「Opus 5.5 Extra high」）

/// 「Opus 5.5 超高」：模型名 + 思考等级
@MainActor
enum ModelLabel {
    static func parts(_ model: AppModel, _ key: String) -> (name: String, effort: String?) {
        let name = modelName(model.currentModel(key))
        let effort = EffortLevel.name(model.currentEffort(key)) + (model.currentUltracode(key) ? " · Ultracode" : "")
        return (name.isEmpty ? L("模型") : name, effort)
    }

    static func text(_ model: AppModel, _ key: String) -> String {
        let (name, effort) = parts(model, key)
        return effort.map { "\(name) · \($0)" } ?? name
    }
}

struct ModelSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let key: String

    var body: some View {
        let session = model.session(key)
        let current = modelName(model.currentModel(key))
        let effort = model.currentEffort(key)
        FitSheet(title: L("模型和思考等级")) {
            Group {
            SheetSection(title: L("模型"), footer: current.isEmpty ? L("Claude 尚未回复，暂无法确定当前使用的模型。")
                         : L("切换模型将在此会话中发送 /model 命令，自下一条消息起生效。")) {
                ForEach(Array(ModelChoice.all.enumerated()), id: \.element.id) { index, choice in
                    if index > 0 { SheetDivider() }
                    Button {
                        if choice.name != current { model.setModel(key, choice.id, choice.name) }
                        dismiss()
                    } label: {
                        HStack {
                            Text(choice.name).font(.ui(.body).weight(.medium))
                            Spacer(minLength: 4)
                            if choice.name == current { Image(systemName: "checkmark").font(.ui(.body).weight(.semibold)).foregroundStyle(Theme.wechatGreen) }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            SheetSection(title: L("思考等级"), footer: effortFooter(session)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("思考等级", systemImage: "gauge.with.dots.needle.50percent")
                        Spacer()
                        Text(EffortLevel.name(effort)).foregroundStyle(.secondary)
                    }
                    // 一排点，像 VS Code 里的滑块：点哪档发哪档的 /effort
                    HStack(spacing: 0) {
                        ForEach(EffortLevel.all, id: \.id) { level in
                            let on = (effort ?? "auto") == level.id
                            Button {
                                guard !on else { return }
                                withAnimation(.snappy(duration: 0.2)) { model.setEffort(key, level: level.id, level.name) }
                            } label: {
                                VStack(spacing: 5) {
                                    Circle().fill(on ? Theme.wechatGreen : Color.primary.opacity(0.15)).frame(width: on ? 16 : 9, height: on ? 16 : 9)
                                        .frame(height: 16)
                                    Text(level.name).font(.ui(.caption2)).foregroundStyle(on ? .primary : .secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.steady(.plain))
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                SheetDivider()
                SwitchRow(isOn: Binding(get: { model.currentUltracode(key) }, set: {
                    model.setEffort(key, ultracode: $0, $0 ? L("Ultracode 已开") : L("Ultracode 已关"))
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Ultracode", systemImage: "bolt.horizontal")
                        Text("大型任务多代理并行").font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            }
            .disabled(session?.canReply != true)
        }
    }

    /// 刚发的 /effort 还没生效（Claude 在忙要等这一轮做完）时说一声，免得以为没点上
    private func effortFooter(_ session: SessionInfo?) -> String {
        let chat = model.chat(key)
        let waiting = (chat.effortOverride.map { $0.baseline == session?.effort && !chat.sendFailed($0.send) } ?? false)
            || (chat.ultracodeOverride.map { $0.baseline == (session?.ultracode == true) && !chat.sendFailed($0.send) } ?? false)
        if waiting, session?.isBusy == true { return L("已发送 /effort 命令，Claude 正在工作，将在本轮结束后生效。思考等级和 Ultracode 仅作用于此会话。") }
        if waiting { return L("已发送 /effort 命令，等待 Claude Code 生效。思考等级和 Ultracode 仅作用于此会话。") }
        return L("思考等级和 Ultracode 仅作用于此会话（发送 /effort 命令）。")
    }
}
