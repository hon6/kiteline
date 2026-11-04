import SwiftUI

/// 某台电脑上一个目录里的子文件夹（/api/dirs，watcher 的 dirs）
struct FolderListing: Decodable {
    struct Entry: Decodable, Hashable {
        var name: String
        var path: String
        var git: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.fields()
            name = c.text("name") ?? ""
            path = c.text("path") ?? ""
            git = c.truthy("git")
        }
    }

    var path: String
    var parent: String?
    var home: String
    var sep: String
    var entries: [Entry]
    /// Windows 的各个盘（C:\、D:\……）
    var roots: [String]
    /// 这个目录本身是 git 仓库
    var git: Bool
    var truncated: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        path = c.text("path") ?? ""
        parent = c.text("parent")
        home = c.text("home") ?? ""
        sep = c.text("sep") ?? "/"
        entries = c.one("entries") ?? []
        roots = c.one("roots") ?? []
        git = c.truthy("git")
        truncated = c.truthy("truncated")
    }

    /// 最后一级的名字（根目录就是它自己：/、C:）
    var name: String { path.components(separatedBy: sep).last { !$0.isEmpty } ?? path }

    /// 路径一级一级的（显示的字、点了去哪）：在主目录里的从「主目录」起，别的从根起
    var crumbs: [(label: String, path: String)] {
        let home = home.hasSuffix(sep) && home.count > 1 ? String(home.dropLast()) : home
        var out: [(String, String)]
        var rest: String
        if !home.isEmpty, path == home || path.hasPrefix(home + sep) {
            out = [(L("主目录"), home)]
            rest = String(path.dropFirst(home.count))
        } else if sep == "\\", let colon = path.firstIndex(of: ":") {
            let drive = String(path[...colon]) + "\\"
            out = [(drive, drive)]
            rest = String(path[path.index(after: colon)...])
        } else {
            out = [(L("根目录"), "/")]
            rest = path
        }
        var current = out[0].1
        for part in rest.components(separatedBy: sep) where !part.isEmpty {
            current = current.hasSuffix(sep) ? current + part : current + sep + part
            out.append((part, current))
        }
        return out
    }
}

public enum FolderStart {
    /// 选文件夹从哪开始：这台电脑上的项目大多放在哪个文件夹（如 ~/Projects）——出现最多的上一级目录，一样多取最近用过的（cwds 最近的在前）
    public static func usual(_ cwds: [String]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for cwd in cwds {
            let sep: Character = cwd.hasPrefix("/") ? "/" : "\\"
            guard let cut = cwd.lastIndex(of: sep) else { continue }
            let parent = String(cwd[..<cut])
            // 根目录、盘符（C:）不算
            guard !parent.isEmpty, !parent.hasSuffix(":") else { continue }
            if counts[parent] == nil { order.append(parent) }
            counts[parent, default: 0] += 1
        }
        var best = ""
        for parent in order where counts[parent, default: 0] > counts[best, default: 0] { best = parent }
        return best
    }
}

