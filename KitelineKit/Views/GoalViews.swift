import SwiftUI

// MARK: - 数据

/// 目标（/goal；Claude Code 2.1.139 起、Codex 0.128 起）：agent 围着一个目标跨多轮一直做，每轮结束检查一次，确认达成才停，
/// 人不在电脑前也能一直推进。电脑上的 watcher 认出来的（ccpulse-watch.py 的 GoalBook）：Claude Code 看对话记录里的检查结果，
/// Codex 看它自己的目标库。字段缺了、类型不对都不让整份数据解析失败
struct GoalInfo: Decodable, Hashable {
    var text = ""
    /// active 进行中 / paused 停下了（发消息继续）/ blocked 受阻 / limited 额度或预算用完 / met 已达成 / failed 无法达成 / error 出错中止
    var state = "active"
    /// 检查了几次（Claude Code 每轮结束检查一次）；Codex 没有
    var checks: Int?
    /// 最近一次检查的说法：还差什么、为什么做不到
    var reason: String?
    /// 停下的原因（接口出错、检查超时、额度用完……）
    var note: String?
    var since: Double?
    var at: Double?
    var turns: Int?
    var durationMs: Double?
    var tokens: Int?
    /// token 预算（Codex 设了才有）
    var budget: Int?

    private enum CodingKeys: String, CodingKey { case text, state, checks, reason, note, since, at, turns, durationMs, tokens, budget }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? "active"
        checks = try? c.decode(Int.self, forKey: .checks)
        reason = (try? c.decode(String.self, forKey: .reason)).flatMap { $0.isEmpty ? nil : $0 }
        note = (try? c.decode(String.self, forKey: .note)).flatMap { $0.isEmpty ? nil : $0 }
        since = try? c.decode(Double.self, forKey: .since)
        at = try? c.decode(Double.self, forKey: .at)
        turns = try? c.decode(Int.self, forKey: .turns)
        durationMs = try? c.decode(Double.self, forKey: .durationMs)
        tokens = try? c.decode(Int.self, forKey: .tokens)
        budget = try? c.decode(Int.self, forKey: .budget)
    }

    var valid: Bool { !text.isEmpty }
    var running: Bool { GoalText.running(state) }
    /// 正在第几轮（检查过 n 次没达成 = 在做第 n+1 轮）；没有检查次数的（Codex）不说
    var round: Int? { checks.map { running ? $0 + 1 : max(1, $0) } }

    /// 一共做了多久（秒）：结束了的用记下的；还在做的从设定算到现在（Codex 记的是真正干活的时间，用它）
    func seconds(now: Date) -> Int? {
        if let durationMs, durationMs > 0, !running || since == nil { return Int(durationMs / 1000) }
        guard let since else { return durationMs.map { Int($0 / 1000) } }
        let end = running ? now.timeIntervalSince1970 * 1000 : (at ?? since)
        return max(0, Int((end - since) / 1000))
    }

    /// 同一个目标的标识（关掉结束提示时记它）：设定时间 + 目标
    var id: String { "\(Int64(since ?? 0))|\(text.prefix(60))" }
}

extension SessionInfo {
    /// 列表里显示的目标：还在做的一直显示；结束了的（达成、做不到）一小时内还显示，之后看对话页
    var listGoal: GoalInfo? {
        guard let goal, goal.valid else { return nil }
        if goal.running { return goal }
        guard let at = goal.at, Date().timeIntervalSince1970 * 1000 - at < 3_600_000 else { return nil }
        return goal
    }
}

/// 目标各状态的说法、图标、颜色（iPhone、Mac 侧栏和菜单栏、推送共用）
public enum GoalText {
    public static func running(_ state: String) -> Bool { ["active", "paused", "blocked", "limited"].contains(state) }

