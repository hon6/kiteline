import SwiftUI
#if canImport(UIKit)
import UIKit
typealias RichFont = UIFont
typealias RichColor = UIColor
#else
import AppKit
typealias RichFont = NSFont
typealias RichColor = NSColor
#endif

/// 能随意拖选的正文（同 VS Code）：SwiftUI 的 Text 一段一个，选字到换行就断（Mac 只能在一段里选，iPhone 根本选不了一部分）。
/// 这里把连着的段落、标题、列表、引用拼成一段富文本，交给系统的文字控件（Mac NSTextView、iPhone UITextView）画：
/// Mac 上直接拖着选、右键有拷贝和气泡菜单；iPhone 长按选词、拖两头的把手扩大，菜单里有复制和气泡菜单的操作。
/// 代码块、表格还是单独画（自带右上角拷贝钮）。
extension EnvironmentValues {
    /// MarkdownView 里的段落、标题、列表改用能拖选的系统文字控件（对话里的消息打开；确认框、收藏这些地方照旧）
    @Entry var markdownSelectable = false
    /// 气泡的菜单（引用、加入待办、翻译……）：系统文字控件自己接了长按 / 右键，这些操作要放进它的菜单
    @Entry var richMenu: [MenuAction] = []
    /// 富文本的字色：助手的消息正文色、我的气泡里的字色
    @Entry var richTone = RichTone.primary
}

enum RichTone: String {
    case primary, secondary, mine

    var color: RichColor {
        switch self {
        case .primary:
            #if canImport(UIKit)
            return .label
            #else
            return .labelColor
            #endif
        case .secondary:
            #if canImport(UIKit)
            return .secondaryLabel
            #else
            return .secondaryLabelColor
            #endif
        case .mine: return RichColor(Theme.meText)
        }
    }
}

enum RichBuilder {
    private static let cache = NSCache<NSString, NSAttributedString>()

