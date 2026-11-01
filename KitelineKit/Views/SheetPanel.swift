import SwiftUI
#if os(macOS)
import AppKit
#endif

// 弹出的面板（文件、改动、会话信息、看大图、新任务、确认……）。
// iPhone：照旧是系统的 sheet / 底部确认框。
// Mac：系统的 sheet 钉在窗口顶上、拖不动、改不了大小，还挡住整个窗口。改成独立的小窗：
// 打开时在发起它的会话（分屏里那一块）正中，水平、垂直都居中；按住标题栏或空白处能拖走，拖边角能改大小；
// 挂在主窗口上（跟着主窗口走、压在它上面），不挡别的会话，可以一边开着一边看对话。

extension EnvironmentValues {
    /// 关掉所在的面板（Mac 的面板小窗用；iPhone 一直是 nil，走系统的 dismiss）
    @Entry var closePanel: PanelCloser? = nil
}

/// 关面板的动作（包成类：环境里按同一个对象比较，不会每次刷新都当成变了）
final class PanelCloser {
    let run: () -> Void
    /// 关之前问一声内容（见 panelCloseGuard）：返回 false 就先不关
    var shouldClose: (() -> Bool)?
    /// 面板当成正经窗口（见 panelWindowStyle）
    var setWindowStyle: (Bool) -> Void = { _ in }
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// 面板里的「完成 / 取消」用它代替 `@Environment(\.dismiss)`：Mac 的面板是自己开的小窗，系统的 dismiss 关不掉。
/// 只用在面板最外层的视图上；面板里往里推的页面照旧用系统的 dismiss（那是返回上一页）
@MainActor @propertyWrapper
struct PanelDismiss: DynamicProperty {
    @Environment(\.dismiss) private var system
    @Environment(\.closePanel) private var panel

    init() {}

    var wrappedValue: Action { Action(system: system, panel: panel) }

    struct Action {
        let system: DismissAction
        let panel: PanelCloser?

