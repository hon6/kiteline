#if KITELINE_MAC
import SwiftUI
import UniformTypeIdentifiers

// MARK: 标签组（Mac 主窗口，11-10 起）

/// 标签组：一个阶段的几个会话放成一组，切到这组时组里的会话多列摆出来（同 Safari / Chrome 的标签组、VS Code 的工作集：存的是整套分屏——
/// 怎么分的列、每列开着哪些标签、比例、当前列），切到别的组再切回来还是原样。不在任何组里的那套叫「未分组的标签页」（同 Safari「N 个标签页」）。
///
/// 省资源（用户：标签多了卡、要省系统资源）：只有当前这组画在屏幕上，别的组只是一份存着的布局（几百字节），不建视图、不连对话；
/// 切走的会话过 10 分钟把已加载的消息放掉（AppModel.scheduleSleep，同浏览器休眠后台标签）。侧栏每组一行只看各会话的状态点、待确认、新消息。
/// 放掉的只是 Kiteline 里显示用的消息：agent 在 VS Code / 终端里照常跑，状态、推送、确认、群转发都走电脑推来的状态和后台，不受影响（11-10 反馈过）
@Observable @MainActor
public final class TabGroups {
    struct Group: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        /// 切走时存下的整套分屏（ChatPanes.layout）；正显示的那组以 ChatPanes 为准
        var layout: Data?
        /// 组里的会话（切走时记下；正显示的那组以 ChatPanes.keys 为准）
        var keys: [String]
        /// 侧栏里展开着列出组里的会话（默认收起：用户多半只要一行状态，同 Chrome 收起的组）
        var expanded: Bool = false
        /// 组的颜色（TabGroupColor 的 id，同 Edge 九种）：侧栏那一行、分屏标签栏上标出来，一眼认出是哪组。老数据没有就按先后轮一个
        var color: String?
    }

    private struct Stored: Codable {
        var groups: [Group]
        var active: UUID?
        var loose: Data?
        var looseKeys: [String]
    }

    let panes: ChatPanes
    private(set) var groups: [Group] = []
    /// 正显示的组（nil = 未分组的标签页）
    private(set) var active: UUID?
    /// 有组正显示时，未分组的那套存在这
    private var loose: Data?
    private var looseKeys: [String] = []
    @ObservationIgnored private var store: (defaults: UserDefaults, key: String)?

    init(panes: ChatPanes) { self.panes = panes }

    // MARK: 查

    func group(_ id: UUID?) -> Group? { id.flatMap { id in groups.first { $0.id == id } } }

    /// 某组（nil = 未分组）开着哪些会话：正显示的读分屏本身
    func keys(_ id: UUID?) -> [String] {
        if id == active { return panes.keys }
        return id == nil ? looseKeys : group(id)?.keys ?? []
    }

    /// 这个会话在哪几个组里（不算未分组）
    func groups(holding key: String) -> [Group] { groups.filter { keys($0.id).contains(key) } }

    // MARK: 切换

    /// 切到某组（nil = 未分组的标签页）；focus = 切过去后显示组里的这个会话。先把正显示的那套存回它自己的组
    func activate(_ id: UUID?, focus: String? = nil) {
        guard id == nil || group(id) != nil else { return }
        if id != active {
            stash()
            active = id
            panes.load(id == nil ? loose : group(id)?.layout)
            if id == nil { loose = nil; looseKeys = [] }
            panes.save()
            save()
        }
        if let focus { panes.show(focus) }
        // 侧栏、标题、菜单跟着当前块的会话走；空的组不用管（对话页看到当前块变空会把左边栏的选中清掉）
        if let focused = panes.focused { KitelineKit.openSession(focused) }
    }

    /// 正显示的那套存回它自己的组 / 未分组
    private func stash() {
        let layout = panes.layout(), keys = panes.keys
        if let active, let index = groups.firstIndex(where: { $0.id == active }) {
            groups[index].layout = layout
            groups[index].keys = keys
        } else {
            loose = panes.isPristine ? nil : layout
            looseKeys = keys
        }
    }

    /// 上一组 / 下一组（未分组排在最前，同侧栏的顺序）；轮着转
    func step(_ delta: Int) {
        let order: [UUID?] = [nil] + groups.map(\.id)
        guard order.count > 1, let index = order.firstIndex(of: active) else { return }
        activate(order[(index + delta + order.count) % order.count])
    }

    // MARK: 改

    /// 新建一组：keys 每个一列；fromCurrent = 把未分组正开着的这套直接收成一组（同 Safari「用 N 个标签页新建标签组」，不重建视图）
    @discardableResult
    func create(name: String?, keys: [String], fromCurrent: Bool = false, color: String? = nil) -> UUID {
        let id = UUID()
        if fromCurrent, active == nil, !panes.isPristine {
            groups.append(Group(id: id, name: name ?? Self.suggestedName(panes.keys, among: groups), layout: nil, keys: panes.keys, color: color ?? nextColor))
            active = id
            loose = nil
            looseKeys = []
            save()
            return id
        }
        let layout = ChatPanes.edited(nil) { scratch in keys.forEach(scratch.appendColumn) }
        groups.append(Group(id: id, name: name ?? Self.suggestedName(keys, among: groups), layout: layout, keys: keys, color: color ?? nextColor))
        save()
        activate(id)
        return id
    }

    /// 往某组里加会话：在最右边多一列（已经在组里就不动）
    func add(_ keys: [String], to id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        if id == active {
            keys.forEach(panes.appendColumn)
        } else {
            let fresh = keys.filter { !groups[index].keys.contains($0) }
            guard !fresh.isEmpty else { return }
            groups[index].layout = ChatPanes.edited(groups[index].layout) { scratch in fresh.forEach(scratch.appendColumn) }
            groups[index].keys = ChatPanes.keys(in: groups[index].layout)
        }
        save()
    }

    /// 从某组里拿掉这个会话（那一列空了就收掉）
    func remove(_ key: String, from id: UUID?) {
        if id == active {
            panes.close(key: key)
        } else if let id, let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].layout = ChatPanes.edited(groups[index].layout) { $0.close(key: key) }
            groups[index].keys = ChatPanes.keys(in: groups[index].layout)
        } else if id == nil {
            loose = ChatPanes.edited(loose) { $0.close(key: key) }
            looseKeys = ChatPanes.keys(in: loose)
        }
        save()
    }

    /// 正显示的标签挪到别的组（标签右键「移到标签组」）：这边关掉，那边加一列
    func move(_ key: String, to id: UUID) {
        guard id != active else { return }
        panes.close(key: key)
        add([key], to: id)
    }

    func rename(_ id: UUID, _ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
        save()
    }

    func recolor(_ id: UUID, _ color: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].color != color else { return }
        groups[index].color = color
        save()
    }

    /// 某组的颜色：没选过的按它在列表里的位置轮一个（同 Edge 新建时自动给色）
    func color(of id: UUID?) -> TabGroupColor {
        guard let id, let index = groups.firstIndex(where: { $0.id == id }) else { return .grey }
        return TabGroupColor(id: groups[index].color) ?? TabGroupColor.cycle[index % TabGroupColor.cycle.count]
    }

    /// 新建的组给哪个色：先挑还没人用的（同 Edge），都用过了再轮
    var nextColor: String {
        let used = Set(groups.map { color(of: $0.id).id })
        return (TabGroupColor.cycle.first { !used.contains($0.id) } ?? TabGroupColor.cycle[groups.count % TabGroupColor.cycle.count]).id
    }

    func toggleExpanded(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].expanded.toggle()
        save()
    }

    /// 组里每个会话各占一列、平分
    func arrange(_ id: UUID?) {
        if id == active {
            panes.arrangeColumns()
        } else if let id, let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].layout = ChatPanes.edited(groups[index].layout) { $0.arrangeColumns() }
        }
        save()
    }

    /// 删掉一组：只是不要这套布局了，会话本身不关。正显示的那组删了就回到未分组
    func delete(_ id: UUID) {
        if active == id { activate(nil) }
        groups.removeAll { $0.id == id }
        save()
    }

    /// 侧栏里拖着排顺序
    func reorder(_ id: UUID, before target: UUID?) {
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let item = groups.remove(at: from)
        let to = target.flatMap { t in groups.firstIndex { $0.id == t } } ?? groups.count
        groups.insert(item, at: to)
        save()
    }

    /// 默认组名：会话都在同一个项目里就叫项目名，不然「标签组 N」
    static func suggestedName(_ keys: [String], among groups: [Group]) -> String {
        let projects = Set(keys.compactMap { KitelineKit.model?.sessionSnapshot($0)?.cwd.map { ($0 as NSString).lastPathComponent } })
        if projects.count == 1, let name = projects.first, !name.isEmpty, !groups.contains(where: { $0.name == name }) { return name }
        var n = groups.count + 1
        while groups.contains(where: { $0.name == L("会话组 %lld", n) }) { n += 1 }
        return L("会话组 %lld", n)
    }

    // MARK: 记住

    /// 读回上次的组（正显示的那组的分屏由 ChatPanes.remember 自己读回，两边是同一时刻存的）
    func remember(in defaults: UserDefaults, key: String) {
        guard store == nil else { return }
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Stored.self, from: data) {
            groups = saved.groups
            active = saved.groups.contains { $0.id == saved.active } ? saved.active : nil
            loose = saved.loose
            looseKeys = saved.looseKeys
            // 加颜色之前建的组：按先后各定一个色存下（以后排序、删组都不会让它变色）
            for index in groups.indices where groups[index].color == nil { groups[index].color = color(of: groups[index].id).id }
            // 改名前自动起的「标签组 N」跟着改叫「会话组 N」（用户自己起的名字不动）
            for index in groups.indices {
                let name = groups[index].name
                if name.hasPrefix("标签组 "), Int(name.dropFirst(4)) != nil { groups[index].name = "会话组 " + name.dropFirst(4) }
            }
            // 分屏那份没读回来（存坏了、被清掉）：用这组切走时存的那份
            if panes.isPristine, let layout = group(active)?.layout { panes.load(layout) }
        }
        store = (defaults, key)
        // 分屏每次存盘时，正显示的那组也存一份副本（分屏那份丢了还能从这里恢复）
        panes.onSave = { [weak self] in self?.mirror() }
        // 先连上电脑、后读回本机的组：读完再和电脑上的那份并一次
        if let shared, shared.loaded { applyRemote(shared.items, rev: shared.rev) }
    }

    private func mirror() {
        guard let active, let index = groups.firstIndex(where: { $0.id == active }) else { return }
        let layout = panes.layout(), keys = panes.keys
        guard groups[index].layout != layout || groups[index].keys != keys else { return }
        groups[index].layout = layout
        groups[index].keys = keys
        save()
    }

    private func save() {
        guard let store, let data = try? JSONEncoder().encode(Stored(groups: groups, active: active, loose: loose, looseKeys: looseKeys)) else { return }
        store.defaults.set(data, forKey: store.key)
        push()
    }

    // MARK: 和电脑同步（组名、颜色、有哪些会话、先后存在电脑上，手机上看到同一套；分屏布局只存本机）

    /// 电脑上的那份（连上电脑时 KitelineKit.connect 接上）
    @ObservationIgnored private weak var shared: SharedTabGroups?

    func attach(_ shared: SharedTabGroups) {
        self.shared = shared
        shared.onRemote = { [weak self] list, rev in self?.applyRemote(list, rev: rev) }
        if shared.loaded { applyRemote(shared.items, rev: shared.rev) }
    }

    /// 本机这套换成存在电脑上的样子
    private var sharedForm: [SharedTabGroup] {
        groups.map { SharedTabGroup(id: $0.id.uuidString, name: $0.name, color: color(of: $0.id).id, keys: keys($0.id).filter { !$0.isEmpty }) }
    }

    /// 有变化就整份推给电脑（取到过电脑上的那份才推：免得刚启动、还没连上时把电脑上的盖掉）
    private func push() {
        guard let shared, shared.loaded else { return }
        let form = sharedForm
        if form != shared.items { shared.set(form) }
    }

    /// 电脑推来新的一份（手机上建了组、改了名、加了会话）：并进本机。已有的组保留分屏布局，只把多出的会话加一列、没了的关掉
    private func applyRemote(_ list: [SharedTabGroup], rev: Int) {
        // 电脑上还没存过（刚升级）：把本机原有的组补上去
        if rev == 0 {
            if !groups.isEmpty { shared?.set(sharedForm) }
            return
        }
        guard list != sharedForm else { return }
        let ids = Set(list.compactMap { UUID(uuidString: $0.id) })
        // 正显示的组在别处被删了：先回到未分组
        if let active, !ids.contains(active) { activate(nil) }
        var next: [Group] = []
        for remote in list {
            guard let id = UUID(uuidString: remote.id) else { continue }
            let keys = remote.keys.filter { !$0.isEmpty }
            if var group = groups.first(where: { $0.id == id }) {
                group.name = remote.name
                if let color = remote.color { group.color = color }
                let current = self.keys(id)
                let removed = current.filter { !keys.contains($0) }, added = keys.filter { !current.contains($0) }
                if !removed.isEmpty || !added.isEmpty {
                    if id == active {
                        removed.forEach { panes.close(key: $0) }
                        added.forEach(panes.appendColumn)
                        group.keys = panes.keys
                        group.layout = panes.layout()
                    } else {
                        group.layout = ChatPanes.edited(group.layout) { scratch in
                            removed.forEach { scratch.close(key: $0) }
                            added.forEach(scratch.appendColumn)
                        }
                        group.keys = ChatPanes.keys(in: group.layout)
                    }
                }
                next.append(group)
            } else {
                let layout = ChatPanes.edited(nil) { scratch in keys.forEach(scratch.appendColumn) }
                next.append(Group(id: id, name: remote.name, layout: layout, keys: keys, color: remote.color))
            }
        }
        groups = next
        save()
    }
}


