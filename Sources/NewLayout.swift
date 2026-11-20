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

struct RailSidebar: View {
    @ObservedObject var model: KitelineModel
    /// 新版布局里和导航栏叠在同一栏的块（会话列表、文件侧栏）：图标栏照旧占满整栏高度，这些块叠在旁边那一栏内容的下面
    var below: [String] = []

    var body: some View {
        // 搜索框搜的是会话：搜索时不管原来在哪一栏都列会话
        let tab = model.query.isEmpty ? model.sideTab : "sessions"
        let project = tab == "projects" && !model.projectListShown ? model.projectPane : nil
        let none = AnyView(EmptyView())
        HStack(spacing: 0) {
            // 图标栏压暗一档、右边一道细线（11-20 反馈：背景色对比太小，所有内容像平铺上去的）：和旁边的内容栏分成两层
            SidebarRail(model: model)
                .background(RailShade().ignoresSafeArea())
            Rectangle().fill(Look.shared.scheme?.borderColor ?? Color.primary.opacity(0.1)).frame(width: 1).ignoresSafeArea()
            // 叠在导航栏下面的块只在「项目」那一栏时出现：导航栏列着全部会话时再叠一个项目的会话列表是重复的（11-21 自测看到）
            let stacked = ProjectBlock.visible(model) && tab == "projects" ? below : []
            let content = Group {
                if let project {
                    ProjectPaneView(model: model, id: project, inline: true).id(project)
                } else {
                    switch tab {
                    case "todos": TarsTodosSidebar(header: none)
                    case "favorites": TarsFavoritesSidebar(header: none)
                    case "projects": SidebarProjects(model: model, header: none)
                    default: SidebarView(model: model, embedded: true)
                    }
                }
            }
            if stacked.isEmpty {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if project != nil, !stacked.isEmpty {
                // 开着项目：导航那一块只有项目名和用量，不用占多高，下面的块拿走剩下的
                VStack(spacing: 0) {
                    content.fixedSize(horizontal: false, vertical: true)
                    VSplitView {
                        ForEach(stacked, id: \.self) { block in ProjectBlock(model: model, block: block).frame(minHeight: 110, maxHeight: .infinity) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    content.frame(minHeight: 120, maxHeight: .infinity)
                    ForEach(stacked, id: \.self) { block in ProjectBlock(model: model, block: block).frame(minHeight: 110, maxHeight: .infinity) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .listStyle(.sidebar)
        // 列表不画系统侧栏的半透明材质：不在系统分栏里时它透出桌面壁纸的颜色（11-20 反馈：整块发棕、像全选中了），底色交给栏自己
        .scrollContentBackground(.hidden)
        // 状态栏上的用量：来源连上 / 断开时、每 5 分钟重新汇总一次；额度每次回复都在变，一分钟问一次各台电脑
        .liveReload(every: 300) { SidebarStats.shared.loadUsage() }
        .liveReload(every: 60) { SidebarStats.shared.loadLimits() }
    }
}

/// 最左一条图标栏：上面四个是左边这一栏列什么（选中的左边一道品牌色竖线），中间三个打开右边的整页，最底下几个是设置这类入口
struct SidebarRail: View {
    @ObservedObject var model: KitelineModel
    @ObservedObject private var screen = VirtualScreen.shared

    var body: some View {
        let todos = KitelineKit.todoCounts
        let waiting = model.sessions.filter { $0.activity == .waiting }.count
        VStack(spacing: 0) {
            tab("sessions", "bubble.left.and.bubble.right", L("会话"), count: waiting > 0 ? waiting : model.sessions.count, alert: waiting > 0)
            tab("projects", "folder", L("项目"), count: Set(model.sessions.map { "\($0.sourceId)\n\($0.cwd)" }).count)
            tab("todos", "checklist", L("待办"), count: todos.suggested > 0 ? todos.suggested : todos.open, alert: todos.suggested > 0)
            tab("favorites", "star", L("收藏"), count: KitelineKit.favoriteCount)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 24, height: 1).padding(.vertical, 6)
            page(KitelineModel.historyID, "clock.arrow.circlepath", L("历史"))
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
            // 已经在「项目」里、又点开着一个项目：回到项目列表
            // 已经在「项目」里：在项目列表和当前项目之间换（当前项目、中间的标签不变）
            if id == "projects", model.sideTab == id, model.projectPane != nil { model.projectListShown.toggle() }
            model.showSideTab(id)
        }
    }

    private func page(_ id: String, _ symbol: String, _ title: String) -> some View {
        RailItem(symbol: symbol, title: title, on: model.selection == id && !model.worldMode, bar: false) { model.selection = id }
    }
}

/// 图标栏上的一项（照 VS Code 的活动栏，11-20 反馈：侧边栏高仿 VS Code）：48×48 只有图标，名字指上去看；
/// 选中的图标亮、左边一道 2 点的竖线；右下角圆形角标（等你处理的是橙色）。颜色跟着 VS Code 配色方案，没选方案用主题色
private struct RailItem: View {
    let symbol: String
    let title: String
    let on: Bool
    var count = 0
    var alert = false
    /// 左边那道竖线（只有「这一栏列什么」的四项有；打开右边整页的三项只变亮）
    var bar = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let scheme = Look.shared.scheme
        let active = scheme?.activityFgColor ?? Color.primary
        let inactive = scheme?.activityInactiveColor ?? Color.secondary
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular))
                .foregroundStyle(on || hovering ? active : inactive)
                .frame(width: 48, height: 46)
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
                .overlay(alignment: .leading) {
                    if on, bar { Rectangle().fill(scheme?.activityBorderColor ?? Color.tarsBrand).frame(width: 2) }
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
private struct RailButton: View {
    let symbol: String
    let help: String
    var tint = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
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
struct LayoutSwitch: View {
    @ObservedObject var model: KitelineModel
    /// 这个按钮在工具栏上占多宽（连两边的空）：右上角那块会话的标签栏照这个数让位
    static let reserve: CGFloat = 112

    var body: some View {
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
struct StatusBar: View {
    @ObservedObject var model: KitelineModel
    /// 放在窗口顶部（布局里拖上去的）：分隔线画在下面
    var top = false
    @ObservedObject private var stats = SidebarStats.shared
    @ObservedObject private var perf = AppPerf.shared

    var body: some View {
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
                if busy > 0 { Text(L("%lld 个工作中", count: busy)).foregroundStyle(tinted ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.tarsBrand)).fontWeight(tinted ? .semibold : nil) }
                if waiting > 0 { Text(L("%lld 个待确认", count: waiting)).foregroundStyle(tinted ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.tarsOrange)).fontWeight(tinted ? .semibold : nil) }
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
private struct StatusItem<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Content
    @State private var hovering = false

    var body: some View {
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
struct NewLayoutRoot: View {
    @ObservedObject var model: KitelineModel

    var body: some View {
        let open = ProjectBlock.visible(model)
        let columns = model.layoutColumns
            .map { $0.filter { $0 == "nav" || $0 == "tabs" || open } }
            .filter { !$0.isEmpty }
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
                ForEach(Array(columns.enumerated()), id: \.element) { index, column in
                    columnView(column, first: index == 0, inset: !model.statusOnTop)
                        .overlay(alignment: .topTrailing) {
                            if !model.statusOnTop, index == columns.count - 1 { LayoutSwitchCorner(model: model, overTabs: column.contains("tabs")) }
                        }
                }
            }
            if !model.statusOnTop { StatusBar(model: model) }
        }
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.newTask() } label: { Label("新任务", systemImage: "square.and.pencil") }
                    .help("在指定项目中新建 Claude Code 会话")
            }
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

    @ViewBuilder private func columnView(_ blocks: [String], first: Bool, inset: Bool) -> some View {
        // 导航栏和别的块叠在一栏：图标栏占满整栏高，导航栏下面的块叠在它旁边那一栏里（RailSidebar.below）；导航栏上面的块照常上下分
        let nav = blocks.firstIndex(of: "nav")
        let above = nav.map { Array(blocks[..<$0]) } ?? blocks
        let below = nav.map { Array(blocks[($0 + 1)...]).filter { $0 != "tabs" } } ?? []
        let tabsBelowNav = nav.map { blocks[($0 + 1)...].contains("tabs") } ?? false
        let stack = VSplitView {
            ForEach(above, id: \.self) { block in blockView(block, first: first, below: []) }
            if nav != nil { blockView("nav", first: first, below: below) }
            if tabsBelowNav { blockView("tabs", first: first, below: []) }
        }
        if blocks.contains("tabs") {
            stack.modifier(TitlebarInset(on: inset && blocks != ["tabs"])).frame(minWidth: 420, maxWidth: .infinity).layoutPriority(1)
        } else {
            // 导航栏所在那栏：顶上（标题栏下面）是搜索框，填上原来那条空白
            VStack(spacing: 0) {
                if nav != nil { SidebarSearch(text: $model.query) }
                stack
            }
            .modifier(TitlebarInset(on: inset))
            .frame(minWidth: nav != nil ? 290 : 230, idealWidth: nav != nil ? 340 : 300, maxWidth: 640)
            .background(SideColumnShade().ignoresSafeArea())
            // 侧栏里的搜索框、列表边距照侧栏规范（SideMetric）
            .environment(\.sideColumn, true)
        }
    }

    @ViewBuilder private func blockView(_ block: String, first: Bool, below: [String]) -> some View {
        switch block {
        case "nav":
            RailSidebar(model: model, below: below)
                .frame(minHeight: 180, maxHeight: .infinity)
                // 纸鸢飞在最左一栏上方：导航栏在最左时报宽度给它，不在最左就不飞
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { KiteOverlay.shared.sidebarWidth = first ? geo.size.width : 0 }
                            .onChange(of: geo.size.width) { _, width in KiteOverlay.shared.sidebarWidth = first ? width : 0 }
                            .onChange(of: first) { _, now in KiteOverlay.shared.sidebarWidth = now ? geo.size.width : 0 }
                    }
                }
        case "tabs":
            ProjectSplit(model: model).frame(minHeight: 220, maxHeight: .infinity)
        default:
            ProjectBlock(model: model, block: block).frame(minHeight: 110, maxHeight: .infinity)
        }
    }
}

// MARK: - 布局设置（切到新版界面时弹、状态栏和图标栏的「布局」按钮打开）

/// 拖着摆布局：一张窗口示意图，四块（导航栏、会话列表、文件侧栏、标签页区域）都能拖——拖到某一栏上 = 叠在那一栏的下面，
/// 拖到两栏之间的缝 = 单独成一栏；块上的箭头也能挪（← → 换栏，↑ ↓ 栏里上下换）。状态栏拖到顶部或底部。
/// 每块写着名字和里面是什么。确定才生效；勾「下次不再询问」以后切新版不再弹
struct LayoutSetupSheet: View {
    @ObservedObject private var model = KitelineModel.shared
    @State private var columns = KitelineModel.shared.layoutColumns
    @State private var statusTop = KitelineModel.shared.statusOnTop
    @State private var dontAsk = !KitelineModel.shared.askLayoutOnSwitch
    /// 拖着经过的地方：「col:2」某一栏、「gap:1」两栏之间、「status:top|bottom」
    @State private var target: String?

    var body: some View {
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
                Button("恢复默认") { withAnimation(.snappy) { columns = KitelineModel.defaultColumns; statusTop = false } }.tarsButton()
                Button("确定") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .tarsButton(prominent: true)
            }
        }
        .padding(20)
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
            .dropDestination(for: String.self) { items, _ in
                guard let block = items.first, KitelineModel.layoutBlocks.contains(block) else { return false }
                withAnimation(.snappy) { move(block, newColumnAt: at) }
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
        .dropDestination(for: String.self) { items, _ in
            guard let block = items.first, KitelineModel.layoutBlocks.contains(block) else { return false }
            withAnimation(.snappy) { move(block, intoColumn: index) }
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
                    Button { withAnimation(.snappy) { statusTop.toggle() } } label: {
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
                .draggable("status") { dragLabel(L("状态栏")) }
            } else {
                Text(top ? L("拖到这里放在窗口顶部") : L("拖到这里放在窗口底部")).font(.app(size: 10.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).frame(height: 22)
                    .background(target == key ? Color.tarsBrand.opacity(0.1) : Color.clear, in: shape)
                    .overlay { shape.strokeBorder(target == key ? Color.tarsBrand.opacity(0.6) : Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard items.first == "status" else { return false }
            withAnimation(.snappy) { statusTop = top }
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
        .draggable(block) { dragLabel(info.title) }
    }

    private func arrow(_ symbol: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
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
struct RailShade: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme = Look.shared.scheme { Rectangle().fill(theme.activityBarColor) }
        else { Rectangle().fill(scheme == .dark ? Color.black.opacity(0.14) : Color.black.opacity(0.03)) }
    }
}

/// 侧栏里的一块（会话列表、文件侧栏）：照 VS Code 侧栏的视图小节——平铺在侧栏底上，顶上一条 22 点的小节标题
/// （折叠箭头 + 加粗小字），上面一道分隔线；点标题收起 / 展开（记住）。没选配色方案时颜色跟系统
struct SidebarPanel: ViewModifier {
    var title: String = ""
    @AppStorage private var collapsed: Bool

    init(title: String = "") {
        self.title = title
        _collapsed = AppStorage(wrappedValue: false, "panelCollapsed." + title, store: AppConfig.defaults)
    }

    func body(content: Content) -> some View {
        let scheme = Look.shared.scheme
        VStack(spacing: 0) {
            if !title.isEmpty {
                Button { withAnimation(.snappy(duration: 0.18)) { collapsed.toggle() } } label: {
                    // 箭头放在对齐线左边的空里，标题字和下面的内容一样从离栏边 16 点起（同 VS Code：箭头在缩进里）
                    HStack(spacing: 0) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .frame(width: SideMetric.inset - 4)
                        Text(title).font(.app(size: SideMetric.Text.caption, weight: .bold))
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
struct PanelSectionTitle: View {
    let title: String
    var count: Int = 0

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.app(size: SideMetric.Text.caption, weight: .semibold)).foregroundStyle(.secondary)
            if count > 0 { Text("\(count)").font(.app(size: SideMetric.Text.caption).monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .textCase(nil)
    }
}

/// 新版界面侧边几栏的底：不透明的中性灰，比中间对话区亮 / 暗一档（不跟壁纸、不带主题色），和对话区分得开又不扎眼
struct SideColumnShade: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme = Look.shared.scheme { Rectangle().fill(theme.sideBarColor) }
        else { Rectangle().fill(scheme == .dark ? Color(white: 0.135) : Color(white: 0.955)) }
    }
}

/// 导航栏顶上的搜索框（新版界面不在系统分栏里，系统的侧栏搜索框没了）：搜会话，同经典版
struct SidebarSearch: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
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
struct SchemeMenu: View {
    var body: some View {
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
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("配色方案（仿 VS Code 的颜色主题）"))
    }
}

/// 让出标题栏：量自己在窗口里的顶边离标题栏 + 工具栏的底边还差多少，往下让这么多（已经在下面了就不让）。
/// 量的是加了内边距之前的外框（背景里量），不会自己撑自己
struct TitlebarInset: ViewModifier {
    var on = true
    @State private var minY: CGFloat = 0
    /// 标题栏 + 工具栏多高：主窗口建好后量一次写进来（MainWindowController.init）。
    /// 别在 body 里碰 MainWindowController.shared——建窗口时就要算 body，那时 shared 还在初始化，递归初始化直接崩（11-21 keyuanchuangmei-56 用测试实例查出）
    static var band: CGFloat = 52

    func body(content: Content) -> some View {
        let band = Self.band
        content
            .padding(.top, on ? max(0, band - minY) : 0)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { minY = geo.frame(in: .global).minY }
                        .onChange(of: geo.frame(in: .global).minY) { _, value in minY = value }
                }
            }
    }
}
