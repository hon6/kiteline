import AppKit
import SwiftUI
import KitelineKit

// Kiteline 的界面基础件：液态玻璃（macOS 26+ 原生，低版本退回毛玻璃）、状态色、头像、菜单栏图标。

// MARK: - 液态玻璃

extension View {
    /// 玻璃底：macOS 26 起用系统液态玻璃，之前的系统用毛玻璃材质
    @ViewBuilder
    func tarsGlass(cornerRadius: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(interactive ? base.interactive() : base, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .hairlineBorder(Color.white.opacity(0.12)))
        }
    }

    /// 玻璃按钮（prominent = 主操作，带强调色）；字跟着「设置 → 外观」走（见 LookButtonStyle）
    @ViewBuilder
    func tarsButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(LookButtonStyle(base: .glassProminent)) } else { self.buttonStyle(LookButtonStyle(base: .glass)) }
        } else {
            if prominent { self.buttonStyle(LookButtonStyle(base: .borderedProminent)) } else { self.buttonStyle(LookButtonStyle(base: .bordered)) }
        }
    }

    /// 卡片：玻璃之上的一层内容容器
    func tarsCard(padding: CGFloat = 14, cornerRadius: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - 颜色

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
    }

    /// 强调色（和手机 App 的 Theme.claude 一样，跟着「设置 → 通用 → 外观」里选的主题走，经典主题是品牌橙）：
    /// 图标、进行中、头像都用它——全 App 只有这一种强调色
    static var tarsBrand: Color { Look.shared.palette.accent }
    /// 「等你确认」的橙（状态色，不跟主题变）
    static let tarsOrange = Color(hex: 0xff9f0a)
    /// 图标、首字头像的底：淡淡的强调色
    static var tarsTile: Color { Look.shared.palette.tile }
}

// MARK: - 字

extension Font {
    /// 界面上的字（size = 标准字号下的点数）：跟着「设置 → 通用 → 外观」里选的字号缩放、换成选的字体；
    /// 指定了 design（等宽这类）的只缩放不换字体。框死大小的小方块（头像首字、角标）里的字用 appFixed
    static func app(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        Look.shared.font(size: size * Look.shared.textScale, weight: weight, design: design)
    }

    /// 框死大小的小方块（头像首字、角标、编号）里的字：只换字体、不跟字号缩放（放大会撑出来），和周围的字还是同一种字体
    static func appFixed(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        Look.shared.font(size: size, weight: weight, design: design)
    }
}

extension View {
    /// 每个窗口的根视图挂一次：强调色、默认字（13 号乘字号倍数、选的字体）；改了设置立刻重画。
    /// wrapButtons：没指定样式的按钮也包一层 LookButtonStyle（设置窗口、菜单栏面板用；主窗口不用——工具栏按钮包了会走样）
    @ViewBuilder
    func tarsLook(wrapButtons: Bool = false) -> some View {
        if wrapButtons {
            modifier(LookRoot()).buttonStyle(LookButtonStyle(base: .automatic))
        } else {
            modifier(LookRoot())
        }
    }
}

/// Mac 上系统的按钮样式（默认、带边框、玻璃）不吃外面设的字体，只认写在按钮标签上的（实测）：
/// 包一层，把「设置 → 外观」里选的字体套到标签上，字号按控件大小（迷你 9、小号 11、其余 13）乘字号倍数。
/// 无边框、纯文字、链接样式本来就跟着外面的字走，不用包
struct LookButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    var base: Base

    func makeBody(configuration: Configuration) -> some View {
        Wrapped(configuration: configuration, base: base)
    }

    private struct Wrapped: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let base: Base
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label.font(.app(size: size))
            }
            .buttonStyle(base)
        }

        private var size: CGFloat {
            switch controlSize {
            case .mini: 9
            case .small: 11
            case .extraLarge: 15
            default: 13
            }
        }
    }
}

/// 全 App 统一的图标（和手机 App 的 TarsIcon 一样）：品牌橙的图形放在淡橙色圆角方块里，只有这一种双色样式
struct DuoIcon: View {
    let symbol: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Color.tarsBrand)
            .frame(width: size, height: size)
            .background(Color.tarsTile, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

extension Activity {
    var color: Color {
        switch self {
        case .waiting: return .tarsOrange
        case .busy: return .tarsBrand
        case .idle: return .green
        case .unknown: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "exclamationmark.circle.fill"
        case .busy: return "waveform"
        case .idle: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var sectionTitle: String {
        switch self {
        case .waiting: return L("待处理")
        case .busy: return L("进行中")
        case .idle: return L("空闲")
        case .unknown: return L("其他")
        }
    }
}

// MARK: - 头像

struct SessionAvatar: View {
    let key: String
    let title: String
    let activity: Activity
    var size: CGFloat = 34

    private var initials: String {
        let text = title.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "?" }
        if first.isASCII, first.isLetter || first.isNumber {
            return String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(2)).uppercased()
        }
        return String(first)
    }

    var body: some View {
        // 用户在「Agent 详情」里给这个会话换了头像就画那个（同手机）；没换是和图标同一种双色：淡橙底 + 品牌橙的首字
        TarsSessionFace(key: key, size: size, corner: 0.28) {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.tarsTile)
                .frame(width: size, height: size)
                .overlay(Text(initials).font(.appFixed(size: size * 0.4, weight: .semibold)).foregroundStyle(Color.tarsBrand))
        }
            .overlay(alignment: .bottomTrailing) {
                if activity == .busy {
                    SpinningGlyph(size: size * 0.42)
                        .offset(x: size * 0.12, y: size * 0.12)
                } else if activity == .waiting {
                    Circle().fill(Color.tarsOrange)
                        .frame(width: size * 0.36, height: size * 0.36)
                        .overlay(Text("!").font(.appFixed(size: size * 0.24, weight: .bold)).foregroundStyle(.white))
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
    }
}

/// 工作中：随风飘的小纸鸢（和手机、对话页同一个，代替原来的 ✻），直接压在头像角上，不垫底
struct SpinningGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        KiteSpinner(size: size * 1.15, color: .tarsBrand)
            .frame(width: size * 1.2, height: size * 1.2)
    }
}

