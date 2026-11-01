#if canImport(UIKit) && !KITELINE_MAC
import SwiftUI
import UIKit

/// 底部的小提示（「已复制」、出错的原因……）画在一个单独的透明窗口里，盖在弹出的面板上面。
/// 原来画在主界面上，新任务、设置这些面板一弹出来就把它挡住：在面板里点了按钮出了错，看起来就像「没反应」。
/// 窗口只显示、不接手指（点按照常落到下面的界面），没提示时藏起来；状态栏照主界面的来。同 Mac 版的 MacToast
@MainActor
enum ToastWindow {
    private static var window: UIWindow?
    private static var host: ToastHost?
    private static var generation = 0
    private static var hideTask: Task<Void, Never>?

    /// 不经过 AppModel 的小提示（复制这类到处都有、不一定拿得到 model 的地方）：2.5 秒后自己收起，和 model.flash 一样长
    static func flash(_ text: String) {
        show(text)
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { show(nil) }
        }
    }

    static func show(_ text: String?) {
        generation += 1
        let current = generation
        guard let text else {
            guard let window, !window.isHidden else { return }
            UIView.animate(withDuration: 0.2, animations: { window.alpha = 0 }) { _ in
                if current == generation { window.isHidden = true }   // 渐隐时又来了一条：别把新的收掉
            }
            return
        }
        guard let window = window ?? make() else { return }
        host?.rootView = ToastBubble(text: text)
        // 深浅色跟着主界面（App 里可以单独设成浅色 / 深色）
        if let main = window.windowScene?.windows.first(where: { $0 !== window && $0.isKeyWindow }) {
            window.overrideUserInterfaceStyle = main.traitCollection.userInterfaceStyle
        }
        if window.isHidden {
            window.alpha = 0
            window.isHidden = false
        }
        host?.setNeedsStatusBarAppearanceUpdate()
        UIView.animate(withDuration: 0.2) { window.alpha = 1 }
    }

    private static func make() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let host = ToastHost(rootView: ToastBubble(text: ""))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = true
        self.window = window
        self.host = host
        return window
    }
}

/// 不接手指：点按落到下面的窗口
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// 盖在最上面的窗口会接管状态栏：样式和显隐问主界面现在最上层的页面（看图时状态栏是藏着的）
private final class ToastHost: UIHostingController<ToastBubble> {
    private var shown: UIViewController? {
        guard var page = view.window?.windowScene?.windows.first(where: { $0 !== view.window && $0.isKeyWindow })?.rootViewController else { return nil }
        while let next = page.presentedViewController, !next.isBeingDismissed { page = next }
        return page
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { shown?.preferredStatusBarStyle ?? .default }
    override var prefersStatusBarHidden: Bool { shown?.prefersStatusBarHidden ?? false }
}

private struct ToastBubble: View {
    let text: String

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if !text.isEmpty {
                Text(text)
                    .font(.ui(.subheadline))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.horizontal, 30)
                    .padding(.bottom, 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
