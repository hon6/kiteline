import SwiftUI
#if os(iOS)
import CoreMotion
#endif

// iPhone Duo（折叠屏）适配，照苹果「Designing for iPhone Duo」：
// - 外屏（合上）：紧凑宽度，导航栏、工具栏竖排在右侧 → 首页顶上是概览看板（今日用量、各状态会话数），下面是会话列表
// - 内屏（打开）：常规宽度 → 左栏会话列表（汇总缩成一行）、右栏会话详情；未选会话时右栏是完整的概览页
// - 半折（立在桌上 / 像书一样打开）：对话页按折痕分成两块，消息在上（左）、输入框和操作在下（右）
// 都按尺寸类别、工具栏是否竖排（toolbarVerticalEdge）、折痕区域（reservedRegions）、有没有铰链来判断，不认机型、不看屏幕尺寸。

// MARK: - 工具栏竖排

extension View {
    /// 系统把导航栏、工具栏竖排到屏幕侧边时（iPhone Duo 外屏、内屏横放时的详情栏）把 onSide 设为 true
    @ViewBuilder
    func readSideBars(_ onSide: Binding<Bool>) -> some View {
        #if !os(iOS)
        self
        #elseif SNAPSHOT
        // 截图版（Mac 上跑）不会竖排：TARS_DEMO_SIDEBARS=1 当作竖排，看外屏的排版
        if Snapshot.sideBars {
            onAppear { onSide.wrappedValue = true }
        } else {
            sideBarsProbe(onSide)
        }
        #else
        sideBarsProbe(onSide)
        #endif
    }
}

extension View {
    /// 导航栏副标题（iOS 26 起才有；空字符串 = 不显示）
    @ViewBuilder
    func sideSubtitle(_ text: String) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            navigationSubtitle(text)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)   // 以下到「折痕」之前只在手机上有（Mac 版只编对话页，见 build.sh）

extension View {
    @ViewBuilder
    fileprivate func sideBarsProbe(_ onSide: Binding<Bool>) -> some View {
        #if targetEnvironment(macCatalyst)
        self   // 截图版（Catalyst）的 SDK 里没有 iOS 27.1 的这批接口
        #else
        if #available(iOS 27.1, *) {
            modifier(SideBarsProbe(onSide: onSide))
        } else {
            self
        }
        #endif
    }
}

#if !targetEnvironment(macCatalyst)
@available(iOS 27.1, *)
private struct SideBarsProbe: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var edge
    @Binding var onSide: Bool

    func body(content: Content) -> some View {
        content.onChange(of: edge != nil, initial: true) { _, side in onSide = side }
    }
}
#endif

// MARK: - 铰链：有铰链的设备（iPhone Duo）各个方向都支持，其余 iPhone 照旧只竖屏

@MainActor
enum Hinge {
    /// 这台设备有铰链（onHingeChange 第一次回调后才知道）
    private(set) static var present = false

    static func update(_ hasHinge: Bool) {
        guard hasHinge != present else { return }
        present = hasHinge
        // 让系统重新问一遍支持哪些方向（见 PushAppDelegate 的 supportedInterfaceOrientationsFor）
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        }
    }

    /// iPhone Duo：全部方向（外屏、内屏、各种姿态都要能用）；iPad 照旧全部；其余 iPhone 竖屏，点了首页的旋转按钮横屏（见 Rotation）
    static func orientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        if present { return .all }
        if window?.traitCollection.userInterfaceIdiom == .pad { return .all }
        return Rotation.shared.landscape ? .landscape : .portrait
    }
}

#if SNAPSHOT && !targetEnvironment(macCatalyst)
/// 模拟器里的截图版没有 PushAppDelegate（推送）：方向照正式版的规则给
final class SnapshotAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Hinge.orientations(for: window)
    }
}
#endif

extension View {
    /// 根视图上挂一次：记下有没有铰链
    @ViewBuilder
    func tracksHinge() -> some View {
        #if targetEnvironment(macCatalyst)
        self
        #else
        if #available(iOS 27.1, *) {
            onHingeChange { _, context in Hinge.update(context.hinge != nil) }
        } else {
            self
        }
        #endif
    }
}

