#if !KITELINE_MAC
import SwiftUI
import UIKit

// 新版本提醒：这台手机上的 Kiteline（问 App Store）和连着的电脑上的 Kiteline（新版电脑端有 /api/host-update 直接问它，
// 旧版电脑端没有这个接口，手机自己问官网的 latest.json）。
// 打开 App、回到前台、连上电脑时查；有新版本就弹一个面板（UpdatePromptSheet）：版本号、落后的这几版各自的更新内容，
// 手机的去 App Store 更新，电脑的可以直接让电脑在后台下载安装、装好后重启。
// 「以后再说」24 小时后再提醒；勾了「不再提示」这个版本就不再弹，出了更新的版本再弹（同电脑端的更新弹窗）。
// 远程配置里的 update.latest（RemoteConfig）也算：手动写了比 App Store 新的版本号时以它为准。

/// 一项可以更新的：这台手机上的 Kiteline，或连着的电脑上的 Kiteline
struct UpdateOffer: Identifiable, Equatable {
    enum Kind: Equatable {
        case app
        /// platform：mac / windows / linux；name：电脑名
        case host(platform: String, name: String)
    }

    let kind: Kind
    let current: String
    let version: String
    /// 落后的这几版各自的更新内容（新的在前）；只拿得到最新一版的就一条，什么都没有就是空的
    let releases: [UpdateRelease]

    /// 「不再提示」「过一天再提示」都按它记：同一个版本只问一次
    var id: String {
        switch kind {
        case .app: "app:\(version)"
        case .host(let platform, _): "host:\(platform):\(version)"
        }
    }

    var isApp: Bool { kind == .app }
}

/// 一个版本的更新内容
struct UpdateRelease: Equatable, Identifiable {
    let version: String
    /// 发布日期（2026-11-02）；没有就是空的
    let date: String
    let notes: String
    var id: String { version }

    init(version: String, date: String = "", notes: String) {
        self.version = version
        self.date = date
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 官网 notes-*.json、电脑端 /api/host-update 里的一条：{version, date, notes, notesEn}
    init?(_ raw: [String: Any]) {
        guard let version = raw["version"] as? String, !version.isEmpty else { return nil }
        let english = Lang.shared.isEnglish ? raw["notesEn"] as? String : nil
        // latest.json 里的是发布时刻（2026-11-01T17:01:37Z），只要日期
        self.init(version: version, date: String((raw["date"] as? String ?? "").prefix(10)), notes: english ?? raw["notes"] as? String ?? "")
    }

    /// 一串版本里挑出比 current 新、不比 latest 新的（新的在前，最多 limit 个）
    static func between(_ list: [[String: Any]], after current: VersionNumber, upTo latest: VersionNumber, limit: Int = 6) -> [UpdateRelease] {
        let picked = list.compactMap(UpdateRelease.init).filter { release in
            guard let v = VersionNumber(release.version) else { return false }
            return current < v && !(latest < v) && !release.notes.isEmpty
        }
        return Array(picked.sorted { (VersionNumber($0.version)!) > (VersionNumber($1.version)!) }.prefix(limit))
    }
}

/// 电脑端自己的更新进度（新版电脑端的 /api/host-update 才有）：手机上点「在电脑上更新」后看着它
struct HostUpdateState: Equatable {
    /// idle / checking / none / available / downloading / installing / ready / restarting / error
    var phase: String
    /// 电脑能不能自己装（官网下载的正式版才能；开发版、没有写入权限的只能到官网手动下载）
    var supported: Bool
    var reason: String
    var received: Int64
    var size: Int64
    var error: String

    var progress: Double { size > 0 ? min(1, Double(received) / Double(size)) : 0 }
    var busy: Bool { ["downloading", "installing", "restarting"].contains(phase) }
}

/// App Store 上的最新版（存着：连不上时用上次查到的）
struct StoreRelease: Codable, Equatable {
    var version: String
    var notes: String
    var url: String
    var minimumOS: String
    var date: String

