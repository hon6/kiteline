#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit
import WebKit

// 世界模式（iPhone、iPad）：整屏是像素世界（网页同 Mac，Resources/world 由 tools/sync-world.sh 拷进 iPhone App，协议见 docs/world.md）。
// 数据走手机已经连着的那条通道（局域网、远程访问都一样）：整份状态、对话增量、会话之间的消息、负载、待办转给网页；
// 图片、头像、朗读的语音由这里代取。点屏幕弹出会话页，点卫星弹设备详情，右上角的门关掉世界

/// 全屏的世界：网页 + 点出来的会话页、设备详情。page = world（像素园区）/ flow（数据流大屏，同一个宿主换一页）
struct WorldScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bridge: WorldBridge
    private let page: String

    init(page: String = "world") {
        self.page = page
        _bridge = State(initialValue: WorldBridge(page: page))
    }
    @State private var chatKey: ChatTarget?
    @State private var machine: ChatTarget?

    /// 弹出的会话 / 机器（sheet 要 Identifiable）
    struct ChatTarget: Identifiable { let id: String }

    var body: some View {
        // 只铺满刘海、横条这些边（网页按 insets 让开）；键盘弹出时整块缩到键盘上方，私聊输入框不被挡
        WorldWebView(bridge: bridge)
            .ignoresSafeArea(.container)
            .background(Color(uiColor: WorldBridge.canvas(page)))
            .onAppear {
                bridge.model = model
                bridge.onOpen = { chatKey = ChatTarget(id: $0) }
                bridge.onMachine = { machine = ChatTarget(id: $0) }
                bridge.onExit = { dismiss() }
                WorldBridge.current = bridge
            }
            .onDisappear {
                if WorldBridge.current === bridge { WorldBridge.current = nil }
                bridge.stop()
            }
            // 会话页：同点进会话一样（能看能回），往下一拉回到世界
            .sheet(item: $chatKey) { target in
                NavigationStack {
                    ChatView(key: target.id)
                        .toolbar {
                            // 左上角关掉、回到世界：横着的 iPhone 上弹出页铺满整屏，看不出能往下拉（10-27：进去回不来）
                            ToolbarItem(placement: .topBarLeading) {
                                Button { chatKey = nil } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("关闭")
                            }
                        }
                }
                    .environment(model)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $machine) { target in
                MachineInfoSheet(sourceId: target.id).environment(model)
            }
            .onChange(of: chatKey == nil && machine == nil) { _, clear in bridge.setCovered(!clear) }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
    }
}

/// 放网页的地方
private struct WorldWebView: UIViewRepresentable {
    let bridge: WorldBridge

    func makeUIView(context: Context) -> WorldContainerView {
        let view = WorldContainerView()
        view.bridge = bridge
        view.addSubview(bridge.makeWebView())
        return view
    }

    func updateUIView(_ view: WorldContainerView, context: Context) {}
}

final class WorldContainerView: UIView {
    weak var bridge: WorldBridge?

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
        // 刘海、灵动岛、底部横条盖住多少：网页的统计条、对话框让开
        let insets = safeAreaInsets
        MainActor.assumeIsolated { bridge?.setInsets(insets) }
    }
}

