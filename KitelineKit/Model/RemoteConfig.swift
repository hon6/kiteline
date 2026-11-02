#if !KITELINE_MAC
import SwiftUI

// 远程配置：不发版本就能改的几样——功能的紧急开关、首页公告、升级提示、文案更正。
// 服务器上的 https://tars.betac.cn/app/config.json（relay/app-config.sh 发布，字段说明见 relay/app-config/README.md）。
//
// 全是数据、不是代码：开关只能关掉已经过审的功能，公告和文案是字，升级提示指向 App Store（App Store 审核指南 2.5.2、2.3.1）。
// 取到的配置解析通过才存进 Application Support/remote-config.json（不像 Caches 会被系统清掉），启动时先读它：
// 服务器连不上、回了错误码、内容坏了，都接着用上次存下的；从来没取到过就是代码里的默认值（功能全开、没有公告、文案不改）。

// MARK: - 配置

/// 能远程关掉的功能。加新的：这里加一个 case，用的地方判断 RemoteConfig.shared.isOn(.xxx)，README 的表里补一行
enum RemoteFeature: String, CaseIterable {
    /// 输入栏的语音输入（按住说话）
    case voice
    /// 首页「有 N 项事项需要你处理」提示条
    case todoStrip
    /// 首页顶上飞的纸鸢
    case homeKite
    /// 首页会话之间传消息时飞的纸鸢、风筝线
    case peerFlights
    /// 和 Apple Watch 连接（下次启动 App 生效）
    case watch
}

struct AppConfig: Decodable, Equatable {
    /// 功能开关：RemoteFeature 的名字 → 规则；没写的功能开着
    var features: [String: FeatureRule] = [:]
    var notices: [AppNotice] = []
    var update: UpdateInfo?
    /// 文案更正：zh / en → 中文原文 → 改正后的字（见 Lang.setPatches）
    var strings: [String: [String: Lang.Patch]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        // 整份不是 JSON 对象（比如服务器回了个网页）才算坏；某一节、某一条写错只丢那一节 / 那一条
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = ((try? container.decode([String: Lossy<FeatureRule>].self, forKey: .features)) ?? [:]).compactMapValues(\.value)
        notices = ((try? container.decode([Lossy<AppNotice>].self, forKey: .notices)) ?? []).compactMap(\.value)
        update = try? container.decodeIfPresent(UpdateInfo.self, forKey: .update)
        strings = ((try? container.decode([String: [String: Lossy<Lang.Patch>]].self, forKey: .strings)) ?? [:])
            .mapValues { $0.compactMapValues(\.value) }
    }

    private enum CodingKeys: String, CodingKey { case features, notices, update, strings }
}

/// 解析不了的那一条当作没写
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// 一个功能的开关：写 true / false，或者 {"enabled": false, "maxVersion": "1.1"} 只管这几个版本（别的版本照常开着）
struct FeatureRule: Decodable, Equatable {
    var enabled: Bool
    var versions = VersionRange()

    init(from decoder: Decoder) throws {
        if let flag = try? decoder.singleValueContainer().decode(Bool.self) {
            enabled = flag
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        versions = try VersionRange(from: decoder)
    }

    private enum CodingKeys: String, CodingKey { case enabled }
}

/// 只对哪些版本的 App 生效（两头都含）；不写 = 所有版本
struct VersionRange: Decodable, Equatable {
    var minVersion: VersionNumber?
    var maxVersion: VersionNumber?

    func contains(_ version: VersionNumber) -> Bool {
        (minVersion.map { $0 <= version } ?? true) && (maxVersion.map { version <= $0 } ?? true)
    }
}

/// 版本号「1.2」「1.10.3」：一段一段比数字（1.10 比 1.9 新），少的段当 0（1.1 = 1.1.0）
struct VersionNumber: Decodable, Comparable, CustomStringConvertible {
    let parts: [Int]
    let description: String

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...4).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
        description = text
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = VersionNumber(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "版本号写成 1.2 或 1.2.3：\(text)"))
        }
        self = version
    }

    static func < (a: VersionNumber, b: VersionNumber) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : 0, y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: VersionNumber, b: VersionNumber) -> Bool { !(a < b) && !(b < a) }
}

