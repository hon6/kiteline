import SwiftUI

/// 我的收藏（同微信的收藏）：收藏的消息一条一张，新的在上；能搜文字、会话名；点「原消息」跳回那条消息，
/// 长按 / 右键复制、取消收藏。内容存在电脑上，各端看到的是同一份
struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @State private var query = ""
    /// 这次打开从电脑读过一回（之前列表空着是「正在读取」，不是「暂无收藏」）
    @State private var fetched = false
    /// 嵌在 Mac 左边栏的「收藏」页签里（11-20）：列表的第一行是左边栏顶上那几格（跟着一起滚），搜索框排在格子下面一行，
    /// 空着的说明也排在列表里（不盖住那几格）
    var sidebarHeader: AnyView? = nil
    /// 正在改哪一条的文字
    @State private var editing: FavoriteItem?
    /// 刚点开原消息的那一条：选中样子同会话列表（淡主题色底 + 描边），11-21 反馈：选中状态不明显
    @State private var current: String?

    var body: some View {
        let items = filtered
        List {
            if let sidebarHeader {
                sidebarHeader.listRowInsets(EdgeInsets())   // 新版界面里它是空的：别占一行的上下边距（11-21 反馈：收藏标题上面空得出奇）
                sidebarBar
                if model.favorites.items.isEmpty {
                    if fetched { sidebarEmpty } else { SkeletonShape(style: .list(3)) }
                } else if items.isEmpty {
                    Text("没有匹配的收藏").font(.app(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            // 左边栏里行放在一组里（没有组头）：侧栏列表有组的时候各行右边多留一截，和分了组的会话列表对齐，切页签时顶上那几格不会一宽一窄
            rows(items)
        }
        .overlay {
            if sidebarHeader != nil {
                EmptyView()
            } else if model.favorites.items.isEmpty, !fetched {
                SkeletonPage(style: .favorites(4))
            } else if model.favorites.items.isEmpty {
                emptyState
            } else if items.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        #if os(macOS)
        // 左边栏里不用系统侧栏样式：它把每行的字截成一行（11-21 反馈：收藏里全是省略号，要显示完整内容）
        .modifier(PlainInSidebar(on: sidebarHeader != nil))
        #endif
        .animation(.skeletonFade, value: fetched)   // 读回来时骨架淡出、内容淡入
        // 别处（手机、电脑）收藏 / 取消了一条，推过来时行平滑挪动
        .animation(.snappy, value: model.favorites.items.map(\.id))
        .modifier(FavoritesSearch(query: $query, on: sidebarHeader == nil))
        .navigationTitle(sidebarHeader == nil ? L("收藏") : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.refreshFavorites(); fetched = true }
        .refreshable { await model.refreshFavorites() }
        .sheetPanel(item: $editing) { FavoriteEditor(item: $0) }
        // 自测：从外面叫它打开某一条的编辑（KitelineKit.editFavorite）
        .onChange(of: FavoriteEditRequest.shared.item) { _, item in
            guard let item else { return }
            FavoriteEditRequest.shared.item = nil
            editing = item
        }
    }

    private func rows(_ items: [FavoriteItem]) -> some View {
        ForEach(items) { item in
            FavoriteRow(item: item, edit: model.supportsFavoriteEdit ? { editing = item } : nil) { jump(item) }
                .listRowBackground(selectedBackground(item.id == current))
                .contextMenu { menu(item) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { model.removeFavorites([item.id]) } label: { Label("取消收藏", systemImage: "star.slash") }
                    if model.supportsFavoriteEdit {
                        Button { editing = item } label: { Label("编辑", systemImage: "pencil") }.tint(.gray)
                    }
                }
        }
    }

    @ViewBuilder private func selectedBackground(_ on: Bool) -> some View {
        if on {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.fill(Theme.claude.opacity(0.14))
                .overlay(shape.strokeBorder(Theme.claude.opacity(0.32), lineWidth: 1))
                .padding(.horizontal, sidebarHeader != nil ? 4 : 0)
        }
    }

    /// 左边栏里格子下面一行：「收藏 7」和搜索框
    private var sidebarBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("收藏").font(.app(size: 13, weight: .semibold))
                if !model.favorites.items.isEmpty {
                    Text("\(model.favorites.items.count)").font(.app(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            if model.favorites.items.count > 3 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.app(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField(L("搜索收藏的内容、会话"), text: $query).textFieldStyle(.plain).font(.app(size: 12))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).help(L("清除"))
                    }
                }
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var sidebarEmpty: some View {
        Text("暂无收藏。在对话中右键点击一条消息，选择「加入收藏」即可收藏；收藏的内容保存在电脑上，手机和电脑都能查看。")
            .font(.app(size: 11.5)).foregroundStyle(.secondary)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
    }

    /// 搜索：内容、会话名、谁说的，几个词都要对上
    private var filtered: [FavoriteItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let items = model.favorites.items.sorted { $0.at > $1.at }
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = [item.text ?? "", item.title, item.speaker ?? "", item.machine ?? ""].joined(separator: "\n").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    @ViewBuilder
    private func menu(_ item: FavoriteItem) -> some View {
        Button { jump(item) } label: { Label("跳转到原消息", systemImage: "arrowshape.turn.up.backward") }
        if model.supportsFavoriteEdit {
            Button { editing = item } label: { Label("编辑", systemImage: "pencil") }
        }
        if let text = item.text, !text.isEmpty {
            Button { Clipboard.copy(text); model.flash(L("已复制")) } label: { Label("复制", systemImage: "doc.on.doc") }
        }
        Button(role: .destructive) { model.removeFavorites([item.id]) } label: { Label("取消收藏", systemImage: "star.slash") }
    }

    private func jump(_ item: FavoriteItem) {
        current = item.id
        model.openSource(key: item.key, itemId: item.itemId, open: open)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无收藏", systemImage: "star")
        } description: {
            #if os(macOS)
            Text("在对话中右键点击一条消息，选择「加入收藏」即可收藏。收藏的内容保存在电脑上，手机和电脑都能查看。")
            #else
            Text("在对话中长按一条消息，选择「加入收藏」即可收藏。收藏的内容保存在电脑上，手机和电脑都能查看。")
            #endif
        }
    }
}

/// 整页的收藏带搜索框（手机在导航栏下、Mac 面板在列表上面固定一条）；嵌在 Mac 左边栏里时搜索框是列表里的一行，不挂这个
private struct FavoritesSearch: ViewModifier {
    @Binding var query: String
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.panelSearch($query, prompt: L("搜索收藏的内容、会话")) } else { content }
    }
}

/// 一条收藏：图（一张大一点，几张排九宫格）、文字（长的先显示开头，「展开全文」看全部），底下一行谁说的 · 哪个会话 · 时间 · 原消息
struct FavoriteRow: View {
    @Environment(AppModel.self) private var model
    let item: FavoriteItem
    /// 改这条的文字（连着的电脑支持才有）
    var edit: (() -> Void)? = nil
    let jump: () -> Void
    @State private var expanded = false
    @State private var viewing: Int?

    private static let previewLength = 400
    #if os(macOS)
    private let single: CGFloat = 160, gridWidth: CGFloat = 320
    #else
    private let single: CGFloat = 140, gridWidth: CGFloat = 260
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：左边收藏的那条消息的时间（年月日时分秒），右边编辑（11-21）
            HStack(spacing: 6) {
                Text(Format.fullTime(item.ts ?? item.at)).monospacedDigit()
                Spacer(minLength: 8)
                if let edit {
                    Button(action: edit) { Image(systemName: "pencil").font(.ui(.caption).weight(.semibold)).frame(width: 22, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.steady(.plain))
                        .help(L("编辑"))
                        .accessibilityLabel(L("编辑"))
                }
            }
            .font(.ui(.caption))
            .foregroundStyle(.secondary)
            if !item.images.isEmpty { images }
            if let text = item.text, !text.isEmpty {
                let long = text.count > Self.previewLength
                MarkdownView(long && !expanded ? String(text.prefix(Self.previewLength)) + "…" : text)
                    .font(ChatType.body)
                    .lineSpacing(ChatType.lineSpacing)
                if long {
                    Button(expanded ? L("收起") : L("展开全文")) { withAnimation(.snappy) { expanded.toggle() } }
                        .buttonStyle(.steady(.plain))
                        .font(.ui(.footnote))
                        .foregroundStyle(Theme.claude)
                }
            }
            footer
        }
        .padding(.vertical, 6)
        // 点这一条就跳回原消息（去掉了单独的「原消息」按钮，11-21 用户）
        .contentShape(Rectangle())
        .onTapGesture { guard TouchTravel.isTap else { return }; jump() }
        #if os(macOS)
        .sheetPanel(item: Binding(get: { viewing.map(FavoriteViewerIndex.init) }, set: { viewing = $0?.index })) { start in
            MacImageViewer(key: "favorites", images: item.images, index: start.index, path: FavoriteItem.mediaPath)
        }
        #else
        .fullScreenCover(item: Binding(get: { viewing.map(FavoriteViewerIndex.init) }, set: { viewing = $0?.index })) { start in
            ImageViewer(key: "favorites", images: item.images, index: start.index, path: FavoriteItem.mediaPath)
        }
        #endif
    }

    /// 最后一行：谁说的 · 哪个会话（时间在第一行，编辑在右上角；点整条跳回原消息）
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "star.fill").font(.ui(.caption2)).foregroundStyle(Theme.claude)
            Text([speaker, item.title].filter { !$0.isEmpty }.joined(separator: " · "))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.ui(.caption))
        .foregroundStyle(.secondary)
    }

    private var speaker: String {
        item.mine ? (model.me?.name ?? L("我")) : (item.speaker ?? Agents.info(item.agent).speaker)
    }

    @ViewBuilder
    private var images: some View {
        if item.images.count == 1 {
            thumb(0).frame(width: single, height: single)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(item.images.indices, id: \.self) { index in
                    thumb(index).aspectRatio(1, contentMode: .fit)
                }
            }
            .frame(maxWidth: gridWidth)
        }
    }

    /// 格子大小由底色块定，图盖在上面填满再裁掉；点开看大图（能缩放、左右翻）
    private func thumb(_ index: Int) -> some View {
        Color.primary.opacity(0.06)
            .overlay { RemoteImage(path: FavoriteItem.mediaPath, query: FavoriteItem.mediaQuery(item.images[index].ref), variant: .square) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { guard TouchTravel.isTap else { return }; viewing = index }
    }
}

