#if KITELINE_MAC
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Mac 主窗口对话页底部的输入区，排法和间距同手机（所有看得见的间距都是 Bar.spacing）：
/// 常用语（平时收着，点下面那排最右边的「⌃」才出来；可换行，点一下直接发，长按放进输入框，最后一个铅笔去编辑）、附图、
/// 输入框（回车发送，Shift+回车换行，输入法选字的回车不算），Claude 在干活时红色停止键，空着时「+」选图，有字时绿色「发送」；
/// 输入框下面一排同手机：权限模式、模型和思考等级、上下文、任务清单进度、子 agent。⌘V 粘贴截图、把图拖进窗口都能附上。
/// 群聊页用的也是它（group 不为空）：发到群里，下面那排换成「发给全部成员」
struct MacComposer: View {
    @Environment(AppModel.self) private var model
    let key: String
    let session: SessionInfo?
    let chat: ChatStore
    var onStop: () -> Void = {}
    var onMode: () -> Void = {}
    var onModel: () -> Void = {}
    var onCompact: () -> Void = {}
    var onTodos: () -> Void = {}
    var onAgents: () -> Void = {}
    /// 发到群里（群聊页）：没有停止键、权限模式那排
    var group: ComposeGroup? = nil
    @Environment(\.chatPane) private var pane
    /// 常用语展开着（每个会话各记各的：分屏时点哪块只展开哪块）
    private var quickShown: Bool {
        get { chat.quickRepliesShown }
        nonmutating set { chat.quickRepliesShown = newValue }
    }
    @State private var picking = false
    @State private var focusToken = 0
    @State private var inputHeight: CGFloat = 38

    /// 附图放在这个会话的数据上（拖进对话区的图也加到这里）
    private var attachments: [ComposeAttachment] {
        get { chat.attachments }
        nonmutating set { chat.attachments = newValue }
    }

    private var enabled: Bool { session?.canReply ?? true }
    private var draft: String { model.drafts[key] ?? "" }
    private var hasContent: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    private var quickAvailable: Bool { enabled && !model.quickReplies.isEmpty }
    /// 能附图：会话都能；群要电脑端收得了群里的图（老版本只收文字）
    private var canAttach: Bool { group == nil || model.supportsGroupMedia }

