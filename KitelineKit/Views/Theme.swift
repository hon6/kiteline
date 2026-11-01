import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 配色：强调色、主按钮、我的气泡跟着设置里选的主题走（Look.swift；默认「经典」= 品牌橙 + 微信式的绿气泡，和网页版、Mac 版一致），其余跟随系统
enum Theme {
    /// 强调色（经典主题是品牌橙）
    static var claude: Color { Look.shared.palette.accent }
    static var meBubble: Color { Look.shared.palette.bubble }
    /// 我的气泡上的字
    static var meText: Color { Look.shared.palette.bubbleText }
    #if os(macOS)
    /// Mac 主窗口（同网页版的 Mac 样式）：对话区就是窗口底色，Claude 的气泡、工具卡片是半透明灰
    static let botBubble = dynamic(light: 0x787880, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.08)
    static let chatBackground = Color(nsColor: .windowBackgroundColor)
    #else
    static let botBubble = dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let chatBackground = dynamic(light: 0xEDEDED, dark: 0x111111)
    #endif
    static let code = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.09)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let added = Color(red: 0.13, green: 0.6, blue: 0.3)

    // 微信式的输入栏、发送键、按住说话、置顶行
    /// 主按钮色：发送键、开关、选中的勾（经典主题是微信绿）
    static var wechatGreen: Color { Look.shared.palette.action }
    /// 我的气泡的浅色版（经典主题是微信的浅绿）
    static var wechatBubbleGreen: Color { Look.shared.palette.bubbleLight }
    static let inputBar = dynamic(light: 0xF7F7F7, dark: 0x1E1E1E)
    static let field = dynamic(light: 0xFFFFFF, dark: 0x2C2C2C)
    static let holdPressed = dynamic(light: 0xC6C6C6, dark: 0x474747)
    static let pinnedRow = dynamic(light: 0xF3F3F3, dark: 0x262626)
    static let menuBackground = Color(hex: 0x4C4C4C)
    /// 今日动态、用量这些页面的底色（卡片是白的）
    static let pageBackground = dynamic(light: 0xF2F2F7, dark: 0x000000)
    /// 首页汇总卡片（白色列表上的浅灰块）
    static let tile = dynamic(light: 0xF4F4F6, dark: 0x1C1C1E)
    static let removed = Color(red: 0.85, green: 0.25, blue: 0.25)

    /// 图标、首字头像的底色：淡淡的强调色（全 App 的图标都是「强调色图形 + 淡强调色底」这一种双色）
    static var iconTile: Color { Look.shared.palette.tile }

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        #if canImport(UIKit)
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
        #else
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
        #endif
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#else
extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#endif

/// 圆角方块头像：有图显示图，没有就显示首字（和图标同一种双色：橙色字 + 淡橙底）
struct Avatar: View {
    var text: String
    var image: Image?
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Theme.iconTile
                Text(text).font(.appFixed(size: size * 0.4, weight: .semibold)).foregroundStyle(Theme.claude)
                    .minimumScaleFactor(0.5).lineLimit(1).padding(2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

/// 全 App 统一的图标：品牌橙的图形放在淡橙色圆角方块里——只有这一种双色样式。
/// 危险操作（中断、删除）传 tint: Theme.removed
struct TarsIcon: View {
    let symbol: String
    var size: CGFloat = 28
    var tint: Color = Theme.claude

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint == Theme.claude ? Theme.iconTile : tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// 读取失败：图标 + 原因 + 「重试」（照系统空状态的样子）。原来只在页面正中放一行灰字，也没法重试
struct LoadFailed: View {
    let error: String
    let retry: () async -> Void
    @State private var busy = false

    var body: some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button {
                busy = true
                Task {
                    await retry()
                    busy = false
                }
            } label: {
                if busy { ProgressView() } else { Text("重试") }
            }
            .buttonStyle(.bordered)
            .disabled(busy)
        }
    }
}

extension View {
    /// 导航栏右上角挨在一起的图标按钮（会话列表的铃铛和齿轮、对话页的喇叭和「⋯」）：统一占位，几处间距一样
    func barIcon() -> some View { frame(width: 29, height: 36).contentShape(Rectangle()) }
}

extension Font {
    /// 界面字号：iPhone 上就是系统的文字档位（跟着系统「字体大小」或设置里选的字号走）；
    /// Mac 上系统档位小一圈（正文 13），照网页版的字号来（正文 14），再乘设置里的字号倍数。字体都换成设置里选的（Look）
    static func ui(_ style: Font.TextStyle, design: Font.Design? = nil) -> Font {
        #if os(macOS)
        let size: CGFloat = switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 19
        case .title3: 16
        case .headline, .body: 14
        case .callout: 13.5
        case .subheadline: 13
        case .footnote: 12
        case .caption: 11.5
        case .caption2: 11
        @unknown default: 14
        }
        return Look.shared.font(size: size * Look.shared.textScale, weight: style == .headline ? .semibold : nil, design: design)
        #else
        return Look.shared.font(style, design: design)
        #endif
    }

