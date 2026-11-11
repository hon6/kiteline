import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: 模型

/// 分屏（同 VS Code 的编辑器分组）：一块一块放会话，可以左右分、上下分，一层层嵌套。
/// 每块顶上一条：会话标题、「左右分屏」「上下分屏」两个按钮（把这一块往右 / 往下一分为二，新的一半先列出没打开的会话让你选）、×（只剩一块时没有）。
/// 默认平分；分隔条拖着调大小，双击恢复平分。从左边列表把会话拖进来：落在哪一块的哪一边就从哪边分出来，落在中间就换掉这一块。
/// Mac 不限块数、想分就分：这一块对半分太窄时同一排一起平分、再从旁边富余的块里匀出地方；整个窗口都匀不出来也照分，挤小了自己拖分隔条调。
/// iPad 最多两块（左右或上下）；iPhone 不分屏。
/// 点过、在打字的那块是「当前块」：左边栏点会话换掉的是它，标题栏的按钮、菜单也对它。
/// Mac 上每块是一组标签页（同浏览器，10-23 起）：左边栏点开的会话在当前块里新开一个标签，切走了标签还在，点标签切回来，× 关掉；
/// 关掉最后一个标签，这一块也关掉（只剩一块时变回空白）。iPad 每块仍只放一个会话
@Observable
public final class ChatPanes {
    /// 一块：开着的几个会话（标签页，按顺序）和正显示的那个（key 是空的 = 还没选，显示「选择会话」）
    struct Pane: Hashable {
        let id: UUID
        var key: String?
        var tabs: [String] = []
        /// 点「+」开新标签之前正显示的：新标签不要了（×）就回到它
        var previous: String?

        init(id: UUID, key: String?) {
            self.id = id
            self.key = key
            tabs = key.map { [$0] } ?? []
        }
    }

    /// 一层分割：几块（或几组）左右排（horizontal）或上下排（vertical），各占多少比例（加起来是 1）
    struct Split {
        let id: UUID
        var axis: Axis
        var items: [Node]
        var fractions: [CGFloat]
    }

    indirect enum Node {
        case pane(Pane)
        case split(Split)

        var id: UUID {
            switch self {
            case .pane(let pane): pane.id
            case .split(let split): split.id
            }
        }
    }

    private(set) var root: Node { didSet { scheduleSave() } }
    private(set) var focusID: UUID { didSet { scheduleSave() } }
    /// 记在哪（见 remember）：空 = 不记（截图版、测试实例）
    @ObservationIgnored private var store: (defaults: UserDefaults, key: String)?
    @ObservationIgnored private var saving: DispatchWorkItem?
    /// 每块现在多大（画出来时量的）：判断还分不分得下、拖进来能落在哪边。改了不用重画
    @ObservationIgnored var sizes: [UUID: CGSize] = [:]
    /// 整个分屏多大（画出来时量的）：分完以后各块按它重新匀大小。还没量过是 zero
    @ObservationIgnored var bounds: CGSize = .zero
    /// 自测截图用：假装正拖着某个会话停在当前块的某一边
    var preview: (pane: UUID, zone: DropZone, key: String)?

    /// 正拖着的标签（Mac）：哪个会话、从哪块、标签多大（跟手画一张一样大的）
    struct TabDragging: Equatable {
        let key: String
        let source: UUID
        let size: CGSize
    }

    /// 拖标签落到哪：插到某块第几个标签的位置，或者某块对话区的中间 / 四边
    enum TabTarget: Equatable {
        case tab(UUID, Int)
        case zone(UUID, DropZone)
    }

    /// 自测截图：分隔线都画成指针停在上面
    var captureHandles = false
    /// 分屏的坐标系：拖标签的位置、各块和标签的位置都按它算
    static let space = "chatPanes"
    var tabDrag: TabDragging?
    /// 落点：变了才改，块和标签栏只跟着它重画
    var tabTarget: TabTarget?
    /// 指针在分屏里的位置：只有跟手的那张标签读它，拖动时别的不跟着重画
    var tabPoint: CGPoint = .zero
    /// 各块的对话区、标签栏、每个标签在分屏里的位置（画出来时量的）：算落点用。改了不用重画
    @ObservationIgnored var contentFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var stripFrames: [UUID: CGRect] = [:]
    /// 各块标题条以下的部分、输入栏的上沿：信绳只钉在这两者之间的消息区里（不爬到标题条、输入栏上）
    @ObservationIgnored var bodyFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var composerTops: [UUID: CGFloat] = [:]

    /// 一块的消息区（标题条以下、输入栏以上）
    func messageFrame(_ id: UUID) -> CGRect? {
        guard var frame = bodyFrames[id] ?? contentFrames[id] else { return nil }
        if let top = composerTops[id], top > frame.minY + 40, top < frame.maxY { frame.size.height = top - frame.minY }
        return frame
    }
    @ObservationIgnored var tabFrames: [UUID: [String: CGRect]] = [:]
    /// 分屏左上角在窗口里的位置（自测按标签的位置算鼠标坐标用）
    @ObservationIgnored var origin: CGPoint = .zero
    /// 拖着时按了 Esc：松手前都不再跟
    @ObservationIgnored private var tabDragCancelled = false
    #if os(macOS)
    @ObservationIgnored private var escMonitor: Any?

    /// 指着展开的标签（Mac，11-04 起）：鼠标停在一个标题被截短的标签上，它按完整标题变宽——不超出这一块，
    /// 这块的会话、分屏按钮先收进「更多」，别的标签缩窄；离开这块的标签栏收回。key 是空串 = 「选择会话」新标签
    struct Peek: Hashable {
        let pane: UUID
        let key: String
    }
    var peek: Peek?
    /// 各块平时（没展开时）哪些标签的标题被截短了、每个标签多宽：排版时记，展开时照着算。改了不用重画
    @ObservationIgnored var truncated: [UUID: Set<String>] = [:]
    @ObservationIgnored var tabWidths: [UUID: [CGFloat]] = [:]
    /// 指针在哪几块的标签栏上、指着哪几个标签（挪到相邻的时「进」「出」谁先到都行，最后进的算数）
    @ObservationIgnored private var hoveredStrips: Set<UUID> = []
    @ObservationIgnored private var hoveredTabs: [Peek] = []
    @ObservationIgnored private var peekWork: DispatchWorkItem?
    #endif

    public init() {
        let pane = Pane(id: UUID(), key: nil)
        root = .pane(pane)
        focusID = pane.id
    }

    // MARK: 尺寸限制

    #if os(macOS)
    /// 每块是一组标签页（iPad 每块只放一个会话）
    static let tabbed = true
    /// Mac 不限块数。分的时候尽量让每块不窄于 320：对话内容自己至少要 300 出头（头像、留边、发来的图……）；窗口里匀不出来也照分
    static let maxPanes = Int.max
    static let minSize = CGSize(width: 320, height: 220)
    /// 拖分隔条最多拖到这么小（标题条上的按钮还点得到）。本来就比这还小的块不会被拖得更小，但能拖大
    static let dragMin = CGSize(width: 160, height: 120)
    #else
    static let tabbed = false
    /// 横着的 iPhone（点了旋转按钮）：只左右分、最多三列（上下分每块只剩一百多点高，10-27）。Rotation 转屏时改它
    nonisolated(unsafe) static var sideBySideOnly = false
    /// iPad 最多两块；横着的 iPhone 最多三列
    static var maxPanes: Int { sideBySideOnly ? 3 : 2 }
    /// 横着的 iPhone 三列每列二百出头，按 220 算
    static var minSize: CGSize { sideBySideOnly ? CGSize(width: 220, height: 200) : CGSize(width: 280, height: 240) }
    static var dragMin: CGSize { minSize }
    #endif

    // MARK: 查

    var panes: [Pane] { Self.leaves(root) }
    public var count: Int { panes.count }
    /// 开着的会话（从左上到右下，切到后面的标签也算）
    public var keys: [String] { panes.flatMap(\.tabs) }
    /// 当前块的会话（当前块还没选会话时是空的）
    public var focused: String? { panes.first { $0.id == focusID }?.key }
    /// 什么都还没开：只有一块，而且是空的
    public var isPristine: Bool { count == 1 && panes.first?.key == nil && panes.first?.tabs.isEmpty == true }

    func pane(_ id: UUID) -> Pane? { panes.first { $0.id == id } }

    /// 开着这个会话的那一块
    func pane(holding key: String) -> Pane? { panes.first { $0.tabs.contains(key) } }

    private static func leaves(_ node: Node) -> [Pane] {
        switch node {
        case .pane(let pane): [pane]
        case .split(let split): split.items.flatMap(leaves)
        }
    }

    // MARK: 改

    /// 左边栏点了某个会话：已经开着就切到那块的那个标签，没开着就在当前块新开一个标签（iPad：换掉当前块的）
    public func show(_ key: String) {
        guard !key.isEmpty else { return }   // 空的不是会话（别开出一个空标签）
        if let open = pane(holding: key) {
            activate(open.id, key)
        } else {
            setKey(focusID, key)
        }
    }

    public func focus(_ id: UUID) {
        if focusID != id, pane(id) != nil { focusID = id }
    }

    /// 某一块放哪个会话（空块里选了一个、拖到中间）：Mac 新开一个标签（排在正显示的那个后面，同浏览器），已经开着就切过去；iPad 换掉。
    /// key 是空的 = 显示「选择会话」
    func setKey(_ id: UUID, _ key: String?) {
        root = Self.mapPane(root, id) { pane in
            guard let key else { pane.key = nil; return }
            if !pane.tabs.contains(key) {
                if Self.tabbed {
                    let at = pane.key.flatMap { pane.tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? pane.tabs.count
                    pane.tabs.insert(key, at: at)
                } else {
                    pane.tabs = [key]
                }
            }
            pane.key = key
            pane.previous = nil
        }
        focusID = id
    }

    /// 点了某个标签
    func activate(_ id: UUID, _ key: String) {
        root = Self.mapPane(root, id) { pane in
            if pane.tabs.contains(key) { pane.key = key; pane.previous = nil }
        }
        focusID = id
    }

    /// 「+」：在这一块开个新标签，先列出没打开的会话让你选
    func newTab(_ id: UUID) {
        root = Self.mapPane(root, id) { pane in
            if pane.key != nil { pane.previous = pane.key }
            pane.key = nil
        }
        focusID = id
    }

    /// 关掉一个标签：正显示的就切到右边那个（没有就左边，同浏览器）；关掉的是最后一个，这一块也关掉（只剩一块时变回空白）。
    /// key 是空的 = 关掉「选择会话」那个新标签，回到开它之前的那个
    func closeTab(_ id: UUID, _ key: String?) {
        guard let pane = pane(id) else { return }
        guard let key else {
            let back = pane.previous.flatMap { pane.tabs.contains($0) ? $0 : nil } ?? pane.tabs.last
            if back == nil, count > 1 { close(id); return }
            root = Self.mapPane(root, id) { $0.key = back; $0.previous = nil }
            return
        }
        guard let index = pane.tabs.firstIndex(of: key) else { return }
        var tabs = pane.tabs
        tabs.remove(at: index)
        if tabs.isEmpty, pane.key == key, count > 1 {
            close(id)
            return
        }
        let shown = pane.key == key ? (tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]) : pane.key
        root = Self.mapPane(root, id) { $0.tabs = tabs; $0.key = shown; if $0.previous == key { $0.previous = nil } }
    }

    /// 把会话放到某一块的第 index 个标签的位置（拖标签排顺序、从别的块或左边栏拖到某个标签上）：从原来那块拿走（那块空了就关掉），切过去
    func place(_ key: String, from source: UUID?, in id: UUID, at index: Int) {
        let existing = source.flatMap { pane($0)?.tabs.contains(key) == true ? $0 : nil } ?? pane(holding: key)?.id
        var at = index
        if existing == id, let from = pane(id)?.tabs.firstIndex(of: key) {
            if from < at { at -= 1 }   // 往右挪：先拿走自己，后面的往前挤了一格
        } else if let existing {
            closeTab(existing, key)
        }
        guard pane(id) != nil else { setKey(focusID, key); return }
        root = Self.mapPane(root, id) { pane in
            pane.tabs.removeAll { $0 == key }
            pane.tabs.insert(key, at: max(0, min(at, pane.tabs.count)))
            pane.key = key
            pane.previous = nil
        }
        focusID = id
    }

    /// 关掉这一块里除了 key 以外的标签 / key 右边的标签
    func closeOtherTabs(_ id: UUID, keeping key: String, rightOnly: Bool = false) {
        root = Self.mapPane(root, id) { pane in
            guard let index = pane.tabs.firstIndex(of: key) else { return }
            pane.tabs = rightOnly ? Array(pane.tabs[...index]) : [key]
            if let shown = pane.key, !pane.tabs.contains(shown) { pane.key = key }
            pane.previous = nil
        }
        focusID = id
    }

    /// 把一块一分为二，新的一半在 edge 那边、放 key（空 = 先选会话），新的一半成为当前块。块数到顶了返回 nil
    @discardableResult
    func split(_ id: UUID, edge: Edge, key: String?) -> UUID? {
        let new = Pane(id: UUID(), key: key)
        guard let next = splitTree(id, axis: Self.axis(edge), new: new, after: edge == .trailing || edge == .bottom) else { return nil }
        root = next
        focusID = new.id
        return new.id
    }

    /// 当前块一分为二：down = 上下分、false = 左右分、没指定 = 左右分。块数到顶了返回 false
    @discardableResult
    public func splitFocused(key: String? = nil, down: Bool? = nil) -> Bool {
        guard let edge = splitEdge(focusID, down: down) else { return false }
        return split(focusID, edge: edge, key: key) != nil
    }

    /// 这一块往哪边分（没指定是左右）；分不了返回 nil
    func splitEdge(_ id: UUID, down: Bool? = nil) -> Edge? {
        canSplit(id, down == true ? .vertical : .horizontal) ? (down == true ? .bottom : .trailing) : nil
    }

    /// 这一块还能不能再分：只看块数（iPad 最多两块），放不放得下不管，挤小了自己拖；横着的 iPhone 不上下分
    func canSplit(_ id: UUID, _ axis: Axis) -> Bool {
        #if os(iOS)
        if axis == .vertical && Self.sideBySideOnly { return false }
        #endif
        return count < Self.maxPanes && pane(id) != nil
    }

    /// 把 id 那块沿 axis 一分为二后的样子（块数到顶了返回 nil）。
    /// 这一块对半分还够大：就对半分（别的块不动，留着你拖过的比例）；不够：同一排一起平分。
    /// 分完还有哪块比最小尺寸小的，从同一层富余的块里匀过来（同 VS Code：新的一组挤不下就压旁边的）；匀不出来就这样，自己拖
    private func splitTree(_ id: UUID, axis: Axis, new: Pane, after: Bool) -> Node? {
        guard canSplit(id, axis) else { return nil }
        let next = Self.splitting(root, id, axis: axis, new: new, after: after, halve: halves(id, axis))
        return bounds.width > 0 && bounds.height > 0 ? Self.fitted(next, bounds, around: new.id) : next
    }

