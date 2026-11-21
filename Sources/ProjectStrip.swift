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

    /// 点 × 关掉：不再列
    func close(_ id: String) {
        guard opened.contains(id) else { return }
        opened.remove(id)
        AppConfig.defaults.set(Array(opened), forKey: "projectStripOpened")
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

    var body: some View {
        // 按最近活动排（11-21）：最近有动静的在最前；同时间按名字。关掉的不列，当前项目哪怕关过也列
        let items = ordered()
        ScrollViewReader { proxy in
            KiteHScroll {
                HStack(alignment: .top, spacing: 3) {
                    ProjectStripTab(title: L("全部"), symbol: "square.stack", state: .unknown, waiting: 0, active: model.projectPane == nil,
                                    height: height, closable: false, close: {}) { model.projectPane = nil }
                        .help(L("全部会话（不按项目分）"))
                        .id("@all")
                    ForEach(items, id: \.first!.id) { group in
                        let id = group[0].id
                        let live = projects.live(group: group)
                        ProjectStripTab(title: group[0].name, symbol: nil, state: Self.state(live), waiting: live.filter { $0.activity == .waiting }.count,
                                        active: model.projectPane == id, height: height, closable: true,
                                        close: { close(id) }) {
                            model.openProject(id, showList: false)
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
            .onChange(of: model.projectPane, initial: true) { _, id in proxy.scrollTo(id ?? "@all") }
        }
        .frame(height: height, alignment: .top)
        .onAppear { if !projects.loaded { projects.load() } }
    }

    private func ordered() -> [[ProjectItem]] {
        let shown = projects.groups.filter { group in group.contains { state.opened.contains($0.id) } || group[0].id == model.projectPane }
        let keyed: [(group: [ProjectItem], at: Double)] = shown.map { ($0, Self.lastActive($0)) }
        let sorted = keyed.sorted { a, b in
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
        .background(active ? activeFill : Color.primary.opacity(hovering ? 0.1 : 0.05), in: shape)
        // 当前项目整块染主题色，不画顶上那一道（11-21 反馈：单边色条是 AI 样式）
        .overlay { if active { shape.strokeBorder(Color.tarsBrand.opacity(0.5), lineWidth: 1) } }
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}