/// 文字：写一个字符串，或者 {"zh": "…", "en": "…"} 按 App 的界面语言挑
struct RemoteText: Decodable, Equatable {
    let zh: String?
    let en: String?

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            zh = single
            en = single
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zh = try container.decodeIfPresent(String.self, forKey: .zh)
        en = try container.decodeIfPresent(String.self, forKey: .en)
    }

    private enum CodingKeys: String, CodingKey { case zh, en }

    var text: String? {
        let value = Lang.shared.isEnglish ? (en ?? zh) : (zh ?? en)
        return value?.isEmpty == false ? value : nil
    }
}

/// 首页公告（维护通知、已知问题和临时绕过办法、新功能……）
struct AppNotice: Decodable, Equatable, Identifiable {
    enum Level: String, Decodable { case info, warning }

    let id: String
    var level: Level
    var title: RemoteText?
    var body: RemoteText?
    /// 点了打开的地址：https:// 完整地址，或相对 tars.betac.cn 的路径（如 /support）；中英文要打开不同页面时写 {"zh", "en"}
    var link: RemoteText?
    /// 生效时间段（ISO 8601 带时区）；不写就一直有效
    var from: Date?
    var until: Date?
    var versions: VersionRange
    /// 能不能点 ✕ 关掉（默认能；关掉后这台手机不再显示这一条）
    var dismissible: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        level = (try? container.decode(Level.self, forKey: .level)) ?? .info
        title = try container.decodeIfPresent(RemoteText.self, forKey: .title)
        body = try container.decodeIfPresent(RemoteText.self, forKey: .body)
        link = try container.decodeIfPresent(RemoteText.self, forKey: .link)
        from = try container.decodeIfPresent(Date.self, forKey: .from)
        until = try container.decodeIfPresent(Date.self, forKey: .until)
        versions = try VersionRange(from: decoder)
        dismissible = try container.decodeIfPresent(Bool.self, forKey: .dismissible) ?? true
    }

    private enum CodingKeys: String, CodingKey { case id, level, title, body, link, from, until, dismissible }

    func isLive(_ now: Date, version: VersionNumber) -> Bool {
        !id.isEmpty && (from ?? .distantPast) <= now && now < (until ?? .distantFuture) && versions.contains(version)
            && (title?.text != nil || body?.text != nil)
    }

    /// 只认 https：公告里放不了打电话、发短信、跳别的 App 这类链接
    var url: URL? {
        guard let link = link?.text, let url = URL(string: link, relativeTo: RemoteConfig.url)?.absoluteURL, url.scheme == "https" else { return nil }
        return url
    }
}

/// 升级提示：latest 比这台的版本新 → 当作有新版本（和 App Store 上查到的取新的，见 AppUpdates）；minimum 比这台的版本新 → 整屏挡住，只能去更新
struct UpdateInfo: Decodable, Equatable {
    var latest: VersionNumber?
    var minimum: VersionNumber?
    /// App Store 上的地址；不写就按 bundle id 去 App Store 查
    var url: String?
    /// 新版本说明（首页提示、整屏挡住时都显示）
    var notes: RemoteText?
}

extension Lang.Patch: Decodable {
    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = .text(text)
            return
        }
        let container = try decoder.container(keyedBy: PluralKeys.self)
        self = .plural(one: try container.decode(String.self, forKey: .one), other: try container.decode(String.self, forKey: .other))
    }

    private enum PluralKeys: String, CodingKey { case one, other }
}

// MARK: - 本机缓存 + 后台更新

@MainActor @Observable
final class RemoteConfig {
    static let shared = RemoteConfig()
    nonisolated static let url = URL(string: "https://tars.betac.cn/app/config.json")!
    /// 上次取到的那份，原样存着。Application Support 不会像 Caches 那样在空间紧张时被系统清掉
    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("remote-config.json")

    private(set) var config = AppConfig()
    /// 这台手机上关掉的公告（id）、插件要求更新的提示（plugin-app:版本号）
    private(set) var dismissed: Set<String>
    /// 这个 App 的版本（Info.plist 的 CFBundleShortVersionString）
    let version: VersionNumber

    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var checked: Date?

