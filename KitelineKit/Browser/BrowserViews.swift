import SwiftUI

// 会话浏览器的界面（iPhone / iPad / Mac 共用，Mac 经 MacEmbed 编进来）：
// - 小窗（BrowserMini）：agent 一用浏览器，对话页右上角浮出缩略画面，下面一行是它刚发的指令；点一下放大
// - 放大（BrowserViewer）：半个会话 / 整个会话（盖在对话页上，BrowserDock 管）、整个应用 / 全屏（盖在整个窗口上，BrowserAppLayer 管）；
//   左边（窄屏是上面）是实时画面，右边（窄屏是下面）是 agent 的指令列表；可以接管：点、拖、打字、按键、地址栏、切标签页
// 画面只在这些视图显示时向电脑要（BrowserStore.watch），小窗要缩略档、放大要大画面档

/// 对话页上的浮层：小窗、半个会话、整个会话。「整个应用 / 全屏」时这里不画（画在 BrowserAppLayer）
struct BrowserDock: View {
    @Environment(AppModel.self) private var model
    let key: String
    let info: BrowserInfo?
    var available: CGFloat

    var body: some View {
        let store = model.browsers
        if let info, store.visible(key, info) {
            GeometryReader { geo in
                let half = max(260, available * 0.5)
                switch store.size(key) {
                case .mini:
                    BrowserMini(key: key, info: info, area: geo.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                case .half:
                    BrowserViewer(key: key, info: info, size: .half)
                        .frame(height: half)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(growFromMini(area: geo.size, height: half))
                case .session:
                    BrowserViewer(key: key, info: info, size: .session)
                        .transition(growFromMini(area: geo.size, height: geo.size.height))
                case .app, .fullscreen:
                    EmptyView()
                }
            }
        }
    }

    /// 放大 / 缩回的动画从小窗所在的位置长出来、缩回去（11-16 反馈：不要从上面滑下来，要从小窗放大）。
    /// 锚点 = 小窗中心在对话页里的位置（默认贴右上，拖过的按拖到的位置算）
    /// height：放大后的视图有多高（半个会话只占上半截，锚点按它自己的高度算）
    private func growFromMini(area: CGSize, height viewHeight: CGFloat) -> AnyTransition {
        guard area.width > 0, viewHeight > 0 else { return .opacity }
        #if os(macOS)
        let width: CGFloat = 250
        #else
        let width: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 240 : 172
        #endif
        let height = width * 0.62 + 40
        let offset = model.browsers.miniOffset
        let center = CGPoint(x: area.width - 10 - width / 2 + offset.width, y: 56 + height / 2 + offset.height)
        let anchor = UnitPoint(x: center.x / area.width, y: center.y / viewHeight)
        return .scale(scale: width / area.width, anchor: anchor).combined(with: .opacity)
    }
}

/// 盖在整个窗口上的（整个应用 / 全屏）：挂在主界面根上
struct BrowserAppLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.browsers
        if let key = store.focus, let info = model.session(key)?.browser, store.visible(key, info) {
            BrowserViewer(key: key, info: info, size: store.size(key))
                // 不铺进安全区：iPhone 上顶栏会跑到状态栏底下，缩回 / 退出全屏的按钮点不到（11-16 反馈：全屏后无法退出）
                .background(Theme.chatBackground.ignoresSafeArea())
                #if os(iOS)
                .statusBarHidden(store.size(key) == .fullscreen)
                .persistentSystemOverlays(store.size(key) == .fullscreen ? .hidden : .automatic)
                #endif
                .transition(.opacity)
                #if os(macOS)
                .onChange(of: store.size(key), initial: true) { _, size in MacFullScreen.set(size == .fullscreen) }
                .onDisappear { MacFullScreen.set(false) }
                #endif
        }
    }
}

#if os(macOS)
import AppKit
/// 全屏：Mac 上把主窗口切成系统全屏（退出时切回来；本来就是全屏的不动）
enum MacFullScreen {
    @MainActor private static var entered = false

