import SwiftUI
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
import CoreMotion
#endif

// 分屏里的信绳：同一封信在发信那列（致…）和收信那列（来自…）各有一张卡片，用一根绳子连起来；
// 另一张滚出了那一列（或还没滚到）时，绳子钉在那一列对话区的上沿 / 下沿，一看就知道对面那份在上面还是下面（10-27）。
// 绳子是一串小点（Verlet 积分）：受重力自然垂着，两列各自滚动时两头跟着走、先绷着再慢慢放松；按住绳子中间能拖长，
// 松手弹回去、晃几下停下。平时细而淡、不挡字，鼠标停在这两张卡片或绳子上时才显眼（10-27）。
// 只有贴着绳子的几个点接鼠标，别处的点击、选字照常穿透。静止时不刷新、不费电；用 Core Animation 画，不走 SwiftUI 逐帧重画。

/// 卡片报的位置（分屏坐标）：不是观察出来的，滚动时写进来不引起重画；变了叫绳子那一层
@MainActor
final class PeerRopeBoard {
    static let shared = PeerRopeBoard()

    struct Card: Equatable {
        /// 卡片在分屏里的位置（ChatPanes.space）
        var frame: CGRect
        /// 在哪一列；那一列对话区的范围画的时候现取（卡片先于那一列量好时还没有）
        var pane: UUID
        weak var panes: ChatPanes?
        /// 哪一棵分屏视图（Mac 主窗口里可能同时有两棵，绳子只连同一棵里的卡片）
        var tree: UUID
        /// 信那头的会话（发出的是收信方，收到的是发信方）：另一张卡片不在画面里时，找开着它的那一列
        var peer: String?

        /// 那一列的消息区（标题条以下、输入栏以上）
        var clip: CGRect? { panes?.messageFrame(pane) }

        static func == (a: Card, b: Card) -> Bool {
            a.frame == b.frame && a.pane == b.pane && a.panes === b.panes && a.tree == b.tree && a.peer == b.peer
        }
    }

    /// "信的 id|out" / "信的 id|in" → 登记它的各张卡片（视图）：同一张信件可能同时有两份（两棵分屏视图、重排时新旧两份），各删各的
    private(set) var cards: [String: [UUID: Card]] = [:]
    /// 滚出画面、不再登记的卡片最后在那一列的下面（true）还是上面：另一头的绳子钉到哪条边
    private var below: [String: Bool] = [:]
    /// 鼠标停在哪封信的卡片上
    private(set) var hovered: String?
    /// 绳子层挂上来的：卡片动了、悬停变了就叫它们（界面重排时可能同时有新旧两层，释放了的自动剔除）
    private var listeners: [(owner: () -> AnyObject?, call: () -> Void)] = []

    func listen(_ owner: AnyObject, _ call: @escaping () -> Void) {
        weak var box = owner
        listeners.removeAll { $0.owner() == nil || $0.owner() === owner }
        listeners.append(({ box }, call))
    }

    private func changed() {
        listeners.removeAll { $0.owner() == nil }
        listeners.forEach { $0.call() }
    }

    /// 重力方向变了（手机斜过来）：绳子层醒过来重新垂
    func nudge() { changed() }

    func report(_ id: String, outgoing: Bool, card: Card?, owner: UUID) {
        let slot = id + (outgoing ? "|out" : "|in")
        var entries = cards[slot] ?? [:]
        guard entries[owner] != card else { return }
        if card == nil, let last = entries[owner], let clip = last.clip { below[slot] = last.frame.minY > clip.midY }
        entries[owner] = card
        cards[slot] = entries.isEmpty ? nil : entries
        changed()
    }

    /// 这一棵分屏视图里，某封信发出 / 收到的那张
    private func card(_ id: String, _ suffix: String, in tree: UUID) -> Card? {
        cards[id + suffix]?.values.first { $0.tree == tree }
    }

    /// 发出、收到两张都登记了的信
    var paired: [String] {
        cards.keys.filter { $0.hasSuffix("|out") }.map { String($0.dropLast(4)) }.filter { cards[$0 + "|in"] != nil }.sorted()
    }

    func hover(_ id: String, _ inside: Bool) {
        let next = inside ? id : (hovered == id ? nil : hovered)
        guard next != hovered else { return }
        hovered = next
        changed()
    }

