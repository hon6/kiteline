import Charts
import SwiftUI

/// 首页四个汇总卡片点进去的页面：今日动态、用量、历史会话、项目（内容和手机网页版一样）

// MARK: 今日动态

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var range = "today"
    @State private var payload: DigestPayload?
    @State private var error: String?
    /// 后台在取新的（页面上先显示着上次存的）
    @State private var refreshing = false

    private var title: String { ["today": L("今日动态"), "yesterday": L("昨日动态"), "week": L("近 7 天动态")][range] ?? L("今日动态") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("范围", selection: $range) {
                    Text("今天").tag("today")
                    Text("昨天").tag("yesterday")
                    Text("近 7 天").tag("week")
                }
                .pickerStyle(.segmented)
                // 战绩条：跟着上面选的今天 / 昨天 / 近 7 天，数字一眼看到，点了生成分享图（电脑端支持才有）
                if model.hostFeatures.contains("brag") {
                    BragStrip(range: range == "yesterday" ? .yesterday : range == "week" ? .week : .today)
                }
                if let payload {
                    stats(payload.totals)
                    if payload.sessions.isEmpty { PageNote(text: "此期间暂无 Claude Code 动态。") }
                    ForEach(payload.sessions) { DigestCard(session: $0) }
                    ForEach(payload.errors, id: \.self) { PageNote(text: $0) }
                    NavigationLink(value: Route.usage) {
                        LinkRow(title: L("用量报表（按天、模型、项目）"))
                    }
                    .buttonStyle(.steady(.plain))
                    if let at = payload.generatedAt {
                        Text("生成于 \(Format.messageTime(at)) · 统计所有在线来源，包括已关闭的会话")
                            .font(.ui(.caption)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                } else if let error {
                    LoadFailed(error: error) { await load() }.padding(.top, 40)
                } else {
                    ProgressView("正在汇总…").frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .updating(refreshing && payload != nil)
        .task(id: range) {
            // 先显示上次存的这一段（换了范围也是），再静默取新的
            if let cached = model.api.cached(DigestPayload.self, "/api/digest", digestQuery) { payload = cached }
            await load()
        }
        .refreshable { await load() }
    }

    private var digestQuery: [String: String] {
        var query = ["since": HomeStats.dayStart(range == "week" ? -6 : (range == "yesterday" ? -1 : 0))]
        if range == "yesterday" { query["until"] = HomeStats.dayStart(0) }
        return query
    }

    private func stats(_ t: DigestTotals) -> some View {
        StatGrid(cards: [
            StatCard(value: "\(t.sessions)", label: L("个会话", plural: "%lld 个会话", count: t.sessions), sub: L("%lld 个项目", count: t.projects)),
            StatCard(value: "\(t.prompts)", label: L("轮对话", plural: "%lld 轮对话", count: t.prompts), sub: L("%lld 条回复", count: t.replies)),
            StatCard(value: "\(t.files)", label: L("个文件", plural: "%lld 个文件", count: t.files), sub: L("有改动")),
            StatCard(value: "\(t.testRuns)", label: L("次测试", plural: "测试 %lld 次", count: t.testRuns),
                     sub: t.testRuns > 0 ? (t.testFailed > 0 ? L("%lld 次失败", count: t.testFailed) : L("全部通过")) : L("未运行测试"),
                     tone: t.testFailed > 0 ? .bad : (t.testRuns > 0 ? .good : .plain)),
            StatCard(value: "\(t.images)", label: L("张截图", plural: "%lld 张截图", count: t.images), sub: L("Claude 发来的")),
            StatCard(value: Money.compact(Double(t.outputTokens)), label: L("输出 token"), sub: L("%lld 次请求", count: t.requests)),
        ])
    }

    private func load() async {
        refreshing = true
        defer { refreshing = false }
        do {
            payload = try await model.api.getCaching(DigestPayload.self, "/api/digest", digestQuery)
            error = nil
        } catch {
            if payload == nil { self.error = error.localizedDescription }
        }
    }
}

/// 一个会话在这段时间里做了什么：几轮、改了哪些文件、测试、结论、截图
struct DigestCard: View {
    let session: DigestSession
    @State private var expanded = false
    @State private var allFiles = false

    var body: some View {
        let s = session
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(text: Format.initials(s.title), size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.ui(.headline)).lineLimit(1)
                    Text([s.sourceName, s.cwd.map { ($0 as NSString).lastPathComponent }, span].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                status
            }
            FlowLayout(spacing: 6) {
                Chip(text: L("%lld 轮", count: s.prompts))
                if s.fileCount > 0 { Chip(text: L("%lld 个文件", count: s.fileCount)) }
                if s.testRuns > 0 {
                    Chip(text: L("%@ 测试 %@ 次", "\(s.testFailed > 0 ? "✗" : "✓")", "\(s.testRuns)") + (s.testFailed > 0 ? L(" · %@ 失败", "\(s.testFailed)") : ""),
                         color: s.testFailed > 0 ? Theme.removed : Theme.added)
                }
                if s.images > 0 { Chip(text: L("%lld 张截图", count: s.images)) }
                if s.outputTokens > 0 { Chip(text: L("%@ token", Money.compact(Double(s.outputTokens)))) }
            }
            if let note = s.conclusion, !note.isEmpty {
                MarkdownView(note)
                    .frame(maxHeight: expanded ? nil : 180, alignment: .top)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        if !expanded {
                            LinearGradient(colors: [Theme.tile.opacity(0), Theme.tile], startPoint: .top, endPoint: .bottom).frame(height: 36)
                        }
                    }
                    .padding(12)
                    .background(Theme.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { guard TouchTravel.isTap else { return }; withAnimation(.snappy) { expanded.toggle() } }
            }
            if !s.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allFiles ? s.files : Array(s.files.prefix(4)), id: \.path) { file in fileRow(file) }
                    if s.fileCount > 4, !allFiles {
                        Button("还有 \(s.fileCount - 4) 个文件") { allFiles = true }.font(.ui(.footnote))
                    }
                }
            }
            if let run = s.lastTest {
                let mark = run.ok == false ? "✗" : (run.ok == true ? "✓" : "•")
                let name = run.description ?? (run.command ?? "").components(separatedBy: "\n").first ?? ""
                Text(L("%@ 最近一次测试：%@", "\(mark)", "\(name)") + (run.passed.map { L(" · %@ 通过", "\($0)") } ?? "") + ((run.failed ?? 0) > 0 ? L(" · %@ 失败", "\(run.failed!)") : ""))
                    .font(.ui(.footnote))
                    .foregroundStyle(run.ok == false ? Theme.removed : (run.ok == true ? Theme.added : .secondary))
            }
            if !s.shots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(s.shots, id: \.ref) { shot in
                            RemoteImage(path: "/api/digest/media", query: ["source": s.sourceId, "sid": s.sessionId, "ref": shot.ref], variant: .thumb)
                                .frame(width: 100, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)   // 截图多了别把一排的总宽往上报，撑宽整页
            }
            HStack {
                Spacer()
                NavigationLink(value: Route.chat(s.id)) {
                    // 字只有一行高：点击区域上下各扩 8、左边扩 12，排版上再收回来
                    Text(s.live ? "打开对话 ›" : "查看对话 ›").font(.ui(.subheadline).weight(.medium))
                        .padding(.vertical, 8).padding(.leading, 12)
                        .contentShape(Rectangle())
                }
            }
            .padding(.vertical, -8)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var span: String? {
        guard let a = session.firstAt, let b = session.lastAt else { return nil }
        let start = Format.separator(a), end = Format.separator(b)
        if start == end { return start }
        let day = Calendar.current.isDate(Date(timeIntervalSince1970: a / 1000), inSameDayAs: Date(timeIntervalSince1970: b / 1000))
        return day ? "\(start)–\(end.components(separatedBy: " ").last ?? end)" : "\(start)–\(end)"
    }

    @ViewBuilder private var status: some View {
        let (text, color): (String, Color) = !session.live ? (L("已结束"), .secondary)
            : (["waiting": (L("待确认"), Color.orange), "busy": (L("进行中"), Theme.claude)][session.activity ?? ""] ?? (L("空闲"), Theme.added))
        Text(text).font(.ui(.caption).weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    /// 目录太长只留最后两级，保证文件名露出来（和网页版一样）
    private func fileRow(_ file: DigestSession.File) -> some View {
        let name = (file.path as NSString).lastPathComponent
        var dir = file.path.hasSuffix(name) ? String(file.path.dropLast(name.count)) : ""
        if dir.count > 30 { dir = "…/" + dir.split(separator: "/").suffix(2).joined(separator: "/") + "/" }
        return HStack(spacing: 0) {
            Text(dir).foregroundStyle(.secondary)
            Text(name)
            if let edits = file.edits, edits > 1 { Text(" ×\(edits)").foregroundStyle(.secondary).font(.ui(.caption2)) }
        }
        .font(.ui(.footnote, design: .monospaced)).fontDesign(nil)
        .lineLimit(1)
        .truncationMode(.head)
    }
}

// MARK: 用量

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State var days = 7
    @State private var payload: UsagePayload?
    @State private var budget = Budget()
    @State private var limits: [LimitDevice]?
    @State private var error: String?
    @State private var picking: BudgetKind?
    @State private var showBrag = false
    /// 后台在取新的（页面上先显示着上次存的）
    @State private var refreshing = false

    enum BudgetKind: String, Identifiable { case daily, cap; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 订阅额度（各台电脑的 5 小时 / 本周）：首页卡片上那几条，宽屏时一台电脑一栏
                let devices = limits ?? model.home.limits
                if !devices.isEmpty {
                    SectionLabel(text: L("订阅额度"))
                    LimitsBoard(devices: devices, wide: true)
                        .padding(14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                Picker("范围", selection: $days) {
                    Text("今天").tag(1)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                // 分享战绩：把用了多少 token、改了多少行画成图发微信（电脑端支持才有）
                if model.hostFeatures.contains("brag") {
                    Button { showBrag = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "trophy.fill").foregroundStyle(KiteColor.brand)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("分享战绩")).font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.primary)
                                Text(L("用了多少 Token、改了多少行代码，生成图片发微信好友或朋友圈")).font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.ui(.caption).weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let payload {
                    content(payload)
                } else if let error {
                    LoadFailed(error: error) { await load() }.padding(.top, 40)
                } else {
                    ProgressView("正在统计各机器的用量…").frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
        .navigationTitle("用量")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheetPanel(isPresented: $showBrag) { BragShareSheet().environment(model) }
        .updating(refreshing && payload != nil)
        .task(id: days) {
            // 先显示上次存的（这个范围的用量、预算、额度），再静默取新的
            if let cached = model.api.cached(UsagePayload.self, "/api/usage", ["days": String(days)]) { payload = cached }
            if let cached = model.api.cached(Budget.self, "/api/budget") { budget = cached }
            if limits == nil, let cached = model.api.cached(LimitsPayload.self, "/api/limits") { limits = cached.devices }
            await load()
        }
        // 额度每 5 分钟重拉一次（同首页）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if !Task.isCancelled, let fresh = try? await model.api.getCaching(LimitsPayload.self, "/api/limits") { limits = fresh.devices }
            }
        }
        .refreshable { await load() }
        .confirmationDialog(picking == .cap ? "每日花费上限：超出后将跳过定时任务，新建任务、恢复会话和手机发送消息均需先确认（允许操作与回答提问不受影响）"
                                : "每日花费达到该金额时提醒（达到 80% 时提前提醒一次）",
                            isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                            titleVisibility: .visible, presenting: picking) { kind in
            let options = kind == .cap ? [100.0, 200, 300, 500, 1000] : [50.0, 100, 150, 200, 300, 500]
            let current = kind == .cap ? budget.cap : budget.daily
            ForEach(options, id: \.self) { value in
                Button("$\(Int(value))" + (current == value ? L("（当前）") : "")) { Task { await setBudget(kind, value) } }
            }
            Button(kind == .cap ? "不设上限" : "关闭提醒", role: .destructive) { Task { await setBudget(kind, 0) } }
        }
    }

    @ViewBuilder
    private func content(_ r: UsagePayload) -> some View {
        let t = r.totals
        if !budget.capped.isEmpty {
            PageNote(text: L("%@：定时任务已暂停，新建任务和手机发送消息需先确认。", "\(budget.capped)"), color: Theme.removed)
        }
        StatGrid(cards: [
            StatCard(value: Money.cost(t.cost), label: L("花费"), sub: t.estimated > 0 ? L("含估算 %@", "\(Money.cost(t.estimated))") : L("取自 agent 记录")),
            StatCard(value: "\(Int(t.requests.rounded()))", label: L("次请求", plural: "%lld 次请求", count: Int(t.requests.rounded())), sub: L("%lld 个模型", count: r.models.count)),
            StatCard(value: Money.compact(t.output), label: L("输出 token"), sub: L("输入 %@", "\(Money.compact(t.input + t.cacheRead + t.cacheWrite))")),
        ], columns: 3)
        if r.days.count > 1 {
            SectionLabel(text: L("每天花费"))
            Chart {
                ForEach(r.days, id: \.day) { day in
                    BarMark(x: .value("日期", String(day.day.suffix(5)).replacingOccurrences(of: "-", with: "/")),
                            y: .value("花费", max(0, day.cost - day.estimated)))
                        .foregroundStyle(by: .value("类型", L("记录")))
                    BarMark(x: .value("日期", String(day.day.suffix(5)).replacingOccurrences(of: "-", with: "/")),
                            y: .value("花费", day.estimated))
                        .foregroundStyle(by: .value("类型", L("估算")))
                }
            }
            .chartForegroundStyleScale([L("记录"): Theme.added, L("估算"): Theme.added.opacity(0.4)])
            .chartLegend(.hidden)
            .chartYAxis { AxisMarks { value in AxisValueLabel { if let v = value.as(Double.self) { Text(Money.cost(v)) } } } }
            .frame(height: 170)
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        if r.agents.count > 1 {
            breakdown(L("按 Agent"), r.agents, total: t.cost) { L("%@ 次请求", "\(Int($0.requests.rounded()))") }
        }
        breakdown(L("按模型"), r.models.map { var m = $0; m.unpriced = m.cost == 0 && r.unpriced.contains(m.name); return m }, total: t.cost) { L("%@ 次 · 输出 %@ · 读缓存 %@", "\(Int($0.requests.rounded()))", "\(Money.compact($0.output))", "\(Money.compact($0.cacheRead))") }
        breakdown(L("按项目"), Array(r.projects.prefix(10)), total: t.cost) { L("%@ · %@ 次 · 输出 %@", "\($0.sub)", "\(Int($0.requests.rounded()))", "\(Money.compact($0.output))") }
        if r.sources.count > 1 {
            breakdown(L("按机器"), r.sources, total: t.cost) { L("%@ 次请求", "\(Int($0.requests.rounded()))") }
        }
        VStack(spacing: 0) {
            Button { picking = .daily } label: {
                LinkRow(title: L("每日花费提醒"), value: budget.daily > 0 ? L("超过 %@ 推送", "\(Money.cost(budget.daily))") : L("未开启"), boxed: false)
            }
            Divider().padding(.leading, 16)
            Button { picking = .cap } label: {
                LinkRow(title: L("每日花费上限"), value: budget.cap > 0 ? L("%@，超出后拦截", "\(Money.cost(budget.cap))") : L("不设上限"), boxed: false)
            }
        }
        .buttonStyle(.steady(.plain))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        PageNote(text: L("花费取自各 agent 自己的记录：Claude Code 的 cost-state（会话结束或恢复时写入；进行中的会话按同一机器、同一模型的平均费率估算，图中浅色部分），以及 OpenCode、Proma、Cursor 记下的花费。Codex、DeepSeek Harness、Qwen Code 不记录花费，只统计 token。"))
        if !r.unpriced.isEmpty { PageNote(text: L("无费率数据的模型仅统计 token：%@", "\(r.unpriced.joined(separator: "、"))")) }
        ForEach(r.errors, id: \.self) { PageNote(text: $0) }
    }

    @ViewBuilder
    private func breakdown(_ title: String, _ items: [UsageItem], total: Double, sub: @escaping (UsageItem) -> String) -> some View {
        if !items.isEmpty {
            SectionLabel(text: title)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().padding(.leading, 16) }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.ui(.subheadline).weight(.semibold)).lineLimit(1)
                            Text(sub(item)).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                            GeometryReader { geo in
                                Capsule().fill(Color.primary.opacity(0.07))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Theme.added).frame(width: geo.size.width * (total > 0 ? min(1, item.cost / total) : 0))
                                    }
                            }
                            .frame(height: 4)
                            .opacity(item.unpriced ? 0 : 1)
                        }
                        if item.unpriced {
                            Text("仅 token").font(.ui(.caption)).foregroundStyle(.secondary)
                        } else {
                            Text(Money.cost(item.cost)).font(.ui(.subheadline).monospacedDigit())
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func load() async {
        do {
            refreshing = true
            defer { refreshing = false }
            async let usage = model.api.getCaching(UsagePayload.self, "/api/usage", ["days": String(days)])
            async let budget = try? model.api.getCaching(Budget.self, "/api/budget")
            async let limits = try? model.api.getCaching(LimitsPayload.self, "/api/limits")
            payload = try await usage
            self.budget = await budget ?? self.budget
            if let limits = await limits { self.limits = limits.devices }
            error = nil
        } catch {
            if payload == nil { self.error = error.localizedDescription }
        }
    }

    private func setBudget(_ kind: BudgetKind, _ value: Double) async {
        do {
            let reply = try await model.api.post("/api/budget", body: [kind.rawValue: value])
            budget.daily = reply["daily"] as? Double ?? budget.daily
            budget.cap = reply["cap"] as? Double ?? budget.cap
            if kind == .cap {
                model.flash(value > 0 ? L("今日花费达到 %@ 后：跳过定时任务，新建任务和发送消息需先确认", "\(Money.cost(value))") : L("已取消每日上限"))
            } else {
                model.flash(value > 0 ? L("今日花费达到 %@、%@ 时各提醒一次", "\(Money.cost(value * 0.8))", "\(Money.cost(value))") : L("已关闭花费提醒"))
            }
            await load()
        } catch {
            model.show(error)
        }
    }
}

// MARK: 历史会话

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @State private var query = ""
    @State private var sessions: [PastSession] = []
    @State private var loaded = false
    @State private var truncated = false
    @State private var errors: [String] = []
    /// 后台在取新的（页面上先显示着上次存的）
    @State private var refreshing = false
    /// 分组：none 按日期 / source 按来源 / project 按项目（同会话列表）
    @AppStorage("historyGrouping") private var grouping = "none"
    /// 按状态筛：all / live 进行中 / ended 已结束（同会话列表的筛选条）
    @AppStorage("historyFilter") private var statusFilter = "all"
    /// 只看某台设备（来源名；空 = 全部设备）
    @AppStorage("historySource") private var sourceFilter = ""
    /// 只看某个项目（项目名 = 目录最后一级，几台设备上同名的算一个；空 = 全部项目）
    @AppStorage("historyProject") private var projectFilter = ""

    var body: some View {
        let base = sessions.filter(inScope)
        let shown = base.filter { matches($0, statusFilter) }
        List {
            if !sessions.isEmpty || isFiltering {
                Section {
                    filterRows(base)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            ForEach(sections(shown), id: \.title) { day in
                Section {
                    ForEach(day.items) { session in
                        Button {
                            model.rememberPast(session)
                            // 搜到的：打开后跳到命中的那条
                            if !query.isEmpty, let hit = session.hits.first?.id { model.jumpRequests[session.key] = hit }
                            open(.chat(session.key))
                        } label: { PastRow(session: session, searching: !query.isEmpty, query: query) }
                        .buttonStyle(RowButtonStyle())
                    }
                } header: {
                    Text(day.title).font(.sectionHeader)
                }
            }
            if truncated { Text("结果过多，仅显示部分内容；请尝试更具体的关键词。").font(.ui(.footnote)).foregroundStyle(.secondary) }
            ForEach(errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.ui(.footnote)).foregroundStyle(.secondary) }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        // 筛选条是第一行：去掉分组列表给第一组留的那一大截上边距（和搜索框之间只留一点）
        .contentMargins(.top, 4, for: .scrollContent)
        #endif
        .overlay {
            if !loaded {
                ProgressView(query.isEmpty ? "正在读取历史会话…" : "正在搜索…")
            } else if sessions.isEmpty {
                ContentUnavailableView(query.isEmpty ? "暂无历史会话" : "未找到「\(query)」", systemImage: "clock.arrow.circlepath")
            } else if shown.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "暂无\(filterName)" : "\(filterName)中未找到「\(query)」", systemImage: "line.3.horizontal.decrease")
                } actions: {
                    Button(query.isEmpty ? "显示全部" : "在全部会话中搜索") { withAnimation(.snappy) { clearFilters() } }
                }
            }
        }
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题、项目名称和对话内容")
        #else
        .searchable(text: $query, prompt: L("搜索标题、项目名称和对话内容"))
        #endif
        .navigationTitle("历史会话")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .updating(refreshing && loaded)
        // 搜索词变了重新搜；没在搜时换了项目也重新读（把这个项目的会话取全）
        .task(id: query.isEmpty ? "\n" + projectFilter : query) {
            // 没在搜时先显示上次存的列表（进页面不是空白转圈），再静默取新的（11-13）
            if query.isEmpty, sessions.isEmpty, let cached = model.api.cached(PastSessionsReply.self, "/api/sessions") {
                sessions = cached.sessions
                truncated = cached.truncated
                loaded = true
            }
            // 打字时等一下再搜
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .refreshable { await load() }
    }

    // MARK: 筛选、显示方式（同会话列表：状态筛选条在左，「显示方式」菜单在右；下面是设备、项目两排胶囊）

    private static var statusOptions: [(String, String, Color?)] { [
        ("all", L("全部"), nil), ("live", L("进行中"), Theme.claude), ("ended", L("已结束"), Color.secondary),
    ] }
    private static var groupOptions: [(String, String)] { [("none", L("按日期")), ("source", L("按来源")), ("project", L("按项目"))] }

    private func matches(_ session: PastSession, _ filter: String) -> Bool {
        switch filter {
        case "live": return session.live
        case "ended": return !session.live
        default: return true
        }
    }

    /// 在筛着的设备、项目里
    private func inScope(_ session: PastSession) -> Bool {
        (activeSource == nil || session.sourceName == activeSource) && (projectFilter.isEmpty || session.project == projectFilter)
    }

    /// 读到的会话来自几台设备（一台就不给按设备筛）
    private var sourceNames: [String] {
        var seen = Set<String>()
        return sessions.map(\.sourceName).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 筛着的那台设备（读到的会话里已经没有它就当没筛）
    private var activeSource: String? {
        sourceFilter.isEmpty || !sourceNames.contains(sourceFilter) ? nil : sourceFilter
    }

    private var isFiltering: Bool { statusFilter != "all" || activeSource != nil || !projectFilter.isEmpty }

    /// 选了某个项目时按项目、按来源分都只剩一组：不给分组，按日期排（项目选「全部」时才有「按项目」）
    private var effectiveGrouping: String { projectFilter.isEmpty ? grouping : "none" }

    private func clearFilters() {
        statusFilter = "all"
        sourceFilter = ""
        projectFilter = ""
    }

    /// 「虚拟机上「ccpulse」项目里已结束的会话」
    private var filterName: String {
        let status = statusFilter == "all" ? "" : Self.statusOptions.first { $0.0 == statusFilter }?.1 ?? ""
        let place = (activeSource.map { L("%@上", $0) } ?? "") + (projectFilter.isEmpty ? "" : L("「%@」项目里", projectFilter))
        return place + L("%@的会话", status)
    }

    /// 设备那排：个数跟着项目筛选走
    private var sourceOptions: [ScopeBar.Option] {
        let inProject = sessions.filter { projectFilter.isEmpty || $0.project == projectFilter }
        return sourceNames.map { name in ScopeBar.Option(id: name, title: name, count: inProject.filter { $0.sourceName == name }.count) }
    }

    /// 项目那排：最近有动静的在前，个数跟着设备筛选走；筛着的项目这会儿一个都没有也列着
    private var projectOptions: [ScopeBar.Option] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for s in sessions.sorted(by: { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }) where activeSource == nil || s.sourceName == activeSource {
            guard !s.project.isEmpty else { continue }
            if counts[s.project] == nil { order.append(s.project) }
            counts[s.project, default: 0] += 1
        }
        if !projectFilter.isEmpty, counts[projectFilter] == nil { order.insert(projectFilter, at: 0) }
        return order.map { ScopeBar.Option(id: $0, title: $0, count: counts[$0] ?? 0) }
    }

    private func filterRows(_ base: [PastSession]) -> some View {
        let projects = projectOptions
        let bySource = sourceNames.count > 1 || activeSource != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FilterBar(trailingBleed: 0) {
                    ForEach(Self.statusOptions, id: \.0) { option in
                        FilterChip(title: option.1, count: base.filter { matches($0, option.0) }.count, dot: option.2,
                                   selected: statusFilter == option.0) {
                            Haptics.tap()
                            withAnimation(.snappy) { statusFilter = statusFilter == option.0 && option.0 != "all" ? "all" : option.0 }
                        }
                    }
                }
                if projectFilter.isEmpty { viewMenu }
            }
            // 不止一台设备、不止一个项目时才有（筛着的时候也留着，好点回全部）
            if bySource {
                ScopeBar(symbol: "desktopcomputer", allTitle: L("全部设备"), options: sourceOptions, selection: $sourceFilter)
            }
            if projects.count > 1 || !projectFilter.isEmpty {
                ScopeBar(symbol: "folder", allTitle: L("全部项目"), options: projects, selection: $projectFilter)
            }
        }
    }

    /// 「显示方式」：分组放在一个菜单里，按钮上写着现在怎么分
    private var viewMenu: some View {
        Menu {
            Picker("分组", selection: $grouping.animation(.snappy)) {
                ForEach(Self.groupOptions, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.inline)
            if grouping != "none" || isFiltering {
                Section {
                    Button {
                        withAnimation(.snappy) { grouping = "none"; clearFilters() }
                    } label: { Label("恢复默认", systemImage: "arrow.counterclockwise") }
                }
            }
        } label: {
            ViewMenuLabel(summary: grouping == "none" ? L("显示方式") : Self.groupOptions.first { $0.0 == grouping }?.1 ?? L("显示方式"),
                          isDefault: grouping == "none")
        }
        .fixedSize()
        .accessibilityLabel("显示方式")
    }

    private struct Day { var title: String; var items: [PastSession] }

    /// 不分组 = 按最后活动的那天；按来源 / 按项目 = 组的先后跟着组里最近的那个会话走，标题带个数
    private func sections(_ sessions: [PastSession]) -> [Day] {
        let grouping = effectiveGrouping
        guard grouping != "none" else { return days(sessions) }
        let bySource = grouping == "source"
        let multi = Set(sessions.map(\.sourceName)).count > 1
        var order: [String] = []
        var map: [String: [PastSession]] = [:]
        var names: [String: String] = [:]
        for s in sessions {
            let key = bySource ? s.sourceName : "\(s.sourceName)\n\(s.cwd ?? "")"
            if map[key] == nil {
                order.append(key)
                let project = s.cwd.map { ($0 as NSString).lastPathComponent } ?? L("（未知目录）")
                names[key] = bySource ? (s.sourceName.isEmpty ? L("未知来源") : s.sourceName) : (multi && !s.sourceName.isEmpty ? "\(project) · \(s.sourceName)" : project)
            }
            map[key, default: []].append(s)
        }
        return order.map { Day(title: "\(names[$0] ?? $0)（\(map[$0]?.count ?? 0)）", items: map[$0] ?? []) }
    }

    /// 按最后活动的那天分组：今天、昨天、星期几、日期
    private func days(_ sessions: [PastSession]) -> [Day] {
        var order: [String] = []
        var map: [String: [PastSession]] = [:]
        for s in sessions {
            let title = s.lastActive.map(dayTitle) ?? L("更早")
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(s)
        }
        return order.map { Day(title: $0, items: map[$0] ?? []) }
    }

    private func dayTitle(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(d) { return L("今天") }
        if calendar.isDateInYesterday(d) { return L("昨天") }
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return c.year == calendar.component(.year, from: Date()) ? L("%@月%@日", "\(c.month ?? 0)", "\(c.day ?? 0)") : L("%@年%@月%@日", "\(c.year ?? 0)", "\(c.month ?? 0)", "\(c.day ?? 0)")
    }

    private func load() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        let project = projectFilter
        do {
            if q.isEmpty { refreshing = true }
            defer { refreshing = false }
            let reply = q.isEmpty ? try await model.api.getCaching(PastSessionsReply.self, "/api/sessions")
                : try await model.api.get(PastSessionsReply.self, "/api/search", ["q": q])
            var list = reply.sessions
            // 按项目筛着时这个项目的会话另外取全，并进列表（各电脑只列最近 120 个，老一些的项目不全）
            if q.isEmpty, !project.isEmpty,
               let more = try? await model.api.get(PastSessionsReply.self, "/api/sessions", ["project": project]) {
                let have = Set(list.map(\.key))
                list += more.sessions.filter { !have.contains($0.key) }
                list.sort { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }
            }
            guard q == query.trimmingCharacters(in: .whitespaces) else { return }
            sessions = list
            truncated = reply.truncated
            errors = reply.errors
        } catch {
            errors = [error.localizedDescription]
        }
        loaded = true
    }
}

