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
                #if os(macOS)
                .foregroundStyle(open ? Color.white : Color.primary)
                .frame(width: 14)
                .kiteLook(prominent: open)   // 开着 = 主题色亮起，同统一按钮样式
                #else
                .foregroundStyle(open ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(.primary.opacity(0.75)))
                .frame(width: height + 12, height: height)
                .background(open ? Theme.claude.opacity(0.12) : Theme.field, in: Capsule(style: .circular))
                .overlay { if open { Capsule(style: .circular).hairlineBorder(Theme.claude.opacity(0.45)) } }
                #endif
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
    /// 终端列表（同 VS Code）：右边一列，开着两个以上终端才显示；中间的分隔条拖动改宽度（记住）、双击恢复默认；
    /// 拖窄到放不下文字只剩图标。面板宽度用来限制列表最多占一半
    @State private var width: CGFloat = 0
    @AppStorage("terminalListWidth") private var storedList: Double = TerminalPanel.defaultList
    @State private var listDragStart: Double?
    static let defaultList: Double = 176
    static let minList: Double = 44
    private var listWidth: CGFloat { CGFloat(min(max(storedList, Self.minList), max(Self.minList, Double(width) * 0.5))) }
    /// 窄到只放得下图标
    private var listCompact: Bool { listWidth < 96 }
    /// 重命名框
    @State private var renaming: TermInfo?
    @State private var renameText = ""
    /// 手机上打开终端时的手势引导（轻点 / 滑动 / 长按）；点「不再显示」后不再出现
    @AppStorage("terminalGestureGuideOff") private var guideOff = false
    @State private var guideShown = false

    var body: some View {
        let store = model.terminals
        let terms = store.lists[key] ?? []
        let current = store.selected[key].flatMap { id in terms.first { $0.id == id } }
        let height = clamped(stored)
        VStack(spacing: 0) {
            grip
            header(terms, current)
            if let current { place(current) }
            HStack(spacing: 0) {
            ZStack {
                TerminalColors.background(scheme)
                if let current {
                    panes(terms, current)
                } else if store.opening.contains(key) || store.lists[key] == nil {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 10) {
                        Text("没有开着的终端").font(.ui(.subheadline)).foregroundStyle(.secondary)
                        Button { Task { await openNew() } } label: {
                            if let device = store.devices[key] {
                                Label("在「\(device)」上新建终端", systemImage: "plus").font(.ui(.subheadline))
                            } else {
                                Label("新建终端", systemImage: "plus").font(.ui(.subheadline))
                            }
                        }
                        .kiteButton()
                    }
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { area = $0 }
            .overlay { if guideShown { gestureGuide } }
            if terms.count > 1 {
                sash
                titleList(terms, current)
            }
            }
            .frame(height: height)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Theme.inputBar)
        .task(id: key) {
            #if canImport(UIKit)
            // 只出现一次：一出现就记下看过了（没点掉直接离开，下次也不再出）
            if !guideOff { guideOff = true; withAnimation(.easeOut(duration: 0.2)) { guideShown = true } }
            #endif
            await store.refresh(key)
            if store.lists[key]?.isEmpty == true { await openNew() }
        }
        .alert("重命名终端", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $renameText)
            Button("确定") {
                if let term = renaming { Task { await store.rename(key, term.id, renameText) } }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text("留空则恢复默认名称")
        }
    }

    /// 终端区：正在看的那个，和与它拆分在一起的并排（同 VS Code 的拆分）；点哪个就切到哪个
    @ViewBuilder
    private func panes(_ terms: [TermInfo], _ current: TermInfo) -> some View {
        let members = current.group.map { group in terms.filter { $0.group == group } } ?? [current]
        HStack(spacing: 0) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, term in
                if index > 0 { Rectangle().fill(SwiftUI.Color.primary.opacity(0.12)).frame(width: 1) }
                TermScreen(key: key, id: term.id, fontSize: fontSize, dark: scheme == .dark)
                    .id("\(term.id)-\(scheme == .dark)")
                    .padding(.leading, 6)
                    .overlay {
                        if members.count > 1 && term.id == current.id {
                            Rectangle().strokeBorder(Theme.claude.opacity(0.35), lineWidth: 1).allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded { model.terminals.selected[key] = term.id })
            }
        }
    }

    /// 手机上的手势引导：只在第一次打开终端时出现；一张贴在终端顶上的小卡片（不盖灰色遮罩、不挡下面的输入区），
    /// 点卡片任意处或右上角关闭就收起，看过一次以后都不再出现（11-21：之前每次都弹、半屏灰遮罩挡住状态和输入）
    private var gestureGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("终端手势").font(.ui(.subheadline).weight(.semibold))
                Spacer()
                Image(systemName: "xmark.circle.fill").font(.app(size: 18)).foregroundStyle(.tertiary)
                    .accessibilityLabel(L("关闭"))
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 8) {
                guideRow("hand.tap", L("单指轻点"), L("定位光标"))
                guideRow("hand.point.up.left.and.text", L("单指拖动"), L("选中文字"))
                guideRow("hand.draw", L("双指上下滑"), L("翻看历史"))
                guideRow("hand.point.up.left", L("长按"), L("拷贝、粘贴"))
            }
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { guideOff = true; guideShown = false } }
        .transition(.opacity)
    }

    private func guideRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.app(size: 17)).frame(width: 24).foregroundStyle(Theme.claude)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.subheadline).weight(.semibold))
                Text(detail).font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    /// 按面板（或其中一块）的宽高算行列数（同 SwiftTerm 的算法）
    private func grid(width: CGFloat, height: CGFloat) -> (cols: Int, rows: Int) {
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let scroller: CGFloat = 0
        #else
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let scroller: CGFloat = 16
        #endif
        let ct = font as CTFont
        let line = ceil((CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) * scale) / scale
        let cell = (("W" as NSString).size(withAttributes: [.font: font]).width * scale).rounded() / scale
        guard width >= 1 else { return (80, 24) }
        return (max(Int((width - 6 - scroller) / max(cell, 1)), 20), max(Int(height / max(line, 1)), 5))
    }

    private func split(_ term: TermInfo) {
        let size = grid(width: area.width / 2, height: area.height)
        Task { await model.terminals.split(key, term.id, cols: size.cols, rows: size.rows) }
    }

    /// 终端的右键 / 长按菜单（同 VS Code）：重命名、改颜色、拆分、关闭
    @ViewBuilder
    private func termMenu(_ term: TermInfo) -> some View {
        Button { renameText = term.customName; renaming = term } label: { Label("重命名…", systemImage: "pencil") }
        Menu {
            ForEach(TermColor.all, id: \.id) { color in
                Button { Task { await model.terminals.setColor(key, term.id, color.id) } } label: {
                    if term.color == color.id { Label(color.name, systemImage: "checkmark") } else { Text(color.name) }
                }
            }
        } label: { Label("更改颜色", systemImage: "paintpalette") }
        if !term.hosted && !term.isRun {
            Button { split(term) } label: { Label("拆分终端", systemImage: "square.split.2x1") }
        }
        if !term.hosted {
            Divider()
            Button(role: .destructive) { Task { await model.terminals.close(key, term.id) } } label: { Label("关闭终端", systemImage: "trash") }
        }
    }

    /// 新开一个终端，一开始就按面板的大小（同 SwiftTerm 的算法）：先按 80 列开再缩小的话，zsh 会在第一行留下一个「%」
    private func openNew() async {
        for _ in 0..<20 where area.width < 1 { try? await Task.sleep(for: .milliseconds(50)) }
        let size = grid(width: area.width, height: area.height)
        await model.terminals.open(key, cols: size.cols, rows: size.rows)
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
            // 同 VS Code：标题栏只写「终端」；几个终端在右边一列切换（只有一个时不显示那列，名字写在这里）
            Group {
                if terms.count == 1, let only = terms.first {
                    Text(only.device.isEmpty ? only.name : "\(only.device) · \(only.name)")
                } else {
                    Text(terms.isEmpty ? L("所有终端") : "\(L("所有终端")) · \(terms.count)")
                }
            }
            .font(.ui(.caption).weight(.semibold))
            .lineLimit(1)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await openNew() } } label: {
                Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.opening.contains(key))
            .accessibilityLabel(L("新建终端"))
            // 拆分（同 VS Code 标题栏上的拆分按钮）：在正在看的终端旁边再开一个
            if let current, !current.hosted, !current.isRun {
                Button { split(current) } label: {
                    Image(systemName: "square.split.2x1").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("拆分终端"))
            }
            Menu {
                Button { fontSize = min(fontSize + 1, 20) } label: { Label("放大字号", systemImage: "textformat.size.larger") }
                Button { fontSize = max(fontSize - 1, 9) } label: { Label("缩小字号", systemImage: "textformat.size.smaller") }
                if let current {
                    Divider()
                    termMenu(current)
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

    /// 同一台设备上同一种 shell 开了几个：zsh、zsh 2、zsh 3（同 VS Code）
    private func tabTitle(_ terms: [TermInfo], _ index: Int) -> String {
        let term = terms[index]
        let same = terms[..<index].filter { $0.name == term.name && $0.device == term.device }.count
        return same == 0 ? term.name : "\(term.name) \(same + 1)"
    }

    /// 标签下面一行：这个终端在哪台设备上、agent 跑的是什么命令、跑完没有。设备名放最前面加粗，一眼分清是哪台
    private func place(_ term: TermInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: deviceIcon(term)).font(.app(size: 10, weight: .semibold))
            Text(term.device.isEmpty ? L("电脑") : term.device).font(.ui(.caption).weight(.semibold)).lineLimit(1)
                .foregroundStyle(.primary)
            if term.isRun {
                Text(term.run).font(.app(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if term.ended {
                    if let code = term.exitCode, code != 0 {
                        Text("已结束，退出码 \(code)").font(.ui(.caption2)).foregroundStyle(Theme.claude)
                    } else {
                        Text("已完成").font(.ui(.caption2))
                    }
                } else {
                    Text("Agent 运行中").font(.ui(.caption2))
                }
            } else {
                Text(term.cwd).font(.ui(.caption2)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 5)
        .accessibilityElement(children: .combine)
    }

    /// 拆分组在列表里的连线（同 VS Code）：组里第一个 ┌、中间 ├、最后 └；不在组里的空
    private func connector(_ terms: [TermInfo], _ index: Int) -> String {
        guard let group = terms[index].group else { return "" }
        let members = terms.indices.filter { terms[$0].group == group }
        guard members.count > 1 else { return "" }
        return index == members.first ? "┌" : index == members.last ? "└" : "├"
    }

    /// 开在会话所在那台以外的设备上：换个图标提醒
    private func deviceIcon(_ term: TermInfo) -> String {
        let home = model.terminals.devices[key]
        return home == nil || home == term.device ? "desktopcomputer" : "arrow.triangle.branch"
    }

    private func tabIcon(_ term: TermInfo) -> String {
        guard term.isRun else { return "apple.terminal" }
        if !term.ended { return "play.circle" }
        return (term.exitCode ?? 0) == 0 ? "checkmark.circle" : "exclamationmark.circle"
    }

    /// 终端和列表之间的分隔条（同 VS Code 的 sash）：拖动改列表宽度，双击恢复默认
    private var sash: some View {
        Rectangle()
            .fill(SwiftUI.Color.primary.opacity(listDragStart == nil ? 0.1 : 0.35))
            .frame(width: 1)
            .frame(width: 7)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = listDragStart ?? Double(listWidth)
                        listDragStart = start
                        storedList = min(max(start - drag.translation.width, Self.minList), max(Self.minList, Double(width) * 0.5))
                    }
                    .onEnded { _ in listDragStart = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { storedList = Self.defaultList })
            #if os(macOS)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            #endif
            .padding(.horizontal, -3)
            .zIndex(1)
            .accessibilityLabel(L("拖动调整终端列表宽度"))
    }

    /// 右边一列：终端列表（同 VS Code）。每行图标 + 设备名（加粗）+ 名字；窄到放不下只剩图标。正在看的那行淡色底加细边，悬停出现删除
    private func titleList(_ terms: [TermInfo], _ current: TermInfo?) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 1) {
                ForEach(Array(terms.enumerated()), id: \.element.id) { index, term in
                    TermTitleRow(term: term, title: tabTitle(terms, index), icon: tabIcon(term), selected: term.id == current?.id,
                                 compact: listCompact, connector: connector(terms, index),
                                 select: { model.terminals.selected[key] = term.id },
                                 close: { Task { await model.terminals.close(key, term.id) } })
                        .contextMenu { termMenu(term) }
                        // 拖动排序（同 VS Code）：拖到哪一行上就放到它前面
                        .draggable(term.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let moving = ids.first, moving != term.id else { return false }
                            Task { await model.terminals.move(key, moving, before: term.id) }
                            return true
                        }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .frame(width: listWidth)
        .background(TerminalColors.background(scheme).opacity(0.6))
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
        // 文字和背景对比度不到 4.5 就自动调深 / 调浅（同 VS Code 终端默认）：Claude 按深色背景配的浅灰次要文字在白底上才看得清
        view.minimumContrastRatio = 4.5
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
        // 双指上下滑翻看历史（单指拖动不做事，也不当成按住鼠标拖动发给 Claude，否则一滑就变成选中文字）；轻点是鼠标单击，长按选中复制
        view.touchScrollsInsteadOfDragging = true
        // 单指拖动选中，松手弹「拷贝 / 取消」（同小程序、同引导里写的交互）
        view.onTouchSelection = { [weak view] text in
            let shown = text.count > 300 ? String(text.prefix(300)) + "…" : text
            let alert = UIAlertController(title: L("选中的文字"), message: shown, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("取消"), style: .cancel) { _ in view?.clearTouchSelection() })
            alert.addAction(UIAlertAction(title: L("拷贝"), style: .default) { _ in
                UIPasteboard.general.string = text
                view?.clearTouchSelection()
            })
            var top = view?.window?.rootViewController
            while let next = top?.presentedViewController { top = next }
            top?.present(alert, animated: true)
        }
        TerminalColors.style(view, dark: dark)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize { view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: TermLink) {
        // 还拿着键盘就被拆掉（收起面板、切到别的会话）：先正常交回去。直接拆的话键盘是被动收起的，
        // iPad 上辅助键那一条的高度可能留在底部安全区里，输入栏回来后底下空着一截（11-19）
        if view.isFirstResponder { _ = view.resignFirstResponder() }
        coordinator.detach()
    }
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

    var grid: (cols: Int, rows: Int)? {
        guard let terminal = view?.getTerminal(), terminal.cols > 0, terminal.rows > 0 else { return nil }
        return (terminal.cols, terminal.rows)
    }

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

/// 终端标题列表里的一行（两列布局的右边那列）
private struct TermTitleRow: View {
    let term: TermInfo
    let title: String
    let icon: String
    let selected: Bool
    /// 列表窄到只放得下图标（同 VS Code）
    let compact: Bool
    /// 拆分组的连线（┌ ├ └）
    let connector: String
    let select: () -> Void
    let close: () -> Void
    @State private var hover = false

    /// 删除按钮：电脑上悬停出现（同 VS Code）；手机没有悬停，正在看的那行常显
    private var showDelete: Bool {
        #if os(macOS)
        hover && !term.hosted
        #else
        selected && !term.hosted
        #endif
    }

    private var label: String { term.device.isEmpty ? title : "\(term.device) · \(title)" }

    var body: some View {
        HStack(spacing: 6) {
            if !connector.isEmpty && !compact {
                Text(connector).font(.app(size: 12, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 8)
            }
            Image(systemName: icon).font(.app(size: 11, weight: .semibold)).frame(width: 14)
                .foregroundStyle(TermColor.swatch(term.color) ?? (selected ? Theme.claude : SwiftUI.Color.primary.opacity(0.8)))
            if !compact {
                if !term.device.isEmpty {
                    Text(term.device).font(.ui(.caption).weight(.semibold)).lineLimit(1).layoutPriority(1)
                }
                Text(title).font(.ui(.caption)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
                // 删除按钮（同 VS Code 悬停出现的垃圾桶）常驻占位、只改透明度：悬停时不增删控件，行高不变
                Button(action: close) {
                    Image(systemName: "trash").font(.app(size: 10, weight: .medium)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showDelete ? 1 : 0)
                .allowsHitTesting(showDelete)
                .accessibilityLabel(L("关闭终端"))
            }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .foregroundStyle(selected ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(.primary.opacity(0.8)))
        .padding(.leading, compact ? 0 : 8).padding(.trailing, compact ? 0 : 4)
        .frame(height: 24)
        .background(selected ? Theme.claude.opacity(0.12) : (hover ? SwiftUI.Color.primary.opacity(0.06) : .clear),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay { if selected { RoundedRectangle(cornerRadius: 5, style: .continuous).hairlineBorder(Theme.claude.opacity(0.45)) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        #if os(macOS)
        .onHover { hover = $0 }
        #endif
        .help(term.hosted ? "\(label)\n" + L("Claude 主终端（后台运行），不能关闭") : "\(label)\n" + (term.isRun ? term.run : term.cwd))
        .accessibilityLabel(label)
    }
}

/// 终端的颜色（同 VS Code 终端的「更改颜色」，取终端调色板里不刺眼的几种）
enum TermColor {
    struct Choice { let id: String; let name: String }
    static let all: [Choice] = [
        Choice(id: "", name: L("默认")), Choice(id: "red", name: L("红色")), Choice(id: "green", name: L("绿色")),
        Choice(id: "yellow", name: L("黄色")), Choice(id: "blue", name: L("蓝色")), Choice(id: "magenta", name: L("紫色")),
        Choice(id: "cyan", name: L("青色")),
    ]

    static func swatch(_ id: String) -> SwiftUI.Color? {
        switch id {
        case "red": SwiftUI.Color(hex: 0xD9534F)
        case "green": SwiftUI.Color(hex: 0x3FA66B)
        case "yellow": SwiftUI.Color(hex: 0xC9A227)
        case "blue": SwiftUI.Color(hex: 0x3B82C4)
        case "magenta": SwiftUI.Color(hex: 0xA25CC4)
        case "cyan": SwiftUI.Color(hex: 0x2A9DB0)
        default: nil
        }
    }
}