    /// 这一棵分屏视图里，露出一部分的信 → 两头钉在哪：另一张也露着就钉在它上面；
    /// 另一张滚出去了、或者对方会话开在另一列但还没滚到那封信，钉在那一列对话区的上沿 / 下沿
    func ends(in tree: UUID) -> [String: (CGPoint, CGPoint)] {
        var out: [String: (CGPoint, CGPoint)] = [:]
        let ids = Set(cards.keys.map { String($0.dropLast($0.hasSuffix("|out") ? 4 : 3)) })
        for id in ids.sorted() {
            let from = card(id, "|out", in: tree), to = card(id, "|in", in: tree)
            if let from, let to, to.pane != from.pane, let fromClip = from.clip, let toClip = to.clip,
               from.frame.intersects(fromClip), to.frame.intersects(toClip) {
                let rightward = to.frame.midX > from.frame.midX
                out[id] = (Self.anchor(from.frame, fromClip, right: rightward), Self.anchor(to.frame, toClip, right: !rightward))
                continue
            }
            // 只露着一张：对面那列的边
            for (shown, other, slot) in [(from, to, "|in"), (to, from, "|out")] {
                guard let shown, let clip = shown.clip, shown.frame.intersects(clip),
                      let edge = edge(for: shown, other: other, otherSlot: id + slot) else { continue }
                let rightward = edge.midX > shown.frame.midX
                let start = Self.anchor(shown.frame, clip, right: rightward)
                let lower = other.map { $0.frame.minY > edge.midY } ?? below[id + slot] ?? false
                let x = rightward ? edge.minX + 14 : edge.maxX - 14
                let end = CGPoint(x: x, y: lower ? edge.maxY - 2 : edge.minY + 2)
                out[id] = slot == "|in" ? (start, end) : (end, start)
                break
            }
        }
        return out
    }

    /// 另一张卡片该在的那一列的对话区：它登记着就用它那一列，没登记就找对方会话开在哪一列（正显示的那个标签）
    private func edge(for shown: Card, other: Card?, otherSlot: String) -> CGRect? {
        if let other {
            guard other.pane != shown.pane else { return nil }
            return other.clip
        }
        guard let peer = shown.peer, let panes = shown.panes, let target = panes.pane(holding: peer),
              target.key == peer, target.id != shown.pane else { return nil }
        return panes.messageFrame(target.id)
    }

    /// 有成对的信件、但所在那一列的范围还没量好（刚分屏）：绳子层先别停，量好了就画
    func waiting(in tree: UUID) -> Bool {
        paired.contains { id in
            guard let from = card(id, "|out", in: tree), let to = card(id, "|in", in: tree) else { return false }
            return from.pane != to.pane && (from.clip == nil || to.clip == nil)
        } || cards.values.contains { entries in
            // 只登记了一张、对方会话开在另一列：那一列的范围还没量好
            entries.values.contains { card in
                guard card.tree == tree, let peer = card.peer, let panes = card.panes, let target = panes.pane(holding: peer) else { return false }
                return target.id != card.pane && (card.clip == nil || panes.messageFrame(target.id) == nil)
            }
        }
    }

    /// 钉在卡片朝着对方的那条边上、抬头那一行的高度；卡片滚出去一半时沿边滑到还看得见的地方
    private static func anchor(_ frame: CGRect, _ clip: CGRect, right: Bool) -> CGPoint {
        let x = right ? frame.maxX - 1 : frame.minX + 1
        let top = max(frame.minY + 8, clip.minY + 8)
        let bottom = min(frame.maxY - 8, clip.maxY - 8)
        return CGPoint(x: x, y: min(max(frame.minY + 26, top), max(top, bottom)))
    }
}

extension View {
    /// 分屏里的信：报出卡片位置（绳子接在这），鼠标停上来时那根绳子显眼。id 是这封信（往来）的 id，两张卡片一样；
    /// peer 是信那头的会话（另一张不在画面里时，绳子接到开着它的那一列）
    func peerRopeEnd(_ id: String?, outgoing: Bool, peer: String? = nil) -> some View {
        modifier(PeerRopeEnd(id: id, outgoing: outgoing, peer: peer))
    }
}

