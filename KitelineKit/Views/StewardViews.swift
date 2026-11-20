import SwiftUI

// 总管模式（实验性，11-20 用户提）：手机不选设备、不选项目，直接对「总管」说需求，总管去找设备、项目、会话派活、盯进度、验收、汇报。
//   设置 →「实验性功能 · 总管模式」：打开开关先弹配置（总管放哪台电脑、用哪个 Agent、现有会话保留还是关闭、要不要朗读回复），确认后开启。
//   开启后 iPhone「会话」页签换成 StewardHome：一个由很多小点组成、会转的球（StewardOrb），轻点开始对话——
//   检测到声音就开始听、停顿一会儿自动发给总管，总管思考时球加速转，回复到了自动朗读，读完接着听。
//   电脑端：Sources/Steward.swift、desktop/kiteline/steward.py；agent 那边：watcher 的 steward 子命令

// MARK: - 点阵球

/// 球的状态：idle 平静地转；listening 跟着麦克风音量起伏；thinking 转得快、赤道一圈亮点跑动；speaking 总管朗读时起伏；off 暗一些（照样转）
enum StewardOrbMode: Equatable {
    case idle, listening, thinking, speaking, off
}

/// 音量平滑、拖动的惯性、轻点的涟漪：每帧都要改，放在不登记观察的对象里（改了不触发重画，重画靠 TimelineView）
private final class OrbMotion {
    var level = 0.0
    var target = 0.0
    var lastFrame = 0.0
    /// 手指拖出来的转角（叠在自转上）和松手后的转速
    var yaw = 0.0, tilt = 0.0
    var spinVelocity = 0.0
    var dragging = false
    var lastDrag: CGSize = .zero
    /// 最近一次轻点的时刻（涟漪从球面正中荡开）
    var tapAt = -10.0
}

/// 很多小点组成的球（斐波那契球面均匀撒点）、外面一圈点组成的圆环，一直在转。
/// 有人说话（你说、总管读）时每个点沿着几道交错的波起伏，音量越大起伏越大；轻点荡开一圈涟漪；手指拖动可以转它。只用主题色
struct StewardOrb: View {
    var mode: StewardOrbMode
    /// 麦克风音量 0…1（listening 时用）
    var level: Double = 0
    var onTap: () -> Void = {}