// MARK: - iPhone 横屏：首页右上角的旋转按钮（10-27）

/// 普通 iPhone 默认只竖屏；点首页右上角的旋转按钮转成横屏（左右两个横向都行，跟着手机翻），再点转回竖屏。
/// 横屏时按宽屏排、同 iPad 竖着用：右边对话占满，会话列表从左边浮出来、可以收起（见 MainView 的 splitOverlay）；
/// 左右分栏、对话分屏都靠把根视图的水平尺寸类别改成常规（普通 iPhone 横着是紧凑，系统不分栏）。
/// 不记到下次启动：下次打开照常竖屏
@MainActor @Observable
final class Rotation {
    static let shared = Rotation()
    private(set) var landscape = false

    /// 这台设备用得上旋转按钮：普通 iPhone（iPad、iPhone Duo 本来各个方向都能转）
    var available: Bool { UIDevice.current.userInterfaceIdiom == .phone && !Hinge.present }

    /// 横着的 iPhone（不含 iPhone Duo）：左栏浮在对话上面
    static func phoneLandscape(_ size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !Hinge.present && size.width > size.height
    }

    func toggle() { set(!landscape) }

    func set(_ on: Bool) {
        guard available, on != landscape else { return }
        landscape = on
        ChatPanes.sideBySideOnly = on
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            // 先让系统重新问一遍支持哪些方向（见 Hinge.orientations），再请它转过去
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscape : .portrait))
        }
    }

    /// 根视图的宽高变了：横着时把水平尺寸类别改成常规（左右分栏），竖回来去掉。按真正转完的宽高来，转到一半不改
    fileprivate func fit(wide: Bool) {
        guard available else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for controller in scene.windows.compactMap(\.rootViewController) {
                // 没设过的直接读 traitOverrides.horizontalSizeClass 会抛异常崩掉，先问 contains
                let set = controller.traitOverrides.contains(UITraitHorizontalSizeClass.self)
                if wide, !set {
                    controller.traitOverrides.horizontalSizeClass = .regular
                } else if !wide, set {
                    controller.traitOverrides.remove(UITraitHorizontalSizeClass.self)
                }
            }
        }
    }
}

extension View {
    /// 根视图上挂一次：iPhone 横过来按宽屏排，竖回来照旧
    func tracksRotation() -> some View {
        onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { wide in
            Rotation.shared.fit(wide: wide)
        }
    }
}

/// 整个 App 共用一个传感器管理器（苹果建议只建一个）：信绳的重力、转屏提示都从这里读
enum SharedMotion {
    @MainActor static let manager = CMMotionManager()
}

/// 转屏提示（同系统「照片」）：手里的手机转了方向、界面没跟着转时，在手里那个方向的右上角放一个慢慢闪的旋转按钮，
/// 点了界面转过去；竖着转横、横着转竖都提示。看加速度计（系统锁了竖屏也读得到），平放、刚转一下不算；提示 12 秒没点就收起
struct RotationHint: View {
    @Environment(\.scenePhase) private var phase
    private var rotation = Rotation.shared
    /// 手里的方向：机身坐标的重力（竖着拿 y≈-1；顶朝左横拿 x≈-1）
    @State private var physical: Physical?
    @State private var shown = false
    @State private var pulse = false
    @State private var since: Date?

    private enum Physical: Equatable { case portrait, topLeft, topRight
        var landscape: Bool { self != .portrait }
    }

