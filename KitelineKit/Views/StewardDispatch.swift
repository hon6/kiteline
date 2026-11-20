import SwiftUI

// 总管派活的过程（11-20 反馈：开始任务后球变小、升到顶上，照样转；下面显示它调度其他会话、派发任务的过程——
//   要好看、清楚，不要纯文字罗列，未来感强一些）。见 StewardHome（StewardViews.swift）。
//   · 每个被派活的会话一张玻璃卡片：圆环是它这一轮做到第几步，一行字是它现在在干什么（等你确认变橙色，回报后变绿色打勾），点了进那个会话
//   · 顶上的球到每张卡片一道光束：平时虚线慢慢流、零星光点往下走（在干活）；派活那一下一串光点冲下去，回报那一下冲回球里
//   · 拉了群的几个会话之间一道虚线
//   · 最底下一条播报：总管刚做的那件事（派给谁、新开、拉群、谁回报了），新的从下面推上来
//   · 都回报完了：一张验收结果卡，写总管最后说的话

private let doneGreen = Color(red: 0.50, green: 0.73, blue: 0.56)

struct StewardDispatchBoard: View {
    /// 卡片位置、球的位置都在这个坐标系里算（StewardHome 的 ZStack）
    static let space = "stewardBoard"

    let tasks: [StewardTask]
    let events: [StewardEvent]
    /// 光束的起点：顶上那颗球的底边
    let anchor: CGPoint
    let headline: String
    let ask: String?
    let reply: String?
    let stewardBusy: Bool
    var open: (String) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @State private var frames: [String: CGRect] = [:]

    private var finished: Bool { !tasks.isEmpty && tasks.allSatisfy { $0.state == "reported" || $0.state == "failed" } && !stewardBusy }

    var body: some View {
        ZStack(alignment: .top) {
            StewardBeams(tasks: tasks, events: events, anchor: anchor, frames: frames, model: model)
                .allowsHitTesting(false)
            VStack(spacing: 12) {
                // 球下面两行字：在调度几个会话 / 你这次说的话（底下垫一层页面底色，光束从字后面穿过去，不把字划花）
                VStack(spacing: 3) {
                    Text(verbatim: headline)
                        .font(.ui(.caption).weight(.semibold)).foregroundStyle(finished ? doneGreen : Theme.claude)
                        .contentTransition(.numericText())
                    if let ask, !ask.isEmpty {
                        Text(verbatim: "「\(ask)」").font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Theme.pageBackground.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, anchor.y + 6)
                .padding(.horizontal, 24)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                        ForEach(tasks) { task in
                            StewardNodeCard(task: task) { if !task.key.isEmpty { open(task.key) } }
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[task.id] = $0 }
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 44)   // 卡片和上面的字隔开一段，光束有地方散开、弯下来
                    .padding(.bottom, 12)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: tasks.map(\.id))
                }
                .scrollBounceBehavior(.basedOnSize)
                if finished, let reply { summary(reply) } else { ticker }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    /// 最底下一条播报：总管刚做的那件事，新的从下面推上来
    private var ticker: some View {
        let last = events.last
        return HStack(spacing: 9) {
            Image(systemName: Self.symbol(last?.kind))
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(last?.kind == "report" ? doneGreen : (last?.kind == "failed" ? .red : Theme.claude))
                .frame(width: 22, height: 22)
                .background((last?.kind == "report" ? doneGreen : Theme.claude).opacity(0.14), in: Circle())
            Text(verbatim: last?.text ?? L("等待指令"))
                .font(.ui(.footnote)).lineLimit(1)
                .id(last?.id ?? "")
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .clipped()
        .modifier(GlassCard(radius: 20))
        .animation(.smooth(duration: 0.45), value: last?.id)
    }

    /// 都回报完了：验收结果（总管最后说的话）
    private func summary(_ reply: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("已验收，全部完成"), systemImage: "checkmark.seal.fill")
                .font(.ui(.subheadline).weight(.semibold)).foregroundStyle(doneGreen)
            Text(verbatim: reply).font(.ui(.footnote)).lineLimit(4)
            Text(L("%lld 个会话 · 用时 %@", tasks.count, Self.duration(tasks)))
                .font(.ui(.caption2)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCard(radius: 20, tint: doneGreen))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    static func symbol(_ kind: String?) -> String {
        switch kind {
        case "assign": "arrow.down.right"
        case "new": "plus"
        case "group": "point.3.connected.trianglepath.dotted"
        case "report": "arrow.up.left"
        case "failed": "exclamationmark"
        default: "circle.dotted"
        }
    }

    static func duration(_ tasks: [StewardTask]) -> String {
        guard let start = tasks.map(\.at).min(), let end = tasks.map({ $0.reportAt ?? $0.at }).max() else { return "—" }
        let minutes = max(1, Int((end - start) / 60_000))
        return minutes < 60 ? L("%lld 分钟", count: minutes) : L("%lld 小时", count: minutes / 60)
    }
}

/// 玻璃卡片：半透明底 + 细边（液态玻璃的样子，选中 / 带色时边框带色）
private struct GlassCard: ViewModifier {
    var radius: CGFloat
    var tint: Color? = nil
    var glow: Double = 0

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background((tint ?? .primary).opacity(tint == nil ? 0.03 : 0.08), in: shape)
            .overlay { shape.strokeBorder((tint ?? .primary).opacity(tint == nil ? 0.10 : 0.40), lineWidth: 1) }
            .shadow(color: (tint ?? Theme.claude).opacity(0.35 * glow), radius: 14)
    }
}

/// 一个被派活的会话
struct StewardNodeCard: View {
    let task: StewardTask
    var tap: () -> Void = {}
    @Environment(AppModel.self) private var model
    @State private var glow = 0.0