// MARK: 侧栏

/// 左边栏的「标签组」一节（排在顶上几块入口下面、会话列表上面）：未分组的标签页 + 每组一行。
/// 一行：组名、组里各会话的状态点（等确认橙、在工作主题色、空闲绿、出错红、已结束空心），右边待确认数 / 新消息数，下面一行小字说最要紧的那件事
///（同 cmux 侧栏显示最新提醒）。点一下切到这组（组里的会话多列摆出来），左边的箭头展开看组里每个会话，点会话直接切过去并显示它。
/// 把左边栏的会话拖到某组上 = 加进这组（多一列）。右键：重命名、每个会话一列、添加会话、删除。
/// 快捷键（同 cmux）：⌃⌘] / ⌃⌘[ 下一组 / 上一组，⌃⌘1…9 第几组，⇧⌘U 跳到待确认 / 有新消息的会话，⌃⌘N 新建标签组
public struct TarsTabGroupSection: View {
    /// 放在左边栏「标签组」页签里：不要组头（页签已经写着了，新建按钮在页签那一行右边）
    let headerless: Bool

    public init(headerless: Bool = false) { self.headerless = headerless }

    public var body: some View {
        if let model = KitelineKit.model {
            TabGroupRows(groups: KitelineKit.tabGroups, headerless: headerless).environment(model)
        }
    }
}

