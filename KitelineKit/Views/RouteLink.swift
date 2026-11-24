import SwiftUI

/// 推一页（代替 NavigationLink(value: Route…)，macOS 13 起才有）：
/// 新系统上就是 NavigationLink(value:)；macOS 12 上没有按值导航，改成按钮，交给环境里的 openRoute（Mac 面板自己排页面，见 MacEmbed.swift 的 PanelStack）
struct RouteLink<Label: View>: KLView {
    let value: Route
    let label: () -> Label
    @Environment(\.openRoute) private var openRoute

    init(value: Route, @ViewBuilder label: @escaping () -> Label) {
        self.value = value; self.label = label
    }

    var klBody: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            NavigationLink(value: value, label: label)
        } else {
            Button { openRoute(value) } label: { label() }
        }
        #elseif os(iOS) || KL_MODERN
        NavigationLink(value: value, label: label)
        
        #else
        if #available(macOS 13, iOS 16, *) {
            NavigationLink(value: value, label: label)
        } else {
            Button { openRoute(value) } label: { label() }
        }
        #endif
    }
}
