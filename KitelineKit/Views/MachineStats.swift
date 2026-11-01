import SwiftUI

/// 一台机器现在的 CPU 占用和内存：电脑上的 watcher 每 5 秒报一次，经 sys 事件推来（GET /api/state 时附一份）。
/// 跟在会话列表里机器名的右边（标题下的电脑名、分组组头里的机器名）；读不到的项电脑不给，这里就不画。
/// 电脑那边也报网速（netIn / netOut），界面上不显示
struct MachineStats: Decodable, Hashable {
    /// CPU 占用，0～1
    var cpu: Double?
    var cores: Int?
    /// 字节
    var memTotal: Double?
    var memUsed: Double?

    /// 每项单独解：哪一项格式不对只丢那一项，不连累整份 state
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpu = try? c.decodeIfPresent(Double.self, forKey: .cpu)
        cores = try? c.decodeIfPresent(Int.self, forKey: .cores)
        memTotal = try? c.decodeIfPresent(Double.self, forKey: .memTotal)
        memUsed = try? c.decodeIfPresent(Double.self, forKey: .memUsed)
    }

    private enum CodingKeys: String, CodingKey { case cpu, cores, memTotal, memUsed }

    var memRatio: Double? {
        guard let used = memUsed, let total = memTotal, total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    /// 读屏、Mac 上鼠标停留时的说明
    var summary: String {
        var parts: [String] = []
        if let cpu { parts.append("CPU \(MachineFormat.percent(cpu))" + (cores.map { L("（%@ 核）", "\($0)") } ?? "")) }
        if let used = memUsed, let total = memTotal {
            parts.append(L("内存已用 %@，共 %@，可用 %@", "\(MachineFormat.gigabytes(used))", "\(MachineFormat.gigabytes(total))", "\(MachineFormat.gigabytes(total - used))"))
        }
        return parts.joined(separator: "；")
    }
}

/// sys 事件：某台机器的新数据；stats 为空 = 这台机器断开了
struct MachineStatsEvent: Decodable {
    var id: String
    var stats: MachineStats?
}

enum MachineFormat {
    static func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }

    /// 按 1024 进位（和系统「关于本机」写的一致）：10 GB 以上取整，以下留一位
    static func gigabytes(_ bytes: Double) -> String {
        let value = max(bytes, 0) / 1_073_741_824
        return value >= 10 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }

    /// 已用 / 总共：31/36 GB（两个数用同一种精度）
    static func memory(_ used: Double, of total: Double) -> String {
        let u = max(used, 0) / 1_073_741_824, t = total / 1_073_741_824
        return t >= 10 ? String(format: "%.0f/%.0f GB", u, t) : String(format: "%.1f/%.1f GB", u, t)
    }
}

/// 占用比例的小圆环：平时跟文字同色，到 warn 转橙、到 alarm 转红（CPU 八成、九成；内存 85%、95%：
/// 电脑会把空闲内存拿去用，八成上下很常见，不该老是橙的）
struct UsageRing: View {
    let ratio: Double
    var size: CGFloat = 11
    var warn = 0.8
    var alarm = 0.9

    var body: some View {
        let width = max(size * 0.2, 1.8)
        let tint: Color? = ratio >= alarm ? Theme.removed : ratio >= warn ? .orange : nil
        ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: width)
            Circle().trim(from: 0, to: max(min(ratio, 1), 0.03))
                .stroke(style: StrokeStyle(lineWidth: width, lineCap: .round))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: ratio)
    }
}

/// CPU 圆环 + 百分比、内存圆环 + 已用/总共，排一行不换行；「CPU」「内存」字样始终带着（光有圆环看不出是什么）。
/// 数字每 5 秒变一次：按最宽的样子占位（100%、88/88 GB），宽度不跟着跳，旁边的字不会左右晃
struct MachineStatsLine: View {
    let stats: MachineStats
    var ring: CGFloat = 11

    var body: some View {
        HStack(spacing: 10) {
            if let cpu = stats.cpu {
                HStack(spacing: 4) {
                    UsageRing(ratio: cpu, size: ring)
                    Text("CPU")
                    steady(MachineFormat.percent(cpu), widest: "100%")
                }
            }
            if let ratio = stats.memRatio, let used = stats.memUsed, let total = stats.memTotal {
                HStack(spacing: 4) {
                    UsageRing(ratio: ratio, size: ring, warn: 0.85, alarm: 0.95)
                    Text("内存")
                    steady(MachineFormat.memory(used, of: total),
                           widest: MachineFormat.memory(total, of: total).replacingOccurrences(of: #"\d"#, with: "8", options: .regularExpression))
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stats.summary)
    }

    private func steady(_ text: String, widest: String) -> some View {
        Text(widest).hidden().overlay(alignment: .leading) { Text(text) }
    }
}

#if !KITELINE_MAC
/// 跟在机器名右边的 CPU、内存：自己读这台机器的数据，每 5 秒刷新只重画这一小块（不连累整个列表）。
/// 机器不在线、没数据时什么都不画；轻点打开这台机器的设备详情（IP、系统、处理器、内存、装了哪些 agent）
struct MachineStatsBadge: View {
    @Environment(AppModel.self) private var model
    let sourceId: String
    /// 设备详情还没拉回来时标题先写的机器名
    let name: String
    var font: Font = .ui(.caption)
    @State private var showDetail = false

    var body: some View {
        if let stats = model.liveStats(sourceId) {
            Button { showDetail = true } label: {
                MachineStatsLine(stats: stats).font(font)
            }
            .buttonStyle(.plain)
            .accessibilityHint("显示设备详情")
            .sheetPanel(isPresented: $showDetail) { MachineInfoSheet(sourceId: sourceId, name: name) }
        }
    }
}

/// 首页大标题下面「电脑名 · N 个会话」那一行，排一行不换行：showStats 时电脑名后面跟着这台电脑自己的 CPU、内存
/// （它的「本机」来源报的）；放不下时前面的字截短，CPU、内存不缩。点电脑名是网络诊断，点 CPU、内存弹出详细数字
struct HostStatsLine: View {
    @Environment(AppModel.self) private var model
    let name: String
    let sessions: Int
    var showStats = true
    let diagnose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: diagnose) {
                // 放不下时先缩电脑名，会话数留全（英文的「6 sessions」比中文长，挤掉的不能是数字）
                HStack(spacing: 6) {
                    Circle().fill(Theme.added).frame(width: 7, height: 7)
                    Text(name).lineLimit(1)
                    Text(verbatim: "· " + L("%lld 个会话", count: sessions)).lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(.steady(.plain))
            if showStats, let local = model.sources.first(where: { $0.kind == "local" }) {
                MachineStatsBadge(sourceId: local.id, name: model.host, font: .ui(.footnote))
            }
        }
    }
}
#endif

#if KITELINE_MAC
extension KitelineKit {
    /// Mac 主窗口侧栏组头里跟在机器名右边的 CPU、内存（没数据、机器不在线时什么都不画）；鼠标停上去看详细数字
    public struct MachineStatsRow: View {
        let sourceId: String

        public init(sourceId: String) { self.sourceId = sourceId }

        public var body: some View {
            if let stats = KitelineKit.model?.liveStats(sourceId) {
                MachineStatsLine(stats: stats, ring: 10).help(stats.summary)
            }
        }
    }
}
#endif
