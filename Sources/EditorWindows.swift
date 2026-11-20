import AppKit
import ApplicationServices
import Foundation

/// 项目的会话都在后台运行以后，它那个 VS Code 窗口就用不着了：关掉它，省下 VS Code 和远端服务占的内存
/// （11-19 反馈：「已经转到终端后台的项目，可以关掉 vscode 吗？开了好多，系统资源都不够了」）。
///
/// 只在 Kiteline 刚对这个项目做完动作时看一次，不巡检——用户自己开着看代码的窗口不碰：
/// - 把 VS Code 里的会话转到了后台运行（Hosted.moveToBackground）；
/// - 在后台新建 / 恢复了会话（Hosted.start）：这种只关已经最小化的窗口，没最小化的可能正开着看代码；
/// - 关掉了 VS Code 里的会话（Delivery.close），而这个项目还有会话在后台运行。
///
/// 关之前都要过 obstacle 这一关（宁可不关）：窗口里没有别的会话在运行、没有未保存的改动、不是用户正看着的、
/// 不是 Kiteline 三分钟内刚打开的；有会话在 VS Code 里运行却对不上任何窗口时，同一类（本机 / 远端）的窗口一个都不关。
///
/// 关窗口用辅助功能按窗口的关闭按钮：不用把 VS Code 切到前台，最小化的窗口也能关。有未保存改动的窗口按了也关不掉
/// （VS Code 弹保存框，还会把最小化的窗口还原出来），所以先看关闭按钮的 AXEdited，是 true 就不按
/// （11-19 在独立的 VS Code 实例上实测）。
///
/// 开关 MobileConfig.hostedCloseEditor（默认开），在设置 → 来源；同一处能一次关掉所有「没有会话在运行」的窗口（idle / closeIdle）。
enum EditorWindows {
    /// 一个 VS Code 窗口
    struct Item {
        let window: AXUIElement
        let close: AXUIElement
        let title: String
        let minimized: Bool
        /// 有未保存的改动（关闭按钮上带小圆点）
        let edited: Bool
        /// 用户正看着：所在的 VS Code 在前台，这是它的主窗口
        let watched: Bool
    }

    /// 判断窗口用得着的那部分会话信息（在主线程上从 SessionStore 取好，辅助功能调用放在后台队列）
    struct Session {
        let key: String
        let cwd: String
        let remote: Bool
        let host: String?
        let port: Int?
        /// 关掉 VS Code 窗口也不受影响：后台运行的、tmux 里的
        let detached: Bool
        /// 在 VS Code 里运行的 Claude Code：它一定在某个窗口里
        let inEditor: Bool
    }

    enum Trigger {
        /// 把 VS Code 里的会话转到了后台运行（带这个会话的 key：快照还没跟上时，别把它自己算成「窗口里还有会话」）
        case moved(String)
        /// 在后台新建 / 恢复了会话
        case started
        /// 关掉了 VS Code 里的会话（带这个会话的 key）
        case closed(String)
    }

    /// 窗口在哪台电脑上（标题里项目名后面的方括号）
    enum Place: Equatable {
        case local
        case ssh(String)
        /// WSL、容器、隧道这些：Kiteline 看不到里面的会话，不碰
        case other
    }

    private static let queue = DispatchQueue(label: "kiteline.editor-windows")
    private static let lock = NSLock()

