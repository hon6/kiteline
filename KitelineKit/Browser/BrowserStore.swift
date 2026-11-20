import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 会话浏览器（watcher 的 BrowserPool）：agent 用 Kiteline 的浏览器时，会话数据里带 browser，对话页浮出实时画面小窗。
/// 画面只在有人看时推（watch 每 5 秒续一次，停了 15 秒电脑就停推）；小窗要缩略档，放大后要大画面档（帧率、清晰度更高）
struct BrowserInfo: Decodable, Hashable {
    var url: String
    var title: String
    /// 最近一条浏览器指令（agent-browser / playwright-cli / MCP 的）
    var last: String
    var actions: Int
    /// agent 请你接管时的说明（browser ask）
    var ask: String?
    var since: Double?
    /// 浏览器已经关了、留着录像（小窗变成「回放」卡片）
    var closed: Bool
    var recs: Int

    enum CodingKeys: String, CodingKey { case url, title, last, actions, ask, since, closed, recs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = ((try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil) ?? ""
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? ""
        last = ((try? c.decodeIfPresent(String.self, forKey: .last)) ?? nil) ?? ""
        actions = ((try? c.decodeIfPresent(Int.self, forKey: .actions)) ?? nil) ?? 0
        ask = ((try? c.decodeIfPresent(String.self, forKey: .ask)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        since = (try? c.decodeIfPresent(Double.self, forKey: .since)) ?? nil
        closed = ((try? c.decodeIfPresent(Bool.self, forKey: .closed)) ?? nil) ?? false
        recs = ((try? c.decodeIfPresent(Int.self, forKey: .recs)) ?? nil) ?? 0
    }

    /// 地址栏上显示的：去掉协议
    var shortURL: String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
}

/// 一条浏览器指令
struct BrowserAction: Identifiable, Hashable {
    let id: Int
    var time: Double?
    var tool: String
    var text: String
}

struct BrowserTab: Identifiable, Hashable {
    let id: String
    var url: String
    var title: String
    var current: Bool
}

/// 画面放多大：小窗 / 半个会话 / 整个会话 / 整个应用 / 全屏。
/// iPhone / iPad 上只用其中三种：半屏（half）、全屏（fullscreen）、悬浮小窗（mini）——
/// 手机屏幕小，「整个会话」「整个应用」和全屏几乎一样，四档反而难选（11-19 反馈：三种状态切换就好）
enum BrowserSize: String, CaseIterable, Identifiable {
    case mini, half, session, app, fullscreen
    var id: String { rawValue }

    /// 这个平台上能切的几档，按顶栏上从左到右的顺序。Mac 的小窗是旁边单独的「缩回小窗」按钮，不在这一排里
    static var choices: [BrowserSize] {
        #if os(macOS)
        [.half, .session, .app, .fullscreen]
        #else
        [.half, .fullscreen, .mini]
        #endif
    }

    var label: String {
        switch self {
        #if os(macOS)
        case .mini: L("小窗")
        case .half: L("半个会话")
        #else
        case .mini: L("悬浮小窗")
        case .half: L("半屏")
        #endif
        case .session: L("整个会话")
        case .app: L("整个应用")
        case .fullscreen: L("全屏")
        }
    }
    var icon: String {
        switch self {
        case .mini: "pip"
        case .half: "rectangle.tophalf.inset.filled"
        case .session: "rectangle.inset.filled"
        case .app: "macwindow"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        }
    }
    /// 放大的几档才要清晰的大画面
    var level: String { self == .mini ? "thumb" : "full" }
}

@MainActor @Observable
final class BrowserStore {
    struct Frame {
        var image: PlatformImage
        var seq: Int
        /// 网页本身的尺寸（CSS 像素）：点击位置按画面比例换算
        var cssWidth: Double
        var cssHeight: Double
        var url: String
        var title: String
    }

    /// 会话 key → 最近一帧
    private(set) var frames: [String: Frame] = [:]
    /// 会话 key → 指令列表、标签页（打开大画面时拉，有新指令时刷新）
    private(set) var actions: [String: [BrowserAction]] = [:]
    private(set) var tabs: [String: [BrowserTab]] = [:]
    /// 会话 key → 放多大（没设过是小窗）
    var sizes: [String: BrowserSize] = [:]
    /// 放到「整个应用 / 全屏」的那个会话（盖在整个窗口上，见 BrowserAppLayer）
    var focus: String?
    /// 会话 key → 关掉了小窗（这次浏览器打开期间不再浮出；agent 请你接管时照样浮出）
    var dismissed: [String: Double] = [:]
    /// 正由这台设备接管的会话
    private(set) var controlling: Set<String> = []
    /// 小窗被拖到哪（相对右上角的默认位置）：记在本机，各会话共用
    var miniOffset: CGSize = BrowserStore.savedOffset() {
        didSet { UserDefaults.standard.set([miniOffset.width, miniOffset.height], forKey: "browserMiniOffset") }
    }

    private static func savedOffset() -> CGSize {
        guard let pair = UserDefaults.standard.array(forKey: "browserMiniOffset") as? [Double], pair.count == 2 else { return .zero }
        return CGSize(width: pair[0], height: pair[1])
    }

    @ObservationIgnored weak var model: AppModel?
    /// 正在看的会话 → 看的档位（几处同时看取最高的）
    @ObservationIgnored private var viewers: [String: [UUID: String]] = [:]
    @ObservationIgnored private var leases: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let viewerId = UUID().uuidString

    func size(_ key: String) -> BrowserSize { sizes[key] ?? .mini }

    func setSize(_ key: String, _ size: BrowserSize) {
        sizes[key] = size
        if size == .app || size == .fullscreen {
            focus = key
        } else if focus == key {
            focus = nil
        }
    }

    /// 有会话的浏览器正全屏盖着整个界面（iPhone / iPad 据此藏状态栏，见 MainView）
    var fullscreenShown: Bool {
        guard let key = focus, sizes[key] == .fullscreen else { return false }
        return model?.session(key)?.browser != nil
    }

    /// 会话在用浏览器就显示（小窗，或收起后的小圆钮）
    func visible(_ key: String, _ info: BrowserInfo?) -> Bool { info != nil }

    /// 小窗收起成小圆钮了（× 只是收起：浏览器照常运行、agent 照常操作；轻点圆钮恢复；agent 请你接管时自动展开）
    func collapsed(_ key: String, _ info: BrowserInfo?) -> Bool {
        guard let info, info.ask == nil, let at = dismissed[key] else { return false }
        return at == (info.since ?? 0)
    }

    func dismiss(_ key: String, _ info: BrowserInfo?) {
        dismissed[key] = info?.since ?? 0
        setSize(key, .mini)
    }

    func expand(_ key: String) { dismissed[key] = nil }

    // MARK: 看画面

    /// 视图出现：开始看（token 是这个视图自己的，消失时用它退订）
    func watch(_ key: String, token: UUID, level: String) {
        viewers[key, default: [:]][token] = level
        ensureLease(key, first: true)
    }

    func unwatch(_ key: String, token: UUID) {
        viewers[key]?[token] = nil
        if viewers[key]?.isEmpty ?? true {
            viewers[key] = nil
            leases[key]?.cancel()
            leases[key] = nil
            Task { [weak self] in
                guard let api = self?.model?.api, let viewer = self?.viewerId else { return }
                _ = try? await api.post("/api/browser", ["key": key], body: ["op": "unwatch", "viewer": viewer])
            }
        } else {
            ensureLease(key, first: false)
        }
    }

    private func level(_ key: String) -> String {
        (viewers[key]?.values.contains("full") ?? false) ? "full" : "thumb"
    }

    /// 每 5 秒续一次（档位变了马上续）：电脑那边 15 秒没续就当没人看、停推
    private func ensureLease(_ key: String, first: Bool) {
        leases[key]?.cancel()
        leases[key] = Task { [weak self] in
            var initial = first
            while !Task.isCancelled {
                guard let self, let api = self.model?.api else { return }
                do {
                    let reply = try await api.post("/api/browser", ["key": key],
                                                   body: ["op": "watch", "viewer": self.viewerId, "level": self.level(key), "first": initial])
                    initial = false
                    self.apply(key, reply)
                } catch {
                    // 浏览器被回收了、会话结束了：等下一轮（会话数据里没了 browser，小窗自己会收起）
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func apply(_ key: String, _ reply: [String: Any]) {
        if let rows = reply["actions"] as? [[String: Any]] {
            actions[key] = rows.enumerated().map { index, row in
                BrowserAction(id: index, time: row["t"] as? Double, tool: row["tool"] as? String ?? "", text: row["text"] as? String ?? "")
            }
        }
        if let rows = reply["tabs"] as? [[String: Any]] {
            tabs[key] = rows.compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                return BrowserTab(id: id, url: row["url"] as? String ?? "", title: row["title"] as? String ?? "",
                                  current: row["current"] as? Bool ?? false)
            }
        }
        if let control = reply["control"] as? [String: Any] {
            _ = control   // 别的设备接管着：现在只看自己这台的状态（交还按钮在接管的那台上）
        }
    }

    /// 有新指令（会话数据里的 last 变了）：刷新列表
    func refreshActions(_ key: String, force: Bool = false) async {
        guard force || viewers[key] != nil, let api = model?.api else { return }
        if let reply = try? await api.post("/api/browser", ["key": key], body: ["op": "actions"]) { apply(key, reply) }
    }

    /// 实时连接上的 browser_frame（browser_ask 由会话数据里的 ask 反映）
    func receive(_ event: String, _ data: Data) {
        guard event == "browser_frame",
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = raw["key"] as? String, viewers[key] != nil,
              let seq = raw["seq"] as? Int, seq > (frames[key]?.seq ?? -1) || frames[key] == nil,
              let blob = (raw["data"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let image = PlatformImage(data: blob) else { return }
        frames[key] = Frame(image: image, seq: seq,
                            cssWidth: (raw["cssW"] as? Double) ?? Double(raw["cssW"] as? Int ?? 0),
                            cssHeight: (raw["cssH"] as? Double) ?? Double(raw["cssH"] as? Int ?? 0),
                            url: raw["url"] as? String ?? "", title: raw["title"] as? String ?? "")
    }

    // MARK: 接管

    func isControlling(_ key: String) -> Bool { controlling.contains(key) }

    func takeOver(_ key: String) async {
        controlling.insert(key)
        await post(key, ["op": "control", "on": true, "device": Self.deviceName])
    }

    /// 交还给 agent（agent 在 browser ask 里等着的话，留言带给它）
    func handBack(_ key: String, note: String = "") async {
        controlling.remove(key)
        await post(key, ["op": "control", "on": false, "text": note, "device": Self.deviceName])
    }

    /// 点击、拖动、滚动、打字、按键、地址栏：x / y 是在画面上的比例（0～1）
    func input(_ key: String, _ body: [String: Any]) {
        var body = body
        body["op"] = "input"
        Task { await post(key, body, quiet: true) }
    }

    func selectTab(_ key: String, _ id: String) async {
        if let api = model?.api, let reply = try? await api.post("/api/browser", ["key": key], body: ["op": "tab", "tab": id]) {
            apply(key, reply)
        }
    }

    func closeBrowser(_ key: String) async {
        await post(key, ["op": "close"])
        setSize(key, .mini)
    }

    private func post(_ key: String, _ body: [String: Any], quiet: Bool = false) async {
        guard let api = model?.api else { return }
        do {
            _ = try await api.post("/api/browser", ["key": key], body: body)
        } catch {
            if !quiet { model?.flash(error.localizedDescription) }
        }
    }

    // MARK: 录像回放

    struct Recording: Identifiable, Hashable {
        let id: String
        var started: Double
        var ended: Double
        var frames: Int
        var live: Bool
    }

    struct RecFrame: Hashable {
        var time: Double     // 毫秒
        var url: String
    }

    func recordings(_ key: String) async -> [Recording] {
        guard let api = model?.api, let reply = try? await api.post("/api/browser", ["key": key], body: ["op": "recordings"]) else { return [] }
        return (reply["recordings"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return Recording(id: id, started: row["started"] as? Double ?? 0, ended: row["ended"] as? Double ?? 0,
                             frames: row["frames"] as? Int ?? 0, live: row["live"] as? Bool ?? false)
        }
    }

    /// 一段录像的帧时刻（不变的时候不存帧：相邻两帧的时间差就是画面停了多久）和结束时刻
    func recording(_ key: String, _ id: String) async -> (frames: [RecFrame], end: Double)? {
        guard let api = model?.api, let reply = try? await api.post("/api/browser", ["key": key], body: ["op": "recording", "rec": id]) else { return nil }
        let frames = (reply["frames"] as? [[Any]] ?? []).map { row in
            RecFrame(time: (row.first as? Double) ?? Double(row.first as? Int ?? 0), url: row.count > 3 ? row[3] as? String ?? "" : "")
        }
        return (frames, reply["end"] as? Double ?? frames.last?.time ?? 0)
    }

    func recFrames(_ key: String, _ id: String, from: Int, count: Int) async -> [Int: PlatformImage] {
        guard let api = model?.api,
              let reply = try? await api.post("/api/browser", ["key": key], body: ["op": "rframes", "rec": id, "from": from, "count": count]) else { return [:] }
        var out: [Int: PlatformImage] = [:]
        for row in reply["frames"] as? [[String: Any]] ?? [] {
            if let index = row["i"] as? Int, let data = (row["data"] as? String).flatMap({ Data(base64Encoded: $0) }), let image = PlatformImage(data: data) {
                out[index] = image
            }
        }
        return out
    }

    /// 关掉「回放」卡片（录像还在，放大视图里照样能看）
    func forget(_ key: String) async { await post(key, ["op": "forget"], quiet: true) }

    static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}
