#if !KITELINE_MAC
import SwiftUI
import UIKit

// 竖着的 iPhone 底部的 Tab 栏（11-13）：首页像微信一样只是会话列表，原来堆在列表上面的用量、战绩、入口方格分到别的页签。
//   会话：会话 / 群 / 会话组、筛选；顶栏左边搜索（点开在顶栏里展开）、右边「新建会话」
//   项目：各项目，顶上历史会话、定时任务
//   待办：我的待办、Agent 的待办、要你处理的提醒
//   概览：今日用量（额度条）、今日战绩、今日动态、世界和数据流
//   我：原来的设置（头像、就绪检查、收藏、通知记录、订阅、外观……）
// iPad、横着的 iPhone、iPhone Duo 是左右分栏，不用 Tab 栏（左栏照旧）。远程配置 homeTabs 关掉时回到一页式首页。

enum HomeTab: String, Hashable {
    case sessions, projects, todos, overview, me
}

extension EnvironmentValues {
    /// 首页在底部 Tab 栏里：会话列表上面不再放汇总卡片和入口方格，顶栏只有搜索和「新建会话」
    @Entry var homeTabs = false
}

/// 页签上的红色角标，只标要你动手的（红点一直挂着就没人看了）：只有待办 = Agent 刚提醒你做、还没决定加不加的件数
/// （已在清单里的未完成待办，进页签就看得到，不另挂角标）。「会话」不挂数字（11-13），有事的会话行上有小点
struct TabBadges: Equatable {
    var todos = 0
}

/// 读待办算角标，数变了才写回 MainView（MainView 自己读模型的话，任何数据一变整个主界面都要重算）
struct TabBadgeProbe: View {
    @Environment(AppModel.self) private var model
    @Binding var badges: TabBadges

    var body: some View {
        let now = TabBadges(todos: model.todos.suggestions.reduce(0) { $0 + $1.asks.count })
        Color.clear.onChange(of: now, initial: true) { _, value in
            if badges != value { badges = value }
        }
    }
}

/// Tab 栏该不该展开：各页签第一层的列表报滚动方向（TabBarScrollWatch），TabBarMinimize 照着换收起方式
@Observable final class TabBarScroll {
    /// 收起方式临时是 .never（系统随即把收起的 Tab 栏展开）
    var expand = false
    @ObservationIgnored private var pulse = 0

    /// 往回滑了：展开 Tab 栏。只临时换一下收起方式就换回来：一直留着 .never 的话，
    /// 下次往下翻到一半才换回 .onScrollDown，系统接不上、那一下不收起
    func expandNow() {
        pulse += 1
        let id = pulse
        if #available(iOS 26.0, *), let bar = Self.tabBarController() {
            // 系统换收起方式时一帧之内直接跳成展开、不走动画（11-14：收起有动画，展开是瞬间的）；
            // 包 withAnimation / UIView.animate 都没用（录屏逐帧看过），只能在展开那一刻自己补一段过渡（grow）
            // 只在真的从圆钮展开时补动画：本来就展开着（没翻多远就往回滑）再揭开一遍会闪一下。
            // 系统没有「是否收起」的公开接口，比较切换前后底栏里看得见的图标、文字横跨多宽
            let before = Self.visibleSpan(bar.tabBar)
            bar.tabBarMinimizeBehavior = .never
            bar.tabBar.layoutIfNeeded()
            let after = Self.visibleSpan(bar.tabBar)
            if Self.animated, after > before + 60 { Self.grow(bar.tabBar) }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                if self.pulse == id { bar.tabBarMinimizeBehavior = .onScrollDown }
            }
            return
        }
        expand = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if self.pulse == id { self.expand = false }
        }
    }

    /// 从左下角的圆钮往右揭开成整条（系统收起动画倒着放的样子）：遮罩从圆钮那么宽弹到整条，图标不变形；带一点淡入。
    /// （直接压扁再弹开会把图标挤成细条，录屏看过不好看）
    static func grow(_ view: UIView) {
        let b = view.bounds
        guard b.width > 120 else { return }
        // 往外多留一圈，玻璃的阴影、高光不被切掉
        let full = b.insetBy(dx: -24, dy: -24)
        let mask = UIView(frame: CGRect(x: full.minX, y: full.minY, width: 24 + 84, height: full.height))
        mask.backgroundColor = .black
        mask.layer.cornerRadius = 40
        view.mask = mask
        view.alpha = 0.7
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) {
            mask.frame = full
            mask.layer.cornerRadius = 0
            view.alpha = 1
        } completion: { _ in
            if view.mask === mask { view.mask = nil }
        }
    }

    #if SNAPSHOT
    /// 截图版 KITELINE_DEMO_EXPANDMODE=none：不补动画（系统原样），录屏对照用
    static let animated = ProcessInfo.processInfo.environment["KITELINE_DEMO_EXPANDMODE"] != "none"
    #else
    static let animated = true
    #endif

    /// 底栏里看得见的图标、文字（叶子视图）横跨多宽：收起成圆钮时只有当前那格，展开时五格
    static func visibleSpan(_ root: UIView) -> CGFloat {
        var low = CGFloat.infinity, high = -CGFloat.infinity
        func walk(_ view: UIView, _ depth: Int) {
            guard !view.isHidden, view.alpha > 0.01, depth < 8 else { return }
            if view.subviews.isEmpty, view !== root, view.bounds.width > 0 {
                let r = view.convert(view.bounds, to: root)
                low = min(low, r.minX); high = max(high, r.maxX)
            }
            for child in view.subviews { walk(child, depth + 1) }
        }
        walk(root, 0)
        return high > low ? high - low : 0
    }

    /// SwiftUI 的 TabView 底下就是 UITabBarController：从前台窗口的视图控制器树里找
    static func tabBarController() -> UITabBarController? {
        func find(_ vc: UIViewController?) -> UITabBarController? {
            guard let vc else { return nil }
            if let bar = vc as? UITabBarController { return bar }
            for child in vc.children { if let bar = find(child) { return bar } }
            return nil
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return find(windows.first(where: \.isKeyWindow)?.rootViewController) ?? windows.lazy.compactMap { find($0.rootViewController) }.first
    }
}

