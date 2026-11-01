#if !KITELINE_MAC
import SwiftUI

/// 设置 → 存储空间：手机上存了多少图片和离线对话记录；能全部清掉，也能按会话清
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [Row]?
    @State private var confirmAll = false
    @State private var clearing: Row?

    struct Row: Identifiable {
        let key: String
        var title: String
        var folders: [URL] = []
        var images = 0
        var imageBytes = 0
        var chatBytes = 0
        var bytes: Int { imageBytes + chatBytes }
        var id: String { key }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("一共", value: Bytes.size(total(\.bytes)))
                LabeledContent("图片", value: L("%@ 张 · ", "\(total(\.images))") + Bytes.size(total(\.imageBytes)))
                LabeledContent("离线对话记录", value: Bytes.size(total(\.chatBytes)))
                Button("清理全部缓存", role: .destructive) { confirmAll = true }
                    .disabled(total(\.bytes) == 0)
            } footer: { Group {
                    Text("已查看的图片（原图和缩略图）缓存在手机上，重启 App 或离线时仍可查看，无需再次从电脑获取。清理不影响电脑上的原图，再次查看时会重新获取。")
                }
                .font(.ui(.footnote))
            }
            if let rows, !rows.isEmpty {
                Section {
                    ForEach(rows) { row in
                        Button { clearing = row } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).foregroundStyle(.primary).lineLimit(1)
                                    Text(detail(row)).font(.ui(.caption)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(Bytes.size(row.bytes)).font(.ui(.subheadline).monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(RowButtonStyle())
                        .swipeActions { Button("清理", role: .destructive) { clear(row) } }
                    }
                } header: {
                    Text("按会话").font(.sectionHeader)
                } footer: { Group {
                        Text("轻点会话（或左滑）可清理其在手机上的图片和离线记录。")
                    }
                    .font(.ui(.footnote))
                }
            }
        }
        .overlay { if rows == nil { ProgressView() } }
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("清理手机上所有会话的图片和离线记录", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("全部清理", role: .destructive) { clearAll() }
        }
        .confirmationDialog(clearing.map { "清理「\($0.title)」" } ?? "", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
                            titleVisibility: .visible, presenting: clearing) { row in
            Button("清理 \(Bytes.size(row.bytes))", role: .destructive) { clear(row) }
        } message: { _ in
            Text("清理此会话在手机上的图片和离线记录，再次打开时将从电脑重新获取。")
        }
    }

    private func total(_ field: KeyPath<Row, Int>) -> Int { (rows ?? []).reduce(0) { $0 + $1[keyPath: field] } }

    private func detail(_ row: Row) -> String {
        var parts: [String] = []
        if row.images > 0 { parts.append(L("图片 %@ 张", "\(row.images)")) }
        if row.chatBytes > 0 { parts.append(L("离线记录 ") + Bytes.size(row.chatBytes)) }
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        let (images, chats) = await Task.detached(priority: .userInitiated) { (ImageDisk.usage(), Offline.chatSizes()) }.value
        var map: [String: Row] = [:]
        for usage in images {
            var row = map[usage.key] ?? Row(key: usage.key, title: title(usage.key, saved: usage.title))
            row.folders.append(usage.folder)
            row.images += usage.images
            row.imageBytes += usage.bytes
            map[usage.key] = row
        }
        for (key, bytes) in chats {
            var row = map[key] ?? Row(key: key, title: title(key, saved: nil))
            row.chatBytes += bytes
            map[key] = row
        }
        rows = map.values.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    /// 会话还在列表里用现在的标题；结束了的用存图时记下的；都没有就写会话号的前几位
    private func title(_ key: String, saved: String?) -> String {
        if let title = model.session(key)?.title, !title.isEmpty { return title }
        if let saved, !saved.isEmpty { return saved }
        let id = key.split(separator: "#").last.map(String.init) ?? key
        return L("会话 ") + id.prefix(8)
    }

    private func clear(_ row: Row) {
        let folders = row.folders, key = row.key
        rows?.removeAll { $0.key == key }
        ImageCache.shared.clearMemory()
        Task.detached(priority: .userInitiated) {
            folders.forEach(ImageDisk.remove(folder:))
            Offline.removeChat(key)
        }
        model.flash(L("已清理 ") + Bytes.size(row.bytes))
    }

    private func clearAll() {
        let bytes = total(\.bytes), keys = (rows ?? []).map(\.key)
        rows = []
        ImageCache.shared.clearMemory()
        Task.detached(priority: .userInitiated) {
            ImageDisk.removeAll()
            keys.forEach(Offline.removeChat)
        }
        model.flash(L("已清理 ") + Bytes.size(bytes))
    }
}
#endif
