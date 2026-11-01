import CoreGraphics
import Foundation

/// Kiteline 的纸鸢：北京沙燕，照用户给的参考图描的——头朝右上斜飞，一根竹条撑起两翅，翅下挂扇骨白羽，两条长燕尾拖向左下。
/// 纯色剪纸风：整只一个颜色，扇骨、眼睛、头顶分界、翅带纹都是镂空。
/// 坐标是 384×384 的格子（y 朝下）。App 图标（tools/make-icon.swift，构建时和这个文件一起编译）、iPhone、手表、
/// Mac 菜单栏和主窗口顶上飞的那只都画这一份；改形状只改这里。
public enum PaperKite {
    public static let size: CGFloat = 384

    /// 两根提线拴在胸口（翅杆和身子交叉处）和腰腹，往前汇成一个结，再接一根主线拉下去
    public static let bridleTop = CGPoint(x: 232, y: 84)
    public static let bridleBottom = CGPoint(x: 200, y: 138)
    public static let knot = CGPoint(x: 246, y: 196)
    /// 纸鸢的「重心」：摇摆、缩放绕这里转
    public static let center = CGPoint(x: 222, y: 108)

    /// 飞行姿态：两条燕尾各自绕根部摆多少（弧度）
    public struct Pose: Sendable {
        public var tailLeft: CGFloat
        public var tailDown: CGFloat
        public init(tailLeft: CGFloat = 0, tailDown: CGFloat = 0) {
            self.tailLeft = tailLeft
            self.tailDown = tailDown
        }
    }

    /// full：图标、顶上飞的大纸鸢，全部镂空细节；glyph：小图标（思考中、菜单栏），只留身子轮廓和眼睛，扇骨这些小了只会糊
    public enum Detail: Sendable { case full, glyph }

