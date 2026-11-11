import SwiftUI

// 标签组在各端共用的部分：一组的状态摘要、角标、颜色、首页三个页签、改版引导卡；
// iPhone / iPad 的「标签组」页签和组页（点开一组看组里的会话，一次看一个）。Mac 的多列切换在 TabGroups.swift

// MARK: 一组的状态摘要（侧栏一行、快捷键找该看的）

struct TabGroupDigest {
    var total = 0
    var waiting: [String] = []
    var failed: [String] = []
    var busy: [String] = []
    var unread: [String] = []
    var ended = 0

    @MainActor
    init(keys: [String], model: AppModel) {
        total = keys.count
        for key in keys {
            guard GroupKey.id(key) == nil else { continue }
            guard let session = model.session(key) else { ended += 1; continue }
            if session.error != nil { failed.append(key) }
            else if session.isWaiting { waiting.append(key) }
            else if session.isBusy { busy.append(key) }
            if model.isUnread(session) { unread.append(key) }
        }
    }

    /// 要不要提醒你看一眼：有待确认的、出错的、有新消息的
    var needsLook: Bool { !waiting.isEmpty || !failed.isEmpty || !unread.isEmpty }

    /// 第二行小字：最要紧的那件事
    @MainActor
    func summary(_ title: (String) -> String) -> String {
        if let key = waiting.first { return L("待确认：%@", title(key)) }
        if let key = failed.first { return L("出错：%@", title(key)) }
        if let key = unread.first, busy.isEmpty { return L("有新消息：%@", title(key)) }
        if !busy.isEmpty { return unread.isEmpty ? L("%lld 个在工作", count: busy.count) : L("%lld 个在工作 · %lld 个有新消息", busy.count, unread.count) }
        if total == 0 { return L("还没有会话") }
        if ended == total { return L("都已结束") }
        return L("空闲")
    }

    var summaryColor: Color {
        if !waiting.isEmpty { return .orange }
        if !failed.isEmpty { return Theme.removed }
        return .secondary
    }
}

/// 角标：实心底白字的小胶囊（数字或一两个字）
struct TabGroupBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.app(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
            .background(color, in: Capsule())
            .fixedSize()
    }
}

/// 右边的角标：待确认的会话数（橙），有新消息的会话数（主题色）
struct TabGroupBadges: View {
    let digest: TabGroupDigest

    var body: some View {
        HStack(spacing: 4) {
            if !digest.waiting.isEmpty {
                TabGroupBadge(text: "\(digest.waiting.count)", color: .orange)
                    .accessibilityLabel(L("%lld 个会话等你确认", count: digest.waiting.count))
            }
            if !digest.unread.isEmpty {
                TabGroupBadge(text: "\(digest.unread.count)", color: Theme.claude)
                    .accessibilityLabel(L("%lld 个会话有新消息", count: digest.unread.count))
            }
        }
    }
}

// MARK: 颜色

extension TabGroupPalette {
    /// 浅色外观、深色外观的色值（同 Edge / Chrome 的标签组）
    private static let hex: [String: (UInt32, UInt32)] = [
        "grey": (0x5F6368, 0xBDC1C6), "blue": (0x1A73E8, 0x8AB4F8), "red": (0xD93025, 0xF28B82),
        "yellow": (0xE8A200, 0xFDD663), "green": (0x188038, 0x81C995), "pink": (0xD01884, 0xFF8BCB),
        "purple": (0xA142F4, 0xC58AF9), "cyan": (0x007B83, 0x78D9EC), "orange": (0xFA903E, 0xFCAD70),
    ]

    static func color(_ id: String?) -> Color {
        let pair = hex[id ?? "grey"] ?? hex["grey"]!
        return Theme.dynamic(light: pair.0, dark: pair.1)
    }

