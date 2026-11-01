import SwiftUI

// 会话之间的消息的几样界面（数据见 Model/Peers.swift）：
// - PeerCard：对话里「→ 发给某会话」「← 来自某会话」的卡片，轻点卡头跳到对方会话
// - peerAnchor / PeerStage：会话列表的每行报出头像位置，上面一层画纸鸢传信（飞过去）和风筝线（左边连起有往来的会话）
// - PeerSettingsSection：设置里的开关（iPhone；Mac 的设置页自己放同样三个开关，存的键一样）

// MARK: - 对话里的卡片

struct PeerCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    let key: String
    let item: ChatItem
    @State private var expanded = false

    private var peer: PeerInfo { item.peer ?? PeerInfo() }
    private var outgoing: Bool { peer.dir != "in" }
    private var otherKey: String? { model.peerKey(peer.session, near: key) }

    /// 信纸的底色：比普通气泡暖一点、浅一点，一眼看出是一封信
    static let paper = Theme.dynamic(light: 0xFBF8F2, dark: 0x262422)

    var body: some View {
        let other = model.peerTitle(otherKey, fallback: peer.name)
        let me = model.session(key)?.title ?? L("本会话")
        // 这封信（往来）的 id：发出的那张、收到的那张一样，分屏里两张都看得见时用绳子连起来
        let ropeId = outgoing ? model.peers.link(tool: item.toolId, msgId: model.chat(key).results[item.toolId ?? ""]?.msgId)?.id : peer.msgId
        // 一封信：抬头「致 / 来自 某会话」，右上角盖纸鸢邮戳（寄出时间）；主题、正文；发出的落款是本会话
        VStack(alignment: .leading, spacing: ChatType.px(8)) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    if let otherKey { open(.chat(otherKey)) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(outgoing ? L("致") : L("来自")).foregroundStyle(.secondary)
                        Text(other).fontWeight(.semibold).lineLimit(1)
                        if otherKey != nil { Image(systemName: "chevron.right").font(.ui(.caption2)).foregroundStyle(.tertiary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(otherKey == nil)
                .accessibilityLabel(outgoing ? L("发给 %@", other) : L("来自 %@", other))
                Spacer(minLength: 4)
                PeerPostmark(time: item.ts)
            }
            // 信纸上的一道折痕
            Line().stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                .frame(height: 0.6)
            if let subject = subject, !subject.isEmpty {
                Text(subject).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            }
            Text(bodyText)
                .lineLimit(expanded ? nil : 5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if outgoing {
                Text(verbatim: "—— " + me).font(.ui(.footnote)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1)
            }
            HStack(spacing: 10) {
                status
                Spacer(minLength: 0)
                if canExpand {
                    Button(expanded ? L("收起") : L("展开全文")) { withAnimation(.snappy) { expanded.toggle() } }
                        .buttonStyle(.plain).foregroundStyle(Theme.claude)
                }
            }
            .font(.ui(.caption))
        }
        .padding(.horizontal, ChatType.padH + ChatType.px(2))
        .padding(.vertical, ChatType.padV + ChatType.px(4))
        .frame(maxWidth: ChatType.px(380), alignment: .leading)
        .background(Self.paper, in: RoundedRectangle(cornerRadius: ChatType.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ChatType.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.7).allowsHitTesting(false))
        .peerRopeEnd(ropeId, outgoing: outgoing, peer: otherKey)
    }

    /// 主题：发出的用 SendMessage 的摘要；收到的从往来里找（发信那边写的摘要）
    private var subject: String? {
        if outgoing { return peer.summary }
        return peer.msgId.flatMap { model.peers.links[$0]?.summary }
    }

    /// 发出的全文在工具调用的 input.message；收到的全文在 peer.body
    private var fullText: String {
        outgoing ? (item.input?["message"]?.string ?? peer.text ?? "") : (peer.body ?? peer.text ?? item.text ?? "")
    }
    private var bodyText: String { fullText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canExpand: Bool { bodyText.count > 170 || bodyText.filter { $0 == "\n" }.count > 4 }

    /// 发出的：已发出 → 对方已读 → 已回复；没送到标红。收到的：回过没有
    @ViewBuilder private var status: some View {
        if outgoing {
            let result = model.chat(key).results[item.toolId ?? ""]
            let link = model.peers.link(tool: item.toolId, msgId: result?.msgId)
            if result?.isError == true || link?.ok == false {
                Label("未送达", systemImage: "exclamationmark.circle").foregroundStyle(Theme.removed)
            } else if let link, model.peers.reply(to: link) != nil {
                Label("对方已回复", systemImage: "arrowshape.turn.up.left").foregroundStyle(.secondary)
            } else if link?.readAt != nil {
                Label("对方已读", systemImage: "envelope.open").foregroundStyle(.secondary)
            } else if result != nil || link != nil {
                Label("已送达，等待对方处理", systemImage: "envelope").foregroundStyle(.secondary)
            } else {
                Label("正在发送…", systemImage: "paperplane").foregroundStyle(.tertiary)
            }
        } else if let msgId = peer.msgId, let link = model.peers.links[msgId], model.peers.reply(to: link) != nil {
            Label("已回复", systemImage: "arrowshape.turn.up.left").foregroundStyle(.secondary)
        }
    }
}

/// 信上的邮戳：一圈虚线圆里一只小纸鸢，下面是寄出的时间，略微歪着盖
private struct PeerPostmark: View {
    let time: Double?

    var body: some View {
        VStack(spacing: 0) {
            KiteMark(color: Theme.claude.opacity(0.8)).frame(width: 15, height: 15)
            if let time { Text(Format.clock(time)).font(.app(size: 8.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.claude.opacity(0.75)) }
        }
        .frame(width: 38, height: 38)
        .overlay(Circle().strokeBorder(Theme.claude.opacity(0.45), style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2])))
        .rotationEffect(.degrees(-12))
        .accessibilityHidden(true)
    }
}

/// 一道水平线（折痕）
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - 列表上的位置

/// 列表、分屏标签报出各会话头像在窗口里的位置（纸鸢从哪飞到哪、风筝线连哪）。故意不做成可观察的：
/// 滚动时每行每帧都写一次，可观察的话盖在整个窗口上的那一层每帧跟着重算，Mac 上连带整窗工具栏一起刷新（11-01 滚动卡顿、闪退）。
/// 风筝线图层登记在 laneHosts 里，位置一变自己跟着挪（只动图层、不经 SwiftUI）；纸鸢飞的那几秒逐帧画，画时直接读最新位置
@MainActor
final class PeerFrames {
    static let shared = PeerFrames()
    var rows: [String: CGRect] = [:] {
        didSet { for host in laneHosts.allObjects { host.rowsChanged() } }
    }
    /// Mac 分屏的标签（会话开在分屏里时，纸鸢在标签之间飞）
    var tabs: [String: CGRect] = [:]
    /// 正在画风筝线的图层（弱引用，一般只有一个）
    let laneHosts = NSHashTable<PeerLaneHost>.weakObjects()
}

extension View {
    /// 会话列表的一行：报出头像的位置（窗口坐标）
    func peerAnchor(_ key: String, tab: Bool = false) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if tab { PeerFrames.shared.tabs[key] = frame } else { PeerFrames.shared.rows[key] = frame }
        }
        .onDisappear {
            if tab { PeerFrames.shared.tabs[key] = nil } else { PeerFrames.shared.rows[key] = nil }
        }
    }
}

