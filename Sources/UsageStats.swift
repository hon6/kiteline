import CryptoKit
import Foundation

/// 使用统计：每 15 分钟把精简的使用情况报给 Kiteline 的服务器（relay/stats，tars.betac.cn/stats/report），
/// 运营后台按它看有哪些客户、各自几台设备、几个会话、用哪些 agent 和模型。
///
/// 只有数字和类别：配对设备的类型 / 系统 / App 版本、会话的 agent / 模型 / token / 上下文 / 时长、按天的用量合计，
/// 加上「我」的名字。不带对话、代码、文件、项目路径、会话标题；设备和会话的 id 都换成和本机编号一起算的摘要。
/// 设置里「发送使用统计」可以关（mobile.usageStats）。测试实例不报，除非用 CCPULSE_STATS_URL 指了地址。
enum UsageStats {
    static let interval: TimeInterval = 15 * 60
    /// 按天用量要扫会话记录：6 小时带一次
    static let usageEvery: TimeInterval = 6 * 3600
    /// 什么都没变也每 6 小时报一次，后台才知道这台电脑还开着
    static let heartbeat: TimeInterval = 6 * 3600

    private static var timer: Timer?
    private static var sending = false
    private static var lastSent: Date?
    private static var lastFingerprint: Data?
    private static var lastUsage: Date?

    static var endpoint: URL? {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["CCPULSE_STATS_URL"] { return URL(string: custom) }
        if AppConfig.isolated || env["CCPULSE_DRY_RUN"] != nil { return nil }
        return URL(string: "https://tars.betac.cn/stats/report")
    }