/// 左边栏「标签组」页签那一行右边的「新建标签组」：未分组开着标签页时多一项「用当前 N 个标签页新建」
public struct TarsTabGroupNewButton<Label: View>: View {
    let label: Label

    public init(@ViewBuilder label: () -> Label) { self.label = label() }

    public var body: some View {
        let groups = KitelineKit.tabGroups
        if groups.active == nil, !groups.panes.isPristine {
            Menu {
                Button(L("新建会话组…")) { TabGroupRequest.shared.picking = .create([]) }
                Button(L("用当前 %lld 个标签页新建会话组", count: groups.panes.keys.count)) { groups.create(name: nil, keys: [], fromCurrent: true) }
            } label: { label }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(L("新建会话组"))
        } else {
            Button { TabGroupRequest.shared.picking = .create([]) } label: { label }
                .buttonStyle(.plain)
                .help(L("新建会话组"))
        }
    }
}

extension KitelineKit {
    /// 有组（不算正显示的那组）里有待确认的会话：「标签组」页签上标个橙点
    public static var tabGroupsWaiting: Bool {
        guard let model else { return false }
        let groups = tabGroups
        return ([nil] + groups.groups.map(\.id)).contains { $0 != groups.active && !TabGroupDigest(keys: groups.keys($0), model: model).waiting.isEmpty }
    }
}

private struct TabGroupRows: View {
    let groups: TabGroups
    var headerless = false
    @Environment(AppModel.self) private var model
    // 弹的面板挂在主窗口上（TarsTabGroupPickerHost）：挂在列表的 Section 上会给这一节的每一行各挂一份，点一次弹好几个
    private var request: TabGroupRequest { TabGroupRequest.shared }
    private var renaming: UUID? { get { request.renaming } nonmutating set { request.renaming = newValue } }
    private var deleting: UUID? { get { request.deleting } nonmutating set { request.deleting = newValue } }
    private var picking: TabGroupPicker.Mode? { get { request.picking } nonmutating set { request.picking = newValue } }

    var body: some View {
        Section {
            if groups.groups.isEmpty {
                emptyHint
            } else {
                looseRow
                ForEach(groups.groups) { group in
                    row(group)
                    if group.expanded {
                        ForEach(groups.keys(group.id), id: \.self) { key in memberRow(key, in: group.id) }
                    }
                }
            }
        } header: {
            if !headerless { header }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack")
            Text("会话组").lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                Button(L("新建会话组…")) { picking = .create([]) }
                if groups.active == nil, !groups.panes.isPristine {
                    Button(L("用当前 %lld 个标签页新建会话组", count: groups.panes.keys.count)) { groups.create(name: nil, keys: [], fromCurrent: true) }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 18).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(L("新建会话组"))
        }
    }

