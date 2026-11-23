#if KITELINE_MAC
import SwiftUI

// MARK: 项目各有一套标签（Mac 新版界面，11-20 反馈：切项目时中间的会话标签也要跟着切，不然 A 项目下出现 B 项目的会话很不协调；
// 上面那排会话组改成项目，点了快速切换）

/// 新版界面里每个项目一套分屏（怎么分、每块开着哪些标签——同会话组存的那份），切项目就整套换掉（同 VS Code 换工作区）。
/// 没选项目时是「""」那一套。经典界面不分项目：切到新版时把经典那套存起来，切回去原样放回（经典的会话组照旧管它自己的）。
/// 只有正显示的那套画在屏幕上，别的只是存着的几百字节
@Observable @MainActor
public final class ProjectSpaces {
    let panes: ChatPanes
    /// 新版界面开着（分项目）
    public private(set) var enabled = false
    /// 正显示的那个项目（项目的 id；"" = 没选项目）
    public private(set) var active: String = ""
    private var layouts: [String: Data] = [:]
    /// 经典界面那一套（新版开着时存在这）
    private var classic: Data?
    @ObservationIgnored private var store: (defaults: UserDefaults, key: String)?

    private struct Stored: Codable {
        var enabled: Bool
        var active: String
        var layouts: [String: Data]
        var classic: Data?
    }

    init(panes: ChatPanes) { self.panes = panes }

    /// 切到新版界面（on）/ 经典界面；切到新版时显示 project 那一套
    public func setEnabled(_ on: Bool, project: String, seed: [String]) {
        guard on != enabled else { return }
        if on {
            classic = panes.isPristine ? nil : panes.layout()
            enabled = true
            active = "\u{1}"   // 让下面的 activate 一定换
            layouts["\u{1}"] = nil
            activate(project, seed: seed, stash: false)
        } else {
            layouts[active] = panes.isPristine ? nil : panes.layout()
            enabled = false
            panes.load(classic)
            classic = nil
            panes.save()
            save()
        }
    }

    /// 切到某个项目那一套（"" = 没选项目）。那个项目还没有自己的一套：开一块，放 seed 里第一个会话（没有就是「选择会话」）。
    /// stash：先把正显示的那套存回它自己的项目
    public func activate(_ project: String, seed: [String], stash: Bool = true) {
        guard enabled, project != active else { return }
        if stash { layouts[active] = panes.isPristine ? nil : panes.layout() }
        active = project
        if let saved = layouts[project] {
            panes.load(saved)
        } else {
            panes.load(nil)
            if let first = seed.first { panes.show(first) }
        }
        panes.save()
        save()
        if let focused = panes.focused { KitelineKit.openSession(focused) }
    }

    /// 把某个标签换成另一个 key：先看正显示的那套，没有再找存着的别的项目的那几套（新会话草稿发出后切走了项目，
    /// 会话开出来要接回它原来的项目，不能显示到现在切到的项目里）。返回是不是换成了
    @discardableResult
    public func replaceTab(_ old: String, with new: String) -> Bool {
        if panes.pane(holding: old) != nil { panes.replace(old, with: new); return true }
        for (project, data) in layouts {
            if let changed = ChatPanes.layout(data, replacing: old, with: new) {
                layouts[project] = changed
                save()
                return true
            }
        }
        return false
    }

    /// 这个项目有没有存着的一套
    public func hasLayout(_ project: String) -> Bool { layouts[project] != nil || project == active }

    /// 项目从顶上那排关掉了：它那一套也扔掉（再打开时重新开）
    public func forget(_ project: String) {
        guard project != active else { return }
        layouts[project] = nil
        save()
    }

    public func remember(in defaults: UserDefaults, key: String) {
        store = (defaults, key)
        guard let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        enabled = saved.enabled
        active = saved.active
        layouts = saved.layouts
        classic = saved.classic
    }

    private func save() {
        guard let store, let data = try? JSONEncoder().encode(Stored(enabled: enabled, active: active, layouts: layouts, classic: classic)) else { return }
        store.defaults.set(data, forKey: store.key)
    }
}

extension KitelineKit {
    public static let projectSpaces = ProjectSpaces(panes: panes)
    /// 顶上那排项目（Mac 主程序画，参数是高度）：新版界面时代替会话组那一排，倒挂在窗口顶边、横跨整个分屏
    public static var projectStrip: ((CGFloat) -> AnyView)?
    /// 顶上留不留那排项目的高
    static var showsProjectStrip: Bool { projectSpaces.enabled && projectStrip != nil }
    /// 分屏「选择会话」里列不列这个会话（Mac 主程序给：新版界面开着某个项目时只列这个项目的会话，
    /// 11-21 自测看到 shop-app 下的「+」还列着 admin、weekly 的会话——正是用户说的 A 项目下出现 B 项目的会话）
    public static var pickerKeeps: ((String) -> Bool)?
}
#endif