extension EnvironmentValues {
    @Entry var tabBarScroll: TabBarScroll? = nil
}

/// iOS 26 起往下翻时 Tab 栏缩成小胶囊，把地方让给列表。系统的 .onScrollDown 要滚回顶部才展开，
/// 11-13 改为「只要往下滑页面就直接展开」：往回滑时把收起方式临时换成 .never 一下（系统随即展开）再换回来。
/// 模拟器里用 XCUITest 真拖验证过（程序滚动不会让系统收起，测不了）
struct TabBarMinimize: ViewModifier {
    let scroll: TabBarScroll

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(scroll.expand ? .never : .onScrollDown)
        } else {
            content
        }
    }
}

/// 挂在页签第一层的列表 / 滚动视图上：按方向累计滚过的距离，过了门槛才报，抖一下不算。
/// 顶部下拉、底部回弹那段橡皮筋不算（回弹是往回走，会被当成往回滑）；内容变高变矮（新消息、展开收起）带来的位移也不算。
/// （没用 onScrollPhaseChange 区分手指拖动：List 上它不报）
struct TabBarScrollWatch: ViewModifier {
    @Environment(\.tabBarScroll) private var bar
    @State private var travel: CGFloat = 0
    /// 这一段往回滑已经展开过了（换方向才重来）
    @State private var fired = false

    private struct Spot: Equatable {
        var y: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let bar {
            content
                .onScrollGeometryChange(for: Spot.self) { geo in
                    let top = -geo.contentInsets.top
                    return Spot(y: geo.contentOffset.y, top: top,
                                bottom: max(top, geo.contentSize.height + geo.contentInsets.bottom - geo.containerSize.height))
                } action: { old, new in
                    guard old.top == new.top, old.bottom == new.bottom else { travel = 0; return }
                    let from = min(max(old.y, new.top), new.bottom), to = min(max(new.y, new.top), new.bottom)
                    let delta = to - from
                    guard delta != 0 else { return }
                    // 换了方向从零算
                    if (delta > 0) != (travel > 0) { travel = 0; fired = false }
                    travel += delta
                    if travel < -12, !fired { fired = true; bar.expandNow() }
                }
        } else {
            content
        }
    }
}

extension View {
    /// 页签第一层的滚动视图挂这个：往回滑时 Tab 栏立刻展开
    func tabBarScrollWatch() -> some View { modifier(TabBarScrollWatch()) }
}