    /// 新版本要求的系统版本这台装得上
    var installable: Bool {
        guard let need = VersionNumber(minimumOS), let mine = VersionNumber(UIDevice.current.systemVersion) else { return true }
        return !(mine < need)
    }
}

@MainActor @Observable
final class AppUpdates {
    static let shared = AppUpdates()
    /// 官网的各平台最新版（relay/download.sh 发布时写）；旧版电脑端没有更新接口时手机自己看它
    nonisolated static let feed = URL(string: "https://tars.betac.cn/download/latest.json")!
    /// 「以后再说」之后多久再弹
    static let snoozeFor: TimeInterval = 24 * 3600

    private(set) var store: StoreRelease?
    private(set) var hostOffer: UpdateOffer?
    private(set) var hostState: HostUpdateState?
    /// 从手机上让电脑更新、重启完了的版本：面板里那一项显示「已更新」
    private(set) var hostDone: String?
    /// 正在弹的面板里列的几项；nil = 没在弹
    var prompt: [UpdateOffer]?
    /// 勾了「不再提示」的（UpdateOffer.id）
    private(set) var skipped: Set<String>

    @ObservationIgnored private var snoozed: [String: Double]
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var storeChecked: Date?
    /// 官网 latest.json 上次取到的（旧版电脑端用；一小时内不重复取，三十几 KB）
    @ObservationIgnored private var feedCache: (at: Date, json: [String: Any], notes: [String: [[String: Any]]])?
    @ObservationIgnored private var promptTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private static let storeKey = "updateStoreRelease"
    private static let skippedKey = "updateSkipped"
    private static let snoozedKey = "updateSnoozed"

    private init() {
        let defaults = UserDefaults.standard
        skipped = Set(defaults.stringArray(forKey: Self.skippedKey) ?? [])
        snoozed = defaults.dictionary(forKey: Self.snoozedKey) as? [String: Double] ?? [:]
        if let data = defaults.data(forKey: Self.storeKey) { store = try? JSONDecoder().decode(StoreRelease.self, from: data) }
        #if SNAPSHOT
        demo()
        #endif
    }

    // MARK: 这台手机

    /// 这台手机上的 Kiteline 能更新到的版本：App Store 上的（这台的系统装得上才算），远程配置里手动写了更新的就用它
    var appOffer: UpdateOffer? {
        let remote = RemoteConfig.shared
        let current = remote.version
        var best: VersionNumber?
        if let store, store.installable, let version = VersionNumber(store.version), current < version { best = version }
        if let latest = remote.config.update?.latest, current < latest, best.map({ $0 < latest }) ?? true { best = latest }
        guard let best else { return nil }
        let fromStore = store.flatMap { VersionNumber($0.version) } == best ? store?.notes : nil
        let fromConfig = remote.config.update?.latest == best ? remote.updateNotes : nil
        // App Store 上的更新说明只有中文：英文界面优先用远程配置里写的
        let notes = (Lang.shared.isEnglish ? fromConfig ?? fromStore : fromStore ?? fromConfig) ?? ""
        let date = fromStore != nil ? String((store?.date ?? "").prefix(10)) : ""
        return UpdateOffer(kind: .app, current: current.description, version: best.description,
                           releases: notes.isEmpty ? [] : [UpdateRelease(version: best.description, date: date, notes: notes)])
    }

    /// 问 App Store 上的最新版（启动时 force；回到前台时一小时内不重复问）
    func refreshStore(force: Bool = false) async {
        #if !SNAPSHOT
        if !force, let storeChecked, Date.now.timeIntervalSince(storeChecked) < 3600 { return }
        storeChecked = .now
        guard let fresh = await Self.lookup(), fresh != store else { return }
        store = fresh
        if let data = try? JSONEncoder().encode(fresh) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        #endif
    }