private struct FavoriteViewerIndex: Identifiable {
    let index: Int
    var id: Int { index }
}

/// 自测用：让开着的收藏页打开某一条的编辑面板
@MainActor @Observable
final class FavoriteEditRequest {
    static let shared = FavoriteEditRequest()
    var item: FavoriteItem?
}

/// 改一条收藏的文字（11-20 反馈：收藏里的内容有问题没办法修改）：只改收藏里存的这一份，原对话不动，图不动。
/// Mac 是面板里一个大文字框（回车换行，⌘回车保存），手机是一页表单
struct FavoriteEditor: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let item: FavoriteItem
    @State private var text: String
    @State private var confirmDiscard = false
    #if os(macOS)
    @State private var inputHeight: CGFloat = 200
    @State private var focusToken = 0
    #endif

    init(item: FavoriteItem) {
        self.item = item
        _text = State(initialValue: item.text ?? "")
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dirty: Bool { trimmed != (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 没有图的收藏不能改成空的（那就是取消收藏了）
    private var canSave: Bool { dirty && (!trimmed.isEmpty || !item.images.isEmpty) }
    private var sourceText: String {
        L("出自「%@」", "\(item.title)") + (item.ts.map { " · " + Format.listTime($0) } ?? "")
    }
    private static var note: String { L("只修改收藏中保存的这一份，原对话不受影响；图片保持不变。") }

    private func cancel() { if dirty { confirmDiscard = true } else { dismiss() } }

    private func save() {
        guard canSave else { return }
        model.updateFavorite(item.id, text: trimmed)
        dismiss()
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // 标题「编辑收藏」在面板标题栏正中；这里一行：左边出自哪个会话，右边时间（11-21）
                HStack(spacing: 8) {
                    Label(L("出自「%@」", "\(item.title)"), systemImage: "text.bubble")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Format.fullTime(item.ts ?? item.at)).monospacedDigit()
                }
                .font(.ui(.footnote)).foregroundStyle(.secondary)
                .padding(.bottom, DialogMetric.gap)
                MacInputField(text: $text, height: $inputHeight, placeholder: L("收藏的内容"), enabled: true, focusToken: focusToken,
                              onSubmit: { save() }, onPasteImages: { _ in },
                              minHeight: 200, maxHeight: 460, returnSubmits: false)
                    // 面板拉高时多出来的高度给输入框
                    .frame(minHeight: inputHeight, idealHeight: inputHeight, maxHeight: .infinity)
                    .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).hairlineBorder(MacPalette.separator))
                Text(Self.note).font(.ui(.caption)).foregroundStyle(.tertiary).padding(.top, 8)
            }
            .padding(DialogMetric.pad)
            Divider()
            HStack(spacing: 10) {
                Text(L("⌘↩ %@", L("保存"))).font(.ui(.caption)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button(L("取消"), action: cancel).keyboardShortcut(.cancelAction).kiteButton()
                Button(L("保存")) { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .kiteButton(prominent: true)
                    .disabled(!canSave)
            }
            .controlSize(.large)
            .padding(.horizontal, DialogMetric.pad).padding(.vertical, DialogMetric.barV)
        }
        // 打开时 600 宽、高度跟着内容走；能拖边改大小
        .frame(minWidth: 460, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("编辑收藏"))   // 面板标题栏正中
        .confirmPanel(L("放弃所做的修改？"), isPresented: $confirmDiscard, confirm: L("放弃修改"), destructive: true, cancel: L("继续编辑")) { dismiss() }
        .task { focusToken += 1 }
        #else
        NavigationStack {
            Form {
                Section {
                    TextField("收藏的内容", text: $text, axis: .vertical)
                        .lineLimit(6...24)
                } header: {
                    Text(sourceText).textCase(nil)
                } footer: {
                    Text(Self.note).font(.ui(.footnote))
                }
            }
            .navigationTitle("编辑收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                        .confirmationDialog("放弃所做的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                            Button("放弃修改", role: .destructive) { dismiss() }
                            Button("继续编辑", role: .cancel) {}
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.fontWeight(.semibold).disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(dirty)
        #endif
    }
}


#if os(macOS)
private struct PlainInSidebar: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.listStyle(.plain).scrollContentBackground(.hidden) } else { content }
    }
}
#endif
