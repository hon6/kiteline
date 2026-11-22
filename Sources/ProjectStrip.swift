import AppKit
import SwiftUI
import KitelineKit

// 顶上那排项目（Mac 新版界面，11-20 反馈：上面的会话组变成项目，点了快速切换项目；展示所有项目，除非用户关掉）。
// 倒挂在窗口顶边、横跨整个分屏（ChatPanes 的 groupStrip 位置，原来是会话组那一排）。最前面「全部」= 不选项目那一套；
// 只列用户打开过的项目（11-21），每个一格：文件夹（有会话等确认是橙色、在忙是主题色）、名字、等确认的数；指着出现 ×，关掉后不再列（再打开那个项目时自动回来）。
// 点一格 = 切到那个项目：中间的标签整套换成它的（ProjectSpaces），项目栏显示它的会话和文件

@MainActor
final class ProjectStripState: ObservableObject {
    static let shared = ProjectStripState()
    /// 用户打开过的项目（项目的 id），存在偏好里：顶上那排只列这些（11-21 反馈：自己打开的项目才显示，原来列出全部项目）
    @Published private(set) var opened: Set<String> = Set(AppConfig.defaults.stringArray(forKey: "projectStripOpened") ?? [])
    /// 顶上那排的先后（项目的 id）：同浏览器标签，排好就不动，新打开的排最后（11-22 反馈：顺序不要来回变；原来按最近活动排，
    /// 哪个项目一有动静就跳到前面，点的时候它还在挪）。头一次没有记录时按当时的最近活动排一次，之后固定
    @Published private(set) var order: [String] = AppConfig.defaults.stringArray(forKey: "projectStripOrder") ?? []

    /// 这一排里有、但还没排过位置的项目：按传进来的先后接到最后（显示前调；已经排过的不动）
    func adopt(_ ids: [String]) {
        let missing = ids.filter { !order.contains($0) }
        guard !missing.isEmpty else { return }
        order += missing
        AppConfig.defaults.set(order, forKey: "projectStripOrder")
    }

    /// 点 × 关掉：不再列
    func close(_ id: String) {
        guard opened.contains(id) else { return }
        opened.remove(id)
        AppConfig.defaults.set(Array(opened), forKey: "projectStripOpened")
        // 关掉的也从顺序里拿掉：再打开时排到最后（同浏览器重新打开的标签）
        order.removeAll { $0 == id }
        AppConfig.defaults.set(order, forKey: "projectStripOrder")
    }

    /// 打开了这个项目（项目列表里点它、打开项目、跳到它的会话）：放进顶上那排
    func reopen(_ id: String) {
        guard !opened.contains(id) else { return }
        opened.insert(id)
        AppConfig.defaults.set(Array(opened), forKey: "projectStripOpened")
    }

    static func install() {
        KitelineKit.projectStrip = { height in AnyView(ProjectStrip(height: height)) }
        // 分屏「选择会话」：新版界面开着项目时只列这个项目的会话
        KitelineKit.pickerKeeps = { key in
            MainActor.assumeIsolated {
                let model = KitelineModel.shared
                guard model.newLayout, let project = model.projectPane else { return true }
                return model.projectID(of: key) == project
            }
        }
    }
}

struct ProjectStrip: View {
    let height: CGFloat
    @ObservedObject private var model = KitelineModel.shared
    @ObservedObject private var projects = ProjectsModel.shared
    @ObservedObject private var state = ProjectStripState.shared
    /// 亮着的是哪一格（"@all" = 全部）：点下去马上换、高亮滑过去，真正切项目（整套标签换掉）放到下一帧，
    /// 不然要等那边换完界面才动，看着像没点上（11-22 反馈：点了反应慢、要点好几次）
    @State private var lit = "@all"
    @Namespace private var glide

