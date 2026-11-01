import SwiftUI

/// 开源许可（设置 → 关于 →「开源许可」）：列出 App 用到的第三方开源组件和它们的许可原文。
/// 清单是 App 里打包的 ThirdPartyNotices.json（tools/licenses.py 生成，iPhone、Mac 各一份）。
/// iPhone 上是可搜索的列表、点进去看原文；Mac 在单独的窗口里左右分栏（Sources/LicensesWindow.swift）
public struct LicensesView: View {
    @State private var notices = ThirdPartyNotices.bundled()
    @State private var query = ""
    #if KITELINE_MAC
    @State private var selected: Int?
    #endif

    /// select：Mac 上一打开就选中这个组件（自测截图用）
    public init(select: String? = nil) {
        #if KITELINE_MAC
        _selected = State(initialValue: select.flatMap { name in ThirdPartyNotices.bundled().components.first { $0.name == name }?.id })
        #endif
    }

    private var filtered: [ThirdPartyNotices.Component] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? notices.components : notices.components.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    public var body: some View {
        #if KITELINE_MAC
        // 普通 NSWindow 里没有工具栏：搜索框、返回都不靠工具栏，左边列表、右边原文
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TextField(L("搜索组件"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                List(filtered, selection: $selected) { item in
                    row(item).tag(item.id)
                }
                .listStyle(.sidebar)
            }
            .frame(width: 270)
            Divider()
            if let id = selected, let item = notices.components.first(where: { $0.id == id }) {
                LicenseDetail(item: item, texts: notices.texts(for: item))
            } else {
                VStack(spacing: 10) {
                    Text(intro).multilineTextAlignment(.center)
                    Text("选择左侧的组件查看许可原文").foregroundStyle(.secondary)
                }
                .font(.ui(.body))
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.ui(.body))
        #else
        List {
            Section {
                ForEach(filtered) { item in
                    NavigationLink { LicenseDetail(item: item, texts: notices.texts(for: item)) } label: { row(item) }
                }
            } header: {
                Text(intro).font(.ui(.footnote)).textCase(nil)
            }
        }
        .searchable(text: $query, prompt: Text("搜索组件"))
        .overlay {
            if notices.components.isEmpty { ContentUnavailableView(L("此版本未包含开源许可清单"), systemImage: "doc.text") }
        }
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var intro: String { L("Kiteline 使用了下列开源软件，感谢这些项目的作者与贡献者。") }

    private func row(_ item: ThirdPartyNotices.Component) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.name).font(.ui(.body))
            Text(verbatim: item.summary).font(.ui(.caption)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}

private struct LicenseDetail: View {
    let item: ThirdPartyNotices.Component
    let texts: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.name).font(.ui(.title3).bold())
                    if !item.summary.isEmpty { Text(verbatim: item.summary).font(.ui(.footnote)).foregroundStyle(.secondary) }
                    if let note = item.note { Text(L(note)).font(.ui(.footnote)).foregroundStyle(.secondary) }
                    if let url = URL(string: item.url), !item.url.isEmpty {
                        Link(item.url, destination: url).font(.ui(.footnote)).lineLimit(1).truncationMode(.middle)
                    }
                }
                ForEach(texts.indices, id: \.self) { index in
                    // 许可原文照原样（英文）显示，等宽、能选中复制
                    Text(verbatim: texts[index])
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        #if !KITELINE_MAC
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// App 里打包的第三方组件清单：{generated, components: [{name, version, license, url, note?, texts: [下标]}], texts: [原文]}
/// （同一份原文多个组件共用，按下标引用）
struct ThirdPartyNotices {
    struct Component: Identifiable {
        let id: Int
        let name: String
        let version: String
        let license: String
        let url: String
        let note: String?
        let texts: [Int]

        /// 「版本 · 许可」
        var summary: String { [version, license].filter { !$0.isEmpty }.joined(separator: " · ") }
    }

    var components: [Component] = []
    var texts: [String] = []

    func texts(for item: Component) -> [String] {
        item.texts.compactMap { texts.indices.contains($0) ? texts[$0] : nil }
    }

    static func bundled() -> ThirdPartyNotices {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ThirdPartyNotices() }
        let rows = object["components"] as? [[String: Any]] ?? []
        return ThirdPartyNotices(
            components: rows.enumerated().map { index, row in
                Component(id: index, name: row["name"] as? String ?? "", version: row["version"] as? String ?? "",
                          license: row["license"] as? String ?? "", url: row["url"] as? String ?? "",
                          note: row["note"] as? String, texts: row["texts"] as? [Int] ?? [])
            },
            texts: object["texts"] as? [String] ?? [])
    }
}
