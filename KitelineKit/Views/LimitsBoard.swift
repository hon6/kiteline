import SwiftUI

// MARK: 订阅额度（/api/limits）

/// 各台电脑上各家 agent 的订阅额度（5 小时 / 每周）。Claude Code 的读数是电脑端装的小插件在每次回复后记下的，
/// Codex 的来自它自己的记录；按电脑分组（顺序同电脑端设置里的来源）
struct LimitsPayload: Decodable {
    var devices: [LimitDevice]

    init(devices: [LimitDevice] = []) { self.devices = devices }
    init(from decoder: Decoder) throws {
        devices = try decoder.fields().list("devices")
    }
}

struct LimitDevice: Decodable, Identifiable, Hashable {
    var sourceId: String
    var name: String
    var local: Bool
    var agents: [LimitAgent]
    var id: String { sourceId }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        sourceId = c.text("sourceId") ?? ""
        name = c.text("name") ?? ""
        local = c.truthy("local")
        agents = c.list("agents")
    }
}

struct LimitAgent: Decodable, Identifiable, Hashable {
    var agent: String
    /// 读数是什么时候记下的（毫秒）
    var at: Double
    var plan: String?
    var windows: [LimitWindow]
    /// 还没有读数：这台电脑上开着的会话都是额度插件装上之前启动的，新开一个会话回复后才有
    var pending: Bool
    var id: String { agent }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        agent = c.text("agent") ?? Agents.defaultID
        at = c.num("at")
        plan = c.text("plan")
        windows = c.list("windows")
        pending = c.truthy("pending")
    }

    /// 卡片上的两格：第一格 5 小时、第二格每周；没有这两种窗口的（Codex 免费版 30 天一个窗口、网关的花费上限）按顺序补上
    var slots: [LimitWindow?] {
        var first = windows.first { $0.kind == "five_hour" }
        var second = windows.first { $0.kind == "seven_day" }
        var rest = windows.filter { $0.kind != "five_hour" && $0.kind != "seven_day" }.makeIterator()
        if first == nil { first = rest.next() }
        if second == nil { second = rest.next() }
        return [first, second]
    }
}

struct LimitWindow: Decodable, Identifiable, Hashable {
    var kind: String
    /// 已用百分比（0～100，网关的花费上限超了会过 100）
    var percent: Double
    var resetsAt: Double?
    var minutes: Int?
    /// 过了重置时间、还没有新读数：额度已经回来了
    var reset: Bool
    var id: String { kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        kind = c.text("kind") ?? ""
        percent = c.num("percent")
        resetsAt = c.one("resetsAt")
        minutes = c.one("minutes")
        reset = c.truthy("reset")
        // 电脑暂时连不上时给的是记住的旧读数：过了重置时间的额度已经回来了
        if let at = resetsAt, at <= Date().timeIntervalSince1970 * 1000 {
            percent = 0
            resetsAt = nil
            reset = true
        }
    }

    var label: String {
        switch kind {
        case "five_hour": return L("5 小时")
        case "seven_day": return L("本周")
        case "spend_limit": return L("额度")
        default:
            let minutes = minutes ?? Int(kind.split(separator: "_").last ?? "") ?? 0
            if minutes >= 1440 { return L("%@ 天", "\(minutes / 1440)") }
            return minutes > 0 ? L("%@ 小时", "\(max(1, minutes / 60))") : L("额度")
        }
    }

    /// 「5 小时 · 22:10 重置」
    var caption: String {
        let reset = resetText
        return reset.isEmpty ? label : "\(label) · \(reset)"
    }

    /// 「22:10 重置」「明天 03:00 重置」「11月7日 重置」；不知道什么时候重置时为空
    var resetText: String {
        if reset { return L("已重置") }
        guard let resetsAt else { return "" }
        let date = Date(timeIntervalSince1970: resetsAt / 1000)
        let calendar = Calendar.current
        let time = Format.clock(resetsAt)
        if calendar.isDateInToday(date) { return L("%@ 重置", time) }
        if calendar.isDateInTomorrow(date) { return L("%@ 重置", L("明天 %@", time)) }
        let c = calendar.dateComponents([.month, .day], from: date)
        return L("%@ 重置", L("%@月%@日", "\(c.month ?? 0)", "\(c.day ?? 0)"))
    }