    var body: some View {
        let session = task.key.isEmpty ? nil : model.session(task.key)
        let look = Self.look(task, session)
        Button(action: tap) {
            HStack(alignment: .top, spacing: 9) {
                StewardProgressRing(progress: look.progress, label: look.ring, color: look.color, spinning: look.spinning)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: session?.title ?? (task.title.isEmpty ? task.project : task.title))
                        .font(.ui(.footnote).weight(.semibold)).lineLimit(1)
                    Text(verbatim: [session?.sourceName ?? task.device, task.project].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                    Text(verbatim: look.line)
                        .font(.ui(.caption2)).foregroundStyle(look.color).lineLimit(2)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .modifier(GlassCard(radius: 18, tint: look.tint, glow: glow))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 刚派到、刚回报：卡片亮一下
        .onChange(of: task.reportAt ?? task.at, initial: true) { _, at in
            guard Date().timeIntervalSince1970 * 1000 - at < 4000 else { return }
            withAnimation(.easeOut(duration: 0.25)) { glow = 1 }
            withAnimation(.easeIn(duration: 1.4).delay(0.4)) { glow = 0 }
        }
    }

    struct Look {
        var progress: Double
        var ring: String
        var line: String
        var color: Color
        var tint: Color?
        var spinning = false
    }

    /// 卡片的样子：圆环进度、圆环里的字、下面那行字和颜色
    static func look(_ task: StewardTask, _ session: SessionInfo?) -> Look {
        if task.state == "failed" {
            return Look(progress: 1, ring: "!", line: task.note ?? L("没有派出去"), color: .red, tint: .red)
        }
        if task.state == "queued" {
            return Look(progress: session.map(stageProgress) ?? 0, ring: "…", line: L("排队中 · 等你先处理它的确认"), color: .orange, tint: .orange)
        }
        if task.state == "reported" {
            return Look(progress: 1, ring: "✓", line: task.report.map { L("回报：%@", $0) } ?? L("已回报"), color: doneGreen, tint: doneGreen)
        }
        guard let session else {
            return task.key.isEmpty ? Look(progress: 0.25, ring: "", line: L("正在开新会话…"), color: .secondary, tint: nil, spinning: true)
                                    : Look(progress: 0, ring: "", line: L("会话已关闭"), color: .secondary, tint: nil)
        }
        if session.isWaiting {
            return Look(progress: stageProgress(session), ring: stageText(session) ?? "!", line: L("等你确认 · %@", session.pendingTool ?? ""),
                        color: .orange, tint: .orange)
        }
        if session.isBusy {
            let detail = session.stage.map { [$0.label, $0.note ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") } ?? session.activityText ?? L("正在工作")
            return Look(progress: stageProgress(session), ring: stageText(session) ?? "", line: detail, color: Theme.claude, tint: Theme.claude,
                        spinning: session.stage == nil)
        }
        return Look(progress: stageProgress(session), ring: stageText(session) ?? "…", line: L("空闲 · 等它回报"), color: .secondary, tint: nil)
    }

    private static func stageProgress(_ session: SessionInfo) -> Double {
        guard let stage = session.stage, stage.total > 0 else { return 0 }
        return Double(stage.step) / Double(stage.total)
    }

    private static func stageText(_ session: SessionInfo) -> String? {
        guard let stage = session.stage, stage.total > 0 else { return nil }
        return "\(stage.step)/\(stage.total)"
    }
}

/// 圆环进度：底下一圈淡的，上面按进度画；spinning = 还不知道做到哪（开新会话、没报阶段），一段弧绕着转
struct StewardProgressRing: View {
    var progress: Double
    var label: String
    var color: Color
    var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: 2.5)
            if spinning {
                TimelineView(.animation) { context in
                    let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(angle - 90))
                }
            } else {
                Circle().trim(from: 0, to: max(0.001, progress))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.8), value: progress)
            }
            Text(verbatim: label).font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(color == .secondary ? .primary : color)
        }
    }
}

