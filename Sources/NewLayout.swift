import AppKit
import Darwin
import SwiftUI
import KitelineKit

// 新版界面（11-20 起的排法，和经典版并存，窗口右上角的按钮切换，见 KitelineModel.newLayout）：
//   最左一条图标栏（同 VS Code 的活动栏）：会话、项目、待办、收藏，下面历史会话、今日动态、用量报表，最底下虚拟屏幕、手机访问、设置；
//   图标栏右边一栏内容：点哪个图标列哪样，右边的会话不动；「项目」里点一个项目，这一栏换成它的文件、Git、会话（ProjectPane.swift）；
//   窗口底部一条状态栏：来源和手机数、Kiteline 自己占的 CPU 和内存、会话数、今天的用量和各台电脑的订阅额度。
// 性能上的讲究：四栏各是各的列表，只有正显示的那栏在；状态栏的数各自几秒采一次、只重画状态栏自己；右边的会话分屏换栏、换界面都不重建

// MARK: - 左边栏：图标栏 + 一栏内容

struct RailSidebar: KLView {
    @ObservedObject var model: KitelineModel
    /// 新版布局里和导航栏叠在同一栏的块（会话列表、文件侧栏）：图标栏照旧占满整栏高度，这些块叠在旁边那一栏内容的下面
    var below: [String] = []