private struct PeerRopeEnd: ViewModifier {
    @Environment(\.chatPane) private var pane
    @Environment(\.peerRopeTree) private var tree
    @AppStorage(PeerPrefs.ropesKey) private var on = true
    let id: String?
    let outgoing: Bool
    let peer: String?
    /// 上次量到的位置：分屏数量、开关变了要重新登记，卡片自己可能没动（不会再报位置）
    @State private var frame: CGRect?
    /// 这张卡片（视图）的标记：只删自己登记的
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatPanes.space)) } action: { frame = $0; report($0) }
            .onChange(of: (pane?.panes.count ?? 0) * 2 + (on ? 1 : 0)) { _, _ in if let frame { report(frame) } }
            .onHover { inside in if let id { PeerRopeBoard.shared.hover(id, inside) } }
            .onChange(of: id) { old, _ in if let old { PeerRopeBoard.shared.report(old, outgoing: outgoing, card: nil, owner: owner) } }
            .onDisappear {
                guard let id else { return }
                PeerRopeBoard.shared.report(id, outgoing: outgoing, card: nil, owner: owner)
                PeerRopeBoard.shared.hover(id, false)
            }
    }

    private func report(_ frame: CGRect) {
        guard let id else { return }
        guard on, let pane, let tree, pane.panes.count > 1 else {
            PeerRopeBoard.shared.report(id, outgoing: outgoing, card: nil, owner: owner)
            return
        }
        PeerRopeBoard.shared.report(id, outgoing: outgoing, card: .init(frame: frame, pane: pane.id, panes: pane.panes, tree: tree, peer: peer), owner: owner)
    }
}

extension EnvironmentValues {
    /// 卡片在哪一棵分屏视图里（ChatPanesView 给的编号）
    @Entry var peerRopeTree: UUID?
}

/// 盖在整个分屏上的一层（ChatPanesView 挂的，tree 是那棵分屏视图的编号）
struct PeerRopeLayer: View {
    let tree: UUID
    @AppStorage(PeerPrefs.ropesKey) private var on = true
    @AppStorage(PeerPrefs.cardsKey) private var cards = true

    var body: some View {
        if on && cards { PeerRopeHost(tree: tree) }
    }
}

// MARK: - 绳子

/// 一根绳子：一串小点，两头钉在两张卡片上
@MainActor
private final class Rope {
    static let count = 22
    var points: [CGPoint]
    var previous: [CGPoint]
    var ends: (CGPoint, CGPoint)
    /// 现在的总长：跟着两头的距离慢慢变——两列滚开时绳子先绷着、再慢慢放松，有弹性
    var length: CGFloat
    /// 被鼠标按住的点、按到哪了
    var grabbed: Int?
    var grab: CGPoint = .zero
    /// 出现、消失时淡入淡出（0～1）；显眼程度（0 = 平时，1 = 鼠标停在卡片或绳子上、拖着）
    var opacity: CGFloat = 0
    var emphasis: CGFloat = 0
    var gone = false

    init(ends: (CGPoint, CGPoint)) {
        self.ends = ends
        points = (0..<Self.count).map { i in
            let t = CGFloat(i) / CGFloat(Self.count - 1)
            return CGPoint(x: ends.0.x + (ends.1.x - ends.0.x) * t, y: ends.0.y + (ends.1.y - ends.0.y) * t)
        }
        previous = points
        length = Self.restLength(ends)
    }

    /// 比两头的直线距离长一点，自然垂下来；垂得不多，免得盖住下面的消息
    static func restLength(_ ends: (CGPoint, CGPoint)) -> CGFloat {
        hypot(ends.1.x - ends.0.x, ends.1.y - ends.0.y) * 1.05 + 18
    }

