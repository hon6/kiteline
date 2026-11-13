import Foundation
import Observation
import CryptoKit

/// 设置、通知、项目详情、定时任务这些页面用到的接口数据（和手机网页版同一套接口）

// MARK: Mac 的基本信息（/api/info）

struct MacInfo: Decodable {
    var host = ""
    var version = ""
    var quietStart = ""
    var quietEnd = ""
    var quietActive = false
    var digestTime = ""
    var morningTime = ""
    var remindWaiting = true
    /// 24 小时未查看的会话自动关闭（nil = 电脑还是没有这项的旧版）
    var autoCloseIdle: Bool?
    var speech = ""
    var accessibility = true
    var accessibilityName = ""
    var submitOnSend = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        host = c.text("host") ?? ""; version = c.text("version") ?? ""
        quietStart = c.text("quietStart") ?? ""; quietEnd = c.text("quietEnd") ?? ""; quietActive = c.truthy("quietActive")
        digestTime = c.text("digestTime") ?? ""; morningTime = c.text("morningTime") ?? ""
        remindWaiting = c.one("remindWaiting") ?? true
        autoCloseIdle = c.one("autoCloseIdle")
        speech = c.text("speech") ?? ""
        accessibility = c.one("accessibility") ?? true
        accessibilityName = c.text("accessibilityName") ?? L("辅助功能")
        submitOnSend = c.one("submitOnSend") ?? true
    }
}

// MARK: 通知收件箱（/api/inbox）

struct InboxEntry: Decodable, Identifiable, Hashable {
    var id: String
    var ts: Double
    var kind: String
    var title: String
    var body: String
    var key: String?
    var route: String?
    /// sent 推到了锁屏；quiet / muted / none / app 没推（原因见 heldReason）
    var delivery: String

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        ts = c.num("ts")
        id = c.text("id") ?? String(Int(ts))
        kind = c.text("kind") ?? ""
        title = c.text("title") ?? ""
        body = c.text("body") ?? ""
        key = c.text("key")
        route = c.text("route")
        delivery = c.text("delivery") ?? "sent"
    }

    /// 图标（SF Symbols）和种类
    var icon: (String, String) {
        ["attention": ("hand.raised.fill", L("待确认")), "conclusion": ("checkmark.seal.fill", L("已完成")), "image": ("photo.fill", L("发来图片")),
         "todo": ("checklist", L("新待办")), "keyinfo": ("key.fill", L("关键信息")),
         "error": ("exclamationmark.triangle.fill", L("出错已停止")), "stuck": ("hourglass", L("可能停滞")), "digest": ("sun.max.fill", L("日报")),
         "schedule": ("alarm.fill", L("定时任务")), "budget": ("dollarsign.circle.fill", L("花费提醒")),
         "editor": ("exclamationmark.bubble.fill", L("VS Code 提示")), "link": ("network.slash", L("连接状态")),
         "goal": ("scope", L("目标"))][kind] ?? ("bell.fill", L("提醒"))
    }

    var heldReason: String? {
        ["quiet": L("处于免打扰时段，未推送到锁屏"), "muted": L("会话已静音，未推送到锁屏"), "none": L("暂无设备开启推送"), "app": L("Kiteline 当时处于前台，仅在 App 内提醒")][delivery]
    }
}

struct InboxReply: Decodable {
    var entries: [InboxEntry]
    init(from decoder: Decoder) throws { entries = try decoder.fields().list("entries") }
}

// MARK: 定时任务（/api/schedules）

struct ScheduleTask: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var name: String
    var sourceName: String
    var cwd: String
    var prompt: String
    var enabled: Bool
    var nextRun: Double?
    var lastRun: Double?
    var lastOk: Bool
    var lastResult: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? ""
        label = c.text("label") ?? ""
        cwd = c.text("cwd") ?? ""
        name = c.text("name") ?? (cwd as NSString).lastPathComponent
        sourceName = c.text("sourceName") ?? ""
        prompt = c.text("prompt") ?? ""
        enabled = c.truthy("enabled")
        nextRun = c.one("nextRun")
        lastRun = c.one("lastRun")
        lastOk = c.truthy("lastOk")
        lastResult = c.text("lastResult")
    }
}

struct SchedulesReply: Decodable {
    var schedules: [ScheduleTask]
    init(from decoder: Decoder) throws { schedules = try decoder.fields().list("schedules") }
}

// MARK: 已配对的设备、操作记录、Bark