// MARK: - 菜单栏图标（Kiteline 的纸鸢）

enum TarsGlyph {
    enum State { case idle, busy, waiting, offline }

    /// 工作中摆动一圈的帧数（菜单栏 0.12 秒换一帧，约 3 秒一圈）
    static let busyFrames = 24
    /// 画过的图按（状态, 帧）留着复用：NSImage 第一次画完会缓存位图，同一个对象再用不再重画。
    /// 以前每帧新建一张、把纸鸢路径（带图形布尔运算）从头画一遍，菜单栏在每块屏上各画一次，Mac 空闲时也占着主线程（10-26 反馈：卡）
    private static var cache: [String: NSImage] = [:]

    /// 18pt 高的模板图：纸鸢剪影（形状在 KitelineKit/Shared/PaperKite.swift，和 App 图标同一份）+ 从提线结垂下的一小段线。
    /// 空闲时静止；工作中随风左右晃、上下起伏；待确认时右下角带个点；离线时变淡
    static func image(state: State, frame: Int = 0) -> NSImage {
        let frame = state == .busy ? (frame % busyFrames + busyFrames) % busyFrames : 0
        let key = "\(state)-\(frame)"
        if let cached = cache[key] { return cached }
        let image = draw(state: state, frame: frame)
        cache[key] = image
        return image
    }

    private static func draw(state: State, frame: Int) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let unit = size.height / PaperKite.size
            var angle: CGFloat = 0, lift: CGFloat = 0
            if state == .busy {
                // 左右晃、上下起伏同一个周期（错开相位），一圈 busyFrames 帧，帧才能复用
                let phase = Double(frame) / Double(busyFrames) * 2 * .pi
                angle = CGFloat(sin(phase)) * 0.14
                lift = CGFloat(sin(phase + 1)) * 0.7
            }
            let alpha: CGFloat = state == .offline ? 0.35 : 1
            let ink = NSColor.black.withAlphaComponent(alpha).cgColor
            if state == .waiting {
                // 右下角是空的（纸鸢头朝右上、燕尾在左下）
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: size.width - 5.6, y: size.height - 5.6, width: 5.3, height: 5.3))
            }
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.translateBy(x: (size.width - size.height) / 2, y: lift)
            ctx.scaleBy(x: unit, y: unit)
            // 绕纸鸢重心转
            ctx.translateBy(x: PaperKite.center.x, y: PaperKite.center.y)
            ctx.rotate(by: angle)
            ctx.translateBy(x: -PaperKite.center.x, y: -PaperKite.center.y)
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(0.55 / unit)   // 要比燕尾细
            ctx.setLineCap(.round)
            ctx.move(to: PaperKite.knot)
            ctx.addLine(to: CGPoint(x: 268, y: 384))
            ctx.strokePath()
            PaperKite.draw(ctx, color: ink, detail: .glyph, unit: unit)
            return true
        }
        image.isTemplate = true
        image.cacheMode = .always
        image.accessibilityDescription = "Kiteline"
        return image
    }
}

// MARK: - 时间

enum Format {
    /// 毫秒时间戳 → 「3 分钟前」
    static func ago(_ milliseconds: Double) -> String {
        let seconds = Date().timeIntervalSince(Date(timeIntervalSince1970: milliseconds / 1000))
        if seconds < 5 { return L("刚刚") }
        if seconds < 60 { return L("%@ 秒前", "\(Int(seconds))") }
        if seconds < 3600 { return L("%@ 分钟前", "\(Int(seconds / 60))") }
        if seconds < 86400 { return L("%@ 小时前", "\(Int(seconds / 3600))") }
        return L("%@ 天前", "\(Int(seconds / 86400))")
    }

    /// /Users/xx/... 或 /home/xx/... 显示成 ~/...
    static func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: "^/(Users|home)/[^/]+", with: "~", options: .regularExpression)
    }

    /// 列表右侧的短时间：今天显示时分，昨天显示「昨天」，更早显示月/日。
    /// 格式器只建一次：侧栏每张卡片每次重算都要调，每次新建 DateFormatter 很贵（11-01 采样里滚动卡死时它占了一截）
    static func short(_ milliseconds: Double?) -> String {
        guard let milliseconds = milliseconds else { return "" }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return clock.string(from: date) }
        if calendar.isDateInYesterday(date) { return L("昨天") }
        return monthDay.string(from: date)
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let monthDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M/d"; return f }()
}

/// 外观：跟随系统 / 浅色 / 深色（设置 → 通用；和手机 App 一样三档），启动时套用；顺带读主题色、字体、字号（Look）
enum AppAppearance {
    static var current: String { AppConfig.defaults.string(forKey: "appearance") ?? "system" }

    static func set(_ value: String) {
        AppConfig.defaults.set(value, forKey: "appearance")
        apply()
    }

    static func apply() {
        // 主题色、字体、字号（Look）也存在这份偏好里：测试实例用自己那份
        Look.shared.use(AppConfig.defaults)
        switch current {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
