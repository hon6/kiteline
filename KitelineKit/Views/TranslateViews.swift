import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 消息下面的「翻译」角标（Mac 在每条下面那行小字里，靠气泡右边；iPhone 设置里打开后在气泡下面）。
/// - 平时一个小「译」图标；鼠标移上去展开成「翻译」「设置」两个按钮（浮在上面，不挤动排版）
/// - 翻好以后变成「原文」+「设置」：点「原文」换回原来的语言，再点「译文」换回来
/// - 第一次点先弹设置（从什么语言翻成什么语言），之后每次点直接翻
struct TranslateBadge: View {
    let id: String
    let text: String
    @State private var translator = Translator.shared
    @State private var hovering = false
    @State private var setting = false

    var body: some View {
        let state = translator.state(id)
        HStack(spacing: 2) {
            switch state {
            case .working:
                chip(L("翻译中…"), symbol: nil, help: L("取消翻译")) { translator.cancel(id) }
                    .overlay(alignment: .leading) { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12).padding(.leading, 4) }
            case .done:
                if translator.isTranslated(id) {
                    chip(L("原文"), symbol: "arrow.uturn.backward", help: L("还原为原文")) { translator.restore(id) }
                } else {
                    chip(L("译文"), symbol: "translate", help: L("显示译文（%@）", Translator.Language.name(translator.target))) { translator.tap(id, text: text) }
                }
                gear
            case .failed(let message):
                chip(L("重试"), symbol: "exclamationmark.triangle", help: message, tint: Theme.removed) { translator.retranslate(id, text: text) }
                gear
            case nil:
                idle
            }
        }
        .font(.app(size: 11))
        .foregroundStyle(.secondary)
        .sheetPanel(isPresented: $setting) {
            TranslateSetupSheet(confirmTitle: L("重新翻译")) { translator.retranslate(id, text: text) }
        }
    }

    /// 没翻过：一个小图标；鼠标移上去在原地展开成「翻译 | 设置」（浮层，不改这一行的大小，免得悬停来回跳）
    @ViewBuilder private var idle: some View {
        #if os(macOS)
        Image(systemName: "translate")
            .frame(width: 16, height: 14)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                if hovering {
                    HStack(spacing: 0) {
                        chip(L("翻译"), symbol: "translate", help: translator.configured ? translator.summary : L("翻译这条消息")) { translator.tap(id, text: text) }
                        Divider().frame(height: 10)
                        gear
                    }
                    .padding(.horizontal, 2)
                    .background(Theme.chatBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    .fixedSize()
                    .transition(.opacity)
                }
            }
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
            .onTapGesture { translator.tap(id, text: text) }
            .help(L("翻译"))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L("翻译"))
        #else
        chip(L("翻译"), symbol: "translate", help: L("翻译这条消息")) { translator.tap(id, text: text) }
        #endif
    }

    private var gear: some View {
        Button { setting = true } label: {
            Image(systemName: "gearshape").frame(width: 18, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("翻译设置"))
        .accessibilityLabel(L("翻译设置"))
    }

    private func chip(_ title: String, symbol: String?, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol) } else { Color.clear.frame(width: 12, height: 1) }
                // 这一行窄时文字别被压成一条竖缝（11-13 截图里「原文」只剩一个竖点）
                Text(title).lineLimit(1).fixedSize()
            }
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 翻译设置：第一次点角标时弹出（确认后翻这一条），翻好后点「设置」也是它（改完重新翻）；设置页里是同样几项
struct TranslateSetupSheet: View {
    var confirmTitle = L("翻译")
    let confirm: () -> Void
    @PanelDismiss private var dismiss