    /// 还没有组：一句说明 + 新建（用户第一次看到这一节时知道是干什么的）
    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("把同一阶段的几个会话放成一组，切换时整组多列显示。")
                .font(.app(size: 11.5)).foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("新建会话组…")) { picking = .create([]) }
                if !groups.panes.isPristine {
                    Button(L("存下当前分屏")) { groups.create(name: nil, keys: [], fromCurrent: true) }
                }
            }
            .font(.app(size: 11.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.claude)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
    }

    /// 未分组的标签页（同 Safari 最上面那行「N 个标签页」）
    private var looseRow: some View {
        let keys = groups.keys(nil)
        return TabGroupLine(symbol: "rectangle.on.rectangle", name: L("未分组的会话"), keys: keys, expanded: nil, toggle: nil)
            .modifier(TabGroupHighlight(selected: groups.active == nil) { groups.activate(nil) })
            .contextMenu {
                if groups.active == nil, !groups.panes.isPristine {
                    Button(L("用这些标签页新建会话组")) { groups.create(name: nil, keys: [], fromCurrent: true) }
                }
            }
    }

    private func row(_ group: TabGroups.Group) -> some View {
        let tint = groups.color(of: group.id)
        return TabGroupLine(symbol: "square.stack.fill", tint: tint.color, name: group.name, keys: groups.keys(group.id), expanded: group.expanded) {
            withAnimation(.snappy(duration: 0.2)) { groups.toggleExpanded(group.id) }
        }
        .modifier(TabGroupHighlight(selected: groups.active == group.id, tint: tint.color) { groups.activate(group.id) })
        // 左边栏的会话拖到这组上：加进来（多一列）
        .modifier(TabGroupDrop { key in
            groups.add([key], to: group.id)
            model.flash(L("已加入会话组「%@」", group.name))
        })
        // 拖着排先后
        .onDrag { NSItemProvider(object: ("tabgroup:" + group.id.uuidString) as NSString) }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String, text.hasPrefix("tabgroup:"), let id = UUID(uuidString: String(text.dropFirst(9))), id != group.id else { return }
                DispatchQueue.main.async { withAnimation(.snappy) { groups.reorder(id, before: group.id) } }
            }
            return true
        }
        .contextMenu {
            Button(L("打开")) { groups.activate(group.id) }
            Button(L("添加会话…")) { picking = .add(group.id) }
            Button(L("每个会话一列")) { groups.arrange(group.id) }
            if model.supportsGroups {
                Button(L("把组里的会话拉成群")) { KitelineKit.groupChat(from: group.id) }
            }
            Button(L("重命名和颜色…")) { renaming = group.id }
            Menu(L("颜色")) {
                ForEach(TabGroupColor.all) { option in
                    Button { groups.recolor(group.id, option.id) } label: {
                        Label { Text(option.title) } icon: { Image(nsImage: option.swatch(selected: tint.id == option.id)) }
                    }
                }
            }
            Divider()
            Button(L("删除会话组…"), role: .destructive) { deleting = group.id }
        }
    }

    /// 展开时组里的一个会话：状态点、标题、有新消息的小圆点；点了切到这组并显示它
    private func memberRow(_ key: String, in id: UUID) -> some View {
        let session = model.session(key)
        let unread = session.map(model.isUnread) ?? false
        return HStack(spacing: 7) {
            // 正在工作的会话：状态点一闪一闪（交给 Core Animation，不让整个侧栏跟着重画）
            if let face = model.sessionSlot(key).tab, face.activity == "busy", !face.failed {
                PulseDot(color: face.color, size: 6, low: 0.25, period: 0.8).help(L("正在工作"))
            } else {
                PaneMark(key: key, size: 6)
            }
            Text(model.paneTitle(key)).font(.app(size: 12)).lineLimit(1)
                .foregroundStyle(session == nil && GroupKey.id(key) == nil ? .tertiary : .primary)
            Spacer(minLength: 4)
            if session?.isWaiting == true { TabGroupBadge(text: L("待确认"), color: .orange) }
            if unread { TabGroupBadge(text: L("新"), color: Theme.claude).help(L("有新消息")) }
        }
        .padding(.leading, 30).padding(.trailing, 4).padding(.vertical, 2)
        .modifier(TabGroupHighlight(selected: groups.active == id && groups.panes.focused == key, compact: true, tint: groups.color(of: id).color) { groups.activate(id, focus: key) })
        .contextMenu {
            Button(L("从会话组移除")) { withAnimation(.snappy) { groups.remove(key, from: id) } }
        }
    }
}

/// 一组那一行：展开箭头、图标、组名、状态点；下面一行小字说最要紧的那件事
private struct TabGroupLine: View {
    let symbol: String
    /// 组的颜色：图标换成这个色的小色块（同 Edge 标签栏上组名前的色块）；nil = 未分组那行，画灰图标
    var tint: Color? = nil
    let name: String
    let keys: [String]
    /// nil = 不能展开（未分组那行）
    let expanded: Bool?
    let toggle: (() -> Void)?
    @Environment(AppModel.self) private var model