    /// 画哪几部分：动画里两条燕尾各自一层（绕根部摆），其余是一层
    public struct Parts: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let tailLeft = Parts(rawValue: 1)
        public static let tailDown = Parts(rawValue: 2)
        public static let rest = Parts(rawValue: 4)
        public static let all: Parts = [.tailLeft, .tailDown, .rest]
    }

    /// 燕尾的根（燕尾绕这里摆）
    public static let tailLeftRoot = Shape.tailLeftRoot
    public static let tailDownRoot = Shape.tailDownRoot

    /// 在 ctx 里画一只纸鸢（ctx 的坐标已经换算到 384 格子、y 朝下）。
    /// unit = 一个格子单位等于多少像素/点：小尺寸时镂空线按它加粗，保证至少看得见。
    /// bridle = 提线粗细（格子单位）；给了就连两根提线和结一起画：压在纸鸢身上的那段反色（挖空露出底色），身外是线的颜色。
    /// 主线由调用方从 knot 接着往下画
    public static func draw(_ ctx: CGContext, color: CGColor, detail: Detail = .full, pose: Pose = Pose(), unit: CGFloat = 1,
                            bridle: CGFloat? = nil, parts: Parts = .all) {
        let minCut = 0.9 / max(unit, 0.001)
        func cutWidth(_ nominal: CGFloat) -> CGFloat { detail == .glyph ? max(nominal, minCut) : nominal }

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        func fill(_ path: CGPath) {
            ctx.setBlendMode(.normal)
            ctx.addPath(path)
            ctx.fillPath()
        }
        func cut(_ path: CGPath, _ width: CGFloat) {
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(cutWidth(width))
            ctx.addPath(path)
            ctx.strokePath()
        }
        /// 先沿轮廓挖一圈（一半挖在下面已经画的东西上），再把自己填上：和底下的部件之间留一道细缝
        func piece(_ path: CGPath, gap: CGFloat) {
            cut(path, gap)
            fill(path)
        }

        if parts.contains(.tailLeft) { fill(rotated(Shape.tailLeft, by: pose.tailLeft, around: Shape.tailLeftRoot)) }
        if parts.contains(.tailDown) { fill(rotated(Shape.tailDown, by: pose.tailDown, around: Shape.tailDownRoot)) }
        guard parts.contains(.rest) else {
            // 只画燕尾（单独一层）：把身子、近翅压在燕尾根上的那圈细缝先挖出来，叠上身子那层后和整只画的一样
            cut(Shape.body, 4.5)
            cut(Shape.nearFan, 3.6)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            return
        }

        switch detail {
        case .full:
            fill(Shape.farFan)
            cut(Shape.farRibs, 2.6)
            piece(Shape.farBand, gap: 3.2)
            cut(Shape.farStripe, 2.4)
            piece(Shape.nearFan, gap: 3.6)
            cut(Shape.nearRibs, 2.8)
            piece(Shape.nearBand, gap: 3.6)
            cut(Shape.nearStripe, 2.6)
            piece(Shape.body, gap: 4.5)
            cut(Shape.capEdge, 2.6)
        case .glyph:
            fill(Shape.farFan)
            fill(Shape.farBand)
            fill(Shape.nearFan)
            fill(Shape.nearBand)
            piece(Shape.body, gap: 4.5)
        }
        fill(Shape.beak)
        // 眼睛：挖一个圆，中间留眼珠
        let eyeRadius = detail == .glyph ? max(4.8, 1.3 / max(unit, 0.001)) : 4.8
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: 270 - eyeRadius, y: 48 - eyeRadius, width: eyeRadius * 2, height: eyeRadius * 2))
        if detail == .full || eyeRadius * unit >= 2.2 {
            ctx.setBlendMode(.normal)
            let pupil = eyeRadius * 0.46
            ctx.fillEllipse(in: CGRect(x: 271 - pupil, y: 48 - pupil, width: pupil * 2, height: pupil * 2))
        }
        // 提线：异或——落在纸鸢上的像素被挖空，落在空处的画成线色
        if let bridle {
            ctx.setBlendMode(.xor)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(cutWidth(bridle))
            ctx.move(to: bridleTop)
            ctx.addLine(to: knot)
            ctx.addLine(to: bridleBottom)
            ctx.strokePath()
            let r = cutWidth(bridle) * 1.2
            ctx.fillEllipse(in: CGRect(x: knot.x - r, y: knot.y - r, width: r * 2, height: r * 2))
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func rotated(_ path: CGPath, by angle: CGFloat, around point: CGPoint) -> CGPath {
        guard angle != 0 else { return path }
        var t = CGAffineTransform(translationX: point.x, y: point.y).rotated(by: angle).translatedBy(x: -point.x, y: -point.y)
        return path.copy(using: &t) ?? path
    }

    /// 各部件的路径（384 格子），用 SVG 的 M / L / C / Z 写，和设计稿逐字对得上
    enum Shape {
        static let tailLeft = svg("M174 142 C140 164 80 204 4 238 C70 216 136 186 184 158 Z")
        static let tailDown = svg("M178 151 C175 220 162 290 147 347 C170 292 188 226 194 155 Z")
        static let tailLeftRoot = CGPoint(x: 179, y: 150)
        static let tailDownRoot = CGPoint(x: 186, y: 153)
        /// 远处（左上）的翅：扇面、上沿的翅带、翅带上的一道纹
        static let farFan = svg("M207 63 L100 10 C95 12 94 20 97 30 C104 56 124 88 150 112 C166 127 180 134 194 137 Z")
        static let farBand = svg("M212 58 L100 9 C95 10 93 17 96 27 L103 33 C136 51 170 69 206 85 Z")
        static let farStripe = svg("M198 72 C180 60 166 62 150 50 C138 42 126 38 114 26")
        static let farRibs = ribs(from: CGPoint(x: 200, y: 82), to: CGPoint(x: 106, y: 34),
                                  edge: [(192, 135), (170, 125), (147, 108), (125, 84), (108, 58), (99, 33)], count: 11)
        /// 近处（右下）的翅
        static let nearFan = svg("M256 104 L378 166 C384 170 383 179 375 184 C335 191 292 188 252 174 C232 166 216 157 206 149 Z")
        static let nearBand = svg("M262 92 L379 165 C385 169 384 178 376 183 L368 186 C330 166 290 146 248 124 Z")
        static let nearStripe = svg("M262 108 C282 116 296 128 318 136 C334 142 350 152 368 168")
        static let nearRibs = ribs(from: CGPoint(x: 250, y: 124), to: CGPoint(x: 366, y: 186),
                                   edge: [(210, 150), (236, 165), (266, 178), (300, 187), (336, 189), (366, 186)], count: 12)
        static let body = svg("M236 40 C252 28 278 31 287 49 C290 66 284 84 270 104 C256 124 230 146 200 156 C186 160 174 158 170 150 C164 138 172 112 186 92 C200 70 218 50 236 40 Z")
        /// 黑顶和白脸的分界（挖一道线）
        static let capEdge = svg("M287 58 C281 62 274 63 268 60 C262 57 256 53 248 52 C241 51 234 47 236 40")
        static let beak = svg("M284 45 C290 41 296 38 302 36 C298 42 294 48 288 56 Z")
        /// 扇骨：翅带下沿上均匀取点，连到扇面外沿折线上对应的位置
        static func ribs(from a: CGPoint, to b: CGPoint, edge: [(CGFloat, CGFloat)], count: Int) -> CGPath {
            let path = CGMutablePath()
            func lerp(_ p: CGPoint, _ q: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t) }
            let points = edge.map { CGPoint(x: $0.0, y: $0.1) }
            for i in 0..<count {
                let t = (CGFloat(i) + 0.5) / CGFloat(count)
                let segments = CGFloat(points.count - 1), f = t * segments
                let index = min(Int(f), points.count - 2)
                path.move(to: lerp(a, b, t))
                path.addLine(to: lerp(points[index], points[index + 1], f - CGFloat(index)))
            }
            return path
        }

        /// 只认绝对坐标的 M / L / C / Z（设计稿里就这几种）
        static func svg(_ d: String) -> CGPath {
            let path = CGMutablePath()
            var command: Character = "M"
            var numbers: [CGFloat] = []
            var token = ""
            func flushToken() {
                if let value = Double(token) { numbers.append(CGFloat(value)) }
                token = ""
            }
            func flushCommand() {
                switch command {
                case "M", "L":
                    var i = 0
                    while i + 1 < numbers.count {
                        let p = CGPoint(x: numbers[i], y: numbers[i + 1])
                        if command == "M" && i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        i += 2
                    }
                case "C":
                    var i = 0
                    while i + 5 < numbers.count {
                        path.addCurve(to: CGPoint(x: numbers[i + 4], y: numbers[i + 5]),
                                      control1: CGPoint(x: numbers[i], y: numbers[i + 1]),
                                      control2: CGPoint(x: numbers[i + 2], y: numbers[i + 3]))
                        i += 6
                    }
                case "Z": path.closeSubpath()
                default: break
                }
                numbers = []
            }
            for ch in d {
                if ch.isLetter {
                    flushToken()
                    flushCommand()
                    command = ch
                } else if ch == " " || ch == "," {
                    flushToken()
                } else if ch == "-" && !token.isEmpty {
                    flushToken()
                    token = "-"
                } else {
                    token.append(ch)
                }
            }
            flushToken()
            flushCommand()
            return path
        }
    }
}