    /// 这一块沿 axis 对半分后，每半还够不够最小尺寸（还没量过大小时当作够）
    private func halves(_ id: UUID, _ axis: Axis) -> Bool {
        guard let size = sizes[id] else { return true }
        return axis == .horizontal ? size.width >= Self.minSize.width * 2 + PaneDivider.thickness : size.height >= Self.minSize.height * 2 + PaneDivider.thickness
    }

    private static func axis(_ edge: Edge) -> Axis { edge == .leading || edge == .trailing ? .horizontal : .vertical }

    /// 关掉一块（只剩一块时不能关）：空出来的地方按比例分给同一层剩下的；关的是当前块，就把当前块交给它后面（没有就前面）那块
    public func close(_ id: UUID) {
        guard count > 1, pane(id) != nil else { return }
        let order = panes.map(\.id)
        if let next = Self.removing(root, id) { root = Self.normalized(next) }
        sizes[id] = nil
        if focusID == id, let index = order.firstIndex(of: id) {
            let rest = order.filter { $0 != id }
            focusID = rest[min(index, rest.count - 1)]
        }
    }

    /// 关掉开着这个会话的标签（iPad：那一块）
    public func close(key: String) {
        guard let pane = pane(holding: key) else { return }
        if Self.tabbed { closeTab(pane.id, key) } else { close(pane.id) }
    }

    /// 把会话拖到某一块上：中间 = 在这块开个标签（iPad：换掉这块）；四边 = 从那边分出来。
    /// 拖的会话已经开在别的块里（或者拖的就是别的块的标签）：挪过来，原来那块里的标签关掉（那块空了就关掉）。
    /// 把一块里的标签拖到这块自己的边上：这个标签单独分出来（这块还有别的标签时）
    func drop(_ key: String, from source: UUID?, on target: UUID, zone: DropZone) {
        let existing = source.flatMap { pane($0)?.tabs.contains(key) == true ? $0 : nil } ?? pane(holding: key)?.id
        if existing == target {
            if let edge = zone.edge, let pane = pane(target), pane.tabs.count > 1 {
                closeTab(target, key)
                if split(target, edge: edge, key: key) == nil { setKey(target, key) }
            } else {
                activate(target, key)
            }
            return
        }
        // iPad 每块只放一个会话：一块的会话拖到另一块中间 = 两块换位置（不然那块原来的会话就看不到了）
        if !Self.tabbed, zone == .center, let existing, let other = pane(target)?.key {
            root = Self.mapPane(Self.mapPane(root, existing) { $0.key = other; $0.tabs = [other] }, target) { $0.key = key; $0.tabs = [key] }
            focusID = target
            return
        }
        // 先从原来那块拿走（iPad 上才腾得出第二块）
        if let existing { Self.tabbed ? closeTab(existing, key) : close(existing) }
        if zone == .center || pane(target) == nil {
            setKey(pane(target) == nil ? focusID : target, key)
        } else if let edge = zone.edge {
            if split(target, edge: edge, key: key) == nil { setKey(target, key) }   // 万一块数到顶了：放进这一块，别把会话弄丢
        }
    }

    /// 拖到某一块的 point（块里的坐标）上会落在哪：靠近哪条边就从哪边分（块数到顶了就放进这块）。
    /// 拖回自己那块：只有这块还有别的标签时，拖到边上才算（把这个标签分出来）
    func zone(at point: CGPoint, in id: UUID, size measured: CGSize? = nil, source: UUID?, key: String?) -> DropZone? {
        let existing = source.flatMap { pane($0) != nil ? $0 : nil } ?? key.flatMap { pane(holding: $0)?.id }
        let own = existing == id
        if own, (pane(id)?.tabs.count ?? 0) <= 1 { return nil }
        guard let size = measured ?? sizes[id], size.width > 0, size.height > 0 else { return own ? nil : .center }
        let x = point.x / size.width, y = point.y / size.height
        var edges: [(DropZone, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
        #if os(iOS)
        if Self.sideBySideOnly { edges.removeLast(2) }   // 横着的 iPhone 只左右分
        #endif
        guard let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 < 0.28 else { return own ? nil : .center }
        // 拖的是别的块里唯一的会话：那块会先关掉，块数不会多
        let freed = existing != nil && !own && (existing.flatMap { pane($0) }?.tabs.count ?? 0) <= 1
        return count - (freed ? 1 : 0) < Self.maxPanes ? nearest.0 : (own ? nil : .center)
    }

    // MARK: 拖标签（Mac，同 VS Code）

    /// 拖着标签到了 point（分屏坐标）：第一次时记下拖的是谁；算落点，变了才改
    func dragTab(_ key: String, from source: UUID, at point: CGPoint) {
        guard !tabDragCancelled else { return }
        if tabDrag?.key != key {
            tabDrag = TabDragging(key: key, source: source, size: tabFrame(source, key)?.size ?? CGSize(width: 160, height: 31))
            #if os(macOS)
            // 展开着的标签先收回：落点、插入竖线按平时的位置算
            peekWork?.cancel()
            if peek != nil { peek = nil }
            if escMonitor == nil {
                escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53, let self, self.tabDrag != nil else { return event }
                    withAnimation(.snappy(duration: 0.15)) { self.cancelTabDrag() }
                    return nil
                }
            }
            #endif
        }
        tabPoint = point
        let target = tabDrag.flatMap { tabTarget(at: point, $0) }
        if target != tabTarget { tabTarget = target }
    }

    /// 拖着标签停在这块对话区的哪儿（没停在这块是 nil）
    func tabZone(_ id: UUID) -> DropZone? {
        if case .zone(id, let zone)? = tabTarget { return zone }
        return nil
    }

    /// 拖着标签停在标签栏上：插入竖线在分屏里的位置（插到第 index 个前面 = 它的左边，插到最后 = 最后一个的右边）
    var tabInsertLine: CGRect? {
        guard case .tab(let id, let index)? = tabTarget, let pane = pane(id), let frames = tabFrames[id] else { return nil }
        let foot: CGFloat = 7
        if index < pane.tabs.count, let frame = frames[pane.tabs[index]] {
            return CGRect(x: frame.minX + foot - 1.25, y: frame.minY + 6, width: 2.5, height: frame.height - 12)
        }
        guard let last = pane.tabs.last, let frame = frames[last] else { return nil }
        return CGRect(x: frame.maxX - foot - 1.25, y: frame.minY + 6, width: 2.5, height: frame.height - 12)
    }

    /// 松手：落到标签栏上 = 插到那里，落到对话区 = 挪进那块 / 从那边分出来；别处 = 不动
    func endTabDrag() {
        let drag = tabDragCancelled ? nil : tabDrag, target = tabTarget
        tabDragCancelled = false
        stopEscMonitor()
        tabDrag = nil
        tabTarget = nil
        guard let drag else { return }
        switch target {
        case .tab(let id, let index): place(drag.key, from: drag.source, in: id, at: index)
        case .zone(let id, let zone): drop(drag.key, from: drag.source, on: id, zone: zone)
        case nil: break
        }
    }

    /// 拖着时按 Esc：标签回原处，松手前不再跟
    func cancelTabDrag() {
        tabDragCancelled = true
        stopEscMonitor()
        tabDrag = nil
        tabTarget = nil
    }

    private func stopEscMonitor() {
        #if os(macOS)
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        #endif
    }

    #if os(macOS)
    // MARK: 指着展开的标签（Mac）

    /// 指针进出某块的标签栏（整条，含空白和按钮）
    func hoverStrip(_ pane: UUID, _ on: Bool) {
        if on { hoveredStrips.insert(pane) } else { hoveredStrips.remove(pane) }
        updatePeek()
    }

    /// 指针进出某个标签
    func hoverTab(_ tab: Peek, _ on: Bool) {
        hoveredTabs.removeAll { $0 == tab }
        if on { hoveredTabs.append(tab) }
        updatePeek()
    }

    /// 该展开哪个：指着的标签平时被截短了就是它（没截短的不用展开，展开着别的也收回）；
    /// 指着这块标签栏的空白、「+」、「更多」时保持（展开时它们挪了位置，收回去会在指针底下跳）；离开标签栏收回
    private var peekTarget: Peek? {
        if let tab = hoveredTabs.last { return truncated[tab.pane]?.contains(tab.key) == true && alive(tab) ? tab : nil }
        if let peek, hoveredStrips.contains(peek.pane), alive(peek) { return peek }
        return nil
    }

    /// 这个标签还在（关掉了、挪走了就不算）
    private func alive(_ tab: Peek) -> Bool {
        guard let pane = pane(tab.pane) else { return false }
        return tab.key.isEmpty ? pane.key == nil : pane.tabs.contains(tab.key)
    }

    /// 展开、收回的动画（11-04 改为流畅地展开）：标签宽度、按钮收起一起走，不回弹
    static let peekAnimation = Animation.smooth(duration: 0.24)

    /// 停 0.3 秒才展开（划过去不闪）；已经展开时换到别的标签、收回都是 0.15 秒
    private func updatePeek() {
        peekWork?.cancel()
        guard peekTarget != peek else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.tabDrag == nil, !PaneDrag.state.active else { return }
            let next = self.peekTarget
            if next != self.peek { withAnimation(Self.peekAnimation) { self.peek = next } }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (peek == nil ? 0.3 : 0.15), execute: work)
    }

    /// 自测截图用：当前块第 index 个标签画成展开的样子（不等悬停、不管截没截短）；nil = 收起
    func debugPeek(_ index: Int?) {
        let next = index.flatMap { index in pane(focusID).flatMap { $0.tabs.indices.contains(index) ? Peek(pane: focusID, key: $0.tabs[index]) : nil } }
        withAnimation(Self.peekAnimation) { peek = next }
    }

    /// 自测用：当成指针挪到当前块第 index 个标签上（走悬停的计时和截短判断，同真鼠标）；nil = 移出标签栏
    func debugHover(_ index: Int?) {
        let id = focusID
        hoveredTabs.removeAll { $0.pane == id }
        if let index, let tabs = pane(id)?.tabs, tabs.indices.contains(index) {
            hoveredStrips.insert(id)
            hoveredTabs.append(Peek(pane: id, key: tabs[index]))
        } else {
            hoveredStrips.remove(id)
        }
        updatePeek()
    }
    #endif

    /// 某块里某个会话的标签（iPad：标题条）在哪。iPad 两块换了会话、标题条位置没变时没重新记，用这块记下的那个
    private func tabFrame(_ pane: UUID, _ key: String) -> CGRect? {
        tabFrames[pane]?[key] ?? (Self.tabbed ? nil : tabFrames[pane]?.values.first)
    }