        @MainActor func callAsFunction() {
            if let panel { panel.run() } else { system() }
        }
    }
}

extension View {
    /// 代替 `.sheet(isPresented:)`：iPhone 照旧；Mac 弹成能拖、能改大小的小窗，在所在会话正中
    public func sheetPanel<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, file: String = #fileID, line: Int = #line,
                                          @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        modifier(SheetPanelModifier(isPresented: isPresented, onDismiss: onDismiss, site: "\(file):\(line)", panel: content))
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    /// 代替 `.sheet(item:)`
    public func sheetPanel<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, file: String = #fileID, line: Int = #line,
                                                              @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(macOS)
        sheetPanel(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }), onDismiss: onDismiss, file: file, line: line) {
            // 换了一项（比如看大图从这张换成那张）：当成新的面板内容，里面的状态从头来（同系统 sheet）
            if let value = item.wrappedValue { content(value).id(value.id) }
        }
        #else
        sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    /// 代替只有一个确认按钮的 `.confirmationDialog`：iPhone 照旧从底部弹出；Mac 弹一张能拖动的小卡片，同样在所在会话正中。
    /// 文字传进来前先 L() 好
    func confirmPanel(_ message: String, isPresented: Binding<Bool>, confirm: String, destructive: Bool = false,
                      cancel: String? = nil, file: String = #fileID, line: Int = #line, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        sheetPanel(isPresented: isPresented, file: file, line: line) {
            ConfirmCard(message: message, confirm: confirm, destructive: destructive, cancel: cancel ?? L("取消"), action: action)
        }
        #else
        confirmationDialog(message, isPresented: isPresented, titleVisibility: .visible) {
            Button(confirm, role: destructive ? .destructive : nil, action: action)
            if let cancel { Button(cancel, role: .cancel) {} }
        }
        #endif
    }

    /// Mac 面板的大小：打开时 width × height（不给 height 就按内容高），之后能拖边放大缩小；iPhone 不管
    public func panelFrame(width: CGFloat, height: CGFloat? = nil, minWidth: CGFloat = 360, minHeight: CGFloat = 200) -> some View {
        #if os(macOS)
        frame(minWidth: min(minWidth, width), idealWidth: width, maxWidth: .infinity,
              minHeight: height.map { min(minHeight, $0) }, idealHeight: height, maxHeight: .infinity)
        #else
        self
        #endif
    }

    /// Mac 面板工具栏里的按钮：用系统字、不染主题色（同系统的工具栏）。面板内容跟着「外观」换字体、字号，
    /// 工具栏按钮要是也跟着，大字号、圆体会撑破系统按标准字号画的玻璃按钮（字溢出、被窗口边裁掉）
    /// 左右各留 6 点：从对话页弹出时，系统把一组按钮画进同一块玻璃底、按内容收得很紧，两头的图标贴着边（10-25 反馈，多列时更明显）。
    /// 不管系统怎么分组，按钮自己带着边距
    public func panelToolbarItem() -> some View {
        #if os(macOS)
        font(.body).tint(Color.primary).padding(.horizontal, 6)
        #else
        self
        #endif
    }

    /// Mac 面板工具栏里的文字按钮（完成、取消……）：自己画成系统的带边框按钮（macOS 26 上就是液态玻璃按钮），系统字、不染主题色。
    /// 交给工具栏套玻璃底的话，有的面板里系统只按字宽套（「完成」比玻璃底还宽、靠右的被窗口边裁掉）
    public func panelToolbarButton() -> some View {
        #if os(macOS)
        font(.body).tint(Color.primary).buttonStyle(PanelTextButtonStyle())
        #else
        self
        #endif
    }

    /// Mac 面板：按住这一块能拖动整个面板（标题一行这类不接点击的地方）
    @ViewBuilder
    public func panelDragArea() -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            gesture(WindowDragGesture()).allowsWindowActivationEvents(true)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Mac 面板：这一块的空白处（按钮、输入框以外）按住能拖动面板
    public func panelDragBackground() -> some View {
        background { Color.clear.contentShape(Rectangle()).panelDragArea() }
    }

    /// Mac 面板当成正经窗口（代码 IDE 这类大工作区）：左上角有红黄绿按钮（关闭、缩放；最小化是灰的——挂在主窗口上的小窗收不进程序坞），
    /// 双击标题栏缩放，Esc 不关（编辑器里 Esc 是收起查找、补全）。挂在面板最外层；iPhone 不管
    public func panelWindowStyle() -> some View {
        #if os(macOS)
        modifier(PanelWindowStyle())
        #else
        self
        #endif
    }

    /// Mac 面板关之前（完成、Esc、⌘W、红色按钮）先问一声：返回 false 就先不关——自己弹确认，用户确认后再关（PanelDismiss）。iPhone 不管
    public func panelCloseGuard(_ check: @escaping () -> Bool) -> some View {
        #if os(macOS)
        modifier(PanelCloseGuard(check: check))
        #else
        self
        #endif
    }

    /// Mac：从这块区域里弹出的面板都对着它居中（主窗口里的每块会话、待办页各挂一个）；不挂的对着整个窗口居中。
    /// key：这块显示的是什么（会话 key）——这块视图被系统重建时，面板认得新的那块还是同一个会话，继续留着
    @ViewBuilder
    public func panelAnchor(key: String? = nil) -> some View {
        #if os(macOS)
        modifier(PanelAnchorMarker(key: key))
        #else
        self
        #endif
    }
}

#if os(macOS)

// MARK: - Mac：面板小窗

extension EnvironmentValues {
    @Entry var panelAnchor: PanelAnchor? = nil
}

/// 面板对着居中的那块区域（记着它在窗口里的视图、显示的是哪个会话）
final class PanelAnchor {
    weak var view: NSView?
    var key: String?
    /// 现在窗口里有的（找同一个会话的新区域用）
    @MainActor private static var all: [Weak] = []
    private struct Weak { weak var anchor: PanelAnchor? }