    /// 列表的分组标题。根上设了正文字体（lookRoot：全 App 换成选的字体），分组标题、说明不写明字号就会被撑成正文大小，
    /// 所以照系统原生的写明：标题 iOS 26 起 15 号半粗、更早 13 号（说明一律 .ui(.footnote)）。Mac 上照旧跟随
    static var sectionHeader: Font? {
        #if os(macOS)
        nil
        #else
        if #available(iOS 26.0, *) { return ui(.subheadline).weight(.semibold) }
        return ui(.footnote)
        #endif
    }
}

#if os(macOS)
// MARK: 颜色（照网页版的 --surface / --sep 这些）

enum MacPalette {
    static let surface = Theme.dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let surface2 = Theme.dynamic(light: 0xF7F7F8, dark: 0x2C2C2E)
    static let separator = Theme.dynamic(light: 0x3C3C43, dark: 0x545458, lightAlpha: 0.18, darkAlpha: 0.6)
    /// 分屏的标签栏：压在对话底色上的一层暗色（标签本身是对话底色，和下面的对话连成一片）
    static let tabStrip = Theme.dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.055, darkAlpha: 0.32)
    static let text2 = Theme.dynamic(light: 0x3C3C43, dark: 0xEBEBF5, lightAlpha: 0.8, darkAlpha: 0.8)
    static let text3 = Theme.dynamic(light: 0x3C3C43, dark: 0xEBEBF5, lightAlpha: 0.6, darkAlpha: 0.6)
    static let red = Color(hex: 0xFF3B30)
}
#endif

// MARK: 细边框

extension InsettableShape {
    /// 细于 1 像素的内描边（0.5pt 这种）。1x 屏（10-31 实测的 5120×1440 带鱼屏）上 0.5pt 正好半个像素，系统按图层边框画时
    /// 顶边中间那段整个丢掉、只剩圆角和另外三边（输入框上边框缺失）：不到 1 像素就画 1 像素、按比例减淡，
    /// 看上去和原来一样细、四条边一样深。视网膜屏、iPhone 上 0.5pt 已经够 1 像素，照原样画
    public func hairlineBorder<S: ShapeStyle>(_ style: S, width: CGFloat = 0.5) -> some View {
        HairlineBorder(shape: self, style: style, width: width)
    }
}

private struct HairlineBorder<Outline: InsettableShape, Style: ShapeStyle>: View {
    let shape: Outline
    let style: Style
    let width: CGFloat
    @Environment(\.displayScale) private var scale

    var body: some View {
        let pixels = width * scale
        if pixels < 1 {
            shape.strokeBorder(style.opacity(pixels), lineWidth: 1 / scale)
        } else {
            shape.strokeBorder(style, lineWidth: width)
        }
    }
}

extension View {
    /// 卡片上的大按钮（允许 / 拒绝、批准 / 继续规划、确定 / 不回答）。iPhone 用系统的胶囊按钮；
    /// Mac 上系统按钮在窗口没激活时会变灰，照网页版画成固定的色块：主按钮是主题的主按钮色（经典主题是绿）白字，另一个浅灰底
    @ViewBuilder
    func cardButton(prominent: Bool) -> some View {
        #if os(macOS)
        buttonStyle(CardButtonStyle(prominent: prominent))
        #else
        modifier(CardButtonSize(prominent: prominent))
        #endif
    }
}

#if os(iOS)
/// 卡片按钮平时是大号的；横着的 iPhone 高度只有三百多点，用常规大小（10-27）
private struct CardButtonSize: ViewModifier {
    @Environment(\.verticalSizeClass) private var vertical
    let prominent: Bool

    func body(content: Content) -> some View {
        let size: ControlSize = vertical == .compact ? .regular : .large
        if prominent {
            content.buttonStyle(.steady(.borderedProminent)).buttonBorderShape(.capsule).controlSize(size).tint(Theme.wechatGreen)
        } else {
            content.buttonStyle(.steady(.bordered)).buttonBorderShape(.capsule).controlSize(size)
        }
    }
}
#endif

