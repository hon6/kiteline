import AppKit
import CryptoKit
import SwiftUI
import KitelineKit

/// Agent 插件（规范见 docs/agent-plugins.md；同电脑端 desktop/kiteline/plugins.py）：官方插件索引、下载校验安装、
/// 自动更新、出错退回、出错报告。
///
/// - 插件装在 watcher 的数据目录（默认 ~/.ccpulse/plugins/<id>/：plugin.json、plugin.py、assets/），watcher 启动时加载；
///   装好、退回、开关变了都重连各来源。Remote-SSH 来源连接时把整个插件目录一起传过去（RemoteSession.syncPlugins）。
/// - 索引（官网 /plugins/index.json）由我们用 Ed25519 签名（index.json.sig），公钥内置在这里；签名不对整份不用；
///   下载的插件包按索引里的 sha256 核对。
/// - 偏好（关掉的、等 Kiteline 更新完再装的、不再询问的出错、出过错的版本）存在配置目录的 plugins.json。
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    private static let env = ProcessInfo.processInfo.environment
    static let publicKey = env["CCPULSE_PLUGIN_PUBKEY"] ?? "s4KGWh096KRYLEJjH8NBNISLLqQy4QJwhAT81/sbzu8="
    static let indexURL = URL(string: env["CCPULSE_PLUGIN_INDEX"] ?? "https://tars.betac.cn/plugins/index.json")!
    static let reportTo = "hon6@foxmail.com"
    /// 索引里 minApp 的键
    static let appKey = "mac"
    /// 自测截图用：兼容表全部展开；接入方式（默认不接的插件）展开
    static var expandAllForCapture = false
    static var expandOptInForCapture = false

    struct Prefs: Codable {
        var off: [String] = []
        /// 默认不接（optIn）、用户自己打开了的
        var on: [String] = []
        var pending: [String] = []
        var muted: [String] = []
        var bad: [String] = []
        /// 用户手动移除过（恢复内置版本）的：不再自动装回来，直到再手动装一次
        var held: [String] = []
        /// 做过的一次性迁移
        var flags: [String] = []

        init() {}

        /// 少了哪个键都按空的算（以后加键，旧文件照样读得出来）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            off = try c.decodeIfPresent([String].self, forKey: .off) ?? []
            on = try c.decodeIfPresent([String].self, forKey: .on) ?? []
            pending = try c.decodeIfPresent([String].self, forKey: .pending) ?? []
            muted = try c.decodeIfPresent([String].self, forKey: .muted) ?? []
            bad = try c.decodeIfPresent([String].self, forKey: .bad) ?? []
            held = try c.decodeIfPresent([String].self, forKey: .held) ?? []
            flags = try c.decodeIfPresent([String].self, forKey: .flags) ?? []
        }
    }

    /// 设置页上的一行
    struct Row: Identifiable {
        let id: String
        let name: String
        let version: String?
        let external: Bool
        let status: String           // ok / off / incompatible / retired / error / absent
        let error: String
        let wanted: String?
        let abilities: [String]
        /// 各平台、各形态能做到什么：{平台: {形态: {abilities, verified, note}}}
        let support: [String: Any]
        let forms: [(String, String)]
        let detected: Bool
        /// 装着那家 agent 的机器：local = 本机，其余是 Remote-SSH 来源的名字
        let detectedOn: [String]
        let enabled: Bool
        /// 不是那家 agent 开放的接入方式：默认不接，打开前给用户看的说明（optInEn 是插件给的英文）
        let optIn: String?
        let optInEn: String?
        let action: String?          // install / update / needsApp
        let target: [String: Any]?
        let pending: Bool
        let canRemove: Bool
        let autoInstall: Bool
        let held: Bool
        /// agent：一家 agent 的插件；skills：技能包（只有数据，watcher 照着给各家 agent 装技能，不在设置页列出）
        var kind = "agent"
    }

    struct PluginError: Identifiable {
        let key: String
        let plugin: String
        let name: String
        let version: String
        let source: String
        let place: String
        let error: String
        let trace: String
        let host: String
        var id: String { key }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var checking = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var problem = ""
    @Published private(set) var busy: [String: String] = [:]
    @Published private(set) var errors: [PluginError] = []

    private(set) var prefs: Prefs
    private var index: [[String: Any]] = []
    private var local: [[String: Any]] = []
    private var hostCaps: [String]?
    /// 插件 id → 装着那家 agent 的机器（local = 本机，其余是 Remote-SSH 来源的名字）
    private var whereFound: [String: [String]] = [:]
    /// 各台机器的 watcher 报来的插件（名称、称呼、标志），给手机的 agents 用
    private var reported: [[String: Any]] = []
    private let cardsLock = NSLock()
    private var cards: [[String: Any]] = []
    private var timer: Timer?

    private static var prefsURL: URL { AppConfig.directoryURL.appendingPathComponent("plugins.json") }
    private static var indexCacheURL: URL { AppConfig.directoryURL.appendingPathComponent("plugins-index.json") }

    /// 和 watcher 的 PLUGINS_DIR 同一个算法（本机 watcher 继承 App 的环境变量）
    static var pluginsDir: URL {
        if let dir = env["CCPULSE_PLUGINS_DIR"] { return URL(fileURLWithPath: dir) }
        let data = env["CCPULSE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ccpulse")
        return data.appendingPathComponent("plugins")
    }

    private init() {
        prefs = (try? JSONDecoder().decode(Prefs.self, from: Data(contentsOf: Self.prefsURL))) ?? Prefs()
        if let data = try? Data(contentsOf: Self.indexCacheURL),
           let cached = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            index = cached["plugins"] as? [[String: Any]] ?? []
        }
        updateCards()
        // 以前「通用」里有「为 OpenCode 安装 Kiteline 插件」开关，现在统一在插件页：关着的转成插件页里关掉 OpenCode（只转一次）
        if !prefs.flags.contains("opencode-switch") {
            prefs.flags.append("opencode-switch")
            if !AppState.shared.config.mobile.installOpenCodePlugin, !prefs.off.contains("opencode") { prefs.off.append("opencode") }
            savePrefs()
        }
    }

    /// 关掉的、自己打开了的（默认不接的）插件随 watcher 的环境变量带过去（本机和远端都是，见 AgentSkill.watcherEnvironment）
    var watcherEnvironment: [String: String] {
        var env: [String: String] = [:]
        if !prefs.off.isEmpty { env["CCPULSE_PLUGINS_OFF"] = prefs.off.sorted().joined(separator: ",") }
        if !prefs.on.isEmpty { env["CCPULSE_PLUGINS_ON"] = prefs.on.sorted().joined(separator: ",") }
        return env
    }

    private func savePrefs() {
        try? FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(prefs) { try? data.write(to: Self.prefsURL, options: .atomic) }
    }

    // MARK: 后台检查

    /// 启动 20 秒后查一次，之后每 6 小时；测试实例（另一个配置目录）不自动查，免得往正式的插件目录里装东西
    func start() {
        if AppConfig.isolated && Self.env["CCPULSE_PLUGIN_INDEX"] == nil { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(auto: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(auto: true) }
    }

    /// 查一次：拉索引、问本机 watcher；auto 时把能自动装的（在用插件的新版本、检测到 agent 的新插件、等更新完再装的）装上
    func check(auto: Bool = false) {
        guard !checking else { return }
        checking = true
        fetchIndex { [weak self] in
            self?.refreshLocal {
                guard let self else { return }
                self.checking = false
                self.checkedAt = Date()
                // 我们吊销了本机装着的版本：退回上一版本（没有就回到内置的），并记成坏版本
                for (id, version) in self.withdrawn() {
                    Log.write("插件 \(id) \(version) 已被吊销，退回")
                    self.rollback(id, badVersion: version)
                }
                self.rebuild()
                if auto {
                    let due = self.rows.filter { ["install", "update"].contains($0.action ?? "") && $0.enabled && $0.autoInstall }.map(\.id)
                    self.installAll(due)
                }
            }
        }
    }

    private func installAll(_ ids: [String], installed: Bool = false) {
        guard let first = ids.first else {
            if installed { reconnect() }
            return
        }
        install(first, reconnect: false, manual: false) { [weak self] error in
            self?.installAll(Array(ids.dropFirst()), installed: installed || error == nil)
        }
    }

    private func fetchIndex(_ done: @escaping () -> Void) {
        let sigURL = URL(string: Self.indexURL.absoluteString + ".sig")!
        Self.get(Self.indexURL) { data, status in
            if status == 404 {   // 官网还没发布插件索引：当作暂无可更新的插件，不算出错
                DispatchQueue.main.async { self.index = []; self.problem = ""; done() }
                return
            }
            Self.get(sigURL) { signature, _ in
                DispatchQueue.main.async {
                    defer { done() }
                    guard let data, let signature else { self.problem = "连不上插件服务器"; return }
                    guard Self.verify(data, signature: String(decoding: signature, as: UTF8.self)) else {
                        self.problem = "插件索引的签名不对，已忽略"
                        Log.write("插件索引签名不对，已忽略")
                        return
                    }
                    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let plugins = object["plugins"] as? [[String: Any]] else { self.problem = "插件索引格式不对"; return }
                    self.index = plugins
                    self.updateCards()
                    self.problem = ""
                    try? data.write(to: Self.indexCacheURL, options: .atomic)
                }
            }
        }
    }

    private static func get(_ url: URL, timeout: TimeInterval = 20, _ done: @escaping (Data?, Int) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Kiteline/\(AppVersion.app) (mac)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done((200..<300).contains(status) ? data : nil, status)
        }.resume()
    }

    static func verify(_ data: Data, signature: String, publicKey: String = PluginStore.publicKey) -> Bool {
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// 问每台在线机器（本机和 Remote-SSH 远端）的 watcher：插件的版本、状态、能力，那台机器上装没装各家 agent；
    /// 还没装的插件按索引里的检测规则问。版本、能力、中台能力以本机为准，「装在哪」合起来
    private func refreshLocal(_ done: @escaping () -> Void) {
        let sources = AppState.shared.liveSources
        guard !sources.isEmpty else { done(); return }
        let specs = Dictionary(index.compactMap { e in (e["id"] as? String).flatMap { id in e["detect"].map { (id, $0) } } },
                               uniquingKeysWith: { a, _ in a })
        let group = DispatchGroup()
        var replies: [String: [String: Any]] = [:]
        var found: [String: [String]] = [:]
        let lock = NSLock()
        for source in sources {
            let label = source.config.id == "local" ? "local" : source.config.name
            group.enter()
            source.request(["cmd": "plugins"], timeout: 15) { result in
                if case .success(let reply) = result {
                    lock.lock(); replies[source.config.id] = reply
                    for row in reply["plugins"] as? [[String: Any]] ?? [] {
                        if let id = row["id"] as? String, ((row["detect"] as? [String: Any])?["installed"] as? Bool) == true { found[id, default: []].append(label) }
                    }
                    lock.unlock()
                }
                guard !specs.isEmpty else { group.leave(); return }
                source.request(["cmd": "detect", "specs": specs], timeout: 10) { result in   // 旧版 watcher 不认，跳过
                    if case .success(let reply) = result {
                        lock.lock()
                        for (id, ok) in reply["found"] as? [String: Bool] ?? [:] where ok && !(found[id] ?? []).contains(label) { found[id, default: []].append(label) }
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            if let reply = replies["local"] ?? replies.values.first {
                self.local = reply["plugins"] as? [[String: Any]] ?? []
                self.hostCaps = reply["hostCaps"] as? [String]
            }
            if !replies.isEmpty { self.reported = replies.values.flatMap { $0["plugins"] as? [[String: Any]] ?? [] } }
            self.whereFound = found
            self.updateCards()
            done()
        }
    }

    /// 手机 /api/state 的 agents：各插件的 agent 名称、称呼、标志（手机内置表里没有的 agent 靠它画），任何线程都能读
    var agentCards: [[String: Any]] {
        cardsLock.lock(); defer { cardsLock.unlock() }
        return cards
    }

    private func updateCards() {
        var byId: [String: [String: Any]] = [:]
        var order: [String] = []
        for row in index + reported {   // watcher 报的（装着的版本）盖过索引里的
            guard let id = row["id"] as? String, let name = row["name"] as? String else { continue }
            var card: [String: Any] = ["id": id, "name": name]
            if let speaker = row["speaker"] as? String, !speaker.isEmpty { card["speaker"] = speaker }
            if let mark = row["mark"] { card["mark"] = mark }
            // 装着的版本要求的各端最低版本（watcher 报的才有）：手机版本低于 minApp.ios 时提示去 App Store 更新
            if row["versions"] == nil, let minimum = row["minApp"] as? [String: Any] { card["minApp"] = minimum }
            if byId[id] == nil { order.append(id) }
            byId[id] = card
        }
        cardsLock.lock(); cards = order.compactMap { byId[$0] }; cardsLock.unlock()
    }

    // MARK: 设置页的一行行

    static func versionParts(_ text: String?) -> [Int] {
        var parts = (text ?? "0").split(whereSeparator: { ".-+".contains($0) }).prefix(4)
            .map { Int($0.filter(\.isNumber)) ?? 0 }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        return parts
    }

    static func newer(_ a: String?, than b: String?) -> Bool {
        let x = versionParts(a), y = versionParts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func fits(_ version: [String: Any]) -> Bool {
        let needs = version["needs"] as? [String] ?? []
        if let caps = hostCaps, needs.contains(where: { !caps.contains($0) }) { return false }
        if let minimum = (version["minApp"] as? [String: Any])?[Self.appKey] as? String, Self.newer(minimum, than: AppVersion.app) { return false }
        return true
    }

    /// 索引里这个插件：最新版本、本机能装的最新版本（吊销的、出过错的不算）
    private func latest(_ entry: [String: Any]) -> (newest: [String: Any]?, usable: [String: Any]?) {
        let id = entry["id"] as? String ?? ""
        let versions = (entry["versions"] as? [[String: Any]] ?? [])
            .filter { ($0["revoked"] as? Bool) != true && !prefs.bad.contains("\(id)@\($0["version"] as? String ?? "")") }
            .sorted { Self.newer($0["version"] as? String, than: $1["version"] as? String) }
        return (versions.first, versions.first(where: fits))
    }

    private static func manifest(_ folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("plugin.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 本机装着、但在索引里被吊销的版本
    private func withdrawn() -> [(String, String)] {
        Self.installedIds.compactMap { id in
            guard let version = Self.manifest(Self.pluginsDir.appendingPathComponent(id))?["version"].map({ "\($0)" }),
                  let entry = index.first(where: { $0["id"] as? String == id }),
                  (entry["versions"] as? [[String: Any]] ?? []).contains(where: { ($0["revoked"] as? Bool) == true && "\($0["version"] ?? "")" == version })
            else { return nil }
            return (id, version)
        }
    }

    private static var installedIds: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: pluginsDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && manifest(pluginsDir.appendingPathComponent($0)) != nil }
    }

    /// 索引里给没装插件的 agent 写的简单检测：有这些目录 / 命令之一就算装了
    private static func detected(by spec: Any?) -> Bool {
        guard let spec = spec as? [String: Any] else { return false }
        if spec["always"] as? Bool == true { return true }   // 技能包：不看装没装哪家 agent，有新版就装
        let paths = (spec["paths"] as? [String] ?? []).map { ($0 as NSString).expandingTildeInPath }
        if paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        let dirs = ["/usr/local/bin", "/opt/homebrew/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.npm-global/bin"]
        return (spec["commands"] as? [String] ?? []).contains { command in dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(command)") } }
    }

    private func rebuild() {
        let localById = Dictionary(local.compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
        let indexById = Dictionary(index.compactMap { e in (e["id"] as? String).map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        let installed = Set(Self.installedIds)
        var ids = local.compactMap { $0["id"] as? String }
        ids += index.compactMap { $0["id"] as? String }.filter { !ids.contains($0) }
        rows = ids.map { id in
            let row = localById[id] ?? [:]
            let entry = indexById[id] ?? [:]
            let (newest, usable) = latest(entry)
            let current = row["version"] as? String ?? (installed.contains(id) ? Self.manifest(Self.pluginsDir.appendingPathComponent(id))?["version"] as? String : nil)
            let detect = row["detect"] as? [String: Any]
            var detectedOn = self.whereFound[id] ?? []
            if detectedOn.isEmpty, detect.map({ ($0["installed"] as? Bool) == true }) ?? Self.detected(by: entry["detect"]) { detectedOn = ["local"] }
            let found = !detectedOn.isEmpty
            var action: String?, target: [String: Any]?
            if let newest, current == nil || Self.newer(newest["version"] as? String, than: current) {
                if let usable, current == nil || Self.newer(usable["version"] as? String, than: current) {
                    action = current == nil ? "install" : "update"; target = usable
                } else {
                    action = "needsApp"; target = newest
                }
            }
            let forms = (detect?["forms"] as? [String: Any] ?? [:])
            let order = ["cli", "vscode", "desktop"]
            let optIn = row["optIn"] as? String ?? entry["optIn"] as? String
            return Row(id: id, name: row["name"] as? String ?? entry["name"] as? String ?? id, version: current,
                       external: (row["source"] as? String ?? (installed.contains(id) ? "external" : "")) == "external",
                       status: row["status"] as? String ?? (current == nil ? "absent" : "ok"),
                       error: row["error"] as? String ?? "", wanted: row["wanted"] as? String,
                       abilities: row["abilities"] as? [String] ?? [],
                       support: row["support"] as? [String: Any] ?? entry["support"] as? [String: Any] ?? [:],
                       forms: order.compactMap { key in forms[key].map { (key, $0 as? String ?? "") } },
                       detected: found, detectedOn: detectedOn,
                       enabled: !prefs.off.contains(id) && (optIn == nil || prefs.on.contains(id)),
                       optIn: optIn, optInEn: row["optInEn"] as? String ?? entry["optInEn"] as? String, action: action, target: target,
                       pending: prefs.pending.contains(id), canRemove: installed.contains(id),
                       autoInstall: (current != nil || found || prefs.pending.contains(id)) && !prefs.held.contains(id),
                       held: prefs.held.contains(id), kind: entry["kind"] as? String ?? "agent")
        }
        .sorted { ($0.detected ? 0 : 1, $0.name.lowercased()) < ($1.detected ? 0 : 1, $1.name.lowercased()) }
    }

    /// 插件变了：重连各来源（watcher 重启才载入插件），过几秒再问一遍状态，设置页上的版本、能力、装在哪跟着更新
    private func reconnect() {
        AppState.shared.reconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.refreshLocal { self.rebuild() } }
    }

    // MARK: 装、退、开关

    /// 装索引里本机能用的最新版本：下载 → 核对 sha256 → 解到临时目录、核对路径和清单 → 换上（旧的留一份在 .previous 退回用）
    /// manual：用户在插件页点的（同时取消「手动移除过」）；自动更新传 false
    func install(_ id: String, reconnect: Bool = true, manual: Bool = true, done: ((String?) -> Void)? = nil) {
        guard busy[id] == nil else { done?("正在处理"); return }
        guard let entry = index.first(where: { $0["id"] as? String == id }), let version = latest(entry).usable,
              let path = version["url"] as? String, let url = URL(string: path, relativeTo: Self.indexURL) else {
            done?("需要先更新 Kiteline"); return
        }
        if let installed = Self.manifest(Self.pluginsDir.appendingPathComponent(id))?["version"], "\(installed)" == "\(version["version"] ?? "")" {
            done?(nil); return   // 已经是这个版本
        }
        busy[id] = "installing"
        rebuild()
        Self.get(url, timeout: 60) { data, _ in
            var failure: String?
            if let data {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if digest != (version["sha256"] as? String ?? "").lowercased() {
                    failure = "下载的插件包校验不通过"
                } else {
                    failure = Self.unpack(id: id, version: version["version"] as? String ?? "", data: data)
                }
            } else {
                failure = "下载插件失败"
            }
            DispatchQueue.main.async {
                self.busy[id] = nil
                if let failure {
                    Log.write("安装插件 \(id) 失败：\(failure)")
                } else {
                    Log.write("已安装插件 \(id) \(version["version"] as? String ?? "")")
                    let before = (self.prefs.pending.count, self.prefs.held.count)
                    self.prefs.pending.removeAll { $0 == id }
                    if manual { self.prefs.held.removeAll { $0 == id } }
                    if (self.prefs.pending.count, self.prefs.held.count) != before { self.savePrefs() }
                    if reconnect { self.reconnect() }
                }
                self.rebuild()
                done?(failure)
            }
        }
    }

    /// 解开插件包换上；出错返回原因
    private static func unpack(id: String, version: String, data: Data) -> String? {
        let fm = FileManager.default
        let root = pluginsDir
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".new-\(id)-\(UUID().uuidString.prefix(8))")
        let zip = fm.temporaryDirectory.appendingPathComponent("kl-plugin-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: staging); try? fm.removeItem(at: zip) }
        do { try data.write(to: zip) } catch { return "写临时文件失败" }
        // 先看包里的路径：绝对路径、带 .. 的一律不装（解压前就拦住，不靠解压工具的处理）
        let names = run("/usr/bin/zipinfo", ["-1", zip.path])?.split(separator: "\n").map(String.init) ?? []
        if names.isEmpty { return "插件包打不开" }
        if names.contains(where: { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }) { return "插件包里有不安全的路径" }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path]) != nil else { return "解压插件包失败" }
        let links = fm.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey])?.contains { item in
            ((item as? URL).flatMap { try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink }) == true
        } ?? false
        if links { return "插件包里有链接文件" }
        // agent 插件要有 plugin.py；技能包（kind: skills）只有数据 skills.json
        let body = manifest(staging)?["kind"] as? String == "skills" ? "skills.json" : "plugin.py"
        guard let manifest = manifest(staging), manifest["id"] as? String == id, "\(manifest["version"] ?? "")" == version,
              fm.fileExists(atPath: staging.appendingPathComponent(body).path) else { return "插件包内容和索引对不上" }
        let current = root.appendingPathComponent(id)
        let previous = root.appendingPathComponent(".previous").appendingPathComponent(id)
        do {
            if fm.fileExists(atPath: current.path) {
                try? fm.removeItem(at: previous)
                try fm.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: current, to: previous)
            }
            try fm.moveItem(at: staging, to: current)
        } catch {
            return "换上新版本失败：\(error.localizedDescription)"
        }
        return nil
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], input: Data? = nil, environment: [String: String]? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// 退回上一版本；没有上一版本就删掉（用内置的）。badVersion 记下来，以后不再自动装它
    func rollback(_ id: String, badVersion: String? = nil) {
        let fm = FileManager.default
        let current = Self.pluginsDir.appendingPathComponent(id)
        let previous = Self.pluginsDir.appendingPathComponent(".previous").appendingPathComponent(id)
        if let badVersion, !prefs.bad.contains("\(id)@\(badVersion)") { prefs.bad.append("\(id)@\(badVersion)"); savePrefs() }
        try? fm.removeItem(at: current)
        let kept = Self.manifest(previous)?["version"].map { "\($0)" } ?? ""
        if fm.fileExists(atPath: previous.path), !prefs.bad.contains("\(id)@\(kept)") {
            try? fm.moveItem(at: previous, to: current)
            Log.write("插件 \(id) 已退回上一版本 \(kept)")
        } else {
            try? fm.removeItem(at: previous)   // 上一版本也是坏的（或没有）：回到内置的
            Log.write("插件 \(id) 已删除，改用内置版本")
        }
        reconnect()
        rebuild()
    }

    /// 删掉下载的版本，回到内置的（设置页「恢复内置版本」）；记下来，自动更新不再把它装回来
    func remove(_ id: String) {
        if !prefs.held.contains(id) { prefs.held.append(id); savePrefs() }
        try? FileManager.default.removeItem(at: Self.pluginsDir.appendingPathComponent(id))
        try? FileManager.default.removeItem(at: Self.pluginsDir.appendingPathComponent(".previous").appendingPathComponent(id))
        reconnect()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        prefs.off.removeAll { $0 == id }
        prefs.on.removeAll { $0 == id }
        // 关掉的都记；打开的只记默认不接的（其余的不在 off 里就是开着）
        if !enabled { prefs.off.append(id) } else if rows.first(where: { $0.id == id })?.optIn != nil { prefs.on.append(id) }
        savePrefs()
        Log.write("插件 \(id) 已\(enabled ? "启用" : "关闭")")
        rebuild()
        if id == "opencode", enabled, !AppState.shared.config.mobile.installOpenCodePlugin {
            // 插件页打开 OpenCode = 也要往 OpenCode 里装桥接插件（旧的「通用」开关跟着打开；apply 会重连各来源）
            var next = AppState.shared.config
            next.mobile.installOpenCodePlugin = true
            AppState.shared.apply(newConfig: next)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.refreshLocal { self.rebuild() } }
        } else {
            reconnect()
        }
    }

    /// 插件要的能力本机 Kiteline 还没有：记下来，打开检查更新；更新完重启后自动装上
    func updateThenInstall(_ id: String) {
        if !prefs.pending.contains(id) { prefs.pending.append(id); savePrefs() }
        rebuild()
        Updater.shared.check(manual: true)
        UpdateWindowController.shared.show()
    }

    // MARK: 出错

    /// watcher 报来的：plugin_error 弹窗问要不要发报告（同一个错只问一次）；plugin_retired 把本机的文件退回上一版本
    func handle(_ event: WatcherEvent, from source: SourceConnection) {
        let raw = event.raw
        let id = raw["id"] as? String ?? ""
        if event.kind == "plugin_retired" {
            if source.config.id == "local", FileManager.default.fileExists(atPath: Self.pluginsDir.appendingPathComponent(id).path) {
                rollback(id, badVersion: raw["version"] as? String)
            }
            return
        }
        let version = raw["version"] as? String ?? ""
        let message = raw["error"] as? String ?? ""
        let key = "\(id)@\(version):\(message.prefix(80))"
        guard !prefs.muted.contains(key), !errors.contains(where: { $0.key == key }) else { return }
        let error = PluginError(key: key, plugin: id, name: raw["name"] as? String ?? id, version: version,
                                source: raw["source"] as? String ?? "", place: raw["where"] as? String ?? "", error: message,
                                trace: raw["trace"] as? String ?? "", host: source.config.name)
        errors = Array((errors + [error]).suffix(20))
        Log.write("插件 \(id) 出错：\(message)")
        PluginErrorPanel.shared.show(error)
    }

    func mute(_ error: PluginError) {
        if !prefs.muted.contains(error.key) { prefs.muted = Array((prefs.muted + [error.key]).suffix(200)); savePrefs() }
        dismiss(error)
    }

    func dismiss(_ error: PluginError) {
        errors.removeAll { $0.key == error.key }
    }

    /// 出错报告：用用户自己的邮件程序发（系统「新建邮件」，内容先给用户看），正文同时复制一份。不含对话内容，不写我们的服务器
    func report(_ error: PluginError?, plugin id: String? = nil) {
        let row = rows.first { $0.id == (error?.plugin ?? id) }
        let name = row?.name ?? error?.name ?? id ?? ""
        let version = error?.version ?? row?.version ?? ""
        let forms = row?.forms.map { $0.1.isEmpty ? $0.0 : "\($0.0) \($0.1)" }.joined(separator: ", ") ?? ""
        let subject = "Kiteline 插件出错：\(name) \(version)"
        let body = """
        插件：\(name) \(version)（\(error?.source ?? (row?.external == true ? "external" : "builtin"))）
        Agent：\(row?.detected == true ? "已安装 \(forms)" : "未检测到")
        Kiteline：Mac \(AppVersion.app)（macOS \(ProcessInfo.processInfo.operatingSystemVersionString)），watcher \(AppVersion.watcherScriptVersion)
        出错位置：\(error?.place ?? row?.status ?? "")
        出错信息：\(error?.error ?? row?.error ?? "")

        \(String((error?.trace ?? "").suffix(1500)))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(subject + "\n\n" + body, forType: .string)
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) {
            service.recipients = [Self.reportTo]
            service.subject = subject
            service.perform(withItems: [body])
        } else {
            var parts = URLComponents()
            parts.scheme = "mailto"
            parts.path = Self.reportTo
            parts.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            if let url = parts.url { NSWorkspace.shared.open(url) }
        }
    }

    /// 能力 → 读 / 写 / 执行的说法（设置页、兼容表）
    static func levels(_ abilities: [String]) -> String {
        let read = abilities.contains("view"), write = abilities.contains("reply")
        let execute = abilities.contains { ["approve", "answer", "interrupt"].contains($0) }
        if read && !write && !execute { return L("只读") }
        return [read ? L("读") : nil, write ? L("写") : nil, execute ? L("执行") : nil].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: 远端同步

    /// 整个插件目录打成 tar.gz（远端部署用）→ (字节, 指纹)；没有插件时字节是空的、指纹是 none
    static func bundle() -> (Data, String) {
        let names = installedIds.sorted()
        guard !names.isEmpty else { return (Data(), "none") }
        var hasher = SHA256()
        for name in names {
            let base = pluginsDir.appendingPathComponent(name)
            let files = (FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
                .filter { !$0.path.contains("/__pycache__") && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) == true }
                .sorted { $0.path < $1.path }
            for file in files {
                hasher.update(data: Data((name + String(file.path.dropFirst(base.path.count))).utf8) + Data([0]))
                hasher.update(data: (try? Data(contentsOf: file)) ?? Data())
            }
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)
        // COPYFILE_DISABLE：别把扩展属性打成「._」文件带过去
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", "-", "--exclude", "__pycache__", "-C", pluginsDir.path] + names
        process.environment = ["COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (Data(), "none") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, String(fingerprint))
    }

    /// 远端：本机同步过去的插件单独放一个目录（远端自己也装了 Kiteline 时，它管的 ~/.ccpulse/plugins 不受影响），
    /// 经 SSH 拉起的远端 watcher 用这个环境变量去读
    static let remoteDirEnvironment = "CCPULSE_PLUGINS_DIR=\"$HOME/.ccpulse/synced-plugins\""
    static let remoteCheckCommand = "cat ~/.ccpulse/synced-plugins/.sync 2>/dev/null || echo none"

    /// 远端解包（同电脑端 plugins.REMOTE_UNPACK）：标准输入是 base64 的 tar.gz，换掉 ~/.ccpulse/synced-plugins，写下指纹
    static func remoteUnpackCommand(python: String, fingerprint: String) -> String {
        let script = """
        import base64, io, os, shutil, sys, tarfile
        root = os.path.join(os.path.expanduser("~"), ".ccpulse", "synced-plugins")
        data = base64.b64decode(sys.stdin.read())
        fresh = root + ".new"
        shutil.rmtree(fresh, ignore_errors=True)
        os.makedirs(fresh)
        if data:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
                for member in tar.getmembers():
                    target = os.path.realpath(os.path.join(fresh, member.name))
                    if not target.startswith(os.path.realpath(fresh) + os.sep) or not (member.isfile() or member.isdir()):
                        raise SystemExit("bad member %s" % member.name)
                tar.extractall(fresh)
        shutil.rmtree(root, ignore_errors=True)
        os.rename(fresh, root)
        open(os.path.join(root, ".sync"), "w").write(sys.argv[1])
        print("PLUGINS_OK")
        """
        return "\(python) -c \"import base64;exec(base64.b64decode('\(Data(script.utf8).base64EncodedString())'))\" \(fingerprint)"
    }
}

/// 插件出错的弹窗（同电脑端 PluginReport.Ask）：右上角一张不抢焦点的小面板（Kiteline 不切到前台，免得把 VS Code 挤到后台，
/// 手机发的消息就不回车了），问要不要发报告。一次一张，后面的排队
final class PluginErrorPanel {
    static let shared = PluginErrorPanel()
    private var panel: NSPanel?
    private var queue: [PluginStore.PluginError] = []

    /// 自测截图用：弹窗内容离屏画出来，不上屏
    static func captureView() -> NSView {
        let sample = PluginStore.PluginError(key: "k", plugin: "codex", name: "Codex", version: "1.0.3", source: "external", place: "sessions",
                                             error: "ValueError: thread/status 的格式变了", trace: "", host: L("本机"))
        let view = NSHostingView(rootView: PluginErrorCard(error: sample, close: {}).tarsLook())
        view.frame.size = view.fittingSize
        return view
    }

    func show(_ error: PluginStore.PluginError) {
        queue.append(error)
        if panel == nil { next() }
    }

    private func next() {
        panel?.orderOut(nil)
        panel = nil
        guard !queue.isEmpty else { return }
        let error = queue.removeFirst()
        let close: () -> Void = { [weak self] in self?.next() }
        let hosting = NSHostingView(rootView: PluginErrorCard(error: error, close: close).tarsLook())
        hosting.frame.size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - panel.frame.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct PluginErrorCard: View {
    let error: PluginStore.PluginError
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentGlyph(error.plugin, size: 16)
                Text(L("「%@」插件出错", error.name)).font(.app(size: 14, weight: .semibold))
            }
            Text(error.error).font(.app(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("来自 %@ · 插件 %@", error.host, error.version)).font(.app(size: 11.5)).foregroundStyle(.tertiary)
            Text("可以把出错信息发给我们，帮助尽快修复。报告只包含插件和 agent 的版本、系统和出错位置，不含对话内容；会用你自己的邮件程序发送，发送前可以查看。")
                .font(.app(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("不再询问") { PluginStore.shared.mute(error); close() }.tarsButton()
                Button("暂不") { PluginStore.shared.dismiss(error); close() }.tarsButton()
                Spacer()
                Button("发送报告…") { PluginStore.shared.report(error); PluginStore.shared.dismiss(error); close() }
                    .tarsButton(prominent: true)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 设置 → 插件：我们做好的 Agent 插件，每家一行——标志、名字和版本、本机的 agent、能做什么、状态；右边操作按钮和开关。
/// 检测到本机装了对应的 agent 自动启用，插件有新版本自动更新：这一页主要是看状态、手动开关
struct PluginsPane: View {
    @ObservedObject var store = PluginStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("每个插件把一家编程 agent 接进 Kiteline，在手机和电脑上查看它的会话、回复和审批。检测到本机装了对应的 agent 会自动启用（标明需手动开启的除外），插件有新版本时自动更新。")
                .font(.app(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 0) {
                    // 技能包不是 agent，不列出来
                    let shown = store.rows.filter { $0.kind != "skills" }
                    ForEach(shown) { row in
                        PluginRowView(row: row, busy: store.busy[row.id] != nil)
                        if row.id != shown.last?.id { Divider().padding(.leading, 46) }
                    }
                    if shown.isEmpty {
                        Text(store.checking ? L("正在读取插件…") : L("本机 Kiteline 还没连上，稍后再看"))
                            .font(.app(size: 12)).foregroundStyle(.secondary).padding(12)
                    }
                }
                .tarsCard(padding: 6)
            }
            HStack {
                Text(note).font(.app(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button(store.checking ? L("正在检查…") : L("检查更新")) { store.check() }
                    .tarsButton().disabled(store.checking)
            }
            Text("兼容情况里，读：查看会话和对话记录；写：发消息、插话；执行：审批命令、回答提问、中断；✓ 表示已在该平台实测，「无」表示那家 agent 在该平台没有这种形态。")
                .font(.app(size: 11.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("插件由 Kiteline 官方提供并签名，只安装校验通过的版本。新版本出错时会自动退回上一个能用的版本，并询问是否发送出错报告。")
                .font(.app(size: 11.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: SettingsWindowController.width, height: 440, alignment: .top)
        .onAppear { store.check() }
    }

    private var note: String {
        if !store.problem.isEmpty { return L(store.problem) }
        guard let at = store.checkedAt else { return L("尚未检查更新") }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return L("上次检查：%@", formatter.string(from: at))
    }
}

private struct PluginRowView: View {
    let row: PluginStore.Row
    let busy: Bool
    @ObservedObject private var store = PluginStore.shared
    @State private var expanded = PluginStore.expandAllForCapture
    @State private var showOptIn = PluginStore.expandAllForCapture || PluginStore.expandOptInForCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line.opacity(dimmed ? 0.55 : 1)
            // 接入方式、兼容表放在整行下面、占满宽度（和文字左对齐），不跟右边的按钮挤。接入方式是开启前要读的，关着也不调暗
            if showOptIn, let text = optInText {
                Text(verbatim: text).font(.app(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .padding(.leading, 40)
            }
            if expanded, !row.support.isEmpty { SupportGrid(support: row.support).padding(.leading, 40).opacity(dimmed ? 0.55 : 1) }
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
    }

    private var dimmed: Bool { row.version != nil && !row.enabled }

    private var line: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentGlyph(row.id, size: 16)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.app(size: 13, weight: .semibold))
                    if let version = row.version {
                        Text(row.external ? version : L("%@（内置）", version)).font(.app(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Text(agentLine).font(.app(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if row.version != nil, !abilities.isEmpty {
                    Text(abilities).font(.app(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let status {
                    Text(status.0).font(.app(size: 11.5))
                        .foregroundStyle(status.1 ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if optInText != nil || !row.support.isEmpty {
                    HStack(spacing: 14) {
                        if optInText != nil { disclosure("接入方式", open: showOptIn) { showOptIn.toggle() } }
                        if !row.support.isEmpty { disclosure("各平台兼容情况", open: expanded) { expanded.toggle() } }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if busy {
                    Text("正在安装…").font(.app(size: 12)).foregroundStyle(.secondary)
                } else if row.action == "install" || row.action == "update" {
                    Button(row.action == "install" ? L("安装") : L("更新到 %@", row.target?["version"] as? String ?? "")) { store.install(row.id) }
                        .tarsButton()
                } else if row.action == "needsApp", !row.pending {
                    Button("更新并安装") { store.updateThenInstall(row.id) }.tarsButton(prominent: true)
                }
                if row.status == "error" || row.status == "retired" {
                    Button("报告问题") { store.report(nil, plugin: row.id) }.tarsButton()
                }
                if row.canRemove {
                    Menu {
                        Button("恢复内置版本") { store.remove(row.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.automatic)   // 菜单里的项别套设置窗口根上的 LookButtonStyle
                        .fixedSize()
                }
                if row.version != nil {
                    Toggle("", isOn: Binding(get: { row.enabled }, set: { on in
                        // 默认不接的：打开前先说明接入方式，用户确认了才开；取消了让开关弹回去
                        if on, let text = optInText, !confirmOptIn(text) { store.objectWillChange.send(); return }
                        store.setEnabled(row.id, on)
                    }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .help(row.enabled ? L("关闭后不再接入这家 agent，并删除装进它里面的 Kiteline 组件") : L("启用"))
                }
            }
            .padding(.top, 2)
        }
    }

    private func disclosure(_ title: LocalizedStringKey, open: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
            }
            .font(.app(size: 11)).foregroundStyle(.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 默认不接的插件的接入说明：英文界面用插件给的英文，没给就查表
    private var optInText: String? {
        guard let text = row.optIn else { return nil }
        return Lang.shared.isEnglish ? (row.optInEn ?? ServerLang.ui(text)) : text
    }

    private func confirmOptIn(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("开启「%@」接入？", row.name)
        alert.informativeText = text
        alert.addButton(withTitle: L("开启"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var agentLine: String {
        if !row.detected { return L("本机未检测到 %@", row.name) }
        let others = row.detectedOn.filter { $0 != "local" }.joined(separator: L("、"))
        if !row.detectedOn.isEmpty, !row.detectedOn.contains("local") { return L("%@ 上已安装 %@", others, row.name) }
        let titles = ["cli": L("命令行"), "vscode": L("VS Code 扩展"), "desktop": L("桌面版")]
        let parts = row.forms.map { key, version in [titles[key] ?? key, version].filter { !$0.isEmpty }.joined(separator: " ") }
        let here = parts.isEmpty ? L("本机已安装 %@", row.name) : L("本机已安装：%@", parts.joined(separator: L("、")))
        return others.isEmpty ? here : here + L("；%@ 上也有", others)
    }

    private var abilities: String {
        if row.abilities == ["view"] { return L("只读：回复和确认需在 %@ 中操作", row.name) }
        return row.abilities.isEmpty ? "" : L("能做到：%@", PluginStore.levels(row.abilities))
    }

    private var status: (String, Bool)? {
        let wanted = row.wanted ?? row.target?["version"] as? String ?? ""
        switch row.status {
        case "retired": return (L("新版本 %@ 出错，已退回上一个能用的版本", wanted), true)
        case "error": return (L("插件加载失败：%@", row.error), true)
        case "incompatible":
            return (row.version == nil ? L("需要更新 Kiteline 才能使用") : L("新版本 %@ 需要更新 Kiteline，暂用当前版本", wanted), false)
        default: break
        }
        if row.optIn != nil, !row.enabled, row.version != nil { return (L("需手动开启：开启前请先了解接入方式"), false) }
        if row.pending { return (L("Kiteline 更新完成后会自动安装"), false) }
        if row.held, row.action != nil { return (L("已关闭自动安装：之前手动移除过此插件，需要时可手动安装"), false) }
        switch row.action {
        case "update": return (L("有新版本 %@", row.target?["version"] as? String ?? ""), false)
        case "needsApp":
            let minimum = (row.target?["minApp"] as? [String: Any])?[PluginStore.appKey] as? String ?? ""
            return (L("新版本 %@ 需要 Kiteline %@ 或更新版本", row.target?["version"] as? String ?? "", minimum), false)
        default: return nil
        }
    }
}

/// 兼容表：行是形态（命令行 / VS Code 扩展 / 桌面版），列是平台（Mac / Windows / Linux，本机那一列加粗）；
/// 每格写读 / 写 / 执行或只读，✓ 是我们在那个平台实测过，「无」是那家 agent 在这个平台没有这个形态
private struct SupportGrid: View {
    let support: [String: Any]
    private static let platforms = [("mac", "Mac"), ("windows", "Windows"), ("linux", "Linux")]
    private static let forms = [("cli", "命令行"), ("vscode", "VS Code 扩展"), ("desktop", "桌面版")]

    var body: some View {
        let forms = Self.forms.filter { form in Self.platforms.contains { cell($0.0, form.0) != nil } }
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text(verbatim: "")
                    ForEach(Self.platforms, id: \.0) { platform in
                        Text(verbatim: platform.1).font(.app(size: 11, weight: platform.0 == "mac" ? .semibold : .regular))
                            .foregroundStyle(platform.0 == "mac" ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    }
                }
                ForEach(forms, id: \.0) { form in
                    GridRow {
                        Text(L(form.1)).font(.app(size: 11)).foregroundStyle(.secondary)
                        ForEach(Self.platforms, id: \.0) { platform in label(cell(platform.0, form.0)) }
                    }
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func cell(_ platform: String, _ form: String) -> [String: Any]? {
        (support[platform] as? [String: Any])?[form] as? [String: Any]
    }

    @ViewBuilder
    private func label(_ cell: [String: Any]?) -> some View {
        let abilities = cell?["abilities"] as? [String] ?? []
        if cell == nil {
            Text(verbatim: "—").font(.app(size: 11)).foregroundStyle(.tertiary)
        } else if abilities.isEmpty {
            Text("无").font(.app(size: 11)).foregroundStyle(.tertiary).help(L(cell?["note"] as? String ?? ""))
        } else {
            Text(verbatim: PluginStore.levels(abilities) + ((cell?["verified"] as? Bool) == true ? " ✓" : ""))
                .font(.app(size: 11)).foregroundStyle(.primary)
                .help((cell?["verified"] as? Bool) == true ? L("已实测") : L("未实测"))
        }
    }
}