/// 「概览」页签：今日用量、今日战绩、今日动态（几个数），下面世界和数据流两个入口
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @State private var cover: Cover?

    private struct Cover: Identifiable { let id: String }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HomeTiles(entries: false)
                if let today = model.home.today {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: L("今日动态"))
                        Button { open(.today) } label: {
                            StatGrid(cards: [
                                StatCard(value: "\(today.prompts)", label: L("条指令", plural: "%lld 条指令", count: today.prompts), sub: L("%lld 个会话", count: today.sessions)),
                                StatCard(value: "\(today.replies)", label: L("次回复", plural: "%lld 次回复", count: today.replies), sub: L("输出 %@", "\(Money.compact(Double(today.outputTokens)))")),
                                StatCard(value: "\(today.files)", label: L("个文件", plural: "%lld 个文件", count: today.files), sub: L("%lld 个项目", count: today.projects)),
                                StatCard(value: "\(today.testRuns)", label: L("次测试", plural: "测试 %lld 次", count: today.testRuns),
                                         sub: today.testFailed > 0 ? L("失败 %@ 次", "\(today.testFailed)") : L("全部通过"),
                                         tone: today.testFailed > 0 ? .bad : .plain),
                            ], columns: 2)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: L("全景视图"))
                    HStack(spacing: 12) {
                        Button { cover = Cover(id: "world") } label: {
                            SceneCard(title: L("世界"), detail: L("像素园区里看各会话")) { WorldGlobeIcon() }
                        }
                        Button { cover = Cover(id: "flow") } label: {
                            SceneCard(title: L("数据流"), detail: L("读了什么、改了什么")) {
                                Image(systemName: "point.3.connected.trianglepath.dotted").font(.app(size: 20)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .tabBarScrollWatch()
        .background(Theme.pageBackground)
        .navigationTitle("概览")
        .navigationBarTitleDisplayMode(.inline)
        // 数据启动时就从手机上的缓存填好了（HomeStats.restore），这里取新的时右上角「更新中」
        .updating(model.home.refreshing)
        .refreshable {
            await model.refresh()
            await model.home.refresh(model.api, force: true)
            await model.home.refreshLimits(model.api, fresh: true)
        }
        .task(id: model.connected) {
            guard model.connected else { return }
            await model.home.refresh(model.api)
        }
        .fullScreenCover(item: $cover) { cover in WorldScreen(page: cover.id).environment(model) }
    }
}

#if SNAPSHOT
/// 截图版：把主屏 / 锁屏小组件按 iPhone 上的尺寸画出来核对（TARS_DEMO_ROUTE=widgets；数据就是 App 此刻会写给小组件的那份）
struct WidgetGallery: View {
    @Environment(AppModel.self) private var model

    /// 从钥匙串里读回来的那份（App 写、小组件读的就是它）：读到了说明写入、读出这条路是通的
    @State private var stored: WidgetSnapshot?
    /// 没等到时直接写一次的结果（钥匙串状态码）
    @State private var probe: String?

    var body: some View {
        var computed = WidgetSync.snapshot(model)
        let _ = (computed.at = Date().timeIntervalSince1970 * 1000)
        let snapshot = stored ?? computed
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(stored.map { "钥匙串里读到 \(WidgetTone.clock($0.at)) 写的摘要：\($0.sessions.count) 个会话、\($0.limits.count) 项额度" } ?? ("钥匙串里还没有摘要（画的是现算的）" + (probe ?? "")))
                    .font(.caption).foregroundStyle(.white)
                HStack(spacing: 16) {
                    tile(SessionsWidgetView(snapshot: snapshot, family: .systemSmall), width: 170, height: 170)
                    tile(UsageWidgetView(snapshot: snapshot, family: .systemSmall), width: 170, height: 170)
                }
                tile(SessionsWidgetView(snapshot: snapshot, family: .systemMedium), width: 356, height: 170)
                tile(UsageWidgetView(snapshot: snapshot, family: .systemMedium), width: 356, height: 170)
                tile(SessionsWidgetView(snapshot: snapshot, family: .systemLarge), width: 356, height: 380)
                HStack(spacing: 12) {
                    lock(SessionsWidgetView(snapshot: snapshot, family: .accessoryCircular), width: 72)
                    lock(UsageWidgetView(snapshot: snapshot, family: .accessoryCircular), width: 72)
                    lock(SessionsWidgetView(snapshot: snapshot, family: .accessoryRectangular), width: 170)
                }
                HStack(spacing: 12) {
                    lock(UsageWidgetView(snapshot: snapshot, family: .accessoryRectangular), width: 170)
                    tile(SessionsWidgetView(snapshot: nil, family: .systemSmall), width: 170, height: 170)
                }
            }
            .padding(16)
        }
        .background(Color(white: 0.35))
        // 平时会话页一打开就取用量、额度；这里直接进来，自己取一下
        .task {
            await model.home.refresh(model.api, force: true)
            // 等 WidgetProbe 把最新的写进去（只改文字的 20 秒内最多写一次）
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if let s = WidgetSnapshot.load(), !s.limits.isEmpty { stored = s; break }
            }
            if stored == nil {
                var test = WidgetSync.snapshot(model)
                test.at = Date().timeIntervalSince1970 * 1000
                let status = test.save()
                probe = "；直接写一次：状态码 \(status)，读回\(WidgetSnapshot.load() == nil ? "失败" : "成功")"
            }
        }
    }

    private func tile(_ content: some View, width: CGFloat, height: CGFloat) -> some View {
        content.padding(16).frame(width: width, height: height)
            .background(WidgetTone.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func lock(_ content: some View, width: CGFloat) -> some View {
        content.frame(width: width, height: 72).foregroundStyle(.white).environment(\.colorScheme, .dark)
    }
}
#endif

/// 世界、数据流的入口：左上图标，下面名字和一句说明
private struct SceneCard<Icon: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            icon().frame(width: 28, height: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
#else
import SwiftUI

// Mac 版也编待办、项目页（共用代码），但没有底部 Tab 栏
extension View {
    func tabBarScrollWatch() -> some View { self }
}
#endif