    /// 测试实例（隔离的配置目录、dry-run、CCPULSE_TEST_NO_EDITOR）一个窗口都不碰：它里面没有用户真实的会话，
    /// 在它看来用户的窗口全是「没有会话在运行」。要测这个功能就给 KITELINE_TEST_EDITOR_PID，只许碰这一个 VS Code 进程
    private static let testPid: pid_t? = ProcessInfo.processInfo.environment["KITELINE_TEST_EDITOR_PID"].flatMap { pid_t($0) }
    private static let disabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        let testing = env["CCPULSE_TEST_NO_EDITOR"] == "1" || env["CCPULSE_DRY_RUN"] == "1" || !(env["CCPULSE_CONFIG_DIR"] ?? "").isEmpty
        return testing && testPid == nil
    }()

    /// Kiteline 刚打开的窗口：会话过一会儿才出现在快照里，这三分钟内不当它是空的
    private static var opened: [(folder: String, remote: Bool, host: String?, at: Date)] = []
    private static let openedFor: TimeInterval = 180

    // MARK: - 窗口

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    /// 各 VS Code 系编辑器所有实例的普通窗口（没有辅助功能权限时为空）。front：此刻在前台的程序
    static func windows(front: pid_t?) -> [Item] {
        guard AXIsProcessTrusted(), !disabled else { return [] }
        var items: [Item] = []
        for (bundleId, _) in Delivery.Editor.known {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
                let pid = app.processIdentifier
                if let testPid, pid != testPid { continue }
                let ax = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(ax, 3)
                for window in attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                    guard attribute(window, kAXSubroleAttribute) as? String == (kAXStandardWindowSubrole as String),
                          let button = attribute(window, kAXCloseButtonAttribute) else { continue }
                    let close = button as! AXUIElement
                    items.append(Item(window: window, close: close,
                                      title: attribute(window, kAXTitleAttribute) as? String ?? "",
                                      minimized: attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                                      edited: attribute(close, "AXEdited") as? Bool ?? false,
                                      watched: pid == front && attribute(window, kAXMainAttribute) as? Bool == true))
                }
            }
        }
        return items
    }

    // MARK: - 标题

    private static func segments(_ title: String) -> [String] {
        title.components(separatedBy: " — ").flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func place(of title: String) -> Place {
        for segment in segments(title).reversed() where segment.hasSuffix("]") {
            guard let open = segment.range(of: " [", options: .backwards) else { continue }
            let tag = segment[open.upperBound...].dropLast()
            if tag.hasPrefix("SSH: ") { return .ssh(String(tag.dropFirst("SSH: ".count))) }
            if tag.contains(": ") { return .other }
        }
        return .local
    }

    private static func same(_ place: Place, _ session: Session) -> Bool {
        switch place {
        case .local: return !session.remote
        case .ssh(let shown):
            guard session.remote, let host = session.host, !host.isEmpty else { return false }
            return WindowLocator.sameHost(shown, host, port: session.port)
        case .other: return false
        }
    }

    /// 会话对不对得上这个窗口。exact：只比会话目录的最后一级（它就是这个窗口的项目）；
    /// 否则从深到浅逐级比（会话的目录可能是工作区根的子目录），宁可多对上。远端窗口连主机一起比
    private static func matches(_ title: String, _ session: Session, exact: Bool) -> Bool {
        let folders = session.cwd.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let last = folders.last else { return false }
        return (exact ? [last] : Array(folders.reversed())).contains {
            Delivery.windowTitle(title, matches: $0, remote: session.remote, host: session.host, port: session.port)
        }
    }

    /// 两边写的都是 IP 地址、又不一样：肯定不是同一台（别名、域名可能指同一台，不敢这么说）
    private static func surelyOther(_ shown: String, _ host: String?) -> Bool {
        func address(_ text: String) -> [UInt8]? {
            let name = String(text.split(separator: "@").last ?? "")
            var v4 = in_addr(), v6 = in6_addr()
            if inet_pton(AF_INET, name, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
            if inet_pton(AF_INET6, name, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
            return nil
        }
        guard let host, let one = address(WindowLocator.decodeAuthority(shown).host), let other = address(host) else { return false }
        return one != other
    }

    /// 这个会话在哪些窗口里：从会话目录最深的一级往上找，第一个对得上窗口的那一级里对上的都算（同投递找窗口的办法）。
    /// 这样开着主目录窗口、又开着项目窗口时，项目里的会话只算在项目窗口头上。
    /// 远端窗口不细比主机——别名、IP 这种写法对不上的也当它在里面，只有两边都是 IP 且不同才排除
    private static func holders(of session: Session, in all: [Item]) -> [Item] {
        let folders = session.cwd.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        for folder in folders.reversed() {
            let hit = all.filter { item in
                guard Delivery.windowTitle(item.title, matches: folder, remote: session.remote) else { return false }
                if session.remote, case .ssh(let shown) = place(of: item.title), surelyOther(shown, session.host) { return false }
                return true
            }
            if !hit.isEmpty { return hit }
        }
        return []
    }

    // MARK: - Kiteline 刚打开的窗口

    static func noteOpened(folder: String, remote: Bool, host: String?) {
        guard !folder.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        opened = opened.filter { Date().timeIntervalSince($0.at) < openedFor } + [(folder, remote, host, Date())]
    }

    private static func justOpened(_ title: String) -> Bool {
        lock.lock()
        let recent = opened.filter { Date().timeIntervalSince($0.at) < openedFor }
        lock.unlock()
        return recent.contains { Delivery.windowTitle(title, matches: $0.folder, remote: $0.remote, host: $0.host) }
    }

    // MARK: - 能不能关

    enum Obstacle {
        case watched, edited, opened, foreign, occupied, unplaced

        var text: String {
            switch self {
            case .watched: return "窗口正在前台使用"
            case .edited: return "窗口中有未保存的改动"
            case .opened: return "窗口刚刚打开"
            case .foreign: return "不是本机或 SSH 远端的窗口"
            case .occupied: return "窗口中还有会话在运行"
            case .unplaced: return "有会话在 VS Code 中运行，但无法确定在哪个窗口"
            }
        }
    }

    /// 不能关的原因；nil = 关了不影响任何会话、不丢改动。except：刚转走 / 刚关掉的那个会话（快照可能还没跟上）
    private static func obstacle(_ item: Item, sessions: [Session], all: [Item], except: String?) -> Obstacle? {
        if item.watched { return .watched }
        if item.edited { return .edited }
        if justOpened(item.title) { return .opened }
        let place = place(of: item.title)
        if place == .other { return .foreign }
        // 同一类（本机 / 远端）的会话都看，远端的不分是哪一台
        let remote = place != .local
        let placed = sessions.filter { !$0.detached && $0.key != except && $0.remote == remote }.map { ($0, holders(of: $0, in: all)) }
        if placed.contains(where: { $0.1.contains { CFEqual($0.window, item.window) } }) { return .occupied }
        // 多文件夹工作区、正在重连标题还没出来的窗口，会话按标题对不上：它可能就在这个窗口里
        if placed.contains(where: { $0.0.inEditor && $0.1.isEmpty }) { return .unplaced }
        return nil
    }

    /// 按关闭按钮，等一会儿再看哪些真的关了（VS Code 要确认时窗口还在）
    private static func close(_ items: [Item], front: pid_t?, why: String) -> (closed: [Item], left: [Item]) {
        guard !items.isEmpty else { return ([], []) }
        var pressed: [Item] = []
        var left: [Item] = []
        for item in items {
            let result = AXUIElementPerformAction(item.close, kAXPressAction as CFString)
            if result == .success { pressed.append(item) } else {
                Log.write("关闭 VS Code 窗口「\(item.title)」未成功（辅助功能返回 \(result.rawValue)）")
                left.append(item)
            }
        }
        Thread.sleep(forTimeInterval: 1.5)
        let still = windows(front: front)
        var closed: [Item] = []
        for item in pressed {
            if still.contains(where: { CFEqual($0.window, item.window) }) {
                Log.write("VS Code 窗口「\(item.title)」没有关闭：VS Code 可能在等待确认")
                left.append(item)
            } else {
                Log.write("已关闭 VS Code 窗口「\(item.title)」：\(why)")
                closed.append(item)
            }
        }
        return (closed, left)
    }

    // MARK: - 会话

    /// 主线程上取：各会话、连着的远端电脑（看得到上面有没有会话）、此刻的前台程序
    private static func snapshot() -> (sessions: [Session], machines: [Session], front: pid_t?) {
        let state = AppState.shared
        let sources = state.config.sources
        let sessions: [Session] = state.store.records.compactMap { record in
            guard record.kind != .kiteline else { return nil }
            let source = sources.first { $0.id == record.sourceId }
            let snap = record.snapshot
            let detached = snap.hosted != nil || snap.tmuxPane?.isEmpty == false
            return Session(key: record.key, cwd: snap.cwd, remote: record.kind == .ssh,
                           host: record.kind == .ssh ? source?.sshHost : nil, port: record.kind == .ssh ? source?.sshPort : nil,
                           detached: detached, inEditor: !detached && snap.agentID == "claude-code" && snap.isVSCode)
        }
        let machines: [Session] = sources.compactMap { source in
            guard source.kind == .ssh, source.enabled, state.source(withId: source.id)?.state.isLive == true else { return nil }
            return Session(key: "", cwd: "", remote: true, host: source.sshHost, port: source.sshPort, detached: true, inEditor: false)
        }
        return (sessions, machines, NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    // MARK: - 自动关

    /// Kiteline 刚对 sourceId 这台电脑上 cwd 这个项目做完动作：看看它的 VS Code 窗口是不是用不着了
    static func settle(_ trigger: Trigger, cwd: String, sourceId: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { settle(trigger, cwd: cwd, sourceId: sourceId) }
            return
        }
        let state = AppState.shared
        guard state.config.mobile.hostedCloseEditor, !disabled,
              let source = state.config.sources.first(where: { $0.id == sourceId }), source.kind != .kiteline else { return }
        let project = Session(key: "", cwd: cwd, remote: source.kind == .ssh, host: source.kind == .ssh ? source.sshHost : nil,
                              port: source.kind == .ssh ? source.sshPort : nil, detached: true, inEditor: false)
        var except: String?
        var minimizedOnly = false
        var needsBackground = false
        let why: String
        switch trigger {
        case .moved(let key): except = key; why = "会话已转到后台运行"
        case .started: minimizedOnly = true; why = "会话已在后台运行，窗口处于最小化"
        case .closed(let key): except = key; needsBackground = true; why = "窗口中的会话已关闭，项目的其余会话在后台运行"
        }
        // 等几秒：转到后台、关闭会话时要切到 VS Code 点菜单，等它把前台还回去，快照也跟上
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let (sessions, _, front) = snapshot()
            queue.async {
                let all = windows(front: front)
                let wanted = all.filter { item in
                    guard matches(item.title, project, exact: true) else { return false }
                    if minimizedOnly, !item.minimized { return false }
                    if needsBackground, !sessions.contains(where: { $0.detached && $0.key != except && matches(item.title, $0, exact: true) }) {
                        return false
                    }
                    guard let obstacle = obstacle(item, sessions: sessions, all: all, except: except) else { return true }
                    // 窗口里还有会话是常事，不记；别的原因记一笔，用户问「怎么没关」时查得到
                    if obstacle != .occupied { Log.write("VS Code 窗口「\(item.title)」未自动关闭：\(obstacle.text)") }
                    return false
                }
                _ = close(wanted, front: front, why: why)
            }
        }
    }

    // MARK: - 手动一次关掉

    /// 没有会话在运行的窗口：远端窗口要连着那台电脑（看得到上面的会话），本机窗口要这个项目有会话在后台运行
    /// （本机上没有项目名的窗口可能是正在重连的远端窗口，不算）
    private static func idleItems(_ all: [Item], sessions: [Session], machines: [Session]) -> [Item] {
        all.filter { item in
            guard obstacle(item, sessions: sessions, all: all, except: nil) == nil else { return false }
            let place = place(of: item.title)
            switch place {
            case .ssh: return machines.contains { same(place, $0) }
            case .local: return sessions.contains { $0.detached && matches(item.title, $0, exact: true) }
            case .other: return false
            }
        }
    }

    /// 给界面看的名字：标题里项目那一段（「文件 — 项目 [SSH: 主机]」的最后一段）
    static func project(_ title: String) -> String {
        segments(title).last(where: { !$0.isEmpty }) ?? title
    }

    /// 可以关的窗口（设置页列出来）：各窗口的项目名
    static func idle(completion: @escaping ([String]) -> Void) {
        let (sessions, machines, front) = snapshot()
        queue.async {
            let titles = idleItems(windows(front: front), sessions: sessions, machines: machines).map { project($0.title) }
            DispatchQueue.main.async { completion(titles) }
        }
    }

    /// 关掉这些窗口；回关掉的和没关掉的（项目名）
    static func closeIdle(completion: @escaping (_ closed: [String], _ left: [String]) -> Void) {
        let (sessions, machines, front) = snapshot()
        queue.async {
            let result = close(idleItems(windows(front: front), sessions: sessions, machines: machines), front: front, why: "窗口中没有会话在运行（用户在设置中关闭）")
            DispatchQueue.main.async { completion(result.closed.map { project($0.title) }, result.left.map { project($0.title) }) }
        }
    }
}