struct PairedDevice: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var online: Bool
    var current: Bool
    var lastSeen: Double?
    var lastIP: String
    var via: String
    var push: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? ""; name = c.text("name") ?? L("设备")
        online = c.truthy("online"); current = c.truthy("current")
        lastSeen = c.one("lastSeen"); lastIP = c.text("lastIP") ?? ""; via = c.text("via") ?? ""; push = c.truthy("push")
    }
}

struct DevicesReply: Decodable {
    var devices: [PairedDevice]
    init(from decoder: Decoder) throws { devices = try decoder.fields().list("devices") }
}

struct AuditEntry: Decodable, Hashable {
    var ts: Double
    var action: String
    var target: String?
    var detail: String?
    var ok: Bool
    var message: String?
    var client: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        ts = c.num("ts"); action = c.text("action") ?? ""; target = c.text("target"); detail = c.text("detail")
        ok = c.one("ok") ?? true; message = c.text("message"); client = c.text("client")
    }
}

struct AuditReply: Decodable {
    var entries: [AuditEntry]
    init(from decoder: Decoder) throws { entries = try decoder.fields().list("entries") }
}

struct BarkConfig: Decodable {
    var url = ""
    var mode = "attention"
    var valid = false
    var encrypted = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        url = c.text("url") ?? ""; mode = c.text("mode") ?? "attention"; valid = c.truthy("valid"); encrypted = c.truthy("encrypted")
    }
}

// MARK: 头像和名字（/api/profile）

struct ProfileInfo: Decodable {
    struct Group: Decodable, Hashable { var name: String; var items: [String] }
    var myName = ""
    var macName = ""
    var avatar = "mac"
    var hasMacPicture = false
    var hasCustom = false
    var groups: [Group] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        myName = c.text("myName") ?? ""; macName = c.text("macName") ?? ""; avatar = c.text("avatar") ?? "mac"
        hasMacPicture = c.truthy("hasMacPicture"); hasCustom = c.truthy("hasCustom"); groups = c.list("groups")
    }
}

// MARK: 改动报告、测试报告、项目文件

struct GitReport: Decodable {
    struct File: Decodable, Hashable { var path: String; var status: String; var add: Int?; var del: Int? }
    struct Commit: Decodable, Hashable { var hash: String; var subject: String; var ts: Double? }
    var repo: String?
    var reason: String?
    var branch: String?
    var upstream: String?
    var ahead: Int
    var behind: Int
    var files: [File]
    var untracked: [String]
    var untrackedCount: Int
    var totalAdd: Int
    var totalDel: Int
    var commits: [Commit]

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        repo = c.text("repo"); reason = c.text("reason"); branch = c.text("branch"); upstream = c.text("upstream")
        ahead = c.int("ahead"); behind = c.int("behind"); files = c.list("files"); untracked = c.list("untracked")
        untrackedCount = max(c.int("untrackedCount"), untracked.count); totalAdd = c.int("totalAdd"); totalDel = c.int("totalDel")
        commits = c.list("commits")
    }
}

struct TestRunInfo: Decodable, Identifiable, Hashable {
    var id: String { "\(ts ?? 0)-\(command.prefix(40))" }
    var command: String
    var description: String?
    var ok: Bool?
    var running: Bool
    var passed: Int?
    var failed: Int?
    var summary: String?
    var output: String?
    var ts: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        command = c.text("command") ?? ""; description = c.text("description"); ok = c.one("ok"); running = c.truthy("running")
        passed = (c.one("passed") as Double?).map(Int.init); failed = (c.one("failed") as Double?).map(Int.init)
        summary = c.text("summary"); output = c.text("output"); ts = c.one("ts")
    }

    var title: String { description ?? command.split(separator: "\n").first.map(String.init) ?? command }
}

struct TestsReply: Decodable {
    var runs: [TestRunInfo]
    init(from decoder: Decoder) throws { runs = try decoder.fields().list("runs") }
}

struct FileEntry: Decodable, Hashable {
    var name: String
    var type: String
    var size: Int
    var mtime: Double?
    var git: String?
    var link: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        name = c.text("name") ?? ""; type = c.text("type") ?? "file"; size = c.int("size"); mtime = c.one("mtime")
        git = c.text("git"); link = c.truthy("link")
    }
}

struct FileList: Decodable {
    var root: String
    var path: String
    var entries: [FileEntry]
    var truncated: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        root = c.text("root") ?? ""; path = c.text("path") ?? ""; entries = c.list("entries"); truncated = c.truthy("truncated")
    }
}