// MARK: - 纸鸢传信、风筝线

/// 盖在会话列表上的一层：纸鸢从发信会话的头像飞到收信会话的头像（拖着一根线），落下时收信那行闪一圈；
/// 风筝线贴着头像那一列走：发给上面会话的线在头像左边（上行），发给下面会话的在右边（下行），都是虚线、一直朝消息方向滚动，
/// 虚线朝收信的一方流动（不画箭头：10-27 觉得不和谐）；最近 15 分钟里有往来的才画，越久越淡。滚动交给 Core Animation（不逐帧重画，常驻也不费电）。
/// order：列表里会话的先后（对方那行滚出屏幕时，知道它在上面还是下面）
/// 不跟系统的「减弱动态效果」：虚线滚动、纸鸢传信要不要，由设置里的开关决定（10-24 起：Mac 开着减弱动态效果也要动）
struct PeerStage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PeerPrefs.flightsKey) private var flightsOn = true
    @AppStorage(PeerPrefs.lanesKey) private var lanesOn = true
    var order: [String]
    /// Mac：会话开在分屏里时在标签之间飞
    var useTabs = false

    /// 风筝线留多久（毫秒）
    static let laneWindow: Double = 15 * 60_000

    var body: some View {
        // 每半分钟看一次哪些线该淡掉、该收掉；纸鸢在飞、收信那行在闪时才逐帧画（几秒）
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let now = Date().timeIntervalSince1970 * 1000
            // 两头都在当前列表里的才画（筛选掉的、别的机器的不画）
            let directions = lanesOn ? model.peers.recentDirections(within: Self.laneWindow, now: now)
                .filter { order.contains($0.from) && order.contains($0.to) } : []
            let flights = flightsOn ? model.peers.flights : []
            let pulses = model.peers.pulses
            ZStack {
                if !directions.isEmpty {
                    // 线的位置由图层自己跟着列表滚动更新（见 PeerFrames），这里只在方向、这一层的位置变了时重给
                    GeometryReader { proxy in
                        PeerLanes(directions: directions, origin: proxy.frame(in: .global).origin, height: proxy.size.height,
                                  now: now, color: Theme.claude, animate: true)
                    }
                }
                if !flights.isEmpty || !pulses.isEmpty {
                    GeometryReader { proxy in
                        TimelineView(.animation) { context in
                            canvas(proxy: proxy, flights: flights, pulses: pulses, date: context.date)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .overlay(alignment: .bottom) { offscreenChips(flights) }
        }
    }

    // MARK: 风筝线

    /// 每个方向一条线：从发信会话头像的一侧出发、沿头像列走到收信会话头像的同一侧。
    /// 两头都显示在屏幕上才画：一头滚出去了就先不画（不往屏幕边上拉长线，免得穿过标题、卡片）。
    /// origin、height：这一层在窗口里的位置和高度（行的位置是窗口坐标，换成这一层的）
    static func lanes(_ directions: [PeerDirection], origin: CGPoint, height: CGFloat, now: Double) -> [PeerLane] {
        let rows = PeerFrames.shared.rows.mapValues { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            .filter { $0.value.maxY > 0 && $0.value.minY < height }
        var used = (up: 0, down: 0)
        var out: [PeerLane] = []
        for direction in directions {
            guard let sender = rows[direction.from], let receiver = rows[direction.to] else { continue }
            // 收信的在上面 = 上行（走左边），在下面 = 下行（走右边）
            let up = receiver.midY < sender.midY
            let lane = up ? used.up : used.down
            if up { guard used.up < 3 else { continue }; used.up += 1 } else { guard used.down < 2 else { continue }; used.down += 1 }
            let x = up ? min(sender.minX, receiver.minX) - 3.5 - CGFloat(lane) * 4 : max(sender.maxX, receiver.maxX) + 3.5 + CGFloat(lane) * 4
            let edgeX = { (frame: CGRect) in up ? frame.minX - 0.5 : frame.maxX + 0.5 }
            let start = CGPoint(x: edgeX(sender), y: sender.midY)
            let end = CGPoint(x: edgeX(receiver), y: receiver.midY)
            let turn: CGFloat = up ? -8 : 8
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: CGPoint(x: x, y: start.y + turn), control: CGPoint(x: x, y: start.y))
            path.addLine(to: CGPoint(x: x, y: end.y - turn))
            path.addQuadCurve(to: end, control: CGPoint(x: x, y: end.y))
            let age = now - direction.last
            out.append(PeerLane(id: direction.from + ">" + direction.to, path: path, head: nil,
                                alpha: 0.9 * max(0.35, 1 - age / Self.laneWindow)))
        }
        return out
    }

    // MARK: 纸鸢、收信那一闪

    private func canvas(proxy: GeometryProxy, flights: [PeerFlight], pulses: [String: Date], date: Date) -> some View {
        let origin = proxy.frame(in: .global).origin
        let size = proxy.size
        let rows = PeerFrames.shared.rows.mapValues { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        let tabs = useTabs ? PeerFrames.shared.tabs.mapValues { $0.offsetBy(dx: -origin.x, dy: -origin.y) } : [:]
        let accent = Theme.claude
        return Canvas { context, _ in
            // 收信那行闪一圈
            for (key, at) in pulses {
                guard let frame = rows[key] ?? tabs[key] else { continue }
                let t = min(max(date.timeIntervalSince(at) / 0.9, 0), 1)
                ring(&context, center: CGPoint(x: frame.midX, y: frame.midY), radius: frame.width / 2 + 2 + 8 * t, alpha: 1 - t, color: accent)
            }
            // 纸鸢
            for flight in flights {
                let t = model.peers.frozen ?? date.timeIntervalSince(flight.start) / PeerFlight.duration
                guard t >= 0, t <= 1.45 else { continue }
                guard let from = point(flight.from, rows: rows, tabs: tabs, height: size.height),
                      let to = point(flight.to, rows: rows, tabs: tabs, height: size.height) ?? edge(flight.to, size: size) else { continue }
                draw(&context, flight: flight, from: from, to: to, t: t, accent: accent, toFrame: flight.to.flatMap { tabs[$0] ?? rows[$0] })
            }
        } symbols: {
            KiteMark(color: accent).frame(width: 26, height: 26).tag(0)
        }
    }

    private func point(_ key: String?, rows: [String: CGRect], tabs: [String: CGRect], height: CGFloat) -> CGPoint? {
        guard let key else { return nil }
        if let tab = tabs[key] { return CGPoint(x: tab.midX, y: tab.midY) }
        if let row = rows[key] { return CGPoint(x: row.midX, y: row.midY) }
        return nil
    }

    /// 对方不在屏幕上：飞向下沿（看不出在上还是在下时）或按列表先后飞向上沿 / 下沿
    private func edge(_ key: String?, size: CGSize) -> CGPoint? {
        let rows = PeerFrames.shared.rows
        if let key, let index = order.firstIndex(of: key), let first = order.firstIndex(where: { rows[$0] != nil }), index < first {
            return CGPoint(x: size.width * 0.5, y: 8)
        }
        return CGPoint(x: size.width * 0.5, y: size.height - 8)
    }

    private func draw(_ context: inout GraphicsContext, flight: PeerFlight, from: CGPoint, to: CGPoint, t raw: Double, accent: Color, toFrame: CGRect?) {
        let t = min(raw, 1)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        // 弧线往右鼓（列表里往内容那边飞，看得见）；距离越远鼓得越多
        let distance = hypot(to.x - from.x, to.y - from.y)
        let bulge = min(max(distance * 0.45, 70), 160)
        let c1 = CGPoint(x: from.x + bulge, y: from.y + (to.y - from.y) * 0.15 - 20)
        let c2 = CGPoint(x: to.x + bulge, y: to.y - (to.y - from.y) * 0.15 - 20)
        func bezier(_ s: Double) -> CGPoint {
            let u = 1 - s
            return CGPoint(x: u * u * u * from.x + 3 * u * u * s * c1.x + 3 * u * s * s * c2.x + s * s * s * to.x,
                           y: u * u * u * from.y + 3 * u * u * s * c1.y + 3 * u * s * s * c2.y + s * s * s * to.y)
        }
        let here = bezier(eased)
        let ahead = bezier(min(eased + 0.02, 1))
        let fadeOut = raw > 1 ? max(0, 1 - (raw - 1) / 0.45) : 1
        // 风筝线：从发信那头拖到纸鸢，跟着飞过的路
        var string = Path()
        string.move(to: from)
        let steps = max(Int(eased * 24), 1)
        for i in 1...steps { string.addLine(to: bezier(eased * Double(i) / Double(steps))) }
        context.stroke(string, with: .color(accent.opacity(0.55 * fadeOut)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        // 纸鸢：顺着飞的方向转，飞到一半最大
        if raw <= 1, let kite = context.resolveSymbol(id: 0) {
            var layer = context
            layer.translateBy(x: here.x, y: here.y)
            layer.rotate(by: .radians(atan2(ahead.y - here.y, ahead.x - here.x) + .pi / 4))
            let scale = 0.8 + 0.45 * sin(eased * .pi)
            layer.scaleBy(x: scale, y: scale)
            layer.draw(kite, at: .zero)
        }
        // 落下：收信头像上一圈涟漪
        if raw > 0.9 {
            let s = min((raw - 0.9) / 0.55, 1)
            let radius = (toFrame.map { $0.width / 2 } ?? 14) + 3 + 10 * s
            ring(&context, center: to, radius: radius, alpha: 1 - s, color: accent)
        }
    }

    private func ring(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, alpha: Double, color: Color) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.8 * alpha)), lineWidth: 1.6)
    }

    /// 对方那行不在屏幕上：纸鸢飞到边上以后留一个小胶囊「↓ 会话名」，轻点打开它
    @ViewBuilder private func offscreenChips(_ flights: [PeerFlight]) -> some View {
        let rows = PeerFrames.shared.rows
        let missing = flights.filter { flight in
            guard let to = flight.to else { return true }
            return rows[to] == nil && (!useTabs || PeerFrames.shared.tabs[to] == nil)
        }
        if let flight = missing.last {
            PeerChip(flight: flight)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// 一条风筝线（窗口内这一层的坐标）：路径从发信那头画到收信那头，虚线沿路径往前滚
struct PeerLane: Identifiable, Equatable {
    let id: String
    let path: CGPath
    let head: CGPath?
    let alpha: CGFloat
}

/// 画风筝线要的东西（SwiftUI 那边给，列表滚动时不变；行的位置由图层自己从 PeerFrames 读）
struct PeerLaneInput {
    let directions: [PeerDirection]
    let origin: CGPoint
    let height: CGFloat
    let now: Double
    let color: CGColor
    let animate: Bool
}

#if os(iOS)
private struct PeerLanes: UIViewRepresentable {
    let directions: [PeerDirection]
    let origin: CGPoint
    let height: CGFloat
    let now: Double
    let color: Color
    let animate: Bool

    func makeUIView(context: Context) -> PeerLaneHost {
        let view = PeerLaneHost()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        PeerFrames.shared.laneHosts.add(view)
        return view
    }

    func updateUIView(_ view: PeerLaneHost, context: Context) {
        view.input = PeerLaneInput(directions: directions, origin: origin, height: height, now: now, color: UIColor(color).cgColor, animate: animate)
    }
}

final class PeerLaneHost: UIView {
    let painter = PeerLanePainter()
    var input: PeerLaneInput? { didSet { redraw() } }

    /// 列表滚动、行的位置变了：只挪图层
    func rowsChanged() { if input != nil { redraw() } }

    private func redraw() {
        guard let input else { return }
        painter.update(PeerStage.lanes(input.directions, origin: input.origin, height: input.height, now: input.now),
                       color: input.color, animate: input.animate, in: layer, flipHeight: nil)
    }
}
#else
private struct PeerLanes: NSViewRepresentable {
    let directions: [PeerDirection]
    let origin: CGPoint
    let height: CGFloat
    let now: Double
    let color: Color
    let animate: Bool

    func makeNSView(context: Context) -> PeerLaneHost {
        let view = PeerLaneHost()
        view.wantsLayer = true
        PeerFrames.shared.laneHosts.add(view)
        return view
    }

    func updateNSView(_ view: PeerLaneHost, context: Context) {
        view.input = PeerLaneInput(directions: directions, origin: origin, height: height, now: now, color: NSColor(color).cgColor, animate: animate)
    }
}

final class PeerLaneHost: NSView {
    let painter = PeerLanePainter()
    var input: PeerLaneInput? { didSet { redraw() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 高度变了要重新翻（SwiftUI 先给新数据、后改尺寸）
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        redraw()
    }

    /// 列表滚动、行的位置变了：只挪图层
    func rowsChanged() { if input != nil { redraw() } }

    private func redraw() {
        guard let input, let layer else { return }
        // 图层的坐标 y 朝上：路径按视图高度翻过来
        painter.update(PeerStage.lanes(input.directions, origin: input.origin, height: input.height, now: input.now),
                       color: input.color, animate: input.animate, in: layer, flipHeight: bounds.height)
    }
}
#endif

/// 每条风筝线两个图层（虚线 + 箭头）；虚线的滚动是挂在图层上的循环动画，由系统合成，不占主线程
@MainActor
final class PeerLanePainter {
    private var layers: [String: (line: CAShapeLayer, head: CAShapeLayer)] = [:]
    private static let period: CGFloat = 8   // 一段虚线 + 一段空白

    func update(_ lanes: [PeerLane], color: CGColor, animate: Bool, in host: CALayer, flipHeight: CGFloat?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var flip = CGAffineTransform.identity
        if let height = flipHeight { flip = CGAffineTransform(translationX: 0, y: height).scaledBy(x: 1, y: -1) }
        let live = Set(lanes.map(\.id))
        for (id, pair) in layers where !live.contains(id) {
            pair.line.removeFromSuperlayer()
            pair.head.removeFromSuperlayer()
            layers[id] = nil
        }
        for lane in lanes {
            let pair = layers[lane.id] ?? {
                let line = CAShapeLayer(), head = CAShapeLayer()
                line.fillColor = nil
                line.lineWidth = 1.6
                line.lineCap = .round
                line.lineJoin = .round
                line.lineDashPattern = [4, 4]
                host.addSublayer(line)
                host.addSublayer(head)
                return (line, head)
            }()
            layers[lane.id] = pair
            var transform = flip
            pair.line.path = lane.path.copy(using: &transform)
            pair.line.strokeColor = color.copy(alpha: lane.alpha)
            pair.head.path = lane.head.flatMap { path in var t = flip; return path.copy(using: &t) }
            pair.head.fillColor = color.copy(alpha: lane.alpha)
            // 虚线朝收信的那头滚：相位从一整段减到 0（相位变小 = 往路径终点走）
            if animate, pair.line.animation(forKey: "flow") == nil {
                let flow = CABasicAnimation(keyPath: "lineDashPhase")
                flow.fromValue = Self.period
                flow.toValue = 0
                flow.duration = 0.55
                flow.repeatCount = .infinity
                pair.line.add(flow, forKey: "flow")
            } else if !animate {
                pair.line.removeAnimation(forKey: "flow")
            }
        }
        CATransaction.commit()
    }
}

private struct PeerChip: View {
    @Environment(\.openRoute) private var open
    let flight: PeerFlight

    var body: some View {
        Button {
            if let to = flight.to { open(.chat(to)) }
        } label: {
            HStack(spacing: 5) {
                KiteMark(color: Theme.claude).frame(width: 14, height: 14)
                Text(L("发给 %@", flight.toLabel)).lineLimit(1)
            }
            .font(.ui(.caption).weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.claude.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .disabled(flight.to == nil)
    }
}

// MARK: - 设置

/// 设置里的三个开关（Mac 设置页放的是同样的三个，存的键一样）
struct PeerSettingsSection: View {
    @AppStorage(PeerPrefs.flightsKey) private var flights = true
    @AppStorage(PeerPrefs.lanesKey) private var lanes = true
    @AppStorage(PeerPrefs.cardsKey) private var cards = true
    @AppStorage(PeerPrefs.ropesKey) private var ropes = true

    var body: some View {
        Section {
            Toggle("纸鸢传信", isOn: $flights)
            Toggle("风筝线", isOn: $lanes)
            Toggle("对话中的信件", isOn: $cards)
            Toggle("分屏中的信绳", isOn: $ropes).disabled(!cards)
        } header: {
            Text("会话之间的消息")
        } footer: {
            Text("会话之间用 SendMessage 互发消息时：纸鸢从发信会话飞到收信会话；最近 15 分钟有往来的会话之间用流动的虚线连起，发给上方会话的在头像左侧、发给下方的在右侧；对话中显示为「致 / 来自」某会话的信件，轻点抬头可跳转。iPad 分屏同时打开两个会话时，同一封信的两张信件用一根绳子连起，可以拖动。")
        }
    }
}

#if KITELINE_MAC
// MARK: - Mac 主窗口用的几样（侧栏、分屏标签在 Mac App 那边）

extension View {
    /// Mac 侧栏的会话行：报出头像位置（纸鸢从这飞、风筝线接在这）
    public func tarsPeerAnchor(_ key: String) -> some View { peerAnchor(key) }
}

extension KitelineKit {
    /// 盖在 Mac 主窗口上的一层：纸鸢传信（会话开在分屏里时在标签之间飞）、侧栏左边的风筝线
    public struct PeerStageView: View {
        let order: [String]
        public init(order: [String]) { self.order = order }

        public var body: some View {
            if let model = KitelineKit.model {
                PeerStage(order: order, useTabs: true)
                    .environment(model)
                    .environment(\.openRoute, OpenRoute { route in
                        if case .chat(let key) = route { KitelineKit.openSession(key) }
                    })
            }
        }
    }
}
#endif
