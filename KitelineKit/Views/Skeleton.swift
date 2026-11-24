import SwiftUI

// 骨架屏：页面、弹窗头一回读数据时先画出和真实页面一样的布局（灰色占位），上面一道光从左往右扫过，
// 顶上一句「正在读取…」，不留一片空白让人以为出问题了（11-16 起：所有页面、弹窗都要有，要有动态效果，要和实际布局一致）。
// 数据回来时骨架淡出、内容淡入（调用处在切换的那个值上挂 .animation(.skeletonFade, value:)）。
// iPhone、iPad、Mac（编进 KitelineKit）共用这一份；Windows / Linux 客户端在 desktop/client/Views/Skeleton.cs、
// 小程序在 miniprogram/components/skeleton 照着做。
// 只在「还没有任何数据」时用；已经有上次的数据就先显示旧的，旁边小转圈（见 cache-first 约定）。

/// 列表行最左边是什么
public enum SkeletonLead: Sendable {
    /// 没有
    case none
    /// 会话、项目头像（圆角方块，同 SessionAvatar）
    case avatar
    /// 小图标（文件、改动、记录）
    case icon
    /// 待办的勾选圈
    case check
}

/// 列表行最右边是什么
public enum SkeletonTrail: Sendable {
    case none
    /// 时间（短灰条）
    case time
    /// 状态胶囊 + 时间
    case badge
    /// 箭头
    case chevron
}

/// 骨架的形状：按页面挑，和真实布局对上
public enum SkeletonStyle: Sendable {
    /// 通用列表
    case list(Int = 8, lead: SkeletonLead = .avatar, lines: Int = 2, trail: SkeletonTrail = .time, sections: Bool = false)
    /// 历史会话：状态胶囊 + 设备 / 项目两排胶囊 + 按日期分组的会话行
    case history
    /// 今日动态：一排统计块 + 几张会话摘要卡片
    case today
    /// 用量：额度卡（几台电脑的进度条）+ 统计块 + 每天花费的柱状图
    case usage
    /// 用量，额度卡已经在上面显示着：只要统计块 + 柱状图
    case usageStats
    /// 项目：头像 + 名称 / 位置 / 说明三行 + 右边状态胶囊、箭头
    case projects(Int = 6)
    /// 待办：勾选圈 + 两行
    case todos(Int = 6)
    /// 收藏：一张张卡片（几行正文 + 谁说的 · 会话）
    case favorites(Int = 4)
    /// 文件列表：路径 + 小图标 + 文件名 + 右边大小
    case files(Int = 10)
    /// 改动：图标 + 路径 + 右边 +/- 数
    case changes(Int = 8)
    /// 代码 / 差异：左边行号 + 长短不一、带缩进的代码行
    case code(Int = 18)
    /// 一段文字（更新记录、说明）：小标题 + 几行
    case text(Int = 6)
    /// 设置表单：一组组圆角卡片，每行左标题右控件
    case form(Int = 6)
    /// 对话：我说的靠右一块、agent 的回复靠左几行
    case messages(Int = 4)
    /// 一排统计 / 信息卡片
    case cards(Int = 4)

    /// 旧写法：头像 + 两行
    public static func rows(_ count: Int = 8, avatar: Bool = true) -> SkeletonStyle {
        .list(count, lead: avatar ? .avatar : .none)
    }
}

public extension Animation {
    /// 骨架淡出、内容淡入
    static var skeletonFade: Animation { .easeOut(duration: 0.28) }
}

/// 一整块占位：一句「正在读取…」+ 骨架。直接放在页面 / 弹窗内容的位置
public struct SkeletonPage: KLView {
    let label: LocalizedStringKey?
    let style: SkeletonStyle
    /// 外面已经留了边距（放在带 padding 的滚动页里）就传 false
    let padded: Bool

    public init(_ label: LocalizedStringKey? = "正在读取…", style: SkeletonStyle = .list(), padded: Bool = true) {
        self.label = label
        self.style = style
        self.padded = padded
    }

    public var klBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let label {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label).font(.footnote).foregroundStyle(.secondary)
                }
            }
            SkeletonShape(style: style)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, padded ? 20 : 0).padding(.vertical, padded ? 12 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label ?? "正在读取…"))
        .transition(.opacity)
    }
}