    /// 自测用：照手势一样拖第 from 块正显示的会话（按住它的标签 / 标题条），拖到第 to 块对话区的 zone 那边，停 hold 秒再松手
    @MainActor
    func debugDrag(from: Int, to: Int, zone: DropZone, hold: Double) async {
        let list = panes
        guard list.indices.contains(from), list.indices.contains(to), let key = list[from].key,
              let grab = tabFrame(list[from].id, key), let area = contentFrames[list[to].id] else { return }
        let point: CGPoint = switch zone {
        case .center: CGPoint(x: area.midX, y: area.midY)
        case .leading: CGPoint(x: area.minX + area.width * 0.1, y: area.midY)
        case .trailing: CGPoint(x: area.maxX - area.width * 0.1, y: area.midY)
        case .top: CGPoint(x: area.midX, y: area.minY + area.height * 0.1)
        case .bottom: CGPoint(x: area.midX, y: area.maxY - area.height * 0.1)
        }
        let start = CGPoint(x: grab.midX, y: grab.midY)
        for step in 1...12 {
            let t = CGFloat(step) / 12
            dragTab(key, from: list[from].id, at: CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t))
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .seconds(hold))
        endTabDrag()
    }

    /// point 落在哪：某块的标签栏上 = 插到指针左边那些标签后面（拖回原处不算）；某块的对话区里 = 中间或四边（同从左边栏拖进来）
    private func tabTarget(at point: CGPoint, _ drag: TabDragging) -> TabTarget? {
        let live = panes
        if let pane = live.first(where: { stripFrames[$0.id]?.contains(point) == true }) {
            let frames = tabFrames[pane.id] ?? [:]
            let index = pane.tabs.filter { frames[$0].map { $0.midX < point.x } ?? false }.count
            if pane.id == drag.source, let from = pane.tabs.firstIndex(of: drag.key), index == from || index == from + 1 { return nil }
            return .tab(pane.id, index)
        }
        guard let pane = live.first(where: { contentFrames[$0.id]?.contains(point) == true }), let frame = contentFrames[pane.id] else { return nil }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        return zone(at: local, in: pane.id, size: frame.size, source: drag.source, key: drag.key).map { .zone(pane.id, $0) }
    }

    /// 拖第 index 条分隔条（split 里第 index 和第 index+1 项之间）：从按下时的比例 start 挪 delta（占这一层总长的比例）。
    /// 两边都不小于各自的拖动下限（dragMin）；按下时就比下限还小的那边只是不再变小，一按下去不会跳
    func drag(_ splitID: UUID, _ index: Int, from start: [CGFloat], by delta: CGFloat, length: CGFloat) {
        guard length > 0 else { return }
        root = Self.mapSplit(root, splitID) { split in
            guard start.count == split.items.count, index + 1 < start.count else { return }
            let pair = start[index] + start[index + 1]
            let low = min(Self.minLength(split.items[index], split.axis, Self.dragMin) / length, start[index])
            let high = max(low, pair - min(Self.minLength(split.items[index + 1], split.axis, Self.dragMin) / length, start[index + 1]))
            let left = min(max(start[index] + delta, low), high)
            split.fractions = start
            split.fractions[index] = left
            split.fractions[index + 1] = pair - left
        }
    }

    func equalize(_ splitID: UUID) {
        root = Self.mapSplit(root, splitID) { $0.fractions = Array(repeating: 1 / CGFloat($0.items.count), count: $0.items.count) }
    }

    func fractions(_ splitID: UUID) -> [CGFloat] {
        func find(_ node: Node) -> [CGFloat]? {
            guard case .split(let split) = node else { return nil }
            return split.id == splitID ? split.fractions : split.items.lazy.compactMap(find).first
        }
        return find(root) ?? []
    }

    /// 排查用：「左右[*首页 50% | 上下[订单 50% / 空 50%] 50%]」（* 是当前块）
    public var summary: String {
        func describe(_ node: Node) -> String {
            switch node {
            case .pane(let pane):
                // 标签之间用逗号，正显示的前面加 ^
                let tabs = pane.tabs.map { ($0 == pane.key ? "^" : "") + String($0.suffix(6)) } + (pane.key == nil && !pane.tabs.isEmpty ? [L("^新标签")] : [])
                return (pane.id == focusID ? "*" : "") + (tabs.isEmpty ? L("空") : tabs.joined(separator: ","))
            case .split(let split):
                let parts = split.items.indices.map { describe(split.items[$0]) + " \(Int((split.fractions[$0] * 100).rounded()))%" }
                return (split.axis == .horizontal ? "左右[" : "上下[") + parts.joined(separator: split.axis == .horizontal ? " | " : " / ") + "]"
            }
        }
        return describe(root)
    }

    // MARK: 记住分屏

    /// 存下来的样子：一块 = 开着的标签和正显示的那个；一层分割 = 方向、里面几项、各占多少
    private struct Stored: Codable {
        var id: UUID
        var key: String?
        var tabs: [String]?
        var vertical: Bool?
        var items: [Stored]?
        var fractions: [CGFloat]?
    }

    private struct Saved: Codable {
        var root: Stored
        var focus: UUID
    }

    /// 记住怎么分的屏、每块开着哪些会话（存在 defaults 的 key 下）：关掉 App 再打开、重装之后还是原来那样（10-23）。
    /// 先读回上次存的，以后一有改动就存
    public func remember(in defaults: UserDefaults, key: String) {
        guard store == nil else { return }
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           let node = Self.restored(saved.root) {
            root = node
            let ids = panes.map(\.id)
            focusID = ids.contains(saved.focus) ? saved.focus : ids[0]
        }
        store = (defaults, key)
    }

    /// 马上存（退出、切到后台前）；平时改动后自己会存
    public func save() {
        saving?.cancel()
        saving = nil
        guard let store, let data = try? JSONEncoder().encode(Saved(root: Self.stored(root), focus: focusID)) else { return }
        store.defaults.set(data, forKey: store.key)
        onSave?()
    }

    /// 存完以后（Mac 标签组跟着给正显示的那组存一份副本）
    @ObservationIgnored var onSave: (() -> Void)?

    /// 拖分隔条时每一帧都在变：停下半秒再存
    private func scheduleSave() {
        guard store != nil else { return }
        saving?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func stored(_ node: Node) -> Stored {
        switch node {
        case .pane(let pane):
            // 正开着「选择会话」新标签的：存成开它之前显示的那个
            let shown = pane.key ?? pane.previous.flatMap { pane.tabs.contains($0) ? $0 : nil } ?? pane.tabs.last
            return Stored(id: pane.id, key: shown, tabs: pane.tabs)
        case .split(let split):
            return Stored(id: split.id, vertical: split.axis == .vertical, items: split.items.map(stored), fractions: split.fractions)
        }
    }

    /// 读回来的不对（存坏了、块数超过这台设备的上限）就当没存过；同一个会话只留第一处
    private static func restored(_ saved: Stored) -> Node? {
        var ids = Set<UUID>(), seen = Set<String>()
        func node(_ item: Stored) -> Node? {
            guard ids.insert(item.id).inserted else { return nil }
            if let items = item.items {
                guard items.count >= 2, let fractions = item.fractions, fractions.count == items.count, fractions.allSatisfy({ $0 > 0 }) else { return nil }
                let children = items.compactMap(node)
                guard children.count == items.count else { return nil }
                let total = fractions.reduce(0, +)
                return .split(Split(id: item.id, axis: item.vertical == true ? .vertical : .horizontal, items: children, fractions: fractions.map { $0 / total }))
            }
            var pane = Pane(id: item.id, key: nil)
            pane.tabs = Array((item.tabs ?? item.key.map { [$0] } ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(tabbed ? .max : 1))
            pane.key = item.key.flatMap { pane.tabs.contains($0) ? $0 : nil } ?? pane.tabs.first
            return .pane(pane)
        }
        // 横着的 iPhone 存下的三列：竖着打开时也接着留着（竖着不分屏，再转横就回来）
        guard let root = node(saved), leaves(root).count <= (tabbed ? maxPanes : 3) else { return nil }
        return normalized(root)
    }

    // MARK: 标签组（整套分屏换一套，Mac）

    /// 现在的分屏（怎么分、每块开着哪些标签、比例、当前块）存成一份：切到别的标签组前存下
    func layout() -> Data? { try? JSONEncoder().encode(Saved(root: Self.stored(root), focus: focusID)) }

    /// 整套换成另一份（nil、存坏了 = 一块空白）。各块按存着的 id 认：切回来时 SwiftUI 认得出是同一批块。
    /// 量过的位置、大小都是旧那套的，清掉（标签多、组多时别越攒越多）
    func load(_ data: Data?) {
        if let data, let saved = try? JSONDecoder().decode(Saved.self, from: data), let node = Self.restored(saved.root) {
            root = node
            let ids = panes.map(\.id)
            focusID = ids.contains(saved.focus) ? saved.focus : ids[0]
        } else {
            let pane = Pane(id: UUID(), key: nil)
            root = .pane(pane)
            focusID = pane.id
        }
        let alive = Set(panes.map(\.id))
        sizes = sizes.filter { alive.contains($0.key) }
        contentFrames = contentFrames.filter { alive.contains($0.key) }
        stripFrames = stripFrames.filter { alive.contains($0.key) }
        bodyFrames = bodyFrames.filter { alive.contains($0.key) }
        composerTops = composerTops.filter { alive.contains($0.key) }
        tabFrames = tabFrames.filter { alive.contains($0.key) }
        #if os(macOS)
        truncated = truncated.filter { alive.contains($0.key) }
        tabWidths = tabWidths.filter { alive.contains($0.key) }
        peekWork?.cancel()
        hoveredStrips = []
        hoveredTabs = []
        if peek != nil { peek = nil }
        #endif
    }

    /// 在最右边加一列放这个会话（标签组里加会话 = 多一列，11-10：组里的会话多列摆出来）；已经开着就切过去，空白时直接放进去
    func appendColumn(_ key: String) {
        if let open = pane(holding: key) { activate(open.id, key); return }
        if isPristine { setKey(focusID, key); return }
        let new = Pane(id: UUID(), key: key)
        if case .split(var split) = root, split.axis == .horizontal {
            let n = CGFloat(split.items.count)
            split.fractions = split.fractions.map { $0 * n / (n + 1) }
            split.items.append(.pane(new))
            split.fractions.append(1 / (n + 1))
            root = .split(split)
        } else {
            root = .split(Split(id: UUID(), axis: .horizontal, items: [root, .pane(new)], fractions: [0.5, 0.5]))
        }
        focusID = new.id
    }

    /// 每个标签各占一列、平分（标签组右键「每个会话一列」）：按现在的先后（从左上到右下、块里从左到右），当前会话还是当前块
    func arrangeColumns() {
        guard keys.count > 1 else { return }
        let current = focused
        // 每块正显示的那个留在原来的块里（块 id 不变，SwiftUI 不用重建它的对话），别的标签各开一块新的
        let items: [Node] = panes.flatMap { pane in pane.tabs.map { key in Node.pane(Pane(id: key == pane.key ? pane.id : UUID(), key: key)) } }
        root = .split(Split(id: UUID(), axis: .horizontal, items: items, fractions: Array(repeating: 1 / CGFloat(items.count), count: items.count)))
        focusID = items.first { if case .pane(let p) = $0 { return p.key == current } else { return false } }?.id ?? items[0].id
    }

    /// 改一份存着的分屏（不是正显示的那套）：读进一份不画的分屏里改完再存回去
    static func edited(_ data: Data?, _ change: (ChatPanes) -> Void) -> Data? {
        let scratch = ChatPanes()
        scratch.load(data)
        change(scratch)
        return scratch.layout()
    }

    /// 存着的那份里开着哪些会话（从左上到右下）
    static func keys(in data: Data?) -> [String] {
        guard let data, let saved = try? JSONDecoder().decode(Saved.self, from: data), let node = restored(saved.root) else { return [] }
        return leaves(node).flatMap(\.tabs)
    }

    // MARK: 树的操作

    /// halve：同一个方向时，原来那块的地方一分为二（别的不动）；false = 这一排一起平分
    private static func splitting(_ node: Node, _ id: UUID, axis: Axis, new: Pane, after: Bool, halve: Bool) -> Node {
        switch node {
        case .pane(let pane):
            guard pane.id == id else { return node }
            return .split(Split(id: UUID(), axis: axis, items: after ? [node, .pane(new)] : [.pane(new), node], fractions: [0.5, 0.5]))
        case .split(var split):
            if split.axis == axis, let index = split.items.firstIndex(where: { $0.id == id }), case .pane = split.items[index] {
                // 同一个方向：插在旁边
                let half = split.fractions[index] / 2
                split.fractions[index] = half
                let at = after ? index + 1 : index
                split.items.insert(.pane(new), at: at)
                split.fractions.insert(half, at: at)
                if !halve { split.fractions = Array(repeating: 1 / CGFloat(split.items.count), count: split.items.count) }
                return .split(split)
            }
            split.items = split.items.map { splitting($0, id, axis: axis, new: new, after: after, halve: halve) }
            return .split(split)
        }
    }

    /// 刚分出来的那块（pane）所在的每一层，从外往里排一遍：装着它的那一项不够最小尺寸，就从同一层别的项超出最小尺寸的部分里匀过来。
    /// 别的项只出让、不撑大：你拖得比最小尺寸还小的块保持原样
    private static func fitted(_ node: Node, _ size: CGSize, around pane: UUID) -> Node {
        guard case .split(var split) = node, let path = split.items.firstIndex(where: { contains($0, pane) }) else { return node }
        let horizontal = split.axis == .horizontal
        let length = max(0, (horizontal ? size.width : size.height) - CGFloat(split.items.count - 1) * PaneDivider.thickness)
        if length > 0 {
            var mins = split.items.indices.map { index in
                let need = minLength(split.items[index], split.axis) / length
                return index == path ? need : min(need, split.fractions[index])
            }
            // 怎么都放不下：别的项让到各自的最小尺寸为止，剩下的都给它（挤了用户自己拖）
            let others = mins.indices.filter { $0 != path }.reduce(0) { $0 + mins[$1] }
            if others + mins[path] > 1 { mins[path] = max(split.fractions[path], 1 - others) }
            split.fractions = clamped(split.fractions, mins)
        }
        let share = length * split.fractions[path]
        split.items[path] = fitted(split.items[path], horizontal ? CGSize(width: share, height: size.height) : CGSize(width: size.width, height: share), around: pane)
        return .split(split)
    }

    private static func contains(_ node: Node, _ pane: UUID) -> Bool {
        switch node {
        case .pane(let item): item.id == pane
        case .split(let split): split.items.contains { contains($0, pane) }
        }
    }

    /// 比例里不够各自最小值的补足，补的从其余项超出最小值的部分里按超出多少扣（谁都不会被扣到最小值以下）；
    /// 最小值加起来就超过 1（怎么都放不下）时不动
    static func clamped(_ fractions: [CGFloat], _ mins: [CGFloat]) -> [CGFloat] {
        guard fractions.count == mins.count, mins.reduce(0, +) <= 1.0001 else { return fractions }
        let raised = zip(fractions, mins).map { max($0, $1) }
        let deficit = raised.reduce(0, +) - fractions.reduce(0, +)
        guard deficit > 0.0001 else { return fractions }
        let spare = zip(raised, mins).map { max(0, $0 - $1) }
        let total = spare.reduce(0, +)
        guard total > 0 else { return fractions }
        return raised.indices.map { raised[$0] - min(spare[$0], deficit * spare[$0] / total) }
    }

    private static func removing(_ node: Node, _ id: UUID) -> Node? {
        switch node {
        case .pane(let pane):
            return pane.id == id ? nil : node
        case .split(var split):
            var items: [Node] = [], fractions: [CGFloat] = []
            for (index, item) in split.items.enumerated() {
                if let kept = removing(item, id) {
                    items.append(kept)
                    fractions.append(split.fractions[index])
                }
            }
            guard !items.isEmpty else { return nil }
            if items.count == 1 { return items[0] }   // 这一层只剩一个：不要这一层
            let total = fractions.reduce(0, +)
            split.items = items
            split.fractions = fractions.map { total > 0 ? $0 / total : 1 / CGFloat(items.count) }
            return .split(split)
        }
    }

    /// 里面一层和外面同方向的（关掉中间一块后会出现）：摊平成一层
    private static func normalized(_ node: Node) -> Node {
        guard case .split(var split) = node else { return node }
        var items: [Node] = [], fractions: [CGFloat] = []
        for (index, item) in split.items.enumerated() {
            let child = normalized(item)
            if case .split(let inner) = child, inner.axis == split.axis {
                items += inner.items
                fractions += inner.fractions.map { $0 * split.fractions[index] }
            } else {
                items.append(child)
                fractions.append(split.fractions[index])
            }
        }
        split.items = items
        split.fractions = fractions
        return .split(split)
    }

    private static func mapPane(_ node: Node, _ id: UUID, _ change: (inout Pane) -> Void) -> Node {
        switch node {
        case .pane(var pane):
            if pane.id == id { change(&pane) }
            return .pane(pane)
        case .split(var split):
            split.items = split.items.map { mapPane($0, id, change) }
            return .split(split)
        }
    }

    private static func mapSplit(_ node: Node, _ id: UUID, _ change: (inout Split) -> Void) -> Node {
        guard case .split(var split) = node else { return node }
        if split.id == id { change(&split) } else { split.items = split.items.map { mapSplit($0, id, change) } }
        return .split(split)
    }

    /// 一块（或一组）沿 axis 至少要多长（每块按 unit 算：分屏时匀大小用 minSize，拖分隔条用 dragMin）
    static func minLength(_ node: Node, _ axis: Axis, _ unit: CGSize = minSize) -> CGFloat {
        switch node {
        case .pane: return axis == .horizontal ? unit.width : unit.height
        case .split(let split):
            let lengths = split.items.map { minLength($0, axis, unit) }
            return split.axis == axis ? lengths.reduce(0, +) + CGFloat(lengths.count - 1) * PaneDivider.thickness : lengths.max() ?? 0
        }
    }
}

/// 拖进来落在一块的哪里：中间（换掉）或四边（从那边分出来）
enum DropZone: Equatable {
    case center, leading, trailing, top, bottom

    var edge: Edge? {
        switch self {
        case .center: nil
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    /// 高亮哪一片
    func rect(in size: CGSize) -> CGRect {
        let w = size.width, h = size.height
        switch self {
        case .center: return CGRect(x: 0, y: 0, width: w, height: h)
        case .leading: return CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .trailing: return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .top: return CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottom: return CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        }
    }

    var hint: String {
        switch self {
        case .center: L("放置于此")
        case .leading: L("放到左侧")
        case .trailing: L("放到右侧")
        case .top: L("放到上方")
        case .bottom: L("放到下方")
        }
    }
}

/// 对话页知道自己在哪一块：只有当前块往导航栏上放标题、按钮（几块都放会叠在一起）
struct ChatPaneContext: Equatable {
    let panes: ChatPanes
    let id: UUID

    static func == (a: ChatPaneContext, b: ChatPaneContext) -> Bool { a.panes === b.panes && a.id == b.id }

    var isFocused: Bool { panes.focusID == id }
    /// 往导航栏上放标题、按钮的那块：只有一块，或者是当前块
    var ownsBar: Bool { panes.count <= 1 || isFocused }
}

extension EnvironmentValues {
    @Entry var chatPane: ChatPaneContext?
    @Entry var listPanes = ListPanes()
    #if os(macOS)
    /// Mac App 给的：标题条右边会话自己的按钮、「更多」菜单
    @Entry var paneAccessory: TarsPaneAccessory?
    /// 分屏铺进了窗口工具栏那一带（Mac 主窗口）：工具栏多高。最上面一排的标题条往上长到窗口顶
    @Entry var paneBand: CGFloat = 0
    #endif
}

#if os(macOS)
/// Mac 主窗口：每块标题条右边、会话自己的按钮（文件、改动、测试、在 VS Code 中打开……）和「更多」菜单，由 Mac App 按会话给。
/// 原来在窗口标题栏上、只对当前块；10-23 起挪到各块自己的标题条上，窗口的标题栏让给分屏。
/// 比较时总算相等（闭包按会话 key 现做按钮，哪一份都一样）：Mac 主窗口每次重算都会新建一份，
/// 比不出相等的话整个分屏（几列 × 几百行消息）的环境都要重传一遍（10-26 4 列分屏卡顿的主因）
public struct TarsPaneAccessory: Equatable {
    let buttons: (String) -> AnyView
    let menu: (String, Bool) -> AnyView

    public static func == (a: TarsPaneAccessory, b: TarsPaneAccessory) -> Bool { true }

    /// buttons：标题条上的按钮（块太窄时不显示，折进「更多」）；menu(key, folded)：「更多」菜单和右键标签的菜单，folded = 按钮折进来了、菜单里要有它们
    public init(buttons: @escaping (String) -> AnyView, menu: @escaping (_ key: String, _ folded: Bool) -> AnyView) {
        self.buttons = buttons
        self.menu = menu
    }
}

/// 分屏标题条上的小图标按钮：26×24，鼠标移上去有浅底；颜色跟外面（当前块深一点、别的块浅一点）
public struct TarsPaneButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    public init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .background(Color.primary.opacity(hovering ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
#endif

/// 会话列表在左右分栏里、右边是分屏时：哪些会话开在右边（浅浅标出来）、长按「在右侧 / 下方分屏打开」、能不能拖进右边
struct ListPanes {
    var open: Set<String> = []
    var split: ((String, Bool) -> Void)?
}

// MARK: 拖会话

/// 从左边列表（或某一块的标题）拖会话：只在本 App 里认的数据类型，拖到输入框里不会变成一串字
enum PaneDrag {
    static let type = UTType(exportedAs: "com.mrhong.tars.session")
    /// 正拖着的（落点上显示它的卡片）。只在主线程上读写
    nonisolated(unsafe) static var current: (key: String, source: UUID?, card: SessionCard)?

    #if os(macOS)
    /// 正从左边栏拖着会话：各块对话区上临时盖一层接住它（见 PaneView）
    nonisolated(unsafe) static let state = PaneDragState()
    #endif

    static func provider(key: String, source: UUID? = nil, card: SessionCard) -> NSItemProvider {
        current = (key, source, card)
        #if os(macOS)
        DispatchQueue.main.async { state.begin() }
        #endif
        let payload = key + "\n" + (source?.uuidString ?? "")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data(payload.utf8), nil)
            return nil
        }
        return provider
    }

    static func decode(_ data: Data) -> (key: String, source: UUID?)? {
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        guard let key = parts.first, !key.isEmpty else { return nil }
        return (key, parts.count > 1 ? UUID(uuidString: parts[1]) : nil)
    }
}

#if os(macOS)
/// 正拖着会话（系统拖放）：对话区自己收拖进来的文件、图片，落点会被它截走、分屏这层收不到（10-26 反馈：拖过去没反应），
/// 拖着的时候各块对话区上盖一层透明的接住它。松开鼠标就撤（等落下那一下处理完）
@Observable
final class PaneDragState {
    var active = false
    @ObservationIgnored private var timer: Timer?

    func begin() {
        active = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { PaneDrag.state.active = false }
        }
    }
}
#endif

/// 拖着走的会话卡片（半透明跟着手指 / 指针），落点上也画一张
public struct SessionCard: View {
    let title: String
    let status: String
    let line: String
    let detail: String
    let dot: Color

    public init(title: String, status: String, line: String, detail: String, dot: Color) {
        self.title = title
        self.status = status
        self.line = line
        self.detail = detail
        self.dot = dot
    }

    init(_ session: SessionInfo) {
        let status = session.error != nil ? L("出错已停止") : (["waiting": L("待确认"), "busy": L("正在工作"), "idle": L("空闲")][session.activity] ?? "")
        self.init(title: session.title, status: status, line: session.activityText ?? session.preview ?? "",
                  detail: [session.sourceName, session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                  dot: StatusColor.of(session))
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(title.prefix(1)))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.claude, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(.subheadline).weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(dot).frame(width: 6, height: 6)
                    Text([status, line].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
                }
                .font(.ui(.caption)).foregroundStyle(.secondary)
                if !detail.isEmpty { Text(detail).font(.ui(.caption2)).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

extension View {
    /// 能拖进分屏的会话（左边列表的一行、某一块的标题）
    func sessionDrag(key: String, source: UUID? = nil, card: SessionCard) -> some View {
        onDrag { PaneDrag.provider(key: key, source: source, card: card) } preview: { card.opacity(0.92) }
    }

    /// 左右分栏里的会话行：能拖到右边的分屏里（不分栏时照旧）
    @ViewBuilder
    func sessionDrag(if enabled: Bool, _ session: SessionInfo) -> some View {
        if enabled { sessionDrag(key: session.key, card: SessionCard(session)) } else { self }
    }
}

// MARK: 画出来

/// 整个分屏
struct ChatPanesView<Content: View>: View {
    let panes: ChatPanes
    /// Mac 主窗口：铺进窗口工具栏那一带，最上面一排的标题条（标签）就是窗口的标题栏
    var fillsTitlebar = false
    let content: (String) -> Content
    @Environment(AppModel.self) private var model
    #if os(macOS)
    /// 窗口标题栏 + 工具栏多高
    @State private var band: CGFloat = 52
    #endif

    /// 这棵分屏视图的编号：信件卡片登记位置时带上，信绳只连同一棵里的（主窗口里可能同时有两棵）
    @State private var ropeTree = UUID()

    var body: some View {
        #if os(macOS)
        if fillsTitlebar {
            // 整个分屏往上铺到窗口顶，最上面一排的标题条往上长到工具栏那么高（从窗口量：顶上安全区在这里量出来不准）
            tree
                .environment(\.paneBand, band)
                .background(TitlebarBridge { if abs($0 - band) > 0.5 { band = $0 } })
                .modifier(NoTopEdgeEffect())
                .ignoresSafeArea(.container, edges: .top)
        } else {
            tree
        }
        #else
        tree
        #endif
    }

    private var tree: some View {
        RootNodeView(root: panes.root, panes: panes, content: content)
            .environment(\.peerRopeTree, ropeTree)
            .coordinateSpace(.named(ChatPanes.space))
            // 同一封信在两列里的两张卡片之间的绳子（只有分屏时）
            .overlay { if panes.count > 1 { PeerRopeLayer(tree: ropeTree) } }
            .overlay { TabDragGhost(panes: panes) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { panes.bounds = $0 }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { panes.origin = $0 }
            // 导航栏、标题栏底下垫对话区的底色
            .background(Theme.chatBackground)
            // 读现在的值，不用送来的：一下子连变两次（点「一分为二」= 先切到这块、再切到新的一块）时，先送来的是过时的
            .onChange(of: panes.focused) { _, _ in
                if let key = panes.focused { model.current = GroupKey.id(key) == nil ? key : nil }
            }
            // 解散了的群（自己解散、别的设备上解散）：它的标签跟着关掉。群列表取到以后才比（刚启动时还没取到，别把上次开着的群关了）
            .onChange(of: model.groups.loaded ? model.groups.items.map(\.id) : nil, initial: true) { _, ids in
                guard let ids else { return }
                let alive = Set(ids)
                for key in panes.keys where GroupKey.id(key).map({ !alive.contains($0) }) == true { panes.close(key: key) }
            }
    }
}

/// atTop：贴着分屏顶边（最上面一排）。Mac 主窗口里这一排的标题条要往上铺进工具栏那一带
/// 最外层：只有一块时也按「只有这一项的一层分割」画，始终是同一个 SplitView。
/// 不然从一块分成两块（或关回一块）时，最外层从「一块」换成「分割」，SwiftUI 当成换了视图，
/// 原来那块的对话整个销毁重建——长对话重排一遍要零点几秒到两秒（11-01 反馈开关多列卡）。各块按 id 认，增删一块别的不动
private struct RootNodeView<Content: View>: View {
    let root: ChatPanes.Node
    let panes: ChatPanes
    let content: (String) -> Content

    private static var soloID: UUID { UUID(uuidString: "00000000-0000-0000-0000-00000000501E")! }

    var body: some View {
        SplitView(split: split, panes: panes, atTop: true, content: content)
    }

    private var split: ChatPanes.Split {
        if case .split(let split) = root { return split }
        return ChatPanes.Split(id: Self.soloID, axis: .horizontal, items: [root], fractions: [1])
    }
}

private struct NodeView<Content: View>: View {
    let node: ChatPanes.Node
    let panes: ChatPanes
    let atTop: Bool
    let content: (String) -> Content

    var body: some View {
        switch node {
        case .pane(let pane): PaneView(pane: pane, panes: panes, atTop: atTop, content: content)
        case .split(let split): SplitView(split: split, panes: panes, atTop: atTop, content: content)
        }
    }
}

/// 一层分割：几项左右或上下排，中间是能拖的分隔条
private struct SplitView<Content: View>: View {
    let split: ChatPanes.Split
    let panes: ChatPanes
    let atTop: Bool
    let content: (String) -> Content
    /// 拖分隔条时，按下那一刻的比例
    @State private var dragStart: [CGFloat]?

    var body: some View {
        GeometryReader { geo in
            let horizontal = split.axis == .horizontal
            let length = max(0, (horizontal ? geo.size.width : geo.size.height) - CGFloat(split.items.count - 1) * PaneDivider.thickness)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(split.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        PaneDivider(axis: split.axis, dragging: dragStart != nil, captureHover: panes.captureHandles) { delta in
                            if dragStart == nil { dragStart = panes.fractions(split.id) }
                            if let dragStart { panes.drag(split.id, index - 1, from: dragStart, by: delta / max(length, 1), length: length) }
                        } ended: {
                            dragStart = nil
                        } reset: {
                            panes.equalize(split.id)
                        }
                        .zIndex(1)
                    }
                    let share = length * (split.fractions.indices.contains(index) ? split.fractions[index] : 1 / CGFloat(split.items.count))
                    // 往下一层要包一下（视图不能直接套自己）；上下分的只有第一项还贴着顶边
                    AnyView(NodeView(node: item, panes: panes, atTop: atTop && (horizontal || index == 0), content: content))
                        .frame(width: horizontal ? share : nil, height: horizontal ? nil : share)
                }
            }
        }
    }
}

/// 一块：顶上标题条，下面是对话（还没选会话就列出能选的）；会话拖到上面时标出会落在哪
private struct PaneView<Content: View>: View {
    let pane: ChatPanes.Pane
    let panes: ChatPanes
    let atTop: Bool
    let content: (String) -> Content
    @Environment(AppModel.self) private var model
    @State private var zone: DropZone?
    #if os(iOS)
    /// 横着的 iPhone 键盘弹出来时收起标题条：键盘占掉一大半高度，标题条再占 40 点，输入框就被顶到看不见（10-27）
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var typing = false
    #endif

    private var showsHeader: Bool {
        #if os(iOS)
        !(verticalSize == .compact && typing)
        #else
        true
        #endif
    }

    var body: some View {
        let context = ChatPaneContext(panes: panes, id: pane.id)
        let shown = zone ?? (panes.preview?.pane == pane.id ? panes.preview?.zone : nil)
        // 从列表拖来的会话停在群聊这块中间：松开是进群（自测画「拖着停在那儿」时按画的那个会话算）
        let dragged = panes.preview?.pane == pane.id ? panes.preview?.key : (PaneDrag.current?.source == nil ? PaneDrag.current?.key : nil)
        let joining = shown == .center ? model.joinableGroup(dragged, into: pane.key) : nil
        #if os(macOS)
        let tabZone = panes.tabZone(pane.id)
        #endif
        VStack(spacing: 0) {
            if showsHeader { PaneHeader(pane: pane, panes: panes, focused: context.isFocused, atTop: atTop) }
            Group {
                if let key = pane.key {
                    content(key).id(key)
                } else {
                    PanePicker(paneID: pane.id, panes: panes)
                }
            }
            // 最小尺寸写 0：里面哪一行比这一块宽也不往外报，这一块（连同顶上的标题条）始终是分给它的大小；
            // 真放不下时靠左下放（输入框留在原处），多出来的裁掉
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottomLeading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatPanes.space)) } action: { panes.bodyFrames[pane.id] = $0 }
            #if os(macOS)
            // 别让内容画到别的块上，也别伸进左边栏底下（Mac 窗口底下没有要延伸过去的地方）
            .clipped()
            // 拖标签、拖会话的落点都在对话区里算（同 VS Code：标签栏上是插到第几个，对话区是中间 / 四边），高亮也只盖对话区
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatPanes.space)) } action: { panes.contentFrames[pane.id] = $0 }
            .overlay {
                if PaneDrag.state.active {
                    Color.clear.contentShape(Rectangle())
                        .onDrop(of: [PaneDrag.type], delegate: PaneDropDelegate(pane: pane.id, panes: panes, zone: $zone, inContent: true, join: join))
                }
            }
            .overlay {
                if let shown {
                    DropZoneOverlay(zone: shown, card: panes.preview?.pane == pane.id ? nil : PaneDrag.current?.card, key: panes.preview?.key,
                                    joining: joining?.name)
                } else if let tabZone {
                    DropZoneOverlay(zone: tabZone, card: nil, plain: true)
                }
            }
            .animation(.snappy(duration: 0.15), value: shown)
            .animation(.snappy(duration: 0.15), value: tabZone)
            #else
            // 别让内容画到别的块上；贴着屏幕底的那块，输入栏的底色照样延伸到 Home 横条那一带
            .mask(Rectangle().ignoresSafeArea())
            #endif
        }
        .environment(\.chatPane, context)
        // 在这一块里按下去（点消息、点输入框、拖滚动条……）：它就是当前块
        .background(PressWatcher { panes.focus(pane.id) })
        .onGeometryChange(for: CGSize.self) { $0.size } action: { panes.sizes[pane.id] = $0 }
        #if !os(macOS)
        .onDrop(of: [PaneDrag.type], delegate: PaneDropDelegate(pane: pane.id, panes: panes, zone: $zone, join: join))
        // 拖标题条换位置（同 Mac 拖标签）：iPad 每块只放一个会话、没有标签栏，整块都算落点
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatPanes.space)) } action: { panes.contentFrames[pane.id] = $0 }
        .overlay {
            if let shown {
                DropZoneOverlay(zone: shown, card: panes.preview?.pane == pane.id ? nil : PaneDrag.current?.card,
                                key: panes.preview?.key, joining: joining?.name)
            } else if let tabZone = panes.tabZone(pane.id) {
                DropZoneOverlay(zone: tabZone, card: nil, plain: true)
            }
        }
        .animation(.snappy(duration: 0.15), value: shown)
        .animation(.snappy(duration: 0.15), value: panes.tabZone(pane.id))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in typing = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in typing = false }
        #endif
    }

    /// 从列表拖来的会话落在群聊这块中间：进群，返回 true；别的情况（拖的是别块的标签）交回去照常放
    private func join(_ key: String, _ source: UUID?) -> Bool {
        source == nil && model.joinDropped(key, into: pane.key)
    }
}

