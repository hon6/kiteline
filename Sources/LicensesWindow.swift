import AppKit
import SwiftUI
import KitelineKit

/// 开源许可窗口（设置 → 关于 →「开源许可」）：和手机同一个页面（KitelineKit 的 LicensesView），
/// 读 App 里打包的 ThirdPartyNotices.json（tools/licenses.py 生成，build.sh 拷进 Contents/Resources）
final class LicensesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LicensesWindowController()

    private init() {
        let hosting = NSHostingController(rootView: LicensesRoot())
        hosting.sizingOptions = []   // 窗口大小由用户拖，不跟内容走
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = L("开源许可")
        NotificationCenter.default.addObserver(forName: Lang.didChange, object: nil, queue: .main) { [weak window] _ in
            window?.title = L("开源许可")   // AppKit 的标题建好就不变：换了界面语言跟着重设
        }
        window.minSize = NSSize(width: 620, height: 420)
        window.setContentSize(NSSize(width: 860, height: 640))
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("KitelineLicenses") { window.center() }
        window.setFrameAutosaveName("KitelineLicenses")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
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

private struct LicensesRoot: View {
    var body: some View {
        LicensesView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .tarsLook()
    }
}
