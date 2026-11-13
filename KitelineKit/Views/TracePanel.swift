import SwiftUI

/// 执行过程面板：对话页右上角的悬浮按钮打开，放在对话页上面 1/3（下面照常聊天；iPhone 横放时左右排；分隔条可拖，见 TraceSplit）。
/// 上面是概览（时长 / agent / 轮次 / 模型调用 / 工具调用 / 出错、按分钟的活动条，可收起）；
/// 下面是时间线：从上到下一行一个 agent / 轮次 / 步骤（一层层点开），从左到右是时间（空闲超过 10 分钟的折成一道缝）；
/// 顶上的时间刻度不随上下滚动、左边的名字列不随左右滚动。默认「适应」：整场会话正好铺满一屏宽，也可选 3 小时 / 1 小时 / 15 分钟一屏或放大缩小。
/// 轮次的时间条按模型调用 / 工具调用 / 出错分段着色，出错处有红色菱形，派出子 agent 的时刻有一道细竖线；点轮次的条看用时拆分。
/// 「回放」把整场会话十几秒重演一遍（播放线从左走到右，数字往上涨，新的 agent、轮次一行行冒出来，画面跟着走）；
/// 「跟随」打开后画面自己往下、往右跟着最新一步走。点一步在底部看详情；一键跳到第一处出错。开着时每几秒刷新一次。
struct TracePanel: View {
    @Environment(AppModel.self) private var model
    let key: String
    var onClose: () -> Void

    @State private var reply: TraceReply?
    @State private var error: String?
    /// 展开着的 agent、轮次（「agent:轮次」）
    @State private var openAgents: Set<String> = []
    @State private var openTurns: Set<String> = []
    /// 底部详情：点了哪一步（「agent:轮次:序号」）或哪一轮的条（「agent:轮次」，看用时拆分）
    @State private var selected: String?
    @State private var selectedTurn: String?
    /// 各轮的步骤（上次拉到的；没在跑的轮次不用每次重拉）
    @State private var steps: [String: TraceSteps] = [:]
    /// 跟着最新一轮走：用户自己收起过就不再自动展开新的
    @State private var follow = true
    /// 要滚到哪（每次请求带新编号：跟随时反复滚到同一步也会触发）
    @State private var scrollTarget: ScrollRequest?
    @State private var scrollAnchor: UnitPoint = .center
    /// 跟随运镜：打开后每次刷新都展开最新在跑的那一轮，画面往下、往右跟到最新一步；手动拖动就退出
    @State private var camera = false
    /// 运镜自己展开的轮次：跟到下一轮时收起它（用户自己展开的不动）
    @State private var cameraOpened: Set<String> = []
    @State private var reloadTick = 0
    /// 刚打开要滚到的地方（主 agent 最新一轮）
    @State private var initialTarget: String?
    /// 时间轴缩放：适应宽度 / 一屏多少分钟 / 每分钟多少点
    @State private var zoom: TraceZoom = .fit
    /// 概览收起（窄、矮的时候默认收起，把地方让给时间线）
    @State private var overviewOpen: Bool?
    @State private var panelSize: CGSize = .zero
    /// 时间线滚到哪了：左列、表头按它反向挪，看起来就不动
    @State private var offset: CGPoint = .zero
    /// 回放：进度 0…1（nil = 没在回放）、倍速；回放前展开着的 agent（回放完还原）
    @State private var replay: Double?
    @State private var replaySpeed: Double = 2
    @State private var replayTask: Task<Void, Never>?
    @State private var replaySaved: Set<String>?
    @State private var replayRow: String?

    private static let space = "trace-grid"
    /// 1 倍速回放一整场用多久（秒）
    private static let replaySeconds: Double = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let reply {
                if reply.unsupported {
                    hint(L("这个 Agent 不记录可读取的执行过程"))
                } else if reply.agents.allSatisfy({ $0.turns.isEmpty }) {
                    hint(L("暂无执行记录"))
                } else {
                    let now = reply.now ?? Date().timeIntervalSince1970 * 1000
                    let base = TimeMap(reply: reply, now: now, perMinute: 60)
                    let labelWidth: CGFloat = min(280, max(170, (panelSize.width * 0.5).rounded()))
                    let map = TimeMap(reply: reply, now: now, perMinute: perMinute(base: base, room: panelSize.width - labelWidth))
                    let cut = replay.map { map.time(atX: map.startX + (map.endX - map.startX) * CGFloat($0)) }
                    overviewBar(reply, cut: cut, now: now)
                    Divider()
                    grid(reply, map: map, cut: cut, now: now, labelWidth: labelWidth)
                    if let selected, let step = step(for: selected) {
                        Divider()
                        detailCard(step, key: selected)
                    } else if let selectedTurn, let found = turn(for: selectedTurn, in: reply) {
                        Divider()
                        turnCard(found.turn, agent: found.agent, now: now)
                    }
                }
            } else if let error {
                LoadFailed(error: error) { await load() }.padding(.top, 40)
                Spacer(minLength: 0)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(TraceColor.panel)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
        .task(id: reloadTick) {
            // 开着时一直刷新：跟随时 2 秒一次，有在跑的 3 秒，都停了 8 秒；回放时不刷新（数据先定住）
            while !Task.isCancelled {
                if replay == nil { await load() }
                try? await Task.sleep(for: .seconds(camera ? 2 : (reply?.running == false ? 8 : 3)))
            }
        }
        .onDisappear { replayTask?.cancel() }
    }

