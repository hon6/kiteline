import SwiftUI

/// 把 Claude 的 Markdown 画成原生排版。表格和代码都自动换行，不出现横向滚动
extension EnvironmentValues {
    /// 标题按正文大小画（只加粗）：横着的 iPhone 上确认框里的计划，地方小（10-27：字跟普通文字一样）
    @Entry var markdownFlatHeadings = false
}

struct MarkdownView: View {
    @Environment(\.markdownFlatHeadings) private var flat
    let blocks: [MarkdownBlock]
    /// 撑满给的宽度；对话气泡里传 false，宽度贴着最长的一行（有代码块、分隔线的照样撑满）
    var fill = true

    init(_ text: String, fill: Bool = true) { blocks = Markdown.blocks(text); self.fill = fill }
    init(blocks: [MarkdownBlock]) { self.blocks = blocks }

    var body: some View {
        let _ = PerfTrace.body("MarkdownView")
        // 块与块之间的空照浏览器的外边距合并：取上一块的下边距和这一块的上边距里大的那个（第一块顶上不留）
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : max(Self.margin(blocks[index - 1], flat).bottom, Self.margin(block, flat).top))
            }
        }
        .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
        // 行内代码（Menlo）别被「外观 → 字体」换掉：根视图上的 fontDesign 连明确写的等宽字也会改；正文本来就明确用了选的字体
        .fontDesign(nil)
    }

    // 排版大体照 VS Code 里的 Claude Code（见 ChatType）：列表、引用上下 1em；代码块上下 10；
    // 段落之间 VS Code 只空 0.2em，几段连在一起像一整块（10-22 反馈挤），改成 0.7em；
    // 标题按浏览器默认（字号 2 / 1.5 / 1.17 / 1 / 0.83 / 0.67em，上下各 0.67 / 0.83 / 1 / 1.33 / 1.67 / 2.33 倍自己的字号）；分隔线上下 0.5em

    private static func headingSize(_ level: Int, _ flat: Bool = false) -> CGFloat {
        flat ? ChatType.size : ChatType.size * [2, 1.5, 1.17, 1, 0.83, 0.67][min(max(level, 1), 6) - 1]
    }

    private static func margin(_ block: MarkdownBlock, _ flat: Bool = false) -> (top: CGFloat, bottom: CGFloat) {
        let em = ChatType.size
        switch block {
        case .paragraph: return (0.1 * em, 0.7 * em)
        case .heading(let level, _):
            if flat { return (0.4 * em, 0.3 * em) }
            let m = headingSize(level) * [0.67, 0.83, 1, 1.33, 1.67, 2.33][min(max(level, 1), 6) - 1]
            return (m, m)
        case .code: return (ChatType.px(10), ChatType.px(10))
        case .quote, .list: return (em, em)
        case .table: return (0.4 * em, 0.7 * em)
        case .rule: return (0.5 * em, 0.5 * em)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        let em = ChatType.size
        switch block {
        case .paragraph(let text):
            Text(Markdown.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            let size = Self.headingSize(level, flat)
            Text(Markdown.inline(text))
                .font(.appFixed(size: size, weight: .bold))
                .lineSpacing(ChatType.lineSpacing(size))
                .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            Text(code)
                .font(ChatType.code).fontDesign(nil)
                .lineSpacing(ChatType.lineSpacing(ChatType.codeSize))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ChatType.px(12))
                .padding(.trailing, CopyCorner.reserve)
                .padding(.vertical, ChatType.px(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: ChatType.px(6), style: .continuous))
                .copyCorner(code, inset: ChatType.px(5))
        case .quote(let inner):
            // 浏览器默认的引用：左边缩进 40，不画竖线
            MarkdownView(blocks: inner).padding(.leading, 40)
        case .list(_, let items):
            // 缩进 2em：序号 / 圆点放在这 2em 里靠右，正文从 2em 处开始；项与项之间空 0.3em（只靠 1.5 倍行高，折行的项连成一片）
            VStack(alignment: .leading, spacing: 0.3 * em) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 2 * em - 6, alignment: .trailing)
                        Text(Markdown.inline(item.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 2 * em)
                }
            }
        case .table(let header, let rows):
            // 不用 Grid：放在消息行的 HStack 里时，Grid 报的高度是按另一个列宽算的，实际字折行更多、画得更高，
            // 压到下一条消息上，最后一条还会躲到输入框底下滑不出来
            // 字和正文一样大；列与列隔 12、行与行隔 6（照 VS Code 的 5 太挤，几列数字连成一串）。
            // 放不下时列距先收到 5，还放不下才折行
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            TableLayout(columns: columns, hSpacing: ChatType.px(12), minHSpacing: ChatType.px(5), vSpacing: ChatType.px(6)) {
                ForEach(0..<columns, id: \.self) { c in
                    Text(Markdown.inline(c < header.count ? header[c] : "")).bold()
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    ForEach(0..<columns, id: \.self) { c in
                        Text(Markdown.inline(c < row.count ? row[c] : ""))
                    }
                }
            }
            .padding(.horizontal, ChatType.px(8))
            .padding(.vertical, ChatType.px(8))
            .background(Theme.code.opacity(0.6), in: RoundedRectangle(cornerRadius: ChatType.px(6), style: .continuous))
        case .rule:
            Divider()
        }
    }
}