    /// 走一小步（Verlet）：惯性 + 重力，再按段长约束几遍。返回这一步里动得最多的点挪了多少
    func step(_ dt: CGFloat) -> CGFloat {
        length += (Self.restLength(ends) - length) * min(1, dt * 3)
        let segment = length / CGFloat(Self.count - 1)
        let fall = 1400 * dt * dt
        let gravity = RopeGravity.vector
        var moved: CGFloat = 0
        for i in 1..<(Self.count - 1) where i != grabbed {
            let p = points[i]
            let vx = (p.x - previous[i].x) * 0.975, vy = (p.y - previous[i].y) * 0.975
            previous[i] = p
            points[i] = CGPoint(x: p.x + vx + fall * gravity.dx, y: p.y + vy + fall * gravity.dy)
            moved = max(moved, abs(vx) + abs(vy))
        }
        // 两头钉住；按住的点跟着鼠标（上一帧的位置留着：松手时带着拖的速度甩出去）
        points[0] = ends.0
        points[Self.count - 1] = ends.1
        if let grabbed {
            previous[grabbed] = points[grabbed]
            points[grabbed] = grab
            moved = max(moved, 1)
        }
        // 绳子只怕拉、不怕挤：比段长短不管（能弯），长了往回拉。拉力留点余量，被拽着时能伸长、松手弹回来
        for _ in 0..<12 {
            for i in 0..<(Self.count - 1) {
                let a = points[i], b = points[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let distance = hypot(dx, dy)
                guard distance > segment else { continue }
                let pinA = i == 0 || i == grabbed, pinB = i + 1 == Self.count - 1 || i + 1 == grabbed
                if pinA && pinB { continue }
                let k = (distance - segment) / distance * 0.9
                if pinA {
                    points[i + 1] = CGPoint(x: b.x - dx * k, y: b.y - dy * k)
                } else if pinB {
                    points[i] = CGPoint(x: a.x + dx * k, y: a.y + dy * k)
                } else {
                    points[i] = CGPoint(x: a.x + dx * k / 2, y: a.y + dy * k / 2)
                    points[i + 1] = CGPoint(x: b.x - dx * k / 2, y: b.y - dy * k / 2)
                }
            }
        }
        return moved
    }

    /// 过各点的平滑曲线（相邻两点的中点之间用二次曲线连）
    var path: CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 1..<(Self.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[Self.count - 1])
        return path
    }

    /// 离绳子（两头各让开两段，免得按卡片边的时候抓到绳子）最近有多远、最近的是哪个点
    func distance(to p: CGPoint) -> (CGFloat, Int) {
        var best: (CGFloat, Int) = (.infinity, 0)
        for i in 2..<(Self.count - 3) {
            let a = points[i], b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 0.0001)))
            let d = hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t))
            if d < best.0 { best = (d, t < 0.5 ? i : i + 1) }
        }
        return best
    }
}

/// 绳子往哪边垂（屏幕坐标）：手机、iPad 上跟着重力感应走，斜着拿时斜着垂（10-27）；Mac 上一直往下。
/// 只在有绳子层（分屏开着、信绳没关）时读传感器
@MainActor
enum RopeGravity {
    private(set) static var vector = CGVector(dx: 0, dy: 1)
    #if os(iOS)
    private static var motion: CMMotionManager { SharedMotion.manager }
    private static var users = 0

    static func start() {
        users += 1
        guard users == 1, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let gravity = data?.gravity else { return }
            MainActor.assumeIsolated { update(gravity) }
        }
    }

    static func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        motion.stopDeviceMotionUpdates()
        vector = CGVector(dx: 0, dy: 1)
    }

    /// 传感器给的是机身坐标（竖着拿时 x 朝右、y 朝上），按界面现在的方向换成屏幕坐标（y 朝下）
    private static func update(_ g: CMAcceleration) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let (x, y): (Double, Double)
        switch scene?.effectiveGeometry.interfaceOrientation ?? .portrait {
        case .landscapeRight: (x, y) = (-g.y, -g.x)
        case .landscapeLeft: (x, y) = (g.y, g.x)
        case .portraitUpsideDown: (x, y) = (-g.x, g.y)
        default: (x, y) = (g.x, -g.y)
        }
        // 平放在桌上时屏幕里几乎没有重力：方向照旧、留三成，绳子还是微微垂着；手抖的小变化滤掉
        let length = hypot(x, y)
        let current = hypot(vector.dx, vector.dy)
        let target = length < 0.05
            ? CGVector(dx: vector.dx / max(current, 0.001) * 0.3, dy: vector.dy / max(current, 0.001) * 0.3)
            : CGVector(dx: x / length * max(length, 0.3), dy: y / length * max(length, 0.3))
        let next = CGVector(dx: vector.dx + (target.dx - vector.dx) * 0.3, dy: vector.dy + (target.dy - vector.dy) * 0.3)
        guard abs(next.dx - vector.dx) + abs(next.dy - vector.dy) > 0.01 else { return }
        vector = next
        PeerRopeBoard.shared.nudge()
    }
    #endif
}