    @MainActor static func set(_ on: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if on, !isFull {
            entered = true
            window.toggleFullScreen(nil)
        } else if !on, isFull, entered {
            entered = false
            window.toggleFullScreen(nil)
        }
    }
}
#endif

// MARK: - 小窗

struct BrowserMini: View {
    @Environment(AppModel.self) private var model
    let key: String
    let info: BrowserInfo
    /// 对话页的大小：拖动时不许拖出去
    var area: CGSize = .zero
    @State private var token = UUID()
    /// 正在拖的这一下挪了多少（松手后并进 BrowserStore.miniOffset，记住位置）
    @State private var drag: CGSize = .zero
    @State private var height: CGFloat = 160

    var width: CGFloat {
        #if os(macOS)
        250
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? 240 : 172
        #endif
    }

    private var isCollapsed: Bool { !info.closed && model.browsers.collapsed(key, info) }
    /// 现在占多宽（收起时是小圆钮）
    var boxWidth: CGFloat { isCollapsed ? 40 : width }

    var body: some View {
        let store = model.browsers
        let collapsed = isCollapsed
        Group {
            if info.closed { replayCard } else if collapsed { pill } else { card }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) { if collapsed { store.expand(key) } else { store.setSize(key, .half) } }   // 浏览器关了：放大后直接放录像
        }
        .contextMenu {
            if collapsed { Button { withAnimation(.snappy) { store.expand(key) } } label: { Label("展开小窗", systemImage: "pip") } }
            ForEach(BrowserSize.allCases.filter { $0 != .mini }) { size in
                Button { withAnimation(.snappy) { store.expand(key); store.setSize(key, size) } } label: { Label(size.label, systemImage: size.icon) }
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .padding(.top, 56).padding(.trailing, 10)
        // 小窗能拖到对话页里任何地方（别挡住要看的内容），位置记住，各会话共用；收起后的小圆钮也一样
        .offset(clamped(CGSize(width: store.miniOffset.width + drag.width, height: store.miniOffset.height + drag.height)))
        .highPriorityGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    let moved = CGSize(width: store.miniOffset.width + value.translation.width,
                                       height: store.miniOffset.height + value.translation.height)
                    store.miniOffset = clamped(moved)
                    drag = .zero
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(collapsed ? L("展开浏览器小窗") : L("浏览器实时画面：%@", info.title.isEmpty ? info.shortURL : info.title))
        .accessibilityAddTraits(.isButton)
        // 收起时、浏览器关了不要画面（省流量）；展开再要
        .task(id: collapsed || info.closed) {
            if collapsed || info.closed { store.unwatch(key, token: token) } else { store.watch(key, token: token, level: "thumb") }
        }
        .onDisappear { store.unwatch(key, token: token) }
        .animation(.snappy, value: collapsed)
    }

    /// 浏览器关了、留着录像：「回放」卡片（轻点看回放，× 不再显示）
    private var replayCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill").font(.app(size: 18)).foregroundStyle(Theme.claude)
            VStack(alignment: .leading, spacing: 1) {
                Text("回放浏览器操作").font(.ui(.caption).weight(.semibold))
                Text(info.title.isEmpty ? info.shortURL : info.title).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { Task { await model.browsers.forget(key) } } label: {
                Image(systemName: "xmark").font(.app(size: 9, weight: .bold)).frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain).accessibilityLabel(L("不再显示"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: width)
        .background { BrowserGlass(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)) }
    }

    /// 收起后的小圆钮：地球 + 红点（浏览器还在运行），轻点恢复小窗
    private var pill: some View {
        Image(systemName: "globe")
            .font(.app(size: 17, weight: .medium))
            .frame(width: 40, height: 40)
            .background { BrowserGlass(shape: Circle()) }
            .overlay(alignment: .topTrailing) { Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: -3, y: 3) }
            .help(L("展开浏览器小窗"))
    }

