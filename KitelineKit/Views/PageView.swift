import SwiftUI
import WebKit

/// agent 发来的网页（agent_page，watcher 的 send-page：图表、对比表、报告）：从电脑取回来，
/// 手机、iPad 上在 App 里打开（能交互、能缩放，右上角可转发）；Mac 主窗口用默认浏览器打开
@MainActor
final class PageOpener {
    static let shared = PageOpener()
    private var task: Task<Void, Never>?

    func open(_ model: AppModel, key: String, item: ChatItem) {
        guard let page = item.images?.first else { return }
        let title = item.title ?? L("网页")
        task?.cancel()
        model.hold(L("正在打开「%@」…", title))
        task = Task { [weak model] in
            guard let model else { return }
            do {
                let data = try await model.api.data("/api/media", ["key": key, "ref": page.ref])
                guard !Task.isCancelled else { return }
                let file = try FileOpener.save(data, name: title + ".html")
                model.hold(nil)
                present(file, title: title)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                model.hold(nil)
                model.flash(L("无法打开网页：%@", error.localizedDescription))
            }
        }
    }

    private func present(_ file: URL, title: String) {
        #if os(iOS)
        Haptics.tap()
        let nav = UINavigationController(rootViewController: PageController(file: file, title: title))
        // iPhone 铺满（图表要宽度）；iPad 用卡片样式，下面的会话还看得到
        nav.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .phone ? .fullScreen : .pageSheet
        SystemShare.top?.present(nav, animated: true)
        #else
        NSWorkspace.shared.open(file)
        #endif
    }
}

#if os(iOS)
/// 在 App 里看 agent 写的网页。网页里的脚本照常跑（图表库要用），但用不留数据的网页存储、不接任何和 App 通信的口子：
/// 它读不到 App 里的东西；页面里点的链接到 Safari 打开
private final class PageController: UIViewController, WKNavigationDelegate {
    private let file: URL

    init(file: URL, title: String) {
        self.file = file
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        view = web
        web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            SystemShare.present([self.file])
        })
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // 点了页面里的网址：交给 Safari；页面自己的加载（打开、#锚点、iframe）放行
        if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
            await UIApplication.shared.open(url)
            return .cancel
        }
        return .allow
    }
}
#endif
