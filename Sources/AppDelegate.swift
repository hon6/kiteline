import AppKit
import ServiceManagement
import SwiftUI
import KitelineKit

/// 菜单栏常驻 + 主窗口。
/// - 菜单栏图标是 Kiteline 的风筝：空闲时静止，Claude 工作时随风轻轻摆，等你确认时带个点
/// - 左键弹出面板，右键弹出菜单
/// - 主窗口开着时出现在 Dock 和 ⌘Tab；关掉后只留在菜单栏
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let state = AppState.shared
    private let model = KitelineModel.shared
    private var glyphState: TarsGlyph.State = .idle
    private var glyphTimer: Timer?
    private var glyphFrame = 0

    /// 自检开关：由命令行参数设置
    var drillNotificationsOnLaunch = false
    var showPanelOnLaunch = false
    var startInBackground = false

    private static let mainWindowOpenKey = "mainWindowOpenAtQuit"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()
        // 设置里换了界面语言：菜单栏是 AppKit 建的，不会跟着 SwiftUI 换，重建一份（右键菜单每次点开现建，不用管）
        NotificationCenter.default.addObserver(forName: Lang.didChange, object: nil, queue: .main) { _ in
            NSApp.mainMenu = Self.makeMainMenu()
            KitelineModel.shared.refresh()   // 来源状态、服务状态这些字是在模型里按语言换好的
        }
        AppAppearance.apply()
        Log.write("Kiteline 启动")
        // 测试实例：按脚本截主窗口（见 SelfTest.runCaptureScript）
        if AppConfig.isolated { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SelfTest.runCaptureScript() } }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = TarsGlyph.image(state: .idle)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Kiteline"
        }
        if AppConfig.isolated {
            // 测试实例（自测、截图用）不在菜单栏占位：几个会话各开一个时，菜单栏会多出好几个 Kiteline。
            // 显示状态 macOS 会按名字记进偏好设置，用自己的名字记，不然正式 Kiteline 下次启动图标也跟着藏起来
            statusItem.autosaveName = "TARS test instance"
            statusItem.isVisible = false
        } else {
            // 正式 App 总是显示（以前的测试实例把它记成了隐藏的，这里纠正回来）
            statusItem.isVisible = true
        }

        let panel = NSHostingController(rootView: MenuBarPanel(
            openMain: { key in MainWindowController.shared.show(select: key) },
            close: { [weak self] in self?.popover.performClose(nil) }).tarsLook(wrapButtons: true))
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.animates = true

        model.onGlyphChange = { [weak self] glyph in self?.updateGlyph(glyph) }
        state.onStoreUpdate = { [weak self] _ in
            DispatchQueue.main.async { self?.model.refresh() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(showSessionNotification(_:)),
                                               name: .ccpulseShowPanel, object: nil)

        state.start()
        model.refresh()
        // 检查更新（启动 30 秒后、之后每 6 小时；有新版本时主窗口右上角出绿色箭头）
        Updater.shared.start()
        // 使用统计（启动两分钟后、之后每 15 分钟；设置里能关）
        UsageStats.start()
        _ = UpdateWindowController.shared   // 装好后自动弹「立即重启」要它先在
        Self.defaultLoginItem()
        // 投递切走前台后还回来要知道用户之前在用什么；上次开着「VS Code 在虚拟屏幕中运行」的，这次接着开
        FrontReturn.startTracking()
        // VS Code 打开 Claude Code 扩展的链接不再弹确认框（见 EditorSettings；测试实例不碰用户的 VS Code 设置）
        if !AppConfig.isolated { EditorSettings.trustInstalledEditors() }
        VirtualScreen.shared.restoreOnLaunch()
        // 显示器关掉再打开后，对话气泡里的字会上下颠倒：屏幕变化后重画一遍
        ScreenRedraw.start()
        // 右边怎么分的屏、每块开着哪些标签：关掉再打开、重装后还在。
        // 测试实例不记（几个会话的截图会互相带上），要测这个功能时另加 CCPULSE_KEEP_PANES=1
        if !AppConfig.isolated || ProcessInfo.processInfo.environment["CCPULSE_KEEP_PANES"] == "1" {
            KitelineKit.panes.remember(in: AppConfig.defaults, key: "chatPanes")
            if let focused = KitelineKit.panes.focused { model.selection = focused }
        }

        // 上次退出时主窗口开着（或第一次运行），这次也打开；开机自启时安静地待在菜单栏
        let defaults = AppConfig.defaults
        let reopen = defaults.object(forKey: Self.mainWindowOpenKey) == nil || defaults.bool(forKey: Self.mainWindowOpenKey)
        if !startInBackground && reopen {
            MainWindowController.shared.show()
        }
        // 第一次打开（还没配过手机）：四步新手引导，压在主窗口上面
        OnboardingWindowController.showOnFirstLaunch()
        if drillNotificationsOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SelfTest.runNotificationDrill() }
        }
        if showPanelOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.togglePopover() }
        }
    }

    /// 装好后第一次运行：默认打开「登录时自动打开 Kiteline」（只做一次，之后用户在设置里关了就不再动；测试实例不碰）
    private static func defaultLoginItem() {
        let key = "loginItemDefaulted"
        guard !AppConfig.isolated, !AppConfig.defaults.bool(forKey: key) else { return }
        AppConfig.defaults.set(true, forKey: key)
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            Log.write("已默认打开登录时自动打开")
        } catch {
            Log.write("打开登录时自动打开失败：\(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Updater.shared.installIfPendingOnQuit()
        AppConfig.defaults.set(MainWindowController.shared.isVisible, forKey: Self.mainWindowOpenKey)
        KitelineKit.panes.save()
        VirtualScreen.shared.prepareForQuit()
        state.shutdown()
        Log.write("Kiteline 退出")
    }

    /// 点 Dock 图标：没有窗口时重新打开主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowController.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - 菜单栏图标

    private func updateGlyph(_ glyph: TarsGlyph.State) {
        guard let button = statusItem?.button else { return }
        let waiting = model.waitingCount
        button.title = waiting > 0 ? " \(waiting)" : ""
        button.toolTip = "Kiteline — \(model.summary)"
        guard glyph != glyphState || button.image == nil else { return }
        glyphState = glyph
        glyphTimer?.invalidate()
        glyphTimer = nil
        button.image = TarsGlyph.image(state: glyph)
        if glyph == .busy {
            // 工作中：风筝随风轻轻摆
            glyphTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.glyphFrame += 1
                self.statusItem.button?.image = TarsGlyph.image(state: .busy, frame: self.glyphFrame)
            }
        }
    }

    // MARK: - 点击

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(item(L("打开 Kiteline"), #selector(menuOpenMain), "o"))
        menu.addItem(item(L("手机访问…"), #selector(menuPhone), "m"))
        menu.addItem(item(L("设置…"), #selector(menuSettings), ","))
        menu.addItem(.separator())
        if VirtualScreen.supported {
            menu.addItem(item(VirtualScreen.shared.isOn ? L("VS Code 移回主屏幕") : L("VS Code 移到虚拟屏幕"), #selector(menuVirtualScreen), ""))
        }
        menu.addItem(item(L("重新连接"), #selector(menuReconnect), "r"))
        menu.addItem(item(L("发送测试提醒"), #selector(menuTestNotification), ""))
        menu.addItem(.separator())
        menu.addItem(item(L("退出 Kiteline"), #selector(menuQuit), "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// 应用菜单 + 编辑菜单：⌘C / ⌘V / ⌘X / ⌘A / ⌘Z 在输入框（对话页、设置、新建任务）里才有人接
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: L("关于 Kiteline"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: L("检查更新…"), action: #selector(menuCheckUpdate), keyEquivalent: "")
        app.addItem(withTitle: L("更新记录…"), action: #selector(menuChangelog), keyEquivalent: "")
        app.addItem(withTitle: L("新手引导…"), action: #selector(menuOnboarding), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("设置…"), action: #selector(menuSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: L("隐藏 Kiteline"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: L("隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L("全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        // 不给 ⌘Q：Kiteline 平时在后台跑，误按退出就收不到提醒了；要退出用菜单栏图标里的「退出 Kiteline」
        app.addItem(withTitle: L("退出 Kiteline"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)

        let file = NSMenu(title: L("文件"))
        file.addItem(withTitle: L("新任务…"), action: #selector(menuNewTask), keyEquivalent: "n")
        file.addItem(withTitle: L("历史会话"), action: #selector(menuHistory), keyEquivalent: "y")
        file.addItem(withTitle: L("世界模式"), action: #selector(menuWorld), keyEquivalent: "E")   // ⇧⌘E：进出世界
        file.addItem(withTitle: L("数据流大屏"), action: #selector(menuFlow), keyEquivalent: "D")   // ⇧⌘D：进出数据流大屏
        file.addItem(.separator())
        // 会话的标签页（同浏览器）：⌘T 新标签、⌘W 关标签（没有标签可关时关窗口）
        file.addItem(withTitle: L("新标签页"), action: #selector(menuNewTab), keyEquivalent: "t").tag = TabNeed.conversation.rawValue
        file.addItem(withTitle: L("关闭标签页"), action: #selector(menuCloseTab), keyEquivalent: "w")
        let fileItem = NSMenuItem()
        fileItem.submenu = file
        main.addItem(fileItem)

        let edit = NSMenu(title: L("编辑"))
        edit.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        // 会话：对右边正在看的那个会话（标题栏按钮、「⋯」里的同一批操作）；没选会话时变灰（见 validateMenuItem）
        let session = NSMenu(title: L("会话"))
        func add(_ title: String, _ action: Selector, _ key: String = "", _ need: SessionNeed, _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = session.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = need.rawValue
        }
        add(L("在对话里搜索…"), #selector(menuSearch), "f", .conversation)
        add(L("项目文件"), #selector(menuFiles), "", .conversation)
        add(L("改动报告"), #selector(menuChanges), "", .live)
        add(L("测试报告"), #selector(menuTests), "", .live)
        add(L("子 agent"), #selector(menuAgents), "", .live)
        add(L("会话信息"), #selector(menuInfo), "i", .live)
        add(L("切换终端"), #selector(menuTerminal), "`", .live, .control)   // 同 VS Code 切换终端：⌃`
        add(L("Agent 详情…"), #selector(menuAgentInfo), "", .conversation)
        session.addItem(.separator())
        add(L("权限模式…"), #selector(menuMode), "", .reply)
        add(L("模型和思考等级…"), #selector(menuModel), "", .reply)
        add(L("压缩上下文（/compact）…"), #selector(menuCompact), "", .reply)
        add(L("中断 %@…", "Claude"), #selector(menuStop), ".", .busy)
        add(L("关闭会话…"), #selector(menuCloseSession), "", .reply)
        session.addItem(.separator())
        add(L("跳到最新"), #selector(menuBottom), "", .conversation)
        add(L("在 VS Code 中打开"), #selector(menuJump), "", .live)
        let sessionItem = NSMenuItem()
        sessionItem.submenu = session
        main.addItem(sessionItem)

        let window = NSMenu(title: L("窗口"))
        window.addItem(withTitle: L("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        window.addItem(.separator())
        // 切标签：⇧⌘[ / ⇧⌘]（菜单里看得到），⌃⇧⇥ / ⌃⇥ 同浏览器，⌘1…⌘8 第几个、⌘9 最后一个（这几个不占菜单）
        func tabItem(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags, hidden: Bool = false, number: Int = 0) {
            let item = window.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = TabNeed.switching.rawValue
            item.representedObject = number
            if hidden {
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
            }
        }
        tabItem(L("显示上一个标签页"), #selector(menuPreviousTab), "{", .command)
        tabItem(L("显示下一个标签页"), #selector(menuNextTab), "}", .command)
        tabItem(L("显示上一个标签页"), #selector(menuPreviousTab), "\t", [.control, .shift], hidden: true)
        tabItem(L("显示下一个标签页"), #selector(menuNextTab), "\t", .control, hidden: true)
        for number in 1...9 {
            tabItem(number == 9 ? L("显示最后一个标签页") : L("显示第 %@ 个标签页", "\(number)"), #selector(menuSelectTab(_:)), "\(number)", .command, hidden: true, number: number)
        }
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 「会话」菜单里的一项要什么条件才能点
    enum SessionNeed: Int { case conversation = 1, live, reply, busy }
    /// 标签页那几项：conversation = 主窗口在前、右边是会话；switching = 还要当前块有两个以上标签
    enum TabNeed: Int { case conversation = 101, switching }

    /// 主窗口在前、右边显示的是会话（不是今日动态、历史这些页）
    private var showingConversation: Bool {
        guard MainWindowController.shared.window?.isKeyWindow == true else { return false }
        let selection = KitelineModel.shared.selection
        if selection?.hasPrefix("@") == true { return false }
        return MainActor.assumeIsolated { selection != nil || !KitelineKit.panes.isPristine }
    }

    /// 右边正在看的会话：在跑的（SessionItem）或已结束的（历史里打开的）
    private var current: (key: String, live: SessionItem?)? {
        let model = KitelineModel.shared
        if let item = model.session(model.selection) { return (item.id, item) }
        if let past = HistoryModel.shared.past(model.selection) { return (past.key, nil) }
        return nil
    }

    private func perform(_ action: KitelineKit.Action) {
        guard let key = current?.key else { return }
        MainWindowController.shared.show()
        MainActor.assumeIsolated { KitelineKit.perform(action, key: key) }   // 菜单项都在主线程上点
    }

    @objc private func menuNewTask() { MainWindowController.shared.show(); KitelineModel.shared.newTask(in: current?.live) }
    @objc private func menuWorld() {
        MainWindowController.shared.show()
        KitelineModel.shared.toggleWorld(page: "world")
    }
    @objc private func menuFlow() {
        MainWindowController.shared.show()
        KitelineModel.shared.toggleWorld(page: "flow")
    }
    @objc private func menuHistory() { MainWindowController.shared.show(select: KitelineModel.historyID) }
    @objc private func menuSearch() { perform(.search) }
    @objc private func menuFiles() { perform(.files) }
    @objc private func menuTerminal() { perform(.terminal) }
    @objc private func menuChanges() { perform(.changes) }
    @objc private func menuTests() { perform(.tests) }
    @objc private func menuAgents() { perform(.agents) }
    @objc private func menuInfo() { perform(.info) }
    @objc private func menuAgentInfo() { perform(.agentInfo) }
    @objc private func menuMode() { perform(.mode) }
    @objc private func menuModel() { perform(.model) }
    @objc private func menuStop() { perform(.stop) }
    @objc private func menuBottom() { perform(.bottom) }
    @objc private func menuCompact() { if let key = current?.live?.id { KitelineModel.shared.compact(key) } }
    @objc private func menuJump() { if let key = current?.live?.id { KitelineModel.shared.jump(key) } }
    @objc private func menuCloseSession() { if let key = current?.live?.id { KitelineModel.shared.close(key) } }

    @objc private func menuNewTab() { if showingConversation { MainActor.assumeIsolated { _ = KitelineKit.tab(.new) } } }
    @objc private func menuNextTab() { if showingConversation { MainActor.assumeIsolated { _ = KitelineKit.tab(.next) } } }
    @objc private func menuPreviousTab() { if showingConversation { MainActor.assumeIsolated { _ = KitelineKit.tab(.previous) } } }
    @objc private func menuSelectTab(_ sender: NSMenuItem) {
        guard showingConversation, let number = sender.representedObject as? Int else { return }
        MainActor.assumeIsolated { _ = KitelineKit.tab(number == 9 ? .last : .select(number)) }
    }
    /// ⌘W：主窗口里有标签就关当前标签（同浏览器），没有可关的就关掉最前面的窗口（设置、更新记录窗口照旧 ⌘W 关）
    @objc private func menuCloseTab() {
        if showingConversation, MainActor.assumeIsolated({ KitelineKit.tab(.close) }) { return }
        NSApp.keyWindow?.performClose(nil)
    }

    @objc private func menuOpenMain() { MainWindowController.shared.show() }
    @objc private func menuPhone() { SettingsWindowController.shared.show(tab: .phone) }
    @objc private func menuSettings() { SettingsWindowController.shared.show(tab: .general) }
    @objc private func menuChangelog() { ChangelogWindowController.shared.show() }
    @objc private func menuOnboarding() { OnboardingWindowController.shared.show() }
    @objc private func menuReconnect() { state.reconnect() }
    @objc private func menuVirtualScreen() { VirtualScreen.shared.toggle() }
    @objc private func menuTestNotification() { NotificationCenterBridge.shared.deliverTest(config: state.config) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// 「检查更新…」：现在去查；有新版本、正在下载、装好待重启时直接打开更新窗口
    @objc private func menuCheckUpdate() {
        let updater = Updater.shared
        if [.idle, .none, .error].contains(updater.phase) { updater.check(manual: true) }
        UpdateWindowController.shared.show()
    }

    /// 点了系统通知：打开主窗口并选中那个会话
    @objc private func showSessionNotification(_ note: Notification) {
        MainWindowController.shared.show(select: note.userInfo?["sessionKey"] as? String)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// 「会话」菜单：没选会话、会话已结束、不能回复、没在干活时对应的项变灰
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let need = TabNeed(rawValue: menuItem.tag) {
            guard showingConversation else { return false }
            return need == .conversation || MainActor.assumeIsolated { KitelineKit.tabCount > 1 }
        }
        if menuItem.action == #selector(menuCloseTab) { return NSApp.keyWindow != nil }
        guard let need = SessionNeed(rawValue: menuItem.tag) else { return true }
        guard let current else { return false }
        // 权限模式、换模型、压缩、子 agent、测试：这个 agent 有才能点（caps）；中断写上是谁
        let caps: [Selector: String] = [#selector(menuMode): "mode", #selector(menuModel): "model", #selector(menuCompact): "compact",
                                        #selector(menuAgents): "subagents", #selector(menuTests): "tests"]
        if let action = menuItem.action, let cap = caps[action], let live = current.live, !live.can(cap) { return false }
        if menuItem.action == #selector(menuStop) { menuItem.title = L("中断 %@…", Agents.info(current.live?.agent).speaker) }
        // 关闭会话：caps 有 close 才能点（目前是 Claude Code）
        if menuItem.action == #selector(menuCloseSession), current.live?.can("close") != true { return false }
        switch need {
        case .conversation: return true
        case .live: return current.live != nil
        case .reply: return current.live?.canReply == true
        case .busy: return current.live?.activity == .busy && current.live?.canReply == true
        }
    }
}
