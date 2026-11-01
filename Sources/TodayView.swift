import AppKit
import SwiftUI
import KitelineKit

// MARK: - 数据

struct DigestReport: Decodable {
    var since: Double
    var generatedAt: Double
    var sessions: [DigestSession]
    var totals: DigestTotals
    var errors: [String]

    static func decode(_ payload: [String: Any]) -> DigestReport? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        do { return try JSONDecoder().decode(DigestReport.self, from: data) } catch {
            Log.write("今日动态解析失败：\(error)")
            return nil
        }
    }
}

struct DigestTotals: Decodable {
    var sessions = 0, projects = 0, prompts = 0, replies = 0, requests = 0, outputTokens = 0
    var files = 0, images = 0, testRuns = 0, testPassed = 0, testFailed = 0
}

struct DigestSession: Decodable, Identifiable {
    struct File: Decodable, Hashable { var path: String; var edits: Int }
    struct Note: Decodable, Hashable { var ts: Double?; var text: String }
    struct Shot: Decodable, Hashable { var ref: String; var caption: String?; var ts: Double? }
    struct TestRun: Decodable, Hashable {
        var command: String?; var description: String?; var ok: Bool?; var passed: Int?; var failed: Int?; var ts: Double?
    }
    struct Tests: Decodable { var runs = 0, passed = 0, failed = 0; var last: [TestRun] = [] }

    var sessionId: String
    var sourceId: String
    var sourceName: String
    var title: String?
    var cwd: String?
    var key: String?
    var activity: String?
    var prompts = 0, replies = 0, requests = 0, outputTokens = 0, fileCount = 0, images = 0
    var files: [File] = []
    var conclusions: [Note] = []
    var shots: [Shot] = []
    var tests = Tests()
    var firstAt: Double?
    var lastAt: Double?

    var id: String { "\(sourceId)#\(sessionId)" }
    var folder: String { cwd.map { ($0 as NSString).lastPathComponent } ?? "" }
    var displayTitle: String { title?.isEmpty == false ? title! : (folder.isEmpty ? L("会话") : folder) }
    var act: Activity { Activity(raw: activity) }
}

/// 「今日动态」的时间范围
enum DigestRange: String, CaseIterable, Identifiable {
    case today, yesterday, week
    var id: String { rawValue }
    var label: String { ["today": L("今天"), "yesterday": L("昨天"), "week": L("近 7 天")][rawValue]! }

    var bounds: (since: Int64, until: Int64?) {
        let today = Digest.startOfDay()
        switch self {
        case .today: return (today, nil)
        case .yesterday: return (today - 86_400_000, today)
        case .week: return (today - 6 * 86_400_000, nil)
        }
    }
}

final class TodayModel: ObservableObject {
    static let shared = TodayModel()
    @Published var range: DigestRange = .today { didSet { load() } }
    @Published private(set) var report: DigestReport?
    @Published private(set) var loading = false
    @Published var pushMessage: String?
    private var token = 0

    func load(fresh: Bool = false) {
        token += 1
        let current = token
        loading = true
        let bounds = range.bounds
        Digest.collect(since: bounds.since, until: bounds.until, fresh: fresh) { [weak self] payload in
            guard let self = self, current == self.token else { return }
            self.report = DigestReport.decode(payload)
            self.loading = false
        }
    }

    /// 自测渲染用：直接塞一份报告
    func inject(_ report: DigestReport) { self.report = report; loading = false }

    func pushNow() {
        pushMessage = L("正在汇总…")
        DailyReport.shared.send(manual: true) { [weak self] message in self?.pushMessage = message }
    }
}

// MARK: - 视图

/// Mac 主窗口右侧的「今日动态」：今天每个项目做了什么（包括已经关掉的会话）
struct TodayView: View {
    @ObservedObject var model = TodayModel.shared
    @ObservedObject var tars = KitelineModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let report = model.report {
                    StatsGrid(totals: report.totals)
                    if report.sessions.isEmpty {
                        EmptyHint(symbol: "sun.haze", title: L("%@暂无动态", "\(model.range.label)"),
                                  detail: report.errors.isEmpty
                                      ? L("Claude Code 产生对话后，此处将按会话汇总：对话轮数、改动文件、运行的测试及发送的截图。")
                                      : L("以下来源尚未连接，连接后将自动刷新。"))
                    }
                    ForEach(report.sessions) { session in
                        DigestCard(session: session) { key in tars.selection = key }
                    }
                    ForEach(report.errors, id: \.self) { error in
                        Label(ServerLang.ui(error), systemImage: "exclamationmark.triangle").font(.app(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Text("生成于 \(Format.short(report.generatedAt))，统计所有在线来源，包括已关闭的会话。")
                        .font(.app(size: 11)).foregroundStyle(.tertiary)
                } else {
                    ProgressView("正在汇总…").frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("今日动态")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("范围", selection: $model.range) {
                    ForEach(DigestRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.load(fresh: true) } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.loading)
                .help("重新汇总")
                Button { model.pushNow() } label: {
                    Label("推送日报", systemImage: "paperplane")
                }
                .help("立即将今日日报推送到手机")
                .popover(isPresented: Binding(get: { model.pushMessage != nil }, set: { if !$0 { model.pushMessage = nil } })) {
                    Text(model.pushMessage ?? "").font(.app(size: 12)).padding(12)
                }
            }
        }
        // 切过来、来源连上 / 断开时都重新汇总，开着时每分钟再汇总一次（只在第一次打开时汇总的话，
        // App 刚启动、来源还没连上那一下的「未连接」「没有动态」会一直挂着）
        .liveReload(every: 60) { model.load() }
    }

    private var subtitle: String {
        guard let report = model.report else { return L("正在汇总") }
        return report.sessions.isEmpty ? L("没有动态") : L("%@ 个会话 · %@ 个项目", "\(report.totals.sessions)", "\(report.totals.projects)")
    }
}

struct StatsGrid: View {
    let totals: DigestTotals
    @State private var width: CGFloat = 0

