import SwiftUI

/// 对话页上的附加部件（和手机网页版一样）：对话内搜索、离开期间小结、可能卡住了、上下文快满了

// MARK: 对话内搜索

struct ChatSearchSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let key: String
    let jump: (String) -> Void
    @State private var query = ""
    @State private var hits: [Hit]?
    @State private var truncated = false
    @State private var error: String?
    @FocusState private var focused: Bool

    struct Hit: Identifiable, Hashable {
        var id: String
        var t: String
        var snippet: String
        var ts: Double?
    }

    var body: some View {
        NavigationStack {
            List {
                if let hits {
                    Section {
                        ForEach(hits) { hit in
                            Button {
                                guard TouchTravel.isTap else { return }
                                dismiss()
                                jump(hit.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(hit.t == "user" ? (model.me?.name ?? L("我")) : (model.session(key)?.speaker ?? "Claude")).font(.ui(.caption).weight(.semibold))
                                            .foregroundStyle(hit.t == "user" ? Theme.wechatGreen : Theme.claude)
                                        Spacer()
                                        Text(hit.ts.map(Format.messageTime) ?? "").font(.ui(.caption2)).foregroundStyle(.tertiary)
                                    }
                                    highlighted(hit.snippet).font(.ui(.subheadline)).foregroundStyle(.primary).lineLimit(4)
                                }
                            }
                        }
                    } header: {
                        Text(hits.isEmpty ? L("此对话中未找到「%@」", "\(query)") : L("找到 %@ 处", "\(hits.count)") + (truncated ? L("（仅列出部分）") : "")).textCase(nil).font(.sectionHeader)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                }
            }
            .panelSearch($query, prompt: L("你的消息与 %@ 的回复", "\(model.session(key)?.speaker ?? "Claude")"), alwaysShown: true, focus: true)
            .onSubmit(of: [.search, .text]) { Task { await search() } }
            .navigationTitle("在对话里搜索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .doneButton { dismiss() }
            .task(id: query) {
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { hits = nil; return }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                await search()
            }
        }
        #if os(macOS)
        .panelFrame(width: 560, height: 560)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private func highlighted(_ text: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let range = text.range(of: q, options: .caseInsensitive) else { return Text(text) }
        return Text(String(text[..<range.lowerBound])) + Text(String(text[range])).foregroundColor(Theme.claude).bold() + Text(String(text[range.upperBound...]))
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        do {
            let reply = try await model.api.get("/api/search", ["key": key, "q": q])
            guard q == query.trimmingCharacters(in: .whitespaces) else { return }
            let first = (reply["results"] as? [[String: Any]])?.first
            let raw = first?["hits"] as? [[String: Any]] ?? []
            // 新的在前
            hits = raw.reversed().compactMap { h in
                guard let id = h["id"] as? String else { return nil }
                return Hit(id: id, t: h["t"] as? String ?? "", snippet: h["snippet"] as? String ?? "", ts: h["ts"] as? Double)
            }
            truncated = reply["truncated"] as? Bool ?? false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: 离开期间小结

/// 「离开 2 小时 · Claude 回复 5 次 · 改了 3 个文件 · 测试 2 次（1 次失败）↑」，点了跳到「以下是新消息」
extension View {
    /// 浮在对话上面的小条（离开后的回顾、「新消息 ↓」）：厚一点的磨砂 + 细边 + 淡阴影。
    /// 原来是 regularMaterial，下面的橙色头像、卡片会透上来，左端像染了一块橙色
    func floatingPill() -> some View {
        background(.thickMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }
}

struct CatchupPill: View {
    let chat: ChatStore
    let since: Double
    /// 对话里怎么称呼这个 agent（Claude、Codex……）
    var speaker = "Claude"
    /// 浮几秒自己收起：右边一圈倒计时转完就调这个
    let expire: () -> Void
    let tap: () -> Void
    /// 什么时候出来的：倒计时圈按过去了多久直接画
    @State private var shownAt = Date()

    static let lifetime: Double = 8

    private static let testCommand = try? NSRegularExpression(pattern: #"\b(pytest|jest|vitest|mocha|go test|cargo test|npm (run )?test|pnpm (run )?test|yarn test|rspec|phpunit|unittest|run-integration|xcodebuild test|swift test)\b"#)

    var body: some View {
        let s = stats
        if s.replies + s.tools + s.images + s.errors > 0 {
            Button(action: tap) {
                HStack(spacing: 8) {
                    Text("离开 \(away)").font(.ui(.caption).weight(.semibold)).foregroundStyle(Theme.claude)
                    Text(describe(s)).font(.ui(.caption)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    // 倒计时圈：转完这条就收起；点一下跳到离开后的第一条
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
                        // 圈按过去了多久每帧直接画，不靠动画：原来 withAnimation(8 秒) 一开，同一时刻别的变化也跟着走 8 秒——
                        // 转横屏时整条重新排版，文字、底、圈各自慢慢飘到新位置（10-27 在 iPhone 上看到）
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                            Circle().trim(from: 0, to: max(0, 1 - context.date.timeIntervalSince(shownAt) / Self.lifetime))
                                .stroke(Theme.claude, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        Image(systemName: "arrow.up").font(.app(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .frame(width: 20, height: 20)
                }
                .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
                .floatingPill()
            }
            .buttonStyle(.steady(.plain))
            .padding([.horizontal, .top], 12)   // 离标题栏和左右一样远
            .onAppear { shownAt = Date() }
            .task {
                try? await Task.sleep(for: .seconds(Self.lifetime))
                if !Task.isCancelled { expire() }
            }
        }
    }

    private var away: String {
        let minutes = Int((Date().timeIntervalSince1970 * 1000 - since) / 60000)
        if minutes < 60 { return L("%lld 分钟", count: minutes) }
        if minutes < 48 * 60 { return L("%@ 小时", "\(Int((Double(minutes) / 60).rounded()))") }
        return L("%@ 天", "\(Int((Double(minutes) / 1440).rounded()))")
    }

    private struct Stats { var replies = 0, tools = 0, tests = 0, failed = 0, images = 0, errors = 0; var files = Set<String>() }

    private var stats: Stats {
        var s = Stats()
        for item in chat.items.values where (item.ts ?? 0) > since {
            switch item.t {
            case "text": s.replies += 1
            case "agent_image": s.images += 1
            case "event" where item.level == "error": s.errors += 1
            case "tool":
                s.tools += 1
                let input = item.input
                if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(item.name ?? ""), let path = input?["file_path"]?.string ?? input?["notebook_path"]?.string {
                    s.files.insert(path)
                }
                if item.name == "Bash", let command = input?["command"]?.string,
                   Self.testCommand?.firstMatch(in: command, range: NSRange(location: 0, length: (command as NSString).length)) != nil {
                    s.tests += 1
                    if let toolId = item.toolId, chat.results[toolId]?.isError == true { s.failed += 1 }
                }
            default: break
            }
        }
        return s
    }

    private func describe(_ s: Stats) -> String {
        var bits: [String] = []
        if s.replies > 0 { bits.append(L("回复 %@ 次", "\(s.replies)")) }
        if !s.files.isEmpty { bits.append(L("修改 %@ 个文件", "\(s.files.count)")) }
        if s.tests > 0 { bits.append(L("测试 %@ 次", "\(s.tests)") + (s.failed > 0 ? L("（%@ 次失败）", "\(s.failed)") : "")) }
        if s.images > 0 { bits.append(L("%lld 张图", count: s.images)) }
        if s.errors > 0 { bits.append(L("出错 %@ 次", "\(s.errors)")) }
        if s.files.isEmpty, s.tests == 0, s.tools > 0 { bits.append(L("调用工具 %@ 次", "\(s.tools)")) }
        return speaker + " " + bits.joined(separator: " · ")
    }
}

extension SessionInfo {
    /// 正在干活却 20 分钟以上没动静：可能卡在不会自己结束的命令上（npm run dev、watch 模式的测试……）
    var stuckMinutes: Int? {
        guard isBusy, let updatedAt else { return nil }
        let minutes = Int((Date().timeIntervalSince1970 * 1000 - updatedAt) / 60000)
        return minutes >= 20 ? minutes : nil
    }
}
