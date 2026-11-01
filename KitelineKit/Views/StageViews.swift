import SwiftUI

/// 任务做到第几步（电脑上的 watcher 按工具调用推断，或 agent 用 stage 命令报的，见 ccpulse-watch.py 的 StageTracker）：
/// 列表里「正在工作」前的「2/4 开发中」、对话页输入框上方的任务进展条。电脑只在忙、等确认时给；字段缺了、类型不对都不让整份数据解析失败
struct StageInfo: Decodable, Hashable {
    var step = 0
    var total = 0
    /// 当前这一步的名字（第 4 步按在做的事是「汇报中」或「发布中」；agent 报的可能是自定的）
    var label = ""
    var steps: [String] = []
    /// 这一步、这一轮从什么时候开始（毫秒）
    var since: Double?
    var turnAt: Double?
    /// agent 报阶段时写的一句「在做什么」
    var note: String?
    /// true = 按工具调用推断的；false = agent 自己报的
    var auto = true
    /// 这一轮（规划过的是这个任务）走过的步骤：[[第几步, 开始时间]]
    var marks: [[Double]] = []
    /// 任务分了几部分（几个端、几个模块）时：正在做哪部分、各部分做到第几步；step 这些说的是正在做的那部分
    var part: String?
    var parts: [StagePart] = []

    private enum CodingKeys: String, CodingKey { case step, total, label, steps, since, turnAt, note, auto, marks, part, parts }

    init(step: Int, total: Int, label: String, steps: [String], since: Double? = nil, turnAt: Double? = nil, note: String? = nil,
         auto: Bool = true, marks: [[Double]] = [], part: String? = nil, parts: [StagePart] = []) {
        (self.step, self.total, self.label, self.steps, self.since, self.turnAt, self.note, self.auto, self.marks, self.part, self.parts)
            = (step, total, label, steps, since, turnAt, note, auto, marks, part, parts)
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        step = (try? c.decode(Int.self, forKey: .step)) ?? 0
        total = (try? c.decode(Int.self, forKey: .total)) ?? 0
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        steps = (try? c.decode([String].self, forKey: .steps)) ?? []
        since = try? c.decode(Double.self, forKey: .since)
        turnAt = try? c.decode(Double.self, forKey: .turnAt)
        note = (try? c.decode(String.self, forKey: .note)).flatMap { $0.isEmpty ? nil : $0 }
        auto = (try? c.decode(Bool.self, forKey: .auto)) ?? true
        marks = (try? c.decode([[Double]].self, forKey: .marks)) ?? []
        parts = ((try? c.decode([StagePart].self, forKey: .parts)) ?? []).filter { !$0.name.isEmpty }
        part = (try? c.decode(String.self, forKey: .part)).flatMap { name in parts.contains { $0.name == name } ? name : nil }
        if parts.count < 2 { parts = []; part = nil }
    }

    var valid: Bool { total >= 2 && (1...total).contains(step) && !label.isEmpty }

    /// 「2/4 开发中」；分了部分的「iPhone · 2/4 开发中」
    var short: String { (part.map { "\($0) · " } ?? "") + compact }
    /// 不带部分的「2/4 开发中」（标题栏这种放不下的地方）
    var compact: String { "\(step)/\(total) \(L(label))" }

    /// 各部分的完成情况（列表小标识前的圆点）
    var dots: [StageDot] { parts.map { $0.done ? .done : $0.name == part ? .current : .pending } }

    /// 第几步（从 0 数）叫什么：当前这步用 label，其余用流程里的名字；都按界面语言换（agent 自定的查不到，原样）
    func name(_ index: Int) -> String {
        if index == step - 1 { return L(label) }
        return index < steps.count ? L(steps[index]) : "\(index + 1)"
    }

    /// 流程里第几步（从 0 数）原本叫什么（别的部分做到哪一步：当前这步报的说明名不算）
    func planned(_ index: Int) -> String {
        index < steps.count ? L(steps[index]) : "\(index + 1)"
    }

    /// 这一轮里每一步累计用了多久（秒）；没走到过的是 nil。来回走过的（测完又改）加在一起
    func seconds(now: Date) -> [Int?] {
        var out = [Int?](repeating: nil, count: total)
        let nowMs = now.timeIntervalSince1970 * 1000
        let list = marks.filter { $0.count == 2 }.isEmpty ? [[Double(step), since ?? turnAt ?? nowMs]] : marks.filter { $0.count == 2 }
        for (i, mark) in list.enumerated() {
            let index = Int(mark[0]) - 1
            guard out.indices.contains(index) else { continue }
            let end = i + 1 < list.count ? list[i + 1][1] : nowMs
            out[index] = (out[index] ?? 0) + max(0, Int((end - mark[1]) / 1000))
        }
        return out
    }
}