    var body: some View {
        // 5 格：够宽一排 5 个，窄了 3 + 2（别排成 4 + 1，最后一格孤零零的）
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: width >= 560 ? 5 : 3), spacing: 10) {
            tile("bubble.left.and.bubble.right", "\(totals.prompts)", L("轮对话", plural: "%lld 轮对话", count: totals.prompts), L("%lld 个会话", count: totals.sessions))
            tile("doc.badge.ellipsis", "\(totals.files)", L("个文件改动", plural: "%lld 个文件改动", count: totals.files), L("%lld 个项目", count: totals.projects))
            tile(totals.testFailed > 0 ? "xmark.seal" : "checkmark.seal", "\(totals.testRuns)", L("次测试", plural: "测试 %lld 次", count: totals.testRuns),
                 totals.testRuns == 0 ? L("未运行测试") : (totals.testFailed > 0 ? L("%lld 次失败", count: totals.testFailed) : L("全部通过")))
            tile("photo.on.rectangle", "\(totals.images)", L("张截图", plural: "%lld 张截图", count: totals.images), L("Claude 发来的"))
            tile("text.word.spacing", UsageInfo.compact(totals.outputTokens), L("输出 token"), L("%lld 次请求", count: totals.requests))
        }
        // 量外面给的宽，不量格子自己：5 格挤不下撑宽了格子，量到的宽就一直够 5 格，缩窄窗口也回不到 3 + 2
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func tile(_ symbol: String, _ value: String, _ label: String, _ detail: String) -> some View {
        // 数字下面再写是什么：一排 5 格时每格只有一百来点宽，数字和说明并排会挤
        VStack(alignment: .leading, spacing: 4) {
            DuoIcon(symbol: symbol, size: 26).padding(.bottom, 4)
            Text(value).font(.app(size: 24, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.app(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Text(detail).font(.app(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .tarsCard(padding: 12, cornerRadius: 14)
    }
}

struct DigestCard: View {
    let session: DigestSession
    var open: (String) -> Void
    @State private var showAllFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SessionAvatar(key: session.id, title: session.displayTitle,
                              activity: session.key == nil ? .unknown : session.act, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle).font(.app(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: session.sourceId == "local" ? "laptopcomputer" : "server.rack")
                        Text([session.sourceName, session.folder, timeSpan].filter { !$0.isEmpty }.joined(separator: " · "))
                            .lineLimit(1)
                    }
                    .font(.app(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                statusBadge
                if let key = session.key {
                    Button("打开对话") { open(key) }.tarsButton().controlSize(.small)
                }
            }
            chips
            if let note = session.conclusions.last {
                Text(Self.plain(note.text))
                    .font(.app(size: 12.5))
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !session.files.isEmpty { files }
            if let run = session.tests.last.first { testLine(run) }
            if !session.shots.isEmpty { ShotStrip(session: session) }
        }
        .tarsCard(padding: 14, cornerRadius: 16)
    }

    private var timeSpan: String {
        guard let first = session.firstAt, let last = session.lastAt else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let a = f.string(from: Date(timeIntervalSince1970: first / 1000))
        let b = f.string(from: Date(timeIntervalSince1970: last / 1000))
        return a == b ? a : "\(a)–\(b)"
    }

    @ViewBuilder private var statusBadge: some View {
        let (text, color): (String, Color) = {
            guard session.key != nil else { return (L("已结束"), .secondary) }
            switch session.act {
            case .waiting: return (L("等你确认"), .tarsOrange)
            case .busy: return (L("进行中"), .tarsBrand)
            default: return (L("空闲"), .green)
            }
        }()
        Text(text).font(.app(size: 10.5, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var chips: some View {
        // 一排放不下就整个标签换到下一行，标签里的字不折行（窗口窄时「测试 3 次 · 1 失败」被挤成两行）
        ChipFlow(spacing: 6) {
            chip("bubble.left", L("%lld 轮", count: session.prompts))
            if session.fileCount > 0 { chip("doc.text", L("%lld 个文件", count: session.fileCount)) }
            if session.tests.runs > 0 {
                chip(session.tests.failed > 0 ? "xmark.seal" : "checkmark.seal",
                     session.tests.failed > 0 ? L("测试 %@ 次 · %@ 失败", "\(session.tests.runs)", "\(session.tests.failed)") : L("测试 %@ 次", "\(session.tests.runs)"),
                     tint: session.tests.failed > 0 ? .red : .green)
            }
            if session.images > 0 { chip("photo", L("%lld 张截图", count: session.images)) }
            if session.outputTokens > 0 { chip("text.word.spacing", "\(UsageInfo.compact(session.outputTokens)) token") }
        }
    }

    private func chip(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        Label(text, systemImage: symbol)
            .font(.app(size: 11))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private var files: some View {
        let shown = showAllFiles ? session.files : Array(session.files.prefix(5))
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(shown, id: \.self) { file in
                HStack(spacing: 6) {
                    Image(systemName: "pencil.line").font(.app(size: 9)).foregroundStyle(.tertiary)
                    Text(file.path).font(.app(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    if file.edits > 1 { Text("×\(file.edits)").font(.app(size: 10)).foregroundStyle(.tertiary) }
                }
            }
            if session.fileCount > shown.count || showAllFiles {
                Button(showAllFiles ? "收起" : "另有 \(session.fileCount - shown.count) 个文件") { showAllFiles.toggle() }
                    .buttonStyle(.link).font(.app(size: 11))
            }
        }
    }

    private func testLine(_ run: DigestSession.TestRun) -> some View {
        HStack(spacing: 6) {
            Image(systemName: run.ok == false ? "xmark.circle.fill" : (run.ok == true ? "checkmark.circle.fill" : "circle.dashed"))
                .foregroundStyle(run.ok == false ? Color.red : (run.ok == true ? Color.green : Color.secondary))
            Text("最近一次测试：\(run.description ?? run.command ?? "")").lineLimit(1).truncationMode(.tail)
            if let passed = run.passed { Text("\(passed) 通过").foregroundStyle(.green) }
            if let failed = run.failed, failed > 0 { Text("\(failed) 失败").foregroundStyle(.red) }
        }
        .font(.app(size: 11.5))
    }

    /// 结论文本去掉最常见的 markdown 标记，卡片里只看纯文字
    static func plain(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Claude 发来的截图缩略图：会话关了也能看（按来源 + 会话 id 去 watcher 取）
struct ShotStrip: View {
    let session: DigestSession
    @State private var images: [String: NSImage] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.shots, id: \.self) { shot in
                    Group {
                        if let image = images[shot.ref] {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.primary.opacity(0.06).overlay(ProgressView().controlSize(.small))
                        }
                    }
                    .frame(width: 132, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .help(shot.caption ?? "")
                    .onTapGesture { open(shot) }
                    .onAppear { load(shot) }
                }
            }
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)   // 截图多了别把一排的总宽往上报，撑宽整页
    }

    private func load(_ shot: DigestSession.Shot) {
        guard images[shot.ref] == nil, let source = AppState.shared.source(withId: session.sourceId) else { return }
        source.request(["cmd": "media", "sessionId": session.sessionId, "ref": shot.ref], timeout: 40) { result in
            if case .success(let response) = result, let base64 = response["data"] as? String,
               let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                images[shot.ref] = image
            }
        }
    }

    private func open(_ shot: DigestSession.Shot) {
        guard let image = images[shot.ref], let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tars-\(shot.ref).png")
        try? png.write(to: url)
        NSWorkspace.shared.open(url)
    }
}

/// 页面里「还没有……」的空状态：图标 + 标题 + 一段说明，居中、最宽 420。
/// 不用系统的 ContentUnavailableView：放在滚动区里时它不撑满宽度，说明文字会被截掉半个字
struct EmptyHint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.app(size: 34, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 2)
            Text(title).font(.app(size: 15, weight: .semibold))
            Text(detail).font(.app(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

/// 主窗口右边几页（今日动态、用量、项目、历史）的自动刷新：切过来、来源连上或断开时重新拉一次；every 不为空时开着的时候定时再拉。
/// 只在第一次打开时拉的话，App 刚启动、来源还没连上那一下拉到的残缺数据会一直挂着
struct LiveReload: ViewModifier {
    var every: TimeInterval?
    let reload: () -> Void
    @ObservedObject private var tars = KitelineModel.shared

    func body(content: Content) -> some View {
        content
            .onAppear(perform: reload)
            .onChange(of: tars.onlineSources) { _, _ in reload() }
            .task {
                guard let every else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(every))
                    if !Task.isCancelled { reload() }
                }
            }
    }
}

extension View {
    func liveReload(every: TimeInterval? = nil, _ reload: @escaping () -> Void) -> some View {
        modifier(LiveReload(every: every, reload: reload))
    }
}

/// 一行排不下就换行的横排（标签、小按钮用），每个子视图按自己的大小放
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