    @MainActor static func register(_ anchor: PanelAnchor) {
        all.removeAll { $0.anchor == nil || $0.anchor === anchor }
        all.append(Weak(anchor: anchor))
    }

    /// 显示着这个会话的区域（给了窗口就只找这个窗口里的）
    @MainActor static func find(key: String, in window: NSWindow? = nil) -> PanelAnchor? {
        all.lazy.compactMap { $0.anchor }.first { anchor in
            guard anchor.key == key, let home = anchor.view?.window else { return false }
            return window == nil || home === window
        }
    }
}

private struct PanelWindowStyle: ViewModifier {
    @Environment(\.closePanel) private var panel

    func body(content: Content) -> some View {
        content
            .onAppear { panel?.setWindowStyle(true) }
            .onDisappear { panel?.setWindowStyle(false) }
    }
}

private struct PanelCloseGuard: ViewModifier {
    let check: () -> Bool
    @Environment(\.closePanel) private var panel

    func body(content: Content) -> some View {
        content
            .onAppear { panel?.shouldClose = check }
            .onDisappear { panel?.shouldClose = nil }
    }
}

private struct PanelAnchorMarker: ViewModifier {
    let key: String?
    @State private var anchor = PanelAnchor()

    func body(content: Content) -> some View {
        anchor.key = key
        return content
            .background(AnchorProbe(anchor: anchor))
            .environment(\.panelAnchor, anchor)
    }
}

/// 垫在区域底下、和它一样大的空视图：用来量这块区域在屏幕上的位置；不接鼠标
private struct AnchorProbe: NSViewRepresentable {
    let anchor: PanelAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        PanelAnchor.register(anchor)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

private class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 面板开着时垫在发起它的视图底下：知道发起的是哪个窗口；它没了（发起的视图不在了）就看要不要跟着关
private final class BridgeView: PassThroughView {
    var controller: PanelController?
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let onWindow else { return }
        self.onWindow = nil
        onWindow(window)
    }
}

/// 发起面板的视图那边记着当前面板（isPresented 变回 false 时关它）
private final class PanelHolder {
    weak var controller: PanelController?
}

/// 从发起的地方带进面板的环境（系统 sheet 会自动继承；自己开的小窗要一样样带过去）
private struct PanelInherited {
    var model: AppModel?
    var openRoute: OpenRoute
    var openURL: OpenURLAction
    var chatPane: ChatPaneContext?
    var chatAgent: String
    var chatReadOnly: Bool
    var font: Font?
}

private struct SheetPanelModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    /// 哪一处弹的（文件:行）：同一处再弹时接管还留着的那个面板，不重复开
    let site: String
    let panel: () -> Panel
    @State private var holder = PanelHolder()
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.openRoute) private var openRoute
    @Environment(\.openURL) private var openURL
    @Environment(\.chatPane) private var chatPane
    @Environment(\.chatAgent) private var chatAgent
    @Environment(\.chatReadOnly) private var chatReadOnly
    @Environment(\.font) private var font
    @Environment(\.panelAnchor) private var anchor

    func body(content: Content) -> some View {
        content
            .background {
                if isPresented {
                    PanelBridge(holder: holder, site: site, root: AnyView(panel()), anchor: anchor,
                                inherited: PanelInherited(model: model, openRoute: openRoute, openURL: openURL, chatPane: chatPane, chatAgent: chatAgent,
                                                          chatReadOnly: chatReadOnly, font: font),
                                close: { isPresented = false }, onDismiss: onDismiss)
                        .frame(width: 0, height: 0)
                }
            }
            .onChange(of: isPresented) { _, shown in
                if !shown { holder.controller?.dismiss() }
            }
    }
}