struct FileContent: Decodable {
    var text: String?
    var size: Int
    var lines: Int
    var mtime: Double?
    var secret: Bool
    var image: Bool
    var binary: Bool
    var tooLarge: Bool
    var truncated: Bool
    var data: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        text = c.text("text"); size = c.int("size"); lines = c.int("lines"); mtime = c.one("mtime")
        secret = c.truthy("secret"); image = c.truthy("image"); binary = c.truthy("binary"); tooLarge = c.truthy("tooLarge")
        truncated = c.truthy("truncated"); data = c.text("data")
    }
}

struct FindReply: Decodable {
    var results: [String]
    var truncated: Bool
    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        results = c.list("results"); truncated = c.truthy("truncated")
    }
}

/// 项目文件 / 测试 / 改动用到的小格式
enum Bytes {
    static func size(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return "\(n / 1024) KB" }
        return "\(n) B"
    }

    /// 「刚刚」「5 分钟前」「3 小时前」，更早写日期（和网页版一样）
    static func relative(_ ms: Double?) -> String {
        guard let ms, ms > 0 else { return "" }
        let seconds = max(0, Date().timeIntervalSince1970 - ms / 1000)
        if seconds < 60 { return L("刚刚") }
        if seconds < 3600 { return L("%@ 分钟前", "\(Int(seconds / 60))") }
        if seconds < 86400 { return L("%@ 小时前", "\(Int(seconds / 3600))") }
        return Format.separator(ms)
    }

    /// 「~/Documents/xx」
    static func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: #"^/(Users|home)/[^/]+"#, with: "~", options: .regularExpression)
    }
}

// MARK: 离线：最近的列表和对话存在手机上，断网也能翻