    /// App Store 的查询接口：按这台手机的地区查，查不到（这个地区没上架）再查中国区
    nonisolated private static func lookup() async -> StoreRelease? {
        let bundle = Bundle.main.bundleIdentifier ?? "com.mrhong.tars.ios"
        let region = Locale.current.region?.identifier.lowercased() ?? "cn"
        for country in region == "cn" ? ["cn"] : [region, "cn"] {
            var link = "https://itunes.apple.com/lookup?bundleId=\(bundle)&country=\(country)"
            #if DEBUG
            // 调试：TARS_STORE_LOOKUP=<地址> 换成本地的假结果（测弹窗）
            if let fake = ProcessInfo.processInfo.environment["TARS_STORE_LOOKUP"] { link = fake }
            #endif
            guard let url = URL(string: link),
                  let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            guard let first = (json["results"] as? [[String: Any]])?.first, let version = first["version"] as? String else { continue }
            return StoreRelease(version: version, notes: first["releaseNotes"] as? String ?? "", url: first["trackViewUrl"] as? String ?? "",
                                minimumOS: first["minimumOsVersion"] as? String ?? "", date: first["currentVersionReleaseDate"] as? String ?? "")
        }
        return nil
    }

    /// 打开 App Store 上的 Kiteline
    func openStore(_ openURL: OpenURLAction) async {
        if let link = store?.url, let url = URL(string: link), url.scheme == "https" {
            openURL(url)
        } else {
            await RemoteConfig.shared.openStore(openURL)
        }
    }

    // MARK: 连着的电脑

    /// 连上电脑（或重连）时问一次：新版电脑端问它自己（顺带拿到下载、安装进度），旧版的看官网 latest.json
    func connect(_ model: AppModel) async {
        self.model = model
        // 演示模式：「演示 Mac」的版本是示例数据里写死的，不提示它更新（列表里的卡片、弹窗都不出）
        if MacStore.shared.isDemo {
            hostOffer = nil
            hostState = nil
            return
        }
        guard model.connected, let current = VersionNumber(model.version) else { return }
        let platform = Self.family(HostPlatform.current)
        let name = model.host
        if model.hostFeatures.contains("hostUpdate") {
            if let reply = try? await model.api.get("/api/host-update") { applyHost(reply, platform: platform, name: name) }
            return
        }
        guard let (latest, notes) = await feed(platform) else { return }
        guard let version = latest["version"] as? String, let newest = VersionNumber(version), current < newest else {
            hostOffer = nil
            return
        }
        var releases = UpdateRelease.between(notes, after: current, upTo: newest)
        if releases.isEmpty, let only = UpdateRelease(latest), !only.notes.isEmpty { releases = [only] }
        hostOffer = UpdateOffer(kind: .host(platform: platform, name: name), current: model.version, version: version, releases: releases)
        hostState = nil
    }

    /// 换了电脑、退出配对：不再说那台电脑的事
    func disconnect(_ model: AppModel) {
        guard self.model === model else { return }
        self.model = nil
        hostOffer = nil
        hostState = nil
        pollTask?.cancel()
    }

    /// mac / windows / linux（Mac 版电脑端不报 platform）
    private static func family(_ platform: String) -> String {
        platform.isEmpty || platform == "macos" ? "mac" : platform
    }

    /// 官网上这个平台的最新版，和最近几版的更新内容（notes-mac.json / notes-desktop.json，Windows、Linux 共用一份更新记录）
    private func feed(_ platform: String) async -> ([String: Any], [[String: Any]])? {
        let family = platform == "mac" ? "mac" : "desktop"
        if let cache = feedCache, Date.now.timeIntervalSince(cache.at) < 3600,
           let latest = (cache.json["platforms"] as? [String: Any])?[platform] as? [String: Any] {
            return (latest, cache.notes[family] ?? [])
        }
        guard let json = await Self.fetchJSON(Self.feed),
              let latest = (json["platforms"] as? [String: Any])?[platform] as? [String: Any] else { return nil }
        var notes = feedCache?.notes ?? [:]
        if let list = await Self.fetchJSON(Self.feed.deletingLastPathComponent().appendingPathComponent("notes-\(family).json"))?["releases"] as? [[String: Any]] {
            notes[family] = list
        }
        feedCache = (.now, json, notes)
        return (latest, notes[family] ?? [])
    }

