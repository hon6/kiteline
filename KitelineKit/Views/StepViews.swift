import SwiftUI

/// 一串连续的步骤（思考、工具调用），装在一张卡片里；很多步时前面的折成一行
struct StepsCard: View {
    @Environment(AppModel.self) private var model
    let key: String
    let groupId: String
    let steps: [Step]
    let hidden: Int
    @State private var openStep: Step?

    var body: some View {
        let _ = PerfTrace.body("StepsCard")
        VStack(alignment: .leading, spacing: 0) {
            if hidden > 0 {
                Button {
                    withAnimation(.snappy) { _ = model.chat(key).expanded.insert(groupId) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis").frame(width: 16)
                        Text("展开前 \(hidden) 步")
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: ChatType.size * 0.75))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ChatType.padH)
                    .padding(.vertical, ChatType.px(4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.steady(.plain))
            }
            // 工具调用列表：一行一个，不画分隔线；行上下各 4、卡片上下再 4，第一行字离卡片顶 8（同气泡）
            // 结果带图的（读图片、截图）图直接显示在那一步下面；点开看大图时，这张卡片里所有步骤的图左右滑着连着看
            let gallery = steps.flatMap { $0.result?.images ?? [] }
            ForEach(steps.dropFirst(hidden), id: \.id) { step in
                StepRow(step: step, key: key, gallery: gallery) { openStep = step }
            }
        }
        .padding(.vertical, ChatType.px(4))
        .background(Theme.botBubble, in: RoundedRectangle(cornerRadius: ChatType.radius, style: .continuous))
        .sheetPanel(item: $openStep) { step in
            ToolDetailView(key: key, step: step)
        }
    }
}

struct StepRow: View {
    let step: Step
    var key = ""
    /// 点开图片后能左右滑着看的一组（整张步骤卡片的图）
    var gallery: [ChatImage] = []
    let open: () -> Void
    #if SNAPSHOT
    // 截图版：TARS_DEMO_THINK=1 思考一开始就展开（看长思考底下的「收起思考」）
    @State private var expanded = ProcessInfo.processInfo.environment["TARS_DEMO_THINK"] == "1"
    #else
    @State private var expanded = false
    #endif

