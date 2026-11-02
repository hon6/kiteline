import SwiftUI

// 列表顶上的筛选条和「显示方式」菜单按钮：首页会话列表、历史会话共用，长得一样、用法一样

/// 一排筛选胶囊：放不下时横着划，划的时候左边贴到屏幕边（外面留的边距是 bleed）；
/// 右边还有别的东西（比如「显示方式」）时 trailingBleed 传 0，划到它跟前就收住
public struct FilterBar<Content: View>: View {
    let bleed: CGFloat
    let trailingBleed: CGFloat
    let content: Content

    public init(bleed: CGFloat = 16, trailingBleed: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.bleed = bleed
        self.trailingBleed = trailingBleed ?? bleed
        self.content = content()
    }

    public var body: some View {
        let row = HStack(spacing: 6) { content }
            .padding(.leading, bleed).padding(.trailing, trailingBleed)
            .padding(.vertical, 1)
        #if os(macOS)
        // Mac 上筛选条都放在竖着滚的列表里：用自己管手势的横向滚动（见 HorizontalStrip），上下滑不会被它接走
        HorizontalStrip(content: row.fixedSize().lookRoot())   // 按胶囊本来的宽排（不压缩、不截字），放不下就横着划
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
            .padding(.leading, -bleed).padding(.trailing, -trailingBleed)
        #else
        ScrollView(.horizontal, showsIndicators: false) { row }
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)   // 胶囊多了别把一排的总宽往上报，撑宽整页
            .padding(.leading, -bleed).padding(.trailing, -trailingBleed)
        #endif
    }
}

#if os(macOS)
/// Mac：放在竖着滚的列表里的一排横向滚动内容（筛选条）。
/// 系统的横向 ScrollView 在 Mac 上会把触控板的上下滑动也接走：两指上下滑到这一排上，外面的列表就停住不动
///（11-01 反馈：会话列表用触控板两指滚动会卡住，拖滚动条没事）。这里每次手势开始时看方向，
/// 以竖向为主的整次手势（连同松手后的惯性）原样交给外面的列表，横向为主的才自己滚；鼠标滚轮按每一下的方向分
private struct HorizontalStrip<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> StripScrollView {
        let scroll = StripScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = NSHostingView(rootView: content)
        return scroll
    }

    func updateNSView(_ scroll: StripScrollView, context: Context) {
        guard let host = scroll.documentView as? NSHostingView<Content> else { return }
        host.rootView = content
        host.setFrameSize(host.fittingSize)
    }

    /// 宽度跟外面给的走（胶囊多了也不往上报总宽），高度是一排胶囊的高
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: StripScrollView, context: Context) -> CGSize? {
        guard let host = scroll.documentView as? NSHostingView<Content> else { return nil }
        let fit = host.fittingSize
        return CGSize(width: proposal.width ?? fit.width, height: fit.height)
    }
}

final class StripScrollView: NSScrollView {
    /// 这一次手势归谁：true = 交给外面的列表
    private var passing = false