    var body: some View {
        let digest = TabGroupDigest(keys: keys, model: model)
        HStack(alignment: .top, spacing: 6) {
            Group {
                if let expanded, let toggle {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 14, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? L("收起") : L("展开组里的会话"))
                } else {
                    Color.clear.frame(width: 14, height: 18)
                }
            }
            if let tint {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(tint).frame(width: 12, height: 12).frame(height: 18)
            } else {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.app(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(keys.count)").font(.app(size: 11)).foregroundStyle(.tertiary).monospacedDigit().fixedSize()
                    Spacer(minLength: 4)
                    badges(digest)
                }
                .frame(height: 18)
                // 第二行只写最要紧的那件事（11-10 反馈：一排状态小点看不出名堂，去掉；有没有新消息看右边的角标）
                if !keys.isEmpty {
                    Text(summary(digest)).font(.app(size: 11)).foregroundStyle(summaryColor(digest)).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 右边的角标：有新消息的会话数（主题色底白字），有人等确认时前面再一个橙色的数
    @ViewBuilder
    private func badges(_ digest: TabGroupDigest) -> some View {
        HStack(spacing: 4) {
            if !digest.waiting.isEmpty {
                TabGroupBadge(text: "\(digest.waiting.count)", color: .orange)
                    .help(L("%lld 个会话等你确认", count: digest.waiting.count))
            }
            if !digest.unread.isEmpty {
                TabGroupBadge(text: "\(digest.unread.count)", color: Theme.claude)
                    .help(L("%lld 个会话有新消息", count: digest.unread.count))
            }
        }
    }

    private func summary(_ digest: TabGroupDigest) -> String {
        if let key = digest.waiting.first { return L("待确认：%@", model.paneTitle(key)) }
        if let key = digest.failed.first { return L("出错：%@", model.paneTitle(key)) }
        if let key = digest.unread.first, digest.busy.isEmpty { return L("有新消息：%@", model.paneTitle(key)) }
        if !digest.busy.isEmpty { return digest.unread.isEmpty ? L("%lld 个在工作", count: digest.busy.count) : L("%lld 个在工作 · %lld 个有新消息", digest.busy.count, digest.unread.count) }
        if digest.ended == digest.total { return L("都已结束") }
        return L("空闲")
    }

    private func summaryColor(_ digest: TabGroupDigest) -> Color {
        if !digest.waiting.isEmpty { return .orange }
        if !digest.failed.isEmpty { return Theme.removed }
        return .secondary
    }
}

/// 选中、悬停：同左边栏会话行（淡品牌色底 + 细边，指着浅浅一层）。悬停只换底色，不增删控件、不改尺寸（见 mac-sidebar-trackpad-scroll）
private struct TabGroupHighlight: ViewModifier {
    let selected: Bool
    var compact = false
    /// 选中时的底色、细边用组的颜色（未分组用主题色）
    var tint: Color? = nil
    let select: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 7 : 10, style: .continuous)
        let accent = tint ?? Theme.claude
        content
            .padding(.horizontal, 7)
            .background(selected ? accent.opacity(compact ? 0.08 : 0.14) : Color.primary.opacity(hovering ? 0.05 : 0), in: shape)
            .overlay { if selected && !compact { shape.hairlineBorder(accent.opacity(0.4), width: 1) } }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onTapGesture(perform: select)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
    }
}

/// 左边栏拖来的会话（PaneDrag）落在这组上：加进来；停在上面时描一圈主题色
private struct TabGroupDrop: ViewModifier {
    let perform: (String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.claude, lineWidth: 1.5).allowsHitTesting(false)
                }
            }
            .onDrop(of: [PaneDrag.type], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadDataRepresentation(forTypeIdentifier: PaneDrag.type.identifier) { data, _ in
                    guard let data, let drag = PaneDrag.decode(data) else { return }
                    DispatchQueue.main.async { perform(drag.key) }
                }
                return true
            }
    }
}

// MARK: 新建 / 添加会话

/// 勾几个会话建一组（每个一列，按勾的先后从左到右），或往已有的组里加
struct TabGroupPicker: View {
    enum Mode: Hashable {
        /// 新建：先勾上的会话（会话右键「新建标签组」时就是它）
        case create([String])
        case add(UUID)
    }

    let mode: Mode
    let groups: TabGroups
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    /// 按勾的先后：建组时从左到右就是这个顺序
    @State private var picked: [String] = []
    @State private var name = ""
    @State private var color = ""
    @State private var query = ""
    @State private var projectFilter = ""

    init(mode: Mode, groups: TabGroups) {
        self.mode = mode
        self.groups = groups
        if case .create(let keys) = mode { _picked = State(initialValue: keys) }
        _color = State(initialValue: groups.nextColor)
    }

    private var target: UUID? { if case .add(let id) = mode { id } else { nil } }
    private var existing: Set<String> { Set(target.map(groups.keys) ?? []) }

