import SwiftUI

/// 从底部弹出、高度跟着内容走的面板：内容少就矮，不在底下留一大块空白；内容超过屏幕就到顶、能滚。
/// 顶上一行标题 + 「完成」（不用 NavigationStack，好量出整块多高）；bottom：固定在底部、不跟着内容滚的主按钮
struct FitSheet<Content: View, Bottom: View>: View {
    let title: String
    var background: Color = Theme.pageBackground
    /// 面板里有自己的主按钮（比如「加入 3 项」）：关面板的按钮叫「取消」、放左上角，免得右上角的「完成」被当成确认
    var cancel = false
    /// 右上角关面板的按钮换个说法（比如新版本面板的「以后再说」）；只在 iPhone / iPad 上用
    var doneTitle: String?
    let content: Content
    let bottom: Bottom
    @PanelDismiss private var dismiss
    @State private var headerHeight: CGFloat = 56
    @State private var contentHeight: CGFloat = 280
    @State private var bottomHeight: CGFloat = 0

    init(title: String, background: Color = Theme.pageBackground, cancel: Bool = false, doneTitle: String? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder bottom: () -> Bottom) {
        self.title = title
        self.background = background
        self.cancel = cancel
        self.doneTitle = doneTitle
        self.content = content()
        self.bottom = bottom()
    }

    /// 底部那条：内容从它下面滚过，上沿渐隐成面板底色（按钮像浮在底部）
    @ViewBuilder private var bottomBar: some View {
        if Bottom.self != EmptyView.self {
            bottom
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
                .background {
                    LinearGradient(stops: [.init(color: background.opacity(0), location: 0), .init(color: background, location: 0.3)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
        }
    }

    var body: some View {
        #if os(macOS)
        // Mac：面板是能拖动、改大小的小窗，标题和「完成」放在小窗的工具栏里（同别的面板）；内容能滚。
        // 放进 NavigationStack：不在导航栈里的工具栏按钮，系统按纯图标给的宽，「完成」两个字撑破玻璃底
        NavigationStack {
            ScrollView {
                // 包一层：content 是几块并列的（几个分组）时，量的是整块的高度，不是最后一块
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .background(background.ignoresSafeArea())
            .navigationTitle(title)
            .modifier(FitSheetClose(cancel: cancel) { dismiss() })
        }
        // 打开时 520 宽，高度跟着内容走、最高 660；之后能拖边改大小
        .frame(minWidth: 360, idealWidth: 520, maxWidth: .infinity,
               minHeight: 120, idealHeight: min(max(contentHeight + bottomHeight, 120), 660, MacSheetLimit.size.height), maxHeight: .infinity)
        #else
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.ui(.headline)).lineLimit(1).padding(.horizontal, 70)
                HStack {
                    if cancel {
                        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                        Spacer()
                    } else if let doneTitle {
                        Spacer()
                        Button(doneTitle) { dismiss() }.fontWeight(.semibold).keyboardShortcut(.cancelAction)
                    } else {
                        Spacer()
                        Button("完成") { dismiss() }.fontWeight(.semibold).keyboardShortcut(.cancelAction)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
        .background(background)
        .presentationDetents([.height(headerHeight + contentHeight + bottomHeight)])
        .presentationDragIndicator(.visible)
        #endif
    }
}

extension FitSheet where Bottom == EmptyView {
    init(title: String, background: Color = Theme.pageBackground, cancel: Bool = false, doneTitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, background: background, cancel: cancel, doneTitle: doneTitle, content: content, bottom: { EmptyView() })
    }
}

#if os(macOS)
/// Mac 面板右上角关面板的按钮：一般是「完成」（同别的面板的 doneButton）；面板里有自己的主按钮时叫「取消」、放左边。
/// 工具栏按钮的位置别按条件现算：那样系统把它当成一段字，玻璃底按字宽套，「完成」两个字撑破玻璃底
private struct FitSheetClose: ViewModifier {
    let cancel: Bool
    let close: () -> Void

    func body(content: Content) -> some View {
        if cancel {
            content.toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消"), action: close).keyboardShortcut(.cancelAction).panelToolbarButton() }
            }
        } else {
            content.doneButton(close)
        }
    }
}
#endif

/// 面板里的一组：小标题 + 白底圆角卡片 + 底下的小字说明（同系统设置的分组）
struct SheetSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.ui(.footnote)).foregroundStyle(.secondary).padding(.leading, 16) }
            MenuGroup { content }
            if let footer { Text(footer).font(.ui(.caption)).foregroundStyle(.secondary).padding(.horizontal, 16) }
        }
        .padding(.bottom, 14)
    }
}

/// 面板卡片里的一行文字信息：左边名字，右边值
struct SheetInfoRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            value.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)   // 长的（目录）换行显示，不截断
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

extension SheetInfoRow where Value == Text {
    init(_ title: String, _ value: String) {
        self.title = title
        self.value = Text(value)
    }
}

/// 卡片里两行之间的分隔线（左边对齐文字）
struct SheetDivider: View {
    var inset: CGFloat = 14
    var body: some View { Divider().padding(.leading, inset) }
}

/// 一行开关：左边说明、右边开关（微信绿）。iPhone 用系统开关；Mac 上系统默认是复选框、文字挤在中间，这里排成和手机一样
struct SwitchRow<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder let label: Label

    var body: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            label
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Theme.wechatGreen)
        }
        #else
        Toggle(isOn: $isOn) { label }.tint(Theme.wechatGreen)
        #endif
    }
}