    private var card: some View {
        let store = model.browsers
        return VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.06))
                if let frame = store.frames[key] {
                    Image(platform: frame.image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: width, height: width * 0.62)
            .clipped()
            .overlay(alignment: .topLeading) { LiveBadge().padding(6) }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title.isEmpty ? info.shortURL : info.title)
                    .font(.ui(.caption2).weight(.semibold)).lineLimit(1)
                Text(info.last.isEmpty ? info.shortURL : info.last)
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            if let ask = info.ask {
                Label(ask, systemImage: "hand.raised.fill")
                    .font(.ui(.caption2).weight(.semibold)).lineLimit(2)
                    .foregroundStyle(Theme.claude)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.bottom, 6)
            }
        }
        .frame(width: width)
        .background { BrowserGlass(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button { withAnimation(.snappy) { store.dismiss(key, info) } } label: {
                Image(systemName: "xmark").font(.app(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain).padding(5)
            .help(L("收起成小图标（浏览器照常运行）"))
            .accessibilityLabel(L("收起浏览器小窗"))
        }
    }
}

extension BrowserMini {
    /// 拖动范围：小窗默认贴右上（距顶 56、距右 10），往左最多拖到距左边 8，往下最多拖到距底边 8
    func clamped(_ offset: CGSize) -> CGSize {
        guard area.width > 0, area.height > 0 else { return offset }
        let minX = -(area.width - boxWidth - 18)
        let maxY = area.height - height - 56 - 8
        return CGSize(width: min(0, max(minX, offset.width)), height: min(max(0, maxY), max(-48, offset.height)))
    }
}

/// 左上角「实时」小标记
private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 6, height: 6)   // 静态红点：小窗常驻，别放循环动画（多列分屏时吃 CPU）
            Text("实时").font(.app(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.5)))
        .foregroundStyle(.white)
    }
}

/// 系统 26 起是液态玻璃，更早的是磨砂 + 细边（Mac 不编 Glass.swift，和执行过程按钮同一写法）
struct BrowserGlass<S: Shape>: View {
    let shape: S
    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial).overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.8))
        }
    }
}

// MARK: - 放大

struct BrowserViewer: View {
    @Environment(AppModel.self) private var model
    let key: String
    let info: BrowserInfo
    let size: BrowserSize
    @State private var token = UUID()
    @State private var typing = ""
    @State private var editingURL = false
    @State private var url = ""
    @State private var handBackNote = ""
    @State private var confirmClose = false
    @State private var replay: BrowserReplay?
    @FocusState private var typingFocused: Bool

    var body: some View {
        let store = model.browsers
        GeometryReader { geo in
            let wide = geo.size.width >= 720
            VStack(spacing: 0) {
                header(wide: geo.size.width >= 520)
                Divider().opacity(0.5)
                if info.closed || replay?.active == true {
                    EmptyView()   // 看录像时没有接管（录像点不了）
                } else if let ask = info.ask, !store.isControlling(key) { askBanner(ask) }
                else if !store.isControlling(key) { takeOverBar }
                if store.isControlling(key), !info.closed, replay?.active != true { controlBar }
                if wide {
                    HStack(spacing: 0) {
                        screen
                        Divider().opacity(0.5)
                        BrowserActionList(key: key, replay: replay, closed: info.closed).frame(width: min(340, geo.size.width * 0.3))
                    }
                } else {
                    screen
                    Divider().opacity(0.5)
                    BrowserActionList(key: key, replay: replay, closed: info.closed).frame(height: min(240, geo.size.height * 0.36))
                }
            }
        }
        .background(Theme.chatBackground)
        .clipShape(RoundedRectangle(cornerRadius: size == .half ? 14 : 0, style: .continuous))
        .overlay {
            if size == .half {
                RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
            }
        }
        .padding(size == .half ? 8 : 0)
        .shadow(color: .black.opacity(size == .half ? 0.12 : 0), radius: 12, y: 4)
        .task(id: size) { if !info.closed { store.watch(key, token: token, level: "full") } }
        .task {
            if replay == nil { replay = BrowserReplay(key: key, store: store) }
            replay?.startIfClosed(info.closed)   // 浏览器关了：放大后直接放录像
        }
        .onDisappear { store.unwatch(key, token: token) }
        .task(id: info.last) { await store.refreshActions(key) }
    }