struct PastRow: View {
    let session: PastSession
    let searching: Bool
    var query = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(text: Format.initials(session.title), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title).font(.ui(.body)).lineLimit(1)
                    if session.live {
                        Text("进行中").font(.ui(.caption2).weight(.medium)).foregroundStyle(Theme.claude)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.tile, in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Text(Format.listTime(session.lastActive)).font(.ui(.caption)).foregroundStyle(.tertiary)
                }
                Text([session.sourceName, session.cwd.map { ($0 as NSString).lastPathComponent }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                if searching {
                    ForEach(Array(session.hits.prefix(2).enumerated()), id: \.offset) { _, hit in
                        Text((hit.t == "user" ? L("我：") : "Claude：") + hit.snippet).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    // 因为项目名、标题搜到的（没有正文片段）：说一声是哪样对上的
                    if session.hits.isEmpty, let note = matchNote {
                        Text(note).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if let first = session.firstPrompt, first != session.title {
                    Text(first).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 「项目名称：kiteline」「标题：世界模式页面」，搜索词加粗、品牌色
    private var matchNote: AttributedString? {
        let text: String
        if session.match.contains("project") { text = L("项目名称：%@", session.project) }
        else if session.match.contains("title") { text = L("标题：%@", session.title) }
        else { return nil }
        var out = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let range = out.range(of: q, options: .caseInsensitive) {
            out[range].foregroundColor = Theme.claude
            out[range].font = .ui(.footnote).weight(.semibold)
        }
        return out
    }
}

// MARK: 项目

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @State private var projects: [ProjectInfo] = []
    @State private var cost7: [String: Double] = [:]
    @State private var loaded = false
    @State private var errors: [String] = []
    /// 整个读失败（不是某台机器读失败）：显示「加载失败 · 重试」，不显示「0 个项目」
    @State private var failed: String?
    @AppStorage("projectFilter") private var filter = "all"
    /// iPhone 底部「项目」页签的根页面：顶上放历史会话、定时任务两个入口（原来在首页的方格里）
    var tabRoot = false
    /// 后台在取新的（页面上先显示着上次存的）
    @State private var refreshing = false

    var body: some View {
        let shown = projects.filter { p in
            filter == "all" || (filter == "active" && (lives(p).count > 0 || p.today > 0)) || (filter == "dirty" && p.dirty)
        }
        .sorted { (rank($0), $0.lastActive ?? 0) > (rank($1), $1.lastActive ?? 0) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if tabRoot {
                    EntryRows(entries: [
                        EntryRows.Entry(symbol: "clock.arrow.circlepath", title: L("历史会话"), value: nil) { open(.history) },
                        EntryRows.Entry(symbol: "calendar.badge.clock", title: L("定时任务"), value: nil) { open(.schedules) },
                    ])
                    .padding(.bottom, 12)
                }
                // 读到了才显示统计和筛选：还在读时「0 个项目 · 0 个运行中」像是真的没有
                if loaded, failed == nil {
                    Text(stats).font(.ui(.footnote)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    Picker("筛选", selection: $filter) {
                        Text("全部").tag("all")
                        Text("有活动").tag("active")
                        Text("有改动").tag("dirty")
                    }
                    .pickerStyle(.segmented)
                }
                ForEach(shown) { p in
                    Button { open(.project(p)) } label: { ProjectCard(project: p, lives: lives(p), cost7: cost7[p.id] ?? 0) }
                        .buttonStyle(PressableStyle())
                }
                if loaded, failed == nil, shown.isEmpty { PageNote(text: projects.isEmpty ? L("暂无使用过 Claude Code 的项目。") : L("无符合条件的项目。")) }
                if let failed, projects.isEmpty { LoadFailed(error: failed) { await load() }.padding(.top, 40) }
                ForEach(errors, id: \.self) { PageNote(text: $0) }
            }
            .padding(16)
        }
        .tabBarScrollWatch()
        .background(Theme.pageBackground)
        .overlay { if !loaded { ProgressView("正在读取各机器上的项目…") } }
        .navigationTitle("项目")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .updating(refreshing && loaded)
        .task {
            restore()
            await load()
        }
        .refreshable { await load() }
    }

    private func lives(_ p: ProjectInfo) -> [SessionInfo] { model.sessions.filter { $0.sourceId == p.sourceId && $0.cwd == p.cwd } }

    /// 有等你确认的排最前，然后是在干活的、开着会话的
    private func rank(_ p: ProjectInfo) -> Int {
        let l = lives(p)
        if l.contains(where: \.isWaiting) { return 3 }
        if l.contains(where: \.isBusy) { return 2 }
        return l.isEmpty ? 0 : 1
    }

    private var stats: String {
        let live = projects.filter { !lives($0).isEmpty }.count
        let waiting = projects.filter { lives($0).contains(where: \.isWaiting) }.count
        let dirty = projects.filter { $0.changed + $0.untracked > 0 }.count
        let unpushed = projects.filter { $0.ahead > 0 }.count
        return [L("%lld 个项目", count: projects.count), L("%lld 个运行中", count: live), waiting > 0 ? L("%lld 个待确认", count: waiting) : nil,
                dirty > 0 ? L("%lld 个有未提交改动", count: dirty) : nil, unpushed > 0 ? L("%lld 个未推送", count: unpushed) : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// 先显示上次存在手机上的项目和 7 天花费（进页面不是空白转圈），再静默取新的（11-13）
    private func restore() {
        guard projects.isEmpty, let reply = model.api.cached(ProjectsReply.self, "/api/projects", ["detail": "1"]) else { return }
        projects = reply.projects.filter { $0.exists || $0.live > 0 }
        loaded = true
        if let usage = model.api.cached(UsagePayload.self, "/api/usage", ["days": "7"]) {
            cost7 = Dictionary(usage.projects.map { ($0.key, $0.cost) }, uniquingKeysWith: +)
        }
    }

    private func load() async {
        refreshing = true
        defer { refreshing = false }
        do {
            let reply = try await model.api.getCaching(ProjectsReply.self, "/api/projects", ["detail": "1"])
            projects = reply.projects.filter { $0.exists || $0.live > 0 }
            errors = reply.errors
            failed = nil
        } catch {
            // 手上有上次存的就接着显示它，不换成「加载失败」
            if projects.isEmpty { failed = error.localizedDescription }
        }
        loaded = true
        // 7 天花费单独取（要扫 7 天的记录，慢一点），回来后补上
        if let usage = try? await model.api.getCaching(UsagePayload.self, "/api/usage", ["days": "7"]) {
            cost7 = Dictionary(usage.projects.map { ($0.key, $0.cost) }, uniquingKeysWith: +)
        }
    }
}

/// 项目卡片：头像、名字、目录、状态；git 一行；最近提交；今天几个会话、7 天花费
struct ProjectCard: View {
    let project: ProjectInfo
    let lives: [SessionInfo]
    let cost7: Double

    var body: some View {
        let p = project
        let waiting = lives.filter(\.isWaiting).count
        let busy = lives.filter(\.isBusy).count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Avatar(text: Format.initials(p.name), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.ui(.headline)).foregroundStyle(.primary).lineLimit(1)
                    Text("\(p.sourceName) · \(Bytes.shortPath(p.cwd))").font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    if waiting > 0 { Chip(text: waiting > 1 ? L("%lld 个待确认", count: waiting) : L("待确认"), color: .orange) }   // 整句给翻译，别拼
                    else if busy > 0 { Chip(text: busy > 1 ? L("%lld 个进行中", count: busy) : L("进行中"), color: Theme.claude) }
                    else if !lives.isEmpty { Chip(text: L("%lld 个会话运行中", count: lives.count), color: Theme.added) }
                    Text(Bytes.relative(p.lastActive)).font(.ui(.caption2)).foregroundStyle(.tertiary)
                }
            }
            if p.gitTimeout {
                Text(HostPlatform.isMac ? L("Git 状态读取超时 · 可能需要在电脑上允许 Kiteline 访问该文件夹") : L("Git 状态读取超时")).font(.ui(.caption)).foregroundStyle(.orange)
            } else if p.hasGit {
                gitLine.font(.ui(.caption))
                if let commit = p.lastCommit {
                    (Text((p.lastHash ?? "") + " ").font(.ui(.caption).monospaced()).fontDesign(nil).foregroundColor(.secondary)
                     + Text(commit).foregroundColor(.primary)
                     + Text(p.lastCommitAt.map { "  \(Bytes.relative($0))" } ?? "").foregroundColor(.secondary))
                        .font(.ui(.caption)).lineLimit(1)
                }
            } else if let title = p.title {
                Text(title).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            let foot = [p.today > 0 ? L("今天 %@ 个会话", "\(p.today)") : nil, p.sessions > 0 ? L("共 %@ 个", "\(p.sessions)") : nil, cost7 > 0 ? L("7 天 %@", "\(Money.cost(cost7))") : nil].compactMap { $0 }
            if !foot.isEmpty { Text(foot.joined(separator: " · ")).font(.ui(.caption2)).foregroundStyle(.tertiary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var gitLine: Text {
        let p = project
        var line = Text("⎇ \(p.branch ?? "(无分支)")").foregroundColor(.secondary)
        if p.ahead > 0 { line = line + Text(" ↑\(p.ahead)").foregroundColor(Theme.claude) }
        if p.behind > 0 { line = line + Text(" ↓\(p.behind)").foregroundColor(.orange) }
        if p.changed > 0 { line = line + Text(" · \(p.changed) 个改动").foregroundColor(.orange) }
        if p.untracked > 0 { line = line + Text(" · \(p.untracked) 个新文件").foregroundColor(.secondary) }
        if p.changed + p.untracked == 0 { line = line + Text(" · 已全部提交").foregroundColor(Theme.added) }
        return line
    }
}

// MARK: 页面里的小部件

struct StatCard: Hashable {
    enum Tone { case plain, good, bad }
    var value: String
    var label: String
    var sub: String
    var tone: Tone = .plain
}

/// 一格一个数（今日动态、用量顶上那几格）
struct StatGrid: View {
    let cards: [StatCard]
    var columns = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(cards, id: \.self) { card in
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.value).font(.ui(.title2).weight(.bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(card.tone == .bad ? Theme.removed : .primary)
                    Text(card.label).font(.ui(.subheadline)).lineLimit(1)
                    Text(card.sub).font(.ui(.caption)).lineLimit(1)
                        .foregroundStyle(card.tone == .bad ? Theme.removed : (card.tone == .good ? Theme.added : .secondary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

struct Chip: View {
    let text: String
    var color: Color? = nil

    var body: some View {
        Text(text).font(.ui(.caption))
            .foregroundStyle(color ?? .secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background((color ?? Color.primary).opacity(color == nil ? 0.06 : 0.12), in: Capsule())
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.ui(.footnote).weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4).padding(.top, 4)
    }
}

struct PageNote: View {
    let text: String
    var color: Color? = nil
    var body: some View {
        Text(text).font(.ui(.footnote)).foregroundStyle(color ?? .secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// 页面已经显示着上次存的数据、后台在取新的：导航栏右边一个小转圈「更新中」，取完消失（11-13：
/// 进页面先给缓存，后台静默更新，更新时在某个位置转个圈）。没有缓存时页面自己照旧在中间转圈
struct UpdatingMark: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.toolbar {
            if active {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("更新中").font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

extension View {
    /// 后台更新时导航栏右边显示「更新中」
    func updating(_ active: Bool) -> some View { modifier(UpdatingMark(active: active)) }
}

/// 一组入口（同系统设置的分组卡片）：图标一列对齐、标题、右边的值和「›」，行间细线从文字起
struct EntryRows: View {
    struct Entry: Identifiable {
        let symbol: String
        let title: String
        let value: String?
        let action: () -> Void
        var id: String { title }
    }
    let entries: [Entry]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 48) }
                Button(action: entry.action) {
                    HStack(spacing: 12) {
                        Image(systemName: entry.symbol)
                            .font(.app(size: 17))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(entry.title).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if let value = entry.value { Text(value).foregroundStyle(.secondary).monospacedDigit() }
                        Image(systemName: "chevron.right").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.ui(.body))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 一行「标题 … 值 ›」，可以单独成卡片
struct LinkRow: View {
    let title: String
    var value: String? = nil
    var boxed = true

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if let value { Text(value).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.tertiary)
        }
        .font(.ui(.subheadline))
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(boxed ? Theme.card : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// 一排排自动换行（标签用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