private struct PaneDropDelegate: DropDelegate {
    let pane: UUID
    let panes: ChatPanes
    @Binding var zone: DropZone?
    /// 挂在对话区上（Mac）：按对话区的大小算四边
    var inContent = false
    /// 落在中间时先问这块要不要自己接（群聊：拖来的会话进群）；接了就不再开标签
    var join: ((String, UUID?) -> Bool)?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [PaneDrag.type]) }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: zone == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone
        zone = nil
        guard let target, let provider = info.itemProviders(for: [PaneDrag.type]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: PaneDrag.type.identifier) { data, _ in
            guard let data, let drag = PaneDrag.decode(data) else { return }
            DispatchQueue.main.async {
                if target == .center, join?(drag.key, drag.source) == true { return }
                panes.drop(drag.key, from: drag.source, on: pane, zone: target)
            }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        let current = PaneDrag.current
        let next = panes.zone(at: info.location, in: pane, size: inContent ? panes.contentFrames[pane]?.size : nil, source: current?.source, key: current?.key)
        if next != zone { zone = next }
    }
}

/// 拖着会话停在一块上：要落的那一半（或整块）蒙一层品牌色，中间是那个会话的卡片
private struct DropZoneOverlay: View {
    let zone: DropZone
    let card: SessionCard?
    /// 自测截图：没有真的在拖，按 key 画卡片
    var key: String?
    /// 拖标签：只蒙一层（同 VS Code），拖着的标签自己跟着指针
    var plain = false
    /// 松开就进这个群（会话拖到群聊那块中间）
    var joining: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let rect = zone.rect(in: geo.size).insetBy(dx: 6, dy: 6)
            VStack(spacing: 10) {
                if !plain {
                    if let card = card ?? key.flatMap({ model.paneCard($0) }) {
                        card.opacity(0.9).scaleEffect(min(1, (rect.width - 40) / 260), anchor: .center).frame(width: max(0, rect.width - 20))
                    }
                    Text(joining.map { L("松开加入群「%@」", $0) } ?? zone.hint).font(.ui(.footnote).weight(.semibold)).foregroundStyle(Theme.claude)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .background(Theme.claude.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.claude.opacity(0.55), lineWidth: 1.5))
            .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

#if os(iOS)
/// 横着的 iPhone 左上角拉出会话列表的按钮：一颗浮在标题条上的毛玻璃（高光细边 + 淡阴影，和标题条分出层次；10-27），
/// 图标就是侧栏的标志。点过一次之前，每次出现时图标轻弹两下、外圈扩散两圈，提示这里能拉出会话列表；点过就不再提示
private struct SidebarHandle: View {
    let action: () -> Void
    @AppStorage("sidebarHandleLearned") private var learned = false
    @State private var hint = 0

    var body: some View {
        Button {
            learned = true
            action()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(Theme.claude)
                .symbolEffect(.bounce, options: .repeat(2), value: hint)
                .frame(width: 40, height: 30)
                .background { glass }
                .background {
                    // 扩散的外圈：平时看不见，提示时从按钮边上扩出去、淡掉（只在这个圈上动，不牵动别的排版）
                    Capsule().stroke(Theme.claude, lineWidth: 1.5)
                        .keyframeAnimator(initialValue: Ripple(), trigger: hint) { ring, value in
                            ring.scaleEffect(x: value.scale, y: 1 + (value.scale - 1) * 0.4).opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) {
                                CubicKeyframe(1.35, duration: 0.9)
                                MoveKeyframe(1)
                                CubicKeyframe(1.35, duration: 0.9)
                                MoveKeyframe(1)
                            }
                            KeyframeTrack(\.opacity) {
                                MoveKeyframe(0.75)
                                LinearKeyframe(0, duration: 0.9)
                                MoveKeyframe(0.75)
                                LinearKeyframe(0, duration: 0.9)
                                MoveKeyframe(0)
                            }
                        }
                }
                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("会话列表")
        .task {
            guard !learned else { return }
            try? await Task.sleep(for: .milliseconds(600))   // 转屏、换页的动画走完再提示
            hint += 1
        }
    }

    private struct Ripple {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    /// iOS 26 起是可交互的液态玻璃；iOS 18 是厚一点的磨砂 + 上沿高光细边（薄磨砂在浅色标题条上几乎看不出来）
    @ViewBuilder private var glass: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom),
                                                lineWidth: 0.8))
        }
    }
}
#endif

