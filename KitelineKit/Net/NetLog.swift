import Foundation

/// 连接记录：网络变化、选路、换路、实时连接断开 / 恢复、远程访问的状态，一行一条追加到 App 的 Documents/net-log.jsonl，
/// 远程访问自己的日志（p2p/）同时存到 Documents/p2p-log.txt。只在 iPhone 调试版里记（上架版、Mac 版里什么都不做）。
/// 换网络后连不上时用 `xcrun devicectl device copy from … --domain-type appDataContainer --source Documents/net-log.jsonl` 取回来逐秒看
enum NetLog {
    static func note(_ event: String, _ fields: [String: Any] = [:]) {
        #if DEBUG && os(iOS) && !KITELINE_MAC
        var record = fields
        record["ev"] = event
        record["t"] = stamp.string(from: Date())
        queue.async { append(record) }
        #endif
    }

    /// 远程访问的日志存一份（断开、换路时调）
    static func saveP2PLogs() {
        #if DEBUG && os(iOS) && !KITELINE_MAC
        Task { @MainActor in
            let text = PhoneP2P.logs
            queue.async {
                guard let folder else { return }
                try? text.write(to: folder.appendingPathComponent("p2p-log.txt"), atomically: true, encoding: .utf8)
            }
        }
        #endif
    }

    #if DEBUG && os(iOS) && !KITELINE_MAC
    private static let queue = DispatchQueue(label: "kiteline.netlog")
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private static var folder: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }

    private static func append(_ record: [String: Any]) {
        guard let folder, let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let url = folder.appendingPathComponent("net-log.jsonl")
        // 超过 2 MB 就把旧的挪到 .old，只留两份
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            let old = folder.appendingPathComponent("net-log.old.jsonl")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }
    #endif
}
