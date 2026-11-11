import CryptoKit
import Foundation

/// 已配对的设备：每台手机一把自己的钥匙（只存哈希），可以单独停用。
///
/// 扫码链接里带的是主令牌，它只用来「登记」：手机第一次打开就换成自己的设备令牌，之后只用设备令牌。
/// 配对码配对直接发设备令牌。停用一台设备 = 删掉它的哈希，它再来就是 401，得重新扫码 / 输配对码。
final class DeviceStore {
    struct Device: Codable, Equatable {
        var id: String
        var name: String
        var tokenHash: String
        var createdAt: Double
        var lastSeen: Double
        var lastIP: String
        var agent: String
        /// 怎么配上的：扫码 / 配对码
        var via: String
        /// 这台手机的点对点公钥：远程访问时 Mac 只接受这些设备的连接
        var p2pId: String?
        /// 这台手机配的 Apple Watch（手机报上来的）
        var watch: WatchState?
        /// App 每个请求带的机型、系统、App 版本（X-Kiteline-Client，如「ios/1.1 (iPhone13,2; iOS 18.7.8)」）；旧版 App 不带
        var client: String?
        /// App 的构建号：系统给 App 的请求自带的 User-Agent（「TARS/202610271712 CFNetwork/… Darwin/…」）里取，旧版 App 也有；自己装的开发版是 1
        var build: String?
        /// 订阅了 Kiteline Pro（App 每个请求带的 X-Kiteline-Pro）；旧版 App 不带
        var pro: Bool?
        /// 订阅的方案（App 带的 X-Kiteline-Plan）：year / month / unlocked（开发版放开、没买）；旧版 App 不带
        var plan: String?
        /// 最近一次经远程访问（点对点 / 中继）连进来的时间：点对点把连接转给本机 HTTPS 服务，来源是 127.0.0.1
        var remoteAt: Double?
        /// 微信小程序：中继给的用户编号（openid 摘要，10 位十六进制），随使用统计上报，运营后台据此对上小程序用户
        var mpUser: String?
        /// 分享战绩的次数：按渠道（friend 发给好友 / moments 朋友圈或存图 / save 存相册）、按天（最近 60 天），最近一次的时间；随使用统计上报
        var shares: [String: Int]?
        var shareDays: [String: Int]?
        var sharedAt: Double?
        /// computer = 互联的另一台 Kiteline 电脑（见 PeerComputers）；手机为空
        var kind: String?
        /// 电脑：对方电脑的编号；别的电脑替它的手机在本机登记的：那台电脑的编号
        var peer: String?
        /// 别的电脑替手机登记的：「那台电脑编号:手机在那台上的设备 id」（重新登记时换掉旧的）
        var ref: String?
    }

    static let shared = DeviceStore()
    /// 设备令牌以 d 开头，和主令牌（纯十六进制）区分开
    static let prefix = "d"

    private let lock = NSLock()
    private var devices: [Device] = []
    private var saveScheduled = false
    private var url: URL { AppConfig.directoryURL.appendingPathComponent("devices.json") }