    /// 能拼进一段富文本的块：段落、标题、列表、只含这些的引用
    static func isProse(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph, .heading, .list: return true
        case .quote(let inner): return inner.allSatisfy(isProse)
        case .code, .table, .rule: return false
        }
    }

    // MARK: 字体（同 Look.font：选了中文字体用它，否则系统字体按选的风格）

    static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> RichFont {
        #if canImport(UIKit)
        var font: UIFont
        if let name = Look.shared.cjkFont, let custom = UIFont(name: name, size: size) {
            font = custom
        } else {
            font = .systemFont(ofSize: size)
            let design: UIFontDescriptor.SystemDesign? = switch Look.shared.font.designName {
            case "rounded": .rounded
            case "serif": .serif
            case "monospaced": .monospaced
            default: nil
            }
            if let design, let descriptor = font.fontDescriptor.withDesign(design) { font = UIFont(descriptor: descriptor, size: size) }
        }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if bold || italic, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: size) }
        return font
        #else
        var font: NSFont
        if let name = Look.shared.cjkFont, let custom = NSFont(name: name, size: size) {
            font = custom
        } else {
            font = .systemFont(ofSize: size)
            let design: NSFontDescriptor.SystemDesign? = switch Look.shared.font.designName {
            case "rounded": .rounded
            case "serif": .serif
            case "monospaced": .monospaced
            default: nil
            }
            if let design, let descriptor = font.fontDescriptor.withDesign(design) { font = NSFont(descriptor: descriptor, size: size) ?? font }
        }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if bold || italic { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font }
        return font
        #endif
    }

    static var codeFont: RichFont { RichFont(name: "Menlo", size: ChatType.codeSize) ?? font(ChatType.codeSize) }

    private static var styleKey: String { "\(ChatType.size)|\(Look.shared.font.id)|\(Look.shared.cjkFont ?? "")" }

    // MARK: 拼富文本

    /// 一串 Markdown 块（都是 isProse 的）拼成一段富文本；块之间的空和 MarkdownView 一样（取上一块下边距和这一块上边距里大的）
    static func attributed(_ blocks: [MarkdownBlock], flat: Bool, tone: RichTone) -> NSAttributedString {
        let key = "md|\(styleKey)|\(flat)|\(tone.rawValue)|\(blocks.hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let out = NSMutableAttributedString()
        append(blocks, to: out, indent: 0, flat: flat, tone: tone, first: true)
        cache.setObject(out, forKey: key)
        return out
    }

    /// 纯文字（用户发的消息、思考内容）：不解析 Markdown，换行照原样
    static func plain(_ text: String, tone: RichTone, size: CGFloat? = nil) -> NSAttributedString {
        let size = size ?? ChatType.size
        let key = "plain|\(styleKey)|\(size)|\(tone.rawValue)|\(text)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = ChatType.lineSpacing(size)
        let out = NSAttributedString(string: text, attributes: [.font: font(size), .foregroundColor: tone.color, .paragraphStyle: style])
        cache.setObject(out, forKey: key)
        return out
    }

    private static func margin(_ block: MarkdownBlock, _ flat: Bool) -> (top: CGFloat, bottom: CGFloat) {
        let em = ChatType.size
        switch block {
        case .paragraph: return (0.1 * em, 0.7 * em)
        case .heading(let level, _):
            if flat { return (0.4 * em, 0.3 * em) }
            let m = headingSize(level, flat) * [0.67, 0.83, 1, 1.33, 1.67, 2.33][min(max(level, 1), 6) - 1]
            return (m, m)
        case .quote, .list: return (em, em)
        default: return (0, 0)
        }
    }

    static func headingSize(_ level: Int, _ flat: Bool) -> CGFloat {
        flat ? ChatType.size : ChatType.size * [2, 1.5, 1.17, 1, 0.83, 0.67][min(max(level, 1), 6) - 1]
    }

    private static func append(_ blocks: [MarkdownBlock], to out: NSMutableAttributedString, indent: CGFloat, flat: Bool, tone: RichTone, first: Bool) {
        let em = ChatType.size
        for (index, block) in blocks.enumerated() {
            let isFirst = first && index == 0
            let before: CGFloat = isFirst ? 0 : max(index > 0 ? margin(blocks[index - 1], flat).bottom : 0, margin(block, flat).top)
            switch block {
            case .paragraph(let text):
                paragraph(inline(text, size: em, bold: false, tone: tone), to: out, indent: indent, before: before, size: em, first: isFirst)
            case .heading(let level, let text):
                let size = headingSize(level, flat)
                paragraph(inline(text, size: size, bold: true, tone: tone), to: out, indent: indent, before: before, size: size, first: isFirst)
            case .list(_, let items):
                for (i, item) in items.enumerated() {
                    // 同 MarkdownView：每级缩进 2em，序号 / 圆点在这 2em 里靠右（离正文 6），折行的字对齐正文
                    let left = indent + CGFloat(item.indent) * 2 * em
                    let line = NSMutableAttributedString(string: "\t", attributes: [.font: font(em)])
                    line.append(NSAttributedString(string: item.marker, attributes: [.font: font(em), .foregroundColor: RichTone.secondary.color]))
                    line.append(NSAttributedString(string: "\t", attributes: [.font: font(em)]))
                    line.append(inline(item.text, size: em, bold: false, tone: tone))
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = ChatType.lineSpacing(em)
                    style.tabStops = [NSTextTab(textAlignment: .right, location: left + 2 * em - 6), NSTextTab(textAlignment: .left, location: left + 2 * em)]
                    style.firstLineHeadIndent = left
                    style.headIndent = left + 2 * em
                    style.paragraphSpacingBefore = i == 0 ? before : 0.3 * em
                    finish(line, style: style, to: out, first: isFirst && i == 0)
                }
            case .quote(let inner):
                // 浏览器默认的引用：左边缩进 40
                let start = out.length
                append(inner, to: out, indent: indent + 40, flat: flat, tone: tone, first: isFirst)
                // 引用第一段顶上的空：按引用这一块算
                if out.length > start, !isFirst {
                    let at = start + 1 < out.length ? start + 1 : start
                    if let style = (out.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                        style.paragraphSpacingBefore = before
                        var range = NSRange()
                        _ = out.attribute(.paragraphStyle, at: at, effectiveRange: &range)
                        out.addAttribute(.paragraphStyle, value: style, range: range)
                    }
                }
            case .code, .table, .rule:
                break
            }
        }
    }

    private static func paragraph(_ text: NSAttributedString, to out: NSMutableAttributedString, indent: CGFloat, before: CGFloat, size: CGFloat, first: Bool) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = ChatType.lineSpacing(size)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacingBefore = before
        finish(text, style: style, to: out, first: first)
    }

    /// 段与段之间用换行隔开；一段里的换行换成「行分隔符」，不然每行都算新的一段、各自加上段前的空
    private static func finish(_ text: NSAttributedString, style: NSParagraphStyle, to out: NSMutableAttributedString, first: Bool) {
        let line = NSMutableAttributedString(attributedString: text)
        var search = NSRange(location: 0, length: line.length)
        while true {
            let found = (line.string as NSString).range(of: "\n", options: [], range: search)
            if found.location == NSNotFound { break }
            line.replaceCharacters(in: found, with: "\u{2028}")
            search = NSRange(location: found.location + 1, length: line.length - found.location - 1)
        }
        if out.length > 0 {
            out.append(NSAttributedString(string: "\n", attributes: [.font: font(ChatType.size), .paragraphStyle: style]))
        }
        let start = out.length
        out.append(line)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: line.length))
        if line.length == 0, out.length > 0 {
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: out.length - 1, length: 1))
        }
    }

    /// 行内 Markdown（粗体、斜体、删除线、`代码`、链接）：照 Markdown.inline 解析（裸网址、文件路径、claude.ai 链接的处理都在那里），换成系统富文本
    private static func inline(_ text: String, size: CGFloat, bold: Bool, tone: RichTone) -> NSAttributedString {
        let parsed = Markdown.inline(text)
        let out = NSMutableAttributedString()
        let codeBackground = RichTone.primary.color.withAlphaComponent(0.08)
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: tone.color]
            if intent.contains(.code) {
                attributes[.font] = codeFont
                attributes[.backgroundColor] = codeBackground
            } else {
                attributes[.font] = font(size, bold: bold || intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized))
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }

    // MARK: 量尺寸（TextKit 1，和下面的文字控件用同一套排版）

    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}