    /// 列表小标识、对话页那条上的状态
    public static func label(_ state: String) -> String {
        switch state {
        case "paused": L("目标已暂停")
        case "blocked": L("目标受阻")
        case "limited": L("目标额度已用完")
        case "met": L("目标已达成")
        case "failed": L("目标无法达成")
        case "error": L("目标已中止")
        default: L("目标进行中")
        }
    }

    /// 列表小标识上的字（手表上的也是它）：进行中写第几轮
    public static func badge(state: String, round: Int?) -> String {
        if state == "active", let round, round > 1 { return L("目标 · 第 %@ 轮", "\(round)") }
        return label(state)
    }

    /// 推送标题里的那半句（电脑拼中文，出口按设备语言换）
    public static func head(_ state: String) -> String {
        switch state {
        case "paused": "目标已暂停"
        case "blocked": "目标受阻"
        case "limited": "目标额度已用完"
        case "met": "目标已达成"
        case "failed": "目标无法达成"
        case "error": "目标已中止"
        default: "目标进行中"
        }
    }

    public static func symbol(_ state: String) -> String {
        switch state {
        case "paused": "pause.circle"
        case "blocked", "limited": "exclamationmark.circle"
        case "met": "checkmark.circle"
        case "failed", "error": "xmark.circle"
        default: "scope"
        }
    }

    /// 进行中用主题色；停下的橙色；达成绿色；做不到、出错红色（同对话里其他状态的用色，不另起颜色）
    static func tint(_ state: String) -> Color {
        switch state {
        case "paused", "blocked", "limited": .orange
        case "met": Theme.added
        case "failed", "error": Theme.removed
        default: Theme.claude
        }
    }

    /// 对话里目标那几行提示（watcher 给的 goal：set / check / met / failed / paused / cleared / error）前的小图标
    static func eventSymbol(_ kind: String) -> String {
        switch kind {
        case "met": "checkmark.circle"
        case "failed", "error": "xmark.circle"
        case "paused": "pause.circle"
        case "cleared": "scope"
        case "check": "arrow.triangle.2.circlepath"
        default: "scope"
        }
    }