    nonisolated private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 电脑端 /api/host-update 的回复：{current, version, phase, releases, notes, supported, reason, size, received, error}
    private func applyHost(_ reply: [String: Any], platform: String, name: String) {
        let phase = reply["phase"] as? String ?? "none"
        let state = HostUpdateState(phase: phase, supported: reply["supported"] as? Bool ?? false, reason: reply["reason"] as? String ?? "",
                                    received: (reply["received"] as? NSNumber)?.int64Value ?? 0, size: (reply["size"] as? NSNumber)?.int64Value ?? 0,
                                    error: reply["error"] as? String ?? "")
        let current = reply["current"] as? String ?? model?.version ?? ""
        // 电脑正在例行检查（checking）时新版本照样在；换完新版本重启起来就是 none，这一项收起
        guard phase != "none", let version = reply["version"] as? String, let newest = VersionNumber(version),
              let mine = VersionNumber(current), mine < newest else {
            if let offer = hostOffer, let mine = VersionNumber(current), let target = VersionNumber(offer.version), !(mine < target) {
                hostDone = offer.version
            }
            hostOffer = nil
            hostState = nil
            return
        }
        var releases = UpdateRelease.between(reply["releases"] as? [[String: Any]] ?? [], after: mine, upTo: newest)
        if releases.isEmpty, let notes = reply["notes"] as? String, !notes.isEmpty { releases = [UpdateRelease(version: version, notes: notes)] }
        let offer = UpdateOffer(kind: .host(platform: platform, name: name), current: current, version: version, releases: releases)
        if offer != hostOffer { hostOffer = offer }
        if state != hostState { hostState = state }
    }

    /// 让电脑下载并安装（start）、取消下载（cancel）、重启换上新版本（restart）
    func hostAction(_ action: String) async {
        guard let model, let offer = hostOffer, case .host(let platform, let name) = offer.kind else { return }
        do {
            let reply = try await model.api.post("/api/host-update", body: ["action": action])
            if reply["ok"] as? Bool == false, let error = reply["error"] as? String, !error.isEmpty { ToastWindow.flash(error) }
            applyHost(reply, platform: platform, name: name)
        } catch {
            ToastWindow.flash(error.localizedDescription)
            return
        }
        watchHost()
    }