private struct PanelBridge: NSViewRepresentable {
    let holder: PanelHolder
    let site: String
    let root: AnyView
    let anchor: PanelAnchor?
    let inherited: PanelInherited
    let close: () -> Void
    let onDismiss: (() -> Void)?

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        // 同一处弹过、发起的视图被系统重建后还留着的面板：接着用它（提到最前），不再开一个
        let key = anchor?.key
        let adopted = PanelController.live.first { $0.orphaned && $0.site == site && $0.anchorKey == key }
        let controller = adopted ?? PanelController()
        controller.site = site
        controller.pendingKey = key
        controller.orphaned = false
        controller.requestClose = close
        controller.onDismiss = onDismiss
        controller.update(root, inherited: inherited)
        view.controller = controller
        holder.controller = controller
        view.onWindow = { [weak controller, anchor] window in
            guard let controller else { return }
            if adopted != nil { controller.bringToFront() } else { controller.present(in: window, anchor: anchor) }
        }
        return view
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        guard let controller = view.controller else { return }
        controller.requestClose = close
        controller.onDismiss = onDismiss
        controller.update(root, inherited: inherited)
    }

    static func dismantleNSView(_ view: BridgeView, coordinator: ()) {
        // isPresented 变回 false 的：onChange 里已经关了。没关的是发起的那一行被列表回收了（比如滚出去了）：
        // 面板留着；它对着的那块会话也没了（关了标签、换了会话）才一起关
        // 发起的视图被系统整块重建（同一个会话还在）也算还在
        guard let controller = view.controller else { return }
        controller.orphaned = true
        DispatchQueue.main.async { controller.rescue() }
    }
}

/// 面板小窗：标题栏透明、平时不要红黄绿三个钮（「完成」/ Esc 关；当成正经窗口的才有）；能成为 key（能打字），不当主窗口
final class KitePanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Esc 关面板（当成正经窗口的不关）
    var escCloses = true
    /// 主窗口在屏幕外（测试实例截图）：面板跟着放在屏幕外，别被系统挪回屏幕里
    var unconstrained = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { if escCloses { onCancel?() } }
    override func performClose(_ sender: Any?) { onCancel?() }   // ⌘W

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        unconstrained ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    // 标题栏透明时，工具栏那一带的点击会落到底下的内容上：macOS 26 贴着顶边的列表、滚动视图会伸到工具栏底下，
    // 背景色也会铺上去，按下去是 SwiftUI 的视图，窗口拖不动（10-31 反馈代码 IDE 的标题栏拖不动）。
    // 有工具栏的面板：那一带按在内容上一律当成按在标题栏上——拖动窗口。工具栏按钮、红黄绿钮不在内容里，照常。
    // 当成正经窗口的：标题栏上按钮以外的地方双击缩放（面板上系统自己不缩放）
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, toolbar != nil, event.locationInWindow.y > contentLayoutRect.maxY,
           let content = contentView, let frame = content.superview, let hit = frame.hitTest(event.locationInWindow) {
            let onContent = hit === content || hit.isDescendant(of: content)
            if event.clickCount == 2, standardWindowButton(.zoomButton)?.isHidden == false, onContent || !Self.isControl(hit) {
                if !["None", "Minimize"].contains(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "") { zoom(nil) }
                return
            }
            if onContent {
                if event.clickCount == 1 { performDrag(with: event) }
                return
            }
        }
        super.sendEvent(event)
    }

    /// 标题栏上按到的是不是按钮（工具栏按钮、红黄绿钮）；标题文字不算
    private static func isControl(_ view: NSView) -> Bool {
        var node: NSView? = view
        while let current = node {
            if let field = current as? NSTextField, !field.isEditable {
                node = current.superview
                continue
            }
            if current is NSControl || String(describing: type(of: current)).contains("ToolbarItem") { return true }
            node = current.superview
        }
        return false
    }
}

/// 面板有没有工具栏（导航标题、返回）：没有的让内容顶到最上面（透明标题栏底下），有的给工具栏让出位置
private final class PanelState: ObservableObject {
    @Published var toolbar = false
}

