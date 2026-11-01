import Charts
import SwiftUI
import KitelineKit

/// Mac 主窗口右侧的「用量」：各台机器按天 / 模型 / 项目的 token 与花费（类似 ccusage）
final class UsageReportModel: ObservableObject {
    static let shared = UsageReportModel()

    struct Row: Identifiable {
        var id: String
        var name: String
        var detail: String
        var cost: Double
        var estimated: Double
        var requests: Double
        var output: Double
        var cacheRead: Double
    }

    struct Day: Identifiable {
        var id: String { key }
        var key: String
        var date: Date
        var cost: Double
        var estimated: Double
        var requests: Double
    }

    @Published var days = 7 { didSet { load() } }
    @Published private(set) var payload: [String: Any]?
    /// 各台电脑的订阅额度（Limits.collect 的 JSON，交给 KitelineKit 画额度条）
    @Published private(set) var limits: Data?
    @Published private(set) var loading = false
    private var seq = 0

    func load(fresh: Bool = false) {
        seq += 1
        let current = seq
        loading = true
        Limits.collect(fresh: fresh) { [weak self] payload in self?.limits = try? JSONSerialization.data(withJSONObject: payload) }
        UsageReport.collect(days: days, fresh: fresh) { [weak self] payload in
            guard let self = self, current == self.seq else { return }
            self.payload = payload
            self.loading = false
        }
    }

    /// 自测渲染用
    func inject(_ payload: [String: Any]) { self.payload = payload; loading = false }

    var totals: [String: Any] { payload?["totals"] as? [String: Any] ?? [:] }

