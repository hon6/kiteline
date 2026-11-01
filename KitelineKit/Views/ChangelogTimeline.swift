import SwiftUI

// MARK: - 更新记录：解析

/// 更新记录里的一个版本：CHANGELOG.md 的「## 3.44.0（2026-10-22）」，下面按「### 新功能 / 改进 / 问题修复 / 安全」分类列条目。
/// iPhone（设置 → 关于 → 更新记录，读电脑端 /api/changelog）和 Mac（设置 → 关于 → 更新记录，经 KitelineKit 读 App 里打包的那份）共用这份解析和时间轴
struct ChangelogRelease: Identifiable {
    var version: String
    /// 「2026-10-22」；最早的几版没写日期
    var date: String
    /// 分类之前的说明段落（早期版本只有一句话、没有条目）
    var notes: [String] = []
    var sections: [ChangelogSection] = []
    var id: String { version }
}

struct ChangelogSection: Identifiable {
    /// 新功能 / 改进 / 问题修复 / 安全；没写分类的条目归在标题为空的一组
    var title: String
    var items: [ChangelogItem] = []
    var id: String { title }
}

struct ChangelogItem: Identifiable {
    var id: Int
    /// 条目原文（续行已接上）：「**标题**：说明」或一整句
    var raw: String
    var details: [String] = []

    /// 「**标题**：说明」拆成标题和说明；标题后紧跟的「（iPhone、Mac）」算标题的一部分。没有加粗标题的整条都是说明
    var parts: (title: String?, body: String) {
        guard raw.hasPrefix("**"), let close = raw.range(of: "**", range: raw.index(raw.startIndex, offsetBy: 2)..<raw.endIndex) else {
            return (nil, raw)
        }
        var title = String(raw[raw.index(raw.startIndex, offsetBy: 2)..<close.lowerBound])
        var rest = raw[close.upperBound...]
        // 中文版「（iPhone、Mac）」、英文版「 (iPhone, Mac)」
        let tag = rest.drop { $0 == " " }
        if let open = tag.first, open == "（" || open == "(", let end = tag.firstIndex(of: open == "（" ? "）" : ")") {
            title += (open == "(" ? " " : "") + tag[...end]
            rest = tag[tag.index(after: end)...]
        }
        if let first = rest.first, "：:".contains(first) { rest = rest.dropFirst() }
        return (title, rest.trimmingCharacters(in: .whitespaces))
    }
}

enum Changelog {
    /// 只认这份文件自己的写法：「## 版本（日期）」「### 分类」「- 条目」「  - 子条目」，缩进的续行接到上一条后面；
    /// 「# 标题」和 <!-- 注释 --> 不显示
    static func parse(_ markdown: String) -> [ChangelogRelease] {
        enum Target { case none, note, item, detail }
        var releases: [ChangelogRelease] = []
        var target = Target.none
        var inComment = false
        var nextID = 0

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inComment {
                if line.contains("-->") { inComment = false }
                continue
            }
            if line.hasPrefix("<!--") {
                inComment = !line.contains("-->")
                continue
            }
            if line.isEmpty {
                if target == .note { target = .none }
                continue
            }
            if line.hasPrefix("## ") {
                releases.append(header(String(line.dropFirst(3))))
                target = .none
                continue
            }
            guard !line.hasPrefix("# "), let r = releases.indices.last else { continue }
            if line.hasPrefix("### ") {
                releases[r].sections.append(ChangelogSection(title: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
                target = .none
                continue
            }
            let indented = raw.prefix(while: { $0 == " " || $0 == "\t" }).count >= 2
            let hasItem = releases[r].sections.last?.items.isEmpty == false
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if indented, target == .item || target == .detail, hasItem {
                    let s = releases[r].sections.count - 1
                    let i = releases[r].sections[s].items.count - 1
                    releases[r].sections[s].items[i].details.append(text)
                    target = .detail
                } else {
                    if releases[r].sections.isEmpty { releases[r].sections.append(ChangelogSection(title: "")) }
                    releases[r].sections[releases[r].sections.count - 1].items.append(ChangelogItem(id: nextID, raw: text))
                    nextID += 1
                    target = .item
                }
                continue
            }
            // 续行：缩进的接到上一条（或它的子条目）后面；顶格的是说明段落
            if indented, hasItem, target == .item || target == .detail {
                let s = releases[r].sections.count - 1
                let i = releases[r].sections[s].items.count - 1
                if target == .detail, let d = releases[r].sections[s].items[i].details.indices.last {
                    releases[r].sections[s].items[i].details[d] = join(releases[r].sections[s].items[i].details[d], line)
                } else {
                    releases[r].sections[s].items[i].raw = join(releases[r].sections[s].items[i].raw, line)
                }
            } else if target == .note, let n = releases[r].notes.indices.last {
                releases[r].notes[n] = join(releases[r].notes[n], line)
            } else {
                releases[r].notes.append(line)
                target = .note
            }
        }
        return releases
    }

    /// 「3.44.0（2026-10-22）」→ 版本、日期；括号里日期后面的附注不显示
    private static func header(_ text: String) -> ChangelogRelease {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(where: { $0 == "（" || $0 == "(" }) else {
            return ChangelogRelease(version: trimmed, date: "")
        }
        let version = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let inside = trimmed[trimmed.index(after: open)...].prefix { $0 != "）" && $0 != ")" }
        let first = inside.split(whereSeparator: { "，,·".contains($0) }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let isDate = first.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil
        return ChangelogRelease(version: version, date: isDate ? first : "")
    }

    /// 续行接上：英文、数字之间补一个空格，中文直接接
    private static func join(_ base: String, _ more: String) -> String {
        guard let a = base.last, let b = more.first else { return base + more }
        let wordy: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || ",.;:)".contains($0)) }
        return base + (wordy(a) && wordy(b) ? " " : "") + more
    }

    /// 「2026-10-22」→「2026 年 10 月 22 日」
    static func displayDate(_ date: String) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return date }
        return L("%@ 年 %@ 月 %@ 日", "\(parts[0])", "\(parts[1])", "\(parts[2])")
    }
}