    /// 平时主题色，用到八成起红色（主题色常是橙的，再分一档橙色看不出来）
    var tint: Color { percent >= 80 ? Theme.removed : Theme.claude }
}

// MARK: 视图

/// 一条额度：上面一行「5 小时 · 22:10 重置」和已用百分比，下面一根横条（10-31：不要环形，两台设备时太占地方）
struct LimitBar: View {
    let window: LimitWindow
    var compact = false

    var body: some View {
        let height: CGFloat = compact ? 5 : 6
        let ratio = min(1, max(0, window.percent / 100))
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.caption).font(.app(size: compact ? 10.5 : 11.5)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(compact ? 0.7 : 0.8)
                Spacer(minLength: 4)
                Text("\(Int(window.percent.rounded()))%")
                    .font(.app(size: compact ? 12 : 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(window.percent >= 80 ? window.tint : .primary)
            }
            GeometryReader { geo in
                Capsule(style: .circular).fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule(style: .circular).fill(window.tint)
                            .frame(width: ratio > 0 ? max(height, geo.size.width * ratio) : 0)
                    }
            }
            .frame(height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.caption) \(Int(window.percent.rounded()))%")
    }
}

/// 额度面板：每台电脑每家 agent 一块——上面一行左边电脑名、右边 agent，下面「5 小时」「本周」两条各占一半并排（10-31）。
/// 手机首页卡片、用量页、Mac 侧栏共用
struct LimitsBoard: View {
    let devices: [LimitDevice]
    /// Mac 侧栏：窄，字小一号
    var compact = false
    /// 宽页面（Mac、iPad 的用量页）：一块一栏并排放，横条不至于拉得太长；窄了自动退成一列
    var wide = false

    private var blocks: [(device: LimitDevice, agent: LimitAgent)] {
        devices.flatMap { device in device.agents.map { (device, $0) } }
    }

    var body: some View {
        if wide {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 32, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, item in block(item.device, item.agent) }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().opacity(0.6) }
                    block(item.device, item.agent)
                }
            }
        }
    }

    private func block(_ device: LimitDevice, _ agent: LimitAgent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: device.local ? "laptopcomputer" : "server.rack").font(.app(size: 11)).foregroundStyle(.secondary)
                Text(device.name).font(.app(size: compact ? 12 : 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                // 读数是多久前的（旧了说明那台电脑一阵子没回复，额度可能已经变了）
                if agent.at > 0 {
                    Text(Bytes.relative(agent.at)).font(.app(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                AgentGlyph(agent.agent, size: compact ? 13 : 14)
                Text(Agents.info(agent.agent).name + (agent.plan.map { $0.isEmpty ? "" : " · " + $0.capitalized } ?? ""))
                    .font(.app(size: compact ? 12.5 : 13.5, weight: .semibold)).lineLimit(1)
            }
            if agent.pending {
                Text("已开着的会话不记额度，新开一个会话回复后显示")
                    .font(.app(size: compact ? 10.5 : 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: compact ? 10 : 14) {
                    ForEach(Array(agent.slots.enumerated()), id: \.offset) { _, window in
                        Group {
                            if let window { LimitBar(window: window, compact: compact) } else { Color.clear.frame(height: 1) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

/// 首页的「今日用量」大卡片（10-31）：右上角今天的 token 总数，下面各台电脑的额度条，花费这些明细点进去看。
/// 还没有额度读数（没用订阅登录、旧版电脑端）时退回一行今天的花费
struct LimitsTile: View {
    let devices: [LimitDevice]
    let usage: UsageItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TarsIcon(symbol: "chart.bar.fill", size: 34)
                Text("今日用量").font(.ui(.subheadline).weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                // 今天各台电脑一共用了多少 token（输入、输出、读写缓存都算）
                if let usage, usage.tokens > 0 {
                    Text(L("%@ token", Money.compact(usage.tokens))).font(.app(size: 15, weight: .semibold).monospacedDigit()).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.app(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            if devices.isEmpty {
                Text(usage.map { L("%@ · %@ 输出 · %@ 次", Money.cost($0.cost), "\(Money.compact($0.output))", "\(Int($0.requests))") }
                     ?? L("Claude Code 回复后显示 5 小时与本周额度"))
                    .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                LimitsBoard(devices: devices)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