/// 每块顶上的一条：状态点 + 会话标题，右边「左右分屏」「上下分屏」和 ×。几块时当前块标题加粗、底下一道品牌色。
/// 标题条能拖：拖到别的块上就把这个会话挪过去。
/// Mac 上做成浏览器的标签页（10-23）：深一点的标签栏上一张圆角标签和下面的对话连成一片，右边是会话自己的按钮（文件、改动、测试、
/// 在 VS Code 中打开）、分屏按钮和「更多」；块窄了按钮依次折进「更多」。主窗口里最上面一排的标签栏铺进窗口工具栏那一带，空白处能拖动窗口
/// 横着的 iPhone：没有导航栏（省出高度），会话的按钮（标记、朗读、⋯）放进每块的标题条；左上那块再放「会话列表」按钮
struct BarlessPanes {
    var showList: () -> Void
}

extension EnvironmentValues {
    @Entry var barlessPanes: BarlessPanes?
}

private struct PaneHeader: View {
    let pane: ChatPanes.Pane
    let panes: ChatPanes
    let focused: Bool
    var atTop = false
    @Environment(AppModel.self) private var model
    @Environment(\.barlessPanes) private var barless
    #if os(iOS)
    /// 这一条有多宽：横着的 iPhone 三列时每列二百多点，按钮少放几个，标题才看得见
    @State private var stripWidth: CGFloat = 1000
    #endif
    #if os(macOS)
    @Environment(\.paneAccessory) private var accessory
    @Environment(\.paneBand) private var paneBand
    /// 这一条有多宽（外面给的）：决定按钮放得下几个
    @State private var width: CGFloat = 1000
    /// 窗口左上角的红绿灯：左边栏收起、标签栏铺到窗口左上角时让开
    @State private var lightsInset: CGFloat = 0
    @State private var hoveringStrip = false
    #endif