    static func start() {
        guard timer == nil, endpoint != nil else { return }
        // 启动后先等两分钟：来源连上、会话列表齐了再报
        let delay = Double(ProcessInfo.processInfo.environment["CCPULSE_STATS_DELAY"] ?? "") ?? 120
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tick() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in tick() }
    }

    /// 设置里关了再开：马上报一次
    static func tick(force: Bool = false) {
        guard let url = endpoint, AppState.shared.config.mobile.usageStats, !sending else { return }
        sending = true
        let wantUsage = force || lastUsage.map { Date().timeIntervalSince($0) > usageEvery } ?? true
        // 本机装了哪些 Agent：一小时问一次（后台据此看出「装了 Kiteline 却没有任何 Agent」的电脑）
        let wantAgents = force || lastAgentCheck.map { Date().timeIntervalSince($0) > 3600 } ?? true
        AgentCheck.run(skip: !wantAgents) { found in
            if let found {
                installedAgents = found.filter(\.installed).map(\.id)
                lastAgentCheck = Date()
            }
            collectUsage(wantUsage) { usage in
                var body = snapshot()
                let fingerprint = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
                if usage == nil, !force, fingerprint == lastFingerprint, let last = lastSent, Date().timeIntervalSince(last) < heartbeat {
                    sending = false
                    return
                }
                if let usage {
                    body["days"] = usage.days
                    body["models"] = usage.models
                }
                post(url, body) { ok in
                    sending = false
                    guard ok else { return }
                    lastSent = Date()
                    lastFingerprint = fingerprint
                    if usage != nil { lastUsage = Date() }
                }
            }
        }
    }

    /// 本机检测到的 Agent（id）：nil = 还没检测过（报 null）
    static var installedAgents: [String]?
    private static var lastAgentCheck: Date?

    /// 用户主动提交的反馈（第一次打开的引导里「你使用的 Agent 不在列表中？」）：和使用统计同一个本机编号，
    /// 发到 /stats/feedback。是用户自己点的「提交」，不看「帮助改进 Kiteline」开关；测试实例没指地址时不发
    static func feedback(_ fields: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let url = endpoint?.deletingLastPathComponent().appendingPathComponent("feedback") else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var body: [String: Any] = [
            "v": 1, "install": identity.install, "key": identity.key,
            "name": Profile.displayName(AppState.shared.config.mobile), "platform": "macos",
            "os": "macOS \(os.majorVersion).\(os.minorVersion)", "app": AppVersion.app,
            "lang": Locale.preferredLanguages.first ?? "",
        ]
        body.merge(fields) { _, new in new }
        post(url, body, completion: completion)
    }

    // MARK: 本机编号

    private struct Identity: Codable {
        var install: String
        var key: String
    }

    /// 第一次用时随机生成，存在配置目录（只有本机用户能读）；删了就当新客户
    private static let identity: Identity = {
        let url = AppConfig.directoryURL.appendingPathComponent("stats-id.json")
        if let data = try? Data(contentsOf: url), let id = try? JSONDecoder().decode(Identity.self, from: data),
           id.install.count == 32, id.key.count == 32 {
            return id
        }
        let id = Identity(install: randomHex(16), key: randomHex(16))
        try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
        try? JSONEncoder().encode(id).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return id
    }()

    private static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 推荐码：分享战绩时印进专属小程序码、写进转发卡片的链接；新用户经它打开小程序，中继记下是谁带来的。
    /// 和统计编号一起算的 8 位摘要，运营后台用同样的算法对回是哪个客户（relay/stats 的 referralCode）；不含任何个人信息
    static var referralCode: String {
        SHA256.hash(data: Data(("kiteline-ref/" + identity.install).utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// 设备、会话的 id 不原样发：和本机编号一起算个摘要，后台只拿来区分是不是同一个
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data((identity.install + "/" + value).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 内容

    static func snapshot() -> [String: Any] {
        let state = AppState.shared
        let mobile = state.config.mobile
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let devices = DeviceStore.shared.all
        let pushed = state.mobile.push.deviceIds(except: [])
        let sources = state.sourceSummaries
        return [
            "v": 1,
            "install": identity.install,
            "key": identity.key,
            "name": Profile.displayName(mobile),
            "platform": "macos",
            "os": "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""),
            "arch": arch,
            "app": AppVersion.app,
            "lang": Locale.preferredLanguages.first ?? "",
            "tz": TimeZone.current.secondsFromGMT() / 60,
            "features": [
                "remote": mobile.remoteEnabled && devices.contains { $0.p2pId != nil },
                "push": !pushed.isEmpty,
                "bark": !mobile.barkURL.isEmpty,
                "ssh": sources.contains { $0.config.kind == .ssh && $0.config.enabled },
                "digest": !mobile.digestTime.isEmpty,
                "budget": mobile.dailyBudget > 0 || mobile.dailyCap > 0,
                "watch": devices.contains { $0.watch?.installed == true },
            ],
            "hosts": sources.filter { $0.config.enabled }.map { ["kind": $0.config.kind == .ssh ? "ssh" : "local", "live": $0.state.isLive] },
            // 本机装了哪些 Agent；还没检测过时是 null（后台显示「未知」，和「一个都没有」分开）
            "agents": installedAgents.map { $0 as Any } ?? NSNull(),
            "devices": devices.map { device(for: $0, pushed: pushed.contains($0.id)) },
            "sessions": state.store.records.map(session(for:)),
        ]
    }

    private static func device(for d: DeviceStore.Device, pushed: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": digest("device/" + d.id), "via": d.via == "扫码" ? "qr" : "code", "remote": d.p2pId != nil,
                                  "push": pushed, "createdAt": Int64(d.createdAt), "lastSeen": Int64(d.lastSeen)]
        if let pro = d.pro { out["pro"] = pro }
        if let plan = d.plan { out["plan"] = plan }
        if let remoteAt = d.remoteAt { out["remoteAt"] = Int64(remoteAt) }
        // 分享战绩的次数（按渠道、按天）：运营后台看谁分享了多少次
        if let shares = d.shares, !shares.isEmpty {
            out["shares"] = shares
            out["shareDays"] = d.shareDays ?? [:]
            if let at = d.sharedAt { out["sharedAt"] = Int64(at) }
        }
        if d.client == "miniprogram" {
            // 微信小程序（来源由电脑端的小程序入口定，不能冒充）；mpUser 是中继给的用户编号，后台据此对上小程序用户和订阅
            out["kind"] = "miniprogram"
            if let mp = d.mpUser { out["mpUser"] = mp }
        } else if let client = parseClient(d.client) {
            out["kind"] = client.model.hasPrefix("iPad") ? "ipad" : client.platform == "mac" ? "mac-app" : "iphone"
            out["model"] = client.model
            out["os"] = client.os
            out["app"] = client.app
        } else {
            // 旧版 App 不报机型：从 User-Agent 猜个大概（Darwin 内核版本换成 iOS 版本）
            let agent = d.agent
            if agent.hasPrefix("TARS/") || agent.contains("CFNetwork") {
                out["kind"] = d.name.contains("iPad") ? "ipad" : "iphone"
                if let os = iOSFromDarwin(agent) { out["os"] = os }
            } else if agent.contains("Android") {
                out["kind"] = "android"
            } else if agent.contains("iPhone") || agent.contains("iPad") {
                out["kind"] = "browser"
                out["os"] = agent.contains("iPad") ? "iPadOS" : "iOS"
            } else {
                out["kind"] = agent.contains("Macintosh") ? "browser-mac" : agent.contains("Windows") ? "browser-windows"
                    : agent.contains("Linux") ? "browser-linux" : "browser"
            }
        }
        if let build = d.build { out["build"] = build }
        if out["kind"] as? String == "ipad", let os = out["os"] as? String, os.hasPrefix("iOS ") {
            out["os"] = "iPadOS " + os.dropFirst(4)
        }
        if let watch = d.watch, watch.paired {
            out["watch"] = !watch.installed ? "paired" : watch.complication == true ? "complication" : "installed"
            if let used = watch.lastUsed { out["watchUsed"] = Int64(used) }
        }
        return out
    }

    /// 「ios/1.1 (iPhone13,2; iOS 18.7.8)」→ (ios, 1.1, iPhone13,2, iOS 18.7.8)
    static func parseClient(_ raw: String?) -> (platform: String, app: String, model: String, os: String)? {
        guard let raw, let slash = raw.firstIndex(of: "/"), let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"),
              slash < open, open < close else { return nil }
        let inside = raw[raw.index(after: open)..<close].split(separator: ";", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard inside.count == 2 else { return nil }
        return (String(raw[..<slash]), raw[raw.index(after: slash)..<open].trimmingCharacters(in: .whitespaces), inside[0], inside[1])
    }

    /// CFNetwork 的 User-Agent 里只有 Darwin 版本：24.6 → iOS 18.6；之后 iOS 26 是 Darwin 25，27 起两边版本号一致
    static func iOSFromDarwin(_ agent: String) -> String? {
        guard let range = agent.range(of: #"Darwin/(\d+)\.(\d+)"#, options: .regularExpression) else { return nil }
        let parts = agent[range].dropFirst("Darwin/".count).split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let major = parts[0] <= 24 ? parts[0] - 6 : parts[0] == 25 ? 26 : parts[0]
        return "iOS \(major).\(parts[1])"
    }

    private static func session(for record: SessionRecord) -> [String: Any] {
        let s = record.snapshot
        let u = s.usage
        var out: [String: Any] = [
            "id": digest("session/" + record.key), "agent": s.agentID, "entry": s.entrypoint ?? "",
            "host": record.kind == .ssh ? "ssh" : "local", "model": u?.model ?? "", "version": s.version ?? "",
            "context": u?.context ?? 0, "window": u?.window ?? 0, "input": u?.input ?? 0, "output": u?.output ?? 0,
            "cacheRead": u?.cacheRead ?? 0, "cacheWrite": u?.cacheWrite ?? 0, "requests": u?.requests ?? 0, "cost": u?.cost ?? 0,
            "subagents": s.subagents ?? 0, "effort": s.effort?.effort ?? "", "mode": s.effort?.mode ?? "", "activity": s.activity,
        ]
        if let started = millis(s.startedAt) { out["startedAt"] = started }
        if let updated = millis(s.updatedAt ?? s.transcriptUpdatedAt) { out["updatedAt"] = updated }
        return out
    }

    /// watcher 报的时间有秒也有毫秒：统一成毫秒
    private static func millis(_ value: Double?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return Int64(value < 1e12 ? value * 1000 : value)
    }

    /// 近 30 天按天、按模型的用量（和「用量」页同一份算法，含已经结束的会话）。有来源没连上时这次不带，免得把那几天报少了
    private static func collectUsage(_ want: Bool, completion: @escaping ((days: [[String: Any]], models: [[String: Any]])?) -> Void) {
        guard want else { completion(nil); return }
        UsageReport.collect(days: 30) { payload in
            let errors = payload["errors"] as? [String] ?? []
            guard errors.isEmpty else { completion(nil); return }
            let keys = ["input", "output", "cacheRead", "cacheWrite", "requests", "cost"]
            func pick(_ item: [String: Any], _ name: String) -> [String: Any] {
                var out: [String: Any] = [name: item[name] ?? ""]
                for key in keys { out[key] = key == "cost" ? Digest.number(item[key]) : Int64(Digest.number(item[key])) }
                return out
            }
            let days = (payload["days"] as? [[String: Any]] ?? []).map { pick($0, "day") }
            let models = (payload["models"] as? [[String: Any]] ?? []).prefix(30).map { pick($0, "model") }
            completion((days, Array(models)))
        }
    }

    private static func post(_ url: URL, _ body: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { completion(false); return }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Kiteline/\(AppVersion.app) (macOS)", forHTTPHeaderField: "User-Agent")
        if let compressed = Gzip.compress(data) {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = compressed
        } else {
            request.httpBody = data
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || status != 200 { Log.write("使用统计没报上去：\(error?.localizedDescription ?? "HTTP \(status)")") }
            DispatchQueue.main.async { completion(error == nil && status == 200) }
        }.resume()
    }
}