/// Markdown 表格的排版。子视图依次是：表头 columns 个格子、一条分隔线、每行 columns 个格子。
/// 每次都按给的宽度现算列宽和行高（不缓存），报出去的尺寸和实际画的一定一致。
/// 列宽：放得下就按内容宽；放不下时先把列距从 hSpacing 收到 minHSpacing，还放不下，内容窄的列保持原宽，其余列平分剩下的宽度（同 Grid 的样子）。
private struct TableLayout: Layout {
    let columns: Int
    var hSpacing: CGFloat = 10
    var minHSpacing: CGFloat = 10
    var vSpacing: CGFloat = 6

    private struct Metrics {
        var widths: [CGFloat]
        /// 实际用的列距
        var gap: CGFloat
        /// 每一行（第 0 行是表头）的高度
        var heights: [CGFloat]
        var divider: CGFloat
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 按父视图给的同一个宽度重算，不用 bounds.width：取整后差零点几会让最宽的一列多折一行
        let m = measure(proposal.width ?? bounds.width, subviews)
        var y = bounds.minY
        for r in m.heights.indices {
            var x = bounds.minX
            for c in 0..<columns {
                // 同 Grid(alignment: .leading)：格子靠左、在这一行里上下居中
                subviews[cellIndex(r, c)].place(at: CGPoint(x: x, y: y + m.heights[r] / 2), anchor: .leading,
                                                proposal: ProposedViewSize(width: m.widths[c], height: nil))
                x += m.widths[c] + m.gap
            }
            y += m.heights[r] + vSpacing
            if r == 0 {
                subviews[columns].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                                        proposal: ProposedViewSize(width: m.size.width, height: m.divider))
                y += m.divider + vSpacing
            }
        }
    }

    private func cellIndex(_ row: Int, _ column: Int) -> Int {
        row == 0 ? column : columns + 1 + (row - 1) * columns + column
    }

    private func measure(_ width: CGFloat?, _ subviews: Subviews) -> Metrics {
        let rowCount = columns > 0 ? (subviews.count - 1) / columns : 0
        guard rowCount > 0 else { return Metrics(widths: [], gap: hSpacing, heights: [], divider: 0, size: .zero) }
        // 每列不换行时要多宽
        var widths = [CGFloat](repeating: 0, count: columns)
        for r in 0..<rowCount {
            for c in 0..<columns {
                widths[c] = max(widths[c], subviews[cellIndex(r, c)].sizeThatFits(.unspecified).width)
            }
        }
        var gap = hSpacing
        if let width, columns > 1, widths.reduce(0, +) + gap * CGFloat(columns - 1) > width + 0.5 {
            gap = max(minHSpacing, min(hSpacing, (width - widths.reduce(0, +)) / CGFloat(columns - 1)))
        }
        let spacing = gap * CGFloat(columns - 1)
        if let width, widths.reduce(0, +) + spacing > width + 0.5 {
            let ideal = widths
            var open = Set(0..<columns)
            var remaining = max(0, width - spacing)
            while !open.isEmpty {
                let share = remaining / CGFloat(open.count)
                let narrow = open.filter { ideal[$0] <= share }
                if narrow.isEmpty {
                    for c in open { widths[c] = share }
                    break
                }
                for c in narrow {
                    remaining -= ideal[c]
                    open.remove(c)
                }
            }
        }
        var heights = [CGFloat](repeating: 0, count: rowCount)
        for r in 0..<rowCount {
            for c in 0..<columns {
                let size = subviews[cellIndex(r, c)].sizeThatFits(ProposedViewSize(width: widths[c], height: nil))
                heights[r] = max(heights[r], size.height)
            }
        }
        let tableWidth = widths.reduce(0, +) + spacing
        let divider = subviews[columns].sizeThatFits(ProposedViewSize(width: tableWidth, height: nil)).height
        // 表头、分隔线、各行一共 rowCount + 1 项，中间 rowCount 个间距
        let height = heights.reduce(0, +) + divider + vSpacing * CGFloat(rowCount)
        return Metrics(widths: widths, gap: gap, heights: heights, divider: divider, size: CGSize(width: tableWidth, height: height))
    }
}