    override func scrollWheel(with event: NSEvent) {
        let gesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if !gesture {
            // 鼠标滚轮：竖着滚的给列表，横着的（含按住 Shift）自己滚
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
            return
        }
        if event.phase.contains(.mayBegin) {
            // 手指刚放上去（还没动）：两边都告诉一声，停下各自的惯性
            passing = true
            nextResponder?.scrollWheel(with: event)
            super.scrollWheel(with: event)
            return
        }
        if event.phase.contains(.began) {
            // 开始动了：以横向为主才自己滚，其余（含还看不出方向的）都给列表
            passing = !(abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY))
        }
        if passing { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
#endif

/// 一个筛选胶囊：状态圆点（或小图标，如「标记」的星星）+ 名字 + 个数；选中的填品牌色，个数是 0 的淡一点
public struct FilterChip: View {
    let title: String
    let count: Int
    let dot: Color?
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void

    public init(title: String, count: Int, dot: Color?, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.dot = dot
        self.symbol = symbol
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.app(size: 10, weight: .bold)).foregroundStyle(selected ? Color.white : (dot ?? Theme.claude))
                } else if let dot {
                    Circle().fill(selected ? .white : dot).frame(width: 6, height: 6)
                }
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .font(.ui(.footnote).weight(.semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(selected ? Theme.claude : Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
            .opacity(count == 0 && !selected ? 0.45 : 1)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(title)，\(count) 个")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 筛着某台机器时排在最前面的「本机 ✕」：点一下就不筛了
public struct SourceTokenChip: View {
    let name: String
    let clear: () -> Void

    public init(name: String, clear: @escaping () -> Void) {
        self.name = name
        self.clear = clear
    }

    public var body: some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Image(systemName: "desktopcomputer").font(.app(size: 11, weight: .semibold))
                Text(name).lineLimit(1)
                Image(systemName: "xmark").font(.app(size: 9, weight: .bold))
            }
            .font(.ui(.footnote).weight(.semibold))
            .foregroundStyle(Theme.claude)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Theme.tile, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("仅显示 \(name)，轻点查看全部机器")
    }
}

/// 一排「只看某一个」的胶囊（设备、项目）：最前面「全部设备」，后面每项带个数，直接点选，再点一下选中的就回到全部。
/// 选中的淡品牌色底加细边（和上面状态筛选的实心胶囊区分开）；放不下时横着划
public struct ScopeBar: View {
    public struct Option: Identifiable, Hashable {
        public let id: String
        public let title: String
        public let count: Int

        public init(id: String, title: String, count: Int) {
            self.id = id
            self.title = title
            self.count = count
        }
    }

    let symbol: String
    let allTitle: String
    let options: [Option]
    let bleed: CGFloat
    @Binding var selection: String

    /// selection 是选中项的 id，空 = 全部
    public init(symbol: String, allTitle: String, options: [Option], selection: Binding<String>, bleed: CGFloat = 16) {
        self.symbol = symbol
        self.allTitle = allTitle
        self.options = options
        self.bleed = bleed
        self._selection = selection
    }

    public var body: some View {
        FilterBar(bleed: bleed) {
            ScopeChip(title: allTitle, symbol: symbol, selected: selection.isEmpty) { pick("") }
            ForEach(options) { option in
                ScopeChip(title: option.title, count: option.count, selected: selection == option.id) {
                    pick(selection == option.id ? "" : option.id)
                }
            }
        }
    }

    private func pick(_ id: String) {
        Haptics.tap()
        withAnimation(.snappy) { selection = id }
    }
}

/// ScopeBar 里的一个胶囊：小图标（「全部」那个才有）+ 名字 + 个数
public struct ScopeChip: View {
    let title: String
    var count: Int? = nil
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void

    public init(title: String, count: Int? = nil, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.symbol = symbol
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.app(size: 11, weight: .semibold)) }
                // 名字太长的截短（一个胶囊别占满一排）
                Text(title.count > 24 ? String(title.prefix(23)) + "…" : title).lineLimit(1)
                if let count {
                    Text("\(count)").monospacedDigit().foregroundStyle(selected ? Theme.claude.opacity(0.75) : Color.secondary)
                }
            }
            .font(.ui(.footnote).weight(.semibold))
            .foregroundStyle(selected ? Theme.claude : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            // 圆弧胶囊：默认的连续曲率胶囊加细边，Mac 离屏出图时两头会多出两截竖线
            .background(selected ? Theme.claude.opacity(0.14) : Color.primary.opacity(0.06), in: Capsule(style: .circular))
            .overlay { if selected { Capsule(style: .circular).strokeBorder(Theme.claude.opacity(0.32), lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(count.map { "\(title)，\($0) 个" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 「显示方式」菜单的按钮：上面写着现在怎么分、怎么排；改过默认的用品牌色
/// 「建群」按钮：会话标题行里「显示方式」左边，样子同它（默认态）
public struct NewGroupLabel: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2.badge.plus").font(.app(size: 12, weight: .semibold))
            Text(L("建群")).lineLimit(1)
        }
        .font(.ui(.footnote).weight(.medium))
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .contentShape(Capsule())
        // Mac 侧栏窄：「显示方式」写着「按项目」这类长字时别把「建群」挤成「…」
        .fixedSize()
    }
}

public struct ViewMenuLabel: View {
    let summary: String
    let isDefault: Bool

    public init(summary: String, isDefault: Bool) {
        self.summary = summary
        self.isDefault = isDefault
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease").font(.app(size: 12, weight: .semibold))
            Text(summary).lineLimit(1)
            Image(systemName: "chevron.down").font(.app(size: 9, weight: .bold))
        }
        .font(.ui(.footnote).weight(.medium))
        .foregroundStyle(isDefault ? Color.secondary : Theme.claude)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(isDefault ? Color.primary.opacity(0.06) : Theme.tile, in: Capsule())
        .contentShape(Capsule())
    }
}

/// 标记了的会话标题后的主题色星星：只是标识，点到它同点卡片（取消标记在右滑里，免得点开会话时误触）
struct MarkStar: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.app(size: 12, weight: .semibold))
            .foregroundStyle(Theme.claude)
            .frame(width: 24, height: 22)
            .accessibilityLabel(L("已标记"))
            .padding(.horizontal, -5)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}
