import Foundation

/// 存储清理（11-24 用户要的）：会话衍生出来的缓存本来就能从 agent 的会话记录里重新拉，不必长期留着。
/// 口径是「超过 N 天（默认 14）没有使用」，按最后一次使用算，不是按创建时间算。
/// 清的只有我们自己存的衍生数据：图片缓存（media-cache，手机看过的图）、会话浏览器的用户数据、手机发来的图片、旧的测试报告；
/// 不碰 agent 自己的会话记录、待办、收藏、配置。浏览器数据、收件图片、报告由 watcher 的 `storage` 子命令管（watcher/kiteline-watch.py），
/// 这里再加上 Mac 自己的图片缓存，并提供「立即清理」和每天一次的自动清理。
enum StorageCleaner {
    struct Category {
        var id: String
        var name: String
        var bytes: Int64
        var cleanable: Int64
        var items: Int
    }

    static let names: [String: String] = [
        "media": "图片缓存", "browser": "会话浏览器数据", "inbox": "手机发来的图片", "reports": "测试报告",
    ]
    private static let lastKey = "storageAutoCleanAt"

    /// 本机 watcher 脚本（和远端同一个位置）
    private static var watcherPath: String { NSString(string: "~/.ccpulse/ccpulse-watch.py").expandingTildeInPath }

    /// 跑 watcher 的 storage 子命令，返回标准输出；不在、跑不了就返回 nil
    private static func watcher(_ arguments: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: watcherPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", watcherPath, "storage"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // 先读完再等退出：输出不大，不会塞满管道
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// 图片缓存：总大小、超过 days 天没碰过的大小和个数（按最近访问时间，同 MediaCache.prune）
    private static func mediaUsage(days: Int) -> (bytes: Int64, stale: Int64, items: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: MediaCache.directory,
                                                      includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey]) else { return (0, 0, 0) }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var total: Int64 = 0, stale: Int64 = 0, count = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentAccessDateKey, .fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            total += size
            if file.pathExtension != "mime" { count += 1 }
            if (values?.contentAccessDate ?? .distantPast) < cutoff { stale += size }
        }
        return (total, stale, count)
    }

    /// 扫一遍：每类多大、按 days 天能清多少 → 给设置页和手机 / 电脑端的「存储」页用
    static func scan(days: Int) -> [String: Any] {
        var rows: [Category] = []
        let media = mediaUsage(days: days)
        rows.append(Category(id: "media", name: names["media"] ?? "media", bytes: media.bytes, cleanable: media.stale, items: media.items))
        if let text = watcher(["scan", "--days", String(days), "--json"]),
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = object["categories"] as? [[String: Any]] {
            for item in list {
                let id = item["category"] as? String ?? ""
                rows.append(Category(id: id, name: names[id] ?? id, bytes: (item["bytes"] as? NSNumber)?.int64Value ?? 0,
                                     cleanable: (item["cleanable"] as? NSNumber)?.int64Value ?? 0, items: item["items"] as? Int ?? 0))
            }
        }
        rows.sort { $0.bytes > $1.bytes }
        return [
            "days": days,
            "total": rows.reduce(Int64(0)) { $0 + $1.bytes },
            "cleanable": rows.reduce(Int64(0)) { $0 + $1.cleanable },
            "categories": rows.map { ["id": $0.id, "name": $0.name, "bytes": $0.bytes, "cleanable": $0.cleanable, "items": $0.items] },
        ]
    }

    /// 清掉超过 days 天没用的；only 为空就全清。返回腾出的字节数
    @discardableResult
    static func clean(days: Int, only: Set<String> = []) -> Int64 {
        var freed: Int64 = 0
        if only.isEmpty || only.contains("media") {
            let before = mediaUsage(days: days).stale
            MediaCache.prune(days: days)
            freed += before
        }
        var arguments = ["clean", "--days", String(days), "--json"]
        let rest = only.subtracting(["media"])
        if !only.isEmpty && rest.isEmpty { return freed }
        if !rest.isEmpty { arguments += ["--only", rest.sorted().joined(separator: ",")] }
        if let text = watcher(arguments), let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            freed += (object["freed"] as? NSNumber)?.int64Value ?? 0
        }
        Log.write("存储清理：超过 \(days) 天没用的，共腾出 \(freed / 1_048_576) MB")
        return freed
    }

    /// 每天最多自动清一次（用户可在设置里关掉、改天数）；浏览器数据等同时由 watcher 自己每天清，这里补上 Mac 自己的图片缓存
    static func autoCleanIfDue(enabled: Bool, days: Int) {
        guard enabled else { return }
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: lastKey) > 20 * 3600 else { return }
        UserDefaults.standard.set(now, forKey: lastKey)
        DispatchQueue.global(qos: .utility).async { _ = clean(days: days, only: ["media"]) }
    }
}
