import AppKit
import ServiceManagement
import SwiftUI
import KitelineKit

/// 第一次打开 Kiteline 的引导（11-02 起：装好之后不知道怎么用、电脑上没有任何 Agent 的大有人在）。四步：
/// 第一步 了解 Kiteline：它是编程 Agent 的辅助工具，检测本机装了哪些 Agent；一个都没有时醒目提醒，列表外的 Agent 可以填写提交（存到统计后台）
/// 第二步 授予权限（同设置 → 权限）+ 登录时自动启动
/// 第三步 连接手机：下载 iPhone App 的二维码、安卓用的微信小程序码 + 配对二维码和配对码
/// 第四步 虚拟屏幕：为什么要开、开关
/// 第一次启动、还没配过手机时自动弹；菜单「Kiteline → 新手引导…」、主窗口欢迎页随时能再打开。测试实例不自动弹（CCPULSE_ONBOARDING=1 才弹）
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private static let shownKey = "onboardingShown"
    let model = OnboardingModel()

    private init() {
        let hosting = NSHostingController(rootView: OnboardingFlow(model: model).tarsLook(wrapButtons: true))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        // 同别的弹窗（11-02 反馈：要有标题栏、全屏、关闭）：标题栏写明是什么，红黄绿钮都能用，绿钮铺满屏幕
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = L("欢迎使用 Kiteline")
        window.setContentSize(NSSize(width: 780, height: 620))
        window.contentMinSize = NSSize(width: 720, height: 560)
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: Lang.didChange, object: nil, queue: .main) { [weak window] _ in
            window?.title = L("欢迎使用 Kiteline")
        }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool { window?.isVisible == true }

    /// 启动时调：没弹过、也还没配过手机（升级上来的老用户不弹）才弹，弹过一次就不再自动弹（中途关掉也算）
    static func showOnFirstLaunch() {
        let forced = ProcessInfo.processInfo.environment["CCPULSE_ONBOARDING"] == "1"
        guard !AppConfig.isolated || forced else { return }
        guard forced || !AppConfig.defaults.bool(forKey: shownKey) else { return }
        AppConfig.defaults.set(true, forKey: shownKey)
        guard forced || DeviceStore.shared.all.isEmpty else { return }
        // 等主窗口先出来，引导压在它上面
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { shared.show() }
    }

    func show(step: OnboardingModel.Step = .agents) {
        model.step = step
        model.detect()
        NSApp.setActivationPolicy(.regular)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 自测截图用：切到某一步、放到屏幕里压在最底下（不激活、不抢焦点）、全透明鼠标穿透（用户看不见），返回窗口
    func showForCapture(step: OnboardingModel.Step) -> NSWindow? {
        model.step = step
        window?.alphaValue = 0
        window?.ignoresMouseEvents = true
        window?.setFrameOrigin(NSPoint(x: 60, y: 60))
        window?.orderBack(nil)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            if !MainWindowController.shared.isVisible && !SettingsWindowController.shared.isVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: - 本机装了哪些 Agent

/// 问本机 watcher（同设备详情 AgentFaces.machine：Claude Code 在 machine_info 里，Codex、OpenCode 这些在插件列表里）
enum AgentCheck {
    struct Found: Identifiable, Equatable {
        let id: String
        let name: String
        let installed: Bool
        /// 装了哪几种：「VS Code 扩展 2.1.3」「终端」……
        let forms: [String]
    }

    /// skip：这次不用问（直接回 nil）；本机来源还没连上、问不到时也回 nil
    static func run(skip: Bool = false, completion: @escaping ([Found]?) -> Void) {
        guard !skip, AppState.shared.source(withId: "local")?.state.isLive == true else { completion(nil); return }
        AgentFaces.machine("local") { out in
            guard let rows = out["agents"] as? [[String: Any]], !rows.isEmpty else { completion(nil); return }
            completion(rows.compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                let forms = (row["forms"] as? [String: String] ?? [:]).sorted { order($0.key) < order($1.key) }
                    .map { form, version in [formName(form), version].filter { !$0.isEmpty }.joined(separator: " ") }
                return Found(id: id, name: row["name"] as? String ?? id, installed: (row["installed"] as? Bool) == true, forms: forms)
            })
        }
    }

    private static func order(_ form: String) -> Int { ["vscode": 0, "cli": 1, "desktop": 2][form] ?? 3 }

    private static func formName(_ form: String) -> String {
        switch form {
        case "vscode": return L("VS Code 扩展")
        case "cli": return L("终端")
        case "desktop": return L("桌面版")
        default: return form
        }
    }
}

// MARK: - 模型

final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case agents, permissions, phone, screen
        var id: Int { rawValue }

        var ordinal: String {
            switch self {
            case .agents: return L("第一步")
            case .permissions: return L("第二步")
            case .phone: return L("第三步")
            case .screen: return L("第四步")
            }
        }

        var title: String {
            switch self {
            case .agents: return L("了解 Kiteline")
            case .permissions: return L("授予权限")
            case .phone: return L("连接手机")
            case .screen: return L("虚拟屏幕")
            }
        }
    }

    @Published var step = Step.agents
    /// nil = 还在检测（本机来源刚连上前问不到，过几秒再问）
    @Published private(set) var agents: [AgentCheck.Found]?
    @Published private(set) var checking = false

    // 「你使用的 Agent 不在列表中？」
    @Published var wanted = ""
    @Published var note = ""
    @Published private(set) var sending = false
    @Published private(set) var sent = false
    @Published private(set) var sendFailed = false

    /// 自测截图：假装一个 Agent 都没检测到（看提醒的样子）
    static var pretendNone = false

    var installed: [AgentCheck.Found] { (agents ?? []).filter(\.installed) }

    /// 检测本机的 Agent；本机来源还没连上（刚装好第一次启动，watcher 在部署）就隔 3 秒再问，最多问 20 次
    func detect(attempt: Int = 0) {
        checking = true
        AgentCheck.run { [weak self] found in
            guard let self else { return }
            if let found {
                if Self.pretendNone {
                    self.agents = found.map { .init(id: $0.id, name: $0.name, installed: false, forms: []) }
                } else {
                    self.agents = found
                    UsageStats.installedAgents = found.filter(\.installed).map(\.id)
                }
                self.checking = false
            } else if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.detect(attempt: attempt + 1) }
            } else {
                self.agents = []
                self.checking = false
            }
        }
    }

    func submit() {
        let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !sending else { return }
        sending = true
        sendFailed = false
        UsageStats.feedback(["kind": "agent", "agents": String(name.prefix(200)),
                             "note": String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)),
                             "detected": installed.map(\.id)]) { [weak self] ok in
            guard let self else { return }
            self.sending = false
            self.sent = ok
            self.sendFailed = !ok
            Log.write(ok ? "已提交 Agent 反馈：\(name)" : "Agent 反馈提交失败")
        }
    }
}