    var body: some View {
        #if os(macOS)
        macBody
        #else
        let session = pane.key.flatMap(model.session)
        let several = panes.count > 1
        HStack(spacing: 7) {
            if let barless, atTop, panes.panes.first?.id == pane.id {
                SidebarHandle(action: barless.showList).padding(.trailing, 2)
            }
            PaneMark(key: pane.key, size: 6)
            Text(title(session))
                .font(.ui(.subheadline).weight(focused && several ? .semibold : .regular))
                .foregroundStyle(focused || !several ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if barless != nil, let key = pane.key {
                if let id = GroupKey.id(key) { GroupPaneButtons(id: id) } else { sessionButtons(key, alive: session != nil, room: stripWidth) }
            }
            if panes.count < ChatPanes.maxPanes {
                splitButton(down: false)
                if !ChatPanes.sideBySideOnly { splitButton(down: true) }
            }
            if several {
                Button { panes.close(pane.id) } label: { icon("xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭此分屏")
            }
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: Self.height)
        // 块被挤得比这一条还窄时：不往外撑，多出来的按钮裁掉（拖宽就回来）
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
        .background(Theme.chatBackground, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(focused && several ? Theme.claude : Color.primary.opacity(0.1))
                .frame(height: focused && several ? 2 : 0.5)
        }
        // 只裁左右（多出来的按钮），上下不裁：左上角侧栏按钮的阴影、提示的外圈要露出来
        .mask(Rectangle().padding(.vertical, -12))
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .opacity(pane.key != nil && panes.tabDrag?.key == pane.key ? 0.5 : 1)
        .modifier(HeaderDrag(pane: pane, panes: panes))
        .animation(.snappy(duration: 0.18), value: focused)
        #endif
    }

    private func title(_ session: SessionInfo?) -> String {
        pane.key.map(model.paneTitle) ?? L("选择会话")
    }

    #if os(iOS)
    /// 没有导航栏时（横着的 iPhone）：这块会话的标记、朗读、⋯（同竖着时导航栏右边那组）。
    /// 窄的列（三列时）先收起朗读、再收起标记（「⋯」菜单里都有），留地方给标题
    private func sessionButtons(_ key: String, alive: Bool, room: CGFloat) -> some View {
        HStack(spacing: 0) {
            if alive, room >= 290 {
                let marked = model.isMarked(key)
                Button { model.setMarked(key, !marked) } label: {
                    Image(systemName: marked ? "star.fill" : "star").foregroundStyle(marked ? Theme.claude : Color.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel(marked ? "已标记，轻点取消标记" : "标记会话")
            }
            if room >= 340 || Speaker.shared.speaking != nil {
                Button { model.externalAction = (key, .speak, UUID()) } label: {
                    Image(systemName: Speaker.shared.speaking != nil ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .symbolEffect(.variableColor.iterative, isActive: Speaker.shared.speaking != nil)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel(Speaker.shared.speaking != nil ? "停止朗读" : "朗读最新回复")
            }
            Button { model.externalAction = (key, .menu, UUID()) } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .accessibilityLabel("会话菜单")
        }
        .font(.ui(.subheadline))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }
    #endif

    #if os(macOS)
    // MARK: Mac：标签页

    static let tabRow: CGFloat = 36
    private static let foot: CGFloat = 7
    /// 标签多了一起变窄，最窄这么宽（再多就横着滚）；最宽这么宽
    private static let minTab: CGFloat = 96
    private static let maxTab: CGFloat = 240

    private var macBody: some View {
        let several = panes.count > 1
        // 最上面一排：标签栏往上长到窗口顶（工具栏那一带），标签贴着底边。多出 1 点：对话的滚动视图贴着工具栏底边时会往上伸到工具栏底下，
        // 盖住标签栏（点不着标签、按钮），隔开一点就不会
        let rise = self.rise
        // 按钮放几个：先保证每个标签至少 120 宽（标题看得清），放不下时会话的按钮先折进「更多」，再不够连分屏按钮也折进去
        let count = CGFloat(max(1, entries.count))
        let level = [2, 1].first { tabRoom($0) / count >= 120 } ?? 0
        // 指着展开了一个标签：会话和分屏的按钮先收进「更多」、「+」也收起，地方让给它（标签按平时的档算宽度，展开的时候不跟着变）
        let expand = panes.peek.flatMap { $0.pane == pane.id ? entries.firstIndex(of: $0.key.isEmpty ? nil : $0.key) : nil }
        return HStack(alignment: .bottom, spacing: 4) {
            #if KITELINE_MAC
            // 顶上放不下倒挂的组标签（工具栏那一带太矮）时，退回标签栏最前面的色块菜单
            if showsGroupChip, !showsGroupStrip { TarsTabGroupChip().frame(height: Self.tabRow) }
            #endif
            // 标签占按钮剩下的地方（靠左）；按钮保持完整
            tabs(several: several, level: level, expand: expand)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            actions(several: several, level: expand == nil ? level : 0)
                .frame(height: Self.tabRow)
                .fixedSize()
        }
        .padding(.leading, 6 + lightsInset).padding(.trailing, 6)
        .padding(.top, rise)
        .frame(height: Self.tabRow + rise, alignment: .bottom)
        #if KITELINE_MAC
        // 会话组：一排倒挂在窗口顶边的组标签（标签栏往上长到窗口顶的那一段里），点了切组
        .overlay(alignment: .topLeading) {
            if showsGroupStrip {
                TarsTabGroupStrip(height: rise - 1)
                    .padding(.leading, 6 + lightsInset).padding(.trailing, 6)
            }
        }
        #endif
        // 块被挤得比这一条还窄时：不往外撑，多出来的按钮裁掉（拖宽就回来）
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatPanes.space)) } action: { panes.stripFrames[pane.id] = $0 }
        // 指着标签栏：标签展开着时在空白、按钮上也保持（见 ChatPanes.hoverStrip）
        .onHover { on in
            hoveringStrip = on
            panes.hoverStrip(pane.id, on)
        }
        .onDisappear { if hoveringStrip { panes.hoverStrip(pane.id, false) } }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            width = frame.width
            // 红绿灯在窗口左上角 78 点以内：铺进工具栏那一带、又贴着窗口左边时让开
            let inset = rise > 0 ? max(0, 78 - frame.minX) : 0
            if abs(inset - lightsInset) > 0.5 { lightsInset = inset }
        }
        .background {
            ZStack(alignment: .bottom) {
                Theme.chatBackground
                MacPalette.tabStrip
                // 标签栏底边一道细线，正显示的标签盖住自己那一段（和下面的对话连成一片）；正显示标签组时是组的颜色
                if let groupTint {
                    Rectangle().fill(groupTint).frame(height: 2)
                } else {
                    Rectangle().fill(MacPalette.separator).frame(height: 0.5)
                }
            }
            // 空白处：按住拖窗口、双击缩放（工具栏那一带被标签栏占了）
            .modifier(WindowDragArea())
            // 从左边栏拖来的会话落在空白处：加到最后一个标签后面
            .onDrop(of: [PaneDrag.type], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                let id = pane.id, panes = panes
                provider.loadDataRepresentation(forTypeIdentifier: PaneDrag.type.identifier) { data, _ in
                    guard let data, let drag = PaneDrag.decode(data) else { return }
                    DispatchQueue.main.async {
                        panes.place(drag.key, from: drag.source, in: id, at: panes.pane(id)?.tabs.count ?? 0)
                    }
                }
                return true
            }
        }
        .clipped()
        .animation(.snappy(duration: 0.18), value: focused)
    }

    /// 最上面一排往上长到窗口顶（工具栏那一带）多出来的高；多 1 点：对话的滚动视图贴着工具栏底边时会往上伸到工具栏底下，盖住标签栏
    private var rise: CGFloat {
        guard atTop, paneBand > 0 else { return 0 }
        let base = max(0, paneBand - Self.tabRow) + 1
        #if KITELINE_MAC
        // 有会话组时顶上留够一排倒挂组标签的高（最上面一排的各块一起加高，标签栏照样齐平）
        if panes === KitelineKit.panes, KitelineKit.tabGroupCount > 0 { return max(base, Self.groupStrip + 1) }
        #endif
        return base
    }
    /// 倒挂在窗口顶边的会话组标签那一排的高
    static let groupStrip: CGFloat = 24

    /// 标签：开着的会话，再加上 nil = 「选择会话」新标签（点了「+」、或空的一块）
    private var entries: [String?] { pane.tabs.map(Optional.some) + (pane.key == nil ? [nil] : []) }

    /// 按钮放到第 level 档时，标签一共能有多宽
    private func tabRoom(_ level: Int) -> CGFloat { max(0, width - 12 - lightsInset - actionsWidth(level) - 30 - groupChipWidth) }

    #if KITELINE_MAC
    /// 主窗口最左上那一块：标签栏最前面放标签组的色块组名（同 Edge 标签栏上的组名），点开切组、改名改色
    private var showsGroupChip: Bool { panes === KitelineKit.panes && KitelineKit.tabGroupCount > 0 && panes.panes.first?.id == pane.id }
    /// 标签栏上面那一带够高（≥ 20）就把组画成一排倒挂在窗口顶边的标签；不够高退回色块菜单
    private var showsGroupStrip: Bool { showsGroupChip && rise >= Self.groupStrip }
    private var groupChipWidth: CGFloat { showsGroupChip && !showsGroupStrip ? 112 : 0 }
    /// 正显示某个标签组时，标签栏底边那道线用组的颜色（同 Edge 组里标签下面的色线）
    private var groupTint: Color? { panes === KitelineKit.panes ? KitelineKit.activeTabGroupTint : nil }
    #else
    private var groupChipWidth: CGFloat { 0 }
    private var groupTint: Color? { nil }
    #endif

    /// 一排标签 + 「+」。标签按标题的宽度来（最宽 240），放不下时一起变窄，窄到 96 还放不下就横着滚。
    /// expand：指着展开的是第几个（它按完整标题变宽，见 TabsLayout）
    @ViewBuilder
    private func tabs(several: Bool, level: Int, expand: Int?) -> some View {
        let entries = entries
        let room = tabRoom(level)
        let cap = min(Self.maxTab, max(Self.minTab, room / CGFloat(max(1, entries.count))))
        let plus = pane.key != nil && expand == nil
        let row = TabsLayout(minTab: Self.minTab, maxTab: Self.maxTab, trailing: plus,
                             report: TabsReport(panes: panes, pane: pane.id, keys: entries.map { $0 ?? "" }), expand: expand) {
            ForEach(Array(entries.enumerated()), id: \.element) { index, key in
                // 两个都没在显示的标签之间一道细竖线（同浏览器）
                let divider = index > 0 && key != pane.key && entries[index - 1] != pane.key
                PaneTab(key: key, pane: pane, panes: panes, focused: focused, several: several, cap: cap, divider: divider)
                    .zIndex(key == pane.key ? 1 : 0)
            }
            if plus {
                TarsPaneButton("plus", help: L("新标签页：选择要在此打开的会话")) { withAnimation(.snappy) { panes.newTab(pane.id) } }
                    .padding(.leading, 2).padding(.bottom, 5)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.snappy(duration: 0.2), value: pane.tabs)
        if CGFloat(entries.count) * Self.minTab > room {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .onChange(of: pane.key) { _, key in withAnimation { proxy.scrollTo(key, anchor: .center) } }
            }
        } else {
            row
        }
    }

    /// 右边那组按钮大约多宽（算标签能有多宽用）
    private static func actionsWidth(_ level: Int) -> CGFloat { [26, 78, 190][max(0, min(2, level))] }

    /// 这一块的按钮多宽：群在块窄时还多留一个成员按钮
    private func actionsWidth(_ level: Int) -> CGFloat { Self.actionsWidth(level) + (level < 2 && GroupKey.id(pane.key) != nil ? 48 : 0) }

    /// 右边的按钮：会话自己的（Mac App 给，对正显示的那个标签）、左右 / 上下分屏、「更多」。块窄了先把会话的按钮折进「更多」，再窄连分屏按钮也折进去
    private func actions(several: Bool, level: Int) -> some View {
        let canSplit = panes.count < ChatPanes.maxPanes
        let group = GroupKey.id(pane.key)
        let hasMenu = (pane.key != nil && (accessory != nil || group != nil)) || (level < 1 && canSplit) || several
        return HStack(spacing: 0) {
            // 群：成员、标记（同会话的按钮放在这里）
            if level == 2, let group {
                GroupPaneButtons(id: group)
                Spacer().frame(width: 8)
            } else if let group {
                // 块再窄：会话的按钮、分屏按钮都折进「更多」，群的成员按钮一直留着（看成员、拉人都从它进，用户 11-01 找不到抽屉）
                GroupPaneButtons(id: group, membersOnly: true)
                Spacer().frame(width: 4)
            } else if level == 2, let key = pane.key, let accessory {
                accessory.buttons(key)
                Spacer().frame(width: 8)
            }
            if level >= 1, canSplit {
                TarsPaneButton("square.split.2x1", help: L("左右分屏：在右侧新开一块，选择要显示的会话")) { split(down: false) }
                TarsPaneButton("square.split.1x2", help: L("上下分屏：在下方新开一块，选择要显示的会话")) { split(down: true) }
            }
            if hasMenu {
                Menu {
                    if let group {
                        GroupPaneMenu(id: group, folded: level < 2)
                    } else if let key = pane.key, let accessory {
                        accessory.menu(key, level < 2)
                    }
                    if level < 1 || several {
                        Divider()
                        menuItems
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("更多"))
            }
        }
        .foregroundStyle(focused || !several ? .secondary : .tertiary)
    }
    #endif

    /// 「左右分屏」「上下分屏」：把这一块往右 / 往下一分为二，新的一块里选会话
    private func splitButton(down: Bool) -> some View {
        Button { split(down: down) } label: {
            icon(down ? "square.split.1x2" : "square.split.2x1")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(down ? "上下分屏" : "左右分屏")
    }

    @ViewBuilder
    private var menuItems: some View {
        if panes.count < ChatPanes.maxPanes {
            Button { split(down: false) } label: { Label("左右分屏", systemImage: "square.split.2x1") }
                .disabled(!panes.canSplit(pane.id, .horizontal))
            Button { split(down: true) } label: { Label("上下分屏", systemImage: "square.split.1x2") }
                .disabled(!panes.canSplit(pane.id, .vertical))
        }
        if panes.count > 1 {
            Button(role: .destructive) { panes.close(pane.id) } label: { Label("关闭此分屏", systemImage: "xmark") }
        }
    }

    private func split(down: Bool) {
        panes.focus(pane.id)
        if !panes.splitFocused(down: down) { model.flash(L("已达到分屏数量上限")) }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: symbol == "xmark" ? 10 : 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    #if os(macOS)
    static let height: CGFloat = tabRow
    #else
    static let height: CGFloat = 38
    #endif
}

#if os(macOS)
/// 一个标签：状态点、会话标题、×。正显示的那个是对话的底色、和下面连成一片（几块时当前块的顶上一道强调色）；
/// 别的标签平铺在标签栏上，鼠标指上去浅浅一层底、出现 ×（同浏览器）。点一下切过去；拖到别的块（或这块的边上）挪过去；
/// 右键：关闭、关闭其他、关闭右侧、分出去，和会话的全部操作
private struct PaneTab: View {
    /// nil = 「选择会话」新标签
    let key: String?
    let pane: ChatPanes.Pane
    let panes: ChatPanes
    let focused: Bool
    let several: Bool
    let cap: CGFloat
    /// 左边和前一个标签之间画一道细竖线
    var divider = false
    @Environment(AppModel.self) private var model
    @Environment(\.paneAccessory) private var accessory
    @State private var hovering = false
    /// 正拖着会话停在这个标签上：插到它前面还是后面（画一道竖线）
    @State private var dropGap: TabDropDelegate.Gap?
    @State private var tabWidth: CGFloat = 0

    private static let foot: CGFloat = 7

    var body: some View {
        let active = key == pane.key
        let lit = active && (focused || !several)
        let shape = PaneTabShape(foot: Self.foot)
        HStack(spacing: 7) {
            PaneMark(key: key, size: 7)
            Text(title)
                .font(.ui(.subheadline).weight(lit ? .semibold : .medium))
                .foregroundStyle(lit ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // 标签变宽变窄（指着展开、收回）的动画里：标题直接换成排好的样子、裁在自己的框里跟着框展开，
                // 不做新旧两份的淡入淡出（中途会叠出两份字、旧的「…」留在原处）
                .contentTransition(.identity)
                .clipped()
            // 窄的时候没在显示的标签不留 × 的位置，先让给标题（关它：右键，或点过去再关）
            if closable, active || cap >= 150 {
                Button { panes.closeTab(pane.id, key) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(active || hovering ? 1 : 0)
                .help(L("关闭标签页"))
                .accessibilityLabel(L("关闭标签页"))
            }
        }
        .padding(.leading, 12 + Self.foot).padding(.trailing, (closable && (active || cap >= 150) ? 6 : 12) + Self.foot)
        .frame(height: PaneHeader.tabRow - 5)
        .background {
            if active {
                shape.fill(Theme.chatBackground)
                PaneTabShape(foot: Self.foot, open: true).stroke(MacPalette.separator, lineWidth: 0.5)
            } else if hovering {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07))
                    .padding(.horizontal, Self.foot).padding(.top, 2).padding(.bottom, 4)
            }
        }
        .overlay(alignment: .leading) {
            if divider && !hovering {
                Rectangle().fill(MacPalette.separator).frame(width: 1, height: 15).offset(x: -0.5, y: -1)
            }
        }
        .overlay {
            if active && focused && several {
                Rectangle().fill(Theme.claude)
                    .frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipShape(shape)
            }
        }
        .opacity(key != nil && panes.tabDrag?.key == key ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { on in
            hovering = on
            TabWindowLock.hold(on)
            // 标题被截短的：停一会儿按完整标题变宽（ChatPanes.hoverTab）
            panes.hoverTab(ChatPanes.Peek(pane: pane.id, key: key ?? ""), on)
        }
        .onDisappear {
            guard hovering else { return }
            TabWindowLock.hold(false)
            panes.hoverTab(ChatPanes.Peek(pane: pane.id, key: key ?? ""), false)
        }
        .onTapGesture {
            if let key { panes.activate(pane.id, key) } else { panes.focus(pane.id) }
        }
        .help(help)
        .contextMenu { menu }
        .modifier(TabDragGesture(key: key, pane: pane, panes: panes))
        // 会话拖到这个标签上：落在左半边插到它前面，右半边插到后面（同浏览器排标签顺序）
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabWidth = $0 }
        // 会话之间互发消息时，纸鸢在分屏的标签之间飞（见 PeerStage）
        .peerAnchor(key ?? "", tab: true)
        .onDrop(of: [PaneDrag.type], delegate: TabDropDelegate(key: key, pane: pane, panes: panes, width: tabWidth, gap: $dropGap))
        .overlay(alignment: gap == .after ? .trailing : .leading) {
            if gap != nil {
                Capsule().fill(Theme.claude).frame(width: 2.5).padding(.vertical, 6)
                    .padding(gap == .after ? .trailing : .leading, Self.foot - 1)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 从左边栏拖来停在这里：插入竖线画在哪边（拖标签时的竖线由 TabDragGhost 画在跟手的标签上面）
    private var gap: TabDropDelegate.Gap? { dropGap }

    /// 能关：会话的标签都能关（最后一个关了这块变空 / 关掉）；「选择会话」新标签要有别的标签可回、或者还有别的块
    private var closable: Bool { key != nil || !pane.tabs.isEmpty || several }

    private var title: String {
        guard let key else { return L("选择会话") }
        return model.paneTitle(key)
    }

    /// 指着看：状态 · 机器 · 项目（原来窗口标题下面那行小字）；群：群名 · 几个成员 · 成员都有谁。
    /// 读不登记观察的快照：提示文字不值得让标签跟着这个会话的每次推送重画
    private var help: String {
        let session = key.flatMap(model.sessionSnapshot)
        guard let key else { return L("选择要在此打开的会话，或从左侧拖入") }
        if let id = GroupKey.id(key) {
            guard let group = model.groups.group(id) else { return L("群已解散") }
            return [group.name, L("%lld 个成员", group.members.count), group.members.map { model.title(of: $0) }.joined(separator: L("、"))]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let session {
            return [title, SessionCard(session).status, session.sourceName, session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return [model.pastMeta[key]?.title ?? "", L("已结束")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var menu: some View {
        if let key {
            Button(L("关闭标签页")) { panes.closeTab(pane.id, key) }
            if pane.tabs.count > 1 {
                Button(L("关闭其他标签页")) { withAnimation(.snappy) { panes.closeOtherTabs(pane.id, keeping: key) } }
                if pane.tabs.last != key {
                    Button(L("关闭右侧标签页")) { withAnimation(.snappy) { panes.closeOtherTabs(pane.id, keeping: key, rightOnly: true) } }
                }
                Divider()
                Button(L("移到右侧分屏")) { panes.drop(key, from: pane.id, on: pane.id, zone: .trailing) }
                Button(L("移到下方分屏")) { panes.drop(key, from: pane.id, on: pane.id, zone: .bottom) }
            }
            #if KITELINE_MAC
            // 主窗口的分屏才有标签组（世界模式里浮着的那张卡片不是）
            if panes === KitelineKit.panes { TarsTabGroupMenu(key: key, moving: true) }
            #endif
            if let id = GroupKey.id(key) {
                Divider()
                GroupPaneMenu(id: id, folded: false)
            } else if let accessory {
                Divider()
                accessory.menu(key, false)
            }
        } else if closable {
            Button(L("关闭标签页")) { panes.closeTab(pane.id, nil) }
        }
    }
}

/// 会话拖到某个标签上：左半边插到它前面，右半边插到后面
private struct TabDropDelegate: DropDelegate {
    enum Gap { case before, after }
    let key: String?
    let pane: ChatPanes.Pane
    let panes: ChatPanes
    let width: CGFloat
    @Binding var gap: Gap?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [PaneDrag.type]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // 拖的就是这个标签自己：不算
        if let dragged = PaneDrag.current?.key, dragged == key { gap = nil; return DropProposal(operation: .forbidden) }
        let next: Gap = info.location.x < width / 2 ? .before : .after
        if gap != next { gap = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { gap = nil }

    func performDrop(info: DropInfo) -> Bool {
        let where_ = gap
        gap = nil
        guard let where_, let provider = info.itemProviders(for: [PaneDrag.type]).first else { return false }
        let base = key.flatMap { pane.tabs.firstIndex(of: $0) } ?? pane.tabs.count
        let index = where_ == .after ? base + 1 : base
        provider.loadDataRepresentation(forTypeIdentifier: PaneDrag.type.identifier) { data, _ in
            guard let data, let drag = PaneDrag.decode(data) else { return }
            DispatchQueue.main.async {
                panes.place(drag.key, from: drag.source, in: pane.id, at: index)
            }
        }
        return true
    }
}

/// 按住标签拖（同 VS Code）：在窗口里自己跟着指针走，不走系统拖放——系统拖放落到对话区上会被它收文件的落点截走（10-26 反馈：拖过去没反应），也没法自动测。
/// 拖到标签栏上 = 插到那里（排顺序、挪到别的块）；拖到某块对话区的中间 = 挪进那一块，四边 = 从那边分出来；别处松手 = 不动；拖着时按 Esc 取消
private struct TabDragGesture: ViewModifier {
    let key: String?
    let pane: ChatPanes.Pane
    let panes: ChatPanes

    func body(content: Content) -> some View {
        if let key {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatPanes.space)) } action: { panes.tabFrames[pane.id, default: [:]][key] = $0 }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(ChatPanes.space))
                        .onChanged { value in panes.dragTab(key, from: pane.id, at: value.location) }
                        .onEnded { _ in panes.endTabDrag() }
                )
        } else {
            content
        }
    }
}


/// 标签的样子：上面两个圆角，底下两只脚往外弯、和标签栏底边接上（同浏览器）。open = 只描上边和两侧（底边和对话连着，不描）
private struct PaneTabShape: Shape {
    var radius: CGFloat = 8
    var foot: CGFloat
    var open = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.minX + foot, right = rect.maxX - foot, top = rect.minY, bottom = rect.maxY
        path.move(to: CGPoint(x: rect.minX, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - foot), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: top), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + radius), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - foot))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: bottom), control: CGPoint(x: right, y: bottom))
        if !open { path.closeSubpath() }
        return path
    }
}

/// 一排标签（最后一个子视图是「+」时 trailing = true，它按自己的宽度）：每个标签按标题要的宽度来（最宽 maxTab）；
/// 总宽放不下时同浏览器，短的照旧、长的平分剩下的（不窄于 minTab，标题截短）。外面不给宽度（横着滚）时每个最宽 160。
/// expand：指着展开的第几个标签按完整标题变宽（最宽 peekMax）：先用按钮收起让出的地方，不够再缩右边的、再缩左边的（最窄到只剩状态点）。
/// 别的标签从平时排出来的宽度开始缩；缩右边的时它左边不动、缩左边的时它右边不动，指针一直还在它上面（不会一展开就移出去、收回、又展开地来回跳）
private struct TabsLayout: Layout {
    let minTab: CGFloat
    let maxTab: CGFloat
    let trailing: Bool
    /// 平时（没展开时）排完记下哪些标签的标题被截短了、这一排多宽
    var report: TabsReport?
    var expand: Int?

    private static let peekMax: CGFloat = 560

    private func widths(_ available: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let count = subviews.count - (trailing ? 1 : 0)
        guard count > 0 else { return ideals }
        let expand = self.expand.flatMap { $0 < count ? $0 : nil }
        guard let available, available.isFinite else {
            var result = ideals.indices.map { $0 < count ? min(ideals[$0], 160) : ideals[$0] }
            // 横着滚：展开的那个按完整标题往右长
            if let expand { result[expand] = max(result[expand], min(ideals[expand], Self.peekMax)) }
            return result
        }
        guard let expand, let report, let normal = report.panes.tabWidths[report.pane], normal.count == count else { return fit(available, ideals, count) }
        // 先照平时的样子，再给展开的那个补宽
        var result = normal + ideals[count...]
        let want = min(ideals[expand], Self.peekMax) - result[expand]
        guard want > 0 else { return result }
        var gain = max(0, available - result.reduce(0, +))
        for index in Array((expand + 1)..<count).reversed() + Array(0..<expand) where gain < want {
            let least = subviews[index].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
            let cut = min(want - gain, max(0, result[index] - least))
            result[index] -= cut
            gain += cut
        }
        result[expand] += min(want, gain)
        return result
    }

    /// 平时的分法：从要得少的开始分，每个拿「自己要的」和「剩下的平分」里小的那个
    private func fit(_ available: CGFloat, _ ideals: [CGFloat], _ count: Int) -> [CGFloat] {
        var result = ideals
        var remaining = available - (trailing ? ideals[count] : 0)
        for (rank, index) in (0..<count).sorted(by: { ideals[$0] < ideals[$1] }).enumerated() {
            let share = remaining / CGFloat(count - rank)
            result[index] = min(ideals[index], maxTab, max(minTab, share))
            remaining -= result[index]
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = widths(proposal.width, subviews).reduce(0, +)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? min($0, total) : nil } ?? total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 和 sizeThatFits 用同一个宽度分（不用 bounds：取整后差零点几，分法会变）
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? bounds.width
        let widths = widths(available, subviews)
        if let report, expand == nil {
            let count = subviews.count - (trailing ? 1 : 0)
            let cut = (0..<max(0, count)).filter { widths[$0] < subviews[$0].sizeThatFits(.unspecified).width - 0.5 }
            report.panes.truncated[report.pane] = Set(cut.compactMap { report.keys.indices.contains($0) ? report.keys[$0] : nil })
            report.panes.tabWidths[report.pane] = Array(widths.prefix(max(0, count)))
        }
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(.unspecified).height
            subview.place(at: CGPoint(x: x, y: bounds.maxY), anchor: .bottomLeading, proposal: ProposedViewSize(width: widths[index], height: height))
            x += widths[index]
        }
    }
}

/// 标签栏排完往分屏里记的：哪块、各标签的 key（「选择会话」是空串）
private struct TabsReport {
    let panes: ChatPanes
    let pane: UUID
    let keys: [String]
}

/// 鼠标在标签上时窗口拖不动：标签栏铺在标题栏那一带，按住拖动会先被系统当成拖窗口（窗口服务器那层，SwiftUI 的拖动收不到），
/// 标签就拖不走、窗口跟着动。离开标签就还原，标签栏空白处照旧能拖窗口（WindowDragArea）。
/// 记着指着的标签数：从一个标签挪到相邻的，「进」和「出」谁先到都不会提前还原
@MainActor
enum TabWindowLock {
    private static var count = 0
    private static weak var window: NSWindow?

    static func hold(_ on: Bool) {
        count = max(0, count + (on ? 1 : -1))
        if count > 0, window == nil {
            let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
            guard let target = NSApp.window(withWindowNumber: number), target.isMovable else { return }
            target.isMovable = false
            window = target
        } else if count == 0, let target = window {
            target.isMovable = true
            window = nil
        }
    }
}

/// 标签栏的空白处：按住拖动窗口，双击照系统设置缩放 / 最小化（主窗口的工具栏那一带让给了标签栏）。
/// 用 SwiftUI 的拖窗口手势（macOS 15 起）：这一带的鼠标按下在 AppKit 那层落到对话的滚动视图上，挂 NSView 收不到
private struct WindowDragArea: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .simultaneousGesture(TapGesture(count: 2).onEnded { Self.doubleClick() })
                .allowsWindowActivationEvents(true)
        } else {
            content
        }
    }

    /// 同系统：「桌面与程序坞 → 连按窗口标题栏以」设的是缩放还是最小化
    @MainActor
    private static func doubleClick() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// 分屏铺进窗口工具栏那一带时，里面的滚动视图（对话、标签条）不要 macOS 26 顶边那层模糊（滚动口袋）：标签栏本身不透明，用不着它；