// MARK: - 时间轴

/// 更新记录的时间轴：左边一条竖线串起各版本，节点对齐版本号；当前版本的节点用强调色并标「当前版本」（找不到就标最新一版）。
/// 版本之间、分类之间、条目之间都留足间距，长篇也好读
struct ChangelogTimeline: View {
    let releases: [ChangelogRelease]
    let current: String

    var body: some View {
        let marked = releases.contains { $0.version == current } ? current : releases.first?.version
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(releases.indices, id: \.self) { i in
                ChangelogReleaseRow(release: releases[i], isCurrent: releases[i].version == marked,
                                    isFirst: i == 0, isLast: i == releases.count - 1)
            }
        }
        .textSelection(.enabled)
    }
}

private enum Rail {
    /// 左边时间轴这一列的宽
    static let width: CGFloat = 22
    /// 时间轴和内容之间
    static let gap: CGFloat = 14
    /// 竖线在节点上下各断开这么多，节点不压线
    static let clearance: CGFloat = 5
    /// 版本和版本之间
    static let releaseSpacing: CGFloat = 52
}

/// 版本号那一行的中心：节点和它对齐（字号、字体怎么换都对得上）
private struct TitleCenter: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil
    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) { value = value ?? nextValue() }
}

private struct ChangelogReleaseRow: View {
    let release: ChangelogRelease
    let isCurrent: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !release.notes.isEmpty || !release.sections.isEmpty {
                content.padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Rail.width + Rail.gap)
        .padding(.bottom, isLast ? 8 : Rail.releaseSpacing)
        .backgroundPreferenceValue(TitleCenter.self) { anchor in
            GeometryReader { proxy in
                let y = anchor.map { proxy[$0].y } ?? 14
                let radius: CGFloat = isCurrent ? 11 : 5
                ZStack(alignment: .topLeading) {
                    if !isFirst {
                        line(from: 0, to: y - radius - Rail.clearance)
                    }
                    if !isLast {
                        line(from: y + radius + Rail.clearance, to: proxy.size.height)
                    }
                    node.position(x: Rail.width / 2, y: y)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                Text(release.version)
                    .font(.app(size: 21, weight: .semibold))
                    .foregroundStyle(.primary)
                    .anchorPreference(key: TitleCenter.self, value: .center) { $0 }
                if isCurrent {
                    Text("当前版本")
                        .font(.ui(.caption2).weight(.semibold))
                        .foregroundStyle(Theme.claude)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.iconTile, in: Capsule())
                }
            }
            if !release.date.isEmpty {
                Text(Changelog.displayDate(release.date))
                    .font(.ui(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(release.notes.indices, id: \.self) { i in
                Text(inline(release.notes[i]))
                    .font(.ui(.subheadline))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(release.sections) { section in
                VStack(alignment: .leading, spacing: 16) {
                    if !section.title.isEmpty {
                        SectionTitle(title: section.title)
                    }
                    ForEach(section.items) { item in
                        ItemRow(item: item)
                    }
                }
            }
        }
    }

    private func line(from top: CGFloat, to bottom: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1.5, height: max(0, bottom - top))
            .offset(x: Rail.width / 2 - 0.75, y: top)
    }

    @ViewBuilder
    private var node: some View {
        if isCurrent {
            ZStack {
                Circle().fill(Theme.claude.opacity(0.16)).frame(width: 22, height: 22)
                Circle().fill(Theme.claude).frame(width: 10, height: 10)
            }
        } else {
            Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5).frame(width: 10, height: 10)
        }
    }
}

/// 分类标题：新功能 / 改进 / 问题修复 / 安全，单色小图标 + 字
private struct SectionTitle: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: Self.symbol(title))
        }
        .font(.ui(.footnote).weight(.semibold))
        .foregroundStyle(.secondary)
        .labelStyle(SpacedLabel())
    }

    static func symbol(_ title: String) -> String {
        switch title {
        // 中文版、英文版（CHANGELOG.en.md）的分类名
        case "新功能", "New Features": "sparkles"
        case "改进", "Improvements": "arrow.up.circle"
        case "问题修复", "Bug Fixes": "wrench.and.screwdriver"
        case "安全", "Security": "lock.shield"
        case "移除", "Removed": "minus.circle"
        default: "circle.grid.2x2"
        }
    }
}

private struct SpacedLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// 一条：有加粗标题的，标题一行、说明在下面（次要色）；没有标题的整句用正文色。子条目缩进、字小一号
private struct ItemRow: View {
    let item: ChangelogItem

    var body: some View {
        let parts = item.parts
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•")
                .font(.ui(.subheadline))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 6) {
                if let title = parts.title {
                    Text(inline(title))
                        .font(.ui(.subheadline).weight(.semibold))
                        .foregroundStyle(.primary)
                }
                if !parts.body.isEmpty {
                    Text(inline(parts.body))
                        .font(.ui(.subheadline))
                        .foregroundStyle(parts.title == nil ? .primary : .secondary)
                        .lineSpacing(4)
                }
                if !item.details.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(item.details.indices, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("–").foregroundStyle(.tertiary)
                                Text(inline(item.details[i]))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                            }
                            .font(.ui(.footnote))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 条目里的行内 markdown：**加粗**、`代码`、[链接](…)
private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}