    // 顶栏：标签页 / 地址、大小档位、收起
    private func header(wide: Bool) -> some View {
        let store = model.browsers
        return HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.secondary)
            if editingURL {
                TextField(L("输入网址"), text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(.footnote))
                    .onSubmit {
                        store.input(key, ["type": "nav", "action": "goto", "url": url])
                        editingURL = false
                    }
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
            } else {
                Menu {
                    ForEach(store.tabs[key] ?? []) { tab in
                        Button {
                            Task { await store.selectTab(key, tab.id) }
                        } label: {
                            Label(tab.title.isEmpty ? tab.url : tab.title, systemImage: tab.current ? "checkmark" : "square.on.square")
                        }
                    }
                    if store.isControlling(key) {
                        Divider()
                        Button { url = info.url; editingURL = true } label: { Label("输入网址", systemImage: "link") }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.title.isEmpty ? L("浏览器") : info.title).font(.ui(.subheadline).weight(.semibold)).lineLimit(1)
                        Text(info.shortURL).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.button).buttonStyle(.plain)
            }
            if store.isControlling(key) {
                navButton("chevron.left", L("后退")) { store.input(key, ["type": "nav", "action": "back"]) }
                navButton("chevron.right", L("前进")) { store.input(key, ["type": "nav", "action": "forward"]) }
                navButton("arrow.clockwise", L("刷新")) { store.input(key, ["type": "nav", "action": "reload"]) }
            }
            sizePicker(wide: wide)
            // 退出全屏：一直在顶栏上（全屏时系统的标题栏、状态栏都没了，只能靠它）
            if size == .fullscreen || size == .app {
                Button { withAnimation(.snappy) { store.setSize(key, .session) } } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help(size == .fullscreen ? L("退出全屏") : L("回到会话里"))
                .accessibilityLabel(size == .fullscreen ? L("退出全屏") : L("回到会话里"))
            }
            Button { withAnimation(.snappy) { store.setSize(key, .mini) } } label: {
                Image(systemName: "pip.enter").frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(L("缩回小窗"))
            .accessibilityLabel(L("缩回小窗"))
            // 真正结束浏览器（小窗上的 × 只是收起）：agent 再用浏览器时会重新打开
            Button { confirmClose = true } label: {
                Image(systemName: "stop.circle").frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(L("关闭浏览器"))
            .accessibilityLabel(L("关闭浏览器"))
            .confirmationDialog(L("关闭这个会话的浏览器？"), isPresented: $confirmClose) {
                Button("关闭浏览器", role: .destructive) { Task { await store.closeBrowser(key) } }
            } message: {
                Text("Agent 正在进行的网页操作会中断，它再次使用浏览器时会重新打开（登录状态保留）。")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func navButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 28, height: 28) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    /// 四档大小：宽的时候一排图标，窄的时候收进菜单
    @ViewBuilder
    private func sizePicker(wide: Bool) -> some View {
        let store = model.browsers
        let sizes: [BrowserSize] = [.half, .session, .app, .fullscreen]
        if wide {
            HStack(spacing: 2) {
                ForEach(sizes) { option in
                    Button { withAnimation(.snappy) { store.setSize(key, option) } } label: {
                        Image(systemName: option.icon).font(.app(size: 13))
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(option == size ? Theme.claude.opacity(0.12) : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(option == size ? Theme.claude.opacity(0.35) : .clear, lineWidth: 0.8))
                            .foregroundStyle(option == size ? Theme.claude : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(option.label)
                    .accessibilityLabel(option.label)
                }
            }
        } else {
            Menu {
                ForEach(sizes) { option in
                    Button { withAnimation(.snappy) { store.setSize(key, option) } } label: {
                        Label(option.label, systemImage: option == size ? "checkmark" : option.icon)
                    }
                }
            } label: {
                Image(systemName: size.icon).frame(width: 30, height: 30)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .accessibilityLabel(L("画面大小"))
        }
    }

    // 画面：接管时点、拖、滚动都送进网页
    private var screen: some View {
        let store = model.browsers
        return GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.04)
                if let replay, replay.active || info.closed {
                    // 看录像：上面换成录到的画面；角上「回到实时」
                    if let image = replay.image {
                        Image(platform: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                    VStack {
                        HStack(spacing: 6) {
                            Label(replay.playing ? L("回放中") : L("回放已暂停"), systemImage: "play.rectangle.fill")
                                .font(.ui(.caption2).weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(.black.opacity(0.55))).foregroundStyle(.white)
                            Spacer()
                            if !info.closed {
                                Button { replay.goLive() } label: {
                                    Label("回到实时", systemImage: "dot.radiowaves.left.and.right").font(.ui(.caption2).weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(Theme.claude)).foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                        Spacer()
                    }
                } else if let frame = store.frames[key] {
                    let fit = Self.fitted(frame.image.size, in: geo.size)
                    Image(platform: frame.image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: fit.width, height: fit.height)
                        .overlay {
                            if store.isControlling(key) {
                                BrowserTouchLayer(key: key, size: fit.size)
                            }
                        }
                        .overlay {
                            if store.isControlling(key) {
                                Rectangle().stroke(Theme.claude.opacity(0.6), lineWidth: 2)
                            }
                        }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在连接浏览器画面…").font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    static func fitted(_ image: CGSize, in box: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / image.width, box.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(origin: CGPoint(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2), size: size)
    }

    // 没在接管：一条说明 + 「接管」（接管后点画面就是点网页、可以打字）
    private var takeOverBar: some View {
        HStack(spacing: 10) {
            Text("实时画面 · 点「接管」后可以直接在画面上点击、拖动、输入")
                .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 8)
            Button {
                Task { await model.browsers.takeOver(key) }
            } label: {
                Label("接管", systemImage: "hand.tap").font(.ui(.footnote).weight(.semibold))
            }
            .buttonStyle(.bordered).controlSize(.small).tint(Theme.claude)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // agent 请你接管
    private func askBanner(_ ask: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.claude)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent 请你接管浏览器").font(.ui(.footnote).weight(.semibold))
                Text(ask).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 8)
            Button("开始接管") { Task { await model.browsers.takeOver(key) } }
                .buttonStyle(.borderedProminent).tint(Theme.claude).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.claude.opacity(0.06))
    }

    // 接管中：打字、常用键、交还
    private var controlBar: some View {
        let store = model.browsers
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField(L("输入文字，回车发送到网页"), text: $typing)
                    .textFieldStyle(.roundedBorder).font(.ui(.footnote))
                    .focused($typingFocused)
                    .onSubmit {
                        if !typing.isEmpty { store.input(key, ["type": "text", "text": typing]) }
                        store.input(key, ["type": "key", "key": "Enter"])
                        typing = ""
                        typingFocused = true
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                Button(L("输入")) {
                    if !typing.isEmpty { store.input(key, ["type": "text", "text": typing]); typing = "" }
                }
                .controlSize(.small)
                keyButton("delete.left", "Backspace", L("退格"))
                keyButton("arrow.right.to.line", "Tab", "Tab")
                keyButton("return", "Enter", L("回车"))
                keyButton("chevron.up", "PageUp", L("向上翻页"))
                keyButton("chevron.down", "PageDown", L("向下翻页"))
            }
            HStack(spacing: 8) {
                Label("你正在操作浏览器，Agent 的指令仍会执行", systemImage: "hand.tap")
                    .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if model.session(key)?.browser?.ask != nil {
                    TextField(L("给 Agent 留言（可不填）"), text: $handBackNote)
                        .textFieldStyle(.roundedBorder).font(.ui(.caption)).frame(maxWidth: 220)
                }
                Button("交还给 Agent") {
                    let note = handBackNote
                    handBackNote = ""
                    Task { await store.handBack(key, note: note) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.claude).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.claude.opacity(0.06))
    }

    private func keyButton(_ icon: String, _ name: String, _ label: String) -> some View {
        Button { model.browsers.input(key, ["type": "key", "key": name]) } label: {
            Image(systemName: icon).frame(width: 26, height: 24)
        }
        .buttonStyle(.bordered).controlSize(.small).help(label).accessibilityLabel(label)
    }
}

/// 接管时盖在画面上：点 = 点击；拖 = 按下 → 移动 → 松开（滑块、拖拽）；位置按画面比例换算成网页坐标
private struct BrowserTouchLayer: View {
    @Environment(AppModel.self) private var model
    let key: String
    let size: CGSize
    @State private var dragging = false
    @State private var lastMove = Date.distantPast

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let moved = hypot(value.translation.width, value.translation.height) > 6
                        if !dragging, moved {
                            dragging = true
                            send("down", value.startLocation)
                        }
                        // 移动最多每秒 30 次（拖滑块够顺，又不把连接灌满）
                        if dragging, Date().timeIntervalSince(lastMove) > 0.033 {
                            lastMove = Date()
                            send("move", value.location, pressed: true)
                        }
                    }
                    .onEnded { value in
                        if dragging {
                            send("up", value.location)
                            dragging = false
                        } else {
                            send("click", value.location)
                        }
                    }
            )
    }

    private func send(_ type: String, _ point: CGPoint, pressed: Bool = false) {
        guard size.width > 0, size.height > 0 else { return }
        var body: [String: Any] = ["type": type, "x": point.x / size.width, "y": point.y / size.height]
        if pressed { body["pressed"] = true }
        model.browsers.input(key, body)
    }
}

/// agent 的浏览器指令（新的在下面，自动滚到最新）
struct BrowserActionList: View {
    @Environment(AppModel.self) private var model
    let key: String
    var replay: BrowserReplay? = nil
    var closed = false

    /// 回放时高亮那一刻之前最近的一条；实时时高亮最新的
    private func highlighted(_ rows: [BrowserAction]) -> Int? {
        guard let moment = replay?.moment else { return rows.last?.id }
        return rows.last { ($0.time ?? 0) > 0 && ($0.time ?? 0) <= moment }?.id
    }

    var body: some View {
        let rows = model.browsers.actions[key] ?? []
        let mark = highlighted(rows)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agent 的操作").font(.ui(.footnote).weight(.semibold))
                Spacer()
                Text("\(rows.count)").font(.ui(.caption2)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 8)
            // 回放控制就在这里（不弹窗）：播放、进度条、倍速、跳过等待
            if let replay { BrowserReplayBar(replay: replay, closed: closed) }
            Divider().opacity(0.4)
            if rows.isEmpty {
                Text("还没有操作记录").font(.ui(.caption)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                BrowserActionRow(action: row, latest: row.id == mark).id(row.id)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: rows.count, initial: true) { _, _ in
                        if let last = rows.last, replay?.active != true { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onChange(of: mark) { _, id in
                        if let id, replay?.active == true { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
    }
}

private struct BrowserActionRow: View {
    let action: BrowserAction
    let latest: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            Text(action.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(latest ? Color.primary : Color.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(latest ? Theme.claude.opacity(0.07) : .clear)
    }

    private var time: String {
        guard let t = action.time else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: t))
    }
}

#if KITELINE_MAC
extension KitelineKit {
    /// Mac 主窗口根上挂这个：会话浏览器放到「整个应用 / 全屏」时盖满窗口
    public struct BrowserAppView: View {
        public init() {}
        public var body: some View {
            if let model = KitelineKit.model {
                BrowserAppLayer().environment(model)
            }
        }
    }
}
#endif
