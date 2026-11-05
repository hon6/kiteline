import AppKit
import CoreImage
import ServiceManagement
import SwiftUI
import UserNotifications
import KitelineKit

enum SettingsTab: Int, CaseIterable {
    case general, phrases, schedules, phone, remote, devices, watch, sources, plugins, permissions, audit, about

    /// 顶上工具栏标签的名字。英文另写一套短的（系统设置窗口的惯例）：11 个标签得在 780 宽的工具栏里摆下，
    /// 用表里的长译名（Quick Replies、Scheduled Tasks……）会把后几个挤进「»」里找不到（实测）
    var title: String {
        if Lang.shared.isEnglish {
            switch self {
            case .general: return "General"
            case .phrases: return "Replies"
            case .schedules: return "Schedules"
            case .phone: return "Phone"
            case .remote: return "Remote"
            case .devices: return "Devices"
            case .watch: return "Watch"
            case .sources: return "Sources"
            case .plugins: return "Plugins"
            case .permissions: return "Privacy"
            case .audit: return "Log"
            case .about: return "About"
            }
        }
        switch self {
        case .general: return "通用"
        case .phrases: return "快捷短语"
        case .schedules: return "定时任务"
        case .phone: return "手机访问"
        case .remote: return "远程访问"
        case .devices: return "设备"
        case .watch: return "Apple Watch"
        case .sources: return "来源"
        case .plugins: return "插件"
        case .permissions: return "权限"
        case .audit: return "操作记录"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .phrases: return "text.bubble"
        case .schedules: return "alarm"
        case .phone: return "iphone.gen3"
        case .remote: return "globe"
        case .devices: return "person.badge.key"
        case .watch: return "applewatch"
        case .sources: return "server.rack"
        case .plugins: return "puzzlepiece.extension"
        case .permissions: return "lock.shield"
        case .audit: return "list.bullet.rectangle"
        case .about: return "info.circle"
        }
    }
}

