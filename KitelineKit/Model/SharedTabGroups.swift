import Foundation
import Observation

// 标签组：同一阶段的几个相关会话放一组。组名、颜色、有哪些会话、先后存在电脑上（Sources/TabGroupStore.swift / 电脑端 tabgroups.py，
// /api/tabgroups + 实时通道的 tabgroups 事件），连同一台电脑的各端看到同一套。
// Mac 上切到哪组右边就多列显示哪组（KitelineKit/Views/TabGroups.swift，分屏布局只存本机）；iPhone / iPad 上点开一组看组里的会话，一次看一个（TabGroupsPhone.swift）

struct SharedTabGroup: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var color: String?
    var keys: [String]
}

@Observable @MainActor
final class SharedTabGroups {
    private(set) var items: [SharedTabGroup] = []
    /// 电脑上的版本号：0 = 电脑上还没存过（Mac 升级上来时用本机原有的组补上去）
    private(set) var rev = 0
    /// 取到过电脑上的那份（没取到前不往上推，免得空的盖掉电脑上的）
    private(set) var loaded = false
    /// 电脑有这个接口（老版本电脑端没有：手机上不显示标签组）
    var supported = false
    /// 电脑推来新的一份时（Mac 的 TabGroups 接着并进分屏）
    @ObservationIgnored var onRemote: (([SharedTabGroup], Int) -> Void)?
    @ObservationIgnored weak var api: MacAPI?

    private static let cacheKey = "tabGroupsCache"

    private struct Payload: Decodable {
        var rev: Int?
        var groups: [SharedTabGroup]?
    }

    func group(_ id: String) -> SharedTabGroup? { items.first { $0.id == id } }

    /// 这个会话在哪几组里
    func groups(holding key: String) -> [SharedTabGroup] { items.filter { $0.keys.contains(key) } }

    /// 上次存的：断网、电脑没开也能看到分组
    func loadCached() {
        guard items.isEmpty, let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        items = payload.groups ?? []
    }

    func apply(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), let groups = payload.groups else { return }
        let rev = payload.rev ?? 0
        loaded = true
        supported = true
        self.rev = rev
        if groups != items { items = groups }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        onRemote?(groups, rev)
    }

    func load() async {
        guard let api, let data = try? await api.data("/api/tabgroups") else { return }
        apply(data)
    }

    /// 改了：先在本地换上（界面马上变），再整份推给电脑
    func set(_ groups: [SharedTabGroup]) {
        guard groups != items || !loaded else { return }
        items = groups
        guard loaded, let api else { return }
        let body: [String: Any] = ["groups": groups.map { group -> [String: Any] in
            var row: [String: Any] = ["id": group.id, "name": group.name, "keys": group.keys]
            if let color = group.color { row["color"] = color }
            return row
        }]
        Task {
            if let data = try? await api.postData("/api/tabgroups/set", body: body) { apply(data) }
        }
    }

    // MARK: 手机上的改动（Mac 走 TabGroups，改完整份同步过来）

    @discardableResult
    func create(name: String, color: String, keys: [String]) -> String {
        let id = UUID().uuidString
        set(items + [SharedTabGroup(id: id, name: name, color: color, keys: keys)])
        return id
    }

    func update(_ id: String, _ change: (inout SharedTabGroup) -> Void) {
        var groups = items
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[index])
        set(groups)
    }

    func add(_ keys: [String], to id: String) {
        update(id) { group in for key in keys where !group.keys.contains(key) { group.keys.append(key) } }
    }

    func remove(_ key: String, from id: String) { update(id) { $0.keys.removeAll { $0 == key } } }

    func delete(_ id: String) { set(items.filter { $0.id != id }) }

    func move(_ id: String, by delta: Int) {
        var groups = items
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard groups.indices.contains(target) else { return }
        groups.swapAt(index, target)
        set(groups)
    }

    /// 新建时给哪个色：先挑还没人用的（同 Edge），都用过了再轮
    var nextColor: String {
        let used = Set(items.compactMap(\.color))
        return TabGroupPalette.cycle.first { !used.contains($0) } ?? TabGroupPalette.cycle[items.count % TabGroupPalette.cycle.count]
    }

    /// 默认组名：组里的会话都在同一个项目就叫项目名，不然「标签组 N」
    func suggestedName(for keys: [String], sessions: [SessionInfo]) -> String {
        let projects = Set(keys.compactMap { key in sessions.first { $0.key == key }?.cwd.map { ($0 as NSString).lastPathComponent } })
        if projects.count == 1, let name = projects.first, !name.isEmpty, !items.contains(where: { $0.name == name }) { return name }
        var n = items.count + 1
        while items.contains(where: { $0.name == L("会话组 %lld", n) }) { n += 1 }
        return L("会话组 %lld", n)
    }
}

/// 九种颜色的 id 和先后（同 Edge：灰、蓝、红、黄、绿、粉、紫、青、橙）；具体色值各端自己画（Mac 见 TabGroupColor）
enum TabGroupPalette {
    static let all = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
    /// 自动给色的顺序：灰色放最后
    static let cycle = Array(all.dropFirst()) + ["grey"]
}

extension AppModel {
    /// 会话组一键建群：组里还在运行、能回复的会话（至少两个）拉成一个群，群名用会话组的名字；返回群 id
    func groupChat(fromTabGroup keys: [String], name: String) async -> String? {
        let live = keys.filter { session($0)?.canReply == true }
        guard live.count >= 2 else {
            flash(L("会话组里至少要有两个运行中的会话才能建群"))
            return nil
        }
        guard let id = await createGroup(keys: live, topic: name) else { return nil }
        await renameGroup(id, name)
        return id
    }
}
