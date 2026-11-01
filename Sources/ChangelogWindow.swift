import AppKit
import SwiftUI
import KitelineKit

/// 更新记录窗口（设置 → 关于 →「更新记录」、菜单「Kiteline → 更新记录…」）：和手机同一个时间轴页面（KitelineKit 的 TarsChangelogView），
/// 读 App 里打包的 CHANGELOG.md。以前是用浏览器打开本机网页（127.0.0.1:8765/#/changelog），网页版下线后改在 App 里看
final class ChangelogWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ChangelogWindowController()
    private let content = ChangelogContent()

    private init() {
        let hosting = NSHostingController(rootView: ChangelogRoot(content: content))
        hosting.sizingOptions = []   // 窗口大小由用户拖，不跟内容走（内容几十屏高）
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = L("更新记录")
        NotificationCenter.default.addObserver(forName: Lang.didChange, object: nil, queue: .main) { [weak window] _ in
            window?.title = L("更新记录")   // AppKit 的标题建好就不变：换了界面语言跟着重设
        }
        NotificationCenter.default.addObserver(forName: Lang.didChange, object: nil, queue: .main) { [content] _ in
            content.text = Self.bundledText()   // 开着窗口时换了语言：内容换成另一种语言的版本
        }
        window.minSize = NSSize(width: 480, height: 420)
        window.setContentSize(NSSize(width: 700, height: 780))
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("KitelineChangelog") { window.center() }
        window.setFrameAutosaveName("KitelineChangelog")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool { window?.isVisible == true }

    /// 每次打开都重读一遍：开着窗口时装了新版本，再点一次就是新的。按界面语言读中文版 / 英文版（没打包英文版就用中文版）
    static func bundledText(english: Bool = Lang.shared.isEnglish) -> String {
        let url = Bundle.main.url(forResource: Lang.changelogName(english: english), withExtension: "md")
            ?? Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    func show() {
        content.text = Self.bundledText()
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            if !MainWindowController.shared.isVisible && !SettingsWindowController.shared.isVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

private final class ChangelogContent: ObservableObject {
    @Published var text = ""
}

private struct ChangelogRoot: View {
    @ObservedObject var content: ChangelogContent

    var body: some View {
        TarsChangelogView(markdown: content.text, version: AppVersion.app)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .tarsLook()
    }
}
