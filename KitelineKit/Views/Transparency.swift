import SwiftUI

// 过程透明化（11-26）：对话里工具调用的风险标签和改动预览、上下文构成、撤回某一轮起的改动。
// 数据都由电脑端的 watcher 算好（tool_risk / session_context / rewind_plan），这里只负责显示。iPhone、iPad、Mac 共用。

/// 风险标签：watcher 的 tool_risk 给的代号 → 文字、级别。2 级（不易撤回、影响外部）用橙色，1 级（值得知道）灰色
enum RiskTag {
    static func label(_ code: String) -> String {
        switch code {
        case "delete", "delete_ask": return L("删除文件")
        case "rewrite", "rewrite_ask": return L("改写 Git 历史")
        case "remote_exec": return L("执行下载的脚本")
        case "db": return L("改动数据库")
        case "disk": return L("磁盘操作")
        case "secret_write": return L("改动密钥文件")
        case "system": return L("改动系统配置")
        case "deploy": return L("改动线上资源")
        case "perm": return L("修改权限")
        case "os": return L("系统服务")
        case "push": return L("推送")
        case "install": return L("安装软件")
        case "kill": return L("结束进程")
        case "sudo": return L("管理员权限")
        case "secret": return L("读取密钥")
        default: return code
        }
    }

    /// 点开那一步时的一句说明
    static func explain(_ code: String) -> String {
        switch code {
        case "delete": return L("递归删除受保护的位置（主目录、系统目录、.git 等），删除后难以恢复")
        case "delete_ask": return L("递归删除项目之外或无法确定的位置")
        case "rewrite": return L("强制推送或删除主分支，会改写共享的 Git 历史")
        case "rewrite_ask": return L("丢弃本地改动或改写分支历史（reset --hard、强制推送到其他分支等）")
        case "remote_exec": return L("下载内容后直接交给 shell 执行")
        case "db": return L("删除数据库对象或清空数据")
        case "disk": return L("格式化、覆盖磁盘或彻底擦除文件")
        case "secret_write": return L("修改存放密钥、令牌的文件")
        case "system": return L("修改系统目录或登录配置（如 /etc、~/.zshrc、~/.ssh）")
        case "deploy": return L("删除或变更云服务、集群上的资源")
        case "perm": return L("放宽文件权限（777、setuid）")
        case "os": return L("改动注册表、系统服务、计划任务或关机")
        case "push": return L("把提交推送到远端仓库或发布出去")
        case "install": return L("在这台电脑上全局安装软件")
        case "kill": return L("结束其他进程")
        case "sudo": return L("以管理员身份运行")
        case "secret": return L("读取存放密钥、令牌的文件")
        default: return ""
        }
    }

    static func high(_ code: String) -> Bool {
        ["delete", "rewrite", "remote_exec", "db", "disk", "secret_write", "system"].contains(code)
    }

    /// 同一件事的两个级别只显示一个（watcher 已去重，这里再保险）、最多 limit 个
    static func shown(_ codes: [String]?, limit: Int = 2) -> [String] {
        var seen = Set<String>()
        return (codes ?? []).filter { seen.insert(label($0)).inserted }.prefix(limit).map { $0 }
    }
}

/// 一串风险小标签（步骤行右侧、确认卡片上）
struct RiskChips: KLView {
    let codes: [String]
    var size: CGFloat = ChatType.size * 0.72

    var klBody: some View {
        HStack(spacing: 4) {
            ForEach(codes, id: \.self) { code in
                let high = RiskTag.high(code)
                HStack(spacing: 3) {
                    if high { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size * 0.85)) }
                    Text(RiskTag.label(code)).lineLimit(1)
                }
                .font(.app(size: size, weight: .medium))
                .foregroundStyle(high ? Color.orange : Color.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background((high ? Color.orange.opacity(0.12) : Color.primary.opacity(0.06)), in: Capsule())
                .fixedSize()
            }
        }
    }
}

/// 步骤行下面的预览：改代码的前几行改动、命令出错时的最后两行输出（不用点开就知道改了什么、错在哪）
struct StepPreview: KLView {
    let step: Step