/// 任务的一部分（一个端、一个模块）：做到第几步（0 = 还没开始）、做完没有
struct StagePart: Decodable, Hashable {
    var name: String
    var step: Int
    var done: Bool

    private enum CodingKeys: String, CodingKey { case name, step, done }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        step = (try? c.decode(Int.self, forKey: .step)) ?? 0
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    }
}

/// 小标识前的圆点：这部分做完了 / 正在做 / 还没开始
public enum StageDot: Sendable { case done, current, pending }

extension SessionInfo {
    /// 正在做（忙、等确认）且像样的阶段才显示
    var liveStage: StageInfo? {
        guard isBusy || isWaiting, let stage, stage.valid else { return nil }
        return stage
    }
}

/// 各部分完成情况的小圆点：做完的实心、正在做的空心圈、没开始的淡色
struct StageDots: View {
    let dots: [StageDot]
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.2) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                switch dot {
                case .done: Circle().fill(Theme.claude)
                case .current: Circle().strokeBorder(Theme.claude, lineWidth: max(1, size * 0.12))
                case .pending: Circle().fill(Theme.claude.opacity(0.25))
                }
            }
            .frame(width: size * 0.45, height: size * 0.45)
        }
    }
}

/// 「2/4 开发中」小标识：会话列表（iPhone、Mac 侧栏、菜单栏）。
/// 主题色字、淡主题色底、细边（同选中态的写法，不用整块饱和色）
public struct StageBadge: View {
    let step: Int
    let total: Int
    let label: String
    /// 分了部分的：正在做的那部分、各部分的圆点（不到两部分不画）
    let part: String?
    let dots: [StageDot]
    let size: CGFloat

    public init(step: Int, total: Int, label: String, part: String? = nil, dots: [StageDot] = [], size: CGFloat = 11) {
        self.step = step
        self.total = total
        self.label = label
        self.part = part
        self.dots = dots
        self.size = size
    }

    init(_ stage: StageInfo, size: CGFloat = 11) {
        self.init(step: stage.step, total: stage.total, label: stage.label, part: stage.part, dots: stage.dots, size: size)
    }

