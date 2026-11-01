import SwiftUI
import WebKit

/// 编辑器内核（Resources/editor/code-editor.html：CodeMirror 6 + VS Code 配色，tools/editor 打包）外面包的一层。
/// IDE 里开文件、取内容、保存、对比都经它调网页里的 window.KL；网页经 webkit.messageHandlers.kl 回报改动、光标、⌘S
@MainActor @Observable
final class EditorController: NSObject {
    @ObservationIgnored let webView: WKWebView
    private(set) var ready = false
    @ObservationIgnored private var queue: [String] = []
    /// 改了还没保存的标签
    var dirty: Set<String> = []
    var line = 1
    var column = 1
    var selected = 0
    var lines = 0
    var cursors = 1
    var language = ""
    var indent = ""
    /// 对比时有几处改动
    var diffChunks = 0
    /// 网页里按了 ⌘S（标签 id）
    @ObservationIgnored var onSave: ((String) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        let proxy = EditorMessageProxy()
        config.userContentController.add(proxy, name: "kl")
        #if os(iOS)
        config.dataDetectorTypes = []
        #endif
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        proxy.owner = self
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif
        if let url = Self.page {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// Mac 包里在 Resources/editor/ 下；iPhone 的 Xcode 同步文件夹把它摊平在包根
    static var page: URL? {
        Bundle.main.url(forResource: "code-editor", withExtension: "html", subdirectory: "editor")
            ?? Bundle.main.url(forResource: "code-editor", withExtension: "html")
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            let pending = queue
            queue.removeAll()
            for script in pending { webView.evaluateJavaScript(script, completionHandler: nil) }
        case "change":
            guard let id = message["id"] as? String else { return }
            if message["dirty"] as? Bool == true { dirty.insert(id) } else { dirty.remove(id) }
        case "cursor":
            line = message["line"] as? Int ?? line
            column = message["col"] as? Int ?? column
            selected = message["selected"] as? Int ?? 0
            lines = message["lines"] as? Int ?? lines
            cursors = message["cursors"] as? Int ?? 1
        case "info":
            language = message["language"] as? String ?? ""
            indent = message["indent"] as? String ?? ""
            lines = message["lines"] as? Int ?? 0
        case "diff":
            diffChunks = message["chunks"] as? Int ?? 0
            language = message["language"] as? String ?? language
        case "save":
            if let id = message["id"] as? String { onSave?(id) }
        default:
            break
        }
    }

    // MARK: 调网页

    private func call(_ function: String, _ args: Any...) {
        let encoded = args.map(Self.json).joined(separator: ",")
        let script = "KL.\(function)(\(encoded))"
        if ready { webView.evaluateJavaScript(script, completionHandler: nil) } else { queue.append(script) }
    }

    private static func json(_ value: Any) -> String {
        if value is NSNull { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return String(text.dropFirst().dropLast())
    }

    /// 打开（或重新载入）一个标签
    func open(id: String, path: String, text: String, readOnly: Bool, line: Int? = nil, baseline: String? = nil, options: EditorOptions) {
        var payload = options.payload
        payload["id"] = id
        payload["path"] = path
        payload["text"] = text
        payload["readOnly"] = readOnly
        if let line { payload["line"] = line }
        if let baseline { payload["baseline"] = baseline }
        dirty.remove(id)
        call("open", payload)
    }

    func show(_ id: String) { call("show", id) }
    func close(_ id: String) { dirty.remove(id); call("close", id) }
    func setOptions(_ options: EditorOptions) { call("setOptions", options.payload) }
    func setReadOnly(_ readOnly: Bool) { call("setOptions", ["readOnly": readOnly]) }
    func command(_ name: String, _ arg: String? = nil) { if let arg { call("command", name, arg) } else { call("command", name) } }
    func insert(_ text: String) { call("insert", text) }
    func gotoLine(_ line: Int) { call("gotoLine", line) }
    func setBaseline(_ text: String?) { call("setBaseline", text ?? NSNull()) }
    func replaceAll(_ text: String) { call("replaceAll", text) }
    func nextChange(_ direction: Int) { call("nextChange", direction) }
    func markSaved(_ id: String, text: String, baseline: String? = nil) {
        if let baseline { call("markSaved", id, text, baseline) } else { call("markSaved", id, text) }
    }

    func diff(original: String, modified: String, path: String, split: Bool, options: EditorOptions) {
        var payload = options.payload
        payload["original"] = original
        payload["modified"] = modified
        payload["path"] = path
        payload["split"] = split
        call("diff", payload)
    }

    /// 标签现在的内容（保存时取）
    func text(_ id: String) async -> String? {
        guard ready else { return nil }
        let result = try? await webView.evaluateJavaScript("KL.getText(\(Self.json(id)))")
        return result as? String
    }
}

/// 外观：深浅色、字号、自动换行、小地图
struct EditorOptions: Equatable {
    var dark: Bool
    var fontSize: Double
    var wrap: Bool
    var minimap: Bool

    /// 编辑器里查找面板这类字跟着 App 的界面语言
    var payload: [String: Any] { ["dark": dark, "fontSize": fontSize, "wrap": wrap, "minimap": minimap, "lang": Lang.shared.isEnglish ? "en" : "zh"] }
}

/// 网页回报的消息：WKUserContentController 会强引用 handler，经这层弱引用转给控制器，免得互相拽着谁都放不掉
private final class EditorMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: EditorController?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { owner?.receive(body) }
    }
}

#if os(iOS)
struct CodeWebView: UIViewRepresentable {
    let controller: EditorController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct CodeWebView: NSViewRepresentable {
    let controller: EditorController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

/// 编辑器的外观设置（全 App 一份，记在本机；视图里用 @AppStorage(EditorPrefs.fontSizeKey) 读写）
enum EditorPrefs {
    static let fontSizeKey = "codeFontSize"
    static let wrapKey = "codeWrap"
    static let minimapKey = "codeMinimap"
    #if os(macOS)
    static let defaultFontSize: Double = 13
    #else
    static let defaultFontSize: Double = 12
    #endif
}

#if os(iOS)
/// 键盘上方那排键：Tab、括号引号、常用符号、撤销重做、查找、收起键盘（手机键盘上找这些要切好几次）
struct CodeKeyBar: View {
    let controller: EditorController
    private let symbols = ["{", "}", "(", ")", "[", "]", "<", ">", "=", ";", ":", "\"", "'", "/", "\\", "|", "-", "_", "+", "*", "&", "!", "?", "#", "$", "@", "`", ",", "."]

    var body: some View {
        HStack(spacing: 0) {
            key(systemImage: "arrow.right.to.line") { controller.insert("\t") }
            key(systemImage: "arrow.left.to.line") { controller.command("indentLess") }
            Divider().frame(height: 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button { controller.insert(symbol) } label: {
                            Text(symbol).font(.system(size: 17, weight: .regular, design: .monospaced))
                                .frame(minWidth: 30, minHeight: 36)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
            Divider().frame(height: 22)
            key(systemImage: "arrow.uturn.backward") { controller.command("undo") }
            key(systemImage: "arrow.uturn.forward") { controller.command("redo") }
            key(systemImage: "magnifyingglass") { controller.command("find") }
            key(systemImage: "keyboard.chevron.compact.down") { controller.command("blur") }
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func key(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 15, weight: .medium)).frame(width: 38, height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
#endif