@MainActor
enum Offline {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 对话内容（可能有代码、密钥）不进 iCloud / 电脑备份：电脑上都有，换手机后连上重新拉就行
        if !excludedFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            excludedFromBackup = (try? dir.setResourceValues(values)) != nil
        }
        return dir
    }
    private static var excludedFromBackup = false
    private static var stateURL: URL { directory.appendingPathComponent("state.json") }
    private static var savedAt: [String: Date] = [:]
    private static var pending: [String: Task<Void, Never>] = [:]

    /// 5 秒内最多存一次；被节流掉的那次在窗口结束时补存，不丢最后一条
    private static func throttle(_ name: String, _ write: @escaping @Sendable () -> Void) {
        let wait = 5 - Date().timeIntervalSince(savedAt[name] ?? .distantPast)
        if wait <= 0 {
            savedAt[name] = Date()
            Task.detached(priority: .utility) { write() }
            return
        }
        pending[name]?.cancel()
        pending[name] = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            savedAt[name] = Date()
            Task.detached(priority: .utility) { write() }
        }
    }

    /// 演示模式的数据不存：退出后、配对真的 Mac 时不会先闪出演示会话
    private static var skip: Bool {
        #if KITELINE_MAC
        false
        #else
        Demo.active
        #endif
    }

    static func saveState(_ data: Data) {
        guard !skip else { return }
        let url = stateURL
        throttle("__state") { try? data.write(to: url, options: .atomic) }
    }

    static func loadState() -> StatePayload? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(StatePayload.self, from: data)
    }

    /// 每个会话留最后 80 条，长文字截短；最多留 10 个会话
    static func saveChat(_ key: String, _ items: [ChatItem]) {
        guard !skip else { return }
        let dir = directory
        let url = chatURL(key)
        throttle(key) {
            // 排序、截短也在后台做：几百条时要十几毫秒，每次推送都在主线程排一遍，滑动会顿一下（10-22 真机追踪）
            let recent = items.sorted(by: ChatItem.ordered).suffix(80).map { item -> ChatItem in
                var copy = item
                if let text = copy.text, text.count > 4000 { copy.text = String(text.prefix(4000)) + L("…（离线仅保存前 4000 字）") }
                return copy
            }
            guard let data = try? JSONEncoder().encode(Array(recent)) else { return }
            try? data.write(to: url, options: .atomic)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let chats = files.filter { $0.lastPathComponent.hasPrefix("chat-") }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for old in chats.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
        }
    }

    static func loadChat(_ key: String) -> [ChatItem]? {
        guard let data = try? Data(contentsOf: chatURL(key)) else { return nil }
        return try? JSONDecoder().decode([ChatItem].self, from: data)
    }

    /// 断开配对时清掉：别让下一台 Mac 先显示上一台的内容
    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 设置 →「存储空间」：每个会话的离线记录占多少（会话 key → 字节）
    nonisolated static func chatSizes() -> [String: Int] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        var sizes: [String: Int] = [:]
        for file in files where file.lastPathComponent.hasPrefix("chat-") && file.pathExtension == "json" {
            let safe = String(file.deletingPathExtension().lastPathComponent.dropFirst("chat-".count))
            sizes[safe.removingPercentEncoding ?? safe] = ImageDisk.size(file)
        }
        return sizes
    }

    nonisolated static func removeChat(_ key: String) {
        try? FileManager.default.removeItem(at: chatURL(key))
    }

    // MARK: 各页的数据（项目、用量、今日动态、历史会话、设置里的电脑和设备……）

    /// 接口原样回的 JSON 存一份（见 MacAPI.getCaching）：下次进页面先显示它，不是空白转圈。
    /// 和对话一样放 offline 目录（不进备份、断开配对时一起清掉）；演示模式不存
    nonisolated static func savePage(_ key: String, _ data: Data) {
        #if !KITELINE_MAC
        if Demo.active { return }
        #endif
        let url = pageURL(key)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func loadPage(_ key: String) -> Data? {
        #if !KITELINE_MAC
        if Demo.active { return nil }
        #endif
        return try? Data(contentsOf: pageURL(key))
    }

    /// 启动时清掉 14 天没再写过的页面缓存：按日期取的（今日动态带当天 0 点）每天一个新文件，不清会一直攒
    nonisolated static func prunePages(olderThan days: Double = 14) {
        Task.detached(priority: .background) {
            let cutoff = Date().addingTimeInterval(-days * 86400)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.lastPathComponent.hasPrefix("page-") {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    nonisolated private static func pageURL(_ key: String) -> URL {
        // 接口 + 参数可能很长、带斜杠：取个摘要当文件名
        let digest = Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("page-\(digest).json")
    }

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("offline", isDirectory: true)
    }

    nonisolated private static func chatURL(_ key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return folder.appendingPathComponent("chat-\(safe).json")
    }
}

// MARK: 网络监测：延迟、下行速率，网差时顶上显示一条

@MainActor
@Observable
final class NetMonitor {
    enum Quality { case good, poor, offline }

    private(set) var rtt: Double?
    private(set) var kbps: Double?
    private var kbpsAt = Date.distantPast
    private(set) var fails = 0
    private(set) var quality: Quality = .good
    private var task: Task<Void, Never>?

    func start(_ api: MacAPI) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loop(api)
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop(_ api: MacAPI) async {
        let wasPoor = quality == .poor
        let last = await probe(api, bytes: false)
        let stale = Date().timeIntervalSince(kbpsAt) > 30
        if ((rtt ?? 0) > 450 || fails > 0) && stale || (wasPoor && (last ?? 999) < 400) {
            if wasPoor { kbps = nil }
            await probe(api, bytes: true)
        }
    }

    /// 测一次：bytes = 顺便下载 96KB 测下行速率。返回这次的延迟（毫秒）
    @discardableResult
    func probe(_ api: MacAPI, bytes: Bool) async -> Double? {
        let start = Date()
        do {
            let data = try await api.data("/api/ping", ["bytes": bytes ? "98304" : "0"])
            let ms = Date().timeIntervalSince(start) * 1000
            fails = 0
            if bytes {
                let transfer = max(ms - (rtt ?? 0), 20)
                let value = Double(data.count) / 1024 / (transfer / 1000)
                kbps = kbps.map { $0 * 0.4 + value * 0.6 } ?? value
                kbpsAt = Date()
            } else {
                let weight = (rtt.map { ms < $0 } ?? false) ? 0.7 : 0.4
                rtt = rtt.map { $0 * (1 - weight) + ms * weight } ?? ms
            }
            update()
            return ms
        } catch {
            fails += 1
            update()
            return nil
        }
    }

    private func update() {
        if fails >= 2 { quality = .offline; return }
        let slow = (kbps ?? 999) < 120 && Date().timeIntervalSince(kbpsAt) < 60
        quality = (rtt ?? 0) > 900 || slow ? .poor : .good
    }

    /// 「↓ 80 KB/s · 延迟 950 ms」
    var description: String {
        var parts: [String] = []
        if let kbps, Date().timeIntervalSince(kbpsAt) < 120 {
            parts.append("↓ " + (kbps >= 1024 ? String(format: "%.1f MB/s", kbps / 1024) : "\(Int(kbps)) KB/s"))
        }
        if let rtt { parts.append(L("延迟 %@ ms", "\(Int(rtt))")) }
        return parts.joined(separator: " · ")
    }
}