    private static let cloud: [SIMD3<Double>] = {
        let n = 620
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<n).map { i in
            let y = 1 - (Double(i) + 0.5) / Double(n) * 2
            let r = (1 - y * y).squareRoot()
            let theta = golden * Double(i)
            return SIMD3(cos(theta) * r, y, sin(theta) * r)
        }
    }()

    @State private var motion = OrbMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                draw(&gc, size: size, t: t)
            }
        }
        .onChange(of: level, initial: true) { _, value in motion.target = value }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    let dx = value.translation.width - motion.lastDrag.width
                    let dy = value.translation.height - motion.lastDrag.height
                    motion.lastDrag = value.translation
                    motion.dragging = true
                    motion.yaw += dx * 0.012
                    motion.tilt = max(-1.1, min(1.1, motion.tilt + dy * 0.008))
                    motion.spinVelocity = dx * 0.6
                }
                .onEnded { _ in
                    motion.dragging = false
                    motion.lastDrag = .zero
                }
        )
        .simultaneousGesture(TapGesture().onEnded {
            motion.tapAt = Date().timeIntervalSinceReferenceDate
            onTap()
        })
        .accessibilityHidden(true)
    }

    private func draw(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        let m = motion
        let dt = m.lastFrame > 0 ? min(0.05, max(0, t - m.lastFrame)) : 1 / 60
        m.lastFrame = t
        // 音量：起得快、落得慢（像真的声音那样有余韵）
        let goal = mode == .listening ? m.target : 0
        m.level += (goal - m.level) * (goal > m.level ? 0.45 : 0.08)
        // 松手后的惯性慢慢停
        if !m.dragging {
            m.yaw += m.spinVelocity * dt
            m.spinVelocity *= pow(0.12, dt)
            m.tilt *= pow(0.6, dt)
        }

        let accent = Theme.claude
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let breathe = 0.5 + 0.5 * sin(t * 1.1)
        var radius = side * 0.30
        let spin: Double
        // 起伏的幅度：平时很轻地流动；你说话时跟着音量；总管朗读时像说话那样一阵一阵
        var wave: Double
        switch mode {
        case .idle: spin = 0.28; wave = 0.018; radius *= 1 + 0.012 * breathe
        case .listening: spin = 0.34; wave = 0.025 + 0.26 * m.level; radius *= 1 + 0.06 * m.level
        case .thinking: spin = 0.95; wave = 0.025; radius *= 1 + 0.02 * breathe
        case .speaking:
            spin = 0.42
            let syllables = max(0, sin(t * 9.0)) * (0.55 + 0.45 * sin(t * 2.7)) + 0.25 * max(0, sin(t * 13.0 + 1))
            wave = 0.05 + 0.13 * syllables
            radius *= 1 + 0.03 * syllables
        case .off: spin = 0.16; wave = 0.01; radius *= 0.94
        }
        // 轻点：一圈涟漪从正中往外荡，一秒左右散去
        let sinceTap = t - m.tapAt
        let ripple = sinceTap < 1.4 ? (1 - sinceTap / 1.4) : 0

        let yaw = t * spin + m.yaw, tilt = -0.38 + m.tilt
        let (sy, cy) = (sin(yaw), cos(yaw))
        let (st, ct) = (sin(tilt), cos(tilt))
        let dim = mode == .off ? 0.4 : 1.0
        for p in Self.cloud {
            // 起伏按点在球面上的位置算（跟着球一起转）：几道不同方向、不同快慢的波叠在一起，看起来像水面而不是整体缩放
            let w1 = sin(p.y * 6.0 + t * 5.2)
            let w2 = sin((p.x * 0.8 + p.z * 0.6) * 7.0 - t * 4.1)
            let w3 = sin(atan2(p.z, p.x) * 4.0 + p.y * 3.0 + t * 3.3)
            var r = radius * (1 + wave * (0.45 * w1 + 0.35 * w2 + 0.3 * w3))
            // 绕竖轴转，再往前倾一点（看得到上半球）
            let x1 = p.x * cy + p.z * sy, z1 = -p.x * sy + p.z * cy
            let y2 = p.y * ct - z1 * st, z2 = p.y * st + z1 * ct
            if ripple > 0 {
                // 涟漪：以朝着你的那一点为中心，按到它的球面距离往外推一圈
                let distance = acos(max(-1, min(1, z2)))
                let front = sinceTap * 2.6
                r *= 1 + 0.10 * ripple * exp(-pow((distance - front) * 3.2, 2))
            }
            let depth = (z2 + 1) / 2   // 0 远 … 1 近
            var alpha = (0.16 + 0.84 * depth) * dim
            var dot = 0.9 + 1.9 * depth
            if mode == .thinking {
                // 赤道附近一圈亮点绕着跑
                let lon = atan2(z1, p.x)
                let glow = max(0, cos(lon - t * 3.2)) * max(0, 1 - abs(p.y) * 3)
                alpha = min(1, alpha + glow * 0.8)
                dot += glow * 1.2
            }
            if wave > 0.05 {
                // 起伏大时，鼓出来的点亮一点、大一点
                let lift = max(0, 0.45 * w1 + 0.35 * w2 + 0.3 * w3) * min(1, wave * 4)
                alpha = min(1, alpha + lift * 0.25)
                dot += lift * 0.6
            }
            let point = CGPoint(x: center.x + x1 * r, y: center.y - y2 * r)
            gc.fill(Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                    with: .color(accent.opacity(alpha)))
        }
        // 外圈：一圈点组成的圆环，听的时候跟着音量往外扩、一圈一圈地抖，说话时跟着起伏
        let ringCount = 120
        let ring = radius * 1.32 * (1 + 0.01 * breathe + 0.08 * m.level)
        for i in 0..<ringCount {
            let a = Double(i) / Double(ringCount) * 2 * .pi + t * (mode == .thinking ? -0.6 : -0.14)
            let shake = wave * 0.5 * sin(a * 6 + t * 7) + 0.25 * wave * sin(a * 11 - t * 5)
            let rr = ring * (1 + shake + 0.06 * ripple * exp(-pow((sinceTap * 1.2 - 0.3) * 4, 2)))
            var alpha = (0.16 + 0.22 * (0.5 + 0.5 * sin(a * 3 + t))) * dim
            alpha += min(0.5, wave * 1.6)
            let p = CGPoint(x: center.x + cos(a) * rr, y: center.y + sin(a) * rr)
            gc.fill(Path(ellipseIn: CGRect(x: p.x - 1.1, y: p.y - 1.1, width: 2.2, height: 2.2)), with: .color(accent.opacity(min(1, alpha))))
        }
    }
}