    var dayRows: [Day] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return ((payload?["days"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let key = item["day"] as? String, let date = formatter.date(from: key) else { return nil }
            return Day(key: key, date: date, cost: Digest.number(item["cost"]), estimated: Digest.number(item["estimated"]),
                       requests: Digest.number(item["requests"]))
        }
    }

    func rows(_ field: String) -> [Row] {
        ((payload?[field] as? [[String: Any]]) ?? []).enumerated().map { index, item in
            let name: String
            let detail: String
            switch field {
            case "models":
                name = item["model"] as? String ?? "unknown"
                detail = L("%@ 次请求", "\(Int(Digest.number(item["requests"])))")
            case "projects":
                name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("（未知目录）")
                detail = "\(item["sourceName"] as? String ?? "") · \(item["cwd"] as? String ?? "")"
            default:
                name = item["name"] as? String ?? ""
                detail = L("%@ 次请求", "\(Int(Digest.number(item["requests"])))")
            }
            return Row(id: "\(field)\(index)", name: name, detail: detail, cost: Digest.number(item["cost"]),
                       estimated: Digest.number(item["estimated"]), requests: Digest.number(item["requests"]),
                       output: Digest.number(item["output"]), cacheRead: Digest.number(item["cacheRead"]))
        }
    }

    static func money(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.1fk", value / 1000) }
        if value >= 100 { return String(format: "$%.0f", value) }
        return String(format: "$%.2f", value)
    }
}

struct UsageReportView: View {
    @ObservedObject var model = UsageReportModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 订阅额度（各台电脑的 5 小时 / 本周）：侧栏卡片上那几条，这里字大一号、一台电脑一栏
                let limits = TarsLimitsBoard(json: model.limits, compact: false, wide: true)
                if !limits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("订阅额度").font(.app(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        limits.tarsCard(padding: 14, cornerRadius: 16)
                    }
                }
                if model.payload != nil {
                    summary
                    if model.days > 1 { chart }
                    table(L("按模型"), model.rows("models"))
                    table(L("按项目"), Array(model.rows("projects").prefix(12)))
                    if model.rows("sources").count > 1 { table(L("按机器"), model.rows("sources")) }
                    Text("花费数据取自 Claude Code 记录的 cost-state（会话结束或恢复时写入）；进行中的会话按同一机器、同一模型的平均费率估算（图中浅色部分）。")
                        .font(.app(size: 11)).foregroundStyle(.tertiary)
                    ForEach((model.payload?["errors"] as? [String]) ?? [], id: \.self) { error in
                        Label(ServerLang.ui(error), systemImage: "exclamationmark.triangle").font(.app(size: 11.5)).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("正在统计各机器的用量…").frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .navigationTitle("用量")
        .navigationSubtitle(model.days == 1 ? "今天" : "最近 \(model.days) 天")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("范围", selection: $model.days) {
                    Text("今天").tag(1)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.load(fresh: true) } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.loading)
            }
        }
        .liveReload(every: 120) { model.load() }
    }

    private var summary: some View {
        let t = model.totals
        let cost = Digest.number(t["cost"]), estimated = Digest.number(t["estimated"])
        let input = Digest.number(t["input"]) + Digest.number(t["cacheRead"]) + Digest.number(t["cacheWrite"])
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            tile("dollarsign.circle", UsageReportModel.money(cost), L("花费"), estimated > 0 ? L("含估算 %@", "\(UsageReportModel.money(estimated))") : L("Claude Code 记录"))
            tile("arrow.up.arrow.down.circle", "\(Int(Digest.number(t["requests"])))", L("次请求"), L("%@ 个模型", "\(model.rows("models").count)"))
            tile("text.word.spacing", UsageInfo.compact(Int(Digest.number(t["output"]))), L("输出 token"), L("输入 %@", "\(UsageInfo.compact(Int(input)))"))
            tile("internaldrive", UsageInfo.compact(Int(Digest.number(t["cacheRead"]))), L("读缓存"), L("写缓存 %@", "\(UsageInfo.compact(Int(Digest.number(t["cacheWrite"]))))"))
        }
    }

    private func tile(_ symbol: String, _ value: String, _ label: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DuoIcon(symbol: symbol, size: 26)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.app(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                Text(label).font(.app(size: 11.5)).foregroundStyle(.secondary)
            }
            Text(detail).font(.app(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .tarsCard(padding: 12, cornerRadius: 14)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每天花费").font(.app(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Chart(model.dayRows) { day in
                BarMark(x: .value("日期", day.date, unit: .day), y: .value("记录", day.cost - day.estimated))
                    .foregroundStyle(by: .value("类型", L("记录")))
                BarMark(x: .value("日期", day.date, unit: .day), y: .value("估算", day.estimated))
                    .foregroundStyle(by: .value("类型", L("估算")))
            }
            .chartForegroundStyleScale([L("记录"): Color.tarsBrand, L("估算"): Color.tarsBrand.opacity(0.4)])
            .chartYAxis { AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(UsageReportModel.money(v)) } }
            } }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: model.days > 10 ? 5 : 1)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
            } }
            .frame(height: 200)
        }
        .tarsCard(padding: 14, cornerRadius: 16)
    }

    @ViewBuilder
    private func table(_ title: String, _ rows: [UsageReportModel.Row]) -> some View {
        if !rows.isEmpty {
            let total = max(Digest.number(model.totals["cost"]), 0.0001)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.app(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name).font(.app(size: 13, weight: .semibold)).lineLimit(1)
                                Text("\(row.detail) · 输出 \(UsageInfo.compact(Int(row.output))) · 读缓存 \(UsageInfo.compact(Int(row.cacheRead)))")
                                    .font(.app(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                GeometryReader { geo in
                                    Capsule().fill(Color.primary.opacity(0.08))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(Color.tarsBrand).frame(width: geo.size.width * min(1, row.cost / total))
                                        }
                                }
                                .frame(height: 4)
                            }
                            Spacer(minLength: 12)
                            Text(UsageReportModel.money(row.cost)).font(.app(size: 13, weight: .semibold)).monospacedDigit()
                        }
                        .padding(.vertical, 8)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
                .tarsCard(padding: 12, cornerRadius: 14)
            }
        }
    }
}