    var body: some View {
        FitSheet(title: target == nil ? L("新建会话组") : L("添加会话到「%@」", groups.group(target)?.name ?? ""), cancel: true) {
            VStack(alignment: .leading, spacing: 12) {
                if target == nil {
                    Text("选中的会话会在这一组里各占一列，切到这组时一起显示；之后可以像平时一样拖动、分屏、开标签。")
                        .font(.ui(.footnote)).foregroundStyle(.secondary)
                    TextField(L("组名（可不填，按项目自动起名）"), text: $name)
                        .textFieldStyle(.plain).font(.ui(.body))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    TabGroupColorRow(selection: $color)
                }
                filters
                list
            }
        } bottom: {
            Button(action: commit) {
                Text(buttonTitle).font(.ui(.body).weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Theme.claude.opacity(fresh.isEmpty ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .disabled(fresh.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private static func project(_ session: SessionInfo) -> String { session.cwd.map { ($0 as NSString).lastPathComponent } ?? "" }

    private var fresh: [String] { picked.filter { !existing.contains($0) } }

    private var buttonTitle: String {
        if fresh.isEmpty { return L("请选择会话") }
        return target == nil ? L("新建会话组（%lld 列）", count: fresh.count) : L("添加 %lld 个会话", count: fresh.count)
    }

    /// 搜索 + 项目胶囊（不止一个项目时）
    @ViewBuilder
    private var filters: some View {
        TextField(L("搜索会话"), text: $query)
            .textFieldStyle(.roundedBorder).font(.ui(.subheadline))
        let projects = model.sessions.reduce(into: [String]()) { list, s in
            let p = Self.project(s)
            if !p.isEmpty, !list.contains(p) { list.append(p) }
        }
        if projects.count > 1 {
            ScopeBar(symbol: "folder", allTitle: L("全部项目"),
                     options: projects.map { p in ScopeBar.Option(id: p, title: p, count: model.sessions.filter { Self.project($0) == p }.count) },
                     selection: $projectFilter)
        }
    }

    private var list: some View {
        let shown = model.sessions.filter { s in
            (projectFilter.isEmpty || Self.project(s) == projectFilter)
                && (query.isEmpty || s.title.localizedCaseInsensitiveContains(query) || Self.project(s).localizedCaseInsensitiveContains(query))
        }
        return VStack(spacing: 0) {
            if shown.isEmpty {
                Text(model.sessions.isEmpty ? L("没有运行中的会话") : L("没有符合筛选条件的会话"))
                    .font(.ui(.footnote)).foregroundStyle(.secondary).padding(12)
            }
            ForEach(shown) { session in
                row(session)
                if session.key != shown.last?.key { Divider().padding(.leading, 44) }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ session: SessionInfo) -> some View {
        let member = existing.contains(session.key)
        let order = picked.firstIndex(of: session.key)
        return Button {
            guard !member else { return }
            if let order { picked.remove(at: order) } else { picked.append(session.key) }
        } label: {
            HStack(spacing: 10) {
                // 勾上的写第几列（建组时从左到右的顺序）
                ZStack {
                    if member {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.claude.opacity(0.45))
                    } else if let order {
                        Circle().fill(Theme.claude)
                        Text("\(order + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 19, weight: .light))
                .frame(width: 20, height: 20)
                Circle().fill(StatusColor.of(session)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        AgentGlyph(session.agent, size: 12).foregroundStyle(.secondary)
                        Text(session.title).font(.ui(.subheadline)).lineLimit(1)
                    }
                    Text(member ? L("已在这个组里") : [session.sourceName, Self.project(session)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                // 已在别的组里的标出来（一个会话可以在几个组里）
                let elsewhere = groups.groups(holding: session.key).filter { $0.id != target }.map(\.name)
                if !elsewhere.isEmpty {
                    Text(elsewhere.joined(separator: L("、"))).font(.ui(.caption2)).foregroundStyle(.tertiary).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    private func commit() {
        let keys = fresh
        guard !keys.isEmpty else { return }
        dismiss()
        if let target {
            groups.add(keys, to: target)
        } else {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            groups.create(name: clean.isEmpty ? nil : clean, keys: keys, color: color)
        }
    }
}

/// 改组名、选颜色（同 Edge 点组名弹的那块：上面组名，下面一排九个色点，点色点立刻换上）
private struct TabGroupRenameSheet: View {
    @PanelDismiss private var dismiss
    @State var name: String
    @State var color: String
    let save: (String) -> Void
    let recolor: (String) -> Void

    var body: some View {
        FitSheet(title: L("编辑会话组"), cancel: true) {
            VStack(alignment: .leading, spacing: 14) {
                TextField(L("组名"), text: $name)
                    .textFieldStyle(.plain).font(.ui(.body))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onSubmit(commit)
                TabGroupColorRow(selection: $color) { recolor($0) }
                Button(action: commit) {
                    Text("保存").font(.ui(.body).weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Theme.claude.opacity(blank ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(blank)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var blank: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func commit() {
        guard !blank else { return }
        save(name)
        dismiss()
    }
}

/// 一排九个色点：选中的外面一圈，指着显示颜色名
struct TabGroupColorRow: View {
    @Binding var selection: String
    var changed: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            ForEach(TabGroupColor.all) { option in
                let on = selection == option.id
                Button {
                    selection = option.id
                    changed?(option.id)
                } label: {
                    Circle().fill(option.color).frame(width: 18, height: 18)
                        .padding(3)
                        .overlay { Circle().strokeBorder(on ? option.color : .clear, lineWidth: 2) }
                        .overlay { if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(option.title)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 标签组的九种颜色（同 Edge / Chrome：灰、蓝、红、黄、绿、粉、紫、青、橙），深浅色外观各一套
public struct TabGroupColor: Identifiable, Equatable {
    public let id: String
    let title: String
    let light: NSColor
    let dark: NSColor

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    init(id: String, title: String, light: UInt32, dark: UInt32) {
        self.id = id
        self.title = title
        self.light = Self.rgb(light)
        self.dark = Self.rgb(dark)
    }

    init?(id: String?) {
        guard let id, let found = Self.all.first(where: { $0.id == id }) else { return nil }
        self = found
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let grey = TabGroupColor(id: "grey", title: L("灰色"), light: 0x5F6368, dark: 0xBDC1C6)
    static var all: [TabGroupColor] { [
        grey,
        TabGroupColor(id: "blue", title: L("蓝色"), light: 0x1A73E8, dark: 0x8AB4F8),
        TabGroupColor(id: "red", title: L("红色"), light: 0xD93025, dark: 0xF28B82),
        TabGroupColor(id: "yellow", title: L("黄色"), light: 0xE8A200, dark: 0xFDD663),
        TabGroupColor(id: "green", title: L("绿色"), light: 0x188038, dark: 0x81C995),
        TabGroupColor(id: "pink", title: L("粉色"), light: 0xD01884, dark: 0xFF8BCB),
        TabGroupColor(id: "purple", title: L("紫色"), light: 0xA142F4, dark: 0xC58AF9),
        TabGroupColor(id: "cyan", title: L("青色"), light: 0x007B83, dark: 0x78D9EC),
        TabGroupColor(id: "orange", title: L("橙色"), light: 0xFA903E, dark: 0xFCAD70),
    ] }
    /// 自动给色的顺序：灰色放最后（同 Edge 先给彩色）
    static var cycle: [TabGroupColor] { Array(all.dropFirst()) + [grey] }

    /// 右键菜单里的小色点（菜单里 SwiftUI 的颜色会被画成单色，要给不当模板用的图）
    func swatch(selected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            if selected {
                NSColor.white.setStroke()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 3.5, dy: 3.5))
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: 右键菜单里的「标签组」

/// 会话、标签右键里的一项「标签组 ▸」：加到某组 / 移到某组 / 用它新建。moving = 从正显示的标签上点的（挪过去，这边关掉）
public struct TarsTabGroupMenu: View {
    let key: String
    let moving: Bool

    public init(key: String, moving: Bool = false) {
        self.key = key
        self.moving = moving
    }

    public var body: some View {
        let groups = KitelineKit.tabGroups
        Menu(moving ? L("移到会话组") : L("添加到会话组")) {
            ForEach(groups.groups.filter { $0.id != (moving ? groups.active : nil) }) { group in
                let inside = groups.keys(group.id).contains(key)
                Button(inside ? L("%@（已在组里）", group.name) : group.name) {
                    if moving { groups.move(key, to: group.id) } else { groups.add([key], to: group.id) }
                    KitelineKit.flash(L("已加入会话组「%@」", group.name))
                }
                .disabled(inside)
            }
            if !groups.groups.isEmpty { Divider() }
            Button(L("新建会话组（只放这个会话）")) {
                if moving { groups.panes.close(key: key) }
                groups.create(name: nil, keys: [key])
            }
        }
    }
}

// MARK: 给 Mac App 用的

extension KitelineKit {
    /// Mac 主窗口的标签组（和 KitelineKit.panes 是同一套分屏）
    public static let tabGroups = TabGroups(panes: panes)

    /// 读回上次的标签组（在 panes.remember 之后调）
    public static func rememberTabGroups(in defaults: UserDefaults, key: String) { tabGroups.remember(in: defaults, key: key) }

    /// ⌃⌘] / ⌃⌘[：下一组 / 上一组
    public static func stepTabGroup(_ delta: Int) { tabGroups.step(delta) }

    /// ⌃⌘1…9：第几组（1 = 未分组的标签页）；没有这组返回 false
    @discardableResult
    public static func selectTabGroup(_ number: Int) -> Bool {
        let order: [UUID?] = [nil] + tabGroups.groups.map(\.id)
        guard number >= 1, number <= order.count else { return false }
        tabGroups.activate(order[number - 1])
        return true
    }

    public static var tabGroupCount: Int { tabGroups.groups.count }

    /// ⇧⌘U：跳到最该看的会话——先待确认，再出错，再有新消息；先找当前组，再按侧栏顺序找别的组（同 cmux「跳到最新未读」）
    @discardableResult
    public static func jumpToAttention() -> Bool {
        guard let model else { return false }
        let order: [UUID?] = [tabGroups.active] + ([nil] + tabGroups.groups.map(\.id)).filter { $0 != tabGroups.active }
        let digests = order.map { (id: $0, digest: TabGroupDigest(keys: tabGroups.keys($0), model: model)) }
        for pick in [\TabGroupDigest.waiting, \.failed, \.unread] {
            for entry in digests {
                // 正显示在屏幕上的不算（已经在看了）
                if let key = entry.digest[keyPath: pick].first(where: { !model.isOpen($0) }) {
                    tabGroups.activate(entry.id, focus: key)
                    return true
                }
            }
        }
        model.flash(L("没有待确认或有新消息的会话"))
        return false
    }

    /// 新建标签组面板（⌃⌘N、会话右键「新建标签组」）
    public static func newTabGroup(with keys: [String] = []) { tabGroupRequest = keys }
    /// 有值时 Mac 主窗口弹新建面板（MainWindow 里 .sheetPanel 读它）
    public static var tabGroupRequest: [String]? {
        get { TabGroupRequest.shared.keys }
        set { TabGroupRequest.shared.keys = newValue }
    }

    /// 自测用：标签组的样子（「*组名[会话…] | 组名[…]」，* 是正显示的；未分组写在最前）
    public static var tabGroupSummary: String {
        let groups = tabGroups
        let loose = (groups.active == nil ? "*" : "") + L("未分组") + "[\(groups.keys(nil).count)]"
        return ([loose] + groups.groups.map { ($0.id == groups.active ? "*" : "") + $0.name + "(\(groups.color(of: $0.id).id))[\(groups.keys($0.id).count)]" }).joined(separator: " | ")
            + "；" + panes.summary + "；" + (model?.chatMemory ?? "")
    }

    /// 自测用：按名字切组（空 = 未分组）
    public static func activateTabGroup(named name: String) -> Bool {
        if name.isEmpty { tabGroups.activate(nil); return true }
        guard let group = tabGroups.groups.first(where: { $0.name == name }) else { return false }
        tabGroups.activate(group.id)
        return true
    }

    /// 自测用：按会话 key 建一组（名字空 = 自动起名）
    @discardableResult
    public static func createTabGroup(name: String?, keys: [String], fromCurrent: Bool = false) -> String {
        let id = tabGroups.create(name: name, keys: keys, fromCurrent: fromCurrent)
        return tabGroups.group(id)?.name ?? ""
    }

    /// 自测用：弹某组的「编辑标签组」
    public static func editTabGroup(named name: String) {
        if let group = tabGroups.groups.first(where: { $0.name == name }) { TabGroupRequest.shared.renaming = group.id }
    }

    /// 自测用：给某组换颜色
    public static func recolorTabGroup(named name: String, _ color: String) {
        if let group = tabGroups.groups.first(where: { $0.name == name }) { tabGroups.recolor(group.id, color) }
    }

    /// 自测用：某组一键建群
    public static func groupChatTabGroup(named name: String) {
        if let group = tabGroups.groups.first(where: { $0.name == name }) { groupChat(from: group.id) }
    }

    /// 自测用：展开 / 收起某组
    public static func toggleTabGroup(named name: String) {
        if let group = tabGroups.groups.first(where: { $0.name == name }) { tabGroups.toggleExpanded(group.id) }
    }

    /// 自测用：对话休眠的等待时间（秒）
    public static func setChatSleep(seconds: Double) { AppModel.sleepAfter = .milliseconds(Int(seconds * 1000)) }
}

extension KitelineKit {
    /// 会话组一键建群：组里运行中的会话拉成群（群名 = 组名），建好打开群聊
    static func groupChat(from id: UUID) {
        guard let model, let group = tabGroups.group(id) else { return }
        let keys = tabGroups.keys(id).filter { GroupKey.id($0) == nil }
        Task {
            if let chat = await model.groupChat(fromTabGroup: keys, name: group.name) { openPage("group:" + chat) }
        }
    }

    /// 正显示的标签组的颜色（未分组 nil）：标签栏底边的色线
    public static var activeTabGroupTint: Color? {
        tabGroups.active == nil ? nil : tabGroups.color(of: tabGroups.active).color
    }
}

/// 标签栏最前面的组名色块（同 Edge 标签栏上的组标签）：正显示某组时是组的颜色 + 组名，未分组时灰色「未分组」。
/// 点开是一张切换菜单：各组（带颜色、待确认和新消息的数）、未分组，下面是编辑、新建、每个会话一列。左边栏收起时也能切组
public struct TarsTabGroupChip: View {
    public init() {}

    public var body: some View {
        if let model = KitelineKit.model { TabGroupChip(groups: KitelineKit.tabGroups).environment(model) }
    }
}

private struct TabGroupChip: View {
    let groups: TabGroups
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let active = groups.group(groups.active)
        let tint = active.map { groups.color(of: $0.id).color }
        // 别的组里有人等确认：色块右上角一个橙点，不用打开侧栏也知道
        let others = ([nil] + groups.groups.map(\.id)).filter { $0 != groups.active }
        let waiting = others.contains { !TabGroupDigest(keys: groups.keys($0), model: model).waiting.isEmpty }
        Menu {
            Button { groups.activate(nil) } label: {
                Label { Text(groups.active == nil ? L("未分组（当前）") : L("未分组")) } icon: { Image(nsImage: TabGroupColor.grey.swatch(selected: groups.active == nil)) }
            }
            ForEach(groups.groups) { group in
                let digest = TabGroupDigest(keys: groups.keys(group.id), model: model)
                let note = !digest.waiting.isEmpty ? L("%lld 个待确认", count: digest.waiting.count)
                    : !digest.unread.isEmpty ? L("%lld 个有新消息", count: digest.unread.count) : ""
                Button { groups.activate(group.id) } label: {
                    Label { Text(note.isEmpty ? group.name : "\(group.name)　\(note)") } icon: {
                        Image(nsImage: groups.color(of: group.id).swatch(selected: groups.active == group.id))
                    }
                }
            }
            Divider()
            if let active {
                Button(L("编辑「%@」的名称和颜色…", active.name)) { TabGroupRequest.shared.renaming = active.id }
                Button(L("添加会话…")) { TabGroupRequest.shared.picking = .add(active.id) }
                Button(L("每个会话一列")) { groups.arrange(active.id) }
                if model.supportsGroups {
                    Button(L("把组里的会话拉成群")) { KitelineKit.groupChat(from: active.id) }
                }
            } else if !groups.panes.isPristine {
                Button(L("用这些标签页新建会话组")) { groups.create(name: nil, keys: [], fromCurrent: true) }
            }
            Button(L("新建会话组…")) { TabGroupRequest.shared.picking = .create([]) }
        } label: {
            HStack(spacing: 5) {
                if let tint {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint).frame(width: 9, height: 9)
                } else {
                    Image(systemName: "square.stack").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(active?.name ?? L("未分组")).font(.app(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(tint ?? .secondary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: 108, alignment: .leading)
            .background((tint ?? Color.primary).opacity(hovering ? 0.22 : (tint == nil ? 0.06 : 0.15)), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if waiting { Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: 2, y: -2) }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .padding(.bottom, 5)
        .help(L("会话组：切换、改名和颜色（⌃⌘[ / ⌃⌘] 上一组 / 下一组）"))
    }
}

/// 新建标签组面板的开关（Mac 主窗口挂着 .sheetPanel 读它）
@Observable @MainActor
final class TabGroupRequest {
    static let shared = TabGroupRequest()
    var keys: [String]?
    /// 左边栏标签组里点的：添加会话 / 新建、重命名、删除
    var picking: TabGroupPicker.Mode?
    var renaming: UUID?
    var deleting: UUID?
}

/// Mac 主窗口挂着：⌃⌘N、会话右键「新建标签组」弹的面板
public struct TarsTabGroupPickerHost: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        let request = TabGroupRequest.shared
        let groups = KitelineKit.tabGroups
        content
            .sheetPanel(isPresented: Binding(get: { request.keys != nil }, set: { if !$0 { request.keys = nil } })) {
                if let model = KitelineKit.model, let keys = request.keys {
                    TabGroupPicker(mode: .create(keys), groups: groups).environment(model)
                }
            }
            .sheetPanel(isPresented: Binding(get: { request.picking != nil }, set: { if !$0 { request.picking = nil } })) {
                if let model = KitelineKit.model, let picking = request.picking { TabGroupPicker(mode: picking, groups: groups).environment(model) }
            }
            .sheetPanel(isPresented: Binding(get: { request.renaming != nil }, set: { if !$0 { request.renaming = nil } })) {
                if let id = request.renaming, let group = groups.group(id) {
                    TabGroupRenameSheet(name: group.name, color: groups.color(of: id).id, save: { groups.rename(id, $0) }, recolor: { groups.recolor(id, $0) })
                }
            }
            .confirmPanel(L("删除这个会话组？组里的会话不会关闭，仍在左边的会话列表里。"),
                          isPresented: Binding(get: { request.deleting != nil }, set: { if !$0 { request.deleting = nil } }), confirm: L("删除会话组"), destructive: true) {
                if let id = request.deleting { withAnimation(.snappy) { groups.delete(id) } }
            }
    }
}
#endif
