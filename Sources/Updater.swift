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

        var notes: String { Lang.shared.isEnglish && !notesEn.isEmpty ? notesEn : notesZh }
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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: Release?
    @Published private(set) var received: Int64 = 0
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
    var progress: Double { guard let size = release?.size, size > 0 else { return 0 }; return min(1, Double(received) / Double(size)) }

    /// 能不能自动安装：官网下载版（Developer ID，有开发者团队号）；测试时 CCPULSE_UPDATE_ANY=1 放开
    private(set) lazy var teamID: String? = Self.teamIdentifier(Bundle.main.bundleURL)
    var supported: Bool { teamID != nil || ProcessInfo.processInfo.environment["CCPULSE_UPDATE_ANY"] == "1" }
    var reason: String { supported ? "" : L("此版本是本机编译的开发版，不会自动安装") }

    private var timer: Timer?
    private var download: Downloader?
    /// 装好待换的新版本（App 旁边的 .Kiteline-<版本>.app）
    private var staged: URL?
    private var installOnQuit = true

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
                let mac = (json["platforms"] as? [String: Any])?["mac"] as? [String: Any]
                if let mac, let version = mac["version"] as? String, let link = mac["url"] as? String, let url = URL(string: link),
                   Self.newer(version, than: self.current) {
                    var found = Release(version: version, url: url, size: Int64(Digest.number(mac["size"])), sha256: mac["sha256"] as? String ?? "",
                                        notesZh: mac["notes"] as? String ?? "", notesEn: mac["notesEn"] as? String ?? "")
                    found.behind = Set((mac["versions"] as? [String] ?? []).filter { Self.newer($0, than: self.current) && !Self.newer($0, than: version) }).count
                    let fresh = self.release?.version != version
                    if fresh { Log.write("发现新版本 \(version)（当前 \(self.current)）") } else { found.history = self.release?.history ?? [] }
                    self.release = found
                    self.error = ""
                    self.phase = .available
                    if fresh { self.fetchHistory(version) }
                    if !manual, self.due(Self.ownKey(version)) {
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
        let region = Locale.current.region?.identifier.lowercased() ?? "cn"
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
            "size": release?.size ?? 0, "received": received, "error": error, "page": downloadPage.absoluteString,
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

    func begin() {
        guard supported, let release, [.available, .error].contains(phase) else { return }
        phase = .downloading
        received = 0
        error = ""
        let folder = Self.workFolder
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    func cancel() { download?.cancel() }

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

    /// 立即重启：脚本等这份退出 → 旧版挪走、新版放到原位置 → 打开新版
    func restart() {
        guard phase == .ready, staged != nil else { return }
        phase = .restarting
        Log.write("更新：重启以换上新版本 \(release?.version ?? "")")
        swap(relaunch: true)
        installOnQuit = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    /// 退出时（applicationWillTerminate）：装好了但没点重启的，这时换上，下次打开就是新版本
    func installIfPendingOnQuit() {
        guard installOnQuit, phase == .ready, staged != nil else { return }
        Log.write("更新：退出时换上新版本 \(release?.version ?? "")")
        swap(relaunch: false)
    }

    private func swap(relaunch: Bool) {
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
        \(relaunch ? relaunchCommand(app, quote: quote) : "")
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
    private func relaunchCommand(_ app: String, quote: (String) -> String) -> String {
        guard AppConfig.isolated else { return "open \(quote(app))" }
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