/// 管所有绳子：对照卡片位置增删、走物理、画、接鼠标。平台的视图只管刷新时机和把事件转进来
@MainActor
private final class RopeEngine {
    weak var host: CALayer?
    /// 只连这一棵分屏视图里的卡片
    var tree = UUID()
    var color: CGColor = CGColor(red: 0.85, green: 0.47, blue: 0.2, alpha: 1)
    private var ropes: [String: Rope] = [:]
    private var layers: [String: (line: CAShapeLayer, knots: CAShapeLayer)] = [:]
    /// 鼠标停在哪根绳子上、正拖着哪根
    private(set) var hoverRope: String?
    private var dragging: String?
    private var still = 0
    /// 鼠标多近算碰到绳子
    static let reach: CGFloat = 6

    /// 走一帧。返回 false = 都停下来了，可以不刷新了
    func tick(_ dt: CGFloat) -> Bool {
        let board = PeerRopeBoard.shared
        let wanted = board.ends(in: tree)
        for (id, ends) in wanted where ropes[id] == nil || ropes[id]?.gone == true {
            if let rope = ropes[id] { rope.gone = false; rope.ends = ends } else { ropes[id] = Rope(ends: ends) }
        }
        var busy = false
        let steps = max(1, min(3, Int((dt * 60).rounded())))
        for (id, rope) in ropes {
            if let ends = wanted[id] {
                rope.ends = ends
            } else if rope.grabbed == nil {
                rope.gone = true
            }
            rope.opacity = approach(rope.opacity, rope.gone ? 0 : 1, dt * 6)
            let lit = board.hovered == id || hoverRope == id || dragging == id
            rope.emphasis = approach(rope.emphasis, lit ? 1 : 0, dt * 8)
            if rope.gone && rope.opacity <= 0 {
                remove(id)
                continue
            }
            var moved: CGFloat = 0
            for _ in 0..<steps { moved = max(moved, rope.step(1 / 60)) }
            busy = busy || moved > 0.04 || rope.grabbed != nil || (rope.opacity > 0 && rope.opacity < 1)
                || (rope.emphasis > 0 && rope.emphasis < 1)
            draw(id, rope)
        }
        still = busy || board.waiting(in: tree) ? 0 : still + 1
        return still < 12
    }

    private func approach(_ value: CGFloat, _ target: CGFloat, _ amount: CGFloat) -> CGFloat {
        value < target ? min(target, value + amount) : max(target, value - amount)
    }

    private func draw(_ id: String, _ rope: Rope) {
        guard let host else { return }
        let pair = layers[id] ?? {
            let line = CAShapeLayer(), knots = CAShapeLayer()
            line.fillColor = nil
            line.lineCap = .round
            line.lineJoin = .round
            host.addSublayer(line)
            host.addSublayer(knots)
            return (line, knots)
        }()
        layers[id] = pair
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let style = Self.style(rope)
        pair.line.path = rope.path
        pair.line.lineWidth = style.width
        pair.line.strokeColor = color.copy(alpha: style.line)
        pair.line.shadowColor = CGColor(gray: 0, alpha: 1)
        pair.line.shadowOpacity = Float(style.shadow)
        pair.line.shadowRadius = 1.5
        pair.line.shadowOffset = CGSize(width: 0, height: 1)
        pair.knots.path = Self.knots(rope, radius: style.knot)
        pair.knots.fillColor = color.copy(alpha: style.knotAlpha)
        CATransaction.commit()
    }

    /// 平时细而淡（不挡字），显眼时实一点、粗一点，带一点影子像根真绳子
    private static func style(_ rope: Rope) -> (width: CGFloat, line: CGFloat, shadow: CGFloat, knot: CGFloat, knotAlpha: CGFloat) {
        let e = rope.emphasis
        return (1.3 + 1.0 * e, (0.22 + 0.63 * e) * rope.opacity, 0.28 * e * rope.opacity, 2 + 0.6 * e, (0.35 + 0.6 * e) * rope.opacity)
    }

