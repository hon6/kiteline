import AppKit
import SwiftUI

/// 鼠标停在图标按钮上 0.35 秒后显示的说明。
///
/// 系统的 `.help()` 提示在主窗口侧栏底栏里显示不出来（辅助功能里读得到，鼠标停上去就是不出，10-22 反馈），
/// 而且要停一秒多。这里用一个不抢焦点、不接鼠标的小浮窗画在鼠标上方：不会被侧栏列表盖住，也不打断输入框里的输入。
/// 文字照样作为辅助功能提示（旁白读得到）
struct HoverTip: ViewModifier {
    let text: String
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .onHover { inside in
                pending?.cancel()
                pending = nil
                if inside {
                    let work = DispatchWorkItem { HoverTipPanel.show(text) }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
                } else {
                    HoverTipPanel.hide()
                }
            }
            // 点了按钮（文字可能跟着变）、按钮消失：提示收起来
            .simultaneousGesture(TapGesture().onEnded {
                pending?.cancel()
                HoverTipPanel.hide()
            })
            .onDisappear {
                pending?.cancel()
                HoverTipPanel.hide()
            }
    }
}

extension View {
    /// 鼠标停上去显示的说明（代替 `.help()`，见 HoverTip）
    func hoverTip(_ text: String) -> some View { modifier(HoverTip(text: text)) }
}

/// 提示浮窗：同一时间只有一个
enum HoverTipPanel {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        hide()
        let hosting = NSHostingView(rootView: Label(text: text).tarsLook())
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        // 放在鼠标正上方；上面放不下（贴着屏幕顶）就放到下面；左右不出屏幕
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y + 14)
        if origin.y + size.height > visible.maxY { origin.y = mouse.y - size.height - 22 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private struct Label: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.app(size: 12))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .tarsGlass(cornerRadius: 10)
                .padding(6)
        }
    }
}