    private init() {
        if let data = try? Data(contentsOf: url) {
            if let list = try? JSONDecoder().decode([Device].self, from: data) { devices = list } else {
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))"))
                Log.write("设备文件读不出来，已备份为 .bak")
            }
        }
    }

    /// 最近用过的在前
    var all: [Device] {
        lock.lock(); defer { lock.unlock() }
        return devices.sorted { $0.lastSeen > $1.lastSeen }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 登记一台新设备，返回它和它的令牌（令牌只在这时出现一次）
    func register(agent: String, ip: String, via: String, name: String? = nil) -> (Device, String) {
        let token = Self.prefix + MobileConfig.makeToken()
        let now = Date().timeIntervalSince1970 * 1000
        lock.lock()
        let base = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String($0.prefix(40)) }
            ?? Self.defaultName(agent)
        var finalName = base
        var index = 2
        while devices.contains(where: { $0.name == finalName }) { finalName = "\(base) \(index)"; index += 1 }
        let device = Device(id: String(UUID().uuidString.prefix(8)).lowercased(), name: finalName, tokenHash: Self.hash(token),
                            createdAt: now, lastSeen: now, lastIP: ip, agent: String(agent.prefix(300)), via: via)
        devices.append(device)
        lock.unlock()
        save()
        Log.write("登记设备「\(device.name)」（\(via)，\(ip)）")
        return (device, token)
    }

    /// 验证设备令牌；顺带记下最后使用时间、IP、App 报的机型版本、构建号、订阅状态和走没走远程访问（一分钟最多写一次盘）
    func authenticate(_ token: String, ip: String, client: String? = nil, agent: String? = nil, pro: Bool? = nil, mpUser: String? = nil, plan: String? = nil) -> Device? {
        guard token.hasPrefix(Self.prefix) else { return nil }
        let hash = Self.hash(token)
        lock.lock()
        guard let index = devices.firstIndex(where: { MobileServer.constantTimeEquals($0.tokenHash, hash) }) else {
            lock.unlock(); return nil
        }
        let now = Date().timeIntervalSince1970 * 1000
        var changed = false
        if now - devices[index].lastSeen > 60_000 || devices[index].lastIP != ip {
            devices[index].lastSeen = now
            devices[index].lastIP = ip
            changed = true
        }
        if let client = client.map({ String($0.prefix(120)) }), !client.isEmpty, devices[index].client != client {
            devices[index].client = client
            changed = true
        }
        if let build = agent.flatMap(Self.appBuild), devices[index].build != build {
            devices[index].build = build
            changed = true
        }
        if let pro, devices[index].pro != pro {
            devices[index].pro = pro
            changed = true
        }
        if pro != nil, devices[index].client != "miniprogram" {
            // 报了订阅状态就同步方案：没订阅的旧方案清掉
            let plan = plan.flatMap { ["year", "month", "unlocked"].contains($0) ? $0 : nil }
            if devices[index].plan != plan {
                devices[index].plan = plan
                changed = true
            }
        }
        // 以前配对的小程序没报名字，叫成了「浏览器」「浏览器 2」：认出是小程序后改成「微信小程序」（只改自动起的名字，用户改过的不动）
        if devices[index].client == "miniprogram", devices[index].name.range(of: #"^(Mac |Windows )?浏览器( \d+)?$"#, options: .regularExpression) != nil {
            var name = "微信小程序", n = 2
            while devices.contains(where: { $0.name == name }) { name = "微信小程序 \(n)"; n += 1 }
            devices[index].name = name
            changed = true
        }
        if devices[index].client == "miniprogram", let mpUser, mpUser.range(of: "^[0-9a-f]{10}$", options: .regularExpression) != nil,
           devices[index].mpUser != mpUser {
            devices[index].mpUser = mpUser
            changed = true
        }
        // 手机 App 从 127.0.0.1 连进来只可能是点对点转进来的（Mac 版 App 连本机不算）；小程序经中继来的隧道来源也记成 127.0.0.1
        let viaRemote = devices[index].client?.hasPrefix("ios/") == true || devices[index].client == "miniprogram"
        if Self.isLoopback(ip), viaRemote, now - (devices[index].remoteAt ?? 0) > 60_000 {
            devices[index].remoteAt = now
            changed = true
        }
        let device = devices[index]
        lock.unlock()
        if changed { scheduleSave() }
        return device
    }

    static func isLoopback(_ ip: String) -> Bool {
        let host = ip.split(separator: "%").first.map(String.init) ?? ip
        return host == "::1" || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }

    /// 「TARS/202610271712 CFNetwork/3860.600.12 Darwin/25.5.0」→ 202610271712；浏览器的 User-Agent 不算
    static func appBuild(_ agent: String) -> String? {
        guard let range = agent.range(of: #"^[A-Za-z]+/[0-9]{1,20} CFNetwork/"#, options: .regularExpression) else { return nil }
        return agent[range].split(whereSeparator: { $0 == "/" || $0 == " " }).dropFirst().first.map(String.init)
    }

    /// 只查不记（操作记录里显示设备名用）
    func peek(_ token: String) -> Device? {
        guard token.hasPrefix(Self.prefix) else { return nil }
        let hash = Self.hash(token)
        lock.lock(); defer { lock.unlock() }
        return devices.first { $0.tokenHash == hash }
    }

    @discardableResult
    func revoke(_ id: String) -> Device? {
        lock.lock()
        guard let index = devices.firstIndex(where: { $0.id == id }) else { lock.unlock(); return nil }
        let device = devices.remove(at: index)
        lock.unlock()
        save()
        Log.write("停用设备「\(device.name)」")
        P2P.shared.refreshAllowlist()   // 停用的手机远程也连不进来了
        // 电脑互联：停用的是一台电脑 → 互联一起解除；是手机 → 替它在别的电脑上的登记也作废
        DispatchQueue.main.async {
            if device.kind == "computer" { PeerComputers.shared.deviceRevoked(device) } else { PeerComputers.shared.phoneRevoked(device) }
        }
        return device
    }

    /// 电脑互联：标上是电脑、是哪台电脑的（或是哪台电脑替手机登记的）
    func setPeer(_ id: String, kind: String?, peer: String?, ref: String?) {
        lock.lock()
        guard let index = devices.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        devices[index].kind = kind
        devices[index].peer = peer
        devices[index].ref = ref
        lock.unlock()
        save()
    }

    /// 手机开通远程访问时报上来的点对点公钥
    func setP2PId(_ p2pId: String, for id: String) {
        lock.lock()
        guard let index = devices.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let changed = devices[index].p2pId != p2pId
        devices[index].p2pId = p2pId
        lock.unlock()
        if changed { save() }
    }

    /// 手机上点了分享战绩（发好友、发朋友圈、存图）：记一次，运营后台看谁分享了多少次
    func noteShare(_ via: String, for id: String) {
        let via = ["friend", "moments", "save"].contains(via) ? via : "other"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        lock.lock()
        guard let index = devices.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        var shares = devices[index].shares ?? [:]
        shares[via, default: 0] += 1
        var days = devices[index].shareDays ?? [:]
        days[day, default: 0] += 1
        for key in days.keys.sorted().dropLast(60) { days.removeValue(forKey: key) }   // 只留最近 60 天
        devices[index].shares = shares
        devices[index].shareDays = days
        devices[index].sharedAt = Date().timeIntervalSince1970 * 1000
        lock.unlock()
        save()
    }

    /// 手机报上来的手表状态：配没配 Apple Watch、手表上装没装 Kiteline
    func setWatch(paired: Bool, installed: Bool, complication: Bool?, for id: String) {
        lock.lock()
        guard let index = devices.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let old = devices[index].watch
        var state = WatchState(paired: paired, installed: installed, complication: complication,
                               updatedAt: Date().timeIntervalSince1970 * 1000, lastUsed: old?.lastUsed)
        if !paired { state.lastUsed = nil }
        let changed = old?.paired != state.paired || old?.installed != state.installed || old?.complication != state.complication
        devices[index].watch = state
        lock.unlock()
        if changed { save() }
    }

    /// 手表经这台手机来要数据、点按钮（请求带 via=watch）：记下最近使用时间，最多一分钟存一次盘
    func touchWatch(_ id: String) {
        let now = Date().timeIntervalSince1970 * 1000
        lock.lock()
        guard let index = devices.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        var state = devices[index].watch ?? WatchState(paired: true, installed: true, complication: nil, updatedAt: now)
        let stale = now - (state.lastUsed ?? 0) > 60_000
        state.paired = true
        state.installed = true
        state.lastUsed = now
        devices[index].watch = state
        lock.unlock()
        if stale { save() }
    }

    /// 允许远程连进来的手机（点对点公钥）
    var p2pIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return devices.compactMap(\.p2pId)
    }

    func rename(_ id: String, to name: String) -> Device? {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty else { return nil }
        lock.lock()
        guard let index = devices.firstIndex(where: { $0.id == id }) else { lock.unlock(); return nil }
        devices[index].name = clean
        let device = devices[index]
        lock.unlock()
        save()
        return device
    }

    /// 重置主令牌时一起清掉：所有手机都要重新配对
    func revokeAll() {
        lock.lock()
        devices.removeAll()
        lock.unlock()
        save()
        P2P.shared.refreshAllowlist()
    }

    static func defaultName(_ agent: String) -> String {
        if agent.contains("MiniProgram") { return "微信小程序" }   // 小程序入口（MPGate）给的 User-Agent：Kiteline-MiniProgram
        if agent.contains("iPhone") { return "iPhone" }
        if agent.contains("iPad") { return "iPad" }
        if agent.contains("Android") { return "安卓手机" }
        if agent.contains("Macintosh") { return "Mac 浏览器" }
        if agent.contains("Windows") { return "Windows 浏览器" }
        return "浏览器"
    }

    private func scheduleSave() {
        lock.lock()
        let already = saveScheduled
        saveScheduled = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.lock.lock()
            self?.saveScheduled = false
            self?.lock.unlock()
            self?.save()
        }
    }

    /// 快照和写盘放在同一个串行队列里：后台的延迟保存不会把刚停用的设备写回去
    private let saveQueue = DispatchQueue(label: "tars.devices.save")

    private func save() {
        saveQueue.sync { self.writeNow() }
    }

    private func writeNow() {
        lock.lock()
        let snapshot = devices
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // 只有本机用户能读
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