/// 一段能拖选的富文本。fill：撑满给的宽度；false 时贴着最长的一行（气泡跟着字走）
struct RichText: View {
    let text: NSAttributedString
    var fill = true
    @Environment(\.richMenu) private var menu
    @Environment(\.openURL) private var openURL

    var body: some View {
        RichTextHost(text: text, fill: fill, link: RichColor(Theme.claude), menu: menu, open: openURL)
    }
}

class RichCoordinator: NSObject {
    var text: NSAttributedString?
    var menu: [MenuAction] = []
    var open: OpenURLAction?
    private var sizes: [CGFloat: CGSize] = [:]
    #if os(macOS)
    var targets: [RichMenuTarget] = []
    #endif

    func set(_ new: NSAttributedString) -> Bool {
        guard text !== new else { return false }
        text = new
        sizes = [:]
        return true
    }

    func size(_ text: NSAttributedString, width proposed: CGFloat?, fill: Bool) -> CGSize {
        if self.text !== text { _ = set(text) }
        let width = (proposed.map { $0.isFinite && $0 > 0 ? $0 : 10_000 }) ?? 10_000
        if let hit = sizes[width] { return hit }
        let used = RichBuilder.measure(text, width: width)
        // 贴着字宽时多给 1 点：宽度取整差零点几会让最长的一行在画的时候折下去
        let size = CGSize(width: fill && width < 10_000 ? width : min(width, used.width + 1), height: max(used.height, 1))
        sizes[width] = size
        return size
    }
}

#if canImport(UIKit)
struct RichTextHost: UIViewRepresentable {
    let text: NSAttributedString
    let fill: Bool
    let link: RichColor
    let menu: [MenuAction]
    let open: OpenURLAction

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1：和 RichBuilder.measure 同一套排版，量出来的高度和画出来的一致
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.menu = menu
        context.coordinator.open = open
        view.linkTextAttributes = [.foregroundColor: link]
        if context.coordinator.set(text) || view.attributedText.length != text.length { view.attributedText = text }
        #if SNAPSHOT
        // 截图版：TARS_DEMO_RICHSELECT=<一段字> 选中含这段字的那块里从这段字到末尾（看跨段选中的样子）
        if let mark = ProcessInfo.processInfo.environment["TARS_DEMO_RICHSELECT"], !mark.isEmpty {
            let found = (text.string as NSString).range(of: mark)
            if found.location != NSNotFound {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    view.becomeFirstResponder()
                    view.selectedRange = NSRange(location: found.location, length: text.length - found.location)
                }
            }
        }
        #endif
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        context.coordinator.size(text, width: proposal.width, fill: fill)
    }

    final class Coordinator: RichCoordinator, UITextViewDelegate {
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content, let open {
                return UIAction { _ in open(url) }
            }
            return defaultAction
        }

        /// 选中文字后的菜单：系统的复制、全选……后面接上气泡的操作（引用、加入待办、翻译……）
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard !menu.isEmpty else { return nil }
            let extra = menu.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { _ in
                    textView.selectedRange = NSRange(location: 0, length: 0)
                    action.run()
                }
            }
            return UIMenu(children: suggestedActions + [UIMenu(options: .displayInline, children: extra)])
        }
    }
}
#else
/// 点别处时收起选中（同网页）：不然几条消息各留一块灰色的选区
final class RichNSTextView: NSTextView {
    override func resignFirstResponder() -> Bool {
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        return super.resignFirstResponder()
    }
}

final class RichMenuTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

struct RichTextHost: NSViewRepresentable {
    let text: NSAttributedString
    let fill: Bool
    let link: RichColor
    let menu: [MenuAction]
    let open: OpenURLAction

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RichNSTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let view = RichNSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: RichNSTextView, context: Context) {
        context.coordinator.menu = menu
        context.coordinator.open = open
        view.linkTextAttributes = [.foregroundColor: link, .cursor: NSCursor.pointingHand]
        if context.coordinator.set(text) || view.textStorage?.length != text.length { view.textStorage?.setAttributedString(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RichNSTextView, context: Context) -> CGSize? {
        context.coordinator.size(text, width: proposal.width, fill: fill)
    }

    final class Coordinator: RichCoordinator, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let open else { return false }
            open(url)
            return true
        }

        /// 右键菜单：系统的拷贝……后面接上气泡的操作
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard !self.menu.isEmpty else { return menu }
            targets = self.menu.map { RichMenuTarget($0.run) }
            menu.addItem(.separator())
            for (action, target) in zip(self.menu, targets) {
                let item = NSMenuItem(title: action.title, action: #selector(RichMenuTarget.fire), keyEquivalent: "")
                item.target = target
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            return menu
        }
    }
}
#endif