/// 只有骨架、不带那句话（放在已有标题、按钮的弹窗里）
public struct SkeletonShape: KLView {
    let style: SkeletonStyle
    public init(style: SkeletonStyle) { self.style = style }

    /// 长短错开，看着像真的内容
    static let widths: [CGFloat] = [0.42, 0.28, 0.5, 0.35, 0.46, 0.3, 0.4, 0.25, 0.48, 0.33]
    static func w(_ i: Int) -> CGFloat { widths[((i % widths.count) + widths.count) % widths.count] }

    public var klBody: some View {
        content.skeletonShimmer()
    }

    @ViewBuilder private var content: some View {
        switch style {
        case let .list(count, lead, lines, trail, sections):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    if sections, i % 4 == 0 { sectionHeader(i) }
                    SkeletonRow(index: i, lead: lead, lines: lines, trail: trail)
                }
            }
        case .history: history
        case .today: today
        case .usage: usage(limits: true)
        case .usageStats: usage(limits: false)
        case let .projects(count):
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in SkeletonRow(index: i, lead: .avatar, lines: 3, trail: .chevron, badge: i % 3 == 0) }
            }
        case let .todos(count):
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(0)
                ForEach(0..<count, id: \.self) { i in SkeletonRow(index: i, lead: .check, lines: i % 3 == 1 ? 1 : 2, trail: .none) }
            }
        case let .favorites(count):
            VStack(spacing: 12) {
                ForEach(0..<count, id: \.self) { i in favoriteCard(i) }
            }
        case let .files(count):
            VStack(alignment: .leading, spacing: 0) {
                SkeletonBar(width: 180, height: 10, dim: true).padding(.bottom, 10)   // 路径
                ForEach(0..<count, id: \.self) { i in SkeletonRow(index: i + 2, lead: .icon, lines: 1, trail: .time, rowHeight: 34) }
            }
        case let .changes(count):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 16, height: 16)
                        GeometryReader { geo in
                            SkeletonBar(width: geo.size.width * (0.35 + Self.w(i) * 0.6), height: 10)
                                .frame(maxHeight: .infinity)
                        }
                        SkeletonBar(width: 22, height: 9, dim: true)
                        SkeletonBar(width: 22, height: 9, dim: true)
                    }
                    .frame(height: 34)
                }
            }
        case let .code(count): code(count)
        case let .text(count):
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<count, id: \.self) { i in
                        if i % 5 == 0 {
                            SkeletonBar(width: geo.size.width * 0.3, height: 13).padding(.top, i == 0 ? 0 : 8)   // 小标题
                        } else {
                            SkeletonBar(width: geo.size.width * (i % 5 == 4 ? 0.5 : min(0.95, 0.6 + Self.w(i) * 0.7)), height: 10, dim: i % 5 == 4)
                        }
                    }
                }
            }
            .frame(height: CGFloat(count) * 20 + CGFloat(count / 5) * 12)
        case let .form(count): form(count)
        case let .messages(count):
            GeometryReader { geo in
                VStack(spacing: 22) {
                    ForEach(0..<count, id: \.self) { i in message(i, width: geo.size.width) }
                }
            }
            .frame(height: CGFloat(count) * 112)
        case let .cards(count):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(0..<count, id: \.self) { i in statTile(i) }
            }
        }
    }

    // MARK: 各页面

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                chip(56, strong: true); chip(78); chip(78)
                Spacer(minLength: 0)
                chip(104)
            }
            HStack(spacing: 8) { chip(100); chip(60); chip(72) }
            HStack(spacing: 8) { chip(100); chip(84); chip(64); chip(96) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<9, id: \.self) { i in
                    if i == 0 || i == 3 || i == 7 { sectionHeader(i) }
                    SkeletonRow(index: i, lead: .avatar, lines: 2, trail: i == 0 ? .badge : .time)
                }
            }
            .padding(.top, 4)
        }
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(0..<5, id: \.self) { i in statTile(i, compact: true) }
            }
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBar(width: 140 + Self.w(i) * 120, height: 11)
                            SkeletonBar(width: 120, height: 9, dim: true)
                        }
                        Spacer(minLength: 0)
                        SkeletonBar(width: 34, height: 9, dim: true)
                    }
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBar(width: geo.size.width * 0.92, height: 10)
                            SkeletonBar(width: geo.size.width * (0.55 + Self.w(i + 2) * 0.6), height: 10)
                            SkeletonBar(width: geo.size.width * 0.38, height: 10, dim: true)
                        }
                    }
                    .frame(height: 46)
                }
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder private func usage(limits: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if limits { usageLimits }
            usageStats
        }
    }

    private var usageLimits: some View {
        VStack(alignment: .leading, spacing: 16) {
            SkeletonBar(width: 64, height: 11)
            // 额度卡：每台电脑一格，两根进度条
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20)], spacing: 16) {
                ForEach(0..<4, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SkeletonBar(width: 50, height: 11)
                            Spacer(minLength: 0)
                            SkeletonBar(width: 70 + Self.w(i) * 60, height: 11)
                        }
                        HStack(spacing: 16) {
                            ForEach(0..<2, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { SkeletonBar(width: 70, height: 8, dim: true); Spacer(minLength: 0); SkeletonBar(width: 26, height: 10) }
                                    Capsule().fill(.quaternary).frame(height: 5)
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var usageStats: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(0..<4, id: \.self) { i in statTile(i) }
            }
            // 每天花费：标题 + 七根高低不一的柱子
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBar(width: 70, height: 11)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                            .frame(width: 26, height: 30 + Self.w(i * 3 + 1) * 220)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 150, alignment: .bottom)
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { _ in SkeletonBar(width: 30, height: 8, dim: true).frame(maxWidth: .infinity) }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func code(_ count: Int) -> some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<count, id: \.self) { i in
                    let indent = CGFloat([0, 1, 2, 2, 1, 2, 3, 1, 0, 1][i % 10]) * 18
                    HStack(spacing: 14) {
                        SkeletonBar(width: 16, height: 9, dim: true)   // 行号
                        if i % 7 == 6 {
                            Color.clear.frame(height: 9)   // 空行
                        } else {
                            SkeletonBar(width: max(30, (geo.size.width - 40 - indent) * min(0.9, 0.25 + Self.w(i) * 1.1)), height: 9)
                                .padding(.leading, indent)
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(count) * 18)
    }

    private func form(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<max(1, (count + 2) / 3), id: \.self) { section in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBar(width: 60 + Self.w(section) * 60, height: 9, dim: true).padding(.leading, 4)
                    VStack(spacing: 0) {
                        ForEach(0..<max(1, min(3, count - section * 3)), id: \.self) { r in
                            let i = section * 3 + r
                            HStack {
                                SkeletonBar(width: 70 + Self.w(i) * 120, height: 11)
                                Spacer()
                                if i % 3 == 0 {
                                    Capsule().fill(.quaternary).frame(width: 38, height: 22)   // 开关
                                } else {
                                    SkeletonBar(width: 70, height: 10, dim: true)
                                }
                            }
                            .frame(height: 42)
                            .padding(.horizontal, 14)
                        }
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func favoriteCard(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<(i % 2 == 0 ? 3 : 2), id: \.self) { l in
                        SkeletonBar(width: geo.size.width * (l == (i % 2 == 0 ? 2 : 1) ? 0.45 : 0.9 - Self.w(i + l) * 0.2), height: 10)
                    }
                }
            }
            .frame(height: i % 2 == 0 ? 46 : 28)
            HStack(spacing: 6) {
                SkeletonBar(width: 40, height: 8, dim: true)
                SkeletonBar(width: 90, height: 8, dim: true)
                Spacer(minLength: 0)
                SkeletonBar(width: 34, height: 8, dim: true)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private func statTile(_ i: Int, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 22, height: 22)
            SkeletonBar(width: 40 + Self.w(i) * 50, height: 20)
            SkeletonBar(width: 60 + Self.w(i + 1) * 30, height: 10)
            SkeletonBar(width: 50, height: 8, dim: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: compact ? 100 : 110, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private func message(_ i: Int, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 我说的：右边一个圆角块
            HStack {
                Spacer(minLength: width * 0.3)
                RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                    .frame(width: width * (0.3 + Self.w(i) * 0.5), height: 34)
            }
            // agent 的回复：左边几行字
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(width: width * 0.86, height: 10)
                SkeletonBar(width: width * min(0.95, 0.6 + Self.w(i + 2) * 0.5), height: 10)
                SkeletonBar(width: width * 0.4, height: 10, dim: true)
            }
        }
    }

    private func chip(_ width: CGFloat, strong: Bool = false) -> some View {
        Capsule().fill(.quaternary.opacity(strong ? 1 : 0.75)).frame(width: width, height: 26)
    }

    private func sectionHeader(_ i: Int) -> some View {
        SkeletonBar(width: 36 + Self.w(i) * 40, height: 9, dim: true)
            .padding(.top, i == 0 ? 2 : 16).padding(.bottom, 8)
    }
}

