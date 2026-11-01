import AVFoundation
import AppKit
import Combine
import SwiftUI
import KitelineKit
import WebKit

// 世界模式：右边整块是 three.js 画的像素世界（Resources/world，Mac / iPhone / Windows / Linux 共用一份网页，协议见 docs/world.md）。
// 机房 = agent，卫星 = 设备，方块人 = 会话；新消息从机房经卫星打一道光弧到会话的电脑、头顶冒气泡；
// agent 之间发消息时几个人站起来面对面聊。点屏幕弹出会话详情，点卫星弹设备详情；右上角那扇开着的门离开世界。

// MARK: - 右边：世界

struct WorldView: View {
    @ObservedObject var model: KitelineModel
    @ObservedObject private var sidebar = SidebarState.shared

    var body: some View {
        // 点了某人的屏幕：这个会话的对话页浮在世界右边。和网页并排叠着放、不挂在网页上：
        // 网页铺到标题栏、侧栏底下（ignoresSafeArea），挂在它上面的会话页会继承那片边距，对话的行就叠在一起
        ZStack(alignment: .trailing) {
            WorldCanvas()
                .ignoresSafeArea()
            if let key = model.worldDetail {
                WorldSessionCard(key: key)
            }
        }
            .navigationTitle(L("世界"))
            .modifier(WorldTitlebar())
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.setWorld(false) } label: {
                        Label(L("离开世界"), systemImage: "door.left.hand.open")
                    }
                    .help(L("离开世界模式，回到会话（⇧⌘E）"))
                    // 会话列表收起 / 展开：展开时从左边浮出来，盖在世界上（macOS 26 起是液态玻璃）
                    Button {
                        withAnimation(.snappy(duration: 0.32)) { sidebar.toggle() }
                    } label: {
                        Label(sidebar.collapsed ? L("展开会话列表") : L("收起会话列表"), systemImage: "sidebar.left")
                    }
                    .help(sidebar.collapsed ? L("展开会话列表") : L("收起会话列表"))
                }
            }
            // 左边栏点了会话：镜头飞过去
            .onChange(of: model.selection) { _, key in
                if let key, !key.hasPrefix("@") { WorldHost.shared.focus(key) }
            }
    }
}

/// 悬浮在世界右边的会话页：只有点的这一个会话（自己一份单块分屏，不带主窗口的多列），标题条、按钮、输入框和平时一样；
/// 左上角外面一个关闭（Esc），「更多」菜单最上面是「在主窗口中打开」
private struct WorldSessionCard: View, Equatable {
    let key: String

    /// 标题条上的按钮同主窗口；菜单前面加「在主窗口中打开」（只建一份，理由同 ConversationDetail.accessory）
    private static let accessory = TarsPaneAccessory(
        buttons: { key in AnyView(PaneButtons(model: KitelineModel.shared, key: key)) },
        menu: { key, folded in
            AnyView(Group {
                Button(L("在主窗口中打开")) {
                    KitelineModel.shared.setWorld(false)
                    KitelineModel.shared.selection = key
                }
                Divider()
                PaneMenu(model: KitelineModel.shared, key: key, folded: folded)
            })
        })