    var body: some View {
        let item = step.item
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if item.t == "thinking" { withAnimation(.snappy) { expanded.toggle() } } else { open() }
            } label: {
                // 照 VS Code：工具名粗体、和正文一样大；后面的参数 0.85em 等宽；思考是灰色斜体
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StateIcon(step: step).frame(width: 16).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + ChatType.size * 0.35 }
                    Text(name).fontWeight(.bold).lineLimit(1).layoutPriority(1)
                    Group {
                        if item.t == "tool" { Text(brief).font(ChatType.detail).fontDesign(nil) } else { Text(brief).italic() }
                    }
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let stat = item.t == "tool" ? Tools.diffStat(item) : nil {
                        HStack(spacing: 3) {
                            Text("+\(stat.added)").foregroundStyle(Theme.added)
                            Text("−\(stat.removed)").foregroundStyle(Theme.removed)
                        }
                        .font(ChatType.detail).fontDesign(nil)
                    }
                    Image(systemName: item.t == "thinking" && expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: ChatType.size * 0.75, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, ChatType.padH)
                .padding(.vertical, ChatType.px(4))
                .contentShape(Rectangle())
                .hoverHighlight()
            }
            .buttonStyle(.steady(.plain))
            if expanded, let text = item.text {
                // 照 VS Code：展开的思考内容和正文一样大、灰色，和标题行隔 4；左边和标题文字对齐（图标 16 + 间隔 6）
                // 用能拖选的系统文字控件（见 RichText）：Mac 上拖着选、iPhone 长按选，能复制其中一段
                RichText(text: RichBuilder.plain(text, tone: .secondary))
                    .environment(\.richMenu, [MenuAction(title: L("复制全部思考"), symbol: "doc.on.doc") { Clipboard.copy(text) }])
                    .padding(.horizontal, ChatType.padH)
                    .padding(.leading, 22)
                    .padding(.trailing, CopyCorner.reserve)
                    .padding(.top, ChatType.px(2))
                    .padding(.bottom, ChatType.px(4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .copyCorner(text, inset: ChatType.px(4))
                // 思考很长时展开后要翻回顶上才收得起来：底下也放一个「收起」
                Button { withAnimation(.snappy) { expanded = false } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up").font(.system(size: ChatType.size * 0.7, weight: .semibold))
                        Text("收起思考")
                    }
                    .font(.appFixed(size: ChatType.size * 0.85))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ChatType.padH)
                    .padding(.leading, 22)
                    .padding(.vertical, ChatType.px(4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.steady(.plain))
                .padding(.bottom, ChatType.px(2))
            }
            if item.t == "tool", let images = step.result?.images, !images.isEmpty {
                // 读图片、截图这类工具：结果里的图直接显示，不用点开这一步才看得到；左边和标题文字对齐
                MessageImages(key: key, images: images, gallery: gallery)
                    .padding(.horizontal, ChatType.padH)
                    .padding(.leading, 22)
                    .padding(.top, ChatType.px(2))
                    .padding(.bottom, ChatType.px(6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var name: String {
        switch step.item.t {
        case "thinking": return L("思考")
        case "result": return L("结果")
        default: return Tools.displayName(step.item.name)
        }
    }

    private var brief: String {
        let item = step.item
        if item.t == "tool" { return Tools.brief(item) }
        return String((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? "")
    }
}

/// 步骤左边的图标：没状态时是工具图标；在跑转圈、等你确认是橙点、成功绿点、出错红点
struct StateIcon: View {
    let step: Step

    var body: some View {
        switch step.state {
        case .none:
            if step.item.t == "thinking" {
                KiteMark(color: Theme.claude).frame(width: ChatType.size * 1.15, height: ChatType.size * 1.15)
            } else {
                Image(systemName: Tools.symbol(step.item.name)).font(.system(size: ChatType.size * 0.85)).foregroundStyle(.secondary)
            }
        case .running:
            PulseDot(color: Theme.claude, size: 7, low: 0.25, period: 0.7)
        case .waiting:
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        case .ok:
            Circle().fill(Theme.added).frame(width: 7, height: 7)
        case .failed:
            Circle().fill(Theme.removed).frame(width: 7, height: 7)
        }
    }
}

/// 点开一步：参数（命令、改动、计划……）+ 结果
struct ToolDetailView: View {
    let key: String
    let step: Step

    var body: some View {
        FitSheet(title: title, background: Theme.card) {
            VStack(alignment: .leading, spacing: 16) {
                if step.item.t == "tool" { ToolInput(item: step.item) }
                if step.item.t == "thinking" {
                    Section2(L("思考")) { MonoBlock(text: step.item.text ?? "") }
                } else {
                    ToolResult(key: key, result: step.result)
                }
            }
        }
    }

    private var title: String {
        let item = step.item
        if item.t == "result" { return L("工具结果") }
        if item.t == "thinking" { return L("思考") }
        let brief = Tools.brief(item)
        return Tools.displayName(item.name) + (brief.isEmpty ? "" : " · " + brief)
    }
}

/// 带小标题的一节
struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(.footnote)).foregroundStyle(.secondary).textCase(.uppercase)
            content
        }
    }
}

struct ToolInput: View {
    let item: ChatItem

    private var input: JSONValue? { item.input }
    private func field(_ key: String) -> String { input?[key]?.string ?? "" }

    var body: some View {
        switch item.name ?? "" {
        case "Bash":
            Section2(field("description").isEmpty ? L("命令") : field("description")) { MonoBlock(text: field("command")) }
        case "Edit":
            Section2(L("修改")) { DiffView(path: field("file_path"), old: field("old_string"), new: field("new_string")) }
        case "MultiEdit":
            Section2(L("修改")) {
                ForEach(Array((input?["edits"]?.array ?? []).enumerated()), id: \.offset) { index, edit in
                    DiffView(path: index == 0 ? field("file_path") : "", old: edit["old_string"]?.string ?? "", new: edit["new_string"]?.string ?? "")
                }
            }
        case "Write":
            Section2(L("写入文件")) { DiffView(path: field("file_path"), old: "", new: field("content"), limit: 300) }
        case "Read":
            let offset = field("offset"), limit = field("limit")
            Section2(L("读取")) { MonoBlock(text: field("file_path") + (offset.isEmpty ? "" : L("\n从第 %@ 行", "\(offset)") + (limit.isEmpty ? "" : L("起 %@ 行", "\(limit)")))) }
        case "Grep", "Glob":
            let lines = [field("pattern").isEmpty ? nil : L("模式：%@", "\(field("pattern"))"), field("path").isEmpty ? nil : L("位置：%@", "\(field("path"))"),
                         field("glob").isEmpty ? nil : L("文件：%@", "\(field("glob"))")].compactMap { $0 }
            Section2(L("搜索")) { MonoBlock(text: lines.joined(separator: "\n")) }
        case "WebFetch", "WebSearch":
            Section2(L("网络")) { MonoBlock(text: [field("url"), field("query"), field("prompt")].filter { !$0.isEmpty }.joined(separator: "\n\n")) }
        case "Task", "Agent":
            Section2(field("description").isEmpty ? L("子任务") : field("description")) { MarkdownView(field("prompt")) }
        case "AskUserQuestion":
            ForEach(Array((input?["questions"]?.array ?? []).enumerated()), id: \.offset) { _, q in
                Section2(q["header"]?.string ?? L("提问")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(q["question"]?.string ?? "").font(.ui(.body).weight(.semibold))
                        ForEach(Array((q["options"]?.array ?? []).enumerated()), id: \.offset) { index, option in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). \(option["label"]?.string ?? "")")
                                if let desc = option["description"]?.string, !desc.isEmpty {
                                    Text(desc).font(.ui(.footnote)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        case "ExitPlanMode":
            Section2(L("计划")) { MarkdownView(field("plan")) }
        case "TodoWrite":
            Section2(L("任务清单")) { TodoCard(todos: input?["todos"]?.array ?? []) }
        default:
            Section2(L("参数")) { MonoBlock(text: input?.pretty ?? "") }
        }
    }
}

struct ToolResult: View {
    let key: String
    let result: ChatItem?

    var body: some View {
        if let result {
            Section2(result.isError == true ? L("出错") : L("结果")) {
                VStack(alignment: .leading, spacing: 8) {
                    if let text = result.text, !text.isEmpty { MonoBlock(text: text, error: result.isError == true) }
                    if let images = result.images, !images.isEmpty { MessageImages(key: key, images: images) }
                    if (result.text ?? "").isEmpty, (result.images ?? []).isEmpty {
                        Text("（无输出）").font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                    if result.truncated == true {
                        Text("仅显示部分内容，完整输出共 \(result.fullLength.map(String.init) ?? "?") 字").font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Section2(L("结果")) { Text("暂无结果").font(.ui(.footnote)).foregroundStyle(.secondary) }
        }
    }
}

/// 改动：删的红、加的绿
struct DiffView: View {
    let path: String
    let old: String
    let new: String
    var limit = 2000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !path.isEmpty {
                Text(path).font(.ui(.caption).monospaced()).fontDesign(nil).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
            }
            let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
            let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
            ForEach(Array(oldLines.prefix(limit).enumerated()), id: \.offset) { _, line in
                DiffLine(text: line, sign: "-", color: Theme.removed)
            }
            ForEach(Array(newLines.prefix(limit).enumerated()), id: \.offset) { _, line in
                DiffLine(text: line, sign: "+", color: Theme.added)
            }
            if newLines.count > limit {
                Text("…共 \(newLines.count) 行").font(.ui(.caption)).foregroundStyle(.secondary).padding(8)
            }
        }
        .font(.app(size: 12, design: .monospaced)).fontDesign(nil)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.08)).allowsHitTesting(false))
    }
}

private struct DiffLine: View {
    let text: String
    let sign: String
    let color: Color

    var body: some View {
        Text("\(sign) \(text)")
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1))
    }
}