// MARK: - 开启前的配置

/// 打开总管模式前弹出的配置：总管放哪台电脑、用哪个 Agent、现有会话怎么办、要不要朗读回复。点「开启」才真的开
struct StewardSetupSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    var done: () -> Void = {}
    @State private var sourceId = ""
    @State private var agent = "claude-code"
    @State private var agents: [(id: String, name: String)] = []
    @State private var existing = "keep"
    @State private var speak = true
    @State private var working = false
    @State private var failure: String?

    private var machines: [SourceInfo] { model.sources.filter { $0.online && $0.kind != "kiteline" } }

    var body: some View {
        FitSheet(title: L("开启总管模式"), cancel: true) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("实验性功能").font(.ui(.caption).weight(.semibold)).foregroundStyle(Theme.claude)
                    Text("开启后，不用再自己挑设备、项目和会话：直接对总管说需求，总管会找到对应的电脑和项目，派给已有的会话或新开一个，盯着进度，做完验收后向你汇报。")
                        .font(.ui(.subheadline))
                    Text("首页的会话列表将换成总管的对话界面；需要你确认的操作照常提醒。总管本身是一个会话，会占用所选 Agent 的额度。")
                        .font(.ui(.footnote)).foregroundStyle(.secondary)
                }
                group(L("总管运行在")) {
                    if machines.isEmpty {
                        Text("没有在线的电脑").font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                    ForEach(machines, id: \.id) { source in
                        option(source.name, sub: source.kind == "ssh" ? L("远端电脑") : L("这台电脑"), on: sourceId == source.id) { sourceId = source.id }
                    }
                }
                group(L("总管使用的 Agent")) {
                    option("Claude Code", sub: nil, on: agent == "claude-code") { agent = "claude-code" }
                    ForEach(agents, id: \.id) { item in
                        option(item.name, sub: nil, on: agent == item.id) { agent = item.id }
                    }
                }
                group(L("现有的会话")) {
                    option(L("保留"), sub: L("总管可以把任务派给这些会话"), on: existing == "keep") { existing = "keep" }
                    option(L("全部关闭"), sub: L("从零开始由总管安排；关闭的会话可在历史会话中恢复"), on: existing == "close") { existing = "close" }
                }
                Toggle(isOn: $speak) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("朗读总管的回复")
                        Text("在总管界面对话时，回复到了自动读出来").font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                }
                .tint(Theme.claude)
                if let failure {
                    Text(failure).font(.ui(.footnote)).foregroundStyle(.red)
                }
            }
        } bottom: {
            Button {
                Task { await enable() }
            } label: {
                HStack(spacing: 8) {
                    if working { ProgressView().tint(.white) }
                    Text(working ? L("正在开启…") : L("开启总管模式"))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.claude)
            .disabled(working || sourceId.isEmpty)
        }
        .task {
            await model.steward.refresh(model.api)
            let saved = model.steward
            sourceId = machines.contains(where: { $0.id == saved.sourceId }) ? saved.sourceId : (machines.first { $0.kind == "local" } ?? machines.first)?.id ?? ""
            agent = saved.agent
            existing = saved.existing
            speak = saved.speak
        }
        .task(id: sourceId) {
            guard !sourceId.isEmpty else { return }
            let reply = try? await model.api.get("/api/launchable", ["sourceId": sourceId])
            agents = ((reply?["agents"] as? [[String: Any]]) ?? []).compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty, id != "claude-code", row["via"] as? String != "ui" else { return nil }
                return (id, row["name"] as? String ?? id)
            }
            if agent != "claude-code", !agents.contains(where: { $0.id == agent }) { agent = "claude-code" }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(.footnote).weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 6) { content() }
        }
    }

    /// 单选的一行：选中的淡主题色底 + 细边（同别处的选中态）
    private func option(_ title: String, sub: String?, on: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Theme.claude : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.ui(.subheadline)).foregroundStyle(.primary)
                    if let sub { Text(verbatim: sub).font(.ui(.caption)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(on ? Theme.claude.opacity(0.10) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { if on { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.claude.opacity(0.35), lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func enable() async {
        working = true
        failure = nil
        defer { working = false }
        do {
            let message = try await model.steward.enable(model.api, sourceId: sourceId, agent: agent, existing: existing, speak: speak)
            if !message.isEmpty { model.flash(message) }
            done()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - 设置里的入口

/// 设置里「实验性功能」一组：总管模式的开关。打开先弹配置，关掉直接关（总管会话保留）
struct StewardSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var showSetup = false
    @State private var confirmOff = false

    var body: some View {
        let steward = model.steward
        Section {
            Toggle(isOn: Binding(get: { steward.enabled }, set: { on in
                if on { showSetup = true } else { confirmOff = true }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("总管模式")
                    Text(steward.enabled ? L("总管运行在 %@", steward.sourceName.isEmpty ? steward.sourceId : steward.sourceName)
                                         : L("直接说需求，由总管安排设备、项目和会话"))
                        .font(.ui(.footnote)).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.claude)
            if steward.enabled {
                Button(L("修改总管设置")) { showSetup = true }
            }
        } header: {
            Text("实验性功能").font(.sectionHeader)
        } footer: {
            Text("实验性功能可能随版本调整。开启后首页的会话列表换成总管的对话界面，可随时在这里关闭。")
                .font(.ui(.footnote))
        }
        .task { await steward.refresh(model.api) }
        .sheetPanel(isPresented: $showSetup) { StewardSetupSheet().environment(model) }
        .confirmationDialog(L("关闭总管模式？"), isPresented: $confirmOff, titleVisibility: .visible) {
            Button(L("关闭总管模式"), role: .destructive) {
                Task {
                    do { try await steward.disable(model.api) } catch { model.show(error) }
                }
            }
        } message: {
            Text("首页恢复为会话列表；总管会话保留，可在会话列表中找到。")
        }
    }
}

#if os(iOS)
import AVFAudio

// MARK: - 对话：检测到声音就听、停顿后自动发、回复到了自动读

@MainActor
@Observable
final class StewardTalk {
    enum Phase: Equatable { case off, waiting, hearing, sending, thinking, speaking }

    private(set) var phase: Phase = .off
    private(set) var level = 0.0
    let recorder = VoiceRecorder()
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 最近一次已读过的总管回复：读过的不再读
    @ObservationIgnored var lastSpoken: String?

    var active: Bool { phase != .off }

    /// 开始对话：循环「等声音 → 听 → 停顿后发 → 等回复 → 读 → 再听」，直到 stop
    func start(_ model: AppModel, key: String) {
        guard loop == nil else { return }
        phase = .waiting
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.round(model, key: key)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        _ = recorder.stop(cancel: true)
        level = 0
        phase = .off
    }

    /// 一轮：录音时盯着音量，0.9 秒没声音（且说了 0.6 秒以上）就收；8 秒都没开口重新开始录（不让文件越录越长）
    private func round(_ model: AppModel, key: String) async {
        // 总管在说话（朗读）时不听：读完再听，免得把读出来的声音录进去
        while Speaker.shared.speakingKey == key, !Task.isCancelled {
            phase = .speaking
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !Task.isCancelled else { return }
        guard await recorder.start() else {
            model.flash(L("没有麦克风权限：请在系统设置中允许 Kiteline 使用麦克风"))
            stop(); return
        }
        phase = .waiting
        var spoke = 0.0, quiet = 0.0
        let began = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
            let now = recorder.levels.last ?? 0
            level = now
            if now > 0.42 {
                spoke += 0.08; quiet = 0
                if phase != .hearing { phase = .hearing }
            } else if spoke > 0 {
                quiet += 0.08
            }
            if spoke >= 0.6, quiet >= 0.9 { break }
            if spoke == 0, Date().timeIntervalSince(began) > 8 {
                _ = recorder.stop(cancel: true)
                return
            }
            if recorder.elapsed > 55 { break }
        }
        guard !Task.isCancelled else { return }
        level = 0
        guard let clip = recorder.stop(cancel: false), clip.duration >= 0.8 else { return }
        phase = .sending
        model.sendVoice(key, audio: clip.data, duration: clip.duration, images: [])
        // 等总管回完：开始忙 → 忙完。最多等 3 分钟，等着时你可以轻点球打断（stop）
        phase = .thinking
        let sent = Date()
        var sawBusy = false
        while !Task.isCancelled, Date().timeIntervalSince(sent) < 180 {
            try? await Task.sleep(for: .milliseconds(300))
            let busy = model.session(key).map { $0.isBusy } ?? false
            if busy { sawBusy = true }
            if (sawBusy && !busy) || (!sawBusy && Date().timeIntervalSince(sent) > 25) { break }
        }
        guard !Task.isCancelled else { return }
        if model.steward.speak, let reply = StewardHome.latestReply(model, key: key), reply.id != lastSpoken {
            lastSpoken = reply.id
            phase = .speaking
            Speaker.shared.speak(reply.text, id: reply.id, key: key)
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}

// MARK: - 首页：总管

/// 开着总管模式时 iPhone「会话」页签的第一层：点阵球、现在在干什么、最近一问一答；底下打字 / 看完整对话 / 等你确认的会话
struct StewardHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var openRoute
    @State private var talk = StewardTalk()
    @State private var typing = false
    @State private var draft = ""
    @State private var waking = false
    @FocusState private var focused: Bool

    /// 总管最新的一段回复（对话里 Claude 说的最后一段文字）
    static func latestReply(_ model: AppModel, key: String) -> (id: String, text: String)? {
        let items = model.chat(key).items.values.filter { $0.t == "text" && !($0.text ?? "").isEmpty }
        guard let last = items.max(by: ChatItem.ordered) else { return nil }
        return (last.id, last.text ?? "")
    }

    /// 你最后说的一句（和它的时间）
    private func lastAsk(_ key: String) -> ChatItem? {
        model.chat(key).items.values.filter { $0.t == "user" && !($0.text ?? "").isEmpty }.max(by: ChatItem.ordered)
    }

    /// 这次的任务派出去的几件事（同一个会话派了几次只留最新一件）：从你最后一次说话前两分钟算起；
    /// 都回报完、过了半小时还没再派活的，回到大球
    private func mission(_ key: String?) -> [StewardTask] {
        let tasks = model.steward.tasks
        guard !tasks.isEmpty else { return [] }
        let now = Date().timeIntervalSince1970 * 1000
        let asked = key.flatMap { lastAsk($0)?.ts } ?? 0
        let start = asked > 0 ? asked - 120_000 : now - 2 * 3600 * 1000
        var seen = Set<String>()
        let list = tasks.filter { $0.at >= start }.reversed().filter { task in
            let id = task.key.isEmpty ? task.id : task.key
            return seen.insert(id).inserted
        }.reversed()
        let result = Array(list)
        if !result.isEmpty, result.allSatisfy({ $0.state == "reported" || $0.state == "failed" }),
           let last = result.map({ $0.reportAt ?? $0.at }).max(), now - last > 30 * 60 * 1000 { return [] }
        return result
    }

    var body: some View {
        let steward = model.steward
        let key = steward.key
        let session = key.flatMap { model.session($0) }
        let tasks = mission(key)
        let compact = !tasks.isEmpty
        GeometryReader { geo in
            let width = geo.size.width
            let orbSize: CGFloat = compact ? 64 : min(width - 48, 340)
            let orbY: CGFloat = compact ? 40 : max(orbSize / 2 + 70, geo.size.height * 0.40)
            ZStack(alignment: .top) {
                if compact {
                    StewardDispatchBoard(tasks: tasks, events: steward.events, anchor: CGPoint(x: width / 2, y: orbY + orbSize * 0.42),
                                         headline: talkText ?? boardHeadline(tasks, session: session),
                                         ask: key.flatMap { lastAsk($0)?.text }, reply: key.flatMap { Self.latestReply(model, key: $0)?.text },
                                         stewardBusy: session?.isBusy == true) { openRoute(.chat($0)) }
                        .transition(.opacity)
                } else {
                    bigInfo(key: key, session: session, orbBottom: orbY + orbSize / 2)
                        .transition(.opacity)
                }
                StewardOrb(mode: orbMode(session), level: talk.level) {
                    guard let key else { Task { await wake() }; return }
                    if talk.active { talk.stop() } else { talk.start(model, key: key) }
                }
                .frame(width: orbSize, height: orbSize)
                .position(x: width / 2, y: orbY)
                .accessibilityElement()
                .accessibilityLabel(talk.active ? L("结束对话") : L("开始对话"))
                .accessibilityAddTraits(.isButton)
            }
            .coordinateSpace(.named(StewardDispatchBoard.space))
            .animation(.spring(response: 0.8, dampingFraction: 0.84), value: compact)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(key) }
        .background(Theme.pageBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: key) {
            await model.steward.refresh(model.api)
            guard let key = model.steward.key else { return }
            // 对话要读进来：最新的回复、你最后说的话都从这里取；读过的旧回复不朗读
            await model.loadHistory(key, older: false)
            talk.lastSpoken = Self.latestReply(model, key: key)?.id
        }
        .onDisappear { talk.stop() }
    }

    /// 大球时球下面：现在在干什么、你最后说的、总管最新的回复；顶上有会话等你确认时一条提示
    private func bigInfo(key: String?, session: SessionInfo?, orbBottom: CGFloat) -> some View {
        let waiting = model.sessions.filter { $0.isWaiting && $0.key != key }
        return ZStack(alignment: .top) {
            if !waiting.isEmpty {
                Button { openRoute(.chat(waiting[0].key)) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(waiting.count == 1 ? L("「%@」等你确认", waiting[0].title) : L("%lld 个会话等你确认", count: waiting.count))
                            .font(.ui(.subheadline)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.ui(.caption)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.top, 8)
            }
            VStack(spacing: 10) {
                Text(talkText ?? idleText(session))
                    .font(.ui(.subheadline).weight(.medium)).foregroundStyle(.secondary)
                if let key {
                    if let ask = lastAsk(key)?.text {
                        Text(verbatim: ask).font(.ui(.footnote)).foregroundStyle(.tertiary).lineLimit(2).multilineTextAlignment(.center)
                    }
                    if let reply = Self.latestReply(model, key: key) {
                        ScrollView {
                            Text(verbatim: reply.text).font(.ui(.body)).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        }
                        .frame(maxHeight: 150)
                        .scrollBounceBehavior(.basedOnSize)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, orbBottom + 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 派活时球下面那一行：在调度几个会话 / 验收中 / 都做完了
    private func boardHeadline(_ tasks: [StewardTask], session: SessionInfo?) -> String {
        let open = tasks.filter { $0.state == "sent" || $0.state == "queued" }.count
        if open > 0 { return L("正在调度 · %lld 个会话", count: tasks.count) }
        return session?.isBusy == true ? L("验收中") : L("已完成 · %lld 个会话", count: tasks.count)
    }

    private func orbMode(_ session: SessionInfo?) -> StewardOrbMode {
        guard model.steward.key != nil else { return .off }
        switch talk.phase {
        case .hearing, .waiting: return .listening
        case .sending, .thinking: return .thinking
        case .speaking: return .speaking
        case .off:
            if let key = model.steward.key, Speaker.shared.speakingKey == key { return .speaking }
            return session?.isBusy == true ? .thinking : .idle
        }
    }

    /// 对话进行中（听、识别、想、读）时的提示；没在对话返回 nil
    private var talkText: String? {
        let steward = model.steward
        if steward.starting || waking { return L("总管正在启动…") }
        guard steward.key != nil else { return L("总管未在运行，轻点唤醒") }
        switch talk.phase {
        case .waiting: return L("请说，我在听")
        case .hearing: return L("正在听…")
        case .sending: return L("正在识别…")
        case .thinking: return L("正在思考…")
        case .speaking: return L("正在回复")
        case .off: return nil
        }
    }

    private func idleText(_ session: SessionInfo?) -> String {
        if session?.isWaiting == true { return L("总管等你确认") }
        return session?.isBusy == true ? L("总管正在处理") : L("轻点开始对话")
    }

    @ViewBuilder
    private func bottomBar(_ key: String?) -> some View {
        if typing, let key {
            HStack(spacing: 10) {
                TextField(L("对总管说…"), text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    model.send(key, text: text, images: [])
                    draft = ""
                    typing = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.claude)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .onAppear { focused = true }
        } else {
            HStack(spacing: 28) {
                circleButton("keyboard", L("打字")) { talk.stop(); typing = true }
                    .disabled(key == nil)
                circleButton(talk.active ? "mic.fill" : "mic", talk.active ? L("结束对话") : L("开始对话"), on: talk.active) {
                    guard let key else { Task { await wake() }; return }
                    if talk.active { talk.stop() } else { talk.start(model, key: key) }
                }
                circleButton("text.bubble", L("完整对话")) {
                    if let key { talk.stop(); openRoute(.chat(key)) }
                }
                .disabled(key == nil)
            }
            .padding(.top, 6).padding(.bottom, 12)
        }
    }

    private func circleButton(_ symbol: String, _ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                    .foregroundStyle(on ? .white : .primary)
                    .frame(width: 54, height: 54)
                    .background(on ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Circle())
                Text(verbatim: label).font(.ui(.caption2)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func wake() async {
        waking = true
        defer { waking = false }
        do {
            let message = try await model.steward.wake(model.api)
            if !message.isEmpty { model.flash(message) }
        } catch {
            model.show(error)
        }
    }
}
#endif
