import AppKit
import SwiftUI
import KitelineKit

// 新版界面的引导（11-21）：
// 1. 装了带新版界面的版本后，经典界面右上角「新版界面」按钮下面弹一张小卡片，告诉有新界面可以试（只弹一次）；
// 2. 第一次进新版界面，界面上逐个指出：会话、项目和打开项目、待办、收藏、今日动态、用量在哪（看完或跳过就不再出）。
// 各处用 .tourAnchor("名字") 报位置，NewLayoutRoot 外面的 TourOverlay 按位置画高亮框和说明

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// 引导要指到的地方
    func tourAnchor(_ name: String) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [name: $0] }
    }
}

@MainActor
final class NewLayoutTour: ObservableObject {
    static let shared = NewLayoutTour()
    private static let doneKey = "newLayoutTourDone"
    private static let announcedKey = "newLayoutAnnounced"

    struct Step {
        let anchor: String
        let title: String
        let text: String
    }

    static var steps: [Step] { [
        Step(anchor: "rail.sessions", title: L("会话"), text: L("所有电脑上正在运行的会话都在这里，点一个就在中间打开成标签页。")),
        Step(anchor: "rail.projects", title: L("项目"), text: L("按项目看会话、文件和 Git。选中一个项目后，下面列出它的会话，右边是文件侧栏。")),
        Step(anchor: "openProject", title: L("打开项目"), text: L("选择电脑上的文件夹和 Agent，直接在其中开一个会话。")),
        Step(anchor: "rail.todos", title: L("待办"), text: L("只有你能做的事（注册账号、申请密钥……）和 Agent 记下的后续工作。")),
        Step(anchor: "rail.favorites", title: L("收藏"), text: L("在对话中右键一条消息「加入收藏」，常用的地址、密码说明都能在这里找到。")),
        Step(anchor: "rail.today", title: L("今日动态"), text: L("今天每个项目做了什么、改了哪些文件、跑了几次测试，弹窗查看。")),
        Step(anchor: "status.usage", title: L("用量"), text: L("今天用了多少 token、各台电脑的订阅额度还剩多少；点一下看完整的用量报表。")),
        Step(anchor: "layoutSwitch", title: L("随时切回"), text: L("不习惯的话，点这里回到经典界面；之后也能再切回来。")),
    ] }

    @Published var index: Int?
    /// 经典界面里那张「有新界面」的卡片
    @Published var announcing = false

    private init() {
        announcing = !AppConfig.defaults.bool(forKey: Self.announcedKey) && !AppConfig.defaults.bool(forKey: "newLayout") && !ARMode.capturing
    }

    /// 进了新版界面：没看过引导就从第一步开始（布局设置弹着时等它关了再开始）
    func startIfNeeded() {
        guard index == nil, !AppConfig.defaults.bool(forKey: Self.doneKey) else { return }
        // 测试实例按脚本截图时不自己弹（会盖住要截的界面）；要看引导用自测步骤 tour
        if ARMode.capturing { return }
        index = 0
    }

    func next() {
        guard let index else { return }
        if index + 1 < Self.steps.count { self.index = index + 1 } else { finish() }
    }

    func finish() {
        index = nil
        AppConfig.defaults.set(true, forKey: Self.doneKey)
    }

    /// 设置里「重新看一遍新版界面引导」
    func replay() {
        AppConfig.defaults.set(false, forKey: Self.doneKey)
        index = 0
    }

    func dismissAnnouncement() {
        announcing = false
        AppConfig.defaults.set(true, forKey: Self.announcedKey)
    }
}

/// 盖在新版界面上的引导：其余地方压暗，指到的那一处留亮框，旁边一张说明卡（上一步 / 下一步 / 跳过）
struct TourOverlay: KLView {
    let anchors: [String: Anchor<CGRect>]
    @ObservedObject private var tour = NewLayoutTour.shared
    @ObservedObject private var model = KitelineModel.shared