/// 设置窗口：系统设置同款的工具栏标签页，每页是一个 SwiftUI 视图
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let width: CGFloat = 780
    private let tabs = NSTabViewController()

    private init() {
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            // 每页一样宽：工具栏上 11 个标签都摆得下（窄了后几个会收进「»」里找不到）
            let hosting = NSHostingController(rootView: AnyView(SettingsWindowController.pane(tab).frame(minWidth: SettingsWindowController.width).tarsLook(wrapButtons: true)))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = tab.title   // 工具栏式标签页拿当前页的标题当窗口标题；不设就显示 Untitled
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = L("Kiteline 设置")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // 换了界面语言：顶上的标签页、窗口标题是 AppKit 的，建好就不变，跟着重设（页面内容是 SwiftUI，自己会换）
        NotificationCenter.default.addObserver(forName: Lang.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.relabel()
        }
    }

    private func relabel() {
        for (item, tab) in zip(tabs.tabViewItems, SettingsTab.allCases) {
            item.label = tab.title
            item.viewController?.title = tab.title
            item.image?.accessibilityDescription = tab.title
        }
        let index = tabs.selectedTabViewItemIndex
        window?.title = tabs.tabViewItems.indices.contains(index) ? (tabs.tabViewItems[index].viewController?.title ?? L("Kiteline 设置"))
                                                                  : L("Kiteline 设置")
    }

    required init?(coder: NSCoder) { fatalError() }

    @ViewBuilder
    private static func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralPane()
        case .phrases: PhrasesPane()
        case .schedules: SchedulesPane()
        case .phone: PhonePane()
        case .remote: RemotePane()
        case .devices: DevicesPane()
        case .watch: WatchPane()
        case .sources: SourcesPane()
        case .plugins: PluginsPane()
        case .permissions: PermissionsPane()
        case .audit: AuditPane()
        case .about: AboutPane()
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        NSApp.setActivationPolicy(.regular)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 自测截图用：切到某一页、放到屏幕里压在最底下（不激活、不抢焦点），返回窗口
    func showForCapture(tab: SettingsTab) -> NSWindow? {
        tabs.selectedTabViewItemIndex = tab.rawValue
        // 放进屏幕（系统列表才算对行高）但全透明、鼠标穿透：用户屏幕上看不见（同新手引导的 showForCapture）
        window?.alphaValue = 0
        window?.ignoresMouseEvents = true
        window?.setFrameOrigin(NSPoint(x: 60, y: 60))
        window?.orderBack(nil)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            if !MainWindowController.shared.isVisible && !ChangelogWindowController.shared.isVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: - 通用

/// 「VS Code 在虚拟屏幕中运行」（同菜单栏面板、主窗口侧栏底部的显示器按钮）
private struct VirtualScreenSection: View {
    @ObservedObject private var screen = VirtualScreen.shared

    var body: some View {
        Section {
            Toggle("VS Code 在虚拟屏幕中运行", isOn: Binding(get: { screen.isOn }, set: { on in
                if on != screen.isOn { screen.toggle() }
            }))
            if screen.isOn {
                LabeledContent("虚拟屏幕中的窗口", value: L("%lld 个", count: screen.windowCount))
            }
        } header: {
            Text("VS Code")
        } footer: {
            Text("将 VS Code 的窗口移到一块看不见的虚拟屏幕上：Kiteline 发送消息、按键时，VS Code 不会出现在你面前，完成后自动回到你原来使用的程序。鼠标不会进入虚拟屏幕。需要查看 VS Code 时，关闭此项或点击「在 VS Code 中打开」即可移回；退出 Kiteline 时窗口自动回到原处。")
                .foregroundStyle(.secondary)
        }
    }
}

struct GeneralPane: View {
    @State private var config = AppState.shared.config
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            ProfileSection()
            LookSection()
            PeerSection()
            Section("提醒") {
                Toggle("Claude 请求确认时提醒", isOn: binding(\.notifyOnNeedsAttention))
                Toggle("Claude 完成任务时提醒", isOn: binding(\.notifyOnConclusion))
                Toggle("提醒时播放声音", isOn: binding(\.playSound))
                Toggle("等待确认超过 10 分钟、30 分钟时再次提醒", isOn: binding(\.mobile.remindWaiting))
                Toggle("免打扰时段（仅推送需要确认的消息）", isOn: Binding(get: { !config.mobile.quietStart.isEmpty }, set: { on in
                    setQuiet(on ? "23:00" : "", on ? "08:00" : "")
                }))
                if !config.mobile.quietStart.isEmpty {
                    HStack {
                        DatePicker("从", selection: quietBinding(start: true), displayedComponents: .hourAndMinute)
                        DatePicker("到", selection: quietBinding(start: false), displayedComponents: .hourAndMinute)
                    }
                }
            }
            Section {
                Toggle("自动关闭 24 小时未查看的会话", isOn: binding(\.mobile.autoCloseIdle))
            } header: {
                Text("会话")
            } footer: {
                Text("24 小时内未在 Kiteline 中打开过详情的会话（包括已标记、已置顶的），将自动关闭其在电脑上的标签页并移入「历史会话」；其他会话发来消息、会话在后台回复均不计为打开。正在运行的会话待本轮结束后再关闭；需要切换 VS Code 时，等电脑 10 分钟无人操作后进行。在历史会话中打开并发送消息即可恢复。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("每天推送日报", isOn: Binding(get: { !config.mobile.digestTime.isEmpty }, set: { on in
                    setDigestTime(on ? "21:30" : "")
                }))
                if !config.mobile.digestTime.isEmpty {
                    DatePicker("推送时间", selection: Binding(get: {
                        DailyReport.scheduledDate(config.mobile.digestTime) ?? Date()
                    }, set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        setDigestTime(String(format: "%02d:%02d", parts.hour ?? 21, parts.minute ?? 30))
                    }), displayedComponents: .hourAndMinute)
                }
                Toggle("早安简报（昨晚动态及待确认会话）", isOn: Binding(get: { !config.mobile.morningTime.isEmpty }, set: { on in
                    setMorningTime(on ? "08:30" : "")
                }))
                if !config.mobile.morningTime.isEmpty {
                    DatePicker("早安简报时间", selection: Binding(get: {
                        DailyReport.scheduledDate(config.mobile.morningTime) ?? Date()
                    }, set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        setMorningTime(String(format: "%02d:%02d", parts.hour ?? 8, parts.minute ?? 30))
                    }), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("日报")
            } footer: {
                Text("按时汇总当天各项目的工作内容（对话轮数、改动文件、测试结果、截图），推送到手机和这台 Mac。")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Bark 地址", text: Binding(get: { config.mobile.barkURL }, set: { value in
                    config.mobile.barkURL = value
                    AppState.shared.updatePreferences { $0.mobile.barkURL = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                }), prompt: Text("https://api.day.app/你的密钥"))
                if Bark.parse(config.mobile.barkURL) != nil {
                    Picker("推送范围", selection: binding(\.mobile.barkMode)) {
                        Text("仅推送需要确认的消息（及花费提醒）").tag("attention")
                        Text("全部提醒").tag("all")
                        Text("暂停").tag("off")
                    }
                    SecureField("加密密钥（可选）", text: binding(\.mobile.barkKey), prompt: Text("16 / 24 / 32 个字符"))
                    if !config.mobile.barkKey.isEmpty {
                        TextField("加密 IV", text: binding(\.mobile.barkIV), prompt: Text("16 个字符"))
                    }
                    HStack {
                        Spacer()
                        Button("发送测试") {
                            Bark.send(title: "Kiteline 测试", body: "Bark 备用推送通道正常 ✓", kind: "attention", config: AppState.shared.config.mobile) { ok, message in
                                KitelineModel.alert(ok ? L("已发送") : L("发送失败"), ok ? L("请在手机上的 Bark 中确认是否收到。") : message)
                            }
                        }
                    }
                }
            } header: {
                Text("Bark 备用推送")
            } footer: {
                Text("当网页推送被专注模式屏蔽，或因未安装证书而无法接收时，可作为备用通道：安装免费的 Bark App，并将其提供的地址填入此处。需要确认的消息以「时效性」级别推送，专注模式下同样会提醒。推送内容会经过 Bark 服务器；如需保护隐私，请在 Bark App 中开启加密，并在此填入相同的密钥。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("每日花费超出预算时提醒", isOn: Binding(get: { config.mobile.dailyBudget > 0 }, set: { on in
                    setBudget(on ? 100 : 0)
                }))
                if config.mobile.dailyBudget > 0 {
                    HStack {
                        Text("每日预算（美元）")
                        Spacer()
                        TextField("", value: Binding(get: { config.mobile.dailyBudget }, set: { setBudget(max(1, $0)) }),
                                  format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }
                Toggle("每日花费达到上限后拦截", isOn: Binding(get: { config.mobile.dailyCap > 0 }, set: { on in
                    setCap(on ? 300 : 0)
                }))
                if config.mobile.dailyCap > 0 {
                    HStack {
                        Text("每日上限（美元）")
                        Spacer()
                        TextField("", value: Binding(get: { config.mobile.dailyCap }, set: { setCap(max(1, $0)) }),
                                  format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }
            } header: {
                Text("花费提醒与上限")
            } footer: {
                Text("提醒：当日所有机器的总花费达到预算的 80% 和 100% 时各推送一次。上限：达到上限后跳过定时任务，新建任务、恢复会话和手机发送消息需先确认（允许操作与回答提问不受影响）。花费数据取自 Claude Code 的记录。")
                    .foregroundStyle(.secondary)
            }
            Section("从手机或本机发送消息") {
                Toggle("发送后直接提交给 Claude", isOn: binding(\.mobile.submitOnSend))
                Picker("「按住说话」识别语言", selection: binding(\.mobile.voiceLocale)) {
                    Text("普通话").tag("zh-CN")
                    Text("粤语").tag("zh-HK")
                    Text("台湾国语").tag("zh-TW")
                    Text("English").tag("en-US")
                }
                // 识别引擎：普通话用本机 Fun-ASR-Nano（下载中显示进度）
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("识别引擎", value: config.mobile.voiceLocale == "zh-CN" ? ServerLang.ui(LocalASR.statusText) : L("系统语音识别"))
                }
            }
            if VirtualScreen.supported { VirtualScreenSection() }
            Section {
                Toggle("安装截图技能", isOn: binding(\.mobile.installAgentSkill))
                Toggle("安装网页测试技能", isOn: binding(\.mobile.installTestSkill))
                Toggle("安装待办与关键信息技能", isOn: binding(\.mobile.installTodoSkill))
                Toggle("安装任务阶段技能", isOn: binding(\.mobile.installStageSkill))
                LabeledContent("其他编程 agent") {
                    Button("在「插件」中管理") { SettingsWindowController.shared.show(tab: .plugins) }
                }
            } header: {
                Text("Agent 集成")
            } footer: {
                Text("技能会装给这台电脑和远端电脑上的各个编程 agent（Claude Code、Codex、OpenCode、DeepSeek Harness 等）。截图技能使 agent 回复时尽量附带相关截图；网页测试技能使 agent 完成网页功能后在浏览器中实际操作一遍，并发来带截图的测试报告；待办与关键信息技能使 agent 把需要以后处理的事加入待办，并把账号、密码等关键信息单独发来，方便收藏；任务阶段技能使 agent 按任务的实际做法规划步骤，并在进入每一步时主动报告，会话列表据此显示「2/4 开发中」；Claude Code 进入下一步却没有报告时，Kiteline 会提醒它补报（未安装时按 agent 的操作自动识别）。各 agent 的接入、开关和兼容情况在「插件」页查看和管理。")
                    .foregroundStyle(.secondary)
            }
            Section("启动") {
                Toggle("登录时自动打开 Kiteline", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            KitelineModel.alert(L("设置失败"), error.localizedDescription)
                        }
                    }
            }
            Section {
                Toggle("发送使用统计", isOn: Binding(get: { config.mobile.usageStats }, set: { on in
                    config.mobile.usageStats = on
                    AppState.shared.updatePreferences { $0.mobile.usageStats = on }
                    if on { UsageStats.tick(force: true) }
                }))
            } header: {
                Text("帮助改进 Kiteline")
            } footer: {
                Text("定期发送设备数量与型号、会话的 Agent、模型、token 用量、上下文长度与时长，以及你在 Kiteline 中的名字，用于改进产品。不包含对话、代码、文件和项目路径。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.width, height: 720)
    }

    private func setCap(_ value: Double) {
        config.mobile.dailyCap = value
        AppState.shared.updatePreferences { $0.mobile.dailyCap = value }
    }

    private func setBudget(_ value: Double) {
        config.mobile.dailyBudget = value
        AppState.shared.updatePreferences { $0.mobile.dailyBudget = value }
        if value > 0 { BudgetWatch.shared.check() }
    }

    private func setQuiet(_ start: String, _ end: String) {
        config.mobile.quietStart = start
        config.mobile.quietEnd = end
        AppState.shared.updatePreferences { $0.mobile.quietStart = start; $0.mobile.quietEnd = end }
    }

    private func quietBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            DailyReport.scheduledDate(start ? config.mobile.quietStart : config.mobile.quietEnd) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let text = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            setQuiet(start ? text : config.mobile.quietStart, start ? config.mobile.quietEnd : text)
        })
    }

    private func setMorningTime(_ value: String) {
        config.mobile.morningTime = value
        AppState.shared.updatePreferences { $0.mobile.morningTime = value }
    }

    private func setDigestTime(_ value: String) {
        config.mobile.digestTime = value
        AppState.shared.updatePreferences { $0.mobile.digestTime = value }
    }

    private func binding<T>(_ path: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(get: { config[keyPath: path] }, set: { value in
            config[keyPath: path] = value
            AppState.shared.updatePreferences { $0[keyPath: path] = value }
        })
    }
}

