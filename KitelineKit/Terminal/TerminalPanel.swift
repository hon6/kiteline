import SwiftUI
import SwiftTerm
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 输入框下面那排里的终端按钮：点开 / 收起会话里的终端面板；角标是开着几个终端（主题色，不用醒目的红）
struct TerminalChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chipHeight) private var height
    let session: SessionInfo
    let chat: ChatStore

    var body: some View {
        let count = model.terminals.count(session)
        let open = chat.terminalOpen
        Button {
            withAnimation(.snappy(duration: 0.25)) { chat.terminalOpen.toggle() }
        } label: {
            Image(systemName: "apple.terminal")
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(open ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(.primary.opacity(0.75)))
                .frame(width: height + 12, height: height)
                .background(open ? Theme.claude.opacity(0.12) : Theme.field, in: Capsule(style: .circular))
                .overlay { if open { Capsule(style: .circular).hairlineBorder(Theme.claude.opacity(0.45)) } }
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Theme.claude, in: Capsule(style: .circular))
                            .offset(x: 5, y: -Bar.badgeRoom + 1)
                    }
                }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(count > 0 ? L("终端（%@ 个）", "\(count)") : L("打开终端"))
    }
}

/// 会话里的终端面板：在输入区的位置从底下升起来（收起后输入框回来），上面是标签（几个终端）、新建、收起，下面是终端本身。
/// 终端开在会话所在的电脑上，收起面板、离开对话页都不会结束它，点标签上的 × 才关
struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale
    let key: String
    let session: SessionInfo
    let chat: ChatStore
    /// 对话页的高度：面板最高占到它的八成五
    let available: CGFloat
    @AppStorage("terminalHeight") private var stored: Double = 300
    @AppStorage("terminalFontSize") private var fontSize: Double = 12
    @State private var dragStart: Double?
    /// 终端那一块的大小（新开终端时按它算行列数）
    @State private var area: CGSize = .zero

    var body: some View {
        let store = model.terminals
        let terms = store.lists[key] ?? []
        let current = store.selected[key].flatMap { id in terms.first { $0.id == id } }
        let height = clamped(stored)
        VStack(spacing: 0) {
            grip
            header(terms, current)
            ZStack {
                TerminalColors.background(scheme)
                if let current {
                    TermScreen(key: key, id: current.id, fontSize: fontSize, dark: scheme == .dark)
                        .id("\(current.id)-\(scheme == .dark)")
                        .padding(.leading, 6)
                } else if store.opening.contains(key) || store.lists[key] == nil {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 10) {
                        Text("没有开着的终端").font(.ui(.subheadline)).foregroundStyle(.secondary)
                        Button { Task { await openNew() } } label: {
                            Label("新建终端", systemImage: "plus").font(.ui(.subheadline))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(height: height)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { area = $0 }
        }
        .background(Theme.inputBar)
        .task(id: key) {
            await store.refresh(key)
            if store.lists[key]?.isEmpty == true { await openNew() }
        }
    }

    /// 新开一个终端，一开始就按面板的大小（同 SwiftTerm 的算法）：先按 80 列开再缩小的话，zsh 会在第一行留下一个「%」
    private func openNew() async {
        for _ in 0..<20 where area.width < 1 { try? await Task.sleep(for: .milliseconds(50)) }
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let scroller: CGFloat = 0
        #else
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let scroller: CGFloat = 16   // Mac 上右边留给滚动条
        #endif
        let ct = font as CTFont
        let line = ceil((CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) * scale) / scale
        let cell = (("W" as NSString).size(withAttributes: [.font: font]).width * scale).rounded() / scale
        let cols = Int((area.width - 6 - scroller) / max(cell, 1)), rows = Int(area.height / max(line, 1))
        await model.terminals.open(key, cols: area.width < 1 ? 80 : max(cols, 20), rows: area.width < 1 ? 24 : max(rows, 5))
    }

    private func clamped(_ value: Double) -> CGFloat {
        let top = max(160, available * 0.85 - 60)
        return min(max(CGFloat(value), 120), top)
    }

    /// 上沿的小横条：上下拖改面板高度
    private var grip: some View {
        Capsule(style: .circular)
            .fill(SwiftUI.Color.primary.opacity(0.22))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity, minHeight: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? Double(clamped(stored))
                        dragStart = start
                        stored = Double(clamped(start - drag.translation.height))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            #if os(macOS)
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            #endif
            .accessibilityLabel(L("拖动调整终端高度"))
    }

    private func header(_ terms: [TermInfo], _ current: TermInfo?) -> some View {
        let store = model.terminals
        return HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(terms.enumerated()), id: \.element.id) { index, term in
                        tab(term, title: tabTitle(terms, index), selected: term.id == current?.id)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
            Button { Task { await openNew() } } label: {
                Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.opening.contains(key))
            .accessibilityLabel(L("新建终端"))
            Menu {
                Button { fontSize = min(fontSize + 1, 20) } label: { Label("放大字号", systemImage: "textformat.size.larger") }
                Button { fontSize = max(fontSize - 1, 9) } label: { Label("缩小字号", systemImage: "textformat.size.smaller") }
                if let current {
                    Divider()
                    Button(role: .destructive) { Task { await store.close(key, current.id) } } label: {
                        Label("关闭当前终端", systemImage: "xmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            #if os(macOS)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
            .accessibilityLabel(L("更多"))
            Button {
                withAnimation(.snappy(duration: 0.25)) { chat.terminalOpen = false }
            } label: {
                Image(systemName: "chevron.down").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("收起终端"))
        }
        .font(.app(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.trailing, 8)
        .padding(.bottom, 6)
    }

    /// 同一种 shell 开了几个：zsh、zsh 2、zsh 3（同 VS Code）
    private func tabTitle(_ terms: [TermInfo], _ index: Int) -> String {
        let name = terms[index].name
        let same = terms[..<index].filter { $0.name == name }.count
        return same == 0 ? name : "\(name) \(same + 1)"
    }

    private func tab(_ term: TermInfo, title: String, selected: Bool) -> some View {
        let store = model.terminals
        return HStack(spacing: 5) {
            Image(systemName: "apple.terminal").font(.app(size: 10, weight: .semibold))
            Text(title).font(.ui(.caption)).lineLimit(1)
            if selected {
                Button { Task { await store.close(key, term.id) } } label: {
                    Image(systemName: "xmark").font(.app(size: 9, weight: .bold)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("关闭终端"))
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(.primary.opacity(0.7)))
        .padding(.leading, 9).padding(.trailing, selected ? 4 : 9)
        .frame(height: 24)
        .background(selected ? Theme.claude.opacity(0.12) : Theme.field, in: Capsule(style: .circular))
        .overlay { if selected { Capsule(style: .circular).hairlineBorder(Theme.claude.opacity(0.45)) } }
        .contentShape(Capsule(style: .circular))
        .onTapGesture { store.selected[key] = term.id }
        .contextMenu {
            Button(role: .destructive) { Task { await store.close(key, term.id) } } label: { Label("关闭终端", systemImage: "xmark") }
        }
    }
}

/// 终端的配色：同 VS Code 默认主题（Dark Modern / Light Modern）的终端
enum TerminalColors {
    static func background(_ scheme: ColorScheme) -> SwiftUI.Color {
        scheme == .dark ? SwiftUI.Color(hex: 0x181818) : SwiftUI.Color(hex: 0xFFFFFF)
    }

    static func palette(dark: Bool) -> [SwiftTerm.Color] {
        let hex: [UInt32] = dark
            ? [0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
               0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5]
            : [0x000000, 0xCD3131, 0x00BC00, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555,
               0x666666, 0xCD3131, 0x14CE14, 0xB5BA00, 0x0451A5, 0xBC05BC, 0x0598BC, 0xA5A5A5]
        return hex.map { SwiftTerm.Color(red8: UInt16($0 >> 16 & 0xFF), green8: UInt16($0 >> 8 & 0xFF), blue8: UInt16($0 & 0xFF)) }
    }

    #if canImport(UIKit)
    static func native(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    #else
    static func native(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    #endif

    static func style(_ view: TerminalView, dark: Bool) {
        view.installColors(palette(dark: dark))
        view.nativeBackgroundColor = native(dark ? 0x181818 : 0xFFFFFF)
        view.nativeForegroundColor = native(dark ? 0xCCCCCC : 0x3B3B3B)
        view.caretColor = native(dark ? 0xAEAFAD : 0x000000)
        #if canImport(UIKit)
        view.keyboardAppearance = dark ? .dark : .light
        #endif
    }
}

/// SwiftTerm 的终端视图：按键交给 TerminalStore 发到电脑，电脑上的输出经 TerminalStore 喂回来
#if canImport(UIKit)
struct TermScreen: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let key: String
    let id: String
    let fontSize: Double
    let dark: Bool

    func makeCoordinator() -> TermLink { TermLink(store: model.terminals, key: key, id: id) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        TerminalColors.style(view, dark: dark)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize { view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: TermLink) { coordinator.detach() }
}
#else
struct TermScreen: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let key: String
    let id: String
    let fontSize: Double
    let dark: Bool

    func makeCoordinator() -> TermLink { TermLink(store: model.terminals, key: key, id: id) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        TerminalColors.style(view, dark: dark)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize { view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: TermLink) { coordinator.detach() }
}
#endif

/// 一个终端视图和 TerminalStore 之间的连线
final class TermLink: NSObject, TerminalViewDelegate, TermSink {
    let store: TerminalStore
    let key: String
    let id: String
    weak var view: TerminalView?

    init(store: TerminalStore, key: String, id: String) {
        self.store = store
        self.key = key
        self.id = id
    }

    @MainActor func attach(_ view: TerminalView) {
        self.view = view
        view.terminalDelegate = self
        store.attach(key, id, sink: self)
    }

    @MainActor func detach() { store.detach(id, sink: self) }

    // MARK: TermSink

    func feed(_ bytes: ArraySlice<UInt8>) { view?.feed(byteArray: bytes) }

    /// 清屏重来：ESC c（终端的完全复位）
    func restart() { view?.feed(byteArray: [0x1B, 0x63][...]) }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated { store.send(key, id, bytes) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        MainActor.assumeIsolated { store.resize(key, id, cols: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// 终端里的网址：只开 http(s)
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// 程序要求复制（OSC 52，比如 vim 里 "+y）
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