/// 内容的理想大小（preferredContentSize）一变就告诉面板：内容后到的面板（会话信息、工具详情）跟着长高
private final class PanelHosting: NSHostingController<AnyView> {
    /// 内容的理想大小（SwiftUI 报来的 preferredContentSize）
    var ideal: NSSize { super.preferredContentSize }

    // 对外报 0：AppKit 看到窗口内容的理想大小变了会自己改窗口大小，用户拖过的大小一刷新就被改回去。
    // 跟不跟着变由面板自己定（见 PanelController.refit）
    override var preferredContentSize: NSSize {
        get { .zero }
        set { super.preferredContentSize = newValue }
    }
}

private struct PanelRoot: View {
    @ObservedObject var state: PanelState
    let content: AnyView
    let inherited: PanelInherited
    let close: PanelCloser

    var body: some View {
        styled
            .environment(\.closePanel, close)
            .environment(\.panelAnchor, nil)   // 面板里再弹的面板对着这个面板居中
            .ignoresSafeArea(.container, edges: state.toolbar ? [] : .top)
    }

    // 没指定样式的按钮不跟发起处（对话页是无边框的）：同系统 sheet，用系统默认的带边框按钮
    private var styled: some View {
        content
            .font(inherited.font ?? .app(size: 13))
            .environment(\.openRoute, inherited.openRoute)
            .environment(\.openURL, inherited.openURL)
            .environment(\.chatPane, inherited.chatPane)
            .environment(\.chatAgent, inherited.chatAgent)
            .environment(\.chatReadOnly, inherited.chatReadOnly)
            .environment(inherited.model ?? KitelineKit.model)   // 从 Mac App 自己的界面（新任务）弹的也能用
            .modifier(LookRoot())
    }
}

