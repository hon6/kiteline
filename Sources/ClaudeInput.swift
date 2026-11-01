import AppKit
import ApplicationServices
import Foundation

/// 用「辅助功能」直接操作 VS Code 里 Claude 标签的输入框：找到内容就是这次要发的话的那个输入框，按它旁边的「发送」。
///
/// 新任务用扩展链接开新标签时，扩展会把内容预填进输入框，但不把光标放进去（primaryEditor.open 不请求聚焦），
/// 模拟回车、命令面板「Claude Code: Focus input」都落不到输入框上（实测）。按发送按钮不用键盘、不用焦点，
/// VS Code 不在前台也行；又是按内容认输入框，不会发进别的会话。
///
/// VS Code（Electron）平时不对外提供网页内容的辅助功能树：要先设 AXManualAccessibility，约 3 秒后才读得到，
/// 一直开着会拖慢 VS Code，用完恢复原样（本来就开着的不关）。整棵树上万个元素、遍历一次约 0.6 秒，放后台做。
enum ClaudeInput {
    enum Result {
        /// 按了发送
        case sent
        /// 找到输入框、没找到发送按钮：已把光标放进输入框，调用方再按回车
        case focused
        /// 到时间还没找到填着这段话的输入框
        case notFound
        /// VS Code 弹着自己的对话框（允许扩展打开链接、重新加载窗口……）挡着，要人在电脑上点：带框里的文字
        case blocked(String)
        /// 项目窗口是受限模式（文件夹没信任过）：Claude Code 扩展不运行，链接也没人接，要人在电脑上信任这个文件夹
        case restricted
    }

    private static let queue = DispatchQueue(label: "tars.claude-input")
    /// 发送按钮的说明文字（扩展网页里的 aria-label）
    private static let sendLabels: Set<String> = ["Send message", "Send", "发送"]