/// 网页和 App 之间（同 Mac 的 WorldHost）：kiteline-world://app/ 读包里的 World 目录，/api/media、/api/agent-avatar、/tts 经手机连着的接口取
@MainActor
final class WorldBridge: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
    /// 正开着的世界（AppModel 收到事件时转给它）
    static weak var current: WorldBridge?
    static let scheme = "kiteline-world"

    weak var model: AppModel?
    /// world → index.html，flow → flow.html
    let page: String
    var onOpen: (String) -> Void = { _ in }
    var onMachine: (String) -> Void = { _ in }
    var onExit: () -> Void = {}
    private var web: WKWebView?
    private var ready = false
    private var insets = UIEdgeInsets.zero
    private var usageTask: Task<Void, Never>?
    private var recorder: VoiceRecorder?
    private var levelTask: Task<Void, Never>?

    private static var root: URL { Bundle.main.resourceURL!.appendingPathComponent("World") }

    init(page: String = "world") {
        self.page = page
        super.init()
    }

    static func canvas(_ page: String) -> UIColor {
        page == "flow" ? UIColor(red: 0x06 / 255, green: 0x07 / 255, blue: 0x0B / 255, alpha: 1)
            : UIColor(red: 0x2A / 255, green: 0x2B / 255, blue: 0x2F / 255, alpha: 1)
    }

    func makeWebView() -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        config.userContentController.add(self, name: "world")
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = Self.canvas(page)
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        web.load(URLRequest(url: URL(string: "\(Self.scheme)://app/\(page == "flow" ? "flow" : "index").html")!))
        self.web = web
        return web
    }

    func stop() {
        usageTask?.cancel()
        levelTask?.cancel()
        _ = recorder?.stop(cancel: true)
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "world")
        web = nil
        ready = false
    }

    func setInsets(_ value: UIEdgeInsets) {
        guard value != insets else { return }
        insets = value
        if ready { send(["type": "insets", "top": value.top, "left": value.left, "right": value.right, "bottom": value.bottom]) }
    }

    // MARK: 推给网页

    private func send(_ object: [String: Any]) {
        guard let web, let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("World.receive(\(json))", completionHandler: nil)
    }

    /// AppModel 收到的实时事件：整份状态、对话增量、会话之间的消息、负载、待办原样转过来
    func event(_ name: String, _ data: Data) {
        guard ready, ["state", "entries", "peers", "sys", "todos"].contains(name), let web,
              let json = String(data: data, encoding: .utf8) else { return }
        let body = name == "state" ? "{type:'state',state:\(json)}" : "Object.assign(\(json),{type:'\(name)'})"
        web.evaluateJavaScript("World.receive(\(body))", completionHandler: nil)
    }

    private func start() {
        guard let model else { return }
        ready = true
        send(initPayload(voices: []))
        if let state = model.stateJSON, let json = String(data: state, encoding: .utf8) {
            web?.evaluateJavaScript("World.receive({type:'state',state:\(json)})", completionHandler: nil)
        }
        Task {
            if let todos = try? await model.api.get("/api/todos") { send(todos.merging(["type": "todos", "initial": true]) { $1 }) }
            // 朗读用电脑上的声音（每个会话固定一种）：取到了再补一次 init
            if let reply = try? await model.api.get("/api/tts/voices"), let list = reply["voices"] as? [[String: Any]] {
                let voices = Array(list.compactMap { $0["id"] as? String }.prefix(6))
                if !voices.isEmpty { send(initPayload(voices: voices)) }
            }
        }
        // 今日用量（公司墙的计量牌）：开着时每分钟取一次
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                if let usage = try? await model.api.get("/api/usage", ["days": "1"]) { self?.send(usage.merging(["type": "usage"]) { $1 }) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func initPayload(voices: [String]) -> [String: Any] {
        var marks: [String: [[String: Any]]] = [:]
        for agent in Set(Agents.all.map(\.id) + (model?.sessions.map(\.agent) ?? [])) {
            let paths = Agents.info(agent).markPaths
            if !paths.isEmpty { marks[agent] = paths.map { ["d": $0.d, "opacity": $0.opacity] } }
        }
        return ["type": "init", "lang": Lang.shared.isEnglish ? "en" : "zh", "strings": WorldStrings.table, "brand": brandHex,
                "quality": UIDevice.current.userInterfaceIdiom == .pad ? "high" : "medium", "door": true,
                "mediaBase": "\(Self.scheme)://app/", "marks": marks, "voices": voices,
                "insets": ["top": insets.top, "left": insets.left, "right": insets.right, "bottom": insets.bottom]]
    }

    #if DEBUG || SNAPSHOT
    /// 调试遥控（DebugRemote 的 worldjs）
    func evaluate(_ script: String) { web?.evaluateJavaScript(script, completionHandler: nil) }
    #endif

    /// 会话页、设备详情盖住世界时停画、不念
    func setCovered(_ covered: Bool) {
        if ready { send(["type": "active", "active": !covered, "visible": !covered]) }
    }

    private var brandHex: String {
        let color = UIColor(Look.shared.palette.accent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    // MARK: 网页发来的

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready": start()
        case "open": if let key = body["key"] as? String { onOpen(key) }
        case "machine": if let id = body["sourceId"] as? String { onMachine(id) }
        case "exit": onExit()
        case "send":
            guard let model, let key = body["key"] as? String else { break }
            let images = (body["images"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }.prefix(6).compactMap { ImagePrep.prepare($0) }
            let ok = model.send(key, text: body["text"] as? String ?? "", images: images.enumerated().map { ("image-\($0.offset + 1).jpg", $0.element.jpeg, $0.element.preview) }) != nil
            send(["type": "sent", "ok": ok])
        case "dictate": dictate(body["action"] as? String ?? "")
        default: break
        }
    }

    /// 私聊的听写：同手机上「按住说话」的录音和转写（交给电脑上的语音识别）
    private func dictate(_ action: String) {
        switch action {
        case "start":
            Task {
                let current = recorder ?? VoiceRecorder()
                recorder = current
                guard await current.start() else {
                    send(["type": "dictation", "state": "failed", "text": L("麦克风权限未开启，请在「设置 → 隐私与安全性 → 麦克风」中允许 Kiteline")])
                    return
                }
                send(["type": "dictation", "state": "recording"])
                levelTask?.cancel()
                levelTask = Task { [weak self] in
                    while !Task.isCancelled, let self, let recorder = self.recorder, recorder.recording {
                        self.send(["type": "dictation", "state": "level", "level": recorder.levels.last ?? 0, "elapsed": recorder.elapsed])
                        if recorder.elapsed >= 60 { self.dictate("stop"); break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        case "stop", "cancel":
            levelTask?.cancel()
            let cancel = action == "cancel"
            guard let clip = recorder?.stop(cancel: cancel), !cancel else { send(["type": "dictation", "state": "done", "text": ""]); return }
            send(["type": "dictation", "state": "converting"])
            Task {
                let text = clip.duration >= 0.8 ? await model?.transcribe(clip.data) ?? "" : ""
                send(["type": "dictation", "state": "done", "text": text, "note": text.isEmpty ? L("未能识别，请重新说一遍") : ""])
            }
        default: break
        }
    }

    // MARK: kiteline-world://

    private var tasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        tasks.insert(ObjectIdentifier(task))
        guard let url = task.request.url else { return }
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { $1 }
        if url.path == "/api/media" || url.path == "/api/agent-avatar" {
            Task {
                let data = try? await model?.api.data(url.path, query)
                finish(task, status: data == nil ? 404 : 200, type: "image/jpeg", data: data ?? Data())
            }
            return
        }
        // 数据流页打开时补每个会话最近的调用
        if url.path == "/api/history" {
            Task {
                let data = try? await model?.api.data(url.path, query)
                finish(task, status: data == nil ? 404 : 200, type: "application/json", data: data ?? Data())
            }
            return
        }
        if url.path == "/tts" {
            Task {
                var body: [String: Any] = ["text": String((query["text"] ?? "").prefix(300)), "rate": 1]
                if let voice = query["voice"], !voice.isEmpty { body["voice"] = voice }
                let data = try? await model?.api.postData("/api/tts", body: body)
                finish(task, status: data == nil ? 500 : 200, type: "audio/mpeg", data: data ?? Data())
            }
            return
        }
        // 网页文件：先按目录找（Xcode 保留了子目录时），找不到按文件名在包里找（同步文件夹把资源摊平到包根时）
        let rel = String(url.path.dropFirst())
        let root = Self.root.standardizedFileURL
        let nested = root.appendingPathComponent(rel).standardizedFileURL
        let name = (rel as NSString).lastPathComponent
        let file = nested.path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: nested.path) ? nested
            : Bundle.main.url(forResource: name, withExtension: nil)
        guard let file, let data = try? Data(contentsOf: file) else {
            finish(task, status: 404, type: "text/plain", data: Data())
            return
        }
        finish(task, status: 200, type: Self.mime((name as NSString).pathExtension), data: data)
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

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "woff2": "font/woff2"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }
}
#endif