#if os(macOS)
/// 面板工具栏里的文字按钮：系统的带边框按钮（macOS 26 上是液态玻璃按钮），字两侧比系统默认多留 4 点，别贴着玻璃底的边
struct PanelTextButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label.padding(.horizontal, 4) }
            .buttonStyle(.bordered)
    }
}
#endif

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    /// 开着的面板（发起的视图没了也留着的，要有人拿着）
    static var live: [PanelController] = []
    /// 测试实例截图：面板全透明、鼠标穿透（截图照样画得出来），用户屏幕上看不见
    static var quiet = false
    /// 自测排查用：面板开关的经过写进日志（测试实例里接到 Log）
    static var log: (String) -> Void = { _ in }

    let panel: KitePanel
    private let hosting = PanelHosting(rootView: AnyView(EmptyView()))
    private let state = PanelState()
    var requestClose: () -> Void = {}
    var onDismiss: (() -> Void)?
    /// 哪一处弹的（见 SheetPanelModifier.site）、对着哪个会话
    var site = ""
    private(set) var anchorKey: String?
    /// 发起它的视图已经不在了（面板还开着，等同一处再弹时接管）
    var orphaned = false
    /// 还没弹出来时要对着的会话（发起的视图在弹出前就被重建了，凭它找新的那块）
    var pendingKey: String?
    private weak var anchorView: NSView?
    private var hadAnchor = false
    private var shown = false
    private var closed = false
    /// 用户自己拖过大小：之后内容再变也不自动改面板大小
    private var userSized = false
    private var lastIdeal: NSSize = .zero
    /// 拖边最小能缩到多大（窗口的 minSize 会被 SwiftUI 改回去，在 windowWillResize 里自己拦）
    private var minimum = NSSize(width: 240, height: 120)
    private lazy var closer: PanelCloser = {
        let closer = PanelCloser { [weak self] in self?.userClose(force: true) }
        closer.setWindowStyle = { [weak self] in self?.setWindowStyle($0) }
        return closer
    }()

    override init() {
        panel = KitePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        // 不让 SwiftUI 按内容的最小尺寸装约束（.minSize）：文字高度随宽度变的内容（确认卡片）会和窗口大小来回触发，AppKit 直接抛异常崩掉。
        // 最小尺寸打开时量一次，设成窗口的 contentMinSize
        hosting.sizingOptions = [.preferredContentSize]
        hosting.sceneBridgingOptions = [.toolbars, .title]   // 面板里的导航标题、返回按钮放进小窗的工具栏
        panel.contentViewController = hosting
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.toolbarStyle = .unified
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(kind)?.isHidden = true }
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.userClose() }
    }

    /// 发起的那块会话还在不在（不在了，被回收掉发起视图的面板也该关了）
    var anchorAlive: Bool {
        if closed { return false }
        if hadAnchor {
            if anchorView?.window != nil { return true }
            // 那块视图被系统重建了：窗口里还显示着同一个会话就认新的那块
            guard let key = anchorKey, let next = PanelAnchor.find(key: key, in: panel.parent) else { return false }
            anchorView = next.view
            return true
        }
        return panel.parent?.isVisible == true
    }

    fileprivate func update(_ content: AnyView, inherited: PanelInherited) {
        guard !closed else { return }
        hosting.rootView = AnyView(PanelRoot(state: state, content: content, inherited: inherited, close: closer))
    }

    func present(in window: NSWindow, anchor: PanelAnchor?) {
        guard !shown, !closed else { return }
        shown = true
        Self.live.append(self)
        let target = anchor?.view.flatMap { $0.window === window ? $0 : nil }
        anchorView = target
        anchorKey = target == nil ? nil : anchor?.key
        hadAnchor = target != nil
        // 对着这块会话（没有就对着整个窗口）的中心
        let area = (target ?? window.contentView).map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? window.frame
        let center = CGPoint(x: area.midX, y: area.midY)
        // 主窗口大半在屏幕外（测试实例截图）：面板也照样放，别被系统挪进屏幕
        let onScreen = NSScreen.screens.reduce(CGFloat(0)) { sum, screen in
            let part = screen.frame.intersection(window.frame)
            return sum + (part.isNull ? 0 : part.width * part.height)
        }
        panel.unconstrained = onScreen < window.frame.width * window.frame.height / 2
        panel.alphaValue = 0
        if Self.quiet { panel.ignoresMouseEvents = true }
        hosting.view.layoutSubtreeIfNeeded()
        place(size: targetSize(), center: center)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        // 下一轮：工具栏（导航标题、返回）这时才挂上，量好最终大小再渐显
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.state.toolbar = self.panel.toolbar != nil
            self.hosting.view.layoutSubtreeIfNeeded()
            let size = self.targetSize()
            self.place(size: size, center: center)
            // 最小尺寸：内容能缩到的大小（加上工具栏），不比打开时大
            let least = self.hosting.sizeThatFits(in: .zero)
            self.minimum = NSSize(width: min(max(least.width, 240), size.width), height: min(max(least.height, 120), size.height))
            if Self.quiet { return }
            self.panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.panel.animator().alphaValue = 1 }
        }
    }

    /// 发起它的视图没了之后：已经弹出来的，对着的会话还在就留着、不在了就关；
    /// 还没来得及弹出来（发起的视图刚弹就被系统重建）的，对着同一个会话的新区域弹出来
    func rescue() {
        guard !closed else { return }
        if shown {
            if !anchorAlive { dismiss() }
        } else if let key = pendingKey, let anchor = PanelAnchor.find(key: key), let window = anchor.view?.window {
            present(in: window, anchor: anchor)
        } else {
            dismiss()
        }
    }

    /// 同一处又要弹：面板已经开着，提到最前
    func bringToFront() {
        guard shown, !closed, !Self.quiet else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// 「完成」、Esc、⌘W、红色按钮：把发起那边的 isPresented 设回去，自己也关（发起的视图已经没了时只能靠这里关）。
    /// 内容挂了 panelCloseGuard 的先问它；force = 内容自己调的关（PanelDismiss，用户已经确认过）
    private func userClose(force: Bool = false) {
        if !force, closer.shouldClose?() == false { return }
        requestClose()
        dismiss()
    }

    /// 当成正经窗口（panelWindowStyle）：露出红黄绿钮，Esc 不关
    private func setWindowStyle(_ on: Bool) {
        guard !closed else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(kind)?.isHidden = !on }
        panel.escCloses = !on
    }

    func dismiss() {
        guard !closed else { return }
        closed = true
        // 面板里又弹的面板一起关
        for child in Self.live where child !== self && child.panel.parent === panel { child.dismiss() }
        Self.live.removeAll { $0 === self }
        let parent = panel.parent
        if panel.isKeyWindow, let parent, parent.isVisible { parent.makeKey() }
        let panel = panel
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
        onDismiss?()
    }

    /// 打开时的大小：内容的理想大小（SwiftUI 量的已经含工具栏），不超出屏幕
    private func targetSize() -> NSSize {
        var ideal = hosting.ideal
        if ideal.width < 1 || ideal.height < 1 { ideal = hosting.view.fittingSize }
        let visible = (panel.parent?.screen ?? panel.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(max(ideal.width, 320), visible.width - 40),
                      height: min(max(ideal.height, 140), visible.height - 40))
    }

    private func place(size: NSSize, center: CGPoint) {
        var frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        if !panel.unconstrained, let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? panel.parent?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        }
        panel.setFrame(frame.integral, display: true)
    }

    /// 内容变了（数据到了、展开了）：用户没手动改过大小就跟着内容变，中心不动
    private func refit() {
        guard shown, !closed, !userSized else { return }
        let size = targetSize()
        guard abs(size.width - panel.frame.width) > 0.5 || abs(size.height - panel.frame.height) > 0.5 else { return }
        place(size: size, center: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
    }

    // MARK: NSWindowDelegate

    func windowWillStartLiveResize(_ notification: Notification) { userSized = true }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        userSized = true
        return true
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        userClose()
        return false
    }

    func windowDidUpdate(_ notification: Notification) {
        let has = panel.toolbar != nil
        // 有没有工具栏、内容的理想大小变了（数据到了、展开了）：用户没拖过大小就跟着变
        if has != state.toolbar || hosting.ideal != lastIdeal {
            state.toolbar = has
            lastIdeal = hosting.ideal
            DispatchQueue.main.async { [weak self] in self?.refit() }
        }
    }
}