/// 窗口被系统搬去别的屏幕、台前调度缩放过之后，这层模糊会盖在整排标签和按钮上（10-25 截图：点得着、看不清）。
/// 自测对照：TARS_EDGE_EFFECT=1 保留
private struct NoTopEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *), ProcessInfo.processInfo.environment["TARS_EDGE_EFFECT"] != "1" {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// 分屏铺进窗口工具栏那一带时挂在底下：量标题栏 + 工具栏多高（窗口变大小、进出全屏都重量），
/// 并让标题栏透明——不透明的标题栏会把这一带的鼠标全收走（拖窗口用），标签、按钮点不着；离开对话页时还原
private struct TitlebarBridge: NSViewRepresentable {
    let changed: (CGFloat) -> Void

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: BridgeView, context: Context) { view.changed = changed }

    final class BridgeView: NSView {
        var changed: (CGFloat) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []
        private weak var host: NSWindow?
        private var wasTransparent = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard newWindow !== host else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            host?.titlebarAppearsTransparent = wasTransparent
            host = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== host else { return }
            host = window
            wasTransparent = window.titlebarAppearsTransparent
            window.titlebarAppearsTransparent = true
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                })
            }
            // 换屏幕、换倍数、台前调度放回来、重新成为前台之后，系统可能把工具栏底色重新显示出来
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.keepClear() }
                })
            }
            measure()
        }

        /// 工具栏那一带让给标签栏：标题栏透明、工具栏底色（NSTitlebarBackgroundView，SwiftUI 的 toolbarBackgroundVisibility(.hidden) 就是藏起它）藏着。
        /// 被系统重新显示的话，毛玻璃盖在整排标签和按钮上，点得着、看不清（10-25 截图）：藏回去。系统的动画结束前后各看一次
        private func keepClear() {
            for delay in [0, 0.4, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated { self?.hideToolbarBackground() }
                }
            }
        }

        private func hideToolbarBackground() {
            guard let window = host, let theme = window.contentView?.superview else { return }
            var fixed = window.titlebarAppearsTransparent ? 0 : 1
            window.titlebarAppearsTransparent = true
            func walk(_ view: NSView) {
                guard view !== window.contentView else { return }
                if !view.isHidden, String(describing: type(of: view)).contains("TitlebarBackground") {
                    view.isHidden = true
                    fixed += 1
                }
                view.subviews.forEach(walk)
            }
            walk(theme)
            #if KITELINE_MAC
            if fixed > 0 { KitelineKit.log("标签栏：工具栏底色被重新显示，已藏回（\(fixed) 处）") }
            #endif
        }

        private func measure() {
            guard let window = host else { return }
            let height = max(0, window.frame.height - window.contentLayoutRect.maxY)
            DispatchQueue.main.async { [weak self] in self?.changed(height) }
        }
    }
}
#endif

/// 拖着的标签跟着指针走：一张半透明的标签挂在指针右下方（同 Finder 拖文件），不挡住标签栏上要插进去的那道竖线；iPad 拖标题条时挂在手指上方
private struct TabDragGhost: View {
    let panes: ChatPanes
    @Environment(AppModel.self) private var model
    #if os(macOS)
    private static let border = MacPalette.separator
    #else
    private static let border = Color.primary.opacity(0.12)
    #endif

    var body: some View {
        if let drag = panes.tabDrag {
            let width = max(80, drag.size.width - 14), height = max(24, drag.size.height)
            HStack(spacing: 7) {
                PaneMark(key: drag.key, size: 7)
                Text(model.paneTitle(drag.key))
                    .font(.ui(.subheadline).weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: height)
            .background(Theme.chatBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Self.border))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .opacity(0.96)
            #if os(macOS)
            .position(x: panes.tabPoint.x + 10 + width / 2, y: panes.tabPoint.y + 16 + height / 2)
            #else
            // 手指会挡住下面：画在手指上方
            .position(x: panes.tabPoint.x, y: panes.tabPoint.y - 36 - height / 2)
            #endif
            .allowsHitTesting(false)
            .transition(.opacity)
            // 停在标签栏上：要插进去的地方一道竖线
            if let line = panes.tabInsertLine {
                Capsule().fill(Theme.claude)
                    .frame(width: line.width, height: line.height)
                    .position(x: line.midX, y: line.midY)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// 标题条拖得动（有会话时）：拖到别的块上把会话挪过去
private struct HeaderDrag: ViewModifier {
    let pane: ChatPanes.Pane
    let panes: ChatPanes

    func body(content: Content) -> some View {
        if let key = pane.key {
            // 同 Mac 拖标签：窗口里自己跟着手指走（见 TabDragGesture）。拖到另一块中间 = 两块换位置，拖到边上 = 从那边分出来
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatPanes.space)) } action: { frame in
                    panes.tabFrames[pane.id] = [key: CGRect(origin: frame.origin, size: CGSize(width: min(frame.width, 240), height: frame.height))]
                }
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .named(ChatPanes.space))
                        .onChanged { value in panes.dragTab(key, from: pane.id, at: value.location) }
                        .onEnded { _ in panes.endTabDrag() }
                )
        } else {
            content
        }
    }
}

/// 空的一块（刚一分为二出来的）：列出还没打开的会话，点一个放进来；也可以从左边列表拖一个进来
private struct PanePicker: View {
    let paneID: UUID
    let panes: ChatPanes
    @Environment(AppModel.self) private var model
    @AppStorage("listSorting") private var sorting = "started"

    var body: some View {
        let open = Set(panes.keys)
        let others = model.sortedSessions(sorting).filter { !open.contains($0.key) }
        // 群同会话一样能开在这里（进行中的在前，历史群也能开：在里面发话会恢复成员）
        let groups = model.supportsGroups ? model.groups.items.filter { !open.contains(GroupKey.make($0.id)) }
            .sorted { model.isLive($0) && !model.isLive($1) } : []
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("选择要在此显示的会话").font(.ui(.headline))
                Text(others.isEmpty && groups.isEmpty ? "其他会话均已打开。也可从左侧列表拖入会话。" : "也可从左侧列表拖入会话，拖至哪一侧即从该侧拆分。")
                    .font(.ui(.footnote)).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                ForEach(others) { session in
                    Button {
                        withAnimation(.snappy) { panes.setKey(paneID, session.key) }
                    } label: {
                        PickerRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
                if !groups.isEmpty {
                    Text("会话群").font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, others.isEmpty ? 0 : 10).padding(.bottom, 2)
                    ForEach(groups) { group in
                        Button {
                            withAnimation(.snappy) { panes.setKey(paneID, GroupKey.make(group.id)) }
                        } label: {
                            GroupPickerRow(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.chatBackground)
    }
}

private struct PickerRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 10) {
            Text(String(session.title.prefix(1)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.claude)
                .frame(width: 32, height: 32)
                .background(Theme.claude.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.ui(.subheadline).weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(StatusColor.of(session)).frame(width: 6, height: 6)
                    Text(SessionCard(session).status + ([session.sourceName, session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""]
                        .filter { !$0.isEmpty }.map { " · " + $0 }.joined()))
                        .lineLimit(1)
                }
                .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle").foregroundStyle(Theme.claude)
        }
        .modifier(PickerRowStyle())
    }
}

/// 「选择会话」里的一个群：群头像、群名、几个成员（历史群标出来）
private struct GroupPickerRow: View {
    let group: GroupInfo
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.isLive(group)
        HStack(spacing: 10) {
            GroupAvatar(members: group.members, size: 32, dim: !live)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.ui(.subheadline).weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(L("%lld 个成员", group.members.count) + (live ? "" : " · " + L("历史群")))
                    .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle").foregroundStyle(Theme.claude)
        }
        .modifier(PickerRowStyle())
    }
}

/// 「选择会话」里一行的底：浅底圆角，Mac 上指着描一圈强调色
private struct PickerRowStyle: ViewModifier {
    #if os(macOS)
    @State private var hover = false
    #endif

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.botBubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            #if os(macOS)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.claude.opacity(hover ? 0.5 : 0)))
            .onHover { hover = $0 }
            #endif
            .contentShape(Rectangle())
    }
}