    var klBody: some View {
        GeometryReader { geo in
            if let index = tour.index, !model.showLayoutSetup {
                let steps = NewLayoutTour.steps
                let step = steps[index]
                if let anchor = anchors[step.anchor] {
                    let rect = geo[anchor].insetBy(dx: -4, dy: -4)
                    ZStack(alignment: .topLeading) {
                        // 压暗，亮框那一块挖空
                        Rectangle().fill(Color.black.opacity(0.45))
                            .reverseMask { RoundedRectangle(cornerRadius: 8, style: .continuous).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY) }
                            .contentShape(Rectangle())
                            .onTapGesture { tour.next() }
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.tarsBrand, lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                        card(step, index: index, count: steps.count)
                            .frame(width: 280)
                            .fixedSize(horizontal: false, vertical: true)
                            .position(cardCenter(rect, in: geo.size))
                    }
                    .animation(.klSnappy(duration: 0.25), value: index)
                } else {
                    // 这一处现在看不到（比如没选项目时没有「打开项目」以外的东西）：跳过
                    Color.clear.onAppear { tour.next() }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { if model.newLayout { tour.startIfNeeded() } }
        .klOnChange(of: model.newLayout) { _, on in if on { tour.startIfNeeded() } }
    }

    /// 卡片放在亮框右边；右边放不下放左边；上下夹在窗口里
    private func cardCenter(_ rect: CGRect, in size: CGSize) -> CGPoint {
        let width: CGFloat = 280, height: CGFloat = 150, gap: CGFloat = 14
        var x = rect.maxX + gap + width / 2
        if x + width / 2 > size.width - 8 { x = rect.minX - gap - width / 2 }
        if x - width / 2 < 8 { x = min(max(rect.midX, width / 2 + 8), size.width - width / 2 - 8) }
        var y = rect.midY
        if rect.midY > size.height - 120 { y = rect.minY - gap - height / 2 }
        y = min(max(y, height / 2 + 8), size.height - height / 2 - 8)
        return CGPoint(x: x, y: y)
    }

    private func card(_ step: NewLayoutTour.Step, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step.title).font(.app(size: 14, weight: .semibold))
                Spacer()
                Text("\(index + 1) / \(count)").font(.app(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(step.text).font(.app(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: KiteMetric.gap) {
                Button(L("跳过")) { tour.finish() }.kiteButton()
                Spacer()
                if index > 0 { Button(L("上一步")) { tour.index = index - 1 }.kiteButton() }
                Button(index + 1 < count ? L("下一步") : L("开始使用")) { tour.next() }.kiteButton(prominent: true)
            }
            .padding(.top, 4)
        }
        .padding(DialogMetric.pad)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
    }
}

/// 经典界面右上角「新版界面」按钮下面的小卡片：装了新版本后告诉一声（只出一次）
struct NewLayoutAnnouncement: KLView {
    @ObservedObject private var tour = NewLayoutTour.shared
    @ObservedObject private var model = KitelineModel.shared

    var klBody: some View {
        if tour.announcing, !model.newLayout {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("新版界面上线了"), systemImage: "sparkles").font(.app(size: 13, weight: .semibold))
                Text(L("左侧图标栏切换会话、项目、待办、收藏；项目的会话、文件和 Git 集中在一栏；底部状态栏随时看用量。可随时切回经典界面。"))
                    .font(.app(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: KiteMetric.gap) {
                    Spacer()
                    Button(L("以后再说")) { tour.dismissAnnouncement() }.kiteButton()
                    Button(L("试试新版界面")) {
                        tour.dismissAnnouncement()
                        model.newLayout = true
                        if model.askLayoutOnSwitch { model.showLayoutSetup = true }
                    }
                    .kiteButton(prominent: true)
                }
                .padding(.top, 2)
            }
            .padding(DialogMetric.pad)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
            .padding(.top, TitlebarInset.band + 4)
            .padding(.trailing, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

private extension View {
    /// 挖空：mask 里画的形状那一块不显示
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle().overlay { mask().blendMode(.destinationOut) }.compositingGroup()
        }
    }
}