    var klBody: some View {
        // 搜索框搜的是会话：搜索时不管原来在哪一栏都列会话
        let tab = model.query.isEmpty ? model.sideTab : "sessions"
        // 点项目不进项目页（11-21 反馈：不要带返回的那一页，列表里显示选中、下面的会话跟着换就好）：「项目」这一栏始终是项目列表
        let none = AnyView(EmptyView())
        HStack(spacing: 0) {
            // 图标栏压暗一档、右边一道细线（11-20 反馈：背景色对比太小，所有内容像平铺上去的）：和旁边的内容栏分成两层
            SidebarRail(model: model)
                .background(RailShade().ignoresSafeArea())
            Rectangle().fill(Look.shared.scheme?.borderColor ?? Color.primary.opacity(0.1)).frame(width: 1).ignoresSafeArea()
            // 叠在导航栏下面的块只在「项目」那一栏时出现：导航栏列着全部会话时再叠一个项目的会话列表是重复的（11-21 自测看到）
            let stacked = ProjectBlock.visible(model) && tab == "projects" ? below : []
            let content = Group {
                switch tab {
                case "todos": TarsTodosSidebar(header: none)
                case "favorites": TarsFavoritesSidebar(header: none)
                case "projects": SidebarProjects(model: model, header: none)
                default: SidebarView(model: model, embedded: true)
                }
            }
            if stacked.isEmpty {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 项目列表和下面的会话一样是能收起的一块（11-21 反馈：同样能拖，为什么项目不能收起）
                PanelStack(slots: [L("项目")] + stacked.map { $0 == "sessions" ? L("会话") : L("文件") },
                           key: "nav." + stacked.joined(separator: ",")) {
                    content
                        .environment(\.sidebarInPanel, true)
                        // 「打开项目」在列表「活动中」那一节的标题右边（11-21），标题条上不再重复
                        .modifier(SidebarPanel(title: L("项目"), count: ProjectsModel.shared.groups.count))
                        .frame(maxHeight: .infinity, alignment: .top)
                    ForEach(stacked, id: \.self) { block in ProjectBlock(model: model, block: block).frame(maxHeight: .infinity, alignment: .top) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .listStyle(.sidebar)
        // 列表不画系统侧栏的半透明材质：不在系统分栏里时它透出桌面壁纸的颜色（11-20 反馈：整块发棕、像全选中了），底色交给栏自己
        .klScrollContentBackground(.hidden)
        // 状态栏上的用量：来源连上 / 断开时、每 5 分钟重新汇总一次；额度每次回复都在变，一分钟问一次各台电脑
        .liveReload(every: 300) { SidebarStats.shared.loadUsage() }
        .liveReload(every: 60) { SidebarStats.shared.loadLimits() }
    }
}

/// 最左一条图标栏：上面四个是左边这一栏列什么（选中的左边一道品牌色竖线），中间三个打开右边的整页，最底下几个是设置这类入口
struct SidebarRail: KLView {
    @ObservedObject var model: KitelineModel
    @ObservedObject private var screen = VirtualScreen.shared

    var klBody: some View {
        let todos = KitelineKit.todoCounts
        let waiting = model.sessions.filter { $0.activity == .waiting }.count
        VStack(spacing: 0) {
            tab("sessions", "bubble.left.and.bubble.right", L("会话"), count: waiting > 0 ? waiting : model.sessions.count, alert: waiting > 0)
            tab("projects", "folder", L("项目"), count: Set(model.sessions.map { "\($0.sourceId)\n\($0.cwd)" }).count)
            tab("todos", "checklist", L("待办"), count: todos.suggested > 0 ? todos.suggested : todos.open, alert: todos.suggested > 0)
            tab("favorites", "star", L("收藏"), count: KitelineKit.favoriteCount)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 24, height: 1).padding(.vertical, 6)
            // 历史会话不单独放（11-21 反馈：项目里已经有了，更方便）；今日动态、用量点了弹窗显示
            page(KitelineModel.todayID, "sun.max", L("今日"))
            page(KitelineModel.usageID, "chart.bar", L("用量"))
            Spacer(minLength: 8)
            UpdateButton(size: 24)
            if VirtualScreen.supported {
                RailButton(symbol: "display", help: screen.helpText, tint: screen.isOn) { screen.toggle() }
            }
            RailButton(symbol: "rectangle.3.group", help: L("布局：会话列表、文件侧栏放在哪边")) { model.showLayoutSetup = true }
            RailButton(symbol: "qrcode", help: L("手机访问")) { SettingsWindowController.shared.show(tab: .phone) }
            RailButton(symbol: "gearshape", help: L("设置")) { SettingsWindowController.shared.show(tab: .general) }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(width: 48)
    }

    private func tab(_ id: String, _ symbol: String, _ title: String, count: Int = 0, alert: Bool = false) -> some View {
        // 正搜索时列的是会话，图标栏上还是原来那一栏亮着（清空搜索就回去）
        RailItem(symbol: symbol, title: title, on: model.sideTab == id && !model.worldMode, count: count, alert: alert) {
            model.showSideTab(id)
        }
        .tourAnchor("rail." + id)
    }

    private func page(_ id: String, _ symbol: String, _ title: String) -> some View {
        RailItem(symbol: symbol, title: title, on: model.popupPage == id && !model.worldMode, bar: false) { model.selection = id }
            .tourAnchor(id == KitelineModel.todayID ? "rail.today" : "rail.usage")
    }
}

/// 图标栏上的一项（照 VS Code 的活动栏，11-20 反馈：侧边栏高仿 VS Code）：48×48 只有图标，名字指上去看；
/// 选中的图标亮、左边一道 2 点的竖线；右下角圆形角标（等你处理的是橙色）。颜色跟着 VS Code 配色方案，没选方案用主题色
private struct RailItem: KLView {
    let symbol: String
    let title: String
    let on: Bool
    var count = 0
    var alert = false
    /// 左边那道竖线（只有「这一栏列什么」的四项有；打开右边整页的三项只变亮）
    var bar = true
    let action: () -> Void
    @State private var hovering = false

    var klBody: some View {
        let scheme = Look.shared.scheme
        let active = scheme?.activityFgColor ?? Color.primary
        let inactive = scheme?.activityInactiveColor ?? Color.secondary
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular))
                .foregroundStyle(on ? Color.tarsBrand : (hovering ? active : inactive))
                .frame(width: 48, height: 46)
                // 选中：整块淡淡染主题色、图标主题色（11-21 反馈：不要左边那道单边色条，那是 AI 样式）
                .background {
                    if on || hovering {
                        RoundedRectangle(cornerRadius: SideMetric.radius, style: .continuous)
                            .fill(on ? Color.tarsBrand.opacity(0.16) : Color.primary.opacity(0.06))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(alert ? Color.tarsOrange : (scheme?.badgeColor ?? Color.tarsBrand), in: Capsule())
                            .padding(.trailing, 7).padding(.bottom, 8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverTip(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 图标栏最底下的小按钮（虚拟屏幕、手机访问、设置）
private struct RailButton: KLView {
    let symbol: String
    let help: String
    var tint = false
    let action: () -> Void
    @State private var hovering = false

    var klBody: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                .foregroundStyle(tint ? Color.tarsBrand : (hovering ? (Look.shared.scheme?.activityFgColor ?? .primary) : (Look.shared.scheme?.activityInactiveColor ?? .secondary)))
                .frame(width: 48, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverTip(help)
        .accessibilityLabel(help)
    }
}

// MARK: - 窗口右上角：两套界面之间换

/// 工具栏最右边的按钮：经典版上写「新版界面」，新版上写「经典界面」，点了就换（右边的会话不动）
struct LayoutSwitch: KLView {
    @ObservedObject var model: KitelineModel
    /// 这个按钮在工具栏上占多宽（连两边的空）：右上角那块会话的标签栏照这个数让位
    static let reserve: CGFloat = 112

    var klBody: some View {
        Button {
            model.newLayout.toggle()
            // 切到新版：先弹布局设置（拖着摆会话列表、文件侧栏放哪边），勾过「下次不再询问」的直接切
            if model.newLayout, model.askLayoutOnSwitch { model.showLayoutSetup = true; return }
            KitelineKit.flash(model.newLayout ? L("已切换到新版界面，右上角可随时切回经典界面") : L("已切换回经典界面"))
        } label: {
            Label(model.newLayout ? L("经典界面") : L("新版界面"), systemImage: model.newLayout ? "rectangle.split.2x1" : "sparkles.rectangle.stack")
                .labelStyle(.titleAndIcon)
        }
        .help(model.newLayout ? L("切换回经典界面（顶部入口格子 + 会话列表）") : L("试用新版界面：左侧图标栏、底部状态栏，项目的文件、Git、会话集中在一栏；可随时切回"))
    }
}

// MARK: - 底部状态栏

/// 窗口底部一条状态栏（新版界面）。左边：来源、手机、Kiteline 自己占的 CPU 和内存、会话数；右边：今天的 token 和各台电脑的订阅额度（点了看用量报表）
struct StatusBar: KLView {
    @ObservedObject var model: KitelineModel
    /// 放在窗口顶部（布局里拖上去的）：分隔线画在下面
    var top = false
    @ObservedObject private var stats = SidebarStats.shared
    @ObservedObject private var perf = AppPerf.shared

    var klBody: some View {
        let busy = model.sessions.filter { $0.activity == .busy }.count
        let waiting = model.sessions.filter { $0.activity == .waiting }.count
        HStack(spacing: 0) {
            // 调整布局（11-20 反馈：底部一个图标，点了弹窗调界面布局）
            StatusItem(help: L("布局：会话列表、文件侧栏放在哪边")) { model.showLayoutSetup = true } label: {
                Image(systemName: "rectangle.3.group")
                Text("布局")
            }
            SchemeMenu()
            StatusItem(help: L("来源：点击管理")) { SettingsWindowController.shared.show(tab: .sources) } label: {
                Circle().fill(model.onlineSources > 0 ? Color.green : Color.red).frame(width: 7, height: 7)
                Text("\(model.onlineSources)/\(model.sources.count) 来源")
            }
            StatusItem(help: L("已连接的手机：点击打开手机访问")) { SettingsWindowController.shared.show(tab: .phone) } label: {
                Image(systemName: "iphone")
                Text("\(model.phoneClients)").monospacedDigit()
            }
            divider
            // Kiteline 自己（主程序加它起的监视进程）占了多少：几秒采一次
            StatusItem(help: L("Kiteline 自身的开销（主程序及其启动的监视进程）：CPU 按单个核心计，内存为实际占用")) {} label: {
                Image(systemName: "cpu")
                Text(L("CPU %@", perf.cpuText)).monospacedDigit()
                Image(systemName: "memorychip").padding(.leading, 6)
                Text(L("内存 %@", perf.memoryText)).monospacedDigit()
            }
            divider
            StatusItem(help: L("运行中的会话")) { model.showSideTab("sessions") } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                Text(L("%lld 个会话", count: model.sessions.count))
                // 配色方案的状态栏可能就是强调色（Dark+ 那条蓝的）：数字用状态栏的字色加粗，不然看不见
                let tinted = Look.shared.scheme != nil
                if busy > 0 { Text(L("%lld 个工作中", count: busy)).fontWeight(tinted ? .semibold : nil).foregroundStyle(tinted ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.tarsBrand)) }
                if waiting > 0 { Text(L("%lld 个待确认", count: waiting)).fontWeight(tinted ? .semibold : nil).foregroundStyle(tinted ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.tarsOrange)) }
            }
            Spacer(minLength: 12)
            // 用量：今天的 token 总数、各台电脑各家 agent 的订阅额度；点了看用量报表
            StatusItem(help: L("今日用量与订阅额度：点击查看用量报表")) { model.selection = KitelineModel.usageID } label: {
                Image(systemName: "chart.bar")
                if let usage = stats.usage, usage.tokens > 0 {
                    Text(L("今日 %@", L("%@ token", UsageInfo.compact(Int(usage.tokens))))).monospacedDigit()
                } else {
                    Text("今日用量")
                }
                TarsLimitsStrip(json: stats.limits).padding(.leading, 6)
            }
            .layoutPriority(-1)
            .tourAnchor("status.usage")
            StatusItem(help: L("刷新额度")) { stats.refresh() } label: {
                if stats.limitsBusy { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
            }
        }
        .font(.app(size: SideMetric.Text.caption))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // 侧栏规范：每一段是个框（指着有浅底），框离窗口边 8、框里 6
        .padding(.horizontal, SideMetric.edge)
        .frame(height: SideMetric.bar)
        .frame(maxWidth: .infinity)
        // 选了 VS Code 配色方案：状态栏用方案的底和字（Dark+ / Light+ 是那条蓝的）
        .foregroundStyle(Look.shared.scheme?.statusFgColor ?? Color.secondary)
        .background { if let scheme = Look.shared.scheme { scheme.statusBarColor } else { Rectangle().fill(.bar) } }
        .overlay(alignment: top ? .bottom : .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
        .onAppear { perf.start() }
        .onDisappear { perf.stop() }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 12).padding(.horizontal, 4)
    }
}

/// 状态栏上的一段：能点的鼠标移上去有浅底
private struct StatusItem<Content: View>: KLView {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Content
    @State private var hovering = false

    var klBody: some View {
        Button(action: action) {
            HStack(spacing: 4) { label }
                .padding(.horizontal, SideMetric.gap)
                .frame(height: SideMetric.small - 2)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: SideMetric.radius - 2, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverTip(help)
    }
}

/// 今天的花费和 token、各台电脑的订阅额度（状态栏用）：放在共用的一处，换栏、换界面都不用重拉
final class SidebarStats: ObservableObject {
    static let shared = SidebarStats()
    @Published private(set) var usage: (cost: Double, output: Double, requests: Double, tokens: Double)?
    /// 各台电脑的订阅额度（Limits.collect 的 JSON，交给 KitelineKit 画）
    @Published private(set) var limits: Data?
    @Published private(set) var limitsBusy = false

    func loadUsage() {
        UsageReport.collect(days: 1) { [weak self] in self?.setUsage($0) }
    }

    func loadLimits() {
        Limits.collect { [weak self] payload in self?.limits = try? JSONSerialization.data(withJSONObject: payload) }
    }

    private func setUsage(_ payload: [String: Any]) {
        let t = payload["totals"] as? [String: Any] ?? [:]
        usage = (Digest.number(t["cost"]), Digest.number(t["output"]), Digest.number(t["requests"]),
                 ["input", "output", "cacheRead", "cacheWrite"].reduce(0) { $0 + Digest.number(t[$1]) })
    }

    /// 刷新按钮：额度、今天的 token 数都跳过缓存当场问各台电脑
    func refresh() {
        guard !limitsBusy else { return }
        limitsBusy = true
        let group = DispatchGroup()
        group.enter()
        Limits.collect(fresh: true) { [weak self] payload in
            self?.limits = try? JSONSerialization.data(withJSONObject: payload)
            group.leave()
        }
        group.enter()
        UsageReport.collect(days: 1, fresh: true) { [weak self] payload in
            self?.setUsage(payload)
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.limitsBusy = false
                KitelineKit.flash(TarsLimitsBoard(json: self.limits).refreshedNote)
            }
        }
    }
}

/// Kiteline 自己的开销：主程序加它直接起的子进程（本机的监视进程、连远端的 ssh）用了多少 CPU、占了多少内存。
/// 状态栏显示着的时候 3 秒采一次（两次之间的 CPU 时间差 ÷ 间隔），不显示就停
final class AppPerf: ObservableObject {
    static let shared = AppPerf()
    /// 占一个核心的百分之几（几个核一起忙能过 100）
    @Published private(set) var cpu: Double = 0
    /// 实际占用的内存（字节，同活动监视器的「内存」一栏）
    @Published private(set) var memory: UInt64 = 0
    private var timer: Timer?
    private var users = 0
    private var last: (at: TimeInterval, cpu: [pid_t: Double])?
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(max(1, info.denom)) / 1_000_000_000
    }()

    var cpuText: String { String(format: cpu < 10 ? "%.1f%%" : "%.0f%%", cpu) }
    var memoryText: String {
        let mb = Double(memory) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    func start() {
        users += 1
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
        last = nil
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        var seconds: [pid_t: Double] = [:]
        var footprint: UInt64 = 0
        for pid in [getpid()] + Self.children() {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            seconds[pid] = Double(info.ri_user_time + info.ri_system_time) * Self.timebase
            footprint += info.ri_phys_footprint
        }
        var percent = cpu
        if let last, now > last.at {
            // 只算两次都在的进程（中途新起的下一轮再算），进程退出了不会算出负数
            let used = seconds.reduce(0.0) { sum, item in sum + max(0, item.value - (last.cpu[item.key] ?? item.value)) }
            percent = used / (now - last.at) * 100
        }
        last = (now, seconds)
        if abs(percent - cpu) >= 0.05 { cpu = percent }
        if memory != footprint { memory = footprint }
    }

    /// 直接起的子进程
    private static func children() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }
}

// MARK: - 新版界面的主窗口：几栏几块，用户自己摆（11-20 反馈：所有板块都能拖，上下左右随便组合）

/// 从左到右是 KitelineModel.layoutColumns 的几栏（HSplitView，栏宽能拖），每栏从上到下几块（VSplitView，块高能拖）。
/// 会话列表、文件侧栏只在「项目」里开着项目时出现，没开时它们让出地方（只剩它们的栏整个不画）。状态栏放顶部或底部
struct NewLayoutRoot: KLView {
    @ObservedObject var model: KitelineModel
    @ObservedObject private var collapse = PanelCollapse.shared
    /// 世界 / 数据流里工具栏的「收起会话列表」：新版界面收起导航栏那一栏（11-23 反馈：数据流模式下侧栏收不起来）
    @ObservedObject private var sidebar = SidebarState.shared
    /// 收起的侧栏列的展开按钮画在哪（键 = 那一列的收起键）
    @State private var unfoldSpots: [String: UnfoldSpot] = [:]

    var klBody: some View {
        let open = ProjectBlock.visible(model)
        let navFolded = model.worldMode && sidebar.collapsed
        let columns = model.layoutColumns
            .map { $0.filter { $0 == "nav" || $0 == "tabs" || open } }
            .filter { !$0.isEmpty }
            .filter { !(navFolded && $0.contains("nav") && !$0.contains("tabs")) }
        // 整个铺到窗口顶上（标题栏底下），各栏自己按「离标题栏底边还差多少」往下让（TitlebarInset），标签页区域的分屏自己铺进标题栏。
        // 原来按外层的安全区算，系统的分栏（HSplitView）又自己让了一次，侧栏顶上空出一大条（11-20 截图）
        VStack(spacing: 0) {
            // 窗口右上角的界面切换（LayoutSwitchCorner）挂在占着窗口最上面那一带的视图自己身上：状态栏在顶部时挂状态栏，否则挂最右一栏
            //（挂在外层会被系统的分栏 HSplitView 盖住）
            if model.statusOnTop {
                StatusBar(model: model, top: true).modifier(TitlebarInset())
                    .overlay(alignment: .topTrailing) { LayoutSwitchCorner(model: model, overTabs: false) }
            }
            HSplitView {
                // 收起的侧栏列不占宽度（11-21）：不画它，在它旁边那一栏贴着它的那条边、上下居中浮一个小按钮，点了展开
                let hidden = Set(columns.indices.filter { index in
                    let column = columns[index]
                    return !column.contains("nav") && !column.contains("tabs") && collapse.has("column." + column.joined(separator: ","))
                })
                let visible = columns.indices.filter { !hidden.contains($0) }
                let tabsIndex = columns.firstIndex { $0.contains("tabs") }
                ForEach(visible, id: \.self) { index in
                    let column = columns[index]
                    let position = visible.firstIndex(of: index) ?? 0
                    // 左右收起：只给没有导航栏、没有标签页的侧栏列（文件侧栏、单独的会话列）。侧栏在标签页区域左边就往左收，在右边就往右收；
                    // 收起按钮在这一栏最上面那块的小节标题右边（原来竖在栏边中间，跟滚动条混在一起）
                    let side = !column.contains("nav") && !column.contains("tabs")
                    let edge: HorizontalEdge = (tabsIndex.map { index > $0 } ?? false) ? .leading : .trailing
                    let key = "column." + column.joined(separator: ",")
                    // 右边紧挨着一栏收起的：按钮在本栏右边缘；左边紧挨着收起的、而它左边没有别的栏可挂：按钮在本栏左边缘
                    let rightHidden = index + 1 < columns.count && hidden.contains(index + 1) ? columns[index + 1] : nil
                    let leftHidden = index >= 1 && hidden.contains(index - 1) && !visible.contains(index - 2) ? columns[index - 1] : nil
                    columnView(column, first: position == 0, inset: !model.statusOnTop, last: position == visible.count - 1,
                               fold: side ? ColumnFold(edge: edge) { withAnimation(.klSnappy(duration: 0.18)) { collapse.toggle(key) } } : nil)
                        // 展开按钮要压在两栏的分隔线上（一半在这栏外面），挂在栏自己身上会被分栏裁掉一半：报出位置，画在外层（见下面 overlay）
                        .klOnGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            if let rightHidden { unfoldSpots["column." + rightHidden.joined(separator: ",")] = UnfoldSpot(column: rightHidden, toward: .trailing, frame: frame) }
                            if let leftHidden { unfoldSpots["column." + leftHidden.joined(separator: ",")] = UnfoldSpot(column: leftHidden, toward: .leading, frame: frame) }
                        }
                        .overlay(alignment: .topTrailing) {
                            if !model.statusOnTop, position == visible.count - 1 { LayoutSwitchCorner(model: model, overTabs: column.contains("tabs")) }
                        }
                }
            }
            if !model.statusOnTop { StatusBar(model: model) }
        }
        .id(model.layoutEpoch)
        // 导航栏收起时纸鸢不再飞在它上方；展开时导航栏出现会自己报宽度
        .klOnChange(of: navFolded) { _, folded in if folded { KiteOverlay.shared.sidebarWidth = 0 } }
        // 各栏宽度：默认侧栏取最窄（导航栏 290、文件 / 会话栏 230，11-21 起的默认宽度），拖过就按栏记住（换界面、进出数据流、重启都不变）
        .background(SplitWidths(columns: columns.filter { column in
            !(!column.contains("nav") && !column.contains("tabs") && collapse.has("column." + column.joined(separator: ",")))
        }, epoch: model.layoutEpoch))
        .overlay {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                ForEach(Array(unfoldSpots.keys).sorted(), id: \.self) { key in
                    if let spot = unfoldSpots[key], collapse.has(key) {
                        FloatingUnfold(column: spot.column, toward: spot.toward) {
                            withAnimation(.klSnappy(duration: 0.22)) { collapse.toggle(key) }
                            unfoldSpots[key] = nil
                        }
                        .position(x: (spot.toward == .trailing ? spot.frame.maxX : spot.frame.minX) - origin.x, y: spot.frame.midY - origin.y)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        // 各栏都铺进标题栏那一带（文件侧栏顶上的文件 / Git / 分支 / 历史四个按钮就在那里）：标题栏一直透明，
        // 不透明时标题栏把那一带的点击全收走（拖窗口用）。原来只有对话分屏显示时才透明，右边换成历史会话、用量这类整页时
        // 文件侧栏顶上的按钮全点不动（11-21 自测：AX 查到点在标题栏的文字上）
        .background(KeepTitlebarTransparent())
        // 第一次进新版界面的引导（NewLayoutTour.swift）
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in TourOverlay(anchors: anchors) }
        .toolbar {
            // 新版界面不放「新任务」（11-21）：新会话在项目的会话列表、标签栏「+」里开，打开项目在项目列表里
            ToolbarItem(placement: .navigation) {
                let on = model.worldMode && model.worldPage == "world"
                Button { model.toggleWorld(page: "world") } label: { Label { Text("世界") } icon: { WorldGlobeIcon(active: on) } }
                    .help(on ? L("离开世界模式，回到会话（⇧⌘E）") : L("世界模式：机房、卫星和像素小人，一眼看全所有会话（⇧⌘E）"))
            }
            ToolbarItem(placement: .navigation) {
                let on = model.worldMode && model.worldPage == "flow"
                Button { model.toggleWorld(page: "flow") } label: {
                    Label { Text("数据流") } icon: { Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(on ? Color.tarsBrand : .secondary) }
                }
                .help(on ? L("离开数据流大屏，回到会话（⇧⌘D）") : L("数据流大屏：所有会话读了什么、做了什么、产出去了哪，连成一块屏（⇧⌘D）"))
            }
            ToolbarItem(placement: .navigation) {
                Button { model.toggleAR() } label: {
                    Label { Text("AR") } icon: { Image(systemName: "cube.transparent").foregroundStyle(model.arMode ? Color.tarsBrand : .secondary) }
                }
                .help(L("AR 模式：界面变为透明，所有会话悬浮在桌面前方的空间中；WASD 移动、拖动转向（⇧⌘A）"))
            }
            // 右上角的界面切换不放工具栏（前面垫的弹性空位会接走标签栏的点击），挂在上面的栏上，见 MainWindow.swift 的 LayoutSwitchCorner
        }
    }

    @ViewBuilder private func columnView(_ blocks: [String], first: Bool, inset: Bool, last: Bool, fold: ColumnFold? = nil) -> some View {
        // 导航栏和别的块叠在一栏：图标栏占满整栏高，导航栏下面的块叠在它旁边那一栏里（RailSidebar.below）；导航栏上面的块照常上下分
        let nav = blocks.firstIndex(of: "nav")
        let above = nav.map { Array(blocks[..<$0]) } ?? blocks
        let below = nav.map { Array(blocks[($0 + 1)...]).filter { $0 != "tabs" } } ?? []
        let tabsBelowNav = nav.map { blocks[($0 + 1)...].contains("tabs") } ?? false
        // 夹在中间、没有导航栏的侧栏（文件侧栏、会话列表单独成一栏）：标题栏那一带上面没东西，直接顶上去（11-21 截图：这里不要空着）；
        // 最左一栏有红绿灯和工具栏按钮、最右一栏有界面切换按钮，照旧让开
        let rise = nav == nil && !first && !last
        // 上下收起只在一栏里有两块以上时才有；单独一列（只有会话列表或只有文件侧栏）没有可让的，不给
        let alone = nav == nil && above.count == 1
        let stack = PanelStack(slots: above.map { $0 == "sessions" ? L("会话") : $0 == "files" ? L("文件") : nil } + (nav != nil ? [nil] : []) + (tabsBelowNav ? [nil] : []),
                               key: "col." + blocks.joined(separator: ",")) {
            ForEach(above, id: \.self) { block in
                blockView(block, first: first, below: [], rise: rise).environment(\.columnFold, block == above.first ? fold : nil)
            }
            if nav != nil { blockView("nav", first: first, below: below) }
            if tabsBelowNav { blockView("tabs", first: first, below: []) }
        }
        .environment(\.panelCollapsible, !alone)
        if blocks.contains("tabs") {
            stack.modifier(TitlebarInset(on: inset && blocks != ["tabs"])).frame(minWidth: 420, maxWidth: .infinity).layoutPriority(1)
        } else {
            // 导航栏所在那栏：顶上（标题栏下面）是搜索框，填上原来那条空白
            VStack(spacing: 0) {
                if nav != nil { SidebarSearch(text: $model.query) }
                stack
            }
            .modifier(TitlebarInset(on: inset && !rise))
            // 顶上去的那栏：系统分栏（HSplitView）给每栏留的标题栏安全区也不认
            .ignoresSafeArea(.container, edges: rise ? .top : [])
            // 默认宽度由 SplitWidths 摆（系统分栏 HSplitView 不认 idealWidth，多出来的宽度平摊给各栏，侧栏会长到上限）
            .frame(minWidth: nav != nil ? 290 : 230, idealWidth: nav != nil ? 340 : 300, maxWidth: 640)
            .background(SideColumnShade().ignoresSafeArea())
            // 侧栏里的搜索框、列表边距照侧栏规范（SideMetric）
            .environment(\.sideColumn, true)
        }
    }

    @ViewBuilder private func blockView(_ block: String, first: Bool, below: [String], rise: Bool = false) -> some View {
        switch block {
        case "nav":
            RailSidebar(model: model, below: below)
                .frame(minHeight: 180, maxHeight: .infinity)
                // 纸鸢飞在最左一栏上方：导航栏在最左时报宽度给它，不在最左就不飞
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { KiteOverlay.shared.sidebarWidth = first ? geo.size.width : 0 }
                            .klOnChange(of: geo.size.width) { _, width in KiteOverlay.shared.sidebarWidth = first ? width : 0 }
                            .klOnChange(of: first) { _, now in KiteOverlay.shared.sidebarWidth = now ? geo.size.width : 0 }
                    }
                }
        case "tabs":
            ProjectSplit(model: model).frame(minHeight: 220, maxHeight: .infinity)
        default:
            // 顶上去的那栏：栏里的 VSplitView 也是系统分栏，每块又让一次标题栏安全区，也不认
            ProjectBlock(model: model, block: block).frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: rise ? .top : [])
        }
    }
}

// MARK: - 布局设置（切到新版界面时弹、状态栏和图标栏的「布局」按钮打开）

/// 拖着摆布局：一张窗口示意图，四块（导航栏、会话列表、文件侧栏、标签页区域）都能拖——拖到某一栏上 = 叠在那一栏的下面，
/// 拖到两栏之间的缝 = 单独成一栏；块上的箭头也能挪（← → 换栏，↑ ↓ 栏里上下换）。状态栏拖到顶部或底部。
/// 每块写着名字和里面是什么。确定才生效；勾「下次不再询问」以后切新版不再弹
struct LayoutSetupSheet: KLView {
    @ObservedObject private var model = KitelineModel.shared
    @State private var columns = KitelineModel.shared.layoutColumns
    @State private var statusTop = KitelineModel.shared.statusOnTop
    @State private var dontAsk = !KitelineModel.shared.askLayoutOnSwitch
    /// 拖着经过的地方：「col:2」某一栏、「gap:1」两栏之间、「status:top|bottom」
    @State private var target: String?

    var klBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("拖动下面的板块摆成你习惯的样子：拖到某一栏上会叠放在那一栏里（上下排），拖到两栏之间的缝隙会单独成为一栏（左右排）。状态栏可以拖到顶部或底部。也可以点板块上的箭头移动。")
                .font(.app(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            preview
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                Text("会话列表和文件侧栏在「项目」中选择一个项目后显示；点击会话或文件会在标签页区域打开，标签页还可以左右、上下分屏。窗口里各栏的宽度、上下的高度都可以直接拖动分隔线调整。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.app(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                Toggle("下次不再询问", isOn: $dontAsk).toggleStyle(.checkbox)
                Spacer()
                Button("恢复默认") { withAnimation(.klSnappy) { columns = KitelineModel.defaultColumns; statusTop = false } }.tarsButton()
                Button("确定") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .tarsButton(prominent: true)
            }
        }
        .padding(DialogMetric.pad)   // 弹窗边距规范
        .frame(width: 760)
        .navigationTitle(L("新版界面布局"))
    }

    private func apply() {
        model.layoutColumns = columns
        model.statusOnTop = statusTop
        model.askLayoutOnSwitch = !dontAsk
        model.showLayoutSetup = false
        KitelineKit.flash(L("布局已保存，状态栏或图标栏上的「布局」按钮可随时调整"))
    }

    // MARK: 示意图

    private var preview: some View {
        VStack(spacing: 6) {
            statusSlot(top: true)
            HStack(spacing: 0) {
                gap(0)
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    columnZone(index, column)
                    gap(index + 1)
                }
            }
            .frame(height: 300)
            statusSlot(top: false)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
    }

    /// 两栏之间的缝：拖进来单独成一栏
    private func gap(_ at: Int) -> some View {
        let on = target == "gap:\(at)"
        return Capsule().fill(on ? Color.tarsBrand : Color.clear)
            .frame(width: on ? 4 : 2)
            .padding(.horizontal, 3)
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .klDropDestination(for: String.self) { items, _ in
                guard let block = items.first, KitelineModel.layoutBlocks.contains(block) else { return false }
                withAnimation(.klSnappy) { move(block, newColumnAt: at) }
                return true
            } isTargeted: { hover($0, "gap:\(at)") }
    }

    /// 一栏：拖进来叠在这一栏下面
    private func columnZone(_ index: Int, _ column: [String]) -> some View {
        let key = "col:\(index)"
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(spacing: 6) {
            ForEach(column, id: \.self) { block in chip(block, column: index) }
        }
        .padding(6)
        .frame(maxWidth: column.contains("tabs") ? .infinity : 150, maxHeight: .infinity)
        .frame(minWidth: column.contains("tabs") ? 180 : 130)
        .background(target == key ? Color.tarsBrand.opacity(0.08) : Color.clear, in: shape)
        .overlay { shape.strokeBorder(target == key ? Color.tarsBrand.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1) }
        .klDropDestination(for: String.self) { items, _ in
            guard let block = items.first, KitelineModel.layoutBlocks.contains(block) else { return false }
            withAnimation(.klSnappy) { move(block, intoColumn: index) }
            return true
        } isTargeted: { hover($0, key) }
    }

    /// 状态栏的两个位置：放着状态栏的那个画状态栏，另一个是空槽（拖过来或点一下换过去）
    @ViewBuilder private func statusSlot(top: Bool) -> some View {
        let key = "status:\(top ? "top" : "bottom")"
        let here = statusTop == top
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if here {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.bottomthird.inset.filled").foregroundStyle(Color.tarsBrand)
                    Text("状态栏").font(.app(size: 12, weight: .semibold))
                    Text("CPU · 内存 · 会话数 · 用量").font(.app(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button { withAnimation(.klSnappy) { statusTop.toggle() } } label: {
                        Image(systemName: top ? "arrow.down" : "arrow.up").font(.app(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(top ? L("移到底部") : L("移到顶部"))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.tarsBrand.opacity(0.12), in: shape)
                .overlay { shape.strokeBorder(Color.tarsBrand.opacity(0.4), lineWidth: 1) }
                .klDraggable("status") { dragLabel(L("状态栏")) }
            } else {
                Text(top ? L("拖到这里放在窗口顶部") : L("拖到这里放在窗口底部")).font(.app(size: 10.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).frame(height: 22)
                    .background(target == key ? Color.tarsBrand.opacity(0.1) : Color.clear, in: shape)
                    .overlay { shape.strokeBorder(target == key ? Color.tarsBrand.opacity(0.6) : Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            }
        }
        .klDropDestination(for: String.self) { items, _ in
            guard items.first == "status" else { return false }
            withAnimation(.klSnappy) { statusTop = top }
            return true
        } isTargeted: { hover($0, key) }
    }

    /// 一块：名字、里面是什么、四个挪动的箭头；能拖
    private func chip(_ block: String, column: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let info = Self.info(block)
        let row = columns[column].firstIndex(of: block) ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: info.symbol).font(.app(size: 11)).foregroundStyle(Color.tarsBrand)
                Text(info.title).font(.app(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(info.sub).font(.app(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                arrow("arrow.left", L("移到左边一栏"), enabled: true) { move(block, step: -1) }
                arrow("arrow.right", L("移到右边一栏"), enabled: true) { move(block, step: 1) }
                arrow("arrow.up", L("在这一栏里往上"), enabled: row > 0) { swap(column, row, row - 1) }
                arrow("arrow.down", L("在这一栏里往下"), enabled: row < columns[column].count - 1) { swap(column, row, row + 1) }
                Spacer(minLength: 0)
                Image(systemName: "hand.draw").font(.app(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tarsBrand.opacity(0.12), in: shape)
        .overlay { shape.strokeBorder(Color.tarsBrand.opacity(0.4), lineWidth: 1) }
        .contentShape(shape)
        .klDraggable(block) { dragLabel(info.title) }
    }

    private func arrow(_ symbol: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.klSnappy) { action() } } label: {
            Image(systemName: symbol).font(.app(size: 9.5, weight: .bold))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func dragLabel(_ title: String) -> some View {
        Text(title).font(.app(size: 12, weight: .semibold)).padding(8)
            .background(Color.tarsBrand.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func info(_ block: String) -> (title: String, sub: String, symbol: String) {
        switch block {
        case "nav": return (L("导航栏"), L("图标栏 + 会话 · 项目 · 待办 · 收藏列表"), "sidebar.left")
        case "sessions": return (L("会话列表"), L("项目里正在运行和最近的会话"), "bubble.left.and.bubble.right.fill")
        case "files": return (L("文件侧栏"), L("文件 · Git · 分支 · 提交历史"), "doc.on.doc.fill")
        default: return (L("标签页区域"), L("会话、文件以标签页打开，可左右、上下分屏"), "rectangle.split.2x1.fill")
        }
    }

    private func hover(_ on: Bool, _ key: String) {
        if on { target = key } else if target == key { target = nil }
    }

    // MARK: 挪

    /// 拿出来（原来那栏空了先留着空位，位置不乱），放好以后去掉空栏
    private func removing(_ block: String) -> [[String]] {
        columns.map { $0.filter { $0 != block } }
    }

    private func move(_ block: String, intoColumn index: Int) {
        var next = removing(block)
        guard next.indices.contains(index) else { return }
        next[index].append(block)
        columns = next.filter { !$0.isEmpty }
    }

    private func move(_ block: String, newColumnAt at: Int) {
        var next = removing(block)
        next.insert([block], at: min(max(0, at), next.count))
        columns = next.filter { !$0.isEmpty }
    }

    /// ← →：挪到旁边那栏（叠在下面）；已经在最边上就自己单独成一栏放到最边上
    private func move(_ block: String, step: Int) {
        guard let from = columns.firstIndex(where: { $0.contains(block) }) else { return }
        let to = from + step
        if columns.indices.contains(to) {
            move(block, intoColumn: to)
        } else if columns[from].count > 1 {
            move(block, newColumnAt: step < 0 ? 0 : columns.count)
        }
    }

    private func swap(_ column: Int, _ a: Int, _ b: Int) {
        guard columns.indices.contains(column), columns[column].indices.contains(a), columns[column].indices.contains(b) else { return }
        columns[column].swapAt(a, b)
    }
}

// MARK: - 层次（11-20 反馈：左边栏的背景对比太小，内容像平铺在一张底上）

/// 图标栏的底：深色模式压暗、浅色模式稍灰，和旁边的内容栏分开
struct RailShade: KLView {
    @Environment(\.colorScheme) private var scheme

    var klBody: some View {
        if let theme = Look.shared.scheme { Rectangle().fill(theme.activityBarColor) }
        else { Rectangle().fill(scheme == .dark ? Color.black.opacity(0.14) : Color.black.opacity(0.03)) }
    }
}

/// 侧栏里「收起」的记录（块的上下收起、栏的左右收起），存在设置里
final class PanelCollapse: ObservableObject {
    static let shared = PanelCollapse()
    private static let storeKey = "collapsedPanels"
    @Published private(set) var keys: Set<String>

    private init() {
        var set = Set(AppConfig.defaults.stringArray(forKey: Self.storeKey) ?? [])
        // 老版本按标题各存一个布尔值（会话、文件）
        for title in [L("会话"), L("文件")] where AppConfig.defaults.bool(forKey: "panelCollapsed." + title) { set.insert("panel." + title) }
        // 11-25 反馈：新版界面的文件列默认收起（点标题条展开；展开后记住）。只在第一次执行，之后以用户自己的选择为准
        if !AppConfig.defaults.bool(forKey: "filesColumnCollapsedByDefault1125") {
            set.insert("column.files")             // 右边单独一列的文件（默认摆法）
            set.insert("panel." + L("文件"))       // 叠在左栏里的文件块
            AppConfig.defaults.set(true, forKey: "filesColumnCollapsedByDefault1125")
            AppConfig.defaults.set(Array(set), forKey: Self.storeKey)
        }
        keys = set
    }

    func has(_ key: String) -> Bool { keys.contains(key) }

    func toggle(_ key: String) {
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        AppConfig.defaults.set(Array(keys), forKey: Self.storeKey)
        AppConfig.defaults.set(false, forKey: "panelCollapsed." + key.replacingOccurrences(of: "panel.", with: ""))
    }
}

private struct PanelCollapsibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var panelCollapsible: Bool {
        get { self[PanelCollapsibleKey.self] }
        set { self[PanelCollapsibleKey.self] = newValue }
    }
}

/// 侧栏列（文件侧栏、单独的会话列）左右收起：按钮是这一栏最上面那块小节标题右边的一个小图标（同 VS Code 视图标题上的操作），
/// 侧栏在标签页左边往左收、在右边往右收（图标朝向跟着变）
struct ColumnFold {
    let edge: HorizontalEdge   // 往哪边收
    let action: () -> Void
}

private struct ColumnFoldKey: EnvironmentKey { static let defaultValue: ColumnFold? = nil }
extension EnvironmentValues {
    var columnFold: ColumnFold? {
        get { self[ColumnFoldKey.self] }
        set { self[ColumnFoldKey.self] = newValue }
    }
}

struct ColumnFoldIcon: KLView {
    let fold: ColumnFold
    @State private var hovering = false

    var klBody: some View {
        Button(action: fold.action) {
            Image(systemName: fold.edge == .trailing ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 22, height: 20)
                .background(Color.primary.opacity(hovering ? 0.10 : 0), in: RoundedRectangle(cornerRadius: SideMetric.radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("收起侧栏"))
    }
}

/// 收起的侧栏列留下的展开按钮（11-21）：浮在旁边那一栏贴边、上下居中，不占宽度。平时是这一栏的图标（文件 / 会话），
/// 指上去换成朝展开方向的双箭头、略放大，点了展开
struct UnfoldSpot: Equatable {
    let column: [String]
    let toward: HorizontalEdge
    let frame: CGRect
}

struct FloatingUnfold: KLView {
    let column: [String]
    /// 收起的那栏在按钮的哪一边（展开朝哪边）
    let toward: HorizontalEdge
    let action: () -> Void
    @State private var hovering = false
    static let size: CGFloat = 28

    var klBody: some View {
        // 圆形，圆心压在两栏之间的分隔线上（11-21 反馈：放在边线中间、显示文件夹标识、边线过圆心）
        let symbol = column.contains("files") ? "folder" : "bubble.left.and.bubble.right"
        let arrows = toward == .trailing ? "chevron.right.2" : "chevron.left.2"
        Button(action: action) {
            ZStack {
                Image(systemName: symbol).opacity(hovering ? 0 : 1).scaleEffect(hovering ? 0.5 : 1)
                Image(systemName: arrows).opacity(hovering ? 1 : 0).scaleEffect(hovering ? 1 : 0.5)
                    .offset(x: hovering ? 0 : (toward == .trailing ? -4 : 4))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(hovering ? Color.white : Color.secondary)
            .frame(width: Self.size, height: Self.size)
            .background(hovering ? AnyShapeStyle(Color.tarsBrand) : AnyShapeStyle(.regularMaterial), in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(hovering ? 0 : 0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 5, y: 1)
            .scaleEffect(hovering ? 1.12 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.klSnappy(duration: 0.18)) { hovering = inside } }
        .help(column.contains("files") ? L("展开文件侧栏") : L("展开侧栏"))
    }
}

/// 收起后留下的窄边：点一下展开
struct ColumnEdgeStrip: KLView {
    let edge: HorizontalEdge
    let action: () -> Void
    @State private var hovering = false

    var klBody: some View {
        Button(action: action) {
            // 图标在顶上，和别的栏的小节标题一排（原来在中间，像一截滚动条）
            ZStack(alignment: .top) {
                Rectangle().fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
                Image(systemName: edge == .trailing ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(hovering ? Color.primary : Color.secondary)
                    .padding(.top, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 24)
        .frame(maxHeight: .infinity)
        .background(SideColumnShade().ignoresSafeArea())
        .onHover { hovering = $0 }
        .help(L("展开侧栏"))
    }
}

/// 一栏里上下叠的几块（项目列表 + 会话 + 文件）：平时各占一样高（两块就是上下各一半），分隔条能拖，拖到哪记到哪、
/// 切项目、重开都不变（11-21 反馈：不该上面项目那么高、下面会话那么少，拖到一半切项目又变回去）；
/// 只要有一块收起了就改成竖排：收起的那块只剩 22 点的标题条贴在栏底，别的块占满整栏高度
/// （系统的 VSplitView 会一直保留收起前分到的高度，下面白白空一块）
struct PanelStack<Content: View>: KLView {
    /// 每一块的标题（会收起的那几块，和 SidebarPanel 的 title 对应）；不会收起的块写 nil。顺序和 content 里的块一一对应
    let slots: [String?]
    /// 记高度比例用的键
    let key: String
    @ViewBuilder var content: () -> Content
    @ObservedObject private var collapse = PanelCollapse.shared
    @State private var weights: [Double] = []

    private var count: Int { slots.count }
    private var storeKey: String { "panelWeights." + key }

    private func current() -> [Double] {
        if weights.count == count { return weights }
        if let saved = AppConfig.defaults.array(forKey: storeKey) as? [Double], saved.count == count, saved.allSatisfy({ $0 > 0 }) { return saved }
        return Array(repeating: 1.0 / Double(max(count, 1)), count: count)
    }

    var klBody: some View {
        // 收起的块：固定一条标题条高，别的块分剩下的（收起的是最底下那块时，标题条就贴在栏底）
        let folded = Set(slots.indices.filter { index in slots[index].map { collapse.has("panel." + $0) } ?? false })
        if count < 2 {
            VStack(spacing: 0) { content() }
        } else if !folded.isEmpty {
            WeightedColumn(weights: current(), fixed: folded) { content() }
        } else {
            let w = current()
            WeightedColumn(weights: w, fixed: []) { content() }
                .coordinateSpace(name: "panelstack")
                .overlay {
                    GeometryReader { geo in
                        ForEach(0..<(count - 1), id: \.self) { i in
                            let boundary = w[0...i].reduce(0, +) * geo.size.height
                            Color.clear.frame(width: geo.size.width, height: 7).contentShape(Rectangle())
                                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("panelstack"))
                                    .onChanged { value in
                                        guard geo.size.height > 0 else { return }
                                        var next = current()
                                        let before = i == 0 ? 0 : next[0..<i].reduce(0, +)
                                        let pair = next[i] + next[i + 1]
                                        let minShare = min(110 / geo.size.height, pair / 2)
                                        let wanted = value.location.y / geo.size.height - before
                                        next[i] = min(max(wanted, minShare), pair - minShare)
                                        next[i + 1] = pair - next[i]
                                        weights = next
                                    }
                                    .onEnded { _ in AppConfig.defaults.set(current(), forKey: storeKey) })
                                .offset(y: boundary - 3.5)
                        }
                    }
                }
        }
    }
}

#if KL_MODERN
private typealias WeightedColumn = WeightedColumnImpl
#else
/// 上下叠的几块按比例分高度（比例之和为 1）
private struct WeightedColumn<Content: View>: KLView {
    var weights: [Double]
    var fixed: Set<Int>
    let content: () -> Content

    init(weights: [Double], fixed: Set<Int>, @ViewBuilder content: @escaping () -> Content) {
        self.weights = weights; self.fixed = fixed; self.content = content
    }

    var klBody: some View {
        if #available(macOS 13, *) {
            WeightedColumnImpl(weights: weights, fixed: fixed) { content() }
        } else {
            // macOS 12：没有 Layout，按比例分高度做不到；收起的块按内容高，其余平分
            KLChildren(content) { children in
                VStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                        if fixed.contains(index) { child.fixedSize(horizontal: false, vertical: true) } else { child.frame(maxHeight: .infinity) }
                    }
                }
            }
        }
    }
}
#endif

@available(macOS 13, *)
private struct WeightedColumnImpl: Layout {
    var weights: [Double]
    /// 收起的块（只剩标题条的高度）
    var fixed: Set<Int>

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 400)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let open = subviews.indices.filter { !fixed.contains($0) }
        let room = max(bounds.height - CGFloat(fixed.count) * SideMetric.header, 0)
        let total = open.map { $0 < weights.count ? weights[$0] : 1 }.reduce(0, +)
        var y = bounds.minY
        for (index, view) in subviews.enumerated() {
            let height: CGFloat
            if fixed.contains(index) {
                height = SideMetric.header
            } else {
                let share = index < weights.count ? weights[index] : 1
                height = fixed.isEmpty ? bounds.height * share : room * (total > 0 ? share / total : 1 / Double(max(open.count, 1)))
            }
            view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }
}

/// 侧栏里的一块（会话列表、文件侧栏）：照 VS Code 侧栏的视图小节——平铺在侧栏底上，顶上一条 22 点的小节标题
/// （折叠箭头 + 加粗小字），上面一道分隔线；点标题收起 / 展开（记住）。没选配色方案时颜色跟系统
private struct SidebarInPanelKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 放在 SidebarPanel 里（标题条已经写了名字）：里面别再重复标题
    var sidebarInPanel: Bool {
        get { self[SidebarInPanelKey.self] }
        set { self[SidebarInPanelKey.self] = newValue }
    }
}

struct SidebarPanel: KLViewModifier {
    var title: String = ""
    var count: Int = 0
    /// 标题条右边的小按钮（如「打开项目」）
    var accessory: AnyView? = nil
    @ObservedObject private var collapse = PanelCollapse.shared
    /// 一栏里只有这一块时不给上下收起（11-21）：没有别的块可让
    @Environment(\.panelCollapsible) private var collapsible
    /// 这块在侧栏列最上面：标题右边放左右收起这一栏的图标
    @Environment(\.columnFold) private var fold

    init(title: String = "", count: Int = 0, accessory: AnyView? = nil) {
        self.title = title
        self.count = count
        self.accessory = accessory
    }

    private var collapsed: Bool { collapsible && collapse.has("panel." + title) }

    func klBody(content: Content) -> some View {
        let scheme = Look.shared.scheme
        VStack(spacing: 0) {
            if !title.isEmpty {
                Button { withAnimation(.klSnappy(duration: 0.18)) { collapse.toggle("panel." + title) } } label: {
                    // 箭头放在对齐线左边的空里，标题字和下面的内容一样从离栏边 16 点起（同 VS Code：箭头在缩进里）
                    HStack(spacing: 0) {
                        if collapsible {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(collapsed ? 0 : 90))
                                .frame(width: SideMetric.inset - 4)
                        } else {
                            Color.clear.frame(width: SideMetric.inset - 4, height: 1)
                        }
                        Text(title).font(.app(size: SideMetric.Text.caption, weight: .bold))
                        if count > 0 {
                            Text("\(count)").font(.app(size: SideMetric.Text.caption).monospacedDigit()).foregroundStyle(.tertiary).padding(.leading, 5)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(scheme?.fgColor ?? Color.primary)
                    .padding(.leading, 4)
                    .padding(.trailing, SideMetric.edge)
                    .frame(height: SideMetric.header)
                    .background(scheme?.sectionHeaderColor ?? Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!collapsible)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 2) {
                        if let accessory { accessory.foregroundStyle(scheme?.fgColor ?? Color.primary) }
                        if let fold { ColumnFoldIcon(fold: fold) }
                    }
                    .padding(.trailing, SideMetric.edge - 4)
                }
                .overlay(alignment: .top) { Rectangle().fill(scheme?.borderColor ?? Color.primary.opacity(0.1)).frame(height: 1) }
            }
            if !collapsed || title.isEmpty {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: collapsed && !title.isEmpty ? SideMetric.header : .infinity, alignment: .top)
    }
}

/// 面板里的小节标题（「正在运行」「最近的会话」）：小号、加粗、次要色，标题和内容拉开层级
struct PanelSectionTitle: KLView {
    let title: String
    var count: Int = 0

    var klBody: some View {
        HStack(spacing: 5) {
            Text(title).font(.app(size: SideMetric.Text.caption, weight: .semibold)).foregroundStyle(.secondary)
            if count > 0 { Text("\(count)").font(.app(size: SideMetric.Text.caption).monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .textCase(nil)
    }
}

/// 新版界面侧边几栏的底：不透明的中性灰，比中间对话区亮 / 暗一档（不跟壁纸、不带主题色），和对话区分得开又不扎眼
struct SideColumnShade: KLView {
    @Environment(\.colorScheme) private var scheme

    var klBody: some View {
        if let theme = Look.shared.scheme { Rectangle().fill(theme.sideBarColor) }
        else { Rectangle().fill(scheme == .dark ? Color(white: 0.135) : Color(white: 0.955)) }
    }
}

/// 导航栏顶上的搜索框（新版界面不在系统分栏里，系统的侧栏搜索框没了）：搜会话，同经典版
struct SidebarSearch: KLView {
    @Binding var text: String
    @FocusState private var focused: Bool

    var klBody: some View {
        HStack(spacing: SideMetric.gap) {
            Image(systemName: "magnifyingglass").font(.app(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField(L("搜索会话"), text: $text).textFieldStyle(.plain).font(.app(size: SideMetric.Text.body)).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help(L("清除"))
            }
        }
        // 侧栏规范（SideMetric）：框离栏边 8、框里 8、高 28、圆角 6；下面空 8 再接列表
        .padding(.horizontal, SideMetric.pad)
        .frame(height: SideMetric.control)
        .background(Color.primary.opacity(focused ? 0.08 : 0.055), in: RoundedRectangle(cornerRadius: SideMetric.radius, style: .continuous))
        .padding(.horizontal, SideMetric.edge)
        .padding(.top, 2)
        .padding(.bottom, SideMetric.edge)
    }
}

/// 状态栏上的「配色」：点开选 VS Code 配色方案（同 VS Code 的「首选项：颜色主题」），选了马上生效
struct SchemeMenu: KLView {
    var klBody: some View {
        Menu {
            Picker("配色方案", selection: Binding(get: { Look.shared.schemeID }, set: { Look.shared.schemeID = $0 })) {
                Text("跟随系统").tag("")
                Section("深色") { ForEach(LookScheme.all.filter(\.dark)) { Text(verbatim: $0.name).tag($0.id) } }
                Section("浅色") { ForEach(LookScheme.all.filter { !$0.dark }) { Text(verbatim: $0.name).tag($0.id) } }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paintpalette")
                Text(Look.shared.scheme?.name ?? L("配色"))
            }
            .padding(.horizontal, SideMetric.gap)
            .frame(height: SideMetric.small - 2)
            .contentShape(Rectangle())
        }
        .klMenuButtonStyle()
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("配色方案（仿 VS Code 的颜色主题）"))
    }
}

/// 让出标题栏：量自己在窗口里的顶边离标题栏 + 工具栏的底边还差多少，往下让这么多（已经在下面了就不让）。
/// 量的是加了内边距之前的外框（背景里量），不会自己撑自己
struct TitlebarInset: KLViewModifier {
    var on = true
    @State private var minY: CGFloat = 0
    /// 标题栏 + 工具栏多高：主窗口建好后量一次写进来（MainWindowController.init）。
    /// 别在 body 里碰 MainWindowController.shared——建窗口时就要算 body，那时 shared 还在初始化，递归初始化直接崩（11-21 keyuanchuangmei-56 用测试实例查出）
    static var band: CGFloat = 52

    func klBody(content: Content) -> some View {
        let band = Self.band
        content
            // minY 不取负数：从经典版换过来时这一栏是从窗口上面滑进来的，量到的是动画途中的负值（-85…-178），
            // 停下后不一定再报一次，留空就变成 52 + 178，左边栏顶上空一大块（11-21 截图，日志查实）
            .padding(.top, on ? max(0, band - max(0, minY)) : 0)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { minY = geo.frame(in: .global).minY }
                        .klOnChange(of: geo.frame(in: .global).minY) { _, value in minY = value }
                }
            }
    }
}


/// 整页（历史会话、今日动态、用量、项目总览）的标题、副标题、范围选择和刷新这类按钮。
/// 经典版放进窗口工具栏；新版界面的窗口工具栏横跨所有栏，标题会叠在左边几栏上、按钮会挤进右上角的界面切换按钮里
///（11-21 自测截图：「历史会话 · 204 个会话」压在文件栏上、刷新按钮把「经典界面」挤成「经典」），改成页面自己顶上一行
struct PageChrome<Center: View, Actions: View>: KLViewModifier {
    let title: String
    let subtitle: String
    let center: Center
    let actions: Actions
    @ObservedObject private var model = KitelineModel.shared

    init(title: String, subtitle: String, @ViewBuilder center: () -> Center = { EmptyView() }, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.center = center()
        self.actions = actions()
    }

    func klBody(content: Content) -> some View {
        if model.newLayout {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // 标题写在弹窗的标题栏上（新版界面里这几页都是弹窗），这一行只放副标题和按钮
                    Text(subtitle).font(.app(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    center
                    HStack(spacing: KiteMetric.gap) { actions }
                        .labelStyle(.iconOnly)
                        .kiteButton()
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                Divider()
                content
            }
            .navigationTitle(title)   // 弹窗的标题栏
        } else {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItem(placement: .principal) { center }
                    ToolbarItemGroup(placement: .primaryAction) { actions }
                }
        }
    }
}


/// 新版界面开着时窗口标题栏一直透明（见 NewLayoutRoot）：对话分屏离开时会把它还原成不透明，这里盯着改回来
struct KeepTitlebarTransparent: NSViewRepresentable {
    func makeNSView(context: Context) -> Holder { Holder() }
    func updateNSView(_ view: Holder, context: Context) {}

    final class Holder: NSView {
        private var watch: NSKeyValueObservation?

        /// 进新版界面前窗口标题原来的样子：换回经典版时照原样还原。别一律设成显示——经典版的标签栏铺在标题栏那一带，
        /// 显示出来的标题文字整条横在上面，右上角「新版界面」、标签的 × 都被它接走点不动（11-21 自测）
        private static var savedVisibility: NSWindow.TitleVisibility?

        /// 窗口上挂着几个（换布局、换模式时整块按 layoutEpoch 重建：新的先挂上、旧的后拆）：最后一个拆掉才还原标题，
        /// 不然旧的拆掉时把新的刚藏起来的标题又放出来，标题栏上横着一条鼠标指过的标签名（11-22 截图）
        private static var live = 0
        private var counted = false

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, counted {
                counted = false
                Self.live -= 1
                if Self.live == 0, let window, let saved = Self.savedVisibility { window.titleVisibility = saved; Self.savedVisibility = nil }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watch = nil
            guard let window else { return }
            if !counted { counted = true; Self.live += 1 }
            window.titlebarAppearsTransparent = true
            // 窗口标题（当前会话名）不画：标题栏透明后它压在左边几栏顶上（11-21 截图：用量页时「QQ_….png 会话内容空白」叠在文件栏上）
            if Self.savedVisibility == nil { Self.savedVisibility = window.titleVisibility }
            window.titleVisibility = .hidden
            watch = window.observe(\.titlebarAppearsTransparent, options: [.new]) { [weak self] window, _ in
                guard !window.titlebarAppearsTransparent else { return }
                DispatchQueue.main.async { if self?.window === window { window.titlebarAppearsTransparent = true } }
            }
        }
    }
}


/// 新版界面左右几栏的宽度：系统分栏（HSplitView）不认 idealWidth，多出来的宽度平摊给各栏，侧栏会被分得很宽。
/// 找到这个分栏（NSSplitView），把侧栏摆成记住的宽度（没记过用默认），标签页那栏拿剩下的；用户拖分隔线时把各侧栏宽度记下来。
/// 宽度按「哪一栏」记（导航栏那栏一个键，文件 / 会话栏按里面的块），不按整套摆法记：原来用系统 autosaveName 按整套栏记，
/// 进数据流 / 世界、开关项目时文件栏、会话栏出现消失，整套摆法变了，导航栏就换成另一份宽度，每次切换都在变（11-23 截图）
struct SplitWidths: NSViewRepresentable {
    let columns: [[String]]
    let epoch: Int

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.columns = columns
        view.schedule()
    }

    private static let storeKey = "newLayoutColumnWidths"
    static func widthKey(_ column: [String]) -> String { column.contains("nav") ? "nav" : column.joined(separator: ",") }
    static var saved: [String: Double] {
        get { AppConfig.defaults.dictionary(forKey: storeKey) as? [String: Double] ?? [:] }
        set { AppConfig.defaults.set(newValue, forKey: storeKey) }
    }

    final class Probe: NSView {
        var columns: [[String]] = []
        private weak var split: NSSplitView?
        private var appliedName: String?
        private var applying = false
        /// 上次摆的时候分栏多宽：变了就是窗口带动的
        private var lastWidth: CGFloat = 0
        private var observer: NSObjectProtocol?

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }

        func schedule() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.apply() }
        }

        private func findSplit(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == columns.count { return split }
            for child in view.subviews { if let found = findSplit(child) { return found } }
            return nil
        }

        private func apply() {
            // 只剩一栏（数据流里收起了导航栏）：下次栏回来要重新摆
            guard columns.count > 1 else { appliedName = nil; return }
            guard let root = window?.contentView, let found = findSplit(root) else { return }
            // 栏的摆法 + 分栏里实际是哪几个子视图：同样的摆法、栏被拆了又建（收起再展开导航栏）也要重新摆，不然系统把它按上限摆宽
            let name = signature(found)
            if found !== split {
                split = found
                appliedName = nil
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: found, queue: .main) { [weak self] _ in
                    self?.resized()
                }
            }
            guard appliedName != name else { return }
            appliedName = name
            migrate(columns.map { $0.joined(separator: ",") }.joined(separator: "|"))
            place(found)
        }

        /// 侧栏按记住的宽度（没记过用默认：导航栏 290、文件 / 会话栏 230）从左往右摆，标签页那栏拿剩下的
        private func place(_ found: NSSplitView) {
            // 窗口变大变小时侧栏宽度不变（11-23）：靠 resized() 每次分栏总宽一变就重摆。
            // 别对 NSSplitView 设 holdingPriority：SwiftUI 的 HSplitView 不许设，抛异常闪退（11-23 测试实例）
            lastWidth = found.bounds.width
            let store = SplitWidths.saved
            let widths: [CGFloat] = columns.map { column in
                if column.contains("tabs") { return 0 }
                let fallback: CGFloat = column.contains("nav") ? 290 : 230
                return min(640, max(column.contains("nav") ? 290 : 230, store[SplitWidths.widthKey(column)].map { CGFloat($0) } ?? fallback))
            }
            let gaps = CGFloat(columns.count - 1) * found.dividerThickness
            let tabs = max(420, found.bounds.width - widths.reduce(0, +) - gaps)
            applying = true
            var x: CGFloat = 0
            for index in 0..<(columns.count - 1) {
                x += columns[index].contains("tabs") ? tabs : widths[index]
                found.setPosition(x, ofDividerAt: index)
                x += found.dividerThickness
            }
            applying = false
        }

        private func signature(_ split: NSSplitView) -> String {
            columns.map { $0.joined(separator: ",") }.joined(separator: "|")
                + "#" + split.arrangedSubviews.map { "\(ObjectIdentifier($0).hashValue)" }.joined(separator: ",")
        }

        /// 分栏里各栏宽度变了：整个分栏变宽变窄（拖窗口边、全屏、缩放）= 窗口带动的，侧栏摆回记住的宽度；
        /// 分栏总宽没变 = 用户拖了分隔线，记下来
        private func resized() {
            guard !applying, let split, split.arrangedSubviews.count == columns.count, appliedName == signature(split) else { return }
            if abs(split.bounds.width - lastWidth) > 0.5 { place(split) } else { remember() }
        }

        /// 用户拖分隔线：各侧栏现在的宽度记下来。只在这套栏已经按记住的宽度摆好之后记：换模式、栏出现消失时系统先乱摆一下，
        /// 那时这套栏还没摆过（签名对不上），不记
        private func remember() {
            guard let split else { return }
            var store = SplitWidths.saved
            for (column, view) in zip(columns, split.arrangedSubviews) where !column.contains("tabs") && !view.isHidden {
                store[SplitWidths.widthKey(column)] = Double(view.frame.width)
            }
            SplitWidths.saved = store
        }

        /// 旧版本按整套摆法让系统记的宽度（autosaveName）：自己还没记过的栏从那里接过来，升级后不丢用户拖好的宽度
        private func migrate(_ name: String) {
            guard let frames = UserDefaults.standard.array(forKey: "NSSplitView Subview Frames KitelineNewLayout." + name) as? [String],
                  frames.count == columns.count else { return }
            var store = SplitWidths.saved
            var changed = false
            for (column, frame) in zip(columns, frames) where !column.contains("tabs") && store[SplitWidths.widthKey(column)] == nil {
                let parts = frame.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 3, let width = Double(parts[2]), width > 0 { store[SplitWidths.widthKey(column)] = width; changed = true }
            }
            if changed { SplitWidths.saved = store }
        }
    }
}