    var body: some View {
        GeometryReader { geometry in
            let width = min(max(geometry.size.width * 0.5, 480), 860)
            TarsSessionCard(key: key, accessory: Self.accessory)
                .id(key)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                .overlay(alignment: .topLeading) {
                    Button { KitelineModel.shared.worldDetail = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(L("关闭（Esc）"))
                    .offset(x: -10, y: -10)
                }
                .frame(width: width)
                .padding(.vertical, 14).padding(.trailing, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                // 世界的按钮、画面中心让开右边这一块
                .onAppear { WorldHost.shared.setRightInset(width + 36) }
                .onChange(of: width) { _, value in WorldHost.shared.setRightInset(value + 36) }
                .onDisappear { WorldHost.shared.setRightInset(0) }
        }
    }
}

/// 工具栏那一带让给世界：不画标题、底色透明（macOS 15 起），世界一直铺到窗口顶
private struct WorldTitlebar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// 放网页的地方：网页本身只建一个（WorldHost 管），离开世界时摘下来、回来时挂回去，不重新加载
private struct WorldCanvas: NSViewRepresentable {
    func makeNSView(context: Context) -> WorldContainer { WorldContainer() }
    func updateNSView(_ view: WorldContainer, context: Context) {}
    static func dismantleNSView(_ view: WorldContainer, coordinator: ()) { WorldHost.shared.setShown(false) }
}

final class WorldContainer: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = WorldHost.canvasColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            guard let window else { WorldHost.shared.setShown(false); return }
            let web = WorldHost.shared.webView
            web.removeFromSuperview()
            web.frame = bounds
            web.autoresizingMask = [.width, .height]
            addSubview(web)
            WorldHost.shared.window = window
            WorldHost.shared.setShown(true)
        }
    }

    override func layout() {
        super.layout()
        // 标题栏 + 工具栏多高、左边浮着的侧栏多宽：网页里的统计条、按钮让开，画面中心也挪到露出来的那块
        let insets = safeAreaInsets
        MainActor.assumeIsolated { WorldHost.shared.setInsets(top: insets.top, left: insets.left) }
    }
}

// MARK: - 网页和 App 之间