/// 球到各张卡片的光束、群里会话之间的虚线、流动的光点。一直在动（TimelineView），不接点按
private struct StewardBeams: View {
    let tasks: [StewardTask]
    let events: [StewardEvent]
    let anchor: CGPoint
    let frames: [String: CGRect]
    let model: AppModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let now = context.date.timeIntervalSince1970 * 1000
            Canvas { gc, _ in draw(&gc, t: t, now: now) }
        }
    }

    private func draw(_ gc: inout GraphicsContext, t: Double, now: Double) {
        let accent = Theme.claude
        for task in tasks {
            guard let frame = frames[task.id] else { continue }
            let end = CGPoint(x: frame.midX, y: frame.minY)
            let session = task.key.isEmpty ? nil : model.session(task.key)
            let color: Color = task.state == "reported" ? doneGreen : (task.state == "failed" ? .red : (session?.isWaiting == true ? .orange : accent))
            let c1 = CGPoint(x: anchor.x, y: anchor.y + (end.y - anchor.y) * 0.55)
            let c2 = CGPoint(x: end.x, y: end.y - (end.y - anchor.y) * 0.45)
            var path = Path()
            path.move(to: anchor)
            path.addCurve(to: end, control1: c1, control2: c2)
            // 底下一道很淡的实线做光晕，上面一道流动的虚线
            gc.stroke(path, with: .color(color.opacity(task.state == "reported" || task.state == "failed" ? 0.06 : 0.12)), lineWidth: 4)
            gc.stroke(path, with: .color(color.opacity(task.state == "reported" || task.state == "failed" ? 0.28 : 0.55)),
                      style: StrokeStyle(lineWidth: 1.2, dash: [3, 4], dashPhase: -t * 18))
            // 光点：派活那一下一串冲下去；回报那一下冲回球里；平时在干活的会话零星几颗慢慢往下走
            let sinceSent = (now - task.at) / 1000
            let sinceReport = task.reportAt.map { (now - $0) / 1000 } ?? 99
            let burstDown = max(0, 1 - sinceSent / 1.8), burstUp = max(0, 1 - sinceReport / 1.8)
            let working = (task.state == "sent" && session?.isBusy == true) || task.key.isEmpty
            var dots: [(Double, Double, Double)] = []   // (位置 0 球 … 1 卡片, 亮度, 大小)
            if burstDown > 0 {
                for k in 0..<10 { dots.append(((t * 0.9 + Double(k) / 10).truncatingRemainder(dividingBy: 1), 0.95 * burstDown + 0.05, 7)) }
            } else if burstUp > 0 {
                for k in 0..<10 { dots.append((1 - (t * 0.9 + Double(k) / 10).truncatingRemainder(dividingBy: 1), 0.95 * burstUp + 0.05, 7)) }
            } else if working {
                for k in 0..<3 { dots.append(((t * 0.22 + Double(k) / 3).truncatingRemainder(dividingBy: 1), 0.6, 4.5)) }
            }
            for (s, alpha, size) in dots {
                let p = bezier(anchor, c1, c2, end, s)
                let rect = CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)
                gc.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [color.opacity(alpha), color.opacity(0)]),
                                                                       center: p, startRadius: 0, endRadius: size))
            }
            // 卡片上沿的落点：一颗小亮点
            gc.fill(Path(ellipseIn: CGRect(x: end.x - 2, y: end.y - 2, width: 4, height: 4)), with: .color(color.opacity(0.8)))
        }
        // 拉了群的：群里几个会话的卡片之间一道虚线（按卡片中心连）
        let byKey = Dictionary(tasks.compactMap { task in frames[task.id].map { (task.key, $0) } }, uniquingKeysWith: { a, _ in a })
        for event in events where event.kind == "group" {
            let rects = event.keys.compactMap { byKey[$0] }
            guard rects.count > 1 else { continue }
            for (a, b) in zip(rects, rects.dropFirst()) {
                var path = Path()
                path.move(to: CGPoint(x: a.midX, y: a.midY))
                path.addLine(to: CGPoint(x: b.midX, y: b.midY))
                gc.stroke(path, with: .color(Color.primary.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3], dashPhase: t * 10))
            }
        }
    }

    private func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ s: Double) -> CGPoint {
        let u = 1 - s
        let a = u * u * u, b = 3 * u * u * s, c = 3 * u * s * s, d = s * s * s
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }
}