    var body: some View {
        FitSheet(title: L("翻译设置"), cancel: true) {
            TranslateOptions()
        } bottom: {
            Button {
                Translator.shared.configured = true
                dismiss()
                confirm()
            } label: {
                Text(confirmTitle)
                    .font(.ui(.body).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Theme.wechatGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// 面板里的几项：原文语言、译成、翻译服务、消息下显示角标
private struct TranslateOptions: View {
    @State private var translator = Translator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetSection(footer: L("「自动检测」会按消息内容判断原文语言；与目标语言相同的内容保持不变。")) {
                pickerRow(L("原文语言"), selection: $translator.source, languages: [.auto] + Translator.Language.all)
                SheetDivider()
                pickerRow(L("翻译为"), selection: $translator.target, languages: Translator.Language.all)
            }
            // 所有翻译方式逐条列出（本机 / 联网、限制写清楚），用户直接选；系统翻译那条带语言包状态和「下载语言包」
            SheetSection(title: L("翻译服务"), footer: L("除系统翻译外，翻译时消息文字会发送到所选服务。")) {
                ForEach(Array(Translator.Engine.choices.enumerated()), id: \.element) { index, engine in
                    if index > 0 { SheetDivider() }
                    EngineRow(engine: engine, selected: translator.engine == engine) { translator.engine = engine }
                }
            }
            SheetSection(footer: L("开启自动翻译后，与目标语言不同的回复显示在屏幕上时自动翻译。关闭「翻译」按钮后仍可在消息的菜单中选择「翻译」。")) {
                SwitchRow(isOn: $translator.auto) { Text(L("自动翻译助手的回复")) }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                SheetDivider()
                SwitchRow(isOn: $translator.showBadge) { Text(L("在每条消息下显示「翻译」")) }
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }

    private func pickerRow(_ title: String, selection: Binding<String>, languages: [Translator.Language]) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Picker("", selection: selection) {
                ForEach(languages) { Text(verbatim: $0.name).tag($0.code) }
            }
            .labelsHidden().fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

/// 设置面板里的一种翻译方式：选中打勾、名字 + 本机 / 联网标签、说明；系统翻译另带语言包状态
private struct EngineRow: View {
    let engine: Translator.Engine
    let selected: Bool
    let pick: () -> Void
    @State private var translator = Translator.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Theme.wechatGreen : Color.secondary)
                .font(.ui(.body))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: engine.title)
                    if let tag = engine.tag {
                        Text(tag).font(.ui(.caption2)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule(style: .circular))
                    }
                }
                Text(engine.note).font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if engine == .apple { ApplePackStatus(source: translator.source, target: translator.target).font(.ui(.caption)) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 系统翻译的语言包：已就绪 / 未下载（「下载语言包」调系统的下载窗口）/ 不支持这组语言。
/// 原文是「自动检测」时按最常见的一组算：翻成中文就看「英语 → 目标」，翻成英语就看「简体中文 → 英语」
struct ApplePackStatus: View {
    let source: String
    let target: String

    var body: some View {
        #if canImport(Translation)
        if #available(iOS 18, macOS 15, *) { ApplePackStatusView(source: source, target: target) }
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18, macOS 15, *)
private struct ApplePackStatusView: View {
    let source: String
    let target: String
    @State private var status: LanguageAvailability.Status?
    @State private var config: TranslationSession.Configuration?
    @State private var failed: String?

    private var from: String { source != "auto" ? source : (target.hasPrefix("en") ? "zh-Hans" : "en") }

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .installed:
                Label(L("语言包已就绪（%@ → %@），可离线翻译", Translator.Language.name(from), Translator.Language.name(target)), systemImage: "checkmark.seal")
                    .foregroundStyle(Theme.wechatGreen)
            case .supported:
                Text(L("尚未下载「%@ → %@」语言包", Translator.Language.name(from), Translator.Language.name(target))).foregroundStyle(.secondary)
                Button(config == nil ? L("下载语言包") : L("下载中…")) {
                    failed = nil
                    if config == nil {
                        config = TranslationSession.Configuration(source: Locale.Language(identifier: from), target: Locale.Language(identifier: target))
                    } else {
                        config?.invalidate()
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.claude)
            case .unsupported:
                Text(L("系统翻译不支持「%@ → %@」", Translator.Language.name(from), Translator.Language.name(target))).foregroundStyle(.secondary)
            default:
                ProgressView().controlSize(.mini)
            }
            if let failed { Text(failed).foregroundStyle(Theme.removed) }
        }
        .task(id: from + "|" + target) { await refresh() }
        // 点「下载语言包」：系统弹出自己的下载确认窗口，下完回来刷新状态
        .translationTask(config) { session in
            do { try await session.prepareTranslation() } catch { failed = L("未能下载：%@", error.localizedDescription) }
            await refresh()
            config = nil
        }
    }

    private func refresh() async {
        status = await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: target))
    }
}
#endif

/// 设置页里的「翻译」一组（Mac：设置 → 通用；iPhone：设置 → 翻译）
public struct TarsTranslateSection: View {
    @State private var translator = Translator.shared
    public init() {}

    public var body: some View {
        Section {
            Picker(L("原文语言"), selection: $translator.source) {
                ForEach([Translator.Language.auto] + Translator.Language.all) { Text(verbatim: $0.name).tag($0.code) }
            }
            Picker(L("翻译为"), selection: $translator.target) {
                ForEach(Translator.Language.all) { Text(verbatim: $0.name).tag($0.code) }
            }
            Picker(L("翻译服务"), selection: $translator.engine) {
                ForEach(Translator.Engine.choices) { Text(verbatim: $0.title).tag($0) }
            }
            if Translator.Engine.appleAvailable {
                LabeledContent(L("系统翻译语言包")) { ApplePackStatus(source: translator.source, target: translator.target) }
            }
            Toggle(L("自动翻译助手的回复"), isOn: $translator.auto)
            Toggle(L("在每条消息下显示「翻译」"), isOn: $translator.showBadge)
        } header: {
            Text(L("翻译"))
        } footer: {
            Text(L("点消息下的「翻译」即可把这条消息翻译为所选语言，再点「原文」还原。")
                 + L("开启自动翻译后，与目标语言不同的回复显示在屏幕上时自动翻译。") + translator.engine.note
                 + (translator.engine == .apple ? "" : L("。翻译时消息文字会发送到该服务。")))
                .font(.app(size: 11)).foregroundStyle(.secondary)
        }
        .onChange(of: translator.source) { translator.configured = true }
        .onChange(of: translator.target) { translator.configured = true }
    }
}

#if os(iOS)
/// iPhone：设置 → 翻译
struct TranslateSettingsPage: View {
    var body: some View {
        List { TarsTranslateSection() }
            .navigationTitle(L("翻译"))
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

extension View {
    /// 挂在能翻译的消息气泡上：系统翻译要从视图上拿 TranslationSession；第一次点「翻译」弹的设置也从这里弹
    /// auto：开了「自动翻译」时这条出现在屏幕上就自动翻（只给助手的回复）
    func translateHost(_ id: String, text: String, auto: Bool = false) -> some View {
        modifier(TranslateHost(id: id, text: text, auto: auto))
    }
}

private struct TranslateHost: ViewModifier {
    let id: String
    let text: String
    let auto: Bool
    @State private var translator = Translator.shared

    func body(content: Content) -> some View {
        content
            .onAppear { if auto { translator.autoTranslate(id, text: text) } }
            .onChange(of: translator.auto) { _, on in if auto && on { translator.autoTranslate(id, text: text) } }
            .sheetPanel(isPresented: Binding(get: { translator.askingFor?.id == id },
                                             set: { if !$0, translator.askingFor?.id == id { translator.askingFor = nil } })) {
                TranslateSetupSheet { translator.confirmAsk() }
            }
    }

}

/// 系统翻译的常驻宿主：根视图上挂一个（看不见），所有消息的系统翻译排队交给它（见 Translator.performApple）。
/// 多个窗口各挂一个时只有第一个干活
public struct TranslateAppleHost: View {
    @State private var translator = Translator.shared
    @State private var me = UUID()
    public init() {}

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .modifier(AppleTask(active: translator.appleHosts.first == me))
            .onAppear { translator.hostAppeared(me) }
            .onDisappear { translator.hostGone(me) }
    }

    private struct AppleTask: ViewModifier {
        let active: Bool
        @State private var translator = Translator.shared
        func body(content: Content) -> some View {
            #if canImport(Translation)
            if #available(iOS 18, macOS 15, *) {
                content.translationTask(active ? translator.appleConfig as? TranslationSession.Configuration : nil) { session in
                    await translator.performApple(session: session)
                }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }
}

/// 消息菜单里的「翻译 / 显示原文」
extension Translator {
    func menuAction(id: String, text: String) -> MenuAction? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if isTranslated(id) {
            return MenuAction(title: L("显示原文"), symbol: "arrow.uturn.backward") { self.restore(id) }
        }
        return MenuAction(title: L("翻译"), symbol: "translate") { self.tap(id, text: text) }
    }
}

/// 一条消息 + 下面那行小字（时间、朗读、翻译）：小字那行和气泡一样宽，翻译角标靠气泡右边（我的消息靠左边）
struct BubbleFooterLayout: Layout {
    var spacing: CGFloat = 6
    var trailing = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        let top = subviews[0].sizeThatFits(proposal)
        let footIdeal = subviews[1].sizeThatFits(.unspecified)
        let width = min(max(top.width, footIdeal.width), proposal.width ?? .infinity)
        let foot = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: top.height + spacing + foot.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let width = ProposedViewSize(width: bounds.width, height: nil)
        let top = subviews[0].sizeThatFits(width)
        subviews[0].place(at: CGPoint(x: trailing ? bounds.maxX : bounds.minX, y: bounds.minY),
                          anchor: trailing ? .topTrailing : .topLeading, proposal: width)
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top.height + spacing), anchor: .topLeading, proposal: width)
    }
}
