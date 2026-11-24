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
    /// 选了 VS Code 配色方案时是方案里编辑区的底，否则窗口底色
    static var chatBackground: Color { Look.shared.scheme.map { Color(hex: $0.editor) } ?? Color(nsColor: .windowBackgroundColor) }
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
    /// 首页汇总卡片（白色列表上的浅灰块）。只放在白底上：浅色下和 pageBackground 只差两个色阶，
    /// 压在灰底页面上会和页面融在一起，那里的卡片用 card
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
struct Avatar: KLView {
    var text: String
    var image: Image?
    var size: CGFloat = 48

    var klBody: some View {
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
struct TarsIcon: KLView {
    let symbol: String
    var size: CGFloat = 28
    var tint: Color = Theme.claude

    var klBody: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint == Theme.claude ? Theme.iconTile : tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// 读取失败：图标 + 原因 + 「重试」（照系统空状态的样子）。原来只在页面正中放一行灰字，也没法重试
struct LoadFailed: KLView {
    let error: String
    let retry: () async -> Void
    @State private var busy = false

    var klBody: some View {
        KLUnavailableView {
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
            .kiteButton()
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
    /// 选了 VS Code 配色方案时是方案里标签栏的底（不透明，盖住下面的对话底色）
    static var tabStrip: Color {
        Look.shared.scheme.map { Color(hex: $0.tabs) } ?? Theme.dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.055, darkAlpha: 0.32)
    }
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

private struct HairlineBorder<Outline: InsettableShape, Style: ShapeStyle>: KLView {
    let shape: Outline
    let style: Style
    let width: CGFloat
    @Environment(\.displayScale) private var scale

    var klBody: some View {
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
private struct CardButtonSize: KLViewModifier {
    @Environment(\.verticalSizeClass) private var vertical
    let prominent: Bool

    func klBody(content: Content) -> some View {
        let size: ControlSize = vertical == .compact ? .regular : .large
        if prominent {
            content.buttonStyle(.steady(.borderedProminent)).klButtonBorderShape(.capsule).controlSize(size).tint(Theme.wechatGreen)
        } else {
            content.buttonStyle(.steady(.bordered)).klButtonBorderShape(.capsule).controlSize(size)
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

    private struct Face: KLView {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled

        var klBody: some View {
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
    /// 改成放在内容顶上的一条（focus：一打开就能打字）。
    /// active：iPhone 上搜索中系统会收起导航栏（连同工具栏按钮），要由页面自己退出搜索时传进来（如选文件夹点进下一级后）
    @ViewBuilder
    func panelSearch(_ text: Binding<String>, prompt: String, alwaysShown: Bool = false, focus: Bool = false, active: Binding<Bool>? = nil) -> some View {
        #if os(iOS)
        if let active {
            searchable(text: text, isPresented: active, prompt: prompt)
        } else if alwaysShown {
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
        klBareToolbarItem(.confirmationAction) { Button("完成", action: action).keyboardShortcut(.cancelAction).panelToolbarButton() }
    }
}

#if os(macOS)
/// Mac 面板顶上的搜索框（见 panelSearch）。在新版界面的侧栏里（sideColumn）照侧栏的尺寸规范：离栏边 8、高 28、圆角 6、底色透明（同导航栏的搜索框）
struct MacSearchField: KLView {
    @Binding var text: String
    let prompt: String
    var focus = false
    @FocusState private var focused: Bool
    @Environment(\.sideColumn) private var side

    var klBody: some View {
        HStack(spacing: SideMetric.gap) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help(L("清除"))
            }
        }
        .font(side ? .system(size: SideMetric.Text.body) : .ui(.body))
        .padding(.horizontal, side ? SideMetric.pad : 10).frame(height: side ? SideMetric.control : 30)
        .background(Color.primary.opacity(side ? 0.055 : 0.06), in: RoundedRectangle(cornerRadius: side ? SideMetric.radius : 8, style: .continuous))
        .padding(.horizontal, side ? SideMetric.edge : 16).padding(.vertical, side ? SideMetric.edge : 10)
        .background(side ? Color.clear : Color(nsColor: .controlBackgroundColor))   // 和面板里列表的底色一样，列表滚上来时从下面过
        .onAppear { if focus { focused = true } }
    }
}

/// Mac 新版界面侧栏（导航栏、会话列表、文件侧栏）的尺寸规范（11-21 反馈：所有边距、间距认真核对、统一，写成样式规范）。
/// 规范全文在 docs/platforms/mac-app.md「新版界面样式规范」；新写侧栏里的东西一律用这里的数，不另写魔法数。
/// 横向只有一条对齐线：栏边 → 框（搜索框、行的选中底、用量条、按钮）8 点，框 → 内容 8 点，所以文字、图标都从离栏边 16 点处起；右边同样
public enum SideMetric {
    /// 栏边 → 框（搜索框、行的选中底、用量条、按钮的外沿）
    public static let edge: CGFloat = 8
    /// 框 → 框里的内容
    public static let pad: CGFloat = 8
    /// 栏边 → 内容（文字、图标）的对齐线 = edge + pad
    public static let inset: CGFloat = 16
    /// 一行里图标和文字、文字和文字之间
    public static let gap: CGFloat = 6
    /// 行的上下内边距（两三行字的会话行、项目行）
    public static let rowPad: CGFloat = 6
    /// 小节标题的高（可折叠的「会话」「文件」，同 VS Code 的 22）
    public static let header: CGFloat = 22
    /// 输入框、带字的按钮
    public static let control: CGFloat = 28
    /// 图标按钮、状态栏里的项
    public static let small: CGFloat = 22
    /// 状态栏的高
    public static let bar: CGFloat = 24
    /// 框、行、按钮的圆角（胶囊按钮除外）
    public static let radius: CGFloat = 6

    /// 字号：四档，加粗只用在标题和选中
    public enum Text {
        /// 栏标题、输入框、项目名（栏顶上那个）
        public static let title: CGFloat = 13
        /// 输入框里的字
        public static let body: CGFloat = 13
        /// 行的标题（会话、项目、待办、收藏）、按钮
        public static let row: CGFloat = 12
        /// 行的第二行（状态）、小节标题、状态栏
        public static let caption: CGFloat = 11
        /// 第三行（设备 · 目录）、时间
        public static let meta: CGFloat = 10.5
    }
}

private struct SideColumnKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 在 Mac 新版界面的侧栏里（搜索框、列表的边距照 SideMetric）
    public var sideColumn: Bool {
        get { self[SideColumnKey.self] }
        set { self[SideColumnKey.self] = newValue }
    }
}
#endif

struct HoverHighlight: KLViewModifier {
    @State private var hovering = false

    func klBody(content: Content) -> some View {
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

// MARK: 按钮样式规范（11-21 反馈：所有按钮样式保持一致；规范全文在 docs/platforms/mac-app.md「按钮样式规范」）

/// 按钮的数：全 App 只有这两个尺寸、一种形状（小圆角矩形，参照 VS Code）、两种状态。新写、改按钮一律用 `.kite` / `.kiteProminent`，不另写样式
/// 弹窗（面板）的边距规范（11-21 反馈：边距、间距统一）：内容四边 16、各块之间 12；底部按钮条左右 16、上下 12
public enum DialogMetric {
    public static let pad: CGFloat = 16
    public static let gap: CGFloat = 12
    public static let barV: CGFloat = 12
}

public enum KiteMetric {
    /// 紧凑（侧栏、工具条、一行里的小按钮、筛选胶囊）高 / 标准（弹窗、表单、独占一行的按钮）高
    public static let compact: CGFloat = 26
    public static let regular: CGFloat = 32
    /// 左右内边距：紧凑 11（同 VS Code）、标准 16；图标和字、字和角标之间 6（= SideMetric.gap）；圆角 6（= SideMetric.radius）
    public static let padCompact: CGFloat = 11
    public static let padRegular: CGFloat = 16
    public static let gap: CGFloat = 6
    public static let radius: CGFloat = 6
    /// 描边 1（1x 屏上也画满 1 像素）；普通按钮的描边比底色重：底色 6%、描边 28%
    public static let border: CGFloat = 1
}

public enum KiteSize { case compact, regular }

private struct KiteProminentKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 当前按钮是不是亮起（主题色底）：里面的角标反色用
    var kiteProminent: Bool {
        get { self[KiteProminentKey.self] }
        set { self[KiteProminentKey.self] = newValue }
    }
}

/// 统一按钮：小圆角矩形 + 描边（同 VS Code 的按钮）。普通 = 淡底 + 比底重的描边 + 主色字；选中 / 主要 = 主题色亮起 + 白字。
/// 悬停略亮、按下略暗、禁用 45%。字号：紧凑 12 粗体、标准 13 粗体，跟「设置 → 外观」的字号倍数走
public struct KiteButtonStyle: ButtonStyle {
    public var prominent: Bool
    public var size: KiteSize
    public var expand: Bool

    public init(prominent: Bool = false, size: KiteSize = .compact, expand: Bool = false) {
        self.prominent = prominent
        self.size = size
        self.expand = expand
    }

    public func makeBody(configuration: Configuration) -> some View {
        KiteButtonBody(configuration: configuration, style: self)
    }

    private struct KiteButtonBody: KLView {
        let configuration: ButtonStyleConfiguration
        let style: KiteButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var klBody: some View {
            let height = style.size == .compact ? KiteMetric.compact : KiteMetric.regular
            let pad = style.size == .compact ? KiteMetric.padCompact : KiteMetric.padRegular
            let pressed = configuration.isPressed
            configuration.label
                .font(.app(size: style.size == .compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(style.prominent ? Color.white : Color.primary)
                .padding(.horizontal, pad)
                .frame(maxWidth: style.expand ? .infinity : nil, minHeight: height)
                .background(fill(pressed: pressed), in: shape)
                .overlay(shape.strokeBorder(stroke, lineWidth: KiteMetric.border))
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.45)
                .environment(\.kiteProminent, style.prominent)
                #if os(macOS)
                .onHover { hovering = $0 }
                #endif
        }

        private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: KiteMetric.radius, style: .continuous) }

        private func fill(pressed: Bool) -> Color {
            if style.prominent { return Theme.claude.opacity(pressed ? 0.78 : (hovering ? 0.92 : 1)) }
            return Color.primary.opacity(pressed ? 0.14 : (hovering ? 0.10 : 0.06))
        }

        private var stroke: Color {
            style.prominent ? Color.white.opacity(0.30) : Color.primary.opacity(0.28)
        }
    }
}

extension ButtonStyle where Self == KiteButtonStyle {
    /// 普通按钮（紧凑）
    public static var kite: KiteButtonStyle { KiteButtonStyle() }
    /// 主要 / 选中按钮：主题色亮起（紧凑）
    public static var kiteProminent: KiteButtonStyle { KiteButtonStyle(prominent: true) }
    public static func kite(prominent: Bool = false, size: KiteSize = .compact, expand: Bool = false) -> KiteButtonStyle {
        KiteButtonStyle(prominent: prominent, size: size, expand: expand)
    }
}

extension View {
    /// 按钮样式规范在 Mac 上生效；iPhone / iPad 先保留系统样式（触控尺寸另有要求）
    @ViewBuilder
    public func kiteButton(prominent: Bool = false, size: KiteSize = .compact, expand: Bool = false) -> some View {
        #if os(macOS)
        buttonStyle(KiteButtonStyle(prominent: prominent, size: size, expand: expand))
        #else
        if prominent { buttonStyle(.borderedProminent).tint(Theme.claude) } else { buttonStyle(.bordered) }
        #endif
    }
}

/// 按钮里的角标（待推送 2、待拉取 3）：普通按钮里主题色底白字，亮起的按钮里反过来白底主题色字
public struct KiteBadge: KLView {
    let count: Int
    @Environment(\.kiteProminent) private var prominent

    public init(_ count: Int) { self.count = count }

    public var klBody: some View {
        Text("\(count)")
            .font(.app(size: 10, weight: .bold)).monospacedDigit()
            .foregroundStyle(prominent ? Theme.claude : Color.white)
            .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
            .background(prominent ? Color.white : Theme.claude, in: Capsule())
    }
}

/// 按钮里的内容：可选图标 + 文字 + 可选角标，间距统一 6
public struct KiteLabel: KLView {
    let title: String?
    let symbol: String?
    let badge: Int

    public init(_ title: String? = nil, symbol: String? = nil, badge: Int = 0) {
        self.title = title
        self.symbol = symbol
        self.badge = badge
    }

    public var klBody: some View {
        HStack(spacing: KiteMetric.gap) {
            if let symbol { Image(systemName: symbol) }
            if let title { Text(title) }
            if badge > 0 { KiteBadge(badge) }
        }
    }
}

extension View {
    /// 只套按钮的外观（字号、内边距、高、底、描边），不管点击：给「放在菜单 / 自己的 Button 里、用 .plain 样式」的标签用，
    /// 看上去和 KiteButtonStyle 完全一样。prominent = 选中 / 非默认，主题色亮起
    public func kiteLook(prominent: Bool = false, size: KiteSize = .compact) -> some View {
        modifier(KiteLook(prominent: prominent, size: size))
    }
}

private struct KiteLook: KLViewModifier {
    let prominent: Bool
    let size: KiteSize

    func klBody(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: KiteMetric.radius, style: .continuous)
        content
            .font(.app(size: size == .compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, size == .compact ? KiteMetric.padCompact : KiteMetric.padRegular)
            .frame(minHeight: size == .compact ? KiteMetric.compact : KiteMetric.regular)
            .background(prominent ? Theme.claude : Color.primary.opacity(0.06), in: shape)
            .overlay(shape.strokeBorder(prominent ? Color.white.opacity(0.30) : Color.primary.opacity(0.28), lineWidth: KiteMetric.border))
            .contentShape(shape)
            .environment(\.kiteProminent, prominent)
    }
}

extension Font {
    /// 输入框下面那排小按钮里的字：Mac 同统一按钮（12 粗），手机照旧小字
    static var chip: Font {
        #if os(macOS)
        .app(size: 12, weight: .semibold)
        #else
        .ui(.caption)
        #endif
    }
}

extension View {
    /// 输入框下面那排小按钮的外观：Mac 套统一按钮外观（高 26、描边，见 KiteMetric），手机保持原来的胶囊
    @ViewBuilder
    public func chipFace(height: CGFloat, hPad: CGFloat = 9) -> some View {
        #if os(macOS)
        kiteLook()
        #else
        padding(.horizontal, hPad).frame(height: height).background(Theme.field, in: Capsule())
        #endif
    }
}

/// 横向滚动的一排（芯片、筛选、标签）：Mac 上给一条悬浮的细滚动条——平时看不见、不占高度不挤内容，
/// 滚动或鼠标移到底边时出来，鼠标能拖着它横着看（11-21 反馈：没有横向滚轮的鼠标没法横着拖）；iPhone / iPad 手指划，不要
public let kiteScrollIndicators: Bool = {
    #if os(macOS)
    true
    #else
    false
    #endif
}()

public struct KiteHScroll<Content: View>: KLView {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var klBody: some View {
        #if os(macOS)
        // 滚动条画在按钮下面多出来的 10 点里，再把这 10 点从外面收回去：不占这一排的高度，也不盖在按钮的字上
        //（11-21 自测：粗滚动条横穿输入框下面那排按钮的正中间）
        ScrollView(.horizontal, showsIndicators: kiteScrollIndicators) {
            content.padding(.bottom, 10).background(OverlayScrollerHook())
        }
        .padding(.bottom, -10)
        #else
        ScrollView(.horizontal, showsIndicators: kiteScrollIndicators) { content }
        #endif
    }
}

#if os(macOS)
/// 找到外面那个 NSScrollView，滚动条一律用悬浮样式（接了鼠标时系统默认是常驻的粗条，会占掉一排的高度）
struct OverlayScrollerHook: NSViewRepresentable {
    func makeNSView(context: Context) -> HookView { HookView() }
    func updateNSView(_ view: HookView, context: Context) { view.apply() }

    final class HookView: NSView {
        private var observer: NSObjectProtocol?
        private var styleWatch: NSKeyValueObservation?
        private weak var hooked: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                Self.force(scroll)
                // SwiftUI 自己也会按系统设置把样式改回常驻的粗条（接了鼠标时），盯着改回来（11-21 自测：粗条盖住了输入框下面那排按钮）
                if self.hooked !== scroll {
                    self.hooked = scroll
                    self.styleWatch = scroll.observe(\.scrollerStyle, options: [.new]) { scroll, _ in
                        if scroll.scrollerStyle != .overlay { DispatchQueue.main.async { Self.force(scroll) } }
                    }
                }
            }
        }

        private static func force(_ scroll: NSScrollView) {
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            scroll.autohidesScrollers = true
            scroll.horizontalScroller?.controlSize = .small   // 细一点
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
        }
    }
}
#endif