// MARK: - 定时任务

struct SchedulesPane: View {
    @State private var tasks: [Scheduler.Task] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("到达设定时间后，在项目的 VS Code 窗口中新建会话并将任务发送给 Claude。新建方式：在主窗口「新任务」或手机端新任务中选择「定时」。")
                    .font(.app(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
            }
            List {
                if tasks.isEmpty { Text("暂无定时任务").foregroundStyle(.secondary) }
                ForEach(tasks, id: \.id) { task in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: Binding(get: { task.enabled }, set: { on in
                            _ = Scheduler.shared.update(task.id, enabled: on)
                            reload()
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(Scheduler.shared.label(task)).font(.app(size: 13, weight: .bold))
                                Text((task.cwd as NSString).lastPathComponent).font(.app(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            Text(task.prompt).font(.app(size: 12)).lineLimit(2)
                            HStack(spacing: 10) {
                                if let next = Scheduler.shared.nextRun(task) {
                                    Text("下次 \(Format.short(next.timeIntervalSince1970 * 1000))").foregroundStyle(Color.tarsBrand)
                                }
                                if let last = task.lastRun {
                                    Text("上次 \(Format.short(last))：\(task.lastResult ?? "")")
                                        .foregroundStyle(task.lastOk == false ? Color.red : Color.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .font(.app(size: 11))
                        }
                        Spacer()
                        Button("运行") { Scheduler.shared.run(task.id) { _, _ in reload() } }.controlSize(.small)
                            .help("立即运行一次")
                        Button(role: .destructive) { Scheduler.shared.remove(task.id); reload() } label: { Image(systemName: "trash") }
                            .controlSize(.small).help("删除")
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 340)
        }
        .padding(20)
        .frame(width: SettingsWindowController.width)
        .onAppear(perform: reload)
    }

    private func reload() { tasks = Scheduler.shared.tasks }
}

// MARK: - 设备

struct DevicesPane: View {
    @State private var devices: [DeviceStore.Device] = []
    @State private var online: Set<String> = []

    /// 设备图标：名字或浏览器标识里看是 iPad、手机还是电脑（App 配对的名字是「Kiteline App (iPhone)」，标识里不一定带 iPhone）
    static func symbol(_ device: DeviceStore.Device) -> String {
        let text = device.name + " " + device.agent
        if text.contains("iPad") { return "ipad" }
        if text.contains("iPhone") || text.contains("Android") { return "iphone" }
        if text.contains("Watch") { return "applewatch" }
        return "laptopcomputer"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("每台已配对的手机都有独立的密钥。如手机丢失或不再使用，可在此停用：密钥将失效、连接断开，并停止向其推送。")
                .font(.app(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                if devices.isEmpty {
                    Text("暂无已配对的设备。请使用「手机访问」中的二维码或配对码进行配对。").foregroundStyle(.secondary)
                }
                ForEach(devices, id: \.id) { device in
                    HStack(spacing: 10) {
                        Image(systemName: Self.symbol(device))
                            .font(.app(size: 18)).frame(width: 26)
                            .foregroundStyle(online.contains(device.id) ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(device.name).font(.app(size: 13, weight: .semibold))
                                if online.contains(device.id) {
                                    Text("在线").font(.app(size: 10, weight: .medium)).foregroundStyle(.green)
                                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.green.opacity(0.12), in: Capsule())
                                }
                            }
                            Text("最后使用 \(Format.short(device.lastSeen)) · \(device.lastIP) · \(device.via)配对于 \(Format.short(device.createdAt))")
                                .font(.app(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            if let watch = device.watch, watch.paired {
                                Label(watch.label, systemImage: "applewatch")
                                    .font(.app(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("停用", role: .destructive) { revoke(device) }.controlSize(.small)
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 300)
            HStack {
                Text("扫码链接本身也是一把密钥（手机首次打开后会换成专属密钥）。如怀疑链接泄露，请前往「手机访问 → 重置令牌」。")
                    .font(.app(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
            }
        }
        .padding(20)
        .frame(width: SettingsWindowController.width)
        .onAppear(perform: reload)
    }

    private func reload() {
        devices = DeviceStore.shared.all
        online = AppState.shared.mobile.onlineDeviceIds
    }

    private func revoke(_ device: DeviceStore.Device) {
        let alert = NSAlert()
        alert.messageText = L("停用「%@」？", "\(device.name)")
        alert.informativeText = L("此设备将立即断开，之后需重新扫码或输入配对码才能连接。")
        alert.addButton(withTitle: L("停用"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppState.shared.mobile.revokeDevice(device.id)
        Audit.note(L("停用设备"), detail: L("%@（在 Mac 设置里）", "\(device.name)"))
        reload()
    }
}

// MARK: - 操作记录

struct AuditPane: View {
    @State private var entries: [[String: Any]] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("记录手机与对话页的所有操作：发送消息、确认、新建任务、恢复会话、修改设置、配对。失败的操作以红色标示。")
                    .font(.app(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Audit.fileURL]) }
            }
            List {
                if entries.isEmpty {
                    Text("暂无记录").foregroundStyle(.secondary)
                }
                ForEach(entries.indices, id: \.self) { index in
                    row(entries[index])
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 380)
        }
        .padding(20)
        .frame(width: SettingsWindowController.width)
        .onAppear(perform: reload)
    }

    private func reload() { entries = Audit.recent(limit: 300) }

    private func row(_ entry: [String: Any]) -> some View {
        let ok = entry["ok"] as? Bool ?? true
        let ts = Digest.number(entry["ts"])
        // 动作、说明、失败原因、来自哪台设备是记录时存下的中文：显示时按界面语言换；对象（会话标题）是内容，不动
        let title = [(entry["action"] as? String).map(ServerLang.ui), entry["target"] as? String].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 10) {
            Text(Format.short(ts)).font(.app(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(size: 12.5, weight: .semibold)).lineLimit(1)
                if let detail = entry["detail"] as? String { Text(ServerLang.ui(detail)).font(.app(size: 11.5)).lineLimit(2) }
                if !ok, let message = entry["message"] as? String {
                    Text(ServerLang.ui(message)).font(.app(size: 11.5)).foregroundStyle(.red).lineLimit(2)
                }
                Text(ServerLang.ui(entry["client"] as? String ?? "")).font(.app(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? Color.green : Color.red)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 快捷短语

struct PhrasesPane: View {
    @State private var items: [Phrase] = AppState.shared.config.mobile.quickReplies.map(Phrase.init)
    @State private var selection: Phrase.ID?

    struct Phrase: Identifiable, Hashable {
        let id = UUID()
        var text: String
        init(_ text: String) { self.text = text }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("显示在对话页输入框上方：点击直接发送给 Claude，长按则填入输入框以便编辑。手机与 Mac 共用此列表。")
                .font(.app(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach($items) { $item in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).font(.app(size: 11))
                        TextField("短语", text: $item.text, onCommit: save)
                            .textFieldStyle(.plain)
                    }
                    .padding(.vertical, 3)
                    .tag(item.id)
                }
                .onMove { from, to in items.move(fromOffsets: from, toOffset: to); save() }
                .onDelete { offsets in items.remove(atOffsets: offsets); save() }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 300)
            HStack(spacing: 8) {
                Button { items.append(Phrase("")); selection = items.last?.id } label: { Image(systemName: "plus") }
                    .help("添加")
                    .disabled(items.count >= 24)
                Button {
                    if let id = selection { items.removeAll { $0.id == id }; selection = nil; save() }
                } label: { Image(systemName: "minus") }
                    .help("删除所选")
                    .disabled(selection == nil)
                Spacer()
                Button("恢复默认") { items = MobileConfig.defaultQuickReplies.map(Phrase.init); save() }
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: SettingsWindowController.width)
        .onDisappear(perform: save)
    }

    private func save() {
        let cleaned = MobileConfig.cleanQuickReplies(items.map(\.text))
        guard cleaned != AppState.shared.config.mobile.quickReplies else { return }
        AppState.shared.updatePreferences { $0.mobile.quickReplies = cleaned }
    }
}

// MARK: - 手机访问

struct PhonePane: View {
    @ObservedObject var model = KitelineModel.shared
    @State private var addresses: [(label: String, base: String)] = []
    @State private var selected = 0
    @State private var code = ""
    @State private var expiry = Date()
    @State private var pushCount = 0
    /// 二维码里的一次性配对令牌（10 分钟有效、配上一台就作废）；主令牌不再放进二维码
    @State private var token = ""

    private var link: String? {
        guard selected < addresses.count else { return nil }
        return PhoneAccess.pairingLink(base: addresses[selected].base, token: token)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white)
                    if let link = link, let qr = PhoneAccess.qrImage(for: link) {
                        Image(nsImage: qr).interpolation(.none).resizable().padding(14)
                    } else {
                        Text(AppState.shared.config.mobile.httpsEnabled ? "没有可用的网络地址" : "请先开启 HTTPS 服务").foregroundStyle(.black.opacity(0.5))
                    }
                }
                .frame(width: 230, height: 230)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(8)
                .tarsGlass(cornerRadius: 28)

                Picker("", selection: $selected) {
                    ForEach(addresses.indices, id: \.self) { index in
                        Text("\(addresses[index].label)  \(addresses[index].base)").tag(index)
                    }
                }
                .labelsHidden()
                .frame(width: 246)
                HStack {
                    Button("复制链接") {
                        if let link = link {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                        }
                    }
                }
                .tarsButton()
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("使用手机上的 Kiteline 扫码").font(.app(size: 17, weight: .semibold))
                    Text("从 App Store 安装 Kiteline，打开后扫描此二维码即可完成配对。")
                        .font(.app(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("或在手机上输入配对码").font(.app(size: 12)).foregroundStyle(.secondary)
                    Text(code.isEmpty ? "------" : "\(code.prefix(3)) \(code.suffix(3))")
                        .font(.app(size: 36, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .lineLimit(1)
                        .fixedSize()
                    HStack(spacing: 10) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, Int(expiry.timeIntervalSince(context.date)))
                            Text(left > 0 ? String(format: L("%d:%02d 后失效 · 仅可使用一次"), left / 60, left % 60) : L("正在生成新配对码…"))
                                .font(.app(size: 11.5)).foregroundStyle(.secondary)
                        }
                        // 过期了、被用掉了（服务里的码已经不是它）就自动换新的：窗口一直开着时，大字显示的旧码输了只会被拒
                        .task {
                            while !Task.isCancelled {
                                try? await Task.sleep(for: .seconds(1))
                                // 二维码里的令牌用掉了（有设备扫码配上了）或过期了：换一个
                                if !token.isEmpty, !AppState.shared.mobile.linkTokenValid(token) {
                                    token = AppState.shared.mobile.newLinkToken()
                                }
                                let current = AppState.shared.mobile.pairingCode
                                if Date() >= expiry || current.isEmpty {
                                    newCode()
                                } else if current != code {
                                    // 服务里已经换了码（Kiteline 服务器说这个码正被别的 Mac 占着）：显示新的，不再另生成
                                    code = current
                                    expiry = AppState.shared.mobile.pairingCodeExpiry
                                }
                            }
                        }
                        Spacer()
                        Button("刷新") { newCode() }.tarsButton().controlSize(.small)
                    }
                }
                .tarsCard()

                VStack(alignment: .leading, spacing: 8) {
                    statusRow("antenna.radiowaves.left.and.right", L("服务"), model.serverStatus)
                    statusRow("iphone", L("在线的手机"), L("%lld 台", count: model.phoneClients))
                    statusRow("bell.badge", L("推送订阅"), L("%lld 台设备", count: pushCount))
                }
                .tarsCard()

                VStack(alignment: .leading, spacing: 5) {
                    tip("1", L("局域网：手机与 Mac 连接同一 Wi-Fi 时，选择「局域网」地址。"))
                    tip("2", L("外部网络：在设置中开启「远程访问」后，手机可通过 5G 或其他 Wi-Fi 连接（端到端加密）。"))
                }
                .font(.app(size: 11.5))
                .foregroundStyle(.secondary)

                Button("重置令牌…", role: .destructive) { resetToken() }
                    .tarsButton()
                    .controlSize(.small)
            }
            .frame(width: 330)
        }
        .padding(24)
        .onAppear(perform: reload)
    }

    private func statusRow(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.app(size: 12))
    }

    private func tip(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number).font(.appFixed(size: 10, weight: .bold)).frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(0.1)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reload() {
        let mobile = AppState.shared.config.mobile
        token = AppState.shared.mobile.newLinkToken()
        addresses = PhoneAccess.addresses(port: mobile.port, publicURL: mobile.publicURL,
                                          httpsPort: mobile.httpsEnabled ? mobile.effectiveHTTPSPort : nil)
        selected = PhoneAccess.preferred(addresses)
        pushCount = AppState.shared.mobile.push.subscriptions.count
        newCode()
    }

    private func newCode() {
        code = AppState.shared.mobile.newPairingCode()
        expiry = AppState.shared.mobile.pairingCodeExpiry
    }

    private func resetToken() {
        let alert = NSAlert()
        alert.messageText = L("重置配对令牌？")
        alert.informativeText = L("所有已配对的手机都将失效，需重新扫码。适用于手机丢失或链接泄露的情况。")
        alert.addButton(withTitle: L("重置"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppState.shared.resetMobileToken()
        reload()
    }
}

/// 手机能连到本机的地址与二维码
enum PhoneAccess {
    /// 扫码配对的链接：base 是手机连本机的地址，token 是一次性配对令牌（AppState.shared.mobile.newLinkToken()）
    static func pairingLink(base: String, token: String) -> String {
        // fp：本机根证书指纹，Kiteline iOS App 扫码时用它确认连的是这台 Mac（网页版忽略这个参数）
        let fingerprint = LocalTLS.caFingerprint.map { "&fp=\($0)" } ?? ""
        // id、r：开着远程访问时带上本机点对点公钥和中继，手机和 Mac 局域网不通时 App 经中继配对（网页版忽略）
        var remote = ""
        if let info = P2P.shared.joinInfo, let id = info["id"] as? String, let relay = info["relay"] as? String {
            remote = "&id=\(id)&r=\(relay.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
        }
        return "\(base)/?t=\(token)\(fingerprint)\(remote)"
    }

    /// 默认选哪个地址扫码：自定义 > Tailscale > 局域网
    static func preferred(_ addresses: [(label: String, base: String)]) -> Int {
        addresses.firstIndex { $0.label.hasPrefix(L("自定义")) }
            ?? addresses.firstIndex { $0.label == "Tailscale" }
            ?? addresses.firstIndex { $0.label == L("局域网") } ?? 0
    }

    static func addresses(port: Int, publicURL: String, httpsPort: Int?) -> [(label: String, base: String)] {
        var result: [(String, String)] = []
        let trimmed = publicURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !trimmed.isEmpty { result.append((L("自定义"), trimmed)) }
        let net = NetworkInfo.current()
        for (label, hosts) in [("Tailscale", net.tailscale), (L("局域网"), net.lan), ("Bonjour", net.names)] {
            // 只给 HTTPS：明文端口只开本机（见 MobileServer.start），手机上的 Kiteline 本来就只走 HTTPS
            guard let https = httpsPort else { continue }
            for host in hosts { result.append((label, "https://\(host):\(https)")) }
        }
        return result
    }

    static func qrImage(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - 来源

struct SourcesPane: View {
    @ObservedObject var model = KitelineModel.shared
    @State private var adding = false
    /// 后台运行 Claude Code 的面板（检测出口 IP、按设备开启；和手机同一个，见 KitelineKit/Views/HostedViews.swift）
    @State private var showHosted = false
    @State private var tipOff = AppState.shared.config.mobile.hostedTipOff
    @State private var host = ""
    @State private var name = ""
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kiteline 监听以下机器上的 Claude Code：本机，以及你在 VS Code 中通过 Remote-SSH 连接的远端主机。首次连接远端时将自动部署观察器。")
                .font(.app(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 有能后台运行、还没开的远端设备：问一声要不要开（勾了「不再提示」就不问，各行的按钮照旧在）
            let candidates = model.sources.filter { $0.hostedSupport && !$0.hostedOn && $0.online }
            if !candidates.isEmpty, !tipOff {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "moon.stars").foregroundStyle(Color.accentColor).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("「%@」支持在后台运行 Claude Code：新建任务、恢复会话不再打开 VS Code，可减少 VS Code 的内存占用。是否开启？",
                               candidates.map(\.name).joined(separator: "」「")))
                            .font(.app(size: 12)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button("检测出口并开启…") { showHosted = true }.tarsButton(prominent: true)
                            Button("不再提示") {
                                tipOff = true
                                Hosted.update(tipOff: true)
                            }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tarsCard(padding: 12)
            }
            VStack(spacing: 0) {
                ForEach(model.sources) { source in
                    SourceRow(source: source)
                    if source.id != model.sources.last?.id { Divider().padding(.leading, 46) }
                }
            }
            .tarsCard(padding: 6)

            if adding {
                VStack(alignment: .leading, spacing: 10) {
                    Text("添加 Remote-SSH 主机").font(.app(size: 13, weight: .semibold))
                    TextField("主机（与 ssh 命令中的写法一致，如 my-server 或 10.0.0.5）", text: $host)
                    TextField("显示名（可选）", text: $name)
                    if !message.isEmpty {
                        Text(message).font(.app(size: 11.5)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("取消") { adding = false; message = "" }.tarsButton()
                        Button(busy ? "正在检查连接…" : "添加") { add() }
                            .tarsButton(prominent: true)
                            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .tarsCard()
            } else {
                HStack {
                    Button { adding = true } label: { Label("添加 Remote-SSH 主机", systemImage: "plus") }
                        .tarsButton()
                    Spacer()
                    Button("全部重新连接") { AppState.shared.reconnect() }.tarsButton()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: SettingsWindowController.width, height: 520, alignment: .top)
        .sheetPanel(isPresented: $showHosted) { TarsHostedSetupView() }
    }

    private func add() {
        let target = host.trimmingCharacters(in: .whitespaces)
        busy = true
        message = L("正在通过 ssh 连接 %@…", "\(target)")
        AppState.shared.addSSHSource(host: target, name: name.trimmingCharacters(in: .whitespaces)) { result in
            busy = false
            switch result {
            case .success:
                adding = false; host = ""; name = ""; message = ""
            case .failure(let error):
                message = L("无法连接：%@。需确保可在终端中免密 ssh 登录（BatchMode）。", "\(error.description)")
            }
        }
    }
}

struct SourceRow: View {
    let source: SourceItem
    @State private var hovering = false
    /// 设备详情（IP、系统、CPU、内存、装了哪些 agent）：和手机同一个面板
    @State private var showDetail = false
    /// 这台的后台运行 Claude Code（检测出口、开关）
    @State private var showHosted = false
    /// 改名：双击名字或菜单里「改名…」，回车保存，Esc 取消
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.kind == .ssh ? "server.rack" : "laptopcomputer")
                .font(.app(size: 16))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if editing {
                        TextField(source.kind == .local ? L("本机") : (source.host ?? L("名字")), text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .font(.app(size: 13, weight: .semibold))
                            .frame(maxWidth: 220)
                            .focused($focused)
                            .onSubmit(commit)
                            .onExitCommand { editing = false }
                            .onChange(of: focused) { _, on in if !on, editing { commit() } }
                    } else {
                        Text(source.name).font(.app(size: 13, weight: .semibold))
                            .onTapGesture(count: 2, perform: startEditing)
                            .help("双击改名")
                    }
                    if let host = source.host, host != source.name {
                        Text(host).font(.app(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(source.online ? Color.green : (source.enabled ? Color.red : Color.gray)).frame(width: 6, height: 6)
                    Text(source.enabled ? source.status : L("已停用")).lineLimit(1)
                    if source.hostedOn { Text("· 后台运行 Claude Code").lineLimit(1) }
                }
                .font(.app(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if source.hostedSupport || source.hostedOn {
                Button(source.hostedOn ? "后台运行：已开启" : "后台运行…") { showHosted = true }
                    .buttonStyle(.borderless)
                    .font(.app(size: 11.5))
                    .foregroundStyle(source.hostedOn ? Color.secondary : Color.accentColor)
                    .help("在这台电脑上后台运行 Claude Code：检测出口 IP、开启或关闭")
            }
            Button { showDetail = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0.6)
                .help("设备详情")
            Menu {
                Button("设备详情…") { showDetail = true }
                Button("改名…", action: startEditing)
                Button("重新连接") { AppState.shared.reconnect() }
                if source.kind == .ssh {
                    Button("重新部署观察器") { AppState.shared.redeployWatcher(on: source.id) }
                }
                Button(source.enabled ? "停用" : "启用") { AppState.shared.setSource(source.id, enabled: !source.enabled) }
                if source.id != "local" {
                    Divider()
                    Button("移除", role: .destructive) { AppState.shared.removeSource(source.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.automatic)   // 菜单里的项别套设置窗口根上的 LookButtonStyle
            .fixedSize()
            .opacity(hovering ? 1 : 0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .onHover { hovering = $0 }
        .sheetPanel(isPresented: $showDetail) { TarsMachineInfoView(sourceId: source.id) }
        .sheetPanel(isPresented: $showHosted) { TarsHostedSetupView(sourceId: source.id) }
    }

    private func startEditing() {
        draft = source.name
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        AppState.shared.renameSource(source.id, to: draft)
    }
}

// MARK: - 权限

struct PermissionsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionsList()
            Text("自行构建的 App 每次重新构建后，macOS 可能要求重新授予以上权限。")
                .font(.app(size: 11)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: SettingsWindowController.width, height: 480, alignment: .top)
    }
}

/// 各项权限的卡片（设置 → 权限、第一次打开的引导第二步共用）：每 2 秒刷新一次，去系统设置里打开了回来马上能看到
struct PermissionsList: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var speech = Transcriber.status
    @State private var notifications = "unknown"
    @State private var localNetwork = LocalNetwork.status
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            permission("hand.raised", ServerLang.ui(Delivery.accessibilityName), accessibility,
                       L("用于将手机发送的消息粘贴到 VS Code 中的会话并提交，以及操作确认框。未授权时，手机消息将无法送达。")
                       + L("（系统设置 → 隐私与安全性 → %@；若已开启但仍显示未授权，请先在该处删除 Kiteline，再点击右侧按钮重新添加）", "\(ServerLang.ui(Delivery.accessibilityName))"),
                       action: accessibility ? nil : (L("打开系统设置"), {
                           let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                           _ = AXIsProcessTrustedWithOptions(options)
                           open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                       }))
            permission("network", L("本地网络"), localNetwork != .denied,
                       L("用于让同一 Wi-Fi 下的手机连接此 Mac，以及连接局域网中的 Remote-SSH 主机。未授权时，局域网内的手机无法连接 Mac，远端主机将显示「No route to host」（经中继的远程访问不受影响）。"),
                       action: localNetwork != .denied ? nil : (L("打开系统设置"), { LocalNetwork.openSettings() }))
            permission("waveform", L("语音识别"), speech == "authorized",
                       L("将手机「按住说话」录制的语音转写为文字。"),
                       action: speech == "authorized" ? nil : (speech == "notDetermined" ? L("允许") : L("打开系统设置"), {
                           if speech == "notDetermined" {
                               Transcriber.requestIfNeeded { _ in speech = Transcriber.status }
                           } else {
                               open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
                           }
                       }))
            permission("bell.badge", L("通知"), notifications == "authorized",
                       L("Claude 请求确认或完成任务时，在 Mac 上显示提醒。"),
                       action: notifications == "authorized" ? nil : (L("打开系统设置"), {
                           open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                       }))
        }
        .onAppear {
            refresh()
            LocalNetwork.check { localNetwork = $0 }   // 开着设置页时去系统设置里打开了，回来马上能看到
        }
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        accessibility = AXIsProcessTrusted()
        speech = Transcriber.status
        localNetwork = LocalNetwork.status
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let value = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                ? "authorized" : "denied"
            DispatchQueue.main.async { notifications = value }
        }
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private func permission(_ symbol: String, _ title: String, _ granted: Bool, _ detail: String,
                            action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.app(size: 18)).frame(width: 30, height: 30)
                .foregroundStyle(granted ? Color.green : Color.tarsOrange)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.app(size: 13, weight: .semibold))
                    Text(granted ? "已授权" : "未授权")
                        .font(.app(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill((granted ? Color.green : Color.tarsOrange).opacity(0.18)))
                        .foregroundStyle(granted ? Color.green : Color.tarsOrange)
                }
                Text(detail).font(.app(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action = action {
                Button(action.0, action: action.1).tarsButton(prominent: true).controlSize(.small)
            }
        }
        .tarsCard()
    }
}

// MARK: - 关于

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            Text("Kiteline").font(.app(size: 26, weight: .bold, design: .rounded))
            Text("随时随地与 Claude Code 协作").foregroundStyle(.secondary)
            Text("版本 \(AppVersion.app) · 观察器 \(AppVersion.watcherScriptVersion)")
                .font(.app(size: 11.5)).foregroundStyle(.tertiary)
            HStack {
                // 在 App 里打开（时间轴，和手机同一个页面）；不再用浏览器打开本机网页
                Button("更新记录") { ChangelogWindowController.shared.show() }
                Button("打开数据目录") { NSWorkspace.shared.open(AppConfig.directoryURL) }
                Button("打开配置文件") { AppState.shared.openConfigFile() }
                Button("复制诊断信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppState.shared.diagnostics(), forType: .string)
                }
            }
            .tarsButton()
            .controlSize(.small)
            .padding(.top, 6)
            // 隐私政策 / 使用条款 / 支持：页面在 relay/site/，用 relay/site.sh 发布到中继域名下
            HStack(spacing: 16) {
                Link("隐私政策", destination: Lang.site("privacy"))
                Link("使用条款", destination: Lang.site("terms"))
                Link("支持与反馈", destination: Lang.site("support"))
                Button("开源许可") { LicensesWindowController.shared.show() }
            }
            .font(.app(size: 12))
        }
        .padding(30)
        .frame(width: 520, height: 390)
    }
}
