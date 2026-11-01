import SwiftUI

/// 我的收藏（同微信的收藏）：收藏的消息一条一张，新的在上；能搜文字、会话名；点「原消息」跳回那条消息，
/// 长按 / 右键复制、取消收藏。内容存在电脑上，各端看到的是同一份
struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @State private var query = ""

    var body: some View {
        let items = filtered
        List {
            ForEach(items) { item in
                FavoriteRow(item: item) { jump(item) }
                    .contextMenu { menu(item) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.removeFavorites([item.id]) } label: { Label("取消收藏", systemImage: "star.slash") }
                    }
            }
        }
        .overlay {
            if model.favorites.items.isEmpty {
                emptyState
            } else if items.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        // 别处（手机、电脑）收藏 / 取消了一条，推过来时行平滑挪动
        .animation(.snappy, value: model.favorites.items.map(\.id))
        .panelSearch($query, prompt: L("搜索收藏的内容、会话"))
        .navigationTitle("收藏")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.refreshFavorites() }
        .refreshable { await model.refreshFavorites() }
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
        if let text = item.text, !text.isEmpty {
            Button { Clipboard.copy(text); model.flash(L("已复制")) } label: { Label("复制", systemImage: "doc.on.doc") }
        }
        Button(role: .destructive) { model.removeFavorites([item.id]) } label: { Label("取消收藏", systemImage: "star.slash") }
    }

    private func jump(_ item: FavoriteItem) {
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

/// 一条收藏：图（一张大一点，几张排九宫格）、文字（长的先显示开头，「展开全文」看全部），底下一行谁说的 · 哪个会话 · 时间 · 原消息
struct FavoriteRow: View {
    @Environment(AppModel.self) private var model
    let item: FavoriteItem
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
            if !item.images.isEmpty { images }
            if let text = item.text, !text.isEmpty {
                let long = text.count > Self.previewLength
                MarkdownView(long && !expanded ? String(text.prefix(Self.previewLength)) + "…" : text)
                    .font(ChatType.body)
                    .lineSpacing(ChatType.lineSpacing)
                    #if os(macOS)
                    .textSelection(.enabled)   // Mac：拖着选一段复制
                    #endif
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
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture { guard TouchTravel.isTap else { return }; jump() }
        #endif
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

    /// 谁说的 · 哪个会话 · 什么时候；右边「原消息」跳回去
    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill").font(.ui(.caption2)).foregroundStyle(Theme.claude)
            Text([speaker, item.title, item.ts.map(Format.listTime) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: jump) {
                HStack(spacing: 3) {
                    Text("原消息")
                    Image(systemName: "chevron.right").font(.ui(.caption2).weight(.semibold))
                }
            }
            .buttonStyle(.steady(.plain))
            .help(L("跳转到原消息"))
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