    var klBody: some View {
        if let lines = Self.lines(step), !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(line.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.app(size: ChatType.size * 0.78, design: .monospaced)).klFontDesign(nil)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    struct Line { let text: String; let color: Color }

    /// 预览哪几行：Edit / MultiEdit / Write 取改动的前三行；命令出错取输出最后两行；别的不预览
    static func lines(_ step: Step) -> [Line]? {
        let item = step.item
        guard item.t == "tool" else { return nil }
        func field(_ value: JSONValue?, _ key: String) -> String { value?[key]?.string ?? "" }
        switch item.name ?? "" {
        case "Edit", "MultiEdit":
            let pairs: [(String, String)] = item.name == "Edit"
                ? [(field(item.input, "old_string"), field(item.input, "new_string"))]
                : (item.input?["edits"]?.array ?? []).map { (field($0, "old_string"), field($0, "new_string")) }
            var out: [Line] = []
            for (old, new) in pairs {
                let oldLines = old.components(separatedBy: "\n"), newLines = new.components(separatedBy: "\n")
                let kept = Set(oldLines).intersection(newLines)
                let removed = oldLines.filter { !kept.contains($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let added = newLines.filter { !kept.contains($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                out += removed.prefix(1).map { Line(text: "- " + $0.trimmingCharacters(in: .whitespaces), color: Theme.removed) }
                out += added.prefix(2).map { Line(text: "+ " + $0.trimmingCharacters(in: .whitespaces), color: Theme.added) }
                if out.count >= 3 { break }
            }
            return Array(out.prefix(3))
        case "Write":
            let content = field(item.input, "content").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return content.prefix(2).map { Line(text: "+ " + $0.trimmingCharacters(in: .whitespaces), color: Theme.added) }
        default:
            guard step.state == .failed || step.result?.isError == true, let text = step.result?.text else { return nil }
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.suffix(2).map { Line(text: $0, color: Theme.removed) }
        }
    }
}

// MARK: - 上下文构成

struct ContextReply: Decodable {
    var context: Int?
    var window: Int?
    var baseline: Int?
    var calls: Int?
    var compactedAt: Double?
    var since: Double?
    var parts: [Part]?
    var top: [Top]?
    var costUSD: Double?
    var unsupported: Bool?

    struct Part: Decodable, Hashable { var k: String; var tokens: Int; var count: Int; var share: Double }
    struct Top: Decodable, Hashable { var k: String; var label: String; var tokens: Int; var share: Double }

    static func kindName(_ k: String) -> String {
        switch k {
        case "system": return L("系统提示、工具定义与记忆")
        case "summary": return L("压缩后的摘要")
        case "you": return L("你的消息")
        case "reminder": return L("提醒与通知")
        case "reply": return L("回复")
        case "thinking": return L("思考")
        case "edit": return L("改代码")
        case "read": return L("读文件")
        case "bash": return L("命令与输出")
        case "search": return L("搜索")
        case "web": return L("网页")
        case "agent": return L("子 agent")
        case "mcp": return L("MCP 工具")
        case "image": return L("图片")
        default: return L("其他工具")
        }
    }
}

/// 点对话页的上下文百分比打开：现在的上下文被什么占着、这段上下文里谁最费钱；底部是压缩上下文
struct ContextSheet: KLView {
    @EnvModel private var model
    @PanelDismiss private var dismiss
    let key: String
    @State private var reply: ContextReply?
    @State private var failed: String?

    var klBody: some View {
        let session = model.session(key)
        FitSheet(title: L("上下文构成"), background: Theme.card) {
            VStack(alignment: .leading, spacing: 16) {
                if let reply, reply.unsupported != true {
                    summary(reply)
                    if let parts = reply.parts, !parts.isEmpty {
                        Section2(L("各部分")) {
                            VStack(spacing: 10) { ForEach(parts, id: \.self) { row($0, total: max(1, reply.context ?? 1)) } }
                        }
                    }
                    if let top = reply.top, !top.isEmpty {
                        Section2(L("占得最多的几项")) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(top.prefix(8), id: \.self) { item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(item.label).font(ChatType.detail).klFontDesign(nil).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 8)
                                        Text(Format.tokens(item.tokens)).font(.ui(.footnote).monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Text(L("数字为估算：总量是 Claude 报的实际用量，各部分按内容字数估算后按比例分配。花费占比按「进入上下文后每次请求都要再读一遍」计算，越早进来、越大的内容越费钱。只统计最近一次压缩之后的部分。"))
                        .font(.ui(.footnote)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if reply?.unsupported == true {
                    Text("这个会话不支持查看上下文构成").foregroundStyle(.secondary)
                } else if let failed {
                    Text(failed).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            }
        } bottom: {
            if session?.can("compact") == true {
                VStack(spacing: 8) {
                    Button {
                        _ = model.send(key, text: "/compact", images: [])
                        dismiss()
                    } label: {
                        Text("压缩上下文").font(.ui(.body).weight(.semibold)).foregroundStyle(Theme.claude)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(Theme.claude.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    Text(L("等同于在 Claude Code 中输入 /compact：将此前的对话总结为摘要以释放空间，部分细节可能丢失"))
                        .font(.ui(.caption)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .task { await load() }
    }

    private func summary(_ reply: ContextReply) -> some View {
        let used = reply.context ?? 0, window = max(1, reply.window ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.tokens(used)).font(.app(size: 28, weight: .semibold).monospacedDigit())
                Text(L("/ %@ token", Format.tokens(window))).foregroundStyle(.secondary)
                Spacer()
                Text("\(min(100, used * 100 / window))%").font(.ui(.title3).monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Theme.claude).frame(width: geo.size.width * min(1, CGFloat(used) / CGFloat(window)))
                }
            }
            .frame(height: 6)
            let calls = reply.calls ?? 0
            let cost = reply.costUSD.map { String(format: "$%.2f", $0) }
            Text([calls > 0 ? L("这段上下文已请求 %lld 次", calls) : nil, cost.map { L("累计约 %@（估算）", $0) }].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(.footnote)).foregroundStyle(.secondary)
        }
    }

    private func row(_ part: ContextReply.Part, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(ContextReply.kindName(part.k)).font(.ui(.subheadline))
                if part.k != "system", part.count > 1 { Text(L("%lld 次", part.count)).font(.ui(.caption)).foregroundStyle(.tertiary) }
                Spacer()
                Text(Format.tokens(part.tokens)).font(.ui(.subheadline).monospacedDigit())
                Text(L("花费 %lld%%", Int((part.share * 100).rounded()))).font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            GeometryReader { geo in
                Capsule().fill(Theme.claude.opacity(0.55)).frame(width: max(2, geo.size.width * CGFloat(part.tokens) / CGFloat(total)))
            }
            .frame(height: 4)
        }
    }

    private func load() async {
        do {
            reply = try await model.api.get(ContextReply.self, "/api/context", ["key": key])
        } catch {
            failed = L("读取失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - 撤回某一轮起的改动

struct RewindPlan: Decodable {
    var files: [File]?
    var turnIndex: Int?
    var note: String?
    var error: String?
    var nothing: Bool?
    var busy: Bool?

    struct File: Decodable, Hashable {
        var path: String
        var rel: String?
        var action: String
        var added: Int?
        var removed: Int?
        var missing: Bool?
        var binary: Bool?
    }
}

/// 用户消息长按「撤回这一轮起的改动」：先列出会动哪些文件，确认后撤回；撤回后能还原
struct RewindSheet: KLView {
    @EnvModel private var model
    @PanelDismiss private var dismiss
    let key: String
    let offset: Int
    @State private var plan: RewindPlan?
    @State private var failed: String?
    @State private var busy = false
    @State private var done: (count: Int, undo: String, failed: Int)?
    @State private var restored = false
    @State private var tell = true

    private var changes: [RewindPlan.File] { (plan?.files ?? []).filter { $0.action == "restore" || $0.action == "delete" } }

    var klBody: some View {
        FitSheet(title: L("撤回改动"), background: Theme.card, cancel: done == nil) {
            VStack(alignment: .leading, spacing: 14) {
                if let done {
                    Label(restored ? L("已还原到撤回之前") : L("已撤回 %lld 个文件", done.count),
                          systemImage: restored ? "arrow.uturn.forward.circle.fill" : "checkmark.circle.fill")
                        .font(.ui(.headline)).foregroundStyle(Theme.added)
                    if done.failed > 0 { Text(L("%lld 个文件没能恢复，请在电脑上检查", done.failed)).foregroundStyle(Theme.removed) }
                    if !restored {
                        Text(L("撤回前的样子已另存一份，点下面的按钮可以还原。")).font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                } else if let plan {
                    if let error = plan.error {
                        Text(error).foregroundStyle(.secondary)
                    } else if plan.nothing == true || changes.isEmpty {
                        Text(plan.note ?? L("这一轮之后的文件已经和改动前一样，不需要撤回")).foregroundStyle(.secondary)
                    } else {
                        Text(L("把第 %lld 轮开始后 Claude 改动的文件恢复到这一轮开始前的样子：", plan.turnIndex ?? 0))
                            .font(.ui(.subheadline)).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(changes, id: \.self) { file in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: file.action == "delete" ? "trash" : "arrow.uturn.backward")
                                        .font(.ui(.footnote)).foregroundStyle(file.action == "delete" ? Theme.removed : .secondary).frame(width: 16)
                                    Text(file.rel ?? file.path).font(ChatType.detail).klFontDesign(nil).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    if file.action == "delete" {
                                        Text("删除（这一轮新建的）").font(.ui(.caption)).foregroundStyle(.secondary)
                                    } else if let a = file.added, let r = file.removed {
                                        HStack(spacing: 3) {
                                            Text("+\(a)").foregroundStyle(Theme.added)
                                            Text("−\(r)").foregroundStyle(Theme.removed)
                                        }
                                        .font(ChatType.detail).klFontDesign(nil)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(L("只包括 Claude 用编辑工具改动的文件；在命令行中改动的（脚本生成、sed、Git 操作等）不在其中。撤回前会把这些文件现在的样子另存一份，可以还原。"))
                            .font(.ui(.footnote)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Toggle(L("撤回后告诉 Claude"), isOn: $tell).font(.ui(.subheadline))
                        if plan.busy == true {
                            Text("Claude 正在工作或在等你确认：请等它停下来，或先处理确认卡片、中断，再撤回").font(.ui(.footnote)).foregroundStyle(.orange)
                        }
                    }
                } else if let failed {
                    Text(failed).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            }
        } bottom: {
            if let done, !restored {
                actionButton(L("还原撤回"), tint: Theme.claude, filled: false) { Task { await undo(done.undo) } }
            } else if done == nil, plan?.error == nil, !changes.isEmpty {
                actionButton(L("撤回 %lld 个文件", changes.count), tint: Theme.removed, filled: true) { Task { await apply() } }
                    .disabled(plan?.busy == true)
            }
        }
        .task { await load() }
    }

    private func actionButton(_ title: String, tint: Color, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.ui(.body).weight(.semibold)).foregroundStyle(filled ? .white : tint)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(filled ? tint.opacity(busy ? 0.4 : 1) : tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
    }

    private func load() async {
        do {
            let data = try await model.api.post("/api/rewind", ["key": key], body: ["op": "plan", "offset": offset])
            plan = try JSONDecoder().decode(RewindPlan.self, from: JSONSerialization.data(withJSONObject: data))
        } catch {
            failed = L("读取失败：%@", error.localizedDescription)
        }
    }

    private func apply() async {
        busy = true
        defer { busy = false }
        do {
            let reply = try await model.api.post("/api/rewind", ["key": key], body: ["op": "apply", "offset": offset])
            if let error = reply["error"] as? String { failed = error; plan?.error = error; return }
            let count = reply["done"] as? Int ?? 0
            done = (count, reply["undo"] as? String ?? "", (reply["failed"] as? [Any])?.count ?? 0)
            if tell, count > 0 {
                _ = model.send(key, text: L("我已把第 %lld 轮开始后你用编辑工具改动的 %lld 个文件撤回到那一轮开始前的样子，请以磁盘上现在的内容为准。", plan?.turnIndex ?? 0, count),
                               images: [])
            }
        } catch {
            plan?.error = L("撤回失败：%@", error.localizedDescription)
        }
    }

    private func undo(_ stamp: String) async {
        busy = true
        defer { busy = false }
        do {
            let reply = try await model.api.post("/api/rewind", ["key": key], body: ["op": "undo", "undo": stamp])
            if let error = reply["error"] as? String { plan?.error = error; done = nil; return }
            restored = true
            if tell { _ = model.send(key, text: L("刚才撤回的文件已还原到撤回之前的样子。"), images: []) }
        } catch {
            plan?.error = L("还原失败：%@", error.localizedDescription)
            done = nil
        }
    }
}

/// sheetPanel(item:) 要 Identifiable：撤回哪一句（记录里的位置）
struct RewindTarget: Identifiable, Hashable { let offset: Int; var id: Int { offset } }

/// 测试入口（Mac 截图步骤 tp:…、iPhone 调试遥控口 cmd「tp …」）：打开当前对话页的上下文构成（context）或第 N 轮的撤回面板（rewind:N）。
/// 由对话页输入框下面那排的上下文胶囊接手（它知道是哪个会话），正式使用不经过这里
final class TransparencyRequest: KLObservable {
    let _klRegistrar = KLRegistrar.make()
    static let shared = TransparencyRequest()
    @Tracked var ask: String?
}