    var body: some View {
        VStack(spacing: Bar.spacing) {
            if quickShown, quickAvailable, !hasContent, !(session?.isWaiting ?? false) {
                quickRow.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !attachments.isEmpty { attachRow }
            // 圆圈按钮左右各空 Bar.iconInset：间隔减掉它，看上去和别处一样是 Bar.spacing
            HStack(alignment: .bottom, spacing: Bar.spacing - Bar.iconInset) {
                MacInputField(text: Binding(get: { model.drafts[key] ?? "" }, set: { model.setDraft(key, $0) }),
                              height: $inputHeight, placeholder: placeholder, enabled: enabled, focusToken: focusToken,
                              onSubmit: send, onPasteImages: add)
                    .frame(height: inputHeight)
                    .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).hairlineBorder(MacPalette.separator))
                    .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
                if let session, session.isBusy, session.canReply {
                    CircleGlyph(kind: .stop, action: onStop).foregroundStyle(MacPalette.red).help(session.isClaude ? L("中断 Claude（等同于在 VS Code 中按 Esc）") : L("中断 %@", "\(session.speaker)"))
                }
                if hasContent {
                    Button(action: send) {
                        Text(L("发送")).font(.app(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 38)
                            .background(Theme.wechatGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!enabled)
                } else {
                    CircleGlyph(kind: .plus) { picking = true }.foregroundStyle(MacPalette.text2).disabled(!enabled || !canAttach).help(L("发送图片"))
                }
            }
            .padding(.trailing, -Bar.iconInset)   // 最右边的圆圈和下面那排右边对齐
            if (session?.canReply ?? false) || group != nil || quickAvailable { chipRow }
        }
        .animation(.snappy(duration: 0.2), value: quickShown)
        .frame(maxWidth: 832)
        .padding(.horizontal, 24).padding(.top, Bar.spacing).padding(.bottom, Bar.edge)
        .frame(maxWidth: .infinity)
        // 点开一个会话就能直接打字（分屏时只有当前块抢输入焦点）
        .onAppear { if pane?.isFocused ?? true { focusToken += 1 } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            add(urls.compactMap { url in try? Data(contentsOf: url) })
        }
    }

    private var placeholder: String {
        if let group {
            let live = model.groups.group(group.id).map(model.isLive) ?? true
            return live ? L("在群里发消息，成员都会收到") : L("发消息，恢复成员会话接着协作")
        }
        guard let session else { return L("发送消息即可在 VS Code 中继续对话") }
        if session.canReply { return L("发消息给 %@", "\(session.speaker)") }
        return session.readOnlyNote
    }

    // MARK: 输入框下面那排

    /// 同手机：权限模式、模型、上下文……横着一排（窄的分屏块里横着滚）；最右边「⌃」展开 / 收起常用语
    private var chipRow: some View {
        HStack(spacing: Bar.spacing) {
            ScrollView(.horizontal, showsIndicators: false) {
                if let session, session.canReply {
                    SessionChips(key: key, session: session, chat: chat, onMode: onMode, onModel: onModel,
                                 onCompact: onCompact, onTodos: onTodos, onAgents: onAgents)
                        .padding(.top, Bar.badgeRoom)
                } else if let group {
                    GroupRecipientsChip(target: group).padding(.top, Bar.badgeRoom)
                }
            }
            .padding(.top, -Bar.badgeRoom)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)   // 同手机：别把一排的总宽往上报，撑宽整页
            if quickAvailable {
                Button { quickShown.toggle() } label: {
                    Image(systemName: quickShown ? "chevron.down" : "chevron.up")
                        .font(.app(size: 11, weight: .semibold))
                        .foregroundStyle(quickShown ? Theme.claude : Color.primary.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(quickShown ? Theme.tile : Theme.field, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help(quickShown ? L("收起常用语") : L("常用语"))
                .accessibilityLabel(quickShown ? L("收起常用语") : L("常用语"))
            }
        }
    }

    // MARK: 常用语

    private var quickRow: some View {
        FlowLayout(spacing: Bar.spacing) {
            ForEach(model.quickReplies, id: \.self) { phrase in
                QuickChip(text: phrase) {
                    if let group { model.send(group, text: phrase) } else { model.send(key, text: phrase, images: []) }
                } longPress: {
                    model.setDraft(key, phrase)
                    focusToken += 1
                }
            }
            QuickChip(symbol: "pencil") { KitelineKit.openQuickReplies() }.help(L("编辑快捷短语"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 附图

    private var attachRow: some View {
        HStack(spacing: 10) {
            ForEach(attachments) { item in
                ZStack(alignment: .topTrailing) {
                    if let image = NSImage(data: item.preview) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).hairlineBorder(MacPalette.separator))
                            .zoomableOnClick(attachments.map { .local($0.data) }, index: attachments.firstIndex { $0.id == item.id } ?? 0)
                    }
                    Button { attachments.removeAll { $0.id == item.id } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(Color.black.opacity(0.72), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -7)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 7)   // 右上角的 × 往外探出 7
    }

    /// 加图（粘贴、「+」选的）
    private func add(_ list: [Data]) {
        guard canAttach else { model.flash(L("电脑端的 Kiteline 版本较旧，群里暂不能发图片，请更新")); return }
        Self.attach(list, to: chat)
        focusToken += 1
    }

    /// 压成 JPEG 加进要发的图，一次最多 6 张（拖进对话区的也走这里）
    static func attach(_ list: [Data], to chat: ChatStore) {
        for data in list.prefix(max(0, 6 - chat.attachments.count)) {
            guard let prepared = ImagePrep.prepare(data) else { continue }
            chat.attachments.append(ComposeAttachment(name: "image-\(chat.attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !text.isEmpty || !attachments.isEmpty else { return }
        if let group {
            model.send(group, text: text, images: attachments.map { ($0.name, $0.data, $0.preview) })
        } else {
            model.send(key, text: text, images: attachments.map { ($0.name, $0.data, $0.preview) })
        }
        model.setDraft(key, "")
        attachments = []
    }
}

/// 细线圆圈里一个方块（停止）或加号，28pt，和网页版的图标一样
private struct CircleGlyph: View {
    enum Kind { case stop, plus }
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(lineWidth: 1.6).frame(width: 30, height: 30)
                switch kind {
                case .stop: RoundedRectangle(cornerRadius: 2).frame(width: 10, height: 10)
                case .plus:
                    Path { p in
                        p.move(to: CGPoint(x: 15, y: 9)); p.addLine(to: CGPoint(x: 15, y: 21))
                        p.move(to: CGPoint(x: 9, y: 15)); p.addLine(to: CGPoint(x: 21, y: 15))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: 30, height: 30)
                }
            }
            .frame(width: Bar.iconWidth, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// 常用语小标签：点一下发，按住半秒放进输入框；鼠标移上去变深一点
private struct QuickChip: View {
    var text: String? = nil
    var symbol: String? = nil
    let action: () -> Void
    var longPress: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        Group {
            if let text {
                Text(text).font(.ui(.subheadline)).lineLimit(1).truncationMode(.tail).foregroundStyle(.primary)
            } else if let symbol {
                Image(systemName: symbol).font(.app(size: 12)).foregroundStyle(MacPalette.text3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)   // 有字的、只有铅笔的一样高
        .frame(maxWidth: 360)
        .background(Theme.field, in: Capsule())
        .overlay(Capsule().fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .onLongPressGesture(minimumDuration: 0.48) { longPress?() }
    }
}

// MARK: 输入框（系统文本控件：输入法、回车发送、Shift+回车换行、⌘V 粘贴截图）

struct MacInputField: NSViewRepresentable {
    @Binding var text: String
    /// 跟着字数长：对话输入栏 38 起，最高 132（和网页版一样），再多就在框里滚
    @Binding var height: CGFloat
    let placeholder: String
    let enabled: Bool
    /// 变一下就把光标放进来（点了常用语长按、加了图之后）
    let focusToken: Int
    let onSubmit: () -> Void
    let onPasteImages: ([Data]) -> Void
    var minHeight: CGFloat = 38
    var maxHeight: CGFloat = 132
    /// true = 回车发送、Shift+回车换行（对话输入栏）；false = 回车照常换行，⌘回车交给 onSubmit（记待办这类整段文字）
    var returnSubmits = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 滚动条一律浮在文字上（overlay）：接了鼠标时系统默认占位式滚动条，字数卡在框高附近时它忽隐忽现，
        // 占掉 / 还回一条宽度，文字跟着反复折行跳动（11-09）
        let scroll = OverlayScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        let view = InputTextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 10, height: 9)
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.onPasteImages = onPasteImages
        view.onMarkedText = { [weak coordinator = context.coordinator] in coordinator?.updateHeight() }
        view.placeholder = placeholder
        view.string = text
        // 只收拖进来的文字：拖图进来不要变成一串文件路径，交给对话区当附图（ChatView 的 onDrop）
        view.unregisterDraggedTypes()
        view.registerForDraggedTypes([.string])
        scroll.documentView = view
        context.coordinator.view = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.view else { return }
        // 只在外面真改了内容（发送后清空、常用语填入、换会话）时才写回框里，不拿「框里和草稿不一样」来判断：
        // 输入法组字时系统不发 textDidChange，框里带着没上屏的拼音、草稿还是旧的，这时一刷新就把拼音冲掉
        //（10-23 反馈打中文还没选字经常丢内容：Claude 干活时会话状态一直推，输入区跟着刷）
        if text != context.coordinator.synced {
            if view.hasMarkedText() { view.inputContext?.discardMarkedText() }
            view.string = text
            view.needsDisplay = true
            context.coordinator.synced = text
            // 之前打字的撤销记录对着旧内容的位置，换了内容再撤销会越界
            context.coordinator.undo.removeAllActions()
        }
        view.isEditable = enabled
        view.placeholder = placeholder
        view.onPasteImages = onPasteImages
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                // 正在组字时挪光标会把拼音字母直接上屏
                guard !view.hasMarkedText() else { return }
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            }
        }
        DispatchQueue.main.async { context.coordinator.updateHeight() }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.undo.removeAllActions()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacInputField
        weak var view: InputTextView?
        var focusToken: Int
        /// 框里和草稿上一次对上的内容：草稿变得和它不一样了才是外面改的
        var synced: String
        /// 框自己的撤销记录：默认记在窗口上，框没了（换会话、关新任务面板）记录还在，⌘Z 调到已释放的框直接闪退（10-27）
        let undo = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        init(_ parent: MacInputField) {
            self.parent = parent
            self.focusToken = parent.focusToken
            self.synced = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            // 读回草稿里实际存下的（只有空白的存成空）：不然只打了个空格或 Shift+回车，下次刷新就被清掉
            synced = parent.text
            updateHeight()
        }

        /// 回车发送、Shift+回车换行；输入法还在组字时系统不会走到这里（回车先交给输入法上屏）
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if !parent.returnSubmits {
                guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
                parent.onSubmit()
                return true
            }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        func updateHeight() {
            guard let view, let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let content = manager.usedRect(for: container).height + view.textContainerInset.height * 2
            let next = min(max(parent.minHeight, ceil(content)), parent.maxHeight)
            if abs(next - parent.height) > 0.5 { parent.height = next }
        }
    }
}

/// 滚动条永远是浮层式、不占宽度：系统切换滚动条样式（插拔鼠标、改「显示滚动条」设置）时也不改回占位式
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

/// 带占位字、能把粘贴的截图交出去的文本框
final class InputTextView: NSTextView {
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }
    var onPasteImages: ([Data]) -> Void = { _ in }
    /// 输入法组字时系统不发 textDidChange：拼音折到下一行也要跟着长高
    var onMarkedText: () -> Void = {}

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedText()
    }

    override func paste(_ sender: Any?) {
        let images = Self.pasteboardImages()
        guard !images.isEmpty else { super.paste(sender); return }
        onPasteImages(images)
    }

    // 纯文本框只认剪贴板里的文字：剪贴板里只有截图（没有文字）时，系统把「粘贴」判成不可用，⌘V 只响一声、根本走不到上面的 paste
    //（10-22 反馈 Mac 输入框粘贴不了截图；从访达拷的图片文件带路径，所以那种一直能贴）。剪贴板里有图也算能粘贴
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, Self.hasImage { return true }
        return super.validateMenuItem(item)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, Self.hasImage { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// 剪贴板里能当图贴的格式：系统截图、微信 / QQ 截图、浏览器「拷贝图像」常见的是 PNG、TIFF，也有 JPEG、HEIC、GIF、WebP
    private static let imageTypes: [NSPasteboard.PasteboardType] =
        [.png, .tiff] + [UTType.jpeg, .heic, .gif, .webP].map { NSPasteboard.PasteboardType($0.identifier) }
    private static let imageFiles: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// 剪贴板里有没有能贴的图（只看类型、不读内容：菜单每次检查「粘贴」能不能用都会问）
    static var hasImage: Bool {
        let board = NSPasteboard.general
        return board.canReadObject(forClasses: [NSURL.self], options: imageFiles) || board.availableType(from: imageTypes) != nil
    }

    /// 剪贴板里的图：从访达拷贝的图片文件（最多 6 张）或截图；同时带了一段文字的照常按文字粘贴（只是网址的还是当图）
    static func pasteboardImages() -> [Data] {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: imageFiles) as? [URL], !urls.isEmpty {
            return urls.prefix(6).compactMap { try? Data(contentsOf: $0) }
        }
        guard let type = board.availableType(from: imageTypes) else { return [] }
        if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.hasPrefix("http") {
            return []
        }
        return board.data(forType: type).map { [$0] } ?? []
    }
}
#endif
