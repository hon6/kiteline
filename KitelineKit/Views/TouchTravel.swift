import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 底部弹窗里的按钮防误触：手指按在按钮上拖弹窗（拉高、往下拉关），按钮跟着弹窗一起走，
/// 系统觉得手指一直在按钮上，松手就算点了。这里在窗口上记下这一下：手指按着的那块界面在屏幕上被带着挪了多远，
/// 挪过就不算点。只看界面挪没挪、不看手指挪没挪：按着开关滑一下照样能拨，手抖一点的点按也照样算。
/// 通用的按钮样式（RowButtonStyle、PressableStyle、.steady(...)）和开关都已经带上这个判断。
@MainActor
enum TouchTravel {
    /// 最近一次按下到现在，手指按着的界面最远被带着挪了多少
    fileprivate(set) static var shift: CGFloat = 0

    /// 是不是一次「点」：手指底下的界面没被拖动
    static var isTap: Bool { shift < 8 }
}

#if canImport(UIKit)
/// 挂在窗口上、只看不抢的手势：什么都不识别，不挡别的手势，也不耽误点击
private final class TravelRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// 按下时手指底下那个视图，和它当时在屏幕上的位置（滚动视图取可见区域的左上角，滚动不算挪）
    private weak var view0: UIView?
    private var start: CGPoint?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard start == nil, let touch = touches.first else { return }
        TouchTravel.shift = 0
        guard let view = touch.view else { return }
        view0 = view
        start = view.convert(view.bounds.origin, to: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { measure() }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        measure()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    override func reset() {
        start = nil
        view0 = nil
    }

    private func measure() {
        guard let start, let view = view0 else { return }
        let now = view.convert(view.bounds.origin, to: nil)
        TouchTravel.shift = max(TouchTravel.shift, hypot(now.x - start.x, now.y - start.y))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private final class TravelInstallerView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, !(window.gestureRecognizers ?? []).contains(where: { $0 is TravelRecognizer }) else { return }
        window.addGestureRecognizer(TravelRecognizer(target: nil, action: nil))
    }
}

private struct TravelInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = TravelInstallerView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

extension View {
    /// 在窗口上装好「手指挪了多远」的记录（根视图挂一次）
    func tracksTouchTravel() -> some View {
        #if canImport(UIKit)
        background(TravelInstaller().allowsHitTesting(false))
        #else
        self
        #endif
    }
}

// MARK: 带防误触的按钮样式和开关

/// 包一层：外观照原来的样式，只是被拖过的那一下不触发。`.buttonStyle(.steady(.plain))`
struct SteadyStyle<Inner: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let inner: Inner

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) { if TouchTravel.isTap { configuration.trigger() } } label: { configuration.label }
            .buttonStyle(inner)
    }
}

extension PrimitiveButtonStyle {
    static func steady<Inner: PrimitiveButtonStyle>(_ inner: Inner) -> SteadyStyle<Inner> where Self == SteadyStyle<Inner> {
        SteadyStyle(inner: inner)
    }
}

/// 开关：被拖过的那一下不拨（根视图上统一挂）。打开时的颜色 = 主题的主按钮色（经典主题是绿色；根视图的 tint 是强调色，不能让开关跟它）
struct SteadySwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: Binding(get: { configuration.isOn }, set: { if TouchTravel.isTap { configuration.isOn = $0 } })) {
            configuration.label
        }
        .toggleStyle(.switch)
        .tint(Theme.wechatGreen)
    }
}