#if os(macOS)
private struct CardButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, prominent: prominent)
    }

    private struct Face: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(prominent ? Theme.wechatGreen : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
#endif

/// Mac 上鼠标指到能点的一整行时，垫一层淡淡的底色（手机上没有鼠标，什么都不做）
/// 会话页（对话内容）的排版，照 VS Code 里 Claude Code 面板的样式（用户的 VS Code 是默认设置）：
/// 正文 = VS Code 聊天字号 13px，整块行高 1.5；代码 = 编辑器字体 Menlo、0.9em；段落、列表、标题、代码块的间距
/// 按它的样式表和浏览器默认值（em 换算成点）。跟着设置里的字号等比放大（iPhone「跟随系统」= 系统「文字大小」，默认档就是 13）；
/// 正文换成设置里选的字体，代码始终是 Menlo
enum ChatType {
    static func scaled(_ size: CGFloat) -> CGFloat { size * Look.shared.chatScale }

    /// 1em：正文字号。Mac 照 VS Code 的 13；iPhone 和首页列表的会话标题一样大（17）——13 在手机上太小（10-21）
    static var size: CGFloat {
        #if os(iOS)
        scaled(17)
        #else
        scaled(13)
        #endif
    }
    /// VS Code 里按 13 号字定的间距（气泡内边距、消息之间的空、工具行间距……），跟着字号等比放大：Mac 上就是原值
    static func px(_ value: CGFloat) -> CGFloat { value * size / 13 }
    static var body: Font { .appFixed(size: size) }
    /// 行高 1.5：系统字体本身一行约 1.2 倍字号（中文英文一样，实测 13 号 16 点），差的 0.3 倍用行间距补
    static func lineSpacing(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.3 }
    static var lineSpacing: CGFloat { lineSpacing(size) }
    /// 代码（行内、代码块）：0.9em 的 Menlo
    static var codeSize: CGFloat { size * 0.9 }
    static var code: Font { .custom("Menlo", fixedSize: codeSize) }
    /// 工具调用后面那串参数：0.85em 等宽
    static var detail: Font { .custom("Menlo", fixedSize: size * 0.85) }

    /// 气泡、工具卡片的内边距和圆角。原先照 VS Code 的上下 4、左右 6、圆角 6，字贴着边、显得挤（10-22），放宽：
    /// Mac 上下 8、左右 12、圆角 10；iPhone 一行字宽本来就少，左右收一点（约 9 / 12 / 10.5）
    #if os(iOS)
    static var padV: CGFloat { px(7) }
    static var padH: CGFloat { px(9.5) }
    static var radius: CGFloat { px(8) }
    #else
    static var padV: CGFloat { px(8) }
    static var padH: CGFloat { px(12) }
    static var radius: CGFloat { px(10) }
    #endif
}

#if os(macOS)
/// Mac：弹出的面板别超出主窗口（窗口最小 820×520，面板太大会伸到窗口外面）
enum MacSheetLimit {
    @MainActor static var size: CGSize {
        let frame = NSApp.mainWindow?.frame ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.frame ?? CGRect(x: 0, y: 0, width: 1180, height: 800)
        return CGSize(width: max(480, frame.width - 40), height: max(360, frame.height - 80))
    }
}
#endif

extension View {
    /// 页面 / 面板里的搜索框。iPhone 用系统的（导航栏下面一条）；Mac 的面板里系统的搜索框会挤进标题栏、把标题挤到内容里去，
    /// 改成放在内容顶上的一条（focus：一打开就能打字）
    @ViewBuilder
    func panelSearch(_ text: Binding<String>, prompt: String, alwaysShown: Bool = false, focus: Bool = false) -> some View {
        #if os(iOS)
        if alwaysShown {
            searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        } else {
            searchable(text: text, prompt: prompt)
        }
        #else
        safeAreaInset(edge: .top, spacing: 0) { MacSearchField(text: text, prompt: prompt, focus: focus) }
        #endif
    }

    /// 面板的「完成」，Esc 也能关：放在右上角（Mac 的面板是能拖动的小窗，「完成」和标题都在小窗的工具栏里，同 FitSheet）
    func doneButton(_ action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成", action: action).keyboardShortcut(.cancelAction).panelToolbarButton() }
        }
    }
}

#if os(macOS)
/// Mac 面板顶上的搜索框（见 panelSearch）
struct MacSearchField: View {
    @Binding var text: String
    let prompt: String
    var focus = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help(L("清除"))
            }
        }
        .font(.ui(.body))
        .padding(.horizontal, 10).frame(height: 30)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))   // 和面板里列表的底色一样，列表滚上来时从下面过
        .onAppear { if focus { focused = true } }
    }
}
#endif

struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
            .onHover { hovering = $0 }
        #else
        content
        #endif
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}