    private static let dismissedKey = "remoteConfigDismissed"
    private static let etagKey = "remoteConfigETag"
    /// 回到前台时隔多久再问一次服务器（带 ETag，没变的话只回 304）
    private static let interval: TimeInterval = 10 * 60

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {
        version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(VersionNumber.init) ?? VersionNumber("0")!
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        #if SNAPSHOT
        // 截图版：TARS_DEMO_CONFIG=<config.json 路径> 预览一份还没发布的配置（截图版不联网）
        let source = Snapshot.remoteConfig.map { URL(fileURLWithPath: $0) }
        #else
        let source: URL? = Self.file
        #endif
        // 只读一个几 KB 的本地文件、不联网：启动时第一帧之前就读好，开关和文案更正从一开始就生效
        if let source, let data = try? Data(contentsOf: source), let cached = try? Self.decoder.decode(AppConfig.self, from: data) {
            apply(cached)
        }
    }

    // MARK: 查

    /// 这个功能开着没有：配置里没写、写的版本范围不含这台，都算开着
    func isOn(_ feature: RemoteFeature) -> Bool {
        guard let rule = config.features[feature.rawValue], rule.versions.contains(version) else { return true }
        return rule.enabled
    }

    /// 首页要显示的公告：在生效时间内、管这个版本、这台手机上没关掉过
    func notices(now: Date = .now) -> [AppNotice] {
        config.notices.filter { $0.isLive(now, version: version) && !dismissed.contains($0.id) }
    }

    /// 这个版本已经低于最低支持的版本
    var updateRequired: Bool {
        guard let minimum = config.update?.minimum else { return false }
        return version < minimum
    }

    var updateNotes: String? { config.update?.notes?.text }

    func dismiss(_ id: String) {
        dismissed.insert(id)
        UserDefaults.standard.set(dismissed.sorted(), forKey: Self.dismissedKey)
    }

    /// 打开 App Store 上的 Kiteline：配置里写了地址就用它，没写就按 bundle id 去 App Store 查；都不行打开 App Store 首页
    func openStore(_ openURL: OpenURLAction) async {
        openURL(await storeURL() ?? URL(string: "https://apps.apple.com/")!)
    }

    private func storeURL() async -> URL? {
        if let link = config.update?.url, let url = URL(string: link), ["https", "itms-apps"].contains(url.scheme) { return url }
        let bundle = Bundle.main.bundleIdentifier ?? "com.mrhong.tars.ios"
        let region = Locale.current.region?.identifier ?? "CN"
        guard let lookup = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundle)&country=\(region)"),
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: lookup, timeoutInterval: 8)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let page = first["trackViewUrl"] as? String else { return nil }
        return URL(string: page)
    }

    // MARK: 更新

    /// 问一次服务器（启动时 force；回到前台时 10 分钟内不重复）。取不到、回了错误、内容坏了都什么也不动：接着用手上这份
    func refresh(force: Bool = false) async {
        #if !SNAPSHOT
        if !force, let checked, Date.now.timeIntervalSince(checked) < Self.interval { return }
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }

        let defaults = UserDefaults.standard
        var request = URLRequest(url: Self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        // 本机存着那份才带它的 ETag：服务器上没变就回 304，不重新下
        if FileManager.default.fileExists(atPath: Self.file.path), let etag = defaults.string(forKey: Self.etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 304:
            checked = .now
        case 200:
            guard let fresh = try? Self.decoder.decode(AppConfig.self, from: data) else { return }
            do {
                let folder = Self.file.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: Self.file, options: .atomic)
                // 随时能重新下，不进 iCloud 备份
                var file = Self.file
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? file.setResourceValues(values)
                defaults.set(http.value(forHTTPHeaderField: "ETag"), forKey: Self.etagKey)
            } catch {
                defaults.removeObject(forKey: Self.etagKey)
            }
            checked = .now
            apply(fresh)
            // 关掉过的公告只记还在配置里的，免得越攒越多；插件要求更新的提示（plugin-app:版本）不归配置管，留着
            let live = Set(fresh.notices.map(\.id))
            let kept = dismissed.filter { live.contains($0) || $0.hasPrefix("plugin-app:") }
            if kept != dismissed {
                dismissed = kept
                defaults.set(dismissed.sorted(), forKey: Self.dismissedKey)
            }
        default:
            // 404、5xx：服务器那边出了状况，不当作「配置撤掉了」
            return
        }
        #endif
    }

    private func apply(_ fresh: AppConfig) {
        guard fresh != config else { return }
        config = fresh
        Lang.setPatches(fresh.strings)
    }
}
#endif