    var body: some View {
        GeometryReader { proxy in
            if shown, let physical {
                let (corner, angle) = layout(physical)
                Button {
                    rotation.set(physical.landscape)
                    withAnimation(.snappy) { shown = false }
                } label: {
                    Image(systemName: physical.landscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                        .font(.app(size: 20, weight: .medium)).foregroundStyle(Theme.claude)
                        .rotationEffect(angle)
                        .frame(width: 44, height: 44)
                        .liquidGlass(in: Circle())
                        // 慢闪只给不透明度（作用域动画）：withAnimation 开的循环动画会把转屏时的重新排版也卷进去，按钮一直来回漂
                        .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { $0.opacity(pulse ? 1 : 0.35) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(physical.landscape ? L("转为横屏") : L("转为竖屏"))
                // 贴着手里那个方向的右上角，离两条边一样远（10-27：不用让开 Home 横条，那一角本来没有按钮）
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
                .transition(.opacity)
                .onAppear {
                    pulse = false
                    Task { @MainActor in pulse = true }   // 下一轮再亮：先回到暗的，再开始闪
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(shown)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: phase) { _, phase in if phase == .active { start() } else { stop() } }
        .onChange(of: rotation.landscape) { _, _ in withAnimation(.snappy) { shown = false } }
        #if DEBUG || SNAPSHOT
        // 模拟器没有加速度计：hint topLeft|topRight|portrait 当作手里转到那个方向（见 DebugRemote）
        .onReceive(NotificationCenter.default.publisher(for: DebugRemote.command)) { note in
            guard let line = note.object as? String, line.hasPrefix("hint ") else { return }
            let next: Physical? = ["topLeft": .topLeft, "topRight": .topRight, "portrait": .portrait][String(line.dropFirst(5))]
            physical = next
            withAnimation(.snappy) { shown = next.map { $0.landscape != rotation.landscape } ?? false }
        }
        #endif
    }

    /// 手里那个方向的右上角在界面上是哪个角、图标要转多少度才是正的
    private func layout(_ physical: Physical) -> (Alignment, Angle) {
        // 界面坐标里「手里的下方」：界面竖着时，顶朝左横拿 = 往界面左边；界面横着（home 条在右，顶朝左）时竖着拿 = 往界面右边……
        let down: CGVector
        switch (rotation.landscape, physical) {
        case (false, .topLeft): down = CGVector(dx: -1, dy: 0)
        case (false, .topRight): down = CGVector(dx: 1, dy: 0)
        case (true, .portrait):
            let left = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.effectiveGeometry.interfaceOrientation == .landscapeLeft
            down = CGVector(dx: left ? -1 : 1, dy: 0)
        default: down = CGVector(dx: 0, dy: 1)
        }
        let up = CGVector(dx: -down.dx, dy: -down.dy)
        let right = CGVector(dx: down.dy, dy: -down.dx)
        let corner = CGVector(dx: up.dx + right.dx, dy: up.dy + right.dy)
        let alignment = Alignment(horizontal: corner.dx > 0 ? .trailing : .leading, vertical: corner.dy > 0 ? .bottom : .top)
        return (alignment, .radians(atan2(-down.dx, down.dy)))
    }

    private func start() {
        let motion = SharedMotion.manager
        guard rotation.available, motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.25
        motion.startAccelerometerUpdates(to: .main) { data, _ in
            guard let a = data?.acceleration else { return }
            MainActor.assumeIsolated { update(a) }
        }
    }

    private func stop() {
        SharedMotion.manager.stopAccelerometerUpdates()
        shown = false
    }

    private func update(_ a: CMAcceleration) {
        // 平放、斜得不够明显的不算；换了方向要稳住 0.75 秒才算
        guard abs(a.z) < 0.8 else { return }
        let next: Physical? = abs(a.x) > 0.7 && abs(a.x) > abs(a.y) + 0.3 ? (a.x < 0 ? .topLeft : .topRight)
            : (a.y < -0.7 && abs(a.y) > abs(a.x) + 0.3 ? .portrait : nil)
        guard let next else { return }
        if next != physical {
            physical = next
            since = Date()
            if shown { withAnimation(.snappy) { shown = false } }
            return
        }
        guard let since else { return }
        let mismatch = next.landscape != rotation.landscape
        let age = Date().timeIntervalSince(since)
        let want = mismatch && age > 0.75 && age < 12.75
        if want != shown { withAnimation(.snappy) { shown = want } }
    }
}

/// 首页右上角的旋转按钮：竖着时点了转横屏，横着时点了转回竖屏
struct RotateButton: View {
    private var rotation = Rotation.shared

    var body: some View {
        Button { rotation.toggle() } label: {
            Image(systemName: rotation.landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate").barIcon()
        }
        .accessibilityLabel(rotation.landscape ? L("转为竖屏") : L("转为横屏"))
    }
}

// MARK: - 概览看板

/// 各状态的会话数（看板、侧栏一行汇总共用）
struct SessionCounts {
    var all = 0, busy = 0, waiting = 0, unread = 0, error = 0

    @MainActor init(_ model: AppModel) {
        let sessions = model.sessions
        all = sessions.count
        busy = sessions.filter(\.isBusy).count
        waiting = sessions.filter(\.isWaiting).count
        unread = sessions.filter { model.isUnread($0) }.count
        error = sessions.filter { $0.error != nil }.count
    }
}

/// 概览看板：今日用量（带近 7 天小柱图、每日预算）、各状态会话数、今日动态 / 历史 / 项目入口。
/// iPhone Duo 外屏首页顶上用紧凑版；宽屏右栏的概览页用大号（large）。
/// 状态格同时是首页列表的筛选（和列表顶上的筛选条存同一个值）：点一下只看这一类，再点一下取消
struct GlanceBoard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @AppStorage("listFilter") private var statusFilter = "all"
    var large = false

    var body: some View {
        VStack(spacing: large ? 14 : 10) {
            usageCard
            statusRow
            links
        }
        .task(id: model.connected) {
            guard model.connected else { return }
            await model.home.refreshWeek(model.api)
        }
    }

    // MARK: 用量

    private var usageCard: some View {
        let usage = model.home.usage
        let budget = model.home.budget
        return Button { open(.usage) } label: {
            VStack(alignment: .leading, spacing: large ? 14 : 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("今日用量", systemImage: "chart.bar.fill")
                        .font(.ui(.subheadline).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .labelStyle(GlanceLabelStyle())
                    Spacer(minLength: 8)
                    Text("近 7 天").font(.ui(.caption)).foregroundStyle(.tertiary)
                }
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(usage.map { Money.cost($0.cost) } ?? "—")
                            .font(.app(size: large ? 40 : 32, weight: .bold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .contentTransition(.numericText())
                        Text(usage.map { "输出 \(Money.compact($0.output)) · \(Int($0.requests.rounded())) 次请求" } ?? "正在统计…")
                            .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    WeekBars(days: model.home.week, labels: large)
                        .frame(width: large ? 220 : 112, height: large ? 72 : 44)
                }
                if let budget, budget.daily > 0 || budget.cap > 0 {
                    BudgetMeter(spent: usage?.cost ?? 0, budget: budget)
                }
            }
            .padding(large ? 18 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("今日用量 \(usage.map { Money.cost($0.cost) } ?? "")，轻点查看详情")
    }

    // MARK: 各状态会话数

    private var statusRow: some View {
        let counts = SessionCounts(model)
        return HStack(spacing: 0) {
            cell("busy", L("运行中"), counts.busy, dot: Theme.claude)
            divider
            cell("waiting", L("待确认"), counts.waiting, dot: .orange)
            divider
            cell("unread", L("新消息"), counts.unread, dot: Theme.removed)
            divider
            cell("error", L("出错"), counts.error, dot: Theme.removed)
        }
        .padding(.vertical, 4)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).padding(.vertical, 12)
    }

    private func cell(_ id: String, _ title: String, _ count: Int, dot: Color) -> some View {
        let selected = statusFilter == id
        return Button {
            Haptics.tap()
            withAnimation(.snappy) { statusFilter = selected ? "all" : id }
        } label: {
            VStack(spacing: 3) {
                Text("\(count)")
                    .font(.app(size: large ? 30 : 24, weight: .bold).monospacedDigit())
                    .foregroundStyle(count > 0 ? .primary : .tertiary)
                    .contentTransition(.numericText())
                HStack(spacing: 4) {
                    Circle().fill(count > 0 ? dot : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(title).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, large ? 14 : 10)
            .background(selected ? Theme.claude.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(title) \(count) 个会话")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: 入口

    private var links: some View {
        let today = model.home.today
        let projects = model.home.projects
        return HStack(spacing: 8) {
            GlanceLink(symbol: "sun.max.fill", title: L("今日动态"),
                       value: today.map { $0.prompts > 0 ? "\($0.prompts)" : "" } ?? "",
                       alert: (today?.testFailed ?? 0) > 0) { open(.today) }
            GlanceLink(symbol: "folder.fill", title: L("项目"),
                       value: projects.isEmpty ? "" : "\(projects.count)",
                       alert: false) { open(.projects) }
            GlanceLink(symbol: "clock.arrow.circlepath", title: L("历史"), value: "", alert: false) { open(.history) }
        }
    }
}

/// 看板标题行的图标：小一号、和文字同色
private struct GlanceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.ui(.caption))
            configuration.title
        }
    }
}

/// 看板底下一排入口：图标 + 名字 + 数
private struct GlanceLink: View {
    let symbol: String
    let title: String
    let value: String
    let alert: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.ui(.caption)).foregroundStyle(Theme.claude)
                Text(title).font(.ui(.footnote).weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                if !value.isEmpty {
                    Text(value).font(.ui(.caption).monospacedDigit()).foregroundStyle(alert ? Theme.removed : .secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// 近 7 天每天的花费：一种颜色，今天实色、往前几天浅色（不画坐标轴；large 时底下写星期）
struct WeekBars: View {
    let days: [UsageItem]
    var labels = false

    var body: some View {
        let recent = Array(days.suffix(7))
        let top = max(recent.map(\.cost).max() ?? 0, 0.01)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: labels ? 8 : 5) {
                if recent.isEmpty {
                    ForEach(0..<7, id: \.self) { _ in bar(0.06, today: false) }
                } else {
                    ForEach(Array(recent.enumerated()), id: \.offset) { index, day in
                        bar(max(day.cost / top, 0.06), today: index == recent.count - 1)
                    }
                }
            }
            if labels {
                HStack(spacing: 8) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, day in
                        Text(Self.weekday(day.day)).font(.ui(.caption2)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("近 7 天花费：") + recent.map { "\(Self.weekday($0.day)) \(Money.cost($0.cost))" }.joined(separator: "，"))
    }

    private func bar(_ ratio: Double, today: Bool) -> some View {
        GeometryReader { geo in
            VStack {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.claude.opacity(today ? 1 : 0.32))
                    .frame(height: max(3, geo.size.height * ratio))
            }
        }
    }

    /// 「2026-10-21」→「周三」
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func weekday(_ day: String) -> String {
        guard let date = dayFormatter.date(from: day) else { return "" }
        // 整个词交给翻译（周一 → Mon），别拼「周」+「一」：英文拼不出来
        let names = [L("周日"), L("周一"), L("周二"), L("周三"), L("周四"), L("周五"), L("周六")]
        return names[Calendar.current.component(.weekday, from: date) - 1]
    }
}

/// 预算进度：一条细线 + 一行字（达到提醒线变橙，达到上限变红）
private struct BudgetMeter: View {
    let spent: Double
    let budget: Budget

    var body: some View {
        let limit = budget.cap > 0 ? budget.cap : budget.daily
        let ratio = min(spent / max(limit, 0.01), 1)
        let over = budget.cap > 0 && spent >= budget.cap
        let warn = budget.daily > 0 && spent >= budget.daily * 0.8
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(over ? Theme.removed : (warn ? .orange : Theme.claude)).frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 5)
            Text(budget.cap > 0 ? "每日上限 \(Money.cost(budget.cap)) · 已用 \(Int((ratio * 100).rounded()))%"
                                : "每日提醒 \(Money.cost(budget.daily)) · 已用 \(Int((ratio * 100).rounded()))%")
                .font(.ui(.caption2)).foregroundStyle(over ? Theme.removed : .secondary)
        }
    }
}

// MARK: - 宽屏左栏顶上的一行汇总

/// 宽屏（iPhone Duo 内屏、iPad）左栏顶上：今日花费和各状态会话数缩成一行，轻点在右栏打开概览
struct GlanceStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open

    var body: some View {
        let counts = SessionCounts(model)
        Button { open(.overview) } label: {
            HStack(spacing: 0) {
                metric(model.home.usage.map { Money.cost($0.cost) } ?? "—", L("今日用量"))
                metric("\(counts.busy)", L("运行中"), dim: counts.busy == 0)
                metric("\(counts.waiting)", L("待确认"), dim: counts.waiting == 0, color: counts.waiting > 0 ? .orange : nil)
                metric("\(counts.error)", L("出错"), dim: counts.error == 0, color: counts.error > 0 ? Theme.removed : nil)
                Image(systemName: "chevron.right").font(.ui(.caption).weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.trailing, 12)
            }
            .padding(.vertical, 10)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("概览：今日用量 \(model.home.usage.map { Money.cost($0.cost) } ?? "")，运行中 \(counts.busy)，待确认 \(counts.waiting)，出错 \(counts.error)")
    }

    private func metric(_ value: String, _ title: String, dim: Bool = false, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.app(size: 17, weight: .bold).monospacedDigit())
                .foregroundStyle(color ?? (dim ? Color.secondary : Color.primary))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 宽屏右栏：概览页

/// 宽屏未选会话时右栏显示的概览（iPhone Duo 内屏、iPad）：看板、需要处理的会话、运行中的会话、今日动态
struct OverviewPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open

    var body: some View {
        let attention = model.sortedSessions("status").filter { $0.isWaiting || $0.error != nil }
        let running = model.sortedSessions("recent").filter { $0.isBusy && !$0.isWaiting }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.connected ? "\(model.host) · \(model.sessions.count) 个会话" : "未连接")
                    .font(.ui(.footnote)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
                GlanceBoard(large: true)
                if !attention.isEmpty {
                    section(L("需要处理"), attention)
                }
                if !running.isEmpty {
                    section(L("运行中"), running)
                }
                if attention.isEmpty && running.isEmpty {
                    PageNote(text: model.sessions.isEmpty ? L("暂无会话。可轻点「新建任务」开始，或在电脑上打开 Claude Code。")
                                                          : L("所有会话均已空闲。在左侧选择会话，即可在此继续对话。"))
                }
                if let today = model.home.today, today.prompts + today.replies > 0 {
                    SectionLabel(text: L("今日动态"))
                    Button { open(.today) } label: {
                        StatGrid(cards: [
                            StatCard(value: "\(today.prompts)", label: L("条指令", plural: "%lld 条指令", count: today.prompts), sub: L("%lld 个会话", count: today.sessions)),
                            StatCard(value: "\(today.replies)", label: L("次回复", plural: "%lld 次回复", count: today.replies), sub: L("输出 %@", "\(Money.compact(Double(today.outputTokens)))")),
                            StatCard(value: "\(today.files)", label: L("个文件", plural: "%lld 个文件", count: today.files), sub: L("%lld 个项目", count: today.projects)),
                            StatCard(value: "\(today.testRuns)", label: L("次测试", plural: "测试 %lld 次", count: today.testRuns), sub: today.testFailed > 0 ? L("失败 %@ 次", "\(today.testFailed)") : L("全部通过"),
                                     tone: today.testFailed > 0 ? .bad : .plain),
                        ], columns: 4)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
        // 和今日动态、用量页一样用导航栏小标题（工具栏竖排时系统放到左上角）
        .navigationTitle("概览")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable {
            await model.refresh()
            await model.home.refresh(model.api, force: true)
            await model.home.refreshWeek(model.api, force: true)
        }
    }

    private func section(_ title: String, _ sessions: [SessionInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "\(title) · \(sessions.count)")
            VStack(spacing: 0) {
                ForEach(Array(sessions.prefix(6).enumerated()), id: \.element.key) { index, session in
                    if index > 0 { Divider().padding(.leading, 60) }
                    Button { open(.chat(session.key)) } label: { OverviewRow(session: session) }
                        .buttonStyle(RowButtonStyle())
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// 概览页里的一行会话：头像、标题、状态一行
private struct OverviewRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            Avatar(text: Format.initials(session.title), size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.app(size: 16)).foregroundStyle(.primary).lineLimit(1)
                status.font(.ui(.footnote)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Format.listTime(session.updatedAt)).font(.ui(.caption)).foregroundStyle(.tertiary)
            Image(systemName: "chevron.right").font(.ui(.caption).weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var status: Text {
        if session.isWaiting {
            return Text("\(Text("待确认").foregroundStyle(.orange)) \(Text(session.blocking ?? session.reason ?? "").foregroundStyle(.secondary))")
        }
        if let error = session.error {
            return Text("\(Text("出错已停止").foregroundStyle(Theme.removed)) \(Text(error).foregroundStyle(.secondary))")
        }
        let running = session.liveStage.map { "\($0.short) · " } ?? ""
        return Text(running + (session.activityText.map { "运行中 · \($0)" } ?? "运行中")).foregroundStyle(Theme.claude)
    }
}

#endif

// MARK: - 折痕（对话页用，Mac 版也编进去：Mac 上没有折痕，总是 nil）

/// 对话页被折痕分成两块（iPhone Duo 半折）：横着的折痕 → 上下两块（立在桌上），竖着的 → 左右两块（像书一样打开）。
/// start = 第一块（上 / 左）的长度，gap = 折痕本身的宽，total = 整页的高 / 宽
struct ChatFold: Equatable {
    var horizontal: Bool
    var start: CGFloat
    var gap: CGFloat
    var total: CGFloat
    /// 第二块（下 / 右，放输入框和操作）连同折痕的长度
    var tail: CGFloat { total - start }

    /// 有效的折痕：在本视图里、两边都放得下（打开键盘后下半块太矮就不算，照常排）
    @MainActor static func read(_ proxy: GeometryProxy) -> ChatFold? {
        let size = proxy.size
        #if SNAPSHOT
        // 截图版（Mac 上跑）没有折痕：TARS_DEMO_FOLD=h / v 在正中间假装有一条 28 宽的
        if let fake = Snapshot.fold {
            return fake == "v" ? ChatFold(horizontal: false, start: size.width / 2 - 14, gap: 28, total: size.width)
                               : ChatFold(horizontal: true, start: size.height / 2 - 14, gap: 28, total: size.height)
        }
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            for region in proxy.reservedRegions(kind: .division) where region.isActive {
                let frame = region.frame
                if frame.width >= frame.height {
                    if frame.minY >= 160, size.height - frame.maxY >= 200 {
                        return ChatFold(horizontal: true, start: frame.minY, gap: frame.height, total: size.height)
                    }
                } else if frame.minX >= 260, size.width - frame.maxX >= 260 {
                    return ChatFold(horizontal: false, start: frame.minX, gap: frame.width, total: size.width)
                }
            }
        }
        #endif
        return nil
    }
}

extension View {
    /// 量出本视图里的折痕（没有或放不下就是 nil）
    func readFold(_ fold: Binding<ChatFold?>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.onChange(of: ChatFold.read(proxy), initial: true) { _, value in
                    withAnimation(.snappy) { fold.wrappedValue = value }
                }
            }
        }
    }
}

/// 半折时折痕另一边、输入框上面空出来的那块：会话当前在做什么、Claude 的任务清单
struct FoldDeck: View {
    let session: SessionInfo?
    let todos: [JSONValue]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(dot).frame(width: 8, height: 8)
                    Text(state).font(.ui(.subheadline).weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                if let detail { Text(detail).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(3) }
                if !todos.isEmpty {
                    TodoCard(todos: todos).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var state: String {
        guard let session else { return L("已结束") }
        if session.isWaiting { return L("待确认") }
        if session.isBusy { return L("运行中") }
        if session.error != nil { return L("出错已停止") }
        return L("空闲")
    }

    private var detail: String? {
        guard let session else { return nil }
        if session.isWaiting { return session.blocking ?? session.reason }
        if session.isBusy {
            return session.activityText   // 做到第几步在下面的任务进展条上
        }
        return session.error
    }

    private var dot: Color {
        guard let session else { return .secondary }
        if session.isWaiting { return .orange }
        if session.isBusy { return Theme.claude }
        if session.error != nil { return Theme.removed }
        return Theme.added
    }
}