    static func title(_ id: String) -> String {
        ["grey": L("灰色"), "blue": L("蓝色"), "red": L("红色"), "yellow": L("黄色"), "green": L("绿色"),
         "pink": L("粉色"), "purple": L("紫色"), "cyan": L("青色"), "orange": L("橙色")][id] ?? id
    }
}

/// 一排九个色点（新建、编辑标签组用）：选中的外面一圈加对号
struct TabGroupColorDots: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(TabGroupPalette.all, id: \.self) { id in
                let on = selection == id
                let color = TabGroupPalette.color(id)
                Button {
                    Haptics.tap()
                    selection = id
                } label: {
                    Circle().fill(color).frame(width: 22, height: 22)
                        .padding(3)
                        .overlay { Circle().strokeBorder(on ? color : .clear, lineWidth: 2) }
                        .overlay { if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TabGroupPalette.title(id))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: 首页的页签和引导

/// 「会话 9 | 群 1 | 标签组 2」：选中的字加粗、下面一条主题色短线；alert = 右上角橙点（里面有等你确认的）
struct ListTabs: View {
    struct Tab {
        let id: String
        let title: String
        let count: Int
        var alert = false
    }

    @Binding var selection: String
    let tabs: [Tab]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(tabs, id: \.id) { tab in
                let on = selection == tab.id
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { selection = tab.id }
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.title).font(.ui(.headline).weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                        Text("\(tab.count)").font(.ui(.subheadline).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Capsule().fill(on ? Theme.claude : .clear).frame(height: 2.5) }
                    .overlay(alignment: .topTrailing) {
                        if tab.alert { Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: 6, y: 3) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

/// 设备、项目筛选收起成的一行：「🖥 全部设备 · 📁 ccpulse ⌄」，筛着的那项用主题色；点了展开 / 收起两排胶囊
struct ScopeSummary: View {
    let source: String?
    let project: String?
    let narrowedSource: Bool
    let narrowedProject: Bool
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let narrowed = narrowedSource || narrowedProject
        Button(action: toggle) {
            HStack(spacing: 6) {
                if let source {
                    Image(systemName: "desktopcomputer").font(.app(size: 12, weight: .semibold))
                    Text(source).lineLimit(1).foregroundStyle(narrowedSource ? Theme.claude : Color.primary)
                }
                if source != nil && project != nil { Text("·").foregroundStyle(.tertiary) }
                if let project {
                    Image(systemName: "folder").font(.app(size: 12, weight: .semibold))
                    Text(project).lineLimit(1).truncationMode(.middle).foregroundStyle(narrowedProject ? Theme.claude : Color.primary)
                }
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.app(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .font(.ui(.footnote).weight(.semibold))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(narrowed ? Theme.claude.opacity(0.12) : Color.primary.opacity(0.06), in: Capsule(style: .circular))
            .overlay { if narrowed { Capsule(style: .circular).strokeBorder(Theme.claude.opacity(0.3), lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(open ? L("收起设备、项目筛选") : L("按设备、项目筛选会话"))
    }
}

/// 改版后第一次看到会话列表时的说明卡（11-10）：会话列表去哪了、会话 / 群 / 标签组有什么不同、标签组怎么用。点「知道了」以后不再出现
public struct ListTabsGuide: View {
    @AppStorage("guide.listTabs") private var seen = false
    let showTabGroups: () -> Void
    let groups: Bool

    public init(groups: Bool, showTabGroups: @escaping () -> Void) {
        self.groups = groups
        self.showTabGroups = showTabGroups
    }

    public var body: some View {
        if !seen {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.claude)
                    Text("会话列表有新的排法").font(.app(size: 14, weight: .semibold))
                    Spacer(minLength: 4)
                    Button { withAnimation(.snappy) { seen = true } } label: {
                        Image(systemName: "xmark").font(.app(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("关闭"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    line("bubble.left.and.bubble.right", L("会话"), L("所有运行中的会话，筛选和显示方式都在这里；设备、项目收成一行，点开再选。"))
                    if groups { line("person.2", L("群"), L("把几个会话拉到一起互相沟通，建群在这里。")) }
                    line("square.stack", L("会话组"), Self.tabGroupLine)
                }
                HStack(spacing: 10) {
                    Button(L("看看会话组")) {
                        withAnimation(.snappy) { seen = true }
                        showTabGroups()
                    }
                    .font(.app(size: 13, weight: .semibold)).foregroundStyle(Theme.claude)
                    Button(L("知道了")) { withAnimation(.snappy) { seen = true } }
                        .font(.app(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Theme.claude.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.claude.opacity(0.22), lineWidth: 1) }
        }
    }

    private static var tabGroupLine: String {
        #if KITELINE_MAC
        L("把同一阶段的相关会话放一组，切到哪组右边就多列显示哪组；组名和颜色可以改，还能一键把组里的会话拉成群，手机上也能看到。")
        #else
        L("把同一阶段的相关会话放一组，点开一组看组里的会话，一次看一个；组名和颜色可以改，还能一键把组里的会话拉成群，电脑上也能看到。")
        #endif
    }

    private func line(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.app(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
            (Text(title).fontWeight(.semibold) + Text("　") + Text(text).foregroundStyle(.secondary))
                // Mac 侧栏列表里的文字默认只排一行（后面省略号），这里要整段换行看全
                .font(.app(size: 12.5)).lineLimit(nil).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if !KITELINE_MAC
// MARK: iPhone / iPad：「标签组」页签和组页

/// 新建 / 编辑 / 往组里加会话的面板（首页、组页、会话长按都弹它）
struct TabGroupSheet: Identifiable {
    enum Mode: Hashable {
        case create([String])
        case edit(String)
        case add(String)
    }

    let mode: Mode
    var id: String {
        switch mode {
        case .create(let keys): "create:" + keys.joined(separator: ",")
        case .edit(let id): "edit:" + id
        case .add(let id): "add:" + id
        }
    }
}

/// 首页「标签组」页签里的一组：颜色小方块、组名、会话数，右边角标；第二行小字说最要紧的那件事。点开进组页
struct TabGroupPhoneRow: View {
    let group: SharedTabGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        let digest = TabGroupDigest(keys: group.keys, model: model)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(TabGroupPalette.color(group.color).opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(TabGroupPalette.color(group.color)).frame(width: 16, height: 16)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(group.name).font(.app(size: 17)).lineLimit(1)
                    Text("\(group.keys.count)").font(.ui(.subheadline).monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    TabGroupBadges(digest: digest)
                }
                Text(digest.summary { model.session($0)?.title ?? L("已结束的会话") })
                    .font(.ui(.subheadline)).foregroundStyle(digest.summaryColor).lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// 一个标签组：组里的会话（和首页一样的卡片，正在工作的有动画、有新消息的有角标），点了照常打开对话页（一次看一个）
struct TabGroupPage: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @Environment(\.listSelection) private var selection
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: TabGroupSheet?
    @State private var deleting = false

    var body: some View {
        let shared = model.tabGroupShared
        if let group = shared.group(id) {
            List {
                Section {
                    ForEach(group.keys, id: \.self) { key in
                        row(key, in: group)
                    }
                    .onMove { from, to in
                        shared.update(id) { $0.keys.move(fromOffsets: from, toOffset: to) }
                    }
                } footer: {
                    if group.keys.isEmpty {
                        Text("这一组还没有会话。点右上角「添加会话」，或在首页长按会话选「添加到会话组」。")
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .navigationTitle(group.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(TabGroupPalette.color(group.color)).frame(width: 10, height: 10)
                        Text(group.name).font(.ui(.headline)).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { sheet = TabGroupSheet(mode: .add(id)) } label: { Label("添加会话", systemImage: "plus") }
                        Button { sheet = TabGroupSheet(mode: .edit(id)) } label: { Label("编辑名称和颜色", systemImage: "pencil") }
                        if model.supportsGroups {
                            Button { groupChat(group) } label: { Label("把组里的会话拉成群", systemImage: "person.2.badge.plus") }
                        }
                        Button(role: .destructive) { deleting = true } label: { Label("删除会话组", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(L("会话组操作"))
                }
            }
            .sheetPanel(item: $sheet) { TabGroupEditor(mode: $0.mode).environment(model) }
            .confirmPanel(L("删除这个会话组？组里的会话不会关闭，仍在会话列表里。"), isPresented: $deleting, confirm: L("删除会话组"), destructive: true) {
                shared.delete(id)
                dismiss()
            }
        } else {
            ContentUnavailableView(L("会话组已删除"), systemImage: "square.stack")
        }
    }

    private func groupChat(_ group: SharedTabGroup) {
        Task { if let chat = await model.groupChat(fromTabGroup: group.keys, name: group.name) { open(.group(chat)) } }
    }

    @ViewBuilder
    private func row(_ key: String, in group: SharedTabGroup) -> some View {
        let shared = model.tabGroupShared
        if let session = model.session(key) {
            ZStack {
                if selection.split {
                    Button { open(.chat(key)) } label: { SessionRow(session: session).contentShape(Rectangle()) }
                        .buttonStyle(RowButtonStyle())
                } else {
                    NavigationLink(value: Route.chat(key)) { EmptyView() }.opacity(0)
                    SessionRow(session: session)
                }
            }
            .listRowBackground(selection.split && selection.key == key ? Theme.claude.opacity(0.14) : Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .swipeActions(edge: .trailing) {
                Button { shared.remove(key, from: id) } label: { Text("移出") }.tint(Theme.removed)
            }
            .contextMenu {
                Button(role: .destructive) { shared.remove(key, from: id) } label: { Label("从会话组移除", systemImage: "minus.circle") }
            }
        } else {
            // 会话已经关了：留一行说明，右滑移出（电脑上重开同一个会话时它又会回来）
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz").frame(width: 44, height: 44).foregroundStyle(.tertiary)
                Text("会话已结束").font(.ui(.subheadline)).foregroundStyle(.secondary)
                Spacer()
                Button(L("移出")) { shared.remove(key, from: id) }.font(.ui(.subheadline)).buttonStyle(.plain).foregroundStyle(Theme.removed)
            }
            .padding(.vertical, 10)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }
}

/// 新建（组名、颜色、勾会话）/ 编辑（组名、颜色）/ 往组里加会话（勾会话）
struct TabGroupEditor: View {
    let mode: TabGroupSheet.Mode
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @PanelDismiss private var dismiss
    @State private var name = ""
    @State private var color = ""
    @State private var picked: [String] = []
    @State private var query = ""
    @State private var ready = false

    private var editing: String? { if case .edit(let id) = mode { id } else { nil } }
    private var adding: String? { if case .add(let id) = mode { id } else { nil } }
    private var existing: Set<String> { Set(adding.flatMap { model.tabGroupShared.group($0)?.keys } ?? []) }

    var body: some View {
        FitSheet(title: title, cancel: true) {
            VStack(alignment: .leading, spacing: 14) {
                if adding == nil {
                    if editing == nil {
                        Text("把同一阶段的相关会话放一组，以后点开这一组就能接着看。组名和颜色在电脑上也能看到。")
                            .font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                    TextField(editing == nil ? L("组名（可不填，按项目自动起名）") : L("组名"), text: $name)
                        .textFieldStyle(.plain).font(.ui(.body))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    TabGroupColorDots(selection: $color)
                }
                if editing == nil { picker }
            }
        } bottom: {
            Button(action: commit) {
                Text(buttonTitle).font(.ui(.body).weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Theme.claude.opacity(canCommit ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .disabled(!canCommit)
            .keyboardShortcut(.defaultAction)
        }
        .onAppear(perform: prepare)
    }

    private var title: String {
        if let editing { return L("编辑「%@」", model.tabGroupShared.group(editing)?.name ?? "") }
        if let adding { return L("添加会话到「%@」", model.tabGroupShared.group(adding)?.name ?? "") }
        return L("新建会话组")
    }

    private func prepare() {
        guard !ready else { return }
        ready = true
        switch mode {
        case .create(let keys):
            picked = keys
            color = model.tabGroupShared.nextColor
        case .edit(let id):
            let group = model.tabGroupShared.group(id)
            name = group?.name ?? ""
            color = group?.color ?? "grey"
        case .add:
            break
        }
    }

    private var fresh: [String] { picked.filter { !existing.contains($0) } }

    private var canCommit: Bool {
        if editing != nil { return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !fresh.isEmpty
    }

    private var buttonTitle: String {
        if editing != nil { return L("保存") }
        if fresh.isEmpty { return L("请选择会话") }
        return adding == nil ? L("新建会话组（%lld 个会话）", count: fresh.count) : L("添加 %lld 个会话", count: fresh.count)
    }

    /// 勾会话：按勾的先后排进组里
    private var picker: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = model.sessions.filter { s in
            q.isEmpty || s.title.localizedCaseInsensitiveContains(q) || (s.cwd ?? "").localizedCaseInsensitiveContains(q)
        }
        return VStack(alignment: .leading, spacing: 8) {
            if model.sessions.count > 6 {
                TextField(L("搜索会话"), text: $query)
                    .textFieldStyle(.plain).font(.ui(.subheadline))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(spacing: 0) {
                if shown.isEmpty {
                    Text(model.sessions.isEmpty ? L("没有运行中的会话") : L("没有符合筛选条件的会话"))
                        .font(.ui(.footnote)).foregroundStyle(.secondary).padding(12)
                }
                ForEach(shown) { session in
                    let inside = existing.contains(session.key)
                    let on = inside || picked.contains(session.key)
                    Button {
                        guard !inside else { return }
                        Haptics.tap()
                        if let index = picked.firstIndex(of: session.key) { picked.remove(at: index) } else { picked.append(session.key) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.app(size: 20)).foregroundStyle(on ? Theme.claude : Color.secondary.opacity(0.5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.ui(.subheadline)).lineLimit(1)
                                Text(inside ? L("已在组里") : [session.sourceName, session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .opacity(inside ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    if session.key != shown.last?.key { Divider().padding(.leading, 42) }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func commit() {
        guard canCommit else { return }
        let shared = model.tabGroupShared
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .edit(let id):
            shared.update(id) { group in
                group.name = clean
                group.color = color
            }
        case .add(let id):
            shared.add(fresh, to: id)
        case .create:
            let id = shared.create(name: clean.isEmpty ? shared.suggestedName(for: fresh, sessions: model.sessions) : clean, color: color, keys: fresh)
            dismiss()
            open(.tabGroup(id))
            return
        }
        dismiss()
    }
}

/// 会话长按菜单里的「添加到标签组 ▸」：各组（已在组里的打勾，点了移出）、新建标签组
struct TabGroupSessionMenu: View {
    let key: String
    let create: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let shared = model.tabGroupShared
        if shared.supported {
            Menu {
                ForEach(shared.items) { group in
                    let inside = group.keys.contains(key)
                    Button {
                        if inside { shared.remove(key, from: group.id) } else { shared.add([key], to: group.id) }
                    } label: {
                        if inside { Label(group.name, systemImage: "checkmark") } else { Text(group.name) }
                    }
                }
                if !shared.items.isEmpty { Divider() }
                Button(action: create) { Label("新建会话组…", systemImage: "plus") }
            } label: {
                Label("添加到会话组", systemImage: "square.stack")
            }
        }
    }
}
#endif