/// 一行列表的骨架（和 PastRow / 会话行 / 项目行同样的排法）
struct SkeletonRow: KLView {
    let index: Int
    let lead: SkeletonLead
    let lines: Int
    let trail: SkeletonTrail
    var badge = false
    var rowHeight: CGFloat? = nil

    var klBody: some View {
        HStack(alignment: lines > 2 ? .top : .center, spacing: 10) {
            switch lead {
            case .none: EmptyView()
            case .avatar: RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 30, height: 30)
            case .icon: RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 18, height: 18)
            case .check: Circle().strokeBorder(.quaternary, lineWidth: 2).frame(width: 20, height: 20)
            }
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 7) {
                    SkeletonBar(width: geo.size.width * (0.25 + SkeletonShape.w(index) * 0.8), height: 11)
                    if lines >= 2 { SkeletonBar(width: geo.size.width * min(0.9, 0.4 + SkeletonShape.w(index + 3) * 1.1), height: 9, dim: true) }
                    if lines >= 3 { SkeletonBar(width: geo.size.width * (0.2 + SkeletonShape.w(index + 5) * 0.5), height: 9, dim: true) }
                }
                .frame(maxHeight: .infinity, alignment: lines > 2 ? .top : .center)
            }
            switch trail {
            case .none: EmptyView()
            case .time: SkeletonBar(width: 30, height: 9, dim: true)
            case .badge:
                Capsule().fill(.quaternary).frame(width: 44, height: 18)
                SkeletonBar(width: 30, height: 9, dim: true)
            case .chevron:
                if badge { Capsule().fill(.quaternary).frame(width: 80, height: 18) }
                SkeletonBar(width: 20, height: 9, dim: true)
                SkeletonBar(width: 7, height: 12, radius: 2, dim: true)
            }
        }
        .frame(height: rowHeight ?? (lines >= 3 ? 70 : lines == 2 ? 50 : 38))
    }
}