    /// 每分钟多少点：适应 = 整场正好铺满可见宽度；一屏 N 分钟；或固定档位
    private func perMinute(base: TimeMap, room: CGFloat) -> CGFloat {
        let room = max(120, room)
        switch zoom {
        case .fit:
            let fixed = TimeMap.lead + TimeMap.trail + CGFloat(max(0, base.segments.count - 1)) * TraceGrid.gapWidth
            let span = max(1, base.width - fixed)    // 每分钟 60 点时有动静的部分多宽
            return max(0.05, 60 * (room - fixed) / span)
        case .window(let minutes):
            return max(0.05, room / CGFloat(minutes))
        case .scale(let index):
            return TraceGrid.scales[min(max(0, index), TraceGrid.scales.count - 1)]
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "align.horizontal.left")
                .font(.ui(.subheadline)).foregroundStyle(Theme.claude)
            Text("执行过程").font(.ui(.headline)).lineLimit(1)
            if replay != nil {
                Text("回放中").font(.ui(.caption)).foregroundStyle(.secondary)
            } else if reply?.running == true {
                LiveDot()
                if panelSize.width > 420 { Text("进行中").font(.ui(.caption)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if let progress = replay {
                // 回放中：倍速（轻点换档）+ 停止（带剩余秒数）
                pill(String(format: "%g×", replaySpeed), icon: nil, on: false) { cycleSpeed() }
                    .accessibilityLabel(L("回放速度"))
                pill(L("停止") + " " + remaining(progress), icon: "stop.fill", on: true) { stopReplay() }
            } else {
                pill(L("回放"), icon: "play.fill", on: false) { startReplay() }
                    .disabled(reply == nil || reply?.agents.allSatisfy({ $0.turns.isEmpty }) != false)
                pill(camera ? L("跟随中") : L("跟随"), icon: camera ? "scope" : "viewfinder", on: camera) {
                    camera.toggle()
                    if camera { followLatest(reply) }
                }
                .accessibilityLabel(camera ? L("停止跟随进度") : L("跟随进度自动滚动"))
            }
            Button { onClose() } label: {
                Image(systemName: "xmark").font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭执行过程")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    /// 顶栏的小胶囊按钮：选中态淡色底 + 细边
    private func pill(_ title: String, icon: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).monospacedDigit()
            }
            .font(.ui(.caption).weight(.medium))
            .foregroundStyle(on ? Theme.claude : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(on ? Theme.claude.opacity(0.1) : Color.clear, in: Capsule(style: .circular))
            .overlay(Capsule(style: .circular).strokeBorder(on ? Theme.claude.opacity(0.35) : Color.primary.opacity(0.15), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Text(text).font(.ui(.footnote)).foregroundStyle(.secondary).padding(.top, 40)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 概览：一行摘要（点开是统计 + 活动条）+ 第一处出错

    private var showOverview: Bool { overviewOpen ?? (panelSize.height > 620 && panelSize.width > 420) }

    private func overviewBar(_ reply: TraceReply, cut: Double?, now: Double) -> some View {
        let stats = TraceTally(reply: reply, cut: cut)
        let span = TraceFormat.span(reply.start, cut ?? (reply.running ? nil : reply.end), now: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy) { overviewOpen = !showOverview } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showOverview ? 90 : 0))
                        Text([span, L("%lld 个 agent", count: stats.agents), L("%lld 轮", count: stats.turns),
                              L("%lld 次模型调用", count: stats.llm), L("%lld 次工具调用", count: stats.tools)]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                            .contentTransition(.numericText())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if let first = reply.firstError, cut == nil {
                    Button { jump(to: first) } label: {
                        Label(panelSize.width > 380 ? L("第一处出错") : "", systemImage: "exclamationmark.triangle")
                            .font(.ui(.caption).weight(.medium)).foregroundStyle(TraceColor.red)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(TraceColor.red.opacity(0.08), in: Capsule(style: .circular))
                            .overlay(Capsule(style: .circular).strokeBorder(TraceColor.red.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("跳到第一处出错")
                }
            }
            if showOverview {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    StatTile(label: L("时长"), value: span,
                             sub: cut == nil && reply.stats.busyMs > 0 ? L("忙碌 %@", TraceFormat.ms(reply.stats.busyMs)) : nil)
                    StatTile(label: L("Agent"), value: "\(stats.agents)",
                             sub: stats.agents > 1 ? L("1 个主 agent · %lld 个子 agent", count: stats.agents - 1) : L("仅主 agent"))
                    StatTile(label: L("轮次"), value: "\(stats.turns)",
                             sub: cut == nil ? reply.stats.medianTurn.map { L("中位 %@", TraceFormat.ms($0)) } : nil)
                    StatTile(label: L("模型调用"), value: "\(stats.llm)", sub: nil)
                    StatTile(label: L("工具调用"), value: "\(stats.tools)", sub: nil)
                    StatTile(label: L("出错"), value: "\(stats.errors)", sub: nil, alert: stats.errors > 0)
                }
                if !reply.activity.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Text("活动").font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
                            Legend(color: TraceColor.llm, text: L("模型调用"))
                            Legend(color: TraceColor.tool, text: L("工具调用"))
                            Legend(color: TraceColor.red, text: L("出错"))
                            Spacer(minLength: 0)
                        }
                        ActivityStrip(buckets: cut.map { t in reply.activity.filter { ($0.first ?? 0) <= t } } ?? reply.activity)
                            .frame(height: 36)
                        Text("每格 1 分钟，空闲时段已折叠").font(.ui(.caption2)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: 时间线（表头不动、左列不动）

    private func grid(_ reply: TraceReply, map: TimeMap, cut: Double?, now: Double, labelWidth: CGFloat) -> some View {
        let rows = gridRows(reply, cut: cut)
        let header = TraceGrid.headerHeight
        let bodyHeight = CGFloat(rows.count) * TraceGrid.rowHeight
        let nowX = map.x(cut ?? now)
        // 派出子 agent 的时刻：一道细竖线
        let spawns = reply.agents.filter { !$0.isMain }.compactMap(\.start).filter { $0 <= (cut ?? .infinity) }.map { map.x($0) }
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // 右边：每行一条时间条（真正被滚动的内容）
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            barRow(row, map: map, now: cut ?? now).frame(width: map.width, height: TraceGrid.rowHeight)
                        }
                    }
                    .background(alignment: .topLeading) { GridLines(map: map, height: bodyHeight, spawns: spawns) }
                    .overlay(alignment: .topLeading) {
                        // 现在 / 回放的播放线
                        if reply.running || cut != nil {
                            Rectangle().fill(cut != nil ? Color.primary.opacity(0.8) : Theme.claude.opacity(0.7))
                                .frame(width: cut != nil ? 1.5 : 1, height: bodyHeight)
                                .padding(.leading, nowX)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.leading, labelWidth).padding(.top, header)
                    // 左列：名字。横着滚的时候反向挪，看起来不动
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            labelCell(row, now: cut ?? now, span: labelWidth >= 220).frame(width: labelWidth, height: TraceGrid.rowHeight)
                        }
                    }
                    .background(TraceColor.panel)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1) }
                    .padding(.top, header)
                    .offset(x: offset.x)
                    // 表头：时间刻度。竖着滚的时候反向挪
                    AxisHeader(map: map, playhead: cut != nil ? nowX : nil)
                        .frame(width: map.width, height: header)
                        .background(TraceColor.panel)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
                        .padding(.leading, labelWidth)
                        .offset(y: offset.y)
                    // 左上角：两个方向都不动；放缩放
                    corner(width: labelWidth, height: header, perMinute: map.perMs * 60_000)
                        .offset(x: offset.x, y: offset.y)
                }
                .frame(width: labelWidth + map.width, height: header + bodyHeight, alignment: .topLeading)
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(Self.space)).origin } action: { origin in
                    offset = CGPoint(x: max(0, -origin.x), y: max(0, -origin.y))
                }
            }
            .coordinateSpace(name: Self.space)
            // 手指拖动：退出跟随（别跟用户抢画面）
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in if camera { camera = false } })
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.smooth(duration: replay != nil ? 0.3 : 0.45)) { proxy.scrollTo(target.id, anchor: target.anchor) }
            }
            // 时间线刚出现（第一次拉到数据、从「暂无记录」变过来）：之前要滚的这时才滚得到
            .onAppear {
                guard let target = scrollTarget else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
            }
            // 回放：最新冒出来的那行变了就跟过去
            .onChange(of: rows.last(where: { $0.start != nil && $0.kind != .step })?.id) { _, id in
                guard replay != nil, let id, id != replayRow else { return }
                replayRow = id
                scrollTarget = ScrollRequest(id: "bar:\(id)", anchor: UnitPoint(x: 0.6, y: 0.9))
            }
        }
    }

    private func corner(width: CGFloat, height: CGFloat, perMinute: CGFloat) -> some View {
        HStack(spacing: 2) {
            Text("名称").font(.ui(.caption2).weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Menu {
                Button { zoom = .fit } label: { Label("适应宽度", systemImage: zoom == .fit ? "checkmark" : "arrow.left.and.right") }
                windowButton(180, L("一屏 3 小时"))
                windowButton(60, L("一屏 1 小时"))
                windowButton(15, L("一屏 15 分钟"))
                Divider()
                Button { zoom = .scale(TraceGrid.nearest(perMinute, step: 1)) } label: { Label("放大", systemImage: "plus.magnifyingglass") }
                Button { zoom = .scale(TraceGrid.nearest(perMinute, step: -1)) } label: { Label("缩小", systemImage: "minus.magnifyingglass") }
            } label: {
                HStack(spacing: 2) {
                    Text(zoomTitle).font(.ui(.caption2).weight(.medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).frame(height: 22)
                .overlay(Capsule(style: .circular).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("时间轴缩放")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(width: width, height: height)
        .background(TraceColor.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1) }
    }

    @ViewBuilder private func windowButton(_ minutes: Double, _ title: String) -> some View {
        Button { zoom = .window(minutes) } label: {
            if zoom == .window(minutes) { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var zoomTitle: String {
        switch zoom {
        case .fit: return L("适应")
        case .window(let minutes): return minutes >= 60 ? L("%lld 小时", count: Int(minutes / 60)) : L("%lld 分钟", count: Int(minutes))
        case .scale: return L("自定")
        }
    }

    // MARK: 行

    /// 从上到下排好的行：agent（主的在前，子 agent 跟在派它的后面）→ 展开的轮次 → 展开的轮次里的步骤。
    /// 回放时（cut = 播放到的时刻）只留那时已经开始的，还没结束的画到播放线
    private func gridRows(_ reply: TraceReply, cut: Double?) -> [TraceGridRow] {
        func started(_ t: Double?) -> Bool { cut == nil || (t ?? .infinity) <= cut! }
        func clipEnd(_ end: Double?, running: Bool) -> Double? {
            guard let cut else { return running ? nil : end }
            guard let end, !running else { return nil }
            return end <= cut ? end : nil
        }
        var out: [TraceGridRow] = []
        for entry in ordered(reply.agents) where started(entry.agent.start) {
            let agent = entry.agent
            let agentOpen = openAgents.contains(agent.id)
            let agentEnd = clipEnd(agent.end, running: agent.running)
            let turnsSoFar = agent.turns.filter { started($0.start) }
            let agentErrors = turnsSoFar.flatMap(\.errAt).filter { cut == nil || $0 <= cut! }
            out.append(TraceGridRow(id: "agent:\(agent.id)", kind: .agent, depth: entry.depth, title: agentTitle(agent), sub: agentSub(agent),
                                    icon: nil, start: agent.start, end: agentEnd,
                                    status: agentEnd == nil ? .running : (agentErrors.isEmpty ? .done : .failed),
                                    open: agentOpen, agentId: agent.id, turnKey: nil, stepKey: nil, tone: .agent,
                                    segs: [], errAt: agentErrors))
            guard agentOpen else { continue }
            for turn in turnsSoFar {
                let turnKey = "\(agent.id):\(turn.i)"
                let turnOpen = openTurns.contains(turnKey)
                let turnEnd = clipEnd(turn.end, running: turn.running)
                let errAt = turn.errAt.filter { cut == nil || $0 <= cut! }
                out.append(TraceGridRow(id: "turn:\(turnKey)", kind: .turn, depth: entry.depth + 1,
                                        title: L("第 %lld 轮", count: turn.i) + " " + turn.displayTitle, sub: nil, icon: nil,
                                        start: turn.start, end: turnEnd,
                                        status: turnEnd == nil ? .running : (errAt.isEmpty ? .done : .failed),
                                        open: turnOpen || selectedTurn == turnKey, agentId: agent.id, turnKey: turnKey, stepKey: nil, tone: .turn,
                                        segs: turn.segs, errAt: errAt))
                guard turnOpen else { continue }
                if let loaded = steps[turnKey] {
                    for step in loaded.items where started(step.start) {
                        let stepKey = "\(turnKey):\(step.n)"
                        let pending = (step.pending && turn.running) || (cut != nil && (step.end ?? .infinity) > cut!)
                        out.append(TraceGridRow(id: "step:\(stepKey)", kind: .step, depth: entry.depth + 2,
                                                title: stepTitle(step) + (stepLine(step).map { " · " + $0 } ?? ""), sub: nil, icon: icon(step),
                                                start: step.start, end: pending ? nil : (step.end ?? step.start),
                                                status: pending ? .running : (step.failed ? .failed : .none),
                                                open: selected == stepKey, agentId: agent.id, turnKey: turnKey, stepKey: stepKey,
                                                tone: step.failed ? .error : (step.k == "llm" ? .llm : (step.k == "tool" ? .tool : .event)),
                                                segs: [], errAt: []))
                    }
                } else {
                    out.append(TraceGridRow(id: "loading:\(turnKey)", kind: .loading, depth: entry.depth + 2, title: L("正在加载…"), sub: nil,
                                            icon: nil, start: nil, end: nil, status: .none, open: false, agentId: agent.id,
                                            turnKey: turnKey, stepKey: nil, tone: .event, segs: [], errAt: []))
                }
            }
        }
        return out
    }

    private func labelCell(_ row: TraceGridRow, now: Double, span: Bool) -> some View {
        Button { tapLabel(row) } label: {
            HStack(spacing: 6) {
                if row.kind == .agent || row.kind == .turn {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded(row) ? 90 : 0)).frame(width: 10)
                } else {
                    Color.clear.frame(width: 10)
                }
                if let icon = row.icon {
                    Image(systemName: icon).font(.system(size: 11))
                        .foregroundStyle(row.status == .failed ? TraceColor.red : (row.status == .running ? Theme.claude : Color.secondary))
                        .frame(width: 14)
                } else {
                    TraceStatusDot(status: row.status).frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(row.kind == .agent ? .ui(.footnote).weight(.semibold) : .ui(.caption))
                        .foregroundStyle(row.status == .failed && row.kind == .step ? TraceColor.red : (row.kind == .loading ? Color.secondary : Color.primary))
                        .lineLimit(1)
                    if let sub = row.sub {
                        Text(sub).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                if span, row.start != nil {
                    Text(TraceFormat.span(row.start, row.end, now: now)).font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary).fixedSize()
                }
            }
            .padding(.leading, 8 + CGFloat(row.depth) * 12).padding(.trailing, 8)
            .frame(maxHeight: .infinity)
            .background(row.open && row.kind != .agent && !isExpanded(row) || (row.kind == .step && row.open)
                        ? Theme.claude.opacity(0.08) : (row.kind == .agent ? Color.primary.opacity(0.035) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isExpanded(_ row: TraceGridRow) -> Bool {
        switch row.kind {
        case .agent: return openAgents.contains(row.agentId)
        case .turn: return row.turnKey.map { openTurns.contains($0) } ?? false
        default: return false
        }
    }

    /// 一行的时间条：放在它开始的位置、按用时画长；轮次按模型 / 工具 / 出错分段着色；出错处红色菱形；还在跑的末端呼吸
    private func barRow(_ row: TraceGridRow, map: TimeMap, now: Double) -> some View {
        let start = row.start.map { map.x($0) }
        let end = map.x(row.end ?? now)
        return HStack(spacing: 0) {
            if let start, let origin = row.start {
                Color.clear.frame(width: max(0, start))
                Button { tapBar(row) } label: {
                    TimeBar(tone: row.tone, running: row.status == .running,
                            selected: (row.kind == .step && row.open) || (row.kind == .turn && selectedTurn == row.turnKey),
                            height: row.kind == .step ? 12 : (row.kind == .agent ? 16 : 14),
                            segs: row.segs, errAt: row.errAt, origin: origin, limit: row.end ?? now, map: map, x0: start)
                        .frame(width: max(3, end - start))
                }
                .buttonStyle(.plain)
                .id("bar:\(row.id)")
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(row.kind == .agent ? Color.primary.opacity(0.035) : .clear)
    }

    private func tapLabel(_ row: TraceGridRow) {
        switch row.kind {
        case .agent: toggle(agent: row.agentId)
        case .turn: if let key = row.turnKey { toggle(turn: key) }
        case .step: if let key = row.stepKey { selected = selected == key ? nil : key; selectedTurn = nil }
        case .loading: break
        }
    }

    /// 点时间条：轮次看用时拆分，步骤看详情，agent 展开 / 收起
    private func tapBar(_ row: TraceGridRow) {
        switch row.kind {
        case .turn:
            if let key = row.turnKey { selectedTurn = selectedTurn == key ? nil : key; selected = nil }
        default: tapLabel(row)
        }
    }

    private func step(for key: String) -> TraceStep? {
        let parts = key.split(separator: ":")
        guard parts.count == 3, let n = Int(parts[2]) else { return nil }
        return steps["\(parts[0]):\(parts[1])"]?.items.first { $0.n == n }
    }

    private func turn(for key: String, in reply: TraceReply) -> (agent: TraceAgent, turn: TraceTurn)? {
        let parts = key.split(separator: ":")
        guard parts.count == 2, let i = Int(parts[1]), let agent = reply.agents.first(where: { $0.id == parts[0] }),
              let turn = agent.turns.first(where: { $0.i == i }) else { return nil }
        return (agent, turn)
    }

    /// 底部详情：选中的那一步（模型调用看思考和输出，工具调用看命令和结果）
    private func detailCard(_ step: TraceStep, key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon(step)).font(.ui(.caption)).foregroundStyle(step.failed ? TraceColor.red : Theme.claude)
                Text(stepTitle(step)).font(.ui(.footnote).weight(.semibold)).lineLimit(1)
                if let start = step.start {
                    Text(TraceFormat.span(start, step.end, now: reply?.now ?? Date().timeIntervalSince1970 * 1000))
                        .font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { selected = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.ui(.subheadline)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("关闭详情")
            }
            ScrollView {
                StepDetail(step: step) { agentId in jump(toAgent: agentId) }
            }
            .frame(maxHeight: max(120, panelSize.height * 0.32))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(TraceColor.raised)
    }

    /// 底部的轮次用时拆分：模型 / 工具 / 失败 / 等待 各多少次、多久、占几成（同视频里指着轮次条的提示）
    private func turnCard(_ turn: TraceTurn, agent: TraceAgent, now: Double) -> some View {
        let total = max(1, turn.llmMs + turn.toolMs + turn.failMs + turn.waitMs)
        let clock: (Double?) -> String = { ms in
            guard let ms else { return "" }
            return Date(timeIntervalSince1970: ms / 1000).formatted(date: .omitted, time: .shortened)
        }
        let parts: [(String, Color, String, Double)] = [
            (L("模型调用"), TraceColor.llm, L("%lld 次", count: turn.llm), turn.llmMs),
            (L("工具调用"), TraceColor.tool, L("%lld 次", count: turn.tools), turn.toolMs),
            (L("失败"), TraceColor.red, "", turn.failMs),
            (L("等待"), Color.secondary.opacity(0.3), "", turn.waitMs),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L("第 %lld 轮", count: turn.i)).font(.ui(.footnote).weight(.semibold))
                Text("\(clock(turn.start)) – \(turn.running ? L("现在") : clock(turn.end)) · \(TraceFormat.span(turn.start, turn.running ? nil : turn.end, now: now))")
                    .font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button { selectedTurn = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.ui(.subheadline)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("关闭详情")
            }
            Text(turn.displayTitle).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
            // 一条按比例分段的横条
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(parts.indices.filter { parts[$0].3 > 0 }, id: \.self) { i in
                        Rectangle().fill(parts[i].1).frame(width: max(2, proxy.size.width * CGFloat(parts[i].3 / total)))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule(style: .circular))
            ForEach(parts.indices.filter { parts[$0].3 > 0 || $0 < 2 }, id: \.self) { i in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(parts[i].1).frame(width: 8, height: 8)
                    Text(parts[i].0).font(.ui(.caption))
                    if !parts[i].2.isEmpty { Text(parts[i].2).font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Text(TraceFormat.ms(parts[i].3)).font(.ui(.caption).monospacedDigit())
                    Text("\(Int((parts[i].3 / total * 100).rounded()))%").font(.ui(.caption).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            if turn.toolMs + turn.llmMs > total * 0.999 && turn.waitMs == 0 && turn.toolMs > 0 {
                Text("工具有并行或后台运行，各项合计可能超过本轮用时").font(.ui(.caption2)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(TraceColor.raised)
    }

    // MARK: 回放

    private func startReplay() {
        guard reply != nil else { return }
        camera = false
        selected = nil
        selectedTurn = nil
        replaySaved = openAgents
        // 回放时所有 agent 都展开到轮次（新的 agent、轮次一行行冒出来）
        openAgents = Set(reply?.agents.map(\.id) ?? [])
        replayRow = nil
        replay = 0
        replayTask?.cancel()
        replayTask = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled, let progress = replay {
                try? await Task.sleep(for: .milliseconds(33))
                let now = Date()
                let step = now.timeIntervalSince(last) * replaySpeed / Self.replaySeconds
                last = now
                let next = progress + step
                if next >= 1 {
                    replay = 1
                    try? await Task.sleep(for: .milliseconds(600))
                    stopReplay()
                    break
                }
                replay = next
            }
        }
    }

    private func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
        replay = nil
        replayRow = nil
        if let saved = replaySaved { openAgents = saved }
        replaySaved = nil
        reloadTick += 1
    }

    private func cycleSpeed() {
        let speeds: [Double] = [1, 2, 4, 8]
        replaySpeed = speeds[((speeds.firstIndex(of: replaySpeed) ?? 0) + 1) % speeds.count]
    }

    private func remaining(_ progress: Double) -> String {
        let seconds = Int(((1 - progress) * Self.replaySeconds / replaySpeed).rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: 文案

    /// 主 agent 在最前，子 agent 按「谁派的」排在派它的 agent 后面，缩进一层
    private func ordered(_ agents: [TraceAgent]) -> [TraceEntry] {
        var out: [TraceEntry] = []
        var seen = Set<String>()
        func visit(_ agent: TraceAgent, _ depth: Int) {
            guard seen.insert(agent.id).inserted else { return }
            out.append(TraceEntry(agent: agent, depth: depth))
            for child in agents where child.parent == agent.id {
                visit(child, min(depth + 1, 4))
            }
        }
        for root in agents where root.isMain { visit(root, 0) }
        for rest in agents where !seen.contains(rest.id) { visit(rest, 1) }
        return out
    }

    private func agentTitle(_ agent: TraceAgent) -> String {
        if agent.isMain { return agent.title.isEmpty ? L("主 agent") : agent.title }
        return agent.title.isEmpty ? L("子 agent") : agent.title
    }

    private func agentSub(_ agent: TraceAgent) -> String {
        var parts: [String] = []
        if agent.isMain {
            parts.append(L("主 agent"))
        } else if let from = agent.fromTurn {
            parts.append(agent.parent == "main" || agent.parent == nil ? L("由第 %lld 轮派出", count: from) : L("由上级子 agent 第 %lld 轮派出", count: from))
        } else {
            parts.append(L("子 agent"))
        }
        parts.append(L("%lld 次模型调用", count: agent.llm))
        parts.append(L("%lld 次工具调用", count: agent.tools))
        if agent.errors > 0 { parts.append(L("%lld 处出错", count: agent.errors)) }
        return parts.joined(separator: " · ")
    }

    private func icon(_ step: TraceStep) -> String {
        switch step.k {
        case "llm": return "sparkles"
        case "error": return "exclamationmark.triangle"
        case "user": return "person.crop.circle"
        case "event": return "info.circle"
        default: break
        }
        switch step.name ?? "" {
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Read", "NotebookRead": return "doc.text"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "pencil"
        case "Grep", "Glob", "ToolSearch": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Agent", "Task", "SendMessage": return "person.2"
        case "TodoWrite": return "checklist"
        case "Skill": return "wand.and.stars"
        default: return "wrench.and.screwdriver"
        }
    }

    private func stepTitle(_ step: TraceStep) -> String {
        switch step.k {
        case "llm":
            var parts = [L("模型调用")]
            let name = TraceFormat.model(step.model)
            if !name.isEmpty { parts.append(name) }
            if step.thought { parts.append(L("含思考")) }
            return parts.joined(separator: " · ")
        case "tool": return step.name ?? L("工具")
        case "error": return L("出错")
        case "user": return L("中途插话")
        default: return step.text ?? L("事件")
        }
    }

    private func stepLine(_ step: TraceStep) -> String? {
        func first(_ text: String?) -> String? {
            text?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        switch step.k {
        case "llm":
            if let text = first(step.text), !text.isEmpty { return text }
            return nil
        case "tool":
            let brief = step.brief ?? ""
            let name = step.name ?? ""
            // 「Bash: npm test」去掉前面重复的工具名
            if !name.isEmpty, brief.hasPrefix(name + ": ") { return String(brief.dropFirst(name.count + 2)) }
            return brief == name || brief.isEmpty ? nil : brief
        case "error", "user": return first(step.text)
        default: return nil
        }
    }

    // MARK: 展开、跳转

    private func toggle(agent id: String) {
        if openAgents.remove(id) == nil { openAgents.insert(id) }
    }

    private func toggle(turn key: String) {
        if openTurns.remove(key) == nil {
            openTurns.insert(key)
            if steps[key] == nil { reloadTick += 1 }    // 马上拉这一轮的步骤，不等下一次刷新
        } else {
            if key.hasPrefix("main:") { follow = false }
            if let selected, selected.hasPrefix(key + ":") { self.selected = nil }
        }
    }

    private func jump(to ref: TraceErrorRef) {
        let turnKey = "\(ref.agent):\(ref.turn)"
        openAgents.insert(ref.agent)
        openTurns.insert(turnKey)
        selected = "\(turnKey):\(ref.step)"
        selectedTurn = nil
        expandParents(of: ref.agent)
        camera = false
        scrollAnchor = .center
        Task {
            if steps[turnKey] == nil { await load() }
            scrollTarget = ScrollRequest(id: "bar:step:\(turnKey):\(ref.step)", anchor: scrollAnchor)
        }
    }

    private func jump(toAgent id: String) {
        openAgents.insert(id)
        expandParents(of: id)
        if let agent = reply?.agents.first(where: { $0.id == id }), let last = agent.turns.last {
            openTurns.insert("\(id):\(last.i)")
            reloadTick += 1
        }
        camera = false
        selected = nil
        scrollAnchor = .center
        scrollTarget = ScrollRequest(id: "bar:agent:\(id)", anchor: scrollAnchor)
    }

    private func expandParents(of id: String) {
        guard let agents = reply?.agents else { return }
        var cursor = agents.first { $0.id == id }?.parent
        var guardCount = 0
        while let parent = cursor, guardCount < 8 {
            openAgents.insert(parent)
            cursor = agents.first { $0.id == parent }?.parent
            guardCount += 1
        }
    }

    // MARK: 加载

    private func load() async {
        // 只重拉展开着、还在跑或还没拉过的轮次
        let running = Set(reply?.agents.flatMap { agent in agent.turns.filter(\.running).map { "\(agent.id):\($0.i)" } } ?? [])
        let wanted = openTurns.filter { steps[$0] == nil || running.contains($0) }.sorted()
        // 没有要补拉的步骤时带上版本号：电脑那边没变就只回一句，不重传整份
        let rev = wanted.isEmpty ? (reply?.rev ?? "") : ""
        do {
            let fresh = try await model.api.get(TraceReply.self, "/api/trace", ["key": key, "expand": wanted.joined(separator: ","), "rev": rev])
            if fresh.same { return }
            let firstLoad = reply == nil
            for (turnKey, value) in fresh.steps { steps[turnKey] = value }
            settle(fresh)
            reply = fresh
            error = nil
            #if SNAPSHOT
            // 截图版：看跟随、看出错详情、看回放的样子
            if firstLoad && Snapshot.sheet == "tracefollow" { camera = true }
            if firstLoad && Snapshot.sheet == "traceerror", let first = fresh.firstError { initialTarget = nil; jump(to: first) }
            if firstLoad, let at = Snapshot.sheet.flatMap({ $0.hasPrefix("tracereplay") ? Double($0.dropFirst(11)) : nil }) {
                startReplay(); replayTask?.cancel(); replay = at / 100
            }
            #else
            _ = firstLoad
            #endif
            if camera {
                followLatest(fresh)
            } else if let target = initialTarget, steps[target.replacingOccurrences(of: "bar:turn:", with: "")] != nil {
                // 第一次：这一轮的步骤到了、时间线也画出来了再滚过去（太早滚，滚动区还没出来，会落空）
                initialTarget = nil
                try? await Task.sleep(for: .milliseconds(200))
                scrollAnchor = UnitPoint(x: 0.85, y: 0.25)
                scrollTarget = ScrollRequest(id: target, anchor: scrollAnchor)
            }
        } catch {
            if reply == nil { self.error = error.localizedDescription }
        }
    }

    /// 跟随运镜：找最近有动静的那一轮（在跑的优先，按最后活动时间），展开它和上级，画面往下、往右移到它的最新一步
    private func followLatest(_ reply: TraceReply?) {
        guard let reply else { return }
        var best: (agent: TraceAgent, turn: TraceTurn)?
        func score(_ turn: TraceTurn) -> Double { (turn.running ? 1e15 : 0) + (turn.end ?? turn.start ?? 0) }
        for agent in reply.agents {
            guard let turn = agent.turns.last else { continue }
            // 打平时取后面的（子 agent 排在派它的后面，更具体：主 agent 在等子 agent 时跟到子 agent 上）
            if best == nil || score(turn) >= score(best!.turn) { best = (agent, turn) }
        }
        guard let (agent, turn) = best else { return }
        let turnKey = "\(agent.id):\(turn.i)"
        openAgents.insert(agent.id)
        expandParents(of: agent.id)
        if !openTurns.contains(turnKey) {
            for old in cameraOpened where old != turnKey { openTurns.remove(old) }
            cameraOpened = [turnKey]
            openTurns.insert(turnKey)
        }
        // 时间条的末端放在右下（往右还留一点看得到「现在」那条线）
        scrollAnchor = UnitPoint(x: 0.8, y: 0.85)
        if let last = steps[turnKey]?.items.last {
            scrollTarget = ScrollRequest(id: "bar:step:\(turnKey):\(last.n)", anchor: scrollAnchor)
        } else {
            scrollTarget = ScrollRequest(id: "bar:turn:\(turnKey)", anchor: scrollAnchor)
            reloadTick += 1     // 这一轮的步骤还没拉：马上拉，下一次再跟到最后一步
        }
    }

    /// 第一次：展开主 agent 和它最新一轮，在跑的子 agent 也展开；之后跟着最新一轮走（用户收起过就不跟）
    private func settle(_ fresh: TraceReply) {
        let first = reply == nil
        guard let main = fresh.agents.first(where: \.isMain), let latest = main.turns.last else { return }
        let latestKey = "main:\(latest.i)"
        if first {
            openAgents.insert("main")
            openTurns.insert(latestKey)
            for agent in fresh.agents where agent.running && !agent.isMain {
                openAgents.insert(agent.id)
                if let turn = agent.turns.last { openTurns.insert("\(agent.id):\(turn.i)") }
            }
            if steps[latestKey] == nil { reloadTick += 1 }
            // 一打开先看到最新：滚到主 agent 最新一轮（等时间线画出来再滚，见 load）
            initialTarget = "bar:turn:\(latestKey)"
            return
        }
        if follow, let old = reply?.agents.first(where: \.isMain)?.turns.last, old.i != latest.i {
            openTurns.remove("main:\(old.i)")
            openTurns.insert(latestKey)
            reloadTick += 1
        }
    }
}

/// 回放到某一刻时的统计（没在回放就是全量）：已经开始的 agent、轮次；模型 / 工具调用按这一轮走过的时间比例估；出错数到那一刻
struct TraceTally {
    var agents = 0
    var turns = 0
    var llm = 0
    var tools = 0
    var errors = 0

    init(reply: TraceReply, cut: Double?) {
        guard let cut else {
            agents = reply.stats.agents; turns = reply.stats.turns
            llm = reply.stats.llm; tools = reply.stats.tools; errors = reply.stats.errors
            return
        }
        for agent in reply.agents where (agent.start ?? .infinity) <= cut {
            agents += 1
            for turn in agent.turns {
                guard let start = turn.start, start <= cut else { continue }
                turns += 1
                let end = turn.end ?? cut
                let fraction = end <= cut ? 1 : max(0, min(1, (cut - start) / max(1, end - start)))
                llm += Int((Double(turn.llm) * fraction).rounded())
                tools += Int((Double(turn.tools) * fraction).rounded())
                errors += turn.errAt.filter { $0 <= cut }.count
            }
        }
    }
}

enum TraceZoom: Hashable {
    /// 整场铺满一屏宽
    case fit
    /// 一屏多少分钟
    case window(Double)
    /// 固定档位（TraceGrid.scales 的下标）
    case scale(Int)
}

// MARK: 时间线的部件

struct ScrollRequest: Equatable {
    let id: String
    let anchor: UnitPoint
    let token = UUID()
}

enum TraceGrid {
    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 26
    /// 缩放档位：每分钟多少点
    static let scales: [CGFloat] = [0.5, 1, 2, 4, 6, 15, 30, 60, 120, 240, 480, 960]
    /// 超过这么久没动静的空档折起来
    static let foldGap: Double = 10 * 60_000
    /// 折起来的空档画多宽
    static let gapWidth: CGFloat = 28

    /// 从现在的比例放大（step 1）/ 缩小（-1）一档
    static func nearest(_ perMinute: CGFloat, step: Int) -> Int {
        if step > 0 { return scales.firstIndex { $0 > perMinute * 1.05 } ?? scales.count - 1 }
        return scales.lastIndex { $0 < perMinute * 0.95 } ?? 0
    }
}

/// 时间线的一行
struct TraceGridRow: Identifiable {
    enum Kind { case agent, turn, step, loading }
    enum Tone { case agent, turn, llm, tool, error, event }
    let id: String
    let kind: Kind
    let depth: Int
    let title: String
    let sub: String?
    let icon: String?
    let start: Double?
    /// nil = 还在跑（画到现在 / 播放线）
    let end: Double?
    let status: TraceStatusDot.Status
    let open: Bool
    let agentId: String
    let turnKey: String?
    let stepKey: String?
    let tone: Tone
    /// 轮次的分段着色（同 TraceTurn.segs）、出错时刻
    let segs: [[Double]]
    let errAt: [Double]
}

/// 时间 → 横坐标：有动静的时段按比例画，中间超过 10 分钟的空档折成固定宽的一道缝
struct TimeMap {
    struct Segment { var start: Double; var end: Double; var x: CGFloat }
    var segments: [Segment] = []
    var perMs: CGFloat
    var width: CGFloat = 0
    static let lead: CGFloat = 12
    static let trail: CGFloat = 24

    init(reply: TraceReply, now: Double, perMinute: CGFloat) {
        perMs = perMinute / 60_000
        var spans: [(Double, Double)] = []
        for agent in reply.agents {
            for turn in agent.turns {
                if let start = turn.start { spans.append((start, turn.running ? now : (turn.end ?? start))) }
            }
        }
        for bucket in reply.activity where !bucket.isEmpty { spans.append((bucket[0], bucket[0] + 60_000)) }
        spans.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for span in spans {
            if let last = merged.last, span.0 - last.1 <= TraceGrid.foldGap {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        var x = Self.lead
        for (index, span) in merged.enumerated() {
            if index > 0 { x += TraceGrid.gapWidth }
            segments.append(Segment(start: span.0, end: span.1, x: x))
            x += CGFloat(span.1 - span.0) * perMs
        }
        width = max(x + Self.trail, 120)
    }

    var startX: CGFloat { segments.first?.x ?? Self.lead }
    var endX: CGFloat { width - Self.trail }

    func x(_ t: Double) -> CGFloat {
        guard let first = segments.first else { return Self.lead }
        if t <= first.start { return first.x }
        var low = 0, high = segments.count - 1
        while low < high {    // 最后一个开始时间 ≤ t 的时段
            let mid = (low + high + 1) / 2
            if segments[mid].start <= t { low = mid } else { high = mid - 1 }
        }
        let seg = segments[low]
        let segEnd = seg.x + CGFloat(seg.end - seg.start) * perMs
        if t <= seg.end { return seg.x + CGFloat(t - seg.start) * perMs }
        // 落在折起来的空档里：按比例放在那道缝里
        if low + 1 < segments.count {
            let next = segments[low + 1]
            return segEnd + TraceGrid.gapWidth * CGFloat((t - seg.end) / max(1, next.start - seg.end))
        }
        return min(endX, segEnd + CGFloat(t - seg.end) * perMs)
    }

    /// 横坐标 → 时间（回放的播放线按横坐标匀速走，折起来的空档一闪而过）
    func time(atX x: CGFloat) -> Double {
        guard let first = segments.first else { return 0 }
        if x <= first.x { return first.start }
        for (index, seg) in segments.enumerated() {
            let segEnd = seg.x + CGFloat(seg.end - seg.start) * perMs
            if x <= segEnd { return seg.start + Double((x - seg.x) / max(perMs, 0.000001)) }
            if index + 1 < segments.count, x < segments[index + 1].x {
                let next = segments[index + 1]
                return seg.end + (next.start - seg.end) * Double((x - segEnd) / TraceGrid.gapWidth)
            }
        }
        return segments.last!.end
    }

    /// 每个时段里的刻度（时间、横坐标），间隔按缩放挑，刻度之间至少 70 点
    func ticks() -> [(t: Double, x: CGFloat)] {
        let steps: [Double] = [10, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800].map { $0 * 1000 }
        let step = steps.first { CGFloat($0) * perMs >= 70 } ?? steps.last!
        var out: [(t: Double, x: CGFloat)] = []
        var lastX = -CGFloat.infinity
        for seg in segments {
            var t = (seg.start / step).rounded(.up) * step
            while t <= seg.end && out.count < 2000 {
                let x = x(t)
                if x - lastX >= 40 { out.append((t, x)); lastX = x }
                t += step
            }
        }
        return out
    }

    /// 折起来的空档（横坐标、空了多久）
    func gaps() -> [(x: CGFloat, ms: Double)] {
        zip(segments, segments.dropFirst()).map { a, b in
            (a.x + CGFloat(a.end - a.start) * perMs + TraceGrid.gapWidth / 2, b.start - a.end)
        }
    }

    /// 刻度间隔不到 1 分钟时标签带秒
    var tickSeconds: Bool { CGFloat(30_000) * perMs >= 70 }
}

/// 表头：时间刻度（「14:05」，刻度密到秒时带秒）、折起来的空档（「7h」灰块）、回放时的播放线
private struct AxisHeader: View {
    let map: TimeMap
    var playhead: CGFloat?

    private static let minute: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let second: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        let formatter = map.tickSeconds ? Self.second : Self.minute
        let gaps = map.gaps()
        // 刻度的字（约 34 点宽）和空档灰块挤在一起时不写字，只留刻度线
        let ticks = map.ticks().filter { tick in !gaps.contains { gap in tick.x + 38 > gap.x - TraceGrid.gapWidth / 2 && tick.x < gap.x + TraceGrid.gapWidth / 2 } }
        ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                Text(formatter.string(from: Date(timeIntervalSince1970: tick.t / 1000)))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: tick.x + 3, y: 7)
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 6).offset(x: tick.x, y: TraceGrid.headerHeight - 6)
            }
            ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                // 折起来的空档：一块淡灰底，写空了多久
                RoundedRectangle(cornerRadius: 3, style: .circular).fill(Color.primary.opacity(0.06))
                    .frame(width: TraceGrid.gapWidth - 4, height: TraceGrid.headerHeight - 8)
                    .overlay {
                        Text(TraceFormat.ms(gap.ms).split(separator: " ").first.map(String.init) ?? "")
                            .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize()
                    }
                    .offset(x: gap.x - TraceGrid.gapWidth / 2 + 2, y: 4)
            }
            if let playhead {
                Rectangle().fill(Color.primary.opacity(0.8)).frame(width: 1.5, height: TraceGrid.headerHeight).offset(x: playhead)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 时间线背景：每个刻度一条淡竖线，折起来的空档一道虚线，派出子 agent 的时刻一道细金线
private struct GridLines: View {
    let map: TimeMap
    let height: CGFloat
    var spawns: [CGFloat] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(map.ticks().enumerated()), id: \.offset) { _, tick in
                Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 1, height: height).offset(x: tick.x)
            }
            ForEach(Array(map.gaps().enumerated()), id: \.offset) { _, gap in
                DashedLine().stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 1, height: height).offset(x: gap.x)
            }
            ForEach(Array(spawns.enumerated()), id: \.offset) { _, x in
                Rectangle().fill(TraceColor.spawn).frame(width: 1, height: height).offset(x: x)
            }
        }
        .frame(width: map.width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// 一条时间条：轮次是淡底条上按模型（主题色）/ 工具（灰）/ 出错（红）分段；agent 是淡主题色底条；步骤按种类整条着色。
/// 出错的时刻画红色菱形；在跑的末端呼吸
private struct TimeBar: View {
    let tone: TraceGridRow.Tone
    let running: Bool
    let selected: Bool
    let height: CGFloat
    var segs: [[Double]] = []
    var errAt: [Double] = []
    /// 这条从哪个时刻开始、画到哪个时刻（回放时截到播放线）
    var origin: Double = 0
    var limit: Double = 0
    var map: TimeMap?
    /// 这条左端的横坐标（分段、菱形的位置相对它算）
    var x0: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .circular)
            .fill(color)
            .frame(height: height)
            .overlay(alignment: .leading) {
                // 太长的条（放得很大）不画分段，省得画一张特别宽的图
                if let map, !segs.isEmpty || !errAt.isEmpty {
                    Canvas { context, size in
                        guard size.width <= 6000 else { return }
                        for seg in segs where seg.count >= 3 {
                            let s = origin + seg[0]
                            guard s <= limit else { continue }
                            let e = min(limit, s + seg[1])
                            let a = map.x(s) - x0
                            let w = max(1, map.x(e) - x0 - a)
                            let color: Color = seg[2] == 0 ? TraceColor.llm : (seg[2] == 2 ? TraceColor.red : TraceColor.tool)
                            context.fill(Path(CGRect(x: a, y: 2, width: w, height: size.height - 4)), with: .color(color))
                        }
                        for t in errAt where t <= limit {
                            let cx = map.x(t) - x0
                            var diamond = Path()
                            let r: CGFloat = 4
                            let cy = size.height / 2
                            diamond.move(to: CGPoint(x: cx, y: cy - r))
                            diamond.addLine(to: CGPoint(x: cx + r, y: cy))
                            diamond.addLine(to: CGPoint(x: cx, y: cy + r))
                            diamond.addLine(to: CGPoint(x: cx - r, y: cy))
                            diamond.closeSubpath()
                            context.fill(diamond, with: .color(TraceColor.red))
                            context.stroke(diamond, with: .color(TraceColor.panel), lineWidth: 1)
                        }
                    }
                    .frame(height: height + 4)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                if running { LiveDot().padding(.trailing, -3) }
            }
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 3, style: .circular).strokeBorder(Theme.claude, lineWidth: 1.5) }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private var color: Color {
        switch tone {
        case .agent: return Color.primary.opacity(0.38)
        case .turn: return Color.primary.opacity(0.1)
        case .llm: return TraceColor.llm
        case .tool: return TraceColor.tool
        case .error: return TraceColor.red
        case .event: return Color.secondary.opacity(0.35)
        }
    }
}

/// 状态点：在跑呼吸、出错红点、做完空心圈
struct TraceStatusDot: View {
    enum Status { case running, failed, done, none }
    let status: Status

    var body: some View {
        switch status {
        case .running: LiveDot()
        case .failed: Circle().fill(TraceColor.red).frame(width: 7, height: 7)
        case .done: Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.2).frame(width: 8, height: 8)
        case .none: Color.clear.frame(width: 7, height: 7)
        }
    }
}

// MARK: 小部件

private enum TraceColor {
    /// 出错：系统红（同 Mac 的 MacPalette.red）
    static let red = Color(hex: 0xFF3B30)
    /// 工具调用：绿（同 Raven 演示视频的配色）
    static let tool = Color(hex: 0x30A46C)
    /// 模型调用：紫（同 Raven 演示视频的配色）
    static let llm = Color(hex: 0x6E56CF)
    /// 流程图底色：和对话区错开一档（浅色白底配对话区浅灰；深色略亮的深灰）
    static let panel = Theme.dynamic(light: 0xFFFFFF, dark: 0x222226)
    /// 面板里浮起来的一层（底部详情、统计卡片）
    static let raised = Theme.dynamic(light: 0xF2F2F5, dark: 0x2E2E34)
    /// 派出子 agent 的竖线：淡金色
    static let spawn = Color(hex: 0xC9A227).opacity(0.55)
}

/// 树的一项（主 agent 在最前，子 agent 跟在派它的后面）
private struct TraceEntry: Identifiable {
    let agent: TraceAgent
    let depth: Int
    var id: String { agent.id }
}

/// 正在进行：主题色小圆点，慢慢呼吸。
/// 用图层自己播放的 PulseDot（KiteMark.swift），不用 SwiftUI 的循环动画：SwiftUI 的 repeatForever 每一帧都要把整个窗口的视图重新算一遍。
/// 这个点还挂在对话页右上角的「执行过程」按钮上（会话在工作、面板没开时），所以只要有会话在工作就一直在跑——
/// 11-13 用 Instruments 量到 Mac 版 4 秒里 11 万次视图更新、主线程八成时间在重排，CPU 常驻 35～45%（改之前的写法见 git 历史）。
/// 位置不参与动画，也就没有原来「刚出现时在两处之间来回跑」的问题
private struct LiveDot: View {
    var body: some View {
        PulseDot(color: Theme.claude, size: 7, low: 0.3, period: 0.9)
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let sub: String?
    var alert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.ui(.caption2).weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value.isEmpty ? "—" : value).font(.ui(.title3).weight(.semibold).monospacedDigit())
                .foregroundStyle(alert ? TraceColor.red : Color.primary).lineLimit(1).minimumScaleFactor(0.7)
            if let sub {
                Text(sub).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TraceColor.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 8, height: 8)
            Text(text).font(.ui(.caption2)).foregroundStyle(.secondary)
        }
    }
}

/// 按分钟的活动条：每格堆叠「模型调用 / 工具调用 / 出错」；超过 10 分钟没动静的空档折成一道细缝，标上空了多久
private struct ActivityStrip: View {
    let buckets: [[Double]]

    private enum Cell { case bar(Double, Double, Double), gap(Double) }

    private var cells: [Cell] {
        var out: [Cell] = []
        var last: Double?
        for bucket in buckets where bucket.count >= 4 {
            if let last, bucket[0] - last > 10 * 60_000 { out.append(.gap(bucket[0] - last)) }
            out.append(.bar(bucket[1], bucket[2], bucket[3]))
            last = bucket[0]
        }
        return out
    }

    var body: some View {
        Canvas { context, size in
            var cells = self.cells
            let gaps = cells.filter { if case .gap = $0 { return true } else { return false } }.count
            let gapWidth: CGFloat = 14
            var bars = cells.count - gaps
            // 格子太多就几分钟并成一格（每格至少 2 点宽）
            let room = max(1, size.width - CGFloat(gaps) * gapWidth)
            let group = max(1, Int(ceil(Double(bars) * 2.5 / Double(room))))
            if group > 1 {
                var merged: [Cell] = []
                var acc = (0.0, 0.0, 0.0), count = 0
                func flush() { if count > 0 { merged.append(.bar(acc.0, acc.1, acc.2)); acc = (0, 0, 0); count = 0 } }
                for cell in cells {
                    switch cell {
                    case .gap: flush(); merged.append(cell)
                    case let .bar(l, t, e):
                        acc = (acc.0 + l, acc.1 + t, acc.2 + e); count += 1
                        if count == group { flush() }
                    }
                }
                flush()
                cells = merged
                bars = cells.count - gaps
            }
            let peak = cells.reduce(1.0) { result, cell in
                if case let .bar(l, t, e) = cell { return max(result, l + t + e) } else { return result }
            }
            let barWidth = room / CGFloat(max(1, bars))
            var x: CGFloat = 0
            for cell in cells {
                switch cell {
                case let .gap(ms):
                    var line = Path()
                    line.move(to: CGPoint(x: x + gapWidth / 2, y: 2))
                    line.addLine(to: CGPoint(x: x + gapWidth / 2, y: size.height - 2))
                    context.stroke(line, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    if gapWidth >= 12 && ms >= 3_600_000 {
                        let text = Text(TraceFormat.ms(ms).split(separator: " ").first.map(String.init) ?? "")
                            .font(.system(size: 8)).foregroundColor(.secondary)
                        context.draw(text, at: CGPoint(x: x + gapWidth / 2, y: 5))
                    }
                    x += gapWidth
                case let .bar(l, t, e):
                    let w = max(1, barWidth - (barWidth > 3 ? 1 : 0))
                    var y = size.height
                    for (value, color) in [(l, TraceColor.llm), (t, TraceColor.tool), (e, TraceColor.red)] where value > 0 {
                        let h = max(1.5, CGFloat(value / peak) * (size.height - 2))
                        y -= h
                        context.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(color))
                    }
                    x += barWidth
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 点开一步：模型调用看思考和输出、token；工具调用看命令和结果；派了子 agent 的可以跳过去
private struct StepDetail: View {
    let step: TraceStep
    var openAgent: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch step.k {
            case "llm":
                if let think = step.think, !think.isEmpty { block(L("思考"), think) }
                if let text = step.text, !text.isEmpty { block(L("输出"), text) }
                if step.input > 0 || step.output > 0 {
                    Text(L("上下文 %@ · 输出 %@ tokens", Format.tokens(step.input), Format.tokens(step.output)))
                        .font(.ui(.caption2)).foregroundStyle(.secondary)
                }
                if (step.think ?? "").isEmpty && (step.text ?? "").isEmpty && step.input == 0 {
                    Text("这次调用只发起了工具调用").font(.ui(.caption)).foregroundStyle(.secondary)
                }
            case "tool":
                block(L("调用"), step.detail ?? step.brief ?? step.name ?? "", mono: step.detail != nil)
                if step.end == nil {
                    Text("尚未返回结果").font(.ui(.caption)).foregroundStyle(.secondary)
                } else {
                    block(step.error ? L("出错") : L("结果"), step.result?.isEmpty == false ? step.result! : L("（无输出）"), mono: true, alert: step.error)
                }
                if let agent = step.agent {
                    Button { openAgent(agent) } label: {
                        Label("查看这个子 agent", systemImage: "arrow.turn.down.right").font(.ui(.caption).weight(.medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.claude)
                }
            default:
                Text(step.text ?? "").font(.ui(.caption)).foregroundStyle(step.failed ? TraceColor.red : Color.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func block(_ title: String, _ text: String, mono: Bool = false, alert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.ui(.caption2).weight(.semibold)).foregroundStyle(alert ? TraceColor.red : Color.secondary)
            Text(text)
                .font(mono ? .system(size: 11, design: .monospaced) : .ui(.caption))
                .foregroundStyle(alert ? TraceColor.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: 挂到对话页上

/// 对话页挂执行过程：上下布局（11-04 起，不左右分列）——上面是执行过程的流程图（默认占 1/3 高），下面是对话。
/// 矮的横屏（iPhone 横放，高不到 500 点）上下排放不下，改左右：左边流程图、右边对话。
/// 中间一道分隔条可以拖，调两块的比例（上下、左右各记一份，记在本机，下次打开照旧）
struct TraceSplit: ViewModifier {
    let key: String
    @Binding var isOn: Bool
    /// 流程图占整页高度的比例（上下排）
    @AppStorage("traceSplitRatio") private var ratio: Double = 1.0 / 3
    /// 流程图占整页宽度的比例（左右排）
    @AppStorage("traceSplitWidth") private var widthRatio: Double = 0.5
    @State private var size: CGSize = .zero
    @State private var dragFrom: Double?

    private static let minRatio = 0.2
    private static let maxRatio = 0.75

    /// 矮的横屏：左右排
    private var sideBySide: Bool {
        #if os(iOS)
        return size.width > size.height && size.height > 0 && size.height < 500
        #else
        return false
        #endif
    }

    func body(content: Content) -> some View {
        let side = sideBySide
        let layout = side ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            if isOn {
                TracePanel(key: key) { withAnimation(.snappy) { isOn = false } }
                    .frame(width: side ? max(260, (size.width * widthRatio).rounded()) : nil,
                           height: side ? nil : (size.height > 0 ? max(180, (size.height * ratio).rounded()) : 260))
                    .clipped()
                    .transition(.move(edge: side ? .leading : .top).combined(with: .opacity))
                handle(side: side)
            }
            // 流程图开着时对话区裁在自己那块里：滚动的消息不盖到分隔条、流程图上
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(ClipWhen(on: isOn))
        }
        // 量的是外面给这一页的大小（先撑满再量），不量自己算出来的尺寸，免得量和排互相牵动
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }

    /// 分隔条：拖动调比例；中间一根短线示意能拖（上下排是横的，左右排是竖的）
    private func handle(side: Bool) -> some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: side ? 1 : nil, height: side ? nil : 1)
            Capsule(style: .circular).fill(Color.secondary.opacity(0.45)).frame(width: side ? 4 : 36, height: side ? 36 : 4)
        }
        .frame(width: side ? 12 : nil, height: side ? nil : 12)
        .frame(maxWidth: side ? nil : .infinity, maxHeight: side ? .infinity : nil)
        .background(Theme.chatBackground)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if side {
                        guard size.width > 0 else { return }
                        let start = dragFrom ?? widthRatio
                        dragFrom = start
                        widthRatio = min(Self.maxRatio, max(0.3, start + Double(value.translation.width / size.width)))
                    } else {
                        guard size.height > 0 else { return }
                        let start = dragFrom ?? ratio
                        dragFrom = start
                        ratio = min(Self.maxRatio, max(Self.minRatio, start + Double(value.translation.height / size.height)))
                    }
                }
                .onEnded { _ in dragFrom = nil }
        )
        #if os(macOS)
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        #endif
        .accessibilityLabel(side ? L("拖动调整流程图和对话的宽度") : L("拖动调整流程图和对话的高度"))
    }
}

/// 只在流程图开着时裁切（平时对话照常滚到导航栏底下，保留系统的滚动边缘效果）
private struct ClipWhen: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.clipShape(Rectangle()) } else { content }
    }
}

/// 执行过程只在电脑（Mac）和 iPad 上有：iPhone 上卡顿、屏幕小也不实用，11-04 起手机上去掉
enum TraceFeature {
    static var enabled: Bool {
        #if KITELINE_MAC
        return true
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom != .phone
        #else
        return false
        #endif
    }
}

extension Binding where Value == Bool {
    /// 两个条件都成立才算开（关的时候只改前一个）
    static func && (lhs: Binding<Bool>, rhs: Bool) -> Binding<Bool> {
        Binding(get: { lhs.wrappedValue && rhs }, set: { lhs.wrappedValue = $0 })
    }
}

/// 对话区右上角的悬浮按钮：打开 / 收起执行过程
struct TraceButton: View {
    @Binding var isOn: Bool
    var running: Bool

    var body: some View {
        Button { withAnimation(.snappy) { isOn.toggle() } } label: {
            Image(systemName: "align.horizontal.left")
                .font(.app(size: 15, weight: .medium))
                .foregroundStyle(isOn ? Theme.claude : Color.primary)
                .frame(width: 38, height: 38)
                .background { glass }
                .overlay(alignment: .topTrailing) {
                    if running && !isOn { LiveDot().offset(x: -3, y: 3) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? L("收起执行过程") : L("查看执行过程"))
        .padding(.top, 8).padding(.trailing, 10)
    }

    /// 系统 26 起是液态玻璃（打开时带一点主题色）；更早的系统是磨砂 + 细边。Mac 和手机共用（Mac 不编 Glass.swift）
    @ViewBuilder private var glass: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Circle().fill(.clear).glassEffect(isOn ? .regular.tint(Theme.claude.opacity(0.18)).interactive() : .regular.interactive(), in: Circle())
        } else {
            Circle().fill(.regularMaterial)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
        }
    }
}