/// 新任务「打开其他文件夹」：一层层点进那台电脑上的文件夹，选定后在那里新建会话。
/// iPhone 和 Mac（远端电脑；Mac 本机用系统的选文件夹框）同一个页面
struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    let sourceId: String
    let machine: String
    /// 打开时先到哪（空 = 主目录）
    var start: String = ""
    /// Mac 面板里自己带「取消」；iPhone 是推进来的页面，返回就行
    var cancel: (() -> Void)? = nil
    let pick: (String) -> Void
    @State private var listing: FolderListing?
    @State private var error: String?
    /// 点进某个文件夹没成功（没权限……）：留在原地，上面提示一句
    @State private var failed: String?
    @State private var query = ""
    /// iPhone 上筛选时系统收起导航栏（「打开」也没了）：点进下一级就退出筛选
    @State private var searching = false
    @State private var hidden = false
    @State private var loading = false
    @State private var nameAsk: NameAsk?

    var body: some View {
        List {
            if let failed {
                Label(failed, systemImage: "exclamationmark.triangle").font(.ui(.footnote)).foregroundStyle(.orange)
            }
            if let listing {
                let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                let shown = q.isEmpty ? listing.entries : listing.entries.filter { $0.name.lowercased().contains(q) }
                Section {
                    ForEach(shown, id: \.path) { entry in
                        Button { Task { await load(entry.path) } } label: { row(entry) }.buttonStyle(RowButtonStyle())
                    }
                    if shown.isEmpty {
                        Text(q.isEmpty ? "此文件夹中没有子文件夹" : "没有匹配的文件夹").foregroundStyle(.secondary)
                    }
                } header: {
                    crumbs(listing).textCase(nil)
                } footer: { Group {
                        if listing.truncated { Text("此目录文件夹过多，仅列出前 2000 个。") }
                        #if os(macOS)
                        Text(L("点击文件夹进入，选好后点击「打开」，将在「%@」中新建会话。", listing.name))
                        #else
                        Text(L("轻点文件夹进入，选好后轻点「打开」，将在「%@」中新建会话。", listing.name))
                        #endif
                    }
                    .font(.ui(.footnote))
                }
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .overlay {
            if listing == nil {
                if let error { LoadFailed(error: error) { await load(start) } } else { ProgressView() }
            }
        }
        .panelSearch($query, prompt: L("筛选文件夹"), active: $searching)
        .navigationTitle(L("选择文件夹 · %@", machine))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let cancel {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel).panelToolbarButton() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { newFolder() } label: { Label("新建文件夹…", systemImage: "folder.badge.plus") }
                    Toggle(isOn: $hidden) { Label("显示隐藏文件夹", systemImage: "eye") }
                    if let listing {
                        Divider()
                        Button { Task { await load(listing.home) } } label: { Label("主目录", systemImage: "house") }
                        ForEach(listing.roots, id: \.self) { drive in
                            Button { Task { await load(drive) } } label: { Label(drive, systemImage: "internaldrive") }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .panelToolbarItem()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("打开") { if let listing { pick(listing.path) } }
                    .disabled(listing == nil || loading)
                    .panelToolbarButton()
            }
        }
        .codeAsks(.constant(nil), $nameAsk)
        .task { await load(start) }
        .onChange(of: hidden) { _, _ in Task { await load(listing?.path ?? start) } }
        #if os(macOS)
        .panelFrame(width: 520, height: 560)
        #endif
    }

    private func row(_ entry: FolderListing.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.claude.opacity(0.85)).frame(width: 22).accessibilityHidden(true)
            Text(entry.name).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                .opacity(entry.name.hasPrefix(".") ? 0.55 : 1)
            Spacer(minLength: 4)
            if entry.git {
                Text("Git").font(.ui(.caption2).weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            Image(systemName: "chevron.right").font(.ui(.caption2).weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
    }

    /// 当前路径当组头（同「项目文件」）：放不下时前面几级收成「…」（点它回到再上一级），现在在哪一级总看得见
    private func crumbs(_ listing: FolderListing) -> some View {
        let parts = listing.crumbs
        return ViewThatFits(in: .horizontal) {
            ForEach(Array((1...max(parts.count, 1)).reversed()), id: \.self) { keep in
                crumbRow(listing, parts: parts, keep: min(keep, parts.count))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func crumbRow(_ listing: FolderListing, parts: [(label: String, path: String)], keep: Int) -> some View {
        let first = parts.count - keep
        let sep = listing.sep == "\\" ? "\\" : "/"
        return HStack(spacing: 4) {
            if first > 0 {
                Button("…") { Task { await load(parts[first - 1].path) } }
                    .font(.ui(.footnote)).foregroundStyle(Theme.claude).buttonStyle(.steady(.plain))
                    .accessibilityLabel(L("上一级"))
                Text(sep).foregroundStyle(.tertiary)
            }
            ForEach(first..<parts.count, id: \.self) { index in
                if index > first { Text(sep).foregroundStyle(.tertiary) }
                let here = index == parts.count - 1
                Button(parts[index].label) { if !here { Task { await load(parts[index].path) } } }
                    .font(.ui(.footnote).weight(here ? .semibold : .regular))
                    .foregroundStyle(here ? Color.primary : Theme.claude)
                    .buttonStyle(.steady(.plain))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        // 量理想宽度（ViewThatFits 按它挑）；只剩当前这一级还放不下时让它截断
        .fixedSize(horizontal: keep > 1, vertical: false)
    }

    private func newFolder() {
        guard let listing else { return }
        nameAsk = NameAsk(title: L("新建文件夹"), message: L("在「%@」中新建", listing.name), placeholder: L("文件夹名称"), confirm: L("新建")) { name in
            Task { await load(listing.path, mkdir: name) }
        }
    }

    private func load(_ path: String, mkdir: String? = nil) async {
        loading = true
        defer { loading = false }
        do {
            let next: FolderListing
            if let mkdir {
                let reply = try await model.api.post("/api/dirs", body: ["sourceId": sourceId, "path": path, "mkdir": mkdir, "hidden": hidden])
                next = try JSONDecoder().decode(FolderListing.self, from: JSONSerialization.data(withJSONObject: reply))
            } else {
                next = try await model.api.get(FolderListing.self, "/api/dirs", ["sourceId": sourceId, "path": path, "hidden": hidden ? "1" : "0"])
            }
            listing = next
            error = nil
            failed = nil
            query = ""
            searching = false
        } catch {
            if listing == nil { self.error = error.localizedDescription } else { failed = error.localizedDescription }
        }
    }
}

#if KITELINE_MAC
/// Mac「新任务」里选远端电脑上的文件夹（本机用系统的选文件夹框）
public struct TarsFolderPicker: View {
    let sourceId: String
    let machine: String
    let start: String
    let pick: (String) -> Void
    @PanelDismiss private var dismiss

    public init(sourceId: String, machine: String, start: String = "", pick: @escaping (String) -> Void) {
        self.sourceId = sourceId
        self.machine = machine
        self.start = start
        self.pick = pick
    }

    public var body: some View {
        if let model = KitelineKit.model {
            NavigationStack {
                FolderPicker(sourceId: sourceId, machine: machine, start: start, cancel: { dismiss() }) { path in
                    pick(path)
                    dismiss()
                }
            }
            .environment(model)
            .lookRoot()
        }
    }
}
#endif