    /// 两头的小结：绳子系在卡片边上
    private static func knots(_ rope: Rope, radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for p in [rope.points[0], rope.points[Rope.count - 1]] {
            path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        return path
    }

    /// 自测截图用：截图（cacheDisplay）画不出图层，把现在的绳子直接画进去
    func draw(in context: CGContext) {
        for rope in ropes.values where rope.opacity > 0 {
            let style = Self.style(rope)
            context.addPath(rope.path)
            context.setStrokeColor(color.copy(alpha: style.line) ?? color)
            context.setLineWidth(style.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            context.addPath(Self.knots(rope, radius: style.knot))
            context.setFillColor(color.copy(alpha: style.knotAlpha) ?? color)
            context.fillPath()
        }
    }

    private func remove(_ id: String) {
        layers[id]?.line.removeFromSuperlayer()
        layers[id]?.knots.removeFromSuperlayer()
        layers[id] = nil
        ropes[id] = nil
        if hoverRope == id { hoverRope = nil }
    }

    /// 这一点碰着哪根绳子
    func rope(at p: CGPoint) -> String? {
        ropes.filter { !$0.value.gone && $0.value.opacity > 0.5 }
            .map { ($0.key, $0.value.distance(to: p).0) }
            .filter { $0.1 <= Self.reach }
            .min { $0.1 < $1.1 }?.0
    }

    /// 鼠标挪动：碰着绳子就把它点亮。返回变了没有
    func hover(_ p: CGPoint?) -> Bool {
        let next = p.flatMap { rope(at: $0) }
        guard next != hoverRope else { return false }
        hoverRope = next
        return true
    }

    func grab(_ p: CGPoint) -> Bool {
        guard let id = rope(at: p), let rope = ropes[id] else { return false }
        rope.grabbed = rope.distance(to: p).1
        rope.grab = p
        dragging = id
        return true
    }

    func drag(_ p: CGPoint, within bounds: CGRect) {
        guard let id = dragging else { return }
        ropes[id]?.grab = CGPoint(x: min(max(p.x, bounds.minX + 4), bounds.maxX - 4), y: min(max(p.y, bounds.minY + 4), bounds.maxY - 4))
    }

    func release() {
        if let id = dragging { ropes[id]?.grabbed = nil }
        dragging = nil
    }

    var isDragging: Bool { dragging != nil }

    /// 自测用：各绳子的两头、中间那一点
    func summary() -> [(id: String, from: CGPoint, to: CGPoint, mid: CGPoint, emphasis: CGFloat)] {
        ropes.filter { !$0.value.gone }.sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.points[0], $0.value.points[Rope.count - 1], $0.value.points[Rope.count / 2], $0.value.emphasis) }
    }
}

// MARK: - 平台视图

#if os(macOS)
private struct PeerRopeHost: NSViewRepresentable {
    let tree: UUID
    func makeNSView(context: Context) -> PeerRopeView { PeerRopeView(tree: tree) }
    func updateNSView(_ view: PeerRopeView, context: Context) {}
}

/// 自测截图时打开（见 KitelineKit.ropesInCapture）：绳子也画进截图
@MainActor private var ropeCapture = false

#if KITELINE_MAC
extension KitelineKit {
    /// 测试实例截图时让分屏里的信绳画进截图（平时是图层，截图画不出来）
    public static var ropesInCapture: Bool {
        get { ropeCapture }
        set { ropeCapture = newValue }
    }

    /// 自测：现在画着的绳子，两头和中间那一点在窗口里的位置（左上角为原点）
    public static func ropeReport() -> String {
        let cards = PeerRopeBoard.shared.cards.flatMap { slot, entries in
            entries.values.map { "\(slot.suffix(16))@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
        }.sorted().joined(separator: " ")
        return (PeerRopeView.current?.report() ?? "没有绳子层（不是分屏，或开关关着）") + "；登记的信件：" + (cards.isEmpty ? "无" : cards)
    }

    /// 自测：当成鼠标停在（或离开）第一根绳子那封信的卡片上，看显眼的样子
    public static func hoverRope(_ on: Bool) {
        if let id = PeerRopeBoard.shared.paired.first { PeerRopeBoard.shared.hover(id, on) }
    }
}
#endif

private final class PeerRopeView: NSView {
    /// 自测用：最近建的绳子层
    static weak var current: PeerRopeView?
    private let engine = RopeEngine()
    private var link: CADisplayLink?
    /// 窗口不在任何屏幕上时（自测窗口放在屏幕外、显示器断开）display link 不走，改用定时器
    private var timer: Timer?
    private var last: CFTimeInterval = 0

    override var isFlipped: Bool { true }