/// 标签、标题条最前面的小记号：会话是状态点；群是双人图标（成员有在工作的就是强调色）
/// 标签、标题条前面的状态点（群是两个人的小图标）。只读这个会话自己的 SessionSlot.tab（标题、状态、出错），
/// 别的会话有动静、这个会话换了个工具都不重画（标签多了每秒的推送会把所有标签重排一遍）
struct PaneMark: View {
    let key: String?
    var size: CGFloat = 7
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = GroupKey.id(key) {
            let busy = model.groups.group(id)?.members.contains { model.sessionSlot($0.key).tab?.activity == "busy" } ?? false
            Image(systemName: "person.2.fill")
                .font(.system(size: size + 3, weight: .semibold))
                .foregroundStyle(busy ? Theme.claude : Color.secondary)
        } else {
            Circle()
                .fill(key.flatMap { model.sessionSlot($0).tab }?.color ?? Color.secondary.opacity(0.4))
                .frame(width: size, height: size)
        }
    }
}

extension AppModel.SessionSlot.TabFace {
    /// 同 StatusColor.of：出错红、等确认橙、在工作主题色、空闲绿
    var color: Color {
        if failed { return Theme.removed }
        return ["waiting": Color.orange, "busy": Theme.claude, "idle": Theme.added][activity] ?? .secondary
    }
}

extension AppModel {
    /// 分屏标签、标题条上写的：会话标题（已结束的用历史里的）；群写群名。只读这个会话的 SessionSlot.tab（见 PaneMark）
    func paneTitle(_ key: String) -> String {
        if let id = GroupKey.id(key) { return groups.group(id)?.name ?? L("群已解散") }
        return sessionSlot(key).tab?.title ?? pastMeta[key]?.title ?? L("会话已结束")
    }

    /// 拖着走的卡片（会话 / 群）
    func paneCard(_ key: String) -> SessionCard? {
        if let id = GroupKey.id(key) { return groups.group(id).map { SessionCard(group: $0, model: self) } }
        return session(key).map(SessionCard.init)
    }
}

/// 块与块之间的分隔条：一道细线，按住拖调大小，双击恢复平分。
/// Mac 上指针放上去变成拖动的样子；iPad 上中间有个小把手
struct PaneDivider: View {
    let axis: Axis
    let dragging: Bool
    /// 自测截图：画成指针停在线的正中间
    var captureHover = false
    let changed: (CGFloat) -> Void
    let ended: () -> Void
    let reset: () -> Void
    @State private var hover = false
    /// 指针在线上的哪儿（沿着线量）：把手画在那里（iPad 没指着时在正中）
    @State private var along: CGFloat?
    /// 按下时把手在哪：拖着时它跟着指针 / 手指沿线走
    @State private var pressAlong: CGFloat?
    /// 线多长：把手别画出头；线的起点在窗口里的位置：按下的那一点换算到线上
    @State private var length: CGFloat = 0
    @State private var start: CGFloat = 0

    static let thickness: CGFloat = 1
    #if os(macOS)
    private static let grab: CGFloat = 9
    /// Mac 指着、拖着才露出把手
    private static let alwaysShown = false
    #else
    private static let grab: CGFloat = 22
    /// iPad 没有悬停：把手一直在（同系统分屏的把手）
    private static let alwaysShown = true
    #endif

    var body: some View {
        let horizontal = axis == .horizontal
        Rectangle()
            .fill(Color.primary.opacity(hover || dragging ? 0.22 : 0.12))
            .frame(width: horizontal ? Self.thickness : nil, height: horizontal ? nil : Self.thickness)
            .frame(maxWidth: horizontal ? nil : .infinity, maxHeight: horizontal ? .infinity : nil)
            .overlay {
                // 能按住的地方比线宽，盖到两边一点
                Color.clear
                    .frame(width: horizontal ? Self.grab : nil, height: horizontal ? nil : Self.grab)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if pressAlong == nil { pressAlong = (horizontal ? value.startLocation.y : value.startLocation.x) - start }
                                if let pressAlong { along = pressAlong + (horizontal ? value.translation.height : value.translation.width) }
                                changed(horizontal ? value.translation.width : value.translation.height)
                            }
                            .onEnded { _ in
                                pressAlong = nil
                                if !hover { along = nil }
                                ended()
                            }
                    )
                    .onTapGesture(count: 2, perform: reset)
                    .onHover { inside in
                        guard inside != hover else { return }
                        hover = inside
                        #if os(macOS)
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                        #endif
                    }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let point): along = horizontal ? point.y : point.x
                        case .ended: if pressAlong == nil { along = nil }
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        length = horizontal ? frame.height : frame.width
                        start = horizontal ? frame.minY : frame.minX
                    }
                    // 指着线：指针那儿出现一个把手（左右分的「⇆」、上下分的「⇅」），示意能拖；拖着时它跟着走、换成强调色。
                    // iPad 一直显示在线的正中
                    .overlay(alignment: horizontal ? .top : .leading) {
                        let shown = Self.alwaysShown || captureHover
                        if let along = along ?? (shown ? length / 2 : nil), shown || hover || pressAlong != nil {
                            let at = min(max(along, DividerHandle.size / 2 + 4), max(DividerHandle.size / 2 + 4, length - DividerHandle.size / 2 - 4))
                            DividerHandle(horizontal: horizontal, active: pressAlong != nil)
                                .offset(x: horizontal ? 0 : at - DividerHandle.size / 2, y: horizontal ? at - DividerHandle.size / 2 : 0)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: hover || pressAlong != nil)
                    #if os(macOS)
                    .help(L("拖动调整大小，双击恢复均分"))
                    #endif
                    .accessibilityLabel("调整分屏大小")
            }
    }
}

/// 分隔线上的把手：圆形小钮，里面左右（或上下）箭头；平时是玻璃底，拖着时淡淡的强调色底 + 细边
private struct DividerHandle: View {
    #if os(macOS)
    static let size: CGFloat = 24
    #else
    static let size: CGFloat = 28
    #endif
    let horizontal: Bool
    let active: Bool

    var body: some View {
        Image(systemName: horizontal ? "arrow.left.and.right" : "arrow.up.and.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(active ? Theme.claude : Color.secondary)
            .frame(width: Self.size, height: Self.size)
            .background {
                if active {
                    Circle().fill(Theme.chatBackground)
                    Circle().fill(Theme.claude.opacity(0.16))
                } else {
                    Circle().fill(.regularMaterial)
                }
            }
            .overlay(Circle().strokeBorder(active ? Theme.claude.opacity(0.6) : Color.primary.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }
}

// MARK: 在哪一块按下去了

/// 看这一块里有没有被按下（不抢事件：点按钮、点输入框、选字照常）：
/// Mac 上看窗口里的鼠标按下，iPad 上在窗口挂一个只看不抢的手势（同 TouchTravel），按的地方落在这一块里就告诉外面
private struct PressWatcher {
    let pressed: () -> Void
}

#if canImport(UIKit)
extension PressWatcher: UIViewRepresentable {
    func makeUIView(context: Context) -> PressWatcherView {
        let view = PressWatcherView()
        view.isUserInteractionEnabled = false
        view.pressed = pressed
        return view
    }

    func updateUIView(_ view: PressWatcherView, context: Context) { view.pressed = pressed }
}

final class PressWatcherView: UIView {
    var pressed: () -> Void = {}
    private var recognizer: PressRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        guard let window else { return }
        let next = PressRecognizer(target: nil, action: nil)
        next.began = { [weak self] touch in
            guard let self, self.window != nil else { return }
            // 弹着面板（菜单、选项……）时按的是面板，不算按在块上
            if self.window?.rootViewController?.presentedViewController != nil { return }
            if self.bounds.contains(touch.location(in: self)) { self.pressed() }
        }
        window.addGestureRecognizer(next)
        recognizer = next
    }
}

/// 只看不抢：手指一按下就记一下，然后自己认输，不挡任何别的手势
private final class PressRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var began: (UITouch) -> Void = { _ in }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { began(touch) }
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#elseif os(macOS)
extension PressWatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> PressWatcherView {
        let view = PressWatcherView()
        view.pressed = pressed
        return view
    }

    func updateNSView(_ view: PressWatcherView, context: Context) { view.pressed = pressed }
}

final class PressWatcherView: NSView {
    var pressed: () -> Void = {}
    private var monitor: Any?

    // 自己不接鼠标：点到的还是上面的消息、输入框
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // 面板（sheet）是另一个窗口：在面板里点不算
            if let self, let window = self.window, event.window === window {
                if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.pressed() }
            }
            return event
        }
    }
}
#endif

#if KITELINE_MAC
// MARK: Mac 主窗口用的

extension KitelineKit {
    /// Mac 主窗口右边的分屏（左边栏选中的是当前块的会话）
    public static let panes = ChatPanes()

    /// 左边栏的会话拖起来：拖进右边哪一块的哪一边就放到哪
    public static func dragProvider(key: String, card: SessionCard) -> NSItemProvider {
        PaneDrag.provider(key: key, card: card)
    }

    /// 左边栏右键「在右侧 / 下方分屏打开」：把当前块一分为二放这个会话（已经开着就切过去）；分不下返回 false
    @discardableResult
    public static func openSplit(_ key: String, down: Bool) -> Bool {
        if panes.keys.contains(key) {
            panes.show(key)
            return true
        }
        return panes.splitFocused(key: key, down: down)
    }

    /// 键盘操作当前块的标签（同浏览器：⌘T、⌘W、⌃⇥ / ⌃⇧⇥、⌘1…⌘9）
    public enum TabCommand: Equatable {
        case new, close, next, previous, last
        case select(Int)
    }

    /// 当前块的标签数（「选择会话」新标签也算一个）
    public static var tabCount: Int {
        guard let pane = panes.pane(panes.focusID) else { return 0 }
        return pane.tabs.count + (pane.key == nil && !pane.tabs.isEmpty ? 1 : 0)
    }

    /// 对当前块做一个标签操作；没什么可做的（没有标签、只有一个……）返回 false
    @discardableResult
    public static func tab(_ command: TabCommand) -> Bool {
        guard let pane = panes.pane(panes.focusID) else { return false }
        switch command {
        case .new:
            guard pane.key != nil else { return false }
            panes.newTab(pane.id)
        case .close:
            guard pane.key != nil || !pane.tabs.isEmpty || panes.count > 1 else { return false }
            panes.closeTab(pane.id, pane.key)
        case .next, .previous:
            guard !pane.tabs.isEmpty else { return false }
            guard let key = pane.key, let index = pane.tabs.firstIndex(of: key) else {
                panes.activate(pane.id, command == .next ? pane.tabs[0] : pane.tabs[pane.tabs.count - 1])
                return true
            }
            guard pane.tabs.count > 1 else { return false }
            let step = command == .next ? 1 : pane.tabs.count - 1
            panes.activate(pane.id, pane.tabs[(index + step) % pane.tabs.count])
        case .last:
            guard let key = pane.tabs.last else { return false }
            panes.activate(pane.id, key)
        case .select(let number):
            guard number >= 1, number <= pane.tabs.count else { return false }
            panes.activate(pane.id, pane.tabs[number - 1])
        }
        return true
    }

    /// 自测用：把会话拖到当前块第 index 个标签的位置，和拖到标签上一样
    public static func placeTab(_ key: String, at index: Int) {
        panes.place(key, from: nil, in: panes.focusID, at: index)
    }

    /// 自测用：把会话放到当前块的某一边（center / leading / trailing / top / bottom），和拖进来一样
    public static func dropOnFocused(_ key: String, zone: String) {
        let zones: [String: DropZone] = ["center": .center, "leading": .leading, "trailing": .trailing, "top": .top, "bottom": .bottom]
        guard let zone = zones[zone] else { return }
        if zone == .center, model?.joinDropped(key, into: panes.focused) == true { return }
        panes.drop(key, from: nil, on: panes.focusID, zone: zone)
    }

    /// 自测用：各块标签栏、每个标签、对话区在窗口里的位置（从窗口左上角算），按标签拖动时照着算鼠标坐标
    public static var tabGeometry: String {
        let o = panes.origin
        func text(_ r: CGRect) -> String { "\(Int(r.minX + o.x)),\(Int(r.minY + o.y)) \(Int(r.width))x\(Int(r.height))" }
        return panes.panes.enumerated().map { index, pane in
            let tabs = pane.tabs.map { key in "\(KitelineKit.model?.session(key)?.title ?? key)@\(panes.tabFrames[pane.id]?[key].map(text) ?? "?")" }
            return "块\(index + 1)\(pane.id == panes.focusID ? "*" : "")：标签栏 \(panes.stripFrames[pane.id].map(text) ?? "?")；对话区 \(panes.contentFrames[pane.id].map(text) ?? "?")；标签 " + tabs.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    /// 自测截图用：代码块、命令、思考右上角的拷贝钮都画出来（在打开会话之前设）
    public static func showCopyButtons() { CopyCorner.captureShown = true }

    /// 自测截图用：分隔线都画成指针停在上面（出现把手）
    public static func showDividerHandles(_ on: Bool) { panes.captureHandles = on }

    /// 自测截图用：当前块第 index 个标签画成指着展开的样子（nil = 收起）
    public static func peekTabs(_ index: Int?) { panes.debugPeek(index) }

    /// 自测用：当成指针挪到当前块第 index 个标签上（走悬停的计时和截短判断，同真鼠标）；nil = 移出标签栏
    public static func hoverTabs(_ index: Int?) { panes.debugHover(index) }

    /// 自测截图用：假装正拖着某个会话停在当前块的某一边（nil = 收起）
    public static func previewDrop(_ key: String?, zone: String) {
        let zones: [String: DropZone] = ["center": .center, "leading": .leading, "trailing": .trailing, "top": .top, "bottom": .bottom]
        if let key, let zone = zones[zone] { panes.preview = (panes.focusID, zone, key) } else { panes.preview = nil }
    }
}

/// Mac 主窗口右边：分屏的会话。fillsTitlebar = 铺进窗口工具栏那一带（标签栏就是标题栏）；accessory = 标题条上会话自己的按钮、菜单
/// 按值比较（外面配 .equatable()）：Mac 主窗口随左边栏数据（每台电脑每秒推一次状态）重算时，这里输入没变就整个跳过
public struct TarsPanesView: View, Equatable {
    let fillsTitlebar: Bool
    let accessory: TarsPaneAccessory?

    public init(fillsTitlebar: Bool = false, accessory: TarsPaneAccessory? = nil) {
        self.fillsTitlebar = fillsTitlebar
        self.accessory = accessory
    }

    public var body: some View {
        if let model = KitelineKit.model {
            ChatPanesView(panes: KitelineKit.panes, fillsTitlebar: fillsTitlebar) { key in
                // 群同会话一样开成一个标签
                Group { if let id = GroupKey.id(key) { MacGroupPane(id: id) } else { TarsConversationView(key: key) } }
            }
            .environment(\.paneAccessory, accessory)
            .environment(model)
        } else {
            ProgressView()
        }
    }
}
#endif
