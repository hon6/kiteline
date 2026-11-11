import Foundation

// MARK: - 战绩（分享卡片）

/// 手机上「分享战绩」用的按天数字：问每台在线电脑的 watcher（brag），按天合并。
/// 只有数字（token、花费、改了几行、在线多久、同时几个会话），不带任何对话内容、文件名、项目名。
/// 在线时长和「最多同时」要把各台电脑的时间段并起来重算，所以 watcher 给每个会话那天的时间段（lanes，单位分钟）；
/// 发给手机前去掉 lanes，只留算好的数。
enum Brag {
    private static var cache: [Int: (at: Date, payload: [String: Any])] = [:]
    private static let sums = ["linesAdded", "linesRemoved", "files", "edits", "prompts", "toolCalls", "sessions",
                               "input", "output", "cacheRead", "cacheWrite", "requests", "cost"]

    static func collect(days: Int, fresh: Bool = false, completion: @escaping ([String: Any]) -> Void) {
        let days = max(1, min(days, 60))
        if !fresh, let hit = cache[days], Date().timeIntervalSince(hit.at) < 60 { completion(hit.payload); return }
        let since = Digest.startOfDay() - Int64(days - 1) * 86_400_000
        let tz = TimeZone.current.secondsFromGMT() / 60
        let state = AppState.shared
        var byDay: [String: [String: Any]] = [:]
        var lanes: [String: [[[Int]]]] = [:]
        var machines = 0
        var errors = state.sourceSummaries.filter { $0.config.enabled && !$0.state.isLive }
            .map { "\($0.config.displayName)：\($0.state.shortLabel)" }
        let complete = errors.isEmpty
        let group = DispatchGroup()
        for connection in state.liveSources {
            group.enter()
            connection.request(["cmd": "brag", "since": since, "tz": tz], timeout: 100) { result in
                switch result {
                case .success(let r):
                    machines += 1
                    for day in r["days"] as? [[String: Any]] ?? [] {
                        let key = day["day"] as? String ?? ""
                        var row = byDay[key] ?? ["day": key]
                        for field in sums { row[field] = Digest.number(row[field]) + Digest.number(day[field]) }
                        let agents = Set((row["agents"] as? [String] ?? []) + (day["agents"] as? [String] ?? []))
                        row["agents"] = agents.sorted()
                        for (field, pick) in [("firstAt", min), ("lastAt", max)] as [(String, (Double, Double) -> Double)] {
                            let mine = Digest.number(day[field])
                            guard mine > 0 else { continue }
                            let old = Digest.number(row[field])
                            row[field] = old > 0 ? pick(old, mine) : mine
                        }
                        // 阵容（按 agent、按模型的 token）逐项相加；24 小时曲线逐格相加（各台电脑的会话本来就不重复）
                        for field in ["agentTokens", "models"] {
                            var merged = row[field] as? [String: Double] ?? [:]
                            for (name, value) in day[field] as? [String: Any] ?? [:] { merged[name, default: 0] += Digest.number(value) }
                            row[field] = merged
                        }
                        let curve = (day["curve"] as? [Any] ?? []).map { Digest.number($0) }
                        if curve.count == 96 {
                            let old = row["curve"] as? [Double] ?? Array(repeating: 0, count: 96)
                            row["curve"] = zip(old, curve).map { $0 + $1 }
                        }
                        byDay[key] = row
                        let dayLanes = (day["lanes"] as? [[[Any]]] ?? []).map { lane in
                            lane.compactMap { span -> [Int]? in
                                span.count == 2 ? [Int(Digest.number(span[0])), Int(Digest.number(span[1]))] : nil
                            }
                        }
                        lanes[key, default: []] += dayLanes
                    }
                case .failure(let error):
                    errors.append("\(connection.config.displayName)：\(error.description)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var list: [[String: Any]] = []
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            for offset in 0..<days {
                let date = Date(timeIntervalSince1970: Double(since) / 1000 + Double(offset) * 86400 + 3600)
                let key = formatter.string(from: date)
                var row = byDay[key] ?? ["day": key, "agents": [String]()]
                for field in sums where row[field] == nil { row[field] = 0 }
                let merged = merge(lanes[key] ?? [])
                row["activeMinutes"] = merged.union
                row["agentMinutes"] = merged.total
                row["peak"] = merged.peak
                list.append(row)
            }
            let payload: [String: Any] = [
                "ok": true, "days": list, "range": days, "since": since, "machines": machines, "ref": UsageStats.referralCode,
                "errors": errors, "generatedAt": Int64(Date().timeIntervalSince1970 * 1000),
            ]
            if complete && errors.isEmpty { cache[days] = (Date(), payload) }
            completion(payload)
        }
    }

    /// 同 watcher 的 brag_merge：各会话时间段 → 并起来的分钟数、加起来的分钟数、最多同时几个
    static func merge(_ lanes: [[[Int]]]) -> (union: Int, total: Int, peak: Int) {
        var points: [(Int, Int)] = []
        var total = 0
        for lane in lanes {
            for span in lane where span.count == 2 && span[1] > span[0] {
                total += span[1] - span[0]
                points.append((span[0], 1))
                points.append((span[1], -1))
            }
        }
        points.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }   // 同一分钟先结束再开始
        var peak = 0, current = 0
        for point in points {
            current += point.1
            peak = max(peak, current)
        }
        var union: [[Int]] = []
        for span in lanes.flatMap({ $0 }).filter({ $0.count == 2 && $0[1] > $0[0] }).sorted(by: { $0[0] < $1[0] }) {
            if let last = union.last, span[0] <= last[1] {
                union[union.count - 1][1] = max(last[1], span[1])
            } else {
                union.append(span)
            }
        }
        return (union.reduce(0) { $0 + $1[1] - $1[0] }, total, peak)
    }
}

extension Brag {
    /// 晨报里的「昨日战绩」一行（中文、英文各一份）；昨天没干活回 nil
    static func yesterdayLine(_ payload: [String: Any], now: Date = Date()) -> (zh: String, en: String)? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)
        guard let day = (payload["days"] as? [[String: Any]] ?? []).first(where: { $0["day"] as? String == key }) else { return nil }
        let n = { (field: String) in Digest.number(day[field]) }
        let tokens = n("input") + n("output") + n("cacheRead") + n("cacheWrite")
        guard tokens > 0 || n("sessions") > 0 else { return nil }
        func zhNumber(_ v: Double) -> String {
            v >= 1e8 ? String(format: "%.2f 亿", v / 1e8) : v >= 1e4 ? String(format: "%.1f 万", v / 1e4) : String(Int(v))
        }
        func enNumber(_ v: Double) -> String {
            v >= 1e9 ? String(format: "%.2fB", v / 1e9) : v >= 1e6 ? String(format: "%.1fM", v / 1e6) : v >= 1e3 ? String(format: "%.1fK", v / 1e3) : String(Int(v))
        }
        let hours = n("activeMinutes") / 60
        var zh = ["昨日战绩：\(zhNumber(tokens)) Token"], en = ["Yesterday: \(enNumber(tokens)) tokens"]
        let lines = Int(n("linesAdded")).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        if n("linesAdded") > 0 { zh.append("+\(lines) 行代码"); en.append("+\(lines) lines") }
        if hours >= 0.1 { zh.append(String(format: "在线 %.1f 小时", hours)); en.append(String(format: "%.1f h online", hours)) }
        if n("peak") >= 2 { zh.append("最多同时 \(Int(n("peak"))) 个 Agent"); en.append("up to \(Int(n("peak"))) agents at once") }
        return (zh.joined(separator: " · "), en.joined(separator: " · "))
    }
}