    init(tree: UUID) {
        super.init(frame: .zero)
        engine.tree = tree
        wantsLayer = true
        engine.host = layer
        engine.color = NSColor(Theme.claude).usingColorSpace(.sRGB)?.cgColor ?? engine.color
        PeerRopeBoard.shared.listen(self) { [weak self] in self?.wake() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Self.current = self
            wake()
        } else {
            stop()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard ropeCapture, let context = NSGraphicsContext.current?.cgContext else { return }
        engine.draw(in: context)
    }

    /// 自测：各绳子两头和中点在窗口里的位置（左上角为原点）
    func report() -> String {
        guard let window else { return "绳子层不在窗口里" }
        let height = window.contentView?.bounds.height ?? window.frame.height
        func spot(_ p: CGPoint) -> String {
            let w = convert(p, to: nil)
            return "\(Int(w.x)),\(Int(height - w.y))"
        }
        let lines = engine.summary().map { "\($0.id.prefix(12))：\(spot($0.from)) → \(spot($0.to))，中点 \(spot($0.mid))，显眼 \(String(format: "%.2f", $0.emphasis))" }
        return lines.isEmpty ? "没有绳子（两张信件没同时露在两列里）" : lines.joined(separator: "；")
    }

    // 按住绳子是拖绳子，不是拖窗口；窗口不在前面时第一下也算数
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 只有贴着绳子的地方接鼠标；别处（消息、按钮、选字）都穿过去
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return engine.rope(at: local) != nil || engine.isDragging ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !engine.isDragging else { return }
        let wasOn = engine.hoverRope != nil
        if engine.hover(convert(event.locationInWindow, from: nil)) {
            if engine.hoverRope != nil { NSCursor.openHand.set() } else if wasOn { NSCursor.arrow.set() }
            wake()
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard !engine.isDragging, engine.hover(nil) else { return }
        NSCursor.arrow.set()
        wake()
    }

    override func mouseDown(with event: NSEvent) {
        guard engine.grab(convert(event.locationInWindow, from: nil)) else { return }
        NSCursor.closedHand.set()
        wake()
    }

    override func mouseDragged(with event: NSEvent) {
        engine.drag(convert(event.locationInWindow, from: nil), within: bounds)
        wake()
    }

    override func mouseUp(with event: NSEvent) {
        engine.release()
        _ = engine.hover(convert(event.locationInWindow, from: nil))
        (engine.hoverRope != nil ? NSCursor.openHand : NSCursor.arrow).set()
        wake()
    }

    /// 有东西要动了：开始逐帧刷新（停下来后自己停）
    private func wake() {
        guard link == nil, timer == nil, let window else { return }
        last = 0
        if window.screen == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.frame(at: CACurrentMediaTime()) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick(_ link: CADisplayLink) { frame(at: link.timestamp) }

    private func frame(at time: CFTimeInterval) {
        let dt = last == 0 ? 1.0 / 60 : min(1.0 / 20, time - last)
        last = time
        if !engine.tick(CGFloat(dt)) { stop() }
        if ropeCapture { needsDisplay = true }
    }
}
#else
private struct PeerRopeHost: UIViewRepresentable {
    let tree: UUID
    func makeUIView(context: Context) -> PeerRopeView { PeerRopeView(tree: tree) }
    func updateUIView(_ view: PeerRopeView, context: Context) {}
}

private final class PeerRopeView: UIView {
    private let engine = RopeEngine()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var sensing = false

    init(tree: UUID) {
        super.init(frame: .zero)
        engine.tree = tree
        backgroundColor = .clear
        isOpaque = false
        engine.host = layer
        engine.color = UIColor(Theme.claude).cgColor
        PeerRopeBoard.shared.listen(self) { [weak self] in self?.wake() }
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 绳子跟着重力垂：有绳子层时才读传感器
        if (window != nil) != sensing {
            sensing = window != nil
            if sensing { RopeGravity.start() } else { RopeGravity.stop() }
        }
        if window != nil { wake() } else { link?.invalidate(); link = nil }
    }

    // 只有贴着绳子的地方接手指、指针；别处都穿过去
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        engine.rope(at: point) != nil || engine.isDragging
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let p = gesture.location(in: self)
        switch gesture.state {
        case .began: _ = engine.grab(p)
        case .changed: engine.drag(p, within: bounds)
        default: engine.release()
        }
        wake()
    }

    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        let p: CGPoint? = gesture.state == .ended || gesture.state == .cancelled ? nil : gesture.location(in: self)
        if engine.hover(p) { wake() }
    }

    private func wake() {
        guard link == nil, window != nil else { return }
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = last == 0 ? 1.0 / 60 : min(1.0 / 20, link.timestamp - last)
        last = link.timestamp
        if !engine.tick(CGFloat(dt)) {
            link.invalidate()
            self.link = nil
        }
    }
}
#endif
