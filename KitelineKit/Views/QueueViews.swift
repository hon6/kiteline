import SwiftUI

/// 输入框上方的排队列表：Claude 正忙时发的消息先排在这里，等它做完当前这一步（正在跑的工具）再读到。
/// 每条可以上移、下移、编辑、删除；最右边「强插」= 中断 Claude 当前这一步，排队的消息马上发送（这一条排到最前）。
/// 参照 Cursor 的排队样式；Windows / Linux 客户端（desktop/client/Views/QueueStrip.cs）、小程序（pages/chat）同一套布局和图标
struct QueueStrip: View {
    @Environment(AppModel.self) private var model
    let key: String
    let session: SessionInfo?
    let chat: ChatStore
    @Environment(\.chatWidth) private var chatWidth
    @State private var editing: String?
    @State private var draft = ""
    @State private var busy: String?
    @FocusState private var focused: Bool

    #if os(macOS)
    private static let corner: CGFloat = 12
    private static let button: CGFloat = 24
    #else
    private static let corner: CGFloat = 14
    private static let button: CGFloat = 30
    #endif

    var body: some View {
        let rows = chat.queueRows(session)
        if !rows.isEmpty {
            VStack(spacing: 0) {
                header(count: rows.count)
                if !chat.queueCollapsed {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5).padding(.leading, 12)
                        line(row, index: index, count: rows.count)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            #if os(macOS)
            // 同任务进展条：白底细边、浅阴影，最宽 832 居中
            .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).hairlineBorder(MacPalette.separator).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
            .frame(maxWidth: 832)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            #else
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).hairlineBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .padding(.horizontal, 10)
            #endif
            .animation(.snappy(duration: 0.22), value: rows)
            .animation(.snappy(duration: 0.22), value: chat.queueCollapsed)
        }
    }

    /// 标题行：⏱ 排队中 N 条 · Claude 完成当前这一步后读到 …… ⌄
    private func header(count: Int) -> some View {
        Button { chat.queueCollapsed.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.app(size: 11, weight: .semibold))
                Text(L("排队中 %@ 条", "\(count)")).fontWeight(.semibold)
                if chatWidth == 0 || chatWidth >= 340 {
                    Text(L("Claude 完成当前这一步后读到")).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.app(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(chat.queueCollapsed ? 180 : 0))
            }
            .font(.ui(.footnote))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chat.queueCollapsed ? L("展开") : L("收起"))
    }

    @ViewBuilder
    private func line(_ row: ChatStore.QueueRow, index: Int, count: Int) -> some View {
        if editing == row.id {
            editor(row)
        } else {
            HStack(spacing: 2) {
                Text(row.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                    .font(.ui(.subheadline))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 6)
                if row.editable {
                    icon("arrow.up", L("上移"), disabled: index == 0) { act(row, "move", dir: -1) }
                    icon("arrow.down", L("下移"), disabled: index == count - 1) { act(row, "move", dir: 1) }
                    icon("pencil", L("编辑")) {
                        draft = row.text
                        editing = row.id
                        focused = true
                    }
                    icon("trash", L("删除")) { act(row, "delete") }
                }
                // 强插：一个实心圆圈里一个上箭头（11-11），主题色
                Button { act(row, "now") } label: {
                    Group {
                        if busy == row.id { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.up.circle.fill").font(.app(size: 19, weight: .regular)).foregroundStyle(Theme.claude) }
                    }
                    .frame(width: Self.button, height: Self.button)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
                .disabled(busy != nil)
                .help(L("中断 Claude 当前这一步，排队的消息马上发送"))
                .accessibilityLabel(L("强插"))
                .accessibilityHint(L("中断 Claude 当前这一步，排队的消息马上发送"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(minHeight: 36)
        }
    }

    /// 编辑：多行输入框 + 取消 / 保存
    private func editor(_ row: ChatStore.QueueRow) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(L("消息内容"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.ui(.subheadline))
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                Button(L("取消")) { editing = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button(L("保存")) {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    editing = nil
                    if !text.isEmpty, text != row.text { act(row, "edit", text: text) }
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.claude)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.ui(.footnote))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func icon(_ symbol: String, _ label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.button, height: Self.button)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy != nil)
        .opacity(disabled ? 0.3 : 1)
        .help(label)
        .accessibilityLabel(label)
    }

    private func act(_ row: ChatStore.QueueRow, _ action: String, text: String? = nil, dir: Int? = nil) {
        if action == "now" { busy = row.id }
        Task {
            await model.queueAction(key, row.id, action, text: text, dir: dir)
            if action == "now" { busy = nil }
        }
    }
}