// MARK: - 窗口内容

struct OnboardingFlow: View {
    @ObservedObject var model: OnboardingModel
    /// 拉大、全屏时步骤条和内容不再变宽，居中
    private static let readable: CGFloat = 940

    var body: some View {
        VStack(spacing: 0) {
            StepBar(model: model)
                .frame(maxWidth: Self.readable)
                .padding(.top, 18)
                .padding(.horizontal, 32)
            ScrollView {
                Group {
                    switch model.step {
                    case .agents: AgentsStep(model: model)
                    case .permissions: PermissionsStep()
                    case .phone: PhoneStep()
                    case .screen: ScreenStep()
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
                .frame(maxWidth: Self.readable, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(model.step)   // 换一步从顶上看起
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("稍后再说") { OnboardingWindowController.shared.close() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Text("可随时在菜单「Kiteline → 新手引导」中再次打开")
                .font(.app(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            if let previous = OnboardingModel.Step(rawValue: model.step.rawValue - 1) {
                Button("上一步") { model.step = previous }.tarsButton().controlSize(.large)
            }
            if let next = OnboardingModel.Step(rawValue: model.step.rawValue + 1) {
                Button("下一步") { model.step = next }.tarsButton(prominent: true).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("开始使用") {
                    OnboardingWindowController.shared.close()
                    MainWindowController.shared.show()
                }
                .tarsButton(prominent: true).controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// 顶上的四步：序号圈 +「第一步」+ 标题；当前一步淡强调色底 + 细边，做过的打勾。点了直接跳过去
private struct StepBar: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingModel.Step.allCases) { step in
                let current = step == model.step
                let done = step.rawValue < model.step.rawValue
                Button { model.step = step } label: {
                    HStack(spacing: 9) {
                        ZStack {
                            Circle().fill(current || done ? Color.tarsBrand : Color.primary.opacity(0.08))
                            if done {
                                Image(systemName: "checkmark").font(.appFixed(size: 10, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(step.rawValue + 1)").font(.appFixed(size: 11, weight: .bold))
                                    .foregroundStyle(current ? Color.white : Color.secondary)
                            }
                        }
                        .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.ordinal).font(.app(size: 10.5)).foregroundStyle(.secondary)
                            Text(step.title).font(.app(size: 12.5, weight: current ? .semibold : .regular))
                                .foregroundStyle(current ? Color.primary : Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(current ? Color.tarsBrand.opacity(0.14) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .hairlineBorder(current ? Color.tarsBrand.opacity(0.32) : Color.primary.opacity(0.08)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 每一步的标题 + 一段说明
private struct StepHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.app(size: 21, weight: .semibold))
            Text(detail).font(.app(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 一行开关：左边标题 + 说明，开关靠右
private struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(size: 13, weight: .semibold))
                Text(detail).font(.app(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .tarsCard()
    }
}

// MARK: 第一步 了解 Kiteline

private struct AgentsStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var showForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                StepHeader(title: L("Kiteline 是编程 Agent 的辅助工具"),
                           detail: L("Kiteline 本身不写代码，也不提供 AI 能力。它连接你电脑上正在使用的编程 Agent，让你在手机上查看会话进展、回复消息、处理确认请求。使用前，请先在电脑上安装并使用至少一种 Agent，例如 VS Code 中的 Claude Code、Codex。"))
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("本机检测到的 Agent").font(.app(size: 13, weight: .semibold))
                    Spacer()
                    if model.checking { ProgressView().controlSize(.small) }
                    Button("重新检测") { model.detect() }.tarsButton().controlSize(.small).disabled(model.checking)
                }
                if let agents = model.agents {
                    if model.installed.isEmpty {
                        noAgents
                    }
                    ForEach(agents.sorted { ($0.installed ? 0 : 1) < ($1.installed ? 0 : 1) }) { agent in
                        agentRow(agent)
                    }
                } else {
                    Text("正在检测…").font(.app(size: 12)).foregroundStyle(.secondary)
                }
            }
            .tarsCard(padding: 16)

            feedback
        }
        .onChange(of: model.agents) { _, agents in
            // 一个都没检测到：直接展开填写框
            if let agents, !agents.contains(where: \.installed) { showForm = true }
        }
    }

    private func agentRow(_ agent: AgentCheck.Found) -> some View {
        HStack(spacing: 10) {
            Image(systemName: agent.installed ? "checkmark.circle.fill" : "circle.dashed")
                .font(.app(size: 14))
                .foregroundStyle(agent.installed ? Color.tarsBrand : Color.secondary.opacity(0.6))
            Text(agent.name).font(.app(size: 13, weight: agent.installed ? .medium : .regular))
                .foregroundStyle(agent.installed ? Color.primary : Color.secondary)
            Spacer()
            Text(agent.installed ? (agent.forms.isEmpty ? L("已安装") : agent.forms.joined(separator: L("、"))) : L("未检测到"))
                .font(.app(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// 一个 Agent 都没有：说清楚要先装什么
    private var noAgents: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.app(size: 16)).foregroundStyle(Color.tarsOrange)
            VStack(alignment: .leading, spacing: 8) {
                Text("未检测到任何编程 Agent").font(.app(size: 13, weight: .semibold))
                Text("Kiteline 需要配合 Agent 使用，否则手机上不会有任何会话。你可以：")
                    .font(.app(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    bullet(L("安装 VS Code，在「扩展」中搜索并安装 Claude Code 或 Codex"))
                    bullet(L("或安装 Claude Code、Codex、OpenCode 等命令行工具"))
                    bullet(L("安装完成并开始一个会话后，点击「重新检测」"))
                }
                HStack(spacing: 8) {
                    Button("下载 VS Code") { NSWorkspace.shared.open(URL(string: "https://code.visualstudio.com/download")!) }
                        .tarsButton(prominent: true).controlSize(.small)
                    Button("重新检测") { model.detect() }.tarsButton().controlSize(.small).disabled(model.checking)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tarsOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).hairlineBorder(Color.tarsOrange.opacity(0.3)))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").font(.app(size: 12, weight: .bold))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.app(size: 12))
    }

    // 「你使用的 Agent 不在列表中？」：填名字 + 补充说明，提交到统计后台
    @ViewBuilder
    private var feedback: some View {
        if model.sent {
            Label("已提交，感谢反馈。我们会根据反馈优先接入更多 Agent。", systemImage: "checkmark.circle")
                .font(.app(size: 12.5)).foregroundStyle(.secondary)
        } else if !showForm {
            Button { showForm = true } label: {
                Label("我使用的 Agent 不在列表中", systemImage: "plus.bubble")
            }
            .buttonStyle(.link)
            .font(.app(size: 12.5))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("你使用的 Agent 不在列表中？").font(.app(size: 13, weight: .semibold))
                    Text("告诉我们你正在使用或计划使用的 Agent，我们会根据反馈优先接入。")
                        .font(.app(size: 12)).foregroundStyle(.secondary)
                }
                TextField("", text: $model.wanted, prompt: Text("Agent 名称，例如 Cline、Aider、Gemini CLI"))
                    .textFieldStyle(.roundedBorder)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.note)
                        .font(.app(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                    if model.note.isEmpty {
                        Text("补充说明（选填）：使用方式、所在系统等")
                            .font(.app(size: 13)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 64)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).hairlineBorder(Color.primary.opacity(0.15)))
                HStack(spacing: 10) {
                    Button(model.sending ? L("正在提交…") : L("提交")) { model.submit() }
                        .tarsButton(prominent: true).controlSize(.small)
                        .disabled(model.sending || model.wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.sendFailed {
                        Text("提交失败，请检查网络后重试").font(.app(size: 11.5)).foregroundStyle(Color.tarsOrange)
                    }
                }
            }
            .tarsCard(padding: 16)
        }
    }
}

// MARK: 第二步 授予权限

private struct PermissionsStep: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: L("授予必要的权限"),
                       detail: L("Kiteline 需要以下权限，才能把你在手机上发送的消息和确认操作送到电脑上的会话中。其中第一项必须开启，其余可按需开启。"))
            PermissionsList()
            SwitchRow(title: L("登录时自动打开 Kiteline"), detail: L("推荐开启：电脑开机后手机即可连接，无需手动打开。"),
                      isOn: Binding(get: { launchAtLogin }, set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    Log.write("切换登录时自动打开失败：\(error.localizedDescription)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }))
        }
    }
}

// MARK: 第三步 连接手机

private struct PhoneStep: View {
    static let appStore = "https://apps.apple.com/cn/app/kiteline/id6825244029"
    @State private var link: String?
    @State private var token = ""
    @State private var code = ""
    @State private var expiry = Date()
    @State private var paired = DeviceStore.shared.all.count

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: L("在手机上使用 Kiteline"),
                       detail: L("iPhone 安装 Kiteline App，安卓手机使用 Kiteline 微信小程序；与这台电脑配对后，即可在手机上查看会话、回复消息和处理确认请求。Apple Watch App 随 iPhone 自动安装。"))
            HStack(alignment: .top, spacing: 16) {
                downloadCard
                card(number: 2, title: L("扫码或输入配对码"), qr: link,
                     detail: L("打开 App 或小程序，扫描此二维码，或输入下方的 6 位配对码。首次配对时手机与电脑需连接同一网络。")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(code.isEmpty ? "------" : "\(code.prefix(3)) \(code.suffix(3))")
                            .font(.app(size: 26, weight: .semibold, design: .monospaced)).tracking(2)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, Int(expiry.timeIntervalSince(context.date)))
                            Text(left > 0 ? String(format: L("%d:%02d 后失效 · 仅可使用一次"), left / 60, left % 60) : L("正在生成新配对码…"))
                                .font(.app(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: paired > 0 ? "checkmark.circle.fill" : "iphone")
                    .foregroundStyle(paired > 0 ? Color.tarsBrand : Color.secondary)
                Text(paired > 0 ? L("已配对 %lld 台设备，可以进入下一步。", count: paired) : L("等待手机配对…"))
                    .font(.app(size: 12.5))
                Spacer()
                Button("更多选项") { SettingsWindowController.shared.show(tab: .phone) }.tarsButton().controlSize(.small)
            }
            .tarsCard(padding: 12)
            Text("在外部网络（如 5G、其他 Wi-Fi）中使用：在设置的「远程访问」中开启，需订阅 Kiteline Pro。")
                .font(.app(size: 11.5)).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .task {
            // 码过期、二维码被扫过就换新的；顺便看有没有新配上的手机
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !token.isEmpty, !AppState.shared.mobile.linkTokenValid(token) { reloadLink() }
                let current = AppState.shared.mobile.pairingCode
                if Date() >= expiry || current.isEmpty {
                    newCode()
                } else if current != code {
                    code = current
                    expiry = AppState.shared.mobile.pairingCodeExpiry
                }
                paired = DeviceStore.shared.all.count
            }
        }
    }

    /// 第 1 步：iPhone 扫 App Store 的码，安卓用微信扫小程序码（11-10 起：安卓用户用小程序）
    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("1").font(.appFixed(size: 11, weight: .bold)).foregroundStyle(Color.tarsBrand)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().hairlineBorder(Color.tarsBrand.opacity(0.6)))
                Text("安装手机端").font(.app(size: 14, weight: .semibold))
            }
            HStack(alignment: .top, spacing: 14) {
                code(PhoneAccess.qrImage(for: Self.appStore), interpolate: false, caption: L("iPhone：相机扫码，或在 App Store 中搜索「Kiteline」"))
                code(NSImage(named: "MiniProgramCode"), interpolate: true, caption: L("安卓：微信扫码，打开 Kiteline 小程序"))
            }
        }
        .tarsCard(padding: 16)
    }

    private func code(_ image: NSImage?, interpolate: Bool, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white)
                if let image {
                    Image(nsImage: image).interpolation(interpolate ? .high : .none).resizable().padding(interpolate ? 4 : 8)
                }
            }
            .frame(width: 112, height: 112)
            Text(caption).font(.app(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(width: 112, alignment: .leading)
        }
    }

    private func card<Extra: View>(number: Int, title: String, qr: String?, detail: String, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(number)").font(.appFixed(size: 11, weight: .bold)).foregroundStyle(Color.tarsBrand)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().hairlineBorder(Color.tarsBrand.opacity(0.6)))
                Text(title).font(.app(size: 14, weight: .semibold))
            }
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white)
                    if let qr, let image = PhoneAccess.qrImage(for: qr) {
                        Image(nsImage: image).interpolation(.none).resizable().padding(8)
                    } else {
                        Text(AppState.shared.config.mobile.httpsEnabled ? "无可用的网络地址" : "请先开启 HTTPS 服务")
                            .font(.app(size: 10)).foregroundStyle(.black.opacity(0.5)).multilineTextAlignment(.center).padding(6)
                    }
                }
                .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 10) {
                    Text(detail).font(.app(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    extra()
                }
            }
        }
        .tarsCard(padding: 16)
    }

    private func reload() {
        reloadLink()
        newCode()
    }

    private func reloadLink() {
        let mobile = AppState.shared.config.mobile
        token = AppState.shared.mobile.newLinkToken()
        let addresses = PhoneAccess.addresses(port: mobile.port, publicURL: mobile.publicURL,
                                              httpsPort: mobile.httpsEnabled ? mobile.effectiveHTTPSPort : nil)
        let index = PhoneAccess.preferred(addresses)
        link = addresses.indices.contains(index) ? PhoneAccess.pairingLink(base: addresses[index].base, token: token) : nil
    }

    private func newCode() {
        code = AppState.shared.mobile.newPairingCode()
        expiry = AppState.shared.mobile.pairingCodeExpiry
    }
}

// MARK: 第四步 虚拟屏幕

private struct ScreenStep: View {
    @ObservedObject private var screen = VirtualScreen.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: L("让 VS Code 在虚拟屏幕中运行"),
                       detail: L("你在手机上发送消息时，Kiteline 需要切换到 VS Code，把消息填进对应的会话并提交。开启虚拟屏幕后，VS Code 的窗口会放到一块看不见的屏幕上：消息送达时不会弹到你面前、不打断你正在做的事，完成后自动回到你原来使用的程序。"))
            diagram
            SwitchRow(title: L("VS Code 在虚拟屏幕中运行"),
                      detail: screen.isOn ? L("已开启 · 虚拟屏幕中有 %lld 个窗口", count: screen.windowCount) : L("推荐在离开电脑、主要用手机操作时开启"),
                      isOn: Binding(get: { screen.isOn }, set: { on in if on != screen.isOn { screen.toggle() } }))
                .disabled(!VirtualScreen.supported)
            VStack(alignment: .leading, spacing: 5) {
                tip(L("鼠标不会进入虚拟屏幕，不影响你正常使用电脑。"))
                tip(L("需要查看 VS Code 时，点击程序坞中的 VS Code 图标，或在 Kiteline 中点击「在 VS Code 中打开」即可移回。"))
                tip(L("退出 Kiteline 时窗口自动回到原处；可随时在「设置 → 通用」或主窗口左下角的显示器按钮中开关。"))
            }
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.app(size: 11)).foregroundStyle(.secondary).padding(.top, 1)
            Text(text).font(.app(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 你的屏幕 + 一块虚线框出来的虚拟屏幕（VS Code 在里面），手机的消息送进虚拟屏幕
    private var diagram: some View {
        HStack(spacing: 18) {
            monitor(L("你的屏幕"), dashed: false) {
                HStack(spacing: 6) {
                    ForEach(["safari", "doc.text", "message"], id: \.self) { symbol in
                        Image(systemName: symbol).font(.app(size: 16)).foregroundStyle(.secondary)
                            .frame(width: 34, height: 26)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
            monitor(L("虚拟屏幕（看不见）"), dashed: true) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.app(size: 15, weight: .medium))
                        .foregroundStyle(Color.tarsBrand)
                        .frame(width: 44, height: 30)
                        .background(Color.tarsBrand.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("VS Code").font(.app(size: 12, weight: .medium))
                }
            }
            Image(systemName: "arrow.left").font(.app(size: 14)).foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Image(systemName: "iphone").font(.app(size: 26)).foregroundStyle(.secondary)
                Text("手机发来的消息").font(.app(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func monitor<Content: View>(_ label: String, dashed: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            content()
                .frame(width: 190, height: 96)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(dashed ? 0.02 : 0.05)))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(dashed ? 0.3 : 0.15), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
                }
            Text(label).font(.app(size: 11)).foregroundStyle(.secondary)
        }
    }
}