/// 一根灰条
public struct SkeletonBar: KLView {
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = 3
    var dim = false

    public init(width: CGFloat, height: CGFloat, radius: CGFloat = 3, dim: Bool = false) {
        self.width = width; self.height = height; self.radius = radius; self.dim = dim
    }

    public var klBody: some View {
        RoundedRectangle(cornerRadius: radius).fill(.quaternary.opacity(dim ? 0.7 : 1)).frame(width: max(0, width), height: height)
    }
}

/// 扫光：一道亮带从左往右扫过所有灰块（只在灰块上亮：用灰块本身做遮罩），1.4 秒一趟；
/// 系统开了「减弱动态效果」就改成整块缓慢明暗变化
struct SkeletonShimmer: KLViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var phase: CGFloat = 0

    func klBody(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let band = max(160, geo.size.width * 0.4)
                        LinearGradient(colors: [.clear, Color.primary.opacity(scheme == .dark ? 0.22 : 0.14), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: band, height: geo.size.height)
                            .offset(x: -band + phase * (geo.size.width + band))
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .opacity(reduceMotion ? 1 - phase * 0.4 : 1)
            .onAppear {
                if reduceMotion {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { phase = 1 }
                } else {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
                }
            }
    }
}

public extension View {
    /// 给自己画的灰块加上扫光
    func skeletonShimmer() -> some View { modifier(SkeletonShimmer()) }
    /// 旧名字
    func skeletonPulse() -> some View { modifier(SkeletonShimmer()) }
}