    /// 电脑在下载、安装、重启时每秒问一次进度；重启后连接会断一下，重新连上时 connect 会再问
    private func watchHost() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<900 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let model = self.model, self.hostState?.busy == true,
                      let offer = self.hostOffer, case .host(let platform, let name) = offer.kind else { return }
                guard model.connected, let reply = try? await model.api.get("/api/host-update") else { continue }
                self.applyHost(reply, platform: platform, name: name)
            }
        }
    }

    // MARK: 什么时候弹

    func isSkipped(_ offer: UpdateOffer) -> Bool { skipped.contains(offer.id) }

    /// 勾 / 取消「不再提示」：当场记下，点 ✕ 关掉面板也算
    func setSkipped(_ offers: [UpdateOffer], _ on: Bool) {
        for offer in offers { if on { skipped.insert(offer.id) } else { skipped.remove(offer.id) } }
        // 只记还可能用上的：版本号变了的那些留着也不会再用
        let live = Set([appOffer?.id, hostOffer?.id].compactMap { $0 })
        if skipped.count > 20 { skipped.formIntersection(live) }
        UserDefaults.standard.set(skipped.sorted(), forKey: Self.skippedKey)
    }

    /// 该弹的：有新版本、没勾过「不再提示」、上次弹过已经过了一天；低于最低版本时整屏挡着（UpdateGate），不再另弹
    private var due: [UpdateOffer] {
        guard !RemoteConfig.shared.updateRequired else { return [] }
        let now = Date.now.timeIntervalSince1970
        return [appOffer, hostOffer].compactMap { $0 }.filter { !skipped.contains($0.id) && (snoozed[$0.id] ?? 0) <= now }
    }

    /// 查完了看要不要弹：等启动页飞走、别的面板都关了再弹（同时只能弹一个面板）；已经在弹的话把新查到的加进去。
    /// 最多等五分钟（一直有别的面板开着就算了，下次回到前台再说）
    func schedulePrompt() {
        if let shown = prompt {
            let more = due.filter { offer in !shown.contains { $0.id == offer.id } }
            guard !more.isEmpty else { return }
            // 同一项换了版本（电脑那头又发了新版）就换掉旧的
            prompt = shown.filter { old in !more.contains { $0.isApp == old.isApp } } + more
            markShown(more)
            return
        }
        guard !due.isEmpty, promptTask == nil else { return }
        promptTask = Task { [weak self] in
            defer { self?.promptTask = nil }
            try? await Task.sleep(for: .seconds(3))
            for attempt in 0..<60 {
                guard let self, !Task.isCancelled else { return }
                let offers = self.due
                guard !offers.isEmpty, self.prompt == nil else { return }
                // 启动页的标志万一没置上：等过 15 秒也照常弹
                if UIApplication.shared.applicationState == .active, SplashOverlay.finished || attempt >= 3, !Self.presenting {
                    self.present(offers)
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// 弹出面板（首页的「有新版本」提示条点了也走这里）
    func present(_ offers: [UpdateOffer]) {
        guard !offers.isEmpty else { return }
        prompt = offers
        markShown(offers)
    }

    /// 弹过就记下：24 小时内不再自动弹
    private func markShown(_ offers: [UpdateOffer]) {
        let until = Date.now.timeIntervalSince1970 + Self.snoozeFor
        for offer in offers { snoozed[offer.id] = until }
        snoozed = snoozed.filter { $0.value > Date.now.timeIntervalSince1970 - Self.snoozeFor }
        UserDefaults.standard.set(snoozed, forKey: Self.snoozedKey)
    }

    /// 屏幕上已经弹着面板、提示框
    private static var presenting: Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let root = windows.first(where: \.isKeyWindow)?.rootViewController else { return true }
        return root.presentedViewController != nil
    }

    #if SNAPSHOT
    /// 截图版：TARS_DEMO_UPDATE=app,host 弹出更新面板（假的版本号和更新内容）
    private func demo() {
        guard let parts = ProcessInfo.processInfo.environment["TARS_DEMO_UPDATE"]?.split(separator: ","), !parts.isEmpty else { return }
        var offers: [UpdateOffer] = []
        let current = RemoteConfig.shared.version.description
        if parts.contains("app") {
            offers.append(UpdateOffer(kind: .app, current: current, version: "9.0", releases: [UpdateRelease(version: "9.0", date: "2026-11-02", notes: L("新功能\n· 打开 App 时提示新版本，可查看更新内容并前往 App Store 更新。\n\n改进\n· 手机与电脑互相提醒对方的新版本。"))]))
        }
        if parts.contains("host") {
            hostState = HostUpdateState(phase: "available", supported: true, reason: "", received: 0, size: 26_000_000, error: "")
            offers.append(UpdateOffer(kind: .host(platform: "mac", name: "Mac Studio"), current: "3.49.12", version: "3.49.16", releases: [
                UpdateRelease(version: "3.49.16", date: "2026-11-02", notes: L("新功能\n· 数据流大屏：把所有会话放在一块屏上。")),
                UpdateRelease(version: "3.49.15", date: "2026-11-01", notes: L("问题修复\n· 修正若干问题。")),
            ]))
            hostOffer = offers.last
        }
        if !offers.isEmpty { Task { try? await Task.sleep(for: .seconds(1.5)); self.prompt = offers } }
    }
    #endif
}
#endif