    /// 「3 轮 · 12m · 4.5 万 token」：结束了的目标用了多少（没有的项不写）
    static func stats(turns: Int?, seconds: Int?, tokens: Int?) -> String {
        var parts: [String] = []
        if let turns, turns > 0 { parts.append(L("%lld 轮", count: turns)) }
        if let seconds, seconds > 0 { parts.append(Format.duration(seconds)) }
        if let tokens, tokens > 0 { parts.append(L("%@ token", Format.tokens(tokens))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 列表小标识

/// 列表里的「◎ 目标 · 第 3 轮」（iPhone 会话列表、Mac 侧栏和菜单栏）：同任务阶段的小标识，淡色底、细边，颜色按状态
public struct GoalBadge: View {
    let state: String
    /// 正在第几轮（Claude Code 有，Codex 没有）
    let round: Int?
    let size: CGFloat

    public init(state: String, round: Int? = nil, size: CGFloat = 11) {
        self.state = state
        self.round = round
        self.size = size
    }

    init(_ goal: GoalInfo, size: CGFloat = 11) {
        self.init(state: goal.state, round: goal.round, size: size)
    }

    private var text: String { GoalText.badge(state: state, round: round) }

    public var body: some View {
        let tint = GoalText.tint(state)
        HStack(spacing: size * 0.28) {
            Image(systemName: GoalText.symbol(state)).font(.app(size: size * 0.92, weight: .semibold))
            Text(text).font(.app(size: size, weight: .medium))
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(tint)
        .padding(.horizontal, size * 0.5)
        .padding(.vertical, size * 0.14)
        .background(tint.opacity(0.12), in: Capsule(style: .circular))
        .overlay(Capsule(style: .circular).hairlineBorder(tint.opacity(0.45)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - 对话页的目标条

/// 对话页输入框上方（任务进展条之上）的一条：目标是什么、到哪了（第几轮、最近一次检查还差什么），轻点打开目标面板。
/// 结束了的（达成、做不到、出错）显示结果，点 × 收起（同一个目标不再出来）
struct GoalStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chatWidth) private var chatWidth
    let key: String
    let goal: GoalInfo
    @AppStorage("goalStripDismissed") private var dismissed = ""

    /// 要不要显示：还在做的都显示；结束了的没被你收起过才显示
    static func visible(_ goal: GoalInfo) -> Bool {
        goal.valid && (goal.running || !(UserDefaults.standard.string(forKey: "goalStripDismissed") ?? "").split(separator: "\n").contains(Substring(goal.id)))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: goal.running ? 30 : 3600)) { context in
            Button { model.chat(key).goalSheet = true } label: { row(now: context.date) }
                .buttonStyle(.plain)
        }
        .deckCard()
        .help(L("查看目标"))
    }

    private func row(now: Date) -> some View {
        let tint = GoalText.tint(goal.state)
        let detail = goal.running ? (goal.note ?? goal.reason) : (goal.state == "met" ? nil : goal.reason ?? goal.note)
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: GoalText.symbol(goal.state)).font(.app(size: 13, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(GoalText.label(goal.state)).fontWeight(.semibold).foregroundStyle(tint).lineLimit(1).layoutPriority(1)
                    Text(goal.text).foregroundStyle(.primary.opacity(0.8)).lineLimit(1)
                }
                // 还差什么（最近一次检查的说法）/ 为什么停下：一眼看出进展；窄的分屏块里放不下就不写
                if let detail, chatWidth == 0 || chatWidth >= 300 {
                    Text(detail).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(progress(now: now)).font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            if goal.running {
                Image(systemName: "chevron.up").font(.app(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            } else {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.app(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("收起"))
            }
        }
        .font(.ui(.footnote))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(minHeight: 34)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("查看目标"))
    }

    /// 右边那段：进行中是「第 4 轮 · 12m」，结束了的是「3 轮 · 12m」
    private func progress(now: Date) -> String {
        let seconds = goal.seconds(now: now)
        if goal.running {
            return [goal.round.flatMap { $0 > 1 ? L("第 %@ 轮", "\($0)") : nil }, seconds.map(Format.duration)].compactMap { $0 }.joined(separator: " · ")
        }
        return GoalText.stats(turns: goal.turns ?? goal.checks, seconds: seconds, tokens: nil)
    }

    private func dismiss() {
        var ids = dismissed.split(separator: "\n").map(String.init)
        ids.append(goal.id)
        dismissed = ids.suffix(50).joined(separator: "\n")
    }
}

/// 输入区上方浮着的卡片（任务进展条、目标条）：iPhone 白卡片细边浅阴影；Mac 同输入框，最宽 832 居中
private struct DeckCard: ViewModifier {
    #if os(macOS)
    private static let corner: CGFloat = 12
    #else
    private static let corner: CGFloat = 14
    #endif

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            #if os(macOS)
            .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).hairlineBorder(MacPalette.separator).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
            .frame(maxWidth: 832)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            #else
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).hairlineBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .padding(.horizontal, 10)
            #endif
    }
}

extension View {
    func deckCard() -> some View { modifier(DeckCard()) }
}

// MARK: - 输入框下面那排的「目标」

/// 输入框下面那排里的「◎ 目标」：会话支持目标（caps 的 goal）才有。没设目标时点开写一个；设了的显示状态，点开看进展
struct GoalChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chipHeight) private var height
    let key: String
    let session: SessionInfo

    var body: some View {
        let goal = session.goal.flatMap { $0.valid && $0.running ? $0 : nil }
        Button { model.chat(key).goalSheet = true } label: {
            HStack(spacing: 4) {
                Image(systemName: GoalText.symbol(goal?.state ?? "active")).font(.app(size: 11, weight: .semibold))
                Text(goal.map { GoalText.label($0.state) } ?? L("目标")).font(.ui(.caption)).lineLimit(1)
            }
            .fixedSize()   // 状态字比「目标」长：按内容定宽，别被挤成「目标进…」
            .foregroundStyle(goal.map { GoalText.tint($0.state) } ?? .primary.opacity(0.75))
            .padding(.horizontal, 9).frame(height: height)
            .background(goal.map { GoalText.tint($0.state).opacity(0.12) } ?? Theme.field, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(L("设定目标：%@ 围绕目标持续工作，确认达成才停", session.speaker))
        .accessibilityLabel(goal.map { GoalText.label($0.state) } ?? L("设定目标"))
    }
}

// MARK: - 目标面板

/// 目标面板：没设目标时写一个（多行，可以说话输入），点「开始」发 /goal；设了的看进展（第几轮、用了多久、最近一次检查还差什么），
/// 可以清除、换一个，Codex 的还能暂停 / 继续。从输入框下面的「目标」、对话页的目标条、会话菜单打开
struct GoalSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let key: String
    @State private var text = ""
    /// 正在写的是从输入框里带过来的（发出去以后把输入框清掉）
    @State private var fromDraft = false
    /// 已经有目标时点了「换一个目标」
    @State private var replacing = false
    @State private var confirmClear = false
    @FocusState private var focused: Bool

    /// Claude Code 的 /goal 最长 4000 字
    static let limit = 4000

    private var session: SessionInfo? { model.session(key) }
    private var goal: GoalInfo? { session?.goal.flatMap { $0.valid ? $0 : nil } }
    private var writing: Bool { goal?.running != true || replacing }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool { !trimmed.isEmpty && trimmed.count <= Self.limit && session?.canReply == true }

    var body: some View {
        FitSheet(title: L("目标"), cancel: writing) {
            VStack(alignment: .leading, spacing: 14) {
                if let goal { current(goal) }
                if writing { editor }
            }
        } bottom: {
            Button(action: writing ? start : { withAnimation(.snappy) { replacing = true }; focused = true }) {
                Text(writing ? L("开始") : L("换一个目标"))
                    .font(.ui(.body).weight(.semibold))
                    .foregroundStyle(writing ? .white : Theme.claude)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(writing ? AnyShapeStyle(Theme.wechatGreen.opacity(ready ? 1 : 0.4)) : AnyShapeStyle(Theme.claude.opacity(0.12)),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .disabled(writing && !ready)
            .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            // 输入框里已经写了字：直接拿来当目标（一键把要说的话变成目标）
            let draft = (model.drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, !draft.isEmpty, goal?.running != true { text = draft; fromDraft = true }
        }
        .confirmPanel(L("清除目标后 %@ 不再自动续做，正在进行的这一轮不受影响", session?.speaker ?? "Agent"),
                      isPresented: $confirmClear, confirm: L("清除目标"), destructive: true) {
            command("/goal clear")
        }
    }

    // MARK: 现在的目标

    @ViewBuilder private func current(_ goal: GoalInfo) -> some View {
        TimelineView(.periodic(from: .now, by: goal.running ? 30 : 3600)) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    GoalBadge(goal, size: 12)
                    Spacer(minLength: 4)
                    if let since = goal.since {
                        Text(L("设定于 %@", Format.listTime(since))).font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12)
                Text(goal.text)
                    .font(.ui(.body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
                SheetDivider()
                facts(goal, now: context.date)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        if goal.running, !replacing, let session, session.canReply { actions(goal, session) }
    }

    /// 进展：第几轮 / 用了几轮、用时、token（有预算的写上预算）、最近一次检查、停下的原因
    @ViewBuilder private func facts(_ goal: GoalInfo, now: Date) -> some View {
        if goal.running, let round = goal.round {
            SheetInfoRow(L("进度"), round > 1 ? L("第 %@ 轮（已检查 %@ 次）", "\(round)", "\(goal.checks ?? 0)") : L("第 1 轮"))
            SheetDivider()
        } else if let turns = goal.turns ?? goal.checks, turns > 0 {
            SheetInfoRow(L("用了"), L("%lld 轮", count: turns))
            SheetDivider()
        }
        if let seconds = goal.seconds(now: now) {
            SheetInfoRow(L("用时"), Format.duration(seconds))
            SheetDivider()
        }
        if let tokens = goal.tokens, tokens > 0 {
            SheetInfoRow(L("Token"), goal.budget.map { L("%@ / 预算 %@", Format.tokens(tokens), Format.tokens($0)) } ?? Format.tokens(tokens))
            SheetDivider()
        }
        if let note = goal.note {
            reasonRow(title: goal.state == "limited" ? L("原因") : L("停下的原因"), text: note)
            SheetDivider()
        }
        if let reason = goal.reason {
            reasonRow(title: goal.running ? L("最近一次检查") : goal.state == "met" ? L("检查结论") : L("原因"), text: reason)
        } else if goal.running, goal.note == nil {
            reasonRow(title: L("最近一次检查"), text: goal.checks == nil ? L("由 %@ 在每轮结束时自行判断是否达成", session?.speaker ?? "Agent") : L("本轮结束后检查"))
        }
    }

    private func reasonRow(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(.caption)).foregroundStyle(.secondary)
            Text(text).font(.ui(.subheadline)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    /// 停下了的发一句「继续」（Claude Code 收到消息就接着做）；Codex 的暂停 / 继续走它自己的目标状态；都能清除
    @ViewBuilder private func actions(_ goal: GoalInfo, _ session: SessionInfo) -> some View {
        MenuGroup {
            if session.can("goal-pause") {
                if goal.state == "active" {
                    MenuRow(symbol: "pause.fill", title: L("暂停目标"), note: L("%@ 做完这一轮后不再续做", session.speaker)) { command("/goal pause") }
                } else {
                    MenuRow(symbol: "play.fill", title: L("继续目标"), note: L("%@ 接着一轮一轮推进", session.speaker)) { command("/goal resume") }
                }
                SheetDivider(inset: 54)
            } else if goal.state != "active" {
                MenuRow(symbol: "play.fill", title: L("继续"), note: L("发送「继续」，%@ 接着推进目标", session.speaker)) {
                    model.send(key, text: L("继续"), images: [])
                    dismiss()
                }
                SheetDivider(inset: 54)
            }
            MenuRow(symbol: "xmark", title: L("清除目标"), danger: true) { confirmClear = true }
        }
    }

    // MARK: 写目标

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if goal?.running == true {
                Text("新目标会替换当前目标").font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
            }
            TextField(L("例如：把登录模块的单元测试全部跑通，并修复发现的问题"), text: $text, axis: .vertical)
                .lineLimit(4...12)
                .textFieldStyle(.plain).font(.ui(.body))
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            #if os(iOS)
            HoldToDictate { said in text = Dictation.append(said, to: text) }
            #else
            MacDictateButton { said in text = Dictation.append(said, to: text) }
            #endif
            if trimmed.count > Self.limit - 500 {
                Text(L("%@ / %@ 字", "\(trimmed.count)", "\(Self.limit)"))
                    .font(.ui(.caption).monospacedDigit()).foregroundStyle(trimmed.count > Self.limit ? Theme.removed : .secondary)
            }
            Text(L("%@ 将围绕这个目标跨多轮持续工作，每轮结束检查一次是否达成，确认完成才停下。写清楚怎样算完成（例如「所有测试通过且无报错」）。达成、无法达成或中途停下时会推送提醒。",
                   session?.speaker ?? "Agent"))
                .font(.ui(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start() {
        guard ready else { return }
        // 一行发出去：终端里的会话按行投递，换行会提前提交
        let line = trimmed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        command("/goal " + line)
        if fromDraft { model.setDraft(key, "") }
    }

    private func command(_ text: String) {
        Haptics.tap()
        model.send(key, text: text, images: [])
        dismiss()
    }
}