    public var body: some View {
        HStack(spacing: size * 0.3) {
            if dots.count >= 2 { StageDots(dots: dots, size: size).padding(.trailing, size * 0.1) }
            if let part { Text(part).font(.app(size: size, weight: .semibold)) }
            Text("\(step)/\(total)").font(.app(size: size, weight: .bold).monospacedDigit())
            Text(L(label)).font(.app(size: size, weight: .medium))
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(Theme.claude)
        .padding(.horizontal, size * 0.5)
        .padding(.vertical, size * 0.14)
        .background(Theme.claude.opacity(0.12), in: Capsule(style: .circular))
        .overlay(Capsule(style: .circular).hairlineBorder(Theme.claude.opacity(0.45)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((part.map { "\($0)，" } ?? "") + L("第 %@ 步，共 %@ 步：%@", "\(step)", "\(total)", L(label)))
    }
}


/// 对话页输入框上方的任务进展条（11-01：步骤都放这里，对话里别处不再显示）。只在忙、等确认时有：
/// 平时收成一行——做到第几步、在做什么、这一步用了多久；轻点（或往上滑）展开成清单：走过的步骤打勾划掉，
/// 正在做的主题色，没到的灰圈；分了几部分（几个端）的每部分一行，正在做的那部分下面列出它的步骤
struct StageStrip: View {
    let stage: StageInfo
    /// 对话页多高：展开的清单最多占四成五，再多在里面滚
    var available: CGFloat = 0
    @Environment(\.chatWidth) private var chatWidth
    @State private var expanded = false
    @State private var listHeight: CGFloat = 0

    #if os(macOS)
    private static let corner: CGFloat = 12
    #else
    private static let corner: CGFloat = 14
    #endif

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = stage.seconds(now: context.date)
            VStack(spacing: 0) {
                if expanded {
                    list(seconds: seconds, now: context.date)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                }
                header(seconds: seconds)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        #if os(macOS)
        // 同输入框：白底细边、浅阴影，最宽 832 居中
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
        #if SNAPSHOT
        .onAppear { if Snapshot.sheet == "stage" { expanded = true } }   // 截展开的样子
        #endif
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
    }

    /// 收起时的一行：（分部分的圆点、哪部分）2/5 这一步叫什么 · 在做什么 …… 这一步用了多久 ⌃
    private func header(seconds: [Int?]) -> some View {
        let spent = seconds.indices.contains(stage.step - 1) ? seconds[stage.step - 1] : nil
        return Button(action: toggle) {
            HStack(spacing: 7) {
                StageRing(step: stage.step, total: stage.total)
                HStack(spacing: 5) {
                    if stage.dots.count >= 2 { StageDots(dots: stage.dots, size: 11) }
                    if let part = stage.part { Text(part).fontWeight(.semibold) }
                    Text("\(stage.step)/\(stage.total)").fontWeight(.bold).monospacedDigit()
                    Text(stage.name(stage.step - 1)).fontWeight(.semibold)
                }
                .foregroundStyle(Theme.claude)
                .lineLimit(1)
                .layoutPriority(1)
                // 在做什么：展开后清单里当前那步下面有，这里不重复；窄的分屏块里放不下
                if !expanded, let note = stage.note, chatWidth == 0 || chatWidth >= 300 {
                    Text(note).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let spent {
                    Text(Format.duration(spent)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.up")
                    .font(.app(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.ui(.footnote))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 往上滑展开、往下滑收起
        .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { value in
            if value.translation.height < -12, !expanded { toggle() }
            if value.translation.height > 12, expanded { toggle() }
        })
        .help(expanded ? L("收起") : L("展开全部步骤"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("任务进展：%@", (stage.part.map { "\($0)，" } ?? "")
                              + L("第 %@ 步，共 %@ 步：%@", "\(stage.step)", "\(stage.total)", stage.name(stage.step - 1))))
        .accessibilityHint(expanded ? L("收起") : L("展开全部步骤"))
        .accessibilityAddTraits(.isButton)
    }

    /// 展开的清单：标题行（自动识别 / Agent 报告、一共用了多久）+ 步骤；太长在里面滚
    private func list(seconds: [Int?], now: Date) -> some View {
        let cap = available > 0 ? max(120, min(380, available * 0.45)) : 300
        let rows = stage.parts.isEmpty ? stage.total : stage.parts.count + stage.total
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(L("任务进展")).fontWeight(.semibold)
                    Text(stage.auto ? L("自动识别") : L("Agent 报告"))
                        .font(.ui(.caption2)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule(style: .circular))
                    Spacer(minLength: 4)
                    if let start = stage.turnAt {
                        Text(L("用时 %@", Format.duration(max(0, Int((now.timeIntervalSince1970 * 1000 - start) / 1000)))))
                            .font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.bottom, 6)
                if stage.parts.isEmpty {
                    steps(seconds: seconds)
                } else {
                    ForEach(stage.parts, id: \.name) { part in
                        partRow(part)
                        if part.name == stage.part { steps(seconds: seconds).padding(.leading, 22) }
                    }
                }
            }
            .font(.ui(.footnote))
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // 量到清单多高之前先按行数估一个，免得展开的第一下是 0 高
        .frame(height: min(listHeight > 0 ? listHeight : CGFloat(rows) * 25 + 44, cap))
    }

    @ViewBuilder private func steps(seconds: [Int?]) -> some View {
        let current = stage.step - 1
        ForEach(0..<stage.total, id: \.self) { index in
            let dot: StageDot = index < current ? .done : index == current ? .current : .pending
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StageCheck(dot: dot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.name(index))
                        .strikethrough(dot == .done)
                        .fontWeight(dot == .current ? .semibold : .regular)
                        .foregroundStyle(dot == .done ? AnyShapeStyle(.secondary) : dot == .current ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(.primary))
                    if dot == .current, let note = stage.note {
                        Text(note).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if dot != .pending, seconds.indices.contains(index), let spent = seconds[index] {
                    Text(Format.duration(spent)).font(.ui(.caption).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.vertical, 3.5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([stage.name(index), dot == .done ? L("已完成") : dot == .current ? L("进行中") : L("未开始")].joined(separator: "，"))
        }
    }

    /// 一部分（一个端）：做完的划掉；右边写做到哪了
    private func partRow(_ part: StagePart) -> some View {
        let current = part.name == stage.part
        let dot: StageDot = part.done ? .done : current ? .current : .pending
        let status = part.done ? L("已完成")
            : current ? "\(stage.step)/\(stage.total)"
            : part.step == 0 ? L("未开始") : "\(part.step)/\(stage.total) " + stage.planned(part.step - 1)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            StageCheck(dot: dot)
            Text(part.name)
                .strikethrough(part.done)
                .fontWeight(current ? .semibold : .medium)
                .foregroundStyle(part.done ? AnyShapeStyle(.secondary) : current ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(status).font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 3.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(part.name + "，" + (part.done ? L("已完成") : part.step == 0 ? L("未开始") : status))
    }
}

/// 清单前的圈：做完的打勾（灰，和划掉的字一起淡下去）、正在做的主题色、没到的空圈（同任务清单）
private struct StageCheck: View {
    let dot: StageDot

    var body: some View {
        switch dot {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        case .current: Image(systemName: "circle.dotted.circle").foregroundStyle(Theme.claude)
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

/// 收起那行最前面的小圈：转到这一步的一半（做到第几步一眼看出来）
private struct StageRing: View {
    let step: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle().stroke(Theme.claude.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: max(0, (CGFloat(step) - 0.5) / CGFloat(max(1, total))))
                .stroke(Theme.claude, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .animation(.snappy, value: step)
    }
}