/// 世界的网页：kiteline-world://app/ 读包里的 Resources/world（开发时 CCPULSE_WORLD_ROOT 指向仓库目录，改完刷新即可）；
/// kiteline-world://app/api/media、/api/agent-avatar 转给本机的 Kiteline 服务（令牌留在 App 里，不进网页）。
/// 数据都是 Kiteline 接口原样的：整份状态（会话列表变了就推，内容没变不推）、对话增量、会话之间的消息、机器负载（MobileServer.publish 转进来）
@MainActor
final class WorldHost: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
    static let shared = WorldHost()
    static let scheme = "kiteline-world"
    static let canvasColor = NSColor(srgbRed: 0x2A / 255, green: 0x2B / 255, blue: 0x2F / 255, alpha: 1)

    private var web: WKWebView?
    private var ready = false
    private var shown = false
    private var insetTop: CGFloat = 0
    private var insetLeft: CGFloat = 0
    private var lastState = ""
    private var lastBrand = ""
    private var sysSent: [String: TimeInterval] = [:]
    private var tasks = Set<ObjectIdentifier>()
    private var bag: Set<AnyCancellable> = []
    private var teardown: DispatchWorkItem?
    /// 今日用量（公司墙的计量牌、项目牌子上的用量）：世界开着时每分钟取一次
    private var usageTimer: Timer?
    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            windowObserver.map(NotificationCenter.default.removeObserver)
            windowObserver = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { WorldHost.shared.sendActive() }
                }
            }
        }
    }
    private var windowObserver: NSObjectProtocol?

    private static var root: URL {
        if let dev = ProcessInfo.processInfo.environment["CCPULSE_WORLD_ROOT"], !dev.isEmpty { return URL(fileURLWithPath: dev) }
        return Bundle.main.resourceURL!.appendingPathComponent("world")
    }

    var webView: WKWebView { web ?? make() }

    private func make() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        config.userContentController.add(self, name: "world")
        config.mediaTypesRequiringUserActionForPlayback = []   // 朗读交谈不用先点一下
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = Self.canvasColor
        // 网页铺到标题栏底下：别让系统按标题栏高度缩掉页面（否则窗口底下空出一条）；网页自己按 insets 让开统计条
        if web.responds(to: NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")) {
            web.setValue(false, forKey: "automaticallyAdjustsContentInsets")
        }
        if #available(macOS 26, *) { web.obscuredContentInsets = NSEdgeInsets() }
        if #available(macOS 13.3, *) { web.isInspectable = true }
        web.load(URLRequest(url: URL(string: "\(Self.scheme)://app/index.html")!))
        self.web = web
        ready = false
        lastState = ""
        // 会话列表、状态有变化（KitelineModel 跟着 AppState 刷新）：攒 0.3 秒推一次整份
        KitelineModel.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { WorldHost.shared.pushState(force: false) } }
            .store(in: &bag)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { _ in MainActor.assumeIsolated { WorldHost.shared.sendActive() } }
                .store(in: &bag)
        }
        NotificationCenter.default.publisher(for: Lang.didChange)
            .sink { _ in MainActor.assumeIsolated { WorldHost.shared.sendInit(); WorldHost.shared.pushState(force: true) } }
            .store(in: &bag)
        return web
    }

    /// 世界显示 / 收起：收起时网页停下来不画；收起 3 分钟还没回来就把网页整个放掉（省内存）
    func setShown(_ value: Bool) {
        shown = value
        teardown?.cancel()
        usageTimer?.invalidate()
        usageTimer = nil
        if value {
            pushState(force: true)
            pushUsage()
            usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { WorldHost.shared.pushUsage() } }
        } else {
            let work = DispatchWorkItem { MainActor.assumeIsolated { WorldHost.shared.release() } }
            teardown = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: work)
        }
        sendActive()
    }

    private func release() {
        guard !shown, let web else { return }
        web.removeFromSuperview()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "world")
        self.web = nil
        ready = false
        bag.removeAll()
    }

    func setInsets(top: CGFloat, left: CGFloat) {
        guard abs(top - insetTop) > 0.5 || abs(left - insetLeft) > 0.5 else { return }
        insetTop = top
        insetLeft = left
        if ready { send(["type": "insets", "top": top, "left": left]) }
    }

    private var insetRight: CGFloat = 0
    func setRightInset(_ right: CGFloat) {
        guard abs(right - insetRight) > 0.5 else { return }
        insetRight = right
        if ready { send(["type": "insets", "right": right]) }
    }

    func focus(_ key: String) {
        if ready { send(["type": "focus", "key": key]) }
    }

    func sendActive() {
        guard ready else { return }
        let visible = shown && (window?.occlusionState.contains(.visible) ?? true)
        send(["type": "active", "active": NSApp.isActive, "visible": visible])
    }

    // MARK: 推给网页

    private func send(_ object: [String: Any]) {
        guard let web, let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("World.receive(\(json))", completionHandler: nil)
    }

    func sendInit() {
        guard ready else { return }
        lastBrand = brandHex
        send([
            "type": "init", "lang": Lang.shared.isEnglish ? "en" : "zh", "strings": Self.strings, "brand": lastBrand,
            "quality": "high", "insets": ["top": insetTop, "left": insetLeft], "door": false, "mediaBase": "\(Self.scheme)://app/", "marks": marks,
            "voices": Array(TTS.voices().map(\.id).prefix(6)),
        ])
    }

    /// 整份状态（同 /api/state，再加上各台机器的负载）；内容没变不推
    func pushState(force: Bool) {
        guard ready, shown || force else { return }
        if brandHex != lastBrand { sendInit() }
        var payload = AppState.shared.mobileStatePayload()
        payload.removeValue(forKey: "quickReplies")
        payload.removeValue(forKey: "watch")
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        if Lang.shared.isEnglish { data = ServerLang.localize(json: data) }
        let json = String(decoding: data, as: UTF8.self)
        guard force || json != lastState else { return }
        lastState = json
        if force {
            // 第一份带上机器负载（之后的变化走 sys）
            let sys = (try? JSONSerialization.data(withJSONObject: AppState.shared.machineStats)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            web?.evaluateJavaScript("World.receive({type:'state',state:Object.assign(\(json),{sys:\(sys)})})", completionHandler: nil)
        } else {
            web?.evaluateJavaScript("World.receive({type:'state',state:\(json)})", completionHandler: nil)
        }
    }

    /// 今日用量：各台机器汇总（UsageReport 自己缓存一分钟）
    func pushUsage() {
        guard ready, shown else { return }
        UsageReport.collect(days: 1) { payload in
            MainActor.assumeIsolated {
                WorldHost.shared.send(["type": "usage", "totals": payload["totals"] ?? [:], "projects": payload["projects"] ?? []])
            }
        }
    }

    /// 实时事件（MobileServer.publish 每条都过一遍）：对话增量、会话之间的消息、机器负载、待办转给网页
    nonisolated static func forward(event: String, payload: [String: Any]) {
        guard ["entries", "peers", "sys", "todos"].contains(event) else { return }
        let work = { MainActor.assumeIsolated { WorldHost.shared.relay(event, payload) } }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func relay(_ event: String, _ payload: [String: Any]) {
        guard ready, shown else { return }
        var body = payload
        body["type"] = event
        switch event {
        case "entries":
            // 只留世界用得到的字段、最后十几条，长文字截短（工具的输入输出可能很大）
            let fields: Set<String> = ["t", "id", "ts", "text", "name", "images", "queued", "brief"]
            let items = (payload["items"] as? [[String: Any]] ?? []).suffix(16).map { item in
                item.filter { fields.contains($0.key) }.mapValues { value -> Any in (value as? String).map { String($0.prefix(600)) } ?? value }
            }
            body["items"] = Array(items)
        case "sys":
            // 每台机器最多 3 秒一次
            guard let id = payload["id"] as? String else { return }
            let now = Date().timeIntervalSince1970
            if now - (sysSent[id] ?? 0) < 3 { return }
            sysSent[id] = now
        default: break
        }
        send(body)
    }

    // MARK: 网页发来的

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let model = KitelineModel.shared
        switch type {
        case "ready":
            ready = true
            lastState = ""
            sendInit()
            pushState(force: true)
            var todos = Todos.shared.payload()
            todos["type"] = "todos"
            todos["initial"] = true
            send(todos)
            pushUsage()
            sendActive()
        case "open":
            // 悬浮窗自己一份单块分屏：不切主窗口的分屏、不往里加标签
            if let key = body["key"] as? String { model.worldDetail = key }
        case "select":
            // 点了人：只在世界里飞过去。不改左边栏的选中（那会往主窗口的分屏里加标签）
            break
        case "machine":
            if let id = body["sourceId"] as? String { model.machineDetail = id }
        case "send":
            // 左下角私聊：发给选中的那个会话（同会话页的发送）
            guard let key = body["key"] as? String else { break }
            let images = (body["images"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
            let ok = TarsWorldChat.send(key: key, text: body["text"] as? String ?? "", images: images)
            send(["type": "sent", "ok": ok, "id": body["id"] as? String ?? ""])
        case "dictate":
            dictate(body["action"] as? String ?? "")
        case "exit":
            model.setWorld(false)
        default: break
        }
    }

    // MARK: 听写（左下角私聊的麦克风）

    private var levelTimer: Timer?

    private func dictate(_ action: String) {
        switch action {
        case "start":
            // 拒绝过麦克风：系统不会再弹授权框，直接打开「隐私与安全性 → 麦克风」
            if AVAudioApplication.shared.recordPermission == .denied { micDenied(); return }
            Task { @MainActor in
                let ok = await TarsWorldChat.startDictation()
                guard ok else {
                    if AVAudioApplication.shared.recordPermission == .denied { self.micDenied() }
                    else { self.send(["type": "dictation", "state": "failed", "text": L("录音未能开始，请重试")]) }
                    return
                }
                self.send(["type": "dictation", "state": "recording"])
                self.levelTimer?.invalidate()
                self.levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let host = WorldHost.shared
                        guard TarsWorldChat.recording else { host.levelTimer?.invalidate(); return }
                        host.send(["type": "dictation", "state": "level", "level": TarsWorldChat.level, "elapsed": TarsWorldChat.elapsed])
                        if TarsWorldChat.elapsed >= 60 { host.dictate("stop") }   // 最长一分钟
                    }
                }
            }
        case "stop", "cancel":
            levelTimer?.invalidate()
            let cancel = action == "cancel"
            if !cancel { send(["type": "dictation", "state": "converting"]) }
            Task { @MainActor in
                let text = await TarsWorldChat.finishDictation(cancel: cancel)
                self.send(["type": "dictation", "state": "done", "text": text ?? "",
                           "note": text == "" ? L("未能识别，请重新说一遍") : ""])
            }
        default: break
        }
    }

    private func micDenied() {
        send(["type": "dictation", "state": "failed", "text": L("麦克风权限未开启，请在「系统设置 → 隐私与安全性 → 麦克风」中允许 Kiteline")])
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }

    // MARK: kiteline-world://

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        tasks.insert(ObjectIdentifier(task))
        guard let url = task.request.url else { return }
        if url.path.hasPrefix("/api/") { proxy(task, url: url); return }
        if url.path == "/tts" { speak(task, url: url); return }
        let root = Self.root.standardizedFileURL
        let file = root.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL
        // 只许读 world 目录里的
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            finish(task, status: 404, type: "text/plain", data: Data())
            return
        }
        finish(task, status: 200, type: Self.mime(file.pathExtension), data: data)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        tasks.remove(ObjectIdentifier(task))
    }

    private func finish(_ task: any WKURLSchemeTask, status: Int, type: String, data: Data) {
        guard tasks.remove(ObjectIdentifier(task)) != nil, let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// 图（对话里的图、头像）：转给本机的 Kiteline 服务取，只放行这两个接口
    private func proxy(_ task: any WKURLSchemeTask, url: URL) {
        let mobile = AppState.shared.config.mobile
        guard ["/api/media", "/api/agent-avatar"].contains(url.path),
              var parts = URLComponents(string: "http://127.0.0.1:\(mobile.port)\(url.path)") else {
            finish(task, status: 404, type: "text/plain", data: Data())
            return
        }
        parts.percentEncodedQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        guard let target = parts.url else { finish(task, status: 400, type: "text/plain", data: Data()); return }
        var request = URLRequest(url: target)
        request.setValue(mobile.token, forHTTPHeaderField: "X-CCP-Token")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WorldHost.shared.finish(task, status: status, type: type, data: data ?? Data()) }
            }
        }.resume()
    }

    /// 朗读 agent 之间的交谈：Mac 合成（装了微软神经语音就用它），正常语速出音频，网页里 2 倍速播
    private func speak(_ task: any WKURLSchemeTask, url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let text = String((query.first { $0.name == "text" }?.value ?? "").prefix(300))
        let voice = query.first { $0.name == "voice" }?.value
        guard !text.isEmpty else { finish(task, status: 400, type: "text/plain", data: Data()); return }
        TTS.shared.synthesize(text: text, voice: voice?.isEmpty == false ? voice : nil, rate: 1) { data, type in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WorldHost.shared.finish(task, status: data == nil ? 500 : 200, type: type, data: data ?? Data()) }
            }
        }
    }

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "svg": "image/svg+xml"
        default: "application/octet-stream"
        }
    }

    // MARK: 给网页的设置

    /// 主题色（深色下的那个，世界一直是深灰画布）
    private var brandHex: String {
        var hex = "#D97757"
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            if let c = NSColor(Color.tarsBrand).usingColorSpace(.sRGB) {
                hex = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            }
        }
        return hex
    }

    /// 各家 agent 的标志（24×24 的 SVG 路径）：机房的牌子、后背的头像牌用
    private var marks: [String: [[String: Any]]] {
        var ids = Set(Agents.all.map(\.id))
        for session in KitelineModel.shared.sessions { ids.insert(session.agent) }
        var out: [String: [[String: Any]]] = [:]
        for id in ids {
            let paths = Agents.info(id).markPaths
            if !paths.isEmpty { out[id] = paths.map { ["d": $0.d, "opacity": $0.opacity] } }
        }
        return out
    }

    /// 网页里的界面文字（中文原文 → 当前语言）：清单在 KitelineKit 的 WorldStrings（iPhone 也用）
    static var strings: [String: String] { WorldStrings.table }
}