    var body: some View {
        // 固定顺序（同浏览器标签，见 ProjectStripState.order）；关掉的不列，当前项目哪怕关过也列
        let items = ordered()
        ScrollViewReader { proxy in
            KiteHScroll {
                HStack(alignment: .top, spacing: 3) {
                    ProjectStripTab(title: L("全部"), symbol: "square.stack", state: .unknown, waiting: 0, active: lit == "@all",
                                    height: height, closable: false, glide: glide, close: {}) { pick(nil) }
                        .help(L("全部会话（不按项目分）"))
                        .id("@all")
                    ForEach(items, id: \.first!.id) { group in
                        let id = group[0].id
                        let live = projects.live(group: group)
                        ProjectStripTab(title: group[0].name, symbol: nil, state: Self.state(live), waiting: live.filter { $0.activity == .waiting }.count,
                                        active: lit == id, height: height, closable: true, glide: glide,
                                        close: { close(id) }) {
                            pick(id)
                        }
                        .help(group.count > 1 ? group[0].name + " · " + group.map(\.sourceName).joined(separator: " · ") : group[0].name + " · " + group[0].sourceName)
                        .contextMenu {
                            Button("关闭") { close(id) }
                            Button("关闭其他项目") { for other in items where other[0].id != id { close(other[0].id) } }
                            Divider()
                            Button("在此项目中新建会话") { newSession(group) }
                        }
                        .id(id)
                    }
                    Button { model.showOpenProject = true } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 24, height: height - 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("打开项目…"))
                }
            }
            .onChange(of: model.projectPane, initial: true) { _, id in
                // 别处切的项目（项目列表、跳到别的项目的会话……）：高亮跟过去
                let target = id ?? "@all"
                if lit != target { withAnimation(.snappy(duration: 0.28)) { lit = target } }
                proxy.scrollTo(target)
            }
            // 新出现的项目接到最后，排过的位置不再变
            .onChange(of: items.map { $0[0].id }, initial: true) { _, ids in state.adopt(ids) }
        }
        .frame(height: height, alignment: .top)
        .onAppear { if !projects.loaded { projects.load() } }
    }

    /// 点了一格：高亮先滑过去，下一帧再切（切项目要整套换标签、开对话，同步做完才刷新界面）
    private func pick(_ id: String?) {
        let target = id ?? "@all"
        guard lit != target || id != model.projectPane else { return }
        withAnimation(.snappy(duration: 0.28)) { lit = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard lit == target else { return }   // 这期间又点了别的：以最后点的为准
            if let id { model.openProject(id, showList: false) } else { model.projectPane = nil }
        }
    }

    private func ordered() -> [[ProjectItem]] {
        let shown = projects.groups.filter { group in group.contains { state.opened.contains($0.id) } || group[0].id == model.projectPane }
        let rank = Dictionary(state.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // 排过的按记下的先后；还没排过的（头一次、刚打开的）先按最近活动接在后面，随后 adopt 记下来就固定了
        let keyed: [(group: [ProjectItem], rank: Int, at: Double)] = shown.map { ($0, rank[$0[0].id] ?? Int.max, Self.lastActive($0)) }
        let sorted = keyed.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.at != b.at { return a.at > b.at }
            return a.group[0].name.localizedStandardCompare(b.group[0].name) == .orderedAscending
        }
        return sorted.map(\.group)
    }

    /// 这个项目最近一次活动（毫秒）：项目记录的时间和正在跑的会话最新动静，取最新的
    private static func lastActive(_ group: [ProjectItem]) -> Double {
        let recorded = group.map(\.lastActive).max() ?? 0
        let live = ProjectsModel.shared.live(group: group).compactMap(\.updatedAt).max() ?? 0
        return max(recorded, live)
    }

    static func state(_ live: [SessionItem]) -> Activity {
        if live.contains(where: { $0.activity == .waiting }) { return .waiting }
        if live.contains(where: { $0.activity == .busy }) { return .busy }
        return live.isEmpty ? .unknown : .idle
    }

    /// 关掉一个项目：不再列；正显示的就是它的话切到旁边那个（没有就「全部」），它那一套标签扔掉
    private func close(_ id: String) {
        state.close(id)
        if model.projectPane == id {
            let rest = projects.groups.map { $0[0].id }.filter { state.opened.contains($0) }
            model.projectPane = rest.first
        }
        KitelineKit.projectSpaces.forget(id)
    }

    private func newSession(_ group: [ProjectItem]) {
        let member = group.first { !projects.live($0).isEmpty } ?? group[0]
        model.openProject(group[0].id, showList: false)
        model.selection = NewDraftKey.make(.init(sourceId: member.sourceId, cwd: member.cwd,
                                                 agent: projects.live(member).first?.agent ?? "claude-code"))
    }
}

/// 顶上那排的一格：倒挂（上沿贴窗口顶、下面两角圆）；当前项目底亮一档、顶上一道强调色；指着出现 ×
private struct ProjectStripTab: View {
    let title: String
    let symbol: String?
    let state: Activity
    let waiting: Int
    let active: Bool
    let height: CGFloat
    let closable: Bool
    /// 当前项目那块高亮在各格之间滑动（matchedGeometryEffect）
    let glide: Namespace.ID
    let close: () -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 0, style: .continuous)
        let scheme = Look.shared.scheme
        let activeFill = Color.tarsBrand.opacity(0.18)   // 当前项目整块染主题色（11-21）
        HStack(spacing: SideMetric.gap - 1) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            } else {
                ProjectFolderMark(state: state, size: 10.5)
            }
            Text(title).font(.app(size: SideMetric.Text.row, weight: active ? .semibold : .medium)).lineLimit(1)
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .frame(maxWidth: 140, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if waiting > 0 {
                Text("\(waiting)").font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                    .background(Color.tarsOrange, in: Capsule())
            }
            if closable {
                // × 一直占着位置，只在指着 / 当前项目时显示（指着时不改宽度，见侧栏转盘那次的教训）
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || active ? 1 : 0)
                .allowsHitTesting(hovering || active)
                .help(L("关闭（不在这一排显示，打开这个项目时会回来）"))
            }
        }
        .padding(.leading, SideMetric.pad).padding(.trailing, closable ? 4 : SideMetric.pad)
        .frame(height: height - 3)
        .background(Color.primary.opacity(hovering && !active ? 0.1 : 0.05), in: shape)
        // 当前项目整块染主题色，不画顶上那一道（11-21 反馈：单边色条是 AI 样式）；点别的项目时这块从原来那格滑过去
        .background {
            if active {
                shape.fill(activeFill)
                    .overlay { shape.strokeBorder(Color.tarsBrand.opacity(0.5), lineWidth: 1) }
                    .matchedGeometryEffect(id: "projectStripActive", in: glide)
            }
        }
        // 不裁成格子的形状：高亮滑动时要能画到格子外面（滑的路上）
        .contentShape(shape)
        .onTapGesture(perform: action)
        .onHover { on in
            // 指着时窗口拖不动（同会话标签的 TabWindowLock）：不然按下去先被系统当成拖窗口，要点好几次
            if hovering != on { TabWindowLock.hold(on) }
            hovering = on
        }
        .onDisappear { if hovering { TabWindowLock.hold(false); hovering = false } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}