// MARK: - 确认卡片

/// Mac 的确认框：一段说明 + 取消 / 确认（回车确认、Esc 取消），同 NSAlert 的排法
private struct ConfirmCard: View {
    let message: String
    let confirm: String
    let destructive: Bool
    let cancel: String
    let action: () -> Void
    @PanelDismiss private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(message)
                .font(.ui(.body))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button(confirm, role: destructive ? .destructive : nil) {
                    action()   // 先做（有的要读发起处的状态，关掉面板就清了）
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(destructive ? Theme.removed : Theme.claude)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 18)
        .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.pageBackground)
        .panelDragBackground()
    }
}

// MARK: - 自测

#if KITELINE_MAC
extension KitelineKit {
    /// 自测用：开着的面板小窗（截图、核对位置大小）
    public static var openPanels: [NSWindow] { PanelController.live.map(\.panel).filter(\.isVisible) }

    /// 自测用：面板一律看不见（测试实例按脚本截图时，主窗口一角会被系统挪进屏幕）
    public static func quietPanels(log: @escaping (String) -> Void) {
        PanelController.quiet = true
        PanelController.log = log
    }

    /// 自测用：关掉最上面那个面板（同按 Esc）
    public static func closeTopPanel() {
        PanelController.live.last?.panel.cancelOperation(nil)
    }
}
#endif
#endif
