import AppKit
import Combine
import CryptoKit
import Security
import SwiftUI
import KitelineKit

/// 检查更新（同 Windows / Linux 版 desktop/kiteline/updater.py）：
/// 官网下载页的 latest.json（relay/download.sh 发布时写）→ 有新版本时主窗口右上角出绿色箭头 → 确认后下载 DMG（带进度、核对大小和 SHA-256）
/// → 静默装好：挂载 DMG、核对签名是同一个开发者、拷到 App 旁边待换 → 提示重启；点「立即重启」时由一个小脚本等 Kiteline 退出、
/// 换上新版本再打开；点「稍后」就在下次退出时换。
/// 只有官网下载的版本（Developer ID 签名）会自动安装：本机自己编的开发版签名不同，换过去辅助功能等权限要重新给，只提示去官网下载
///
/// 发现新版本时主动弹出更新窗口（不抢前台）：「以后再说」24 小时后再弹，勾了「此版本不再提示」这个版本就不再弹，出了更新的版本再弹。
/// 顺带看配对过的手机：App Store 上有比手机上新的 Kiteline 时，同样弹一次「手机端有新版本」（PhoneUpdateWindowController）。
/// 手机也能反过来看这台电脑的更新、让它下载安装和重启（/api/host-update → payload() / remote(_:)）
///
/// 自动更新（设置里默认开，mobile.autoUpdate）：发现新版本不弹窗，直接在后台下载装好，等电脑空闲时（没人用电脑、
/// 没有会话在运行或等确认、手机这几分钟没在看）自动重启换上，不抢前台。下载走差量（DeltaBuilder）：latest.json 的
/// files 指向这个版本的文件清单，本机已有的文件直接拷，变了的文件下二进制补丁或整个文件，拼出新版本后照样核对签名；
/// 拼不出来就退回下载整个 DMG。关掉自动更新 = 回到发现新版本弹窗询问
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: String { case idle, checking, none, available, downloading, installing, ready, restarting, error }

    struct Release: Equatable {
        var version: String
        var url: URL
        var size: Int64
        var sha256: String
        var notesZh: String
        var notesEn: String
        /// 落后的这几版各自的更新内容（新的在前，官网的 notes-mac.json）；取不到就是空的，只显示这一版的 notes
        var history: [Note] = []
        /// 这台落后了几个版本（latest.json 里发过的版本 versions 中比这台新的）
        var behind = 0
        /// 差量更新：文件清单的地址、SHA-256，从各旧版本更新过来要下载多少（版本 → 字节）；旧官网没有就是 nil
        var delta: Delta?

        var notes: String { Lang.shared.isEnglish && !notesEn.isEmpty ? notesEn : notesZh }
    }

    struct Delta: Equatable {
        var url: URL
        var sha256: String
        var from: [String: Int64]
    }

    /// 一个版本的更新内容
    struct Note: Equatable {
        var version: String
        var date: String
        var zh: String
        var en: String

        var text: String { Lang.shared.isEnglish && !en.isEmpty ? en : zh }
        var payload: [String: Any] { ["version": version, "date": date, "notes": zh, "notesEn": en] }
    }

    /// App Store 上比配对过的手机新的 Kiteline：哪个版本、更新内容、哪几台手机还是旧版本
    struct PhoneOffer: Equatable {
        var version: String
        var notes: String
        /// 设备名 → 手机上的版本
        var devices: [Device]

        struct Device: Equatable { var name: String; var version: String }
        var key: String { Updater.phoneKey(version) }
    }

    /// 什么时候主动弹窗：电脑端自己的新版本 / 手机端的新版本
    enum Prompt { case own, phones }

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { phaseChanged() } }
    }
    @Published private(set) var release: Release?
    @Published private(set) var received: Int64 = 0
    /// 这次要下载的总字节数：差量是算出来的那些，整包是 DMG 大小
    @Published private(set) var total: Int64 = 0
    /// 这次是自动更新开始的：装好了不弹窗，等空闲自动重启
    @Published private(set) var silent = false
    /// 自动重启还在等什么（「电脑有人在用」……），更新窗口里显示；空 = 没在等
    @Published private(set) var waitingFor = ""
    @Published private(set) var error = ""
    @Published private(set) var phones: PhoneOffer?
    /// 勾了「此版本不再提示」的（mac:3.49.16、ios:1.7）：不再自动弹，侧栏的箭头照样在
    @Published private(set) var skipped = Set(AppConfig.defaults.stringArray(forKey: "updateSkipped") ?? [])
    /// 上次弹过的时间 + 24 小时（同上的键 → 秒）：这之前不再自动弹
    private var snoozed = AppConfig.defaults.dictionary(forKey: "updateSnoozed") as? [String: Double] ?? [:]
    static let snoozeFor: TimeInterval = 24 * 3600
    /// 该弹窗了（UpdateWindowController 听着）
    let prompts = PassthroughSubject<Prompt, Never>()
    /// App Store 上的 iPhone 版：上次查到的和什么时候查的（六小时查一次）
    private var store: (version: String, notes: String, minimumOS: String)?
    private var storeChecked = Date.distantPast

    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    /// 右上角要不要出绿色箭头
    var visible: Bool { [.available, .downloading, .installing, .ready].contains(phase) || (phase == .error && release != nil) }
    var progress: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    /// 自动更新开着（设置里）且这台能自动装
    var auto: Bool { supported && AppState.shared.config.mobile.autoUpdate }
    /// 从这台的版本更新过去大概要下载多少：差量算得出来就用差量的，不然是整个安装包
    var expectedSize: Int64 { release.flatMap { $0.delta?.from[current] } ?? release?.size ?? 0 }

    /// 能不能自动安装：官网下载版（Developer ID，有开发者团队号）；测试时 CCPULSE_UPDATE_ANY=1 放开
    private(set) lazy var teamID: String? = Self.teamIdentifier(Bundle.main.bundleURL)
    var supported: Bool { teamID != nil || ProcessInfo.processInfo.environment["CCPULSE_UPDATE_ANY"] == "1" }
    var reason: String { supported ? "" : L("此版本是本机编译的开发版，不会自动安装") }

    private var timer: Timer?
    private var download: Downloader?
    /// 装好待换的新版本（App 旁边的 .Kiteline-<版本>.app）
    private var staged: URL?
    private var installOnQuit = true
    /// 差量拼过失败的版本：下次直接下整包
    private var deltaFailed = Set<String>()
    private var deltaJob: DeltaBuilder?
    private var idleTimer: Timer?
    private var readySince: Date?

    private var feed: URL {
        if let override = ProcessInfo.processInfo.environment["CCPULSE_UPDATE_URL"], let url = URL(string: override) { return url }
        let relay = AppState.shared.config.mobile.effectiveRelay
        return URL(string: relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/download/latest.json")!
    }

    var downloadPage: URL { feed.deletingLastPathComponent() }

    // MARK: 检查

    /// 启动 30 秒后查一次，之后每小时一次（发版后各端一小时内就会出绿色箭头；latest.json 才几百字节）；测试实例只在给了 CCPULSE_UPDATE_URL 时查
    func start() {
        let env = ProcessInfo.processInfo.environment
        if AppConfig.isolated && env["CCPULSE_UPDATE_URL"] == nil { return }
        let first = Double(env["CCPULSE_UPDATE_DELAY"] ?? "") ?? 30
        DispatchQueue.main.asyncAfter(deadline: .now() + first) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check(manual: Bool = false) {
        guard [.idle, .none, .available, .error].contains(phase) else { return }
        let previous = phase
        phase = .checking
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Kiteline/\(current) (mac)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    Log.write("检查更新失败：\(error?.localizedDescription ?? "返回内容不对")")
                    // 查不到不算错：之前发现过的新版本照旧显示
                    self.phase = previous == .available ? .available : (manual ? .error : previous == .checking ? .idle : previous)
                    if manual { self.error = L("无法连接更新服务器") }
                    return
                }
                let mac = (json["platforms"] as? [String: Any])?[Self.platformKey] as? [String: Any]
                if let mac, let version = mac["version"] as? String, let link = mac["url"] as? String, let url = URL(string: link),
                   Self.newer(version, than: self.current) {
                    var found = Release(version: version, url: url, size: Int64(Digest.number(mac["size"])), sha256: mac["sha256"] as? String ?? "",
                                        notesZh: mac["notes"] as? String ?? "", notesEn: mac["notesEn"] as? String ?? "")
                    found.behind = Set((mac["versions"] as? [String] ?? []).filter { Self.newer($0, than: self.current) && !Self.newer($0, than: version) }).count
                    if let files = mac["files"] as? [String: Any], let link = files["url"] as? String, let url = URL(string: link),
                       let sha = files["sha256"] as? String, !sha.isEmpty {
                        let from = (files["from"] as? [String: Any] ?? [:]).mapValues { Int64(Digest.number($0)) }
                        found.delta = Delta(url: url, sha256: sha, from: from)
                    }
                    let fresh = self.release?.version != version
                    if fresh { Log.write("发现新版本 \(version)（当前 \(self.current)）") } else { found.history = self.release?.history ?? [] }
                    self.release = found
                    self.error = ""
                    self.phase = .available
                    if fresh { self.fetchHistory(version) }
                    if self.auto {
                        // 自动更新：不弹窗，直接在后台下载装好（手动点「检查更新」的也一样，窗口里看得到进度）
                        if !manual { Log.write("自动更新：开始在后台下载 \(version)") }
                        self.begin(auto: !manual)
                    } else if !manual, self.due(Self.ownKey(version)) {
                        self.markShown(Self.ownKey(version))
                        self.prompts.send(.own)
                    }
                } else {
                    self.release = nil
                    self.phase = .none
                }
                self.checkPhones()
            }
        }.resume()
    }

    /// 落后的这几版各自的更新内容：官网 latest.json 旁边的 notes-mac.json（relay/download.sh 发布时写，最近十几版）；
    /// 旧的官网没有这个文件，就只显示新版本这一版的
    private func fetchHistory(_ version: String) {
        let url = feed.deletingLastPathComponent().appendingPathComponent("notes-mac.json")
        URLSession.shared.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)) { [weak self] data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["releases"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                guard let self, self.release?.version == version else { return }
                let notes = list.compactMap { item -> Note? in
                    guard let v = item["version"] as? String, Self.newer(v, than: self.current), !Self.newer(v, than: version) else { return nil }
                    let note = Note(version: v, date: item["date"] as? String ?? "", zh: item["notes"] as? String ?? "", en: item["notesEn"] as? String ?? "")
                    return note.zh.isEmpty && note.en.isEmpty ? nil : note
                }
                self.release?.history = Array(notes.sorted { Self.newer($0.version, than: $1.version) }.prefix(8))
            }
        }.resume()
    }

    // MARK: 什么时候弹

    static func ownKey(_ version: String) -> String { "mac:\(version)" }
    static func phoneKey(_ version: String) -> String { "ios:\(version)" }

    func isSkipped(_ key: String) -> Bool { skipped.contains(key) }

    /// 勾 / 取消「此版本不再提示」：当场记下，直接关窗口也算
    func setSkipped(_ key: String, _ on: Bool) {
        if on { skipped.insert(key) } else { skipped.remove(key) }
        // 只留最近的几个：换了版本的旧键不会再用到
        if skipped.count > 20 { skipped = Set(skipped.sorted().suffix(10)) }
        AppConfig.defaults.set(skipped.sorted(), forKey: "updateSkipped")
    }

    /// 该自动弹：没勾「不再提示」、上次弹过已经过了一天
    private func due(_ key: String) -> Bool {
        !skipped.contains(key) && (snoozed[key] ?? 0) <= Date().timeIntervalSince1970
    }

    /// 弹过了（自动弹的、自己点开的都算）：24 小时内不再自动弹
    func markShown(_ key: String) {
        let now = Date().timeIntervalSince1970
        snoozed[key] = now + Self.snoozeFor
        snoozed = snoozed.filter { $0.value > now }
        AppConfig.defaults.set(snoozed, forKey: "updateSnoozed")
    }

    // MARK: 手机端的新版本

    /// 配对过的 iPhone / iPad 有没有比 App Store 上旧的：App Store 六小时问一次，设备每次检查都重新看（手机升级了提示就收起）
    private func checkPhones() {
        let env = ProcessInfo.processInfo.environment
        if Date().timeIntervalSince(storeChecked) < (env["CCPULSE_STORE_LOOKUP"] == nil ? 6 * 3600 : 0) {
            evaluatePhones()
            return
        }
        storeChecked = Date()
        let regionCode: String?
        if #available(macOS 13, *) { regionCode = Locale.current.region?.identifier } else { regionCode = Locale.current.regionCode }
        let region = regionCode?.lowercased() ?? "cn"
        let link = env["CCPULSE_STORE_LOOKUP"] ?? "https://itunes.apple.com/lookup?bundleId=com.mrhong.tars.ios&country=\(region)"
        guard let url = URL(string: link) else { return }
        URLSession.shared.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)) { [weak self] data, response, _ in
            let first = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["results"] as? [[String: Any]])?.first
            DispatchQueue.main.async {
                guard let self else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200, let first, let version = first["version"] as? String {
                    self.store = (version, first["releaseNotes"] as? String ?? "", first["minimumOsVersion"] as? String ?? "")
                } else if region != "cn", env["CCPULSE_STORE_LOOKUP"] == nil {
                    self.storeChecked = .distantPast   // 这个地区没上架：下次按中国区查
                }
                self.evaluatePhones()
            }
        }.resume()
    }

    private func evaluatePhones() {
        guard let store else { phones = nil; return }
        // 最近 30 天用过的手机：「ios/1.6 (iPhone13,2; iOS 18.7.8)」→ App 1.6、系统 18.7.8；系统低于新版本要求的装不上，不算
        let recent = Date().timeIntervalSince1970 * 1000 - 30 * 86_400_000
        let devices = DeviceStore.shared.all.compactMap { device -> PhoneOffer.Device? in
            guard device.lastSeen > recent, let client = device.client, client.hasPrefix("ios/") else { return nil }
            let app = String(client.dropFirst(4).prefix { $0 != " " })
            let system = client.range(of: #"iOS [0-9.]+"#, options: .regularExpression).map { String(client[$0].dropFirst(4)) } ?? ""
            guard app.first?.isNumber == true, Self.newer(store.version, than: app), store.minimumOS.isEmpty || system.isEmpty || !Self.newer(store.minimumOS, than: system) else { return nil }
            return PhoneOffer.Device(name: device.name, version: app)
        }
        let offer = devices.isEmpty ? nil : PhoneOffer(version: store.version, notes: store.notes, devices: devices)
        if offer != phones { phones = offer }
        if let offer, due(offer.key) {
            markShown(offer.key)
            prompts.send(.phones)
        }
    }

    // MARK: 手机上看这台电脑的更新（/api/host-update）

    /// 同 Windows / Linux 版 updater.state()：字段名一样，手机一套代码看两种电脑
    func payload() -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true, "supported": supported, "reason": supported ? "" : "此版本是本机编译的开发版，不会自动安装", "current": current,
            "phase": phase.rawValue, "version": release?.version ?? "", "notes": release?.notesZh ?? "", "notesEn": release?.notesEn ?? "",
            "size": phase == .downloading ? total : expectedSize, "received": received, "error": error, "page": downloadPage.absoluteString,
            "autoUpdate": auto, "waitingFor": waitingFor,
        ]
        if let release {
            // 至少有新版本这一版
            let list = release.history.isEmpty ? [Note(version: release.version, date: "", zh: release.notesZh, en: release.notesEn)] : release.history
            payload["releases"] = list.map(\.payload)
        }
        return payload
    }

    /// 手机上点的：check 现在查、start 下载并安装、cancel 取消下载、restart 重启换上新版本
    func remote(_ action: String) -> [String: Any] {
        switch action {
        case "check": check(manual: true)
        case "start":
            guard supported else { return payload().merging(["ok": false, "error": "此版本是本机编译的开发版，不会自动安装，请在电脑上到官网下载新版本"]) { $1 } }
            Log.write("手机上点了更新电脑端 Kiteline \(release?.version ?? "")")
            begin()
        case "cancel": cancel()
        case "restart":
            guard phase == .ready else { return payload().merging(["ok": false, "error": "新版本还没有装好"]) { $1 } }
            Log.write("手机上点了重启电脑端 Kiteline 以完成更新")
            // 先回复手机再退出
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.restart() }
            return payload().merging(["phase": Phase.restarting.rawValue]) { $1 }
        default: return ["ok": false, "error": "未知操作"]
        }
        return payload()
    }

    /// latest.json 里读哪个平台：macOS 14 起是主包「mac」；macOS 12 / 13 上只能装兼容包「mac12」（MINOS=12 编的那份，
    /// 见 docs/platforms/mac-compat.md）。兼容包装在后来升到 14 的电脑上，下次更新自然换成主包
    static var platformKey: String {
        if #available(macOS 14, *) { return "mac" }
        return "mac12"
    }

    static func newer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            var list = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
            while list.count > 1, list.last == 0 { list.removeLast() }
            return list
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: 下载、安装

    /// auto：自动更新开始的（装好了不弹窗、等空闲自动重启）；用户点的、手机上点的是 false
    func begin(auto: Bool = false) {
        guard supported, let release, [.available, .error].contains(phase) else { return }
        phase = .downloading
        silent = auto
        received = 0
        total = 0
        error = ""
        let folder = Self.workFolder
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let delta = release.delta, !deltaFailed.contains(release.version) else { beginFull(release); return }
        // 差量：本机已有的文件直接拷、只下变了的；拼不出来退回下载整包
        // 测试实例可以指定拿哪份 App 当本机文件（CCPULSE_UPDATE_BASE，比如官网的旧版）、按哪个团队号核对签名（CCPULSE_UPDATE_TEAM）
        let env = ProcessInfo.processInfo.environment
        let base = AppConfig.isolated ? env["CCPULSE_UPDATE_BASE"].map { URL(fileURLWithPath: $0) } : nil
        let team = AppConfig.isolated ? env["CCPULSE_UPDATE_TEAM"] ?? teamID : teamID
        let job = DeltaBuilder(delta: delta, version: release.version, team: team, base: base ?? Bundle.main.bundleURL, work: folder,
                               planned: { [weak self] bytes in DispatchQueue.main.async { self?.total = bytes } },
                               progress: { [weak self] bytes in DispatchQueue.main.async { self?.received = bytes } })
        deltaJob = job
        DispatchQueue.global(qos: .utility).async {
            let outcome = Result { try job.run() }
            DispatchQueue.main.async {
                self.deltaJob = nil
                switch outcome {
                case .success(let app):
                    self.staged = app
                    self.phase = .ready
                    Log.write("新版本 \(release.version) 已装好（差量，下载 \(self.received) 字节），重启后生效")
                case .failure(let failure) where failure is DeltaBuilder.Cancelled:
                    self.phase = .available
                    self.received = 0
                case .failure(let failure):
                    Log.write("差量更新没成功（\(failure.localizedDescription)），改为下载整个安装包")
                    self.deltaFailed.insert(release.version)
                    self.received = 0
                    self.beginFull(release)
                }
            }
        }
    }

    /// 下载整个 DMG 装（旧官网没有文件清单、差量拼不出来时）
    private func beginFull(_ release: Release) {
        total = release.size
        received = 0
        let downloader = Downloader(url: release.url, progress: { [weak self] bytes in self?.received = bytes }) { [weak self] result in
            guard let self else { return }
            self.download = nil
            switch result {
            case .failure(let failure):
                if (failure as? URLError)?.code == .cancelled { self.phase = .available; self.received = 0; return }
                // 服务器回了错误码的已经写好「下载失败：…」，别再套一层
                self.fail(failure is Failure ? failure.localizedDescription : L("下载失败：%@", failure.localizedDescription))
            case .success(let file):
                self.phase = .installing
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = Result { try self.install(file, release: release) }
                    DispatchQueue.main.async {
                        switch outcome {
                        case .success(let app):
                            self.staged = app
                            self.phase = .ready
                            Log.write("新版本 \(release.version) 已装好，重启后生效")
                        case .failure(let failure):
                            self.fail(failure.localizedDescription)
                        }
                    }
                }
            }
        }
        download = downloader
        downloader.start()
    }

    func cancel() { download?.cancel(); deltaJob?.cancel() }

    private func fail(_ message: String) {
        Log.write("更新失败：\(message)")
        error = message
        phase = .error
        try? FileManager.default.removeItem(at: Self.workFolder)
    }

    private static var workFolder: URL { AppConfig.directoryURL.appendingPathComponent("updates", isDirectory: true) }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// 后台线程：核对 → 挂载 DMG → 核对签名 → 拷到 App 旁边（.Kiteline-<版本>.app）→ 卸载。返回待换的新 App
    private func install(_ dmg: URL, release: Release) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: dmg.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if release.size > 0 && size != release.size { throw Failure(L("下载不完整，请重试")) }
        if !release.sha256.isEmpty {
            let digest = try SHA256.hash(data: Data(contentsOf: dmg, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            if digest.lowercased() != release.sha256.lowercased() { throw Failure(L("安装包校验失败，请重试")) }
        }
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw Failure(L("没有写入「%@」的权限，请手动安装", parent.path))
        }
        let mount = Self.workFolder.appendingPathComponent("mount", isDirectory: true)
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path, dmg.path]) == 0 else {
            throw Failure(L("无法打开安装包"))
        }
        defer { _ = Self.run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }) else { throw Failure(L("安装包里没有 Kiteline")) }
        // 新版本必须是同一个开发者签的（同一个 bundle id、团队号），不然不装
        let newBundle = Bundle(url: app)
        guard newBundle?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw Failure(L("安装包不是 Kiteline")) }
        if let team = teamID {
            guard Self.teamIdentifier(app) == team, Self.validSignature(app, team: team) else { throw Failure(L("安装包签名校验失败")) }
        }
        let target = parent.appendingPathComponent(".Kiteline-\(release.version).app", isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        guard Self.run("/usr/bin/ditto", [app.path, target.path]) == 0 else { throw Failure(L("拷贝新版本失败")) }
        return target
    }

    // MARK: 重启

    // MARK: 空闲时自动重启

    /// 装好了：自动更新的就开始等空闲（每分钟看一次）；离开 ready 就停
    private func phaseChanged() {
        if phase == .ready {
            readySince = Date()
            idleTimer?.invalidate()
            let every = Double(ProcessInfo.processInfo.environment["CCPULSE_UPDATE_IDLE_TICK"] ?? "") ?? 60
            idleTimer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in self?.tryIdleRestart() }
        } else {
            idleTimer?.invalidate()
            idleTimer = nil
            readySince = nil
            if waitingFor != "" { waitingFor = "" }
        }
    }

    /// 人离开电脑多久才算空闲（测试时 CCPULSE_UPDATE_IDLE 改短）
    static var idleNeeded: TimeInterval { Double(ProcessInfo.processInfo.environment["CCPULSE_UPDATE_IDLE"] ?? "") ?? 600 }
    /// 等了这么久还一直有会话在运行：不再等会话停下（正在运行的会话不受 Kiteline 重启影响，只是保守起见先等它）
    static let busyPatience: TimeInterval = 24 * 3600

    /// 现在不能自动重启的原因；nil = 可以
    func idleBlocker(now: Date = Date()) -> String? {
        guard phase == .ready, staged != nil else { return L("新版本还没有装好") }
        guard auto else { return L("自动更新已关闭") }
        if EditorAlerts.userIdle() < Self.idleNeeded { return L("电脑有人在用") }
        let model = KitelineModel.shared
        if model.waitingCount > 0 { return L("有会话在等待确认") }
        if model.busyCount > 0, now.timeIntervalSince(readySince ?? now) < Self.busyPatience { return L("有会话正在运行") }
        // 手机（iPhone / iPad、小程序）这 5 分钟里来过请求：多半正在看，别让它断线
        let recent = now.timeIntervalSince1970 * 1000 - 5 * 60_000
        if DeviceStore.shared.all.contains(where: { ($0.client?.hasPrefix("ios/") == true || $0.client == "miniprogram") && $0.lastSeen > recent }) {
            return L("手机正在查看")
        }
        return nil
    }

    private func tryIdleRestart() {
        let blocker = idleBlocker()
        if let blocker {
            if blocker != waitingFor {
                waitingFor = blocker
                Log.write("自动更新：新版本 \(release?.version ?? "") 已装好，等待空闲（\(blocker)）")
            }
            return
        }
        Log.write("自动更新：电脑空闲，重启换上新版本 \(release?.version ?? "")")
        restart(auto: true)
    }

    /// 立即重启：脚本等这份退出 → 旧版挪走、新版放到原位置 → 打开新版。
    /// auto：空闲时自动重启的，新版本不抢前台；原来主窗口没开着的就只待在菜单栏
    func restart(auto: Bool = false) {
        guard phase == .ready, staged != nil else { return }
        phase = .restarting
        Log.write("更新：重启以换上新版本 \(release?.version ?? "")")
        let windowOpen = MainWindowController.shared.window?.isVisible == true
        swap(relaunch: true, quiet: auto, background: auto && !windowOpen)
        installOnQuit = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    /// 退出时（applicationWillTerminate）：装好了但没点重启的，这时换上，下次打开就是新版本
    func installIfPendingOnQuit() {
        guard installOnQuit, phase == .ready, staged != nil else { return }
        Log.write("更新：退出时换上新版本 \(release?.version ?? "")")
        swap(relaunch: false)
    }

    private func swap(relaunch: Bool, quiet: Bool = false, background: Bool = false) {
        guard let staged else { return }
        let app = Bundle.main.bundleURL.path
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // 新打开的 App 会继承这个脚本的环境变量：自测脚本那个要去掉，不然新版本又把整套自测步骤跑一遍
        let script = """
        unset TARS_CAPTURE_STEPS
        pid=\(ProcessInfo.processInfo.processIdentifier)
        for i in $(seq 1 300); do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
        old="$(mktemp -d)/old.app"
        if mv \(quote(app)) "$old"; then
          if mv \(quote(staged.path)) \(quote(app)); then rm -rf "$(dirname "$old")"; else mv "$old" \(quote(app)); fi
        fi
        \(relaunch ? relaunchCommand(app, quote: quote, quiet: quiet, background: background) : "")
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// 重新打开：测试实例带上自己的环境变量（配置目录、不真发送……）、不抢前台，不然会以正式 App 的身份再起一份
    private func relaunchCommand(_ app: String, quote: (String) -> String, quiet: Bool, background: Bool) -> String {
        guard AppConfig.isolated else { return "open \(quiet ? "-g " : "")\(quote(app))\(background ? " --args --background" : "")" }
        let env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("CCPULSE_") }
            .map { "--env \(quote("\($0.key)=\($0.value)"))" }.sorted().joined(separator: " ")
        return "open -g -n \(quote(app)) \(env) --args --background"
    }

    // MARK: 签名、命令

    /// App 的签名团队号（Developer ID 才有；本机自签的开发版、没签名的是 nil）
    static func teamIdentifier(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 签名完整、是苹果签发给这个团队的证书
    static func validSignature(_ url: URL, team: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement) == errSecSuccess
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// 带进度的下载（URLSession 下载任务；进度每 0.2 秒报一次）
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    let url: URL
    let progress: (Int64) -> Void
    let done: (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var last = Date.distantPast

    init(url: URL, progress: @escaping (Int64) -> Void, done: @escaping (Result<URL, Error>) -> Void) {
        self.url = url
        self.progress = progress
        self.done = done
    }

    func start() {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        task = session.downloadTask(with: url)
        task?.resume()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if Date().timeIntervalSince(last) > 0.2 {
            last = Date()
            progress(totalBytesWritten)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 临时文件回调一结束就被删：先挪到自己的目录
        let target = AppConfig.directoryURL.appendingPathComponent("updates", isDirectory: true).appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(Updater.Failure(L("下载失败：服务器返回 %@", "\(http.statusCode)"))))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: target)
            progress(downloadTask.countOfBytesReceived)
            finish(.success(target))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private var finished = false

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        done(result)
    }
}

/// 差量更新（同 Windows / Linux 版 updater.py 的 _build_delta；清单格式见 tools/release/delta.py）：
/// 读新版本的文件清单（SHA-256 和 latest.json 里的对上才用）→ 本机这份 App 里有同样内容的文件（按 SHA-256 认）直接拷
/// （APFS 上是克隆，不占空间）→ 变了的文件有从本机某个文件出发的补丁就下补丁、用系统自带的 bspatch 打，没有就下整个文件（gzip）
/// → 每个文件都核对 SHA-256 → 核对整个 App 的签名是同一个开发者 → 放到 App 旁边待换（.Kiteline-<版本>.app，同整包安装）
final class DeltaBuilder {
    struct Cancelled: Error {}

    let delta: Updater.Delta
    let version: String
    let team: String?
    /// 本机这份 App（从这里找已有的文件）；新版本放在正在运行的 App 旁边
    let base: URL
    let work: URL
    let planned: (Int64) -> Void
    let progress: (Int64) -> Void
    private var cancelled = false
    private var received: Int64 = 0

    init(delta: Updater.Delta, version: String, team: String?, base: URL, work: URL, planned: @escaping (Int64) -> Void, progress: @escaping (Int64) -> Void) {
        self.delta = delta
        self.version = version
        self.team = team
        self.base = base
        self.work = work
        self.planned = planned
        self.progress = progress
    }

    func cancel() { cancelled = true }

    private struct Entry {
        var path: String
        var hash: String
        var size: Int64
        var packed: Int64
        var executable: Bool
        var patches: [(from: String, fromSize: Int64, packed: Int64)]
    }

    private enum Source { case local(URL), patch(String, URL, Int64), blob(Int64) }

    /// 后台线程跑；返回待换的新 App
    func run() throws -> URL {
        let manifestData = try fetch(delta.url)
        let digest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        guard digest == delta.sha256.lowercased() else { throw Updater.Failure("文件清单校验失败") }
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              (manifest["format"] as? Int) == 1, let rawFiles = manifest["files"] as? [[String: Any]] else {
            throw Updater.Failure("文件清单格式不对")
        }
        let entries = try rawFiles.map { item -> Entry in
            guard let path = item["p"] as? String, let hash = item["h"] as? String, Self.safe(path) else { throw Updater.Failure("文件清单里有异常路径") }
            let patches = (item["d"] as? [[String: Any]] ?? []).compactMap { d -> (String, Int64, Int64)? in
                guard let from = d["f"] as? String else { return nil }
                return (from, Int64(Digest.number(d["n"])), Int64(Digest.number(d["z"])))
            }
            return Entry(path: path, hash: hash.lowercased(), size: Int64(Digest.number(item["n"])), packed: Int64(Digest.number(item["z"])),
                         executable: Digest.number(item["x"]) != 0, patches: patches.map { (from: $0.0, fromSize: $0.1, packed: $0.2) })
        }
        let links = (manifest["links"] as? [[String: Any]] ?? []).compactMap { l -> (String, String)? in
            guard let p = l["p"] as? String, let t = l["t"] as? String else { return nil }
            return (p, t)
        }
        guard links.allSatisfy({ Self.safe($0.0) && !$0.1.hasPrefix("/") }) else { throw Updater.Failure("文件清单里有异常链接") }
        let dirs = (manifest["dirs"] as? [String] ?? []).filter(Self.safe)

        // 本机这份 App 里的文件：只算大小对得上的（新版本的文件、补丁的出发文件），按 SHA-256 建索引
        let current = base
        let sizes = Set(entries.map(\.size) + entries.flatMap { $0.patches.map(\.fromSize) })
        var local: [String: URL] = [:]
        if let walker = FileManager.default.enumerator(at: current, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
            for case let url as URL in walker {
                try checkCancelled()
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, sizes.contains(Int64(size)) else { continue }
                if let hash = try? Self.sha256(url), local[hash] == nil { local[hash] = url }
            }
        }

        // 每个文件从哪来；要下载的加起来就是进度条的总数
        var plan: [(Entry, Source)] = []
        var total: Int64 = 0
        for entry in entries {
            if let url = local[entry.hash] {
                plan.append((entry, .local(url)))
            } else if let patch = entry.patches.first(where: { local[$0.from] != nil }) {
                plan.append((entry, .patch(patch.from, local[patch.from]!, patch.packed)))
                total += patch.packed
            } else {
                plan.append((entry, .blob(entry.packed)))
                total += entry.packed
            }
        }
        planned(total)
        let downloads = plan.filter { if case .local = $0.1 { return false }; return true }.count
        Log.write("差量更新 \(version)：\(entries.count) 个文件，本机已有 \(entries.count - downloads) 个，要下载 \(downloads) 个、共 \(total) 字节")

        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw Updater.Failure("没有写入「\(parent.path)」的权限") }
        let target = parent.appendingPathComponent(".Kiteline-\(version).app", isDirectory: true)
        let building = parent.appendingPathComponent(".Kiteline-\(version).app.partial", isDirectory: true)
        try? FileManager.default.removeItem(at: building)
        defer { try? FileManager.default.removeItem(at: building) }
        let fm = FileManager.default
        try fm.createDirectory(at: building, withIntermediateDirectories: true)
        for dir in dirs { try fm.createDirectory(at: building.appendingPathComponent(dir), withIntermediateDirectories: true) }
        let base = delta.url.deletingLastPathComponent().deletingLastPathComponent()   // …/download/delta/
        for (entry, source) in plan {
            try checkCancelled()
            let out = building.appendingPathComponent(entry.path)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch source {
            case .local(let url):
                try fm.copyItem(at: url, to: out)
                // 拷过来的不带扩展属性（隔离标记之类）：和从 DMG 装的一样干净，签名严格校验也不会被它挡住
                Self.stripAttributes(out)
            case .patch(let from, let old, let packed):
                let patch = work.appendingPathComponent("patch-\(entry.hash)")
                try fetch(base.appendingPathComponent("patches/\(from)-\(entry.hash).bsdiff"), to: patch, expect: packed)
                guard Updater.run("/usr/bin/bspatch", [old.path, out.path, patch.path]) == 0 else { throw Updater.Failure("补丁打不上：\(entry.path)") }
                try? fm.removeItem(at: patch)
            case .blob(let packed):
                let blob = work.appendingPathComponent("blob-\(entry.hash).gz")
                try fetch(base.appendingPathComponent("blobs/\(entry.hash).gz"), to: blob, expect: packed)
                guard fm.createFile(atPath: out.path, contents: nil), let handle = FileHandle(forWritingAtPath: out.path) else { throw Updater.Failure("写不进 \(entry.path)") }
                let gunzip = Process()
                gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
                gunzip.arguments = ["-c", blob.path]
                gunzip.standardOutput = handle
                gunzip.standardError = FileHandle.nullDevice
                try gunzip.run()
                gunzip.waitUntilExit()
                try handle.close()
                try? fm.removeItem(at: blob)
                guard gunzip.terminationStatus == 0 else { throw Updater.Failure("解压失败：\(entry.path)") }
            }
            guard try Self.sha256(out) == entry.hash else { throw Updater.Failure("文件校验失败：\(entry.path)") }
            try fm.setAttributes([.posixPermissions: entry.executable ? 0o755 : 0o644], ofItemAtPath: out.path)
        }
        for (path, destination) in links {
            let out = building.appendingPathComponent(path)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: out.path, withDestinationPath: destination)
        }

        // 和整包安装一样：同一个 bundle id、同一个开发者签的，签名完整（任何一个文件不对都过不了）
        guard Bundle(url: building)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw Updater.Failure("拼出来的不是 Kiteline") }
        if let team {
            guard Updater.teamIdentifier(building) == team, Updater.validSignature(building, team: team) else { throw Updater.Failure("拼出来的新版本签名校验失败") }
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: building, to: target)
        return target
    }

    private func checkCancelled() throws { if cancelled { throw Cancelled() } }

    static func stripAttributes(_ url: URL) {
        let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return }
        var buffer = [CChar](repeating: 0, count: length)
        guard listxattr(url.path, &buffer, length, XATTR_NOFOLLOW) == length else { return }
        for name in buffer.split(separator: 0).map({ String(cString: Array($0) + [0]) }) {
            removexattr(url.path, name, XATTR_NOFOLLOW)
        }
    }

    /// 路径只能在 App 里面：不能是绝对路径、不能有 ..
    static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Kiteline/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") (mac; delta)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 小文件（清单）：读进内存
    private func fetch(_ url: URL) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(Updater.Failure("下载失败"))
        URLSession.shared.dataTask(with: request(url)) { data, response, error in
            if let error { result = .failure(error) }
            else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { result = .failure(Updater.Failure("服务器返回 \(code)：\(url.lastPathComponent)")) }
            else { result = .success(data ?? Data()) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }

    /// 补丁、文件块：下到 work 里，边下边报进度，核对大小
    private func fetch(_ url: URL, to file: URL, expect: Int64) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        let start = received
        let task = URLSession.shared.downloadTask(with: request(url)) { location, response, error in
            if let error { failure = error }
            else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { failure = Updater.Failure("服务器返回 \(code)：\(url.lastPathComponent)") }
            else if let location {
                try? FileManager.default.removeItem(at: file)
                do { try FileManager.default.moveItem(at: location, to: file) } catch { failure = error }
            }
            semaphore.signal()
        }
        let watch = task.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            guard let self else { return }
            self.progress(start + progress.completedUnitCount)
        }
        task.resume()
        while semaphore.wait(timeout: .now() + 0.3) == .timedOut {
            if cancelled { task.cancel() }
        }
        watch.invalidate()
        if cancelled { throw Cancelled() }
        if let failure { throw failure }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
        if expect > 0, size != expect { throw Updater.Failure("下载不完整：\(url.lastPathComponent)") }
        received = start + size
        progress(received)
    }
}