    /// 每秒找一次，直到 deadline；结果回到主线程。project = 窗口标题里的项目名，先只在这个项目的窗口里找
    static func submit(prompt: String, app: NSRunningApplication, project: String, remote: Bool, deadline: Date,
                       completion: @escaping (Result) -> Void) {
        let want = normalized(prompt)
        queue.async {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            holdWebTree(app)
            var result = Result.notFound
            var openedHere = false
            while Date() < deadline {
                // 恢复的会话在终端 / 别的窗口还开着：新标签是「仍在别处打开」，输入框不能用，按「Open here anyway」（只按一次）
                if !openedHere, let held = heldButton(in: ax) {
                    AXUIElementPerformAction(held, kAXPressAction as CFString)
                    Log.write("新会话：会话仍在别处打开，已按「Open here anyway」")
                    openedHere = true
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                let found = scan(ax, want: want, project: project, remote: remote)
                if let input = found.input {
                    if let send = findSend(near: input) {
                        AXUIElementPerformAction(send, kAXPressAction as CFString)
                        result = .sent
                    } else {
                        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                        result = .focused
                    }
                    break
                }
                if let dialog = found.dialog {
                    result = .blocked(dialogText(dialog))
                    break
                }
                if found.restricted {
                    result = .restricted
                    break
                }
                Thread.sleep(forTimeInterval: 1)
            }
            releaseWebTree(app)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 网页辅助功能树

    /// 几处要读 VS Code 网页里的东西（新任务找输入框、投递前看会话是否被占用、重新加载窗口）：一起计数，
    /// 最后一个用完再过 90 秒才关——手机上连着发几条时不用每条都等树建好。本来就开着的（别的辅助工具开的）不关
    private static let treeLock = NSLock()
    private static var treeHolders = 0
    private static var treeOwned: pid_t?
    private static var treeLinger: DispatchWorkItem?

    /// 开着树；返回开之前是不是已经开着（开着的话现在就读得到，刚开的要等约 3 秒）
    @discardableResult
    static func holdWebTree(_ app: NSRunningApplication) -> Bool {
        treeLock.lock(); defer { treeLock.unlock() }
        treeLinger?.cancel()
        treeLinger = nil
        treeHolders += 1
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var current: CFTypeRef?
        let on = AXUIElementCopyAttributeValue(ax, "AXManualAccessibility" as CFString, &current) == .success && (current as? Bool) == true
        if !on {
            AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            treeOwned = app.processIdentifier
        }
        return on
    }

    static func releaseWebTree(_ app: NSRunningApplication) {
        treeLock.lock(); defer { treeLock.unlock() }
        treeHolders = max(0, treeHolders - 1)
        guard treeHolders == 0, treeOwned == app.processIdentifier else { return }
        let item = DispatchWorkItem {
            treeLock.lock(); defer { treeLock.unlock() }
            guard treeHolders == 0, treeOwned == app.processIdentifier else { return }
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanFalse)
            treeOwned = nil
        }
        treeLinger = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: item)
    }

    // MARK: - 会话仍在别处打开

    /// 扩展 2.1.31x：同一个会话在终端、别的窗口或标签里还开着（或扩展刚重启、之前的 Claude 进程还没退）时，
    /// 标签里是「This conversation is still open somewhere else … This notice stays until you choose Open here anyway.」，
    /// 输入框不能用。按钮文字是写死的英文（扩展网页没有中文）
    private static let heldLabels: Set<String> = ["Open here anyway"]

    /// 前台窗口里「Open here anyway」按钮：恰好一个才算（左右分屏两个 Claude 标签都被占时认不出是哪个，不按）
    private static func heldButton(in ax: AXUIElement) -> AXUIElement? {
        guard let window = attribute(ax, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return nil }
        var found: [AXUIElement] = []
        _ = search(window, depth: 0) { element in
            if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole {
                let label = (attribute(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? attribute(element, kAXDescriptionAttribute) as? String ?? ""
                if heldLabels.contains(label.trimmingCharacters(in: .whitespaces)) { found.append(element) }
            }
            return false
        }
        return found.count == 1 ? found[0] : nil
    }

    /// 前台窗口里 Claude 的输入框（能用的）
    private static func messageInput(in ax: AXUIElement) -> AXUIElement? {
        guard let window = attribute(ax, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return nil }
        return search(window, depth: 0) { isMessageInput($0) }
    }

    /// 投递前（会话标签已经切到前面）：标签是「仍在别处打开」就按「Open here anyway」，等输入框能用了把光标放进去。
    /// 用户从手机给这个会话发消息，就是要在这里接着用。树没建好、认不出来的照常往下走（和以前一样）。
    /// warm = 树之前就开着：读一遍就知道；刚开的最多再等到 treeReady。回调在主线程：true = 按过
    static func openHereIfHeld(app: NSRunningApplication, treeReady: Date, completion: @escaping (Bool) -> Void) {
        queue.async {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var pressed = false
            repeat {
                if let held = heldButton(in: ax) {
                    AXUIElementPerformAction(held, kAXPressAction as CFString)
                    pressed = true
                    break
                }
                if messageInput(in: ax) != nil { break }   // 输入框能用：没被占
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < treeReady
            guard pressed else { DispatchQueue.main.async { completion(false) }; return }
            Log.write("会话仍在别处打开，已按「Open here anyway」")
            // 扩展接着重新拉起 Claude，输入框随后才能用
            let until = Date().addingTimeInterval(8)
            var input: AXUIElement?
            while Date() < until, input == nil {
                Thread.sleep(forTimeInterval: 0.3)
                if heldButton(in: ax) == nil { input = messageInput(in: ax) }
            }
            if let input { AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
            DispatchQueue.main.async { completion(true) }
        }
    }

    // MARK: - 粘贴、按键前核对焦点

    /// 投递要把字粘进、把键按进这个会话的 Claude 面板。只核对窗口标题不够：标题是当前编辑器标签的名字，键盘焦点却可能在底部的终端、
    /// 编辑器或别的面板里（10-29：焦点停在 Remote-SSH 弹出的终端里，⌘V 粘进了终端，VS Code 弹「是否确实要将 3 行文本粘贴到终端?」；
    /// 单行的不弹框，回车就在终端里执行了）
    enum Focus {
        /// 光标在这个会话的输入框里（本来就在，或刚放进去）
        case input(AXUIElement)
        /// 在这个会话的 Claude 面板里、不在输入框：按键用（确认框的选项、Esc 由面板收）
        case panel
        /// 焦点在别处、挪不进来：在哪儿（给用户看）
        case elsewhere(String)
        /// 网页的辅助功能树还读不出来（没建好）、读不到焦点：认不出，照以前的做法往下走
        case unknown
    }

    /// 粘贴 / 按键前（会话标签已经切到前面、VS Code 在前台）：焦点不在这个会话的面板里（粘贴要在输入框里），就把光标放进它的输入框再核对。
    /// titles = 会话标签可能叫的名字（SessionSnapshot.tabCandidates），认是哪个 Claude 面板（左右分屏时一个窗口里有好几个）；deadline = 树最晚该建好的时候。回调在主线程
    static func ensureFocus(app: NSRunningApplication, titles: [String], needInput: Bool, deadline: Date,
                            completion: @escaping (Focus) -> Void) {
        queue.async {
            let result = focus(app: app, titles: titles, needInput: needInput, until: max(deadline, Date().addingTimeInterval(1)))
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 粘贴之后、回车之前：焦点还在那个输入框里（nil = 在；否则是去了哪儿）。
    /// menuOK：斜杠命令粘进去会弹出命令菜单，焦点落在菜单项上（还在这个会话的面板里），回车正是要选中它，不算离开
    static func focusLeft(_ input: AXUIElement, app: NSRunningApplication, menuOK: Bool = false) -> String? {
        guard let focused = focusedElement(AXUIElementCreateApplication(app.processIdentifier)), !CFEqual(focused, input) else { return nil }
        var panel: AXUIElement? = input
        while let current = panel, attribute(current, "AXDOMIdentifier") as? String != "active-frame" {
            panel = attribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        if menuOK, let panel, isInside(focused, panel) { return nil }
        return place(of: focused, panel: panel).name
    }

    /// 输入框里现在的文字（空白统一过；空着时读到的是占位文字）。读不出 = nil。
    /// 粘贴后、回车后拿它核对：10-31 投递时前台被别的程序抢走，⌘V 粘进了那个程序，回车按在空输入框上，却报了「已提交」
    static func text(of input: AXUIElement) -> String? {
        (attribute(input, kAXValueAttribute) as? String).map(normalized)
    }

    /// 把光标放回输入框（粘贴落空、重粘之前），之后由调用方 focusLeft 核对
    static func refocus(_ input: AXUIElement) {
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func focus(app: NSRunningApplication, titles: [String], needInput: Bool, until: Date) -> Focus {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let title = titles.first ?? ""
        var tries = 0
        var result = Focus.unknown
        while true {
            let focused = focusedElement(ax)
            if let panel = sessionPanel(in: ax, titles: titles) {
                let input = search(panel, depth: 0) { isMessageInput($0) }
                if let input, let focused, CFEqual(focused, input) {
                    if tries > 0 { Log.write("已把光标放进「\(title)」的 Claude 输入框") }
                    return .input(input)
                }
                if !needInput, let focused, isInside(focused, panel) { return .panel }
                // 焦点读不到（不是读到了在别处）：认不出，照旧
                guard let focused else { result = .unknown; break }
                let place = place(of: focused, panel: panel)
                // 放进输入框；按键时面板里没有输入框（确认框占着）就放进面板
                if tries < 3, let target = input ?? (needInput ? nil : webArea(in: panel)) {
                    if tries == 0 { Log.write("焦点不在「\(title)」的 Claude 输入框（在\(place.name)），把光标放进去") }
                    AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    tries += 1
                    Thread.sleep(forTimeInterval: 0.3)
                    continue
                }
                result = .elsewhere(place.name)
                if tries >= 3 { break }   // 放了三次都没进去；没放过的是输入框还没出来（面板在加载），等到时限
            } else if let focused {
                // 认不出是哪个面板（树没建好，或分屏几个都对不上），但看得出焦点在终端、编辑器里：不往那儿粘
                let place = place(of: focused)
                result = place.typing ? .elsewhere(place.name) : .unknown
            }
            guard Date() < until else { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if case .elsewhere(let place) = result { Log.write("焦点在\(place)，没能放进「\(title)」的 Claude 输入框") }
        return result
    }

    /// 有焦点的元素。程序级的读法（AXFocusedUIElement）在 VS Code 不在前台、屏幕锁着时常读成空，
    /// 那就在前台窗口里找标着有焦点的元素（每个窗口只有一个，跨网页视图也准：焦点挪到终端后输入框就不标了，10-29 实测）
    private static func focusedElement(_ ax: AXUIElement) -> AXUIElement? {
        if let focused = attribute(ax, kAXFocusedUIElementAttribute) { return (focused as! AXUIElement) }
        guard let window = attribute(ax, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return nil }
        // 外层容器也标着的话取最里面那个（先序遍历里最后一个）
        var found: AXUIElement?
        _ = search(window, depth: 0, limit: 80) { element in
            if attribute(element, kAXFocusedAttribute) as? Bool == true, attribute(element, kAXRoleAttribute) as? String != kAXWindowRole { found = element }
            return false
        }
        return found
    }

    private static func isMessageInput(_ element: AXUIElement) -> Bool {
        attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole
            && attribute(element, kAXDescriptionAttribute) as? String == "Message input"
            && attribute(element, kAXEnabledAttribute) as? Bool != false
    }

    /// 前台窗口里这个会话的 Claude 面板：网页视图里装扩展网页的 iframe（DOM id 是 active-frame，说明文字就是标签名，看不见的标签不在树里）。
    /// 标签名对不上（扩展有时起通用名「Claude Code」，还没发过消息的会话也叫这个）时，窗口里只有一个带输入框的面板就是它
    private static func sessionPanel(in ax: AXUIElement, titles: [String]) -> AXUIElement? {
        guard let window = attribute(ax, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return nil }
        var frames: [(element: AXUIElement, name: String)] = []
        func collect(_ element: AXUIElement, depth: Int) {
            if attribute(element, "AXDOMIdentifier") as? String == "active-frame" {
                frames.append((element, attribute(element, kAXDescriptionAttribute) as? String ?? ""))
                return
            }
            guard depth < 60 else { return }
            children(element).forEach { collect($0, depth: depth + 1) }
        }
        collect(window, depth: 0)
        let named = frames.filter { frame in titles.contains { Delivery.tabTitle(frame.name, matches: $0) } }
        if named.count == 1 { return named[0].element }
        guard named.isEmpty else { return nil }
        let claude = frames.filter { search($0.element, depth: 0) { isMessageInput($0) } != nil }
        return claude.count == 1 ? claude[0].element : nil
    }

    private static func webArea(in panel: AXUIElement) -> AXUIElement? {
        search(panel, depth: 0, limit: 4) { attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }
    }

    private static func isInside(_ element: AXUIElement, _ ancestor: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<80 {
            if CFEqual(current, ancestor) { return true }
            guard let parent = attribute(current, kAXParentAttribute) else { return false }
            current = parent as! AXUIElement
        }
        return false
    }

    /// 焦点在 VS Code 的哪块（给用户看）；typing = 终端、编辑器这种打字就进去的地方
    private static func place(of element: AXUIElement, panel: AXUIElement? = nil) -> (name: String, typing: Bool) {
        var chain = [element]
        while chain.count < 80, let parent = attribute(chain[chain.count - 1], kAXParentAttribute) { chain.append(parent as! AXUIElement) }
        // 在某个网页视图（扩展的面板）里：里面的类名是扩展自己起的，不往下认
        if let frame = chain.first(where: { attribute($0, "AXDOMIdentifier") as? String == "active-frame" }) {
            if let panel, CFEqual(frame, panel) { return ("该会话面板中输入框以外的位置", false) }
            let name = attribute(frame, kAXDescriptionAttribute) as? String ?? ""
            return (name.isEmpty ? "另一个标签页" : "另一个标签页「\(name)」", false)
        }
        for current in chain {
            let classes = (attribute(current, "AXDOMClassList") as? [String] ?? []).joined(separator: " ")
            if classes.contains("xterm") || classes.contains("terminal") { return ("终端", true) }
            if classes.contains("monaco-editor") { return ("编辑器", true) }
            switch attribute(current, "AXDOMIdentifier") as? String ?? "" {
            case "workbench.parts.sidebar", "workbench.parts.auxiliarybar": return ("侧栏", false)
            case "workbench.parts.panel": return ("底部面板", false)
            case "workbench.parts.editor": return ("编辑区", false)
            case "workbench.parts.titlebar", "workbench.parts.statusbar", "workbench.parts.activitybar": return ("窗口边栏", false)
            default: break
            }
        }
        return ("VS Code 的其他位置", false)
    }

    /// 空白（换行、连续空格）统一成一个空格再比：输入框里的文字和发过去的可能差在换行上
    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// 内容就是这段话的多行输入框；先找这个项目的窗口，标题对不上（用户改过窗口标题格式）再找全部窗口。
    /// 同一遍里顺带找这个项目窗口上 VS Code 自己的对话框（标题对不上时只看当前焦点窗口，别把别的窗口里的框算进来）
    private static func scan(_ ax: AXUIElement, want: String, project: String, remote: Bool)
        -> (input: AXUIElement?, dialog: AXUIElement?, restricted: Bool) {
        let windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let mine = windows.filter { Delivery.windowTitle(attribute($0, kAXTitleAttribute) as? String ?? "", matches: project, remote: remote) }
        let focused = attribute(ax, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        var dialog: AXUIElement?
        var restricted = false
        for window in mine.isEmpty ? windows : mine {
            let watch = !mine.isEmpty || (focused.map { CFEqual($0, window) } ?? false)
            if let hit = search(window, depth: 0, match: { element in
                if watch {
                    if dialog == nil, isEditorDialog(element) { dialog = element }
                    if !restricted, isRestrictedMode(element) { restricted = true }
                }
                return attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole
                    && normalized(attribute(element, kAXValueAttribute) as? String ?? "") == want
            }) { return (hit, nil, false) }
        }
        return (nil, dialog, restricted)
    }

    /// 状态栏左边的「受限模式」项（新文件夹没信任过时 VS Code 不弹框，直接这样打开，顶上再挂一条横幅）
    private static func isRestrictedMode(_ element: AXUIElement) -> Bool {
        if attribute(element, "AXDOMIdentifier") as? String == "status.workspaceTrust" { return true }
        guard attribute(element, kAXRoleAttribute) as? String == kAXStaticTextRole,
              let value = attribute(element, kAXValueAttribute) as? String else { return false }
        return ["Restricted Mode", "受限模式"].contains(value.trimmingCharacters(in: .whitespaces))
    }

    /// VS Code 自己的模态对话框（网页里的 .monaco-dialog-box，role=dialog）。Claude 面板里的弹层不算：只认这个类名
    private static func isEditorDialog(_ element: AXUIElement) -> Bool {
        guard let subrole = attribute(element, kAXSubroleAttribute) as? String,
              subrole == "AXApplicationDialog" || subrole == "AXApplicationAlertDialog" else { return false }
        return (attribute(element, "AXDOMClassList") as? [String] ?? []).contains("monaco-dialog-box")
    }

    /// 对话框说的话：先看 aria-label，没有就取里面前两段文字（太长截断）
    private static func dialogText(_ dialog: AXUIElement) -> String {
        var text = [kAXDescriptionAttribute, kAXTitleAttribute].lazy
            .compactMap { attribute(dialog, $0) as? String }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if text.isEmpty {
            var parts: [String] = []
            _ = search(dialog, depth: 0, limit: 12) { element in
                if attribute(element, kAXRoleAttribute) as? String == kAXStaticTextRole,
                   let value = attribute(element, kAXValueAttribute) as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    parts.append(value)
                }
                return parts.count >= 2
            }
            text = parts.joined(separator: " ")
        }
        text = normalized(text)
        // aria-label 开头是图标的读法（Info / Warning …），不是框里的话
        for icon in ["Info ", "Warning ", "Error ", "信息 ", "警告 ", "错误 "] where text.hasPrefix(icon) { text = String(text.dropFirst(icon.count)) }
        return text.count > 120 ? String(text.prefix(118)) + "…" : text
    }

    /// 发送按钮和输入框在同一块输入区里：从输入框往上几层，在那块区域里找
    private static func findSend(near input: AXUIElement) -> AXUIElement? {
        var area = input
        for _ in 0..<6 {
            guard let parent = attribute(area, kAXParentAttribute) else { break }
            area = parent as! AXUIElement
            if let send = search(area, depth: 0, limit: 16, match: { element in
                attribute(element, kAXRoleAttribute) as? String == kAXButtonRole
                    && sendLabels.contains(attribute(element, kAXDescriptionAttribute) as? String ?? "")
            }) { return send }
        }
        return nil
    }

    private static func search(_ element: AXUIElement, depth: Int, limit: Int = 60,
                               match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(element) { return element }
        guard depth < limit else { return nil }
        for child in children(element) {
            if let hit = search(child, depth: depth + 1, limit: limit, match: match) { return hit }
        }
        return nil
    }
}
