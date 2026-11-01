import Foundation
import Observation

/// 会话里开着的一个终端：开在会话所在的电脑上（Remote-SSH 的会话就是那台服务器），目录是会话的工作目录（见 watcher 的 term）
struct TermInfo: Identifiable, Hashable {
    let id: String
    var shell: String
    var cwd: String
    var createdAt: Double

    init?(_ raw: Any?) {
        guard let raw = raw as? [String: Any], let id = raw["term"] as? String else { return nil }
        self.id = id
        shell = raw["shell"] as? String ?? ""
        cwd = raw["cwd"] as? String ?? ""
        createdAt = raw["createdAt"] as? Double ?? 0
    }

    /// 标签上的名字：shell 名（zsh、bash、pwsh）
    var name: String {
        let base = shell.replacingOccurrences(of: ".exe", with: "")
        return base.isEmpty ? "shell" : base
    }
}

/// 显示某个终端的视图（SwiftTerm）：收输出
@MainActor
protocol TermSink: AnyObject {
    func feed(_ bytes: ArraySlice<UInt8>)
    /// 接不上了（中间漏了一段，电脑上留的输出也不够补）：清屏，接着从电脑上留的那段重放
    func restart()
}

/// 会话里的终端：开、关、按键、改大小经 /api/term 发给电脑；输出从实时连接来（term 事件，seq = 这段在整条输出里的字节位置），
/// 按位置接起来喂给正在显示它的视图，漏了就向电脑要最近的输出补上
@MainActor @Observable
final class TerminalStore {
    /// 会话 key → 开着的终端（按开的先后）；没拉过的会话没有
    private(set) var lists: [String: [TermInfo]] = [:]
    /// 会话 key → 正在看的那个
    var selected: [String: String] = [:]
    /// 正在开终端的会话
    private(set) var opening: Set<String> = []

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var feeds: [String: Feed] = [:]
    @ObservationIgnored private var outbox: [String: (key: String, bytes: [UInt8])] = [:]
    @ObservationIgnored private var sending: Set<String> = []
    @ObservationIgnored private var resizes: [String: Task<Void, Never>] = [:]

    /// 一个终端的输出接到哪了
    private final class Feed {
        let key: String
        weak var sink: TermSink?
        /// 下一个要的字节位置；-1 = 还在拉电脑上留的那段，期间到的先攒着
        var next = -1
        var early: [(seq: Int, bytes: [UInt8])] = []
        init(key: String, sink: TermSink) { self.key = key; self.sink = sink }
    }

    /// 角标：拉过列表的用手里的（刚开、刚关立刻变），没拉过的用电脑报的
    func count(_ session: SessionInfo) -> Int { lists[session.key]?.count ?? session.terminals }

    // MARK: 开、关、列

    func refresh(_ key: String) async {
        guard let api = model?.api else { return }
        do {
            let reply = try await api.post("/api/term", ["key": key], body: ["op": "list"])
            let terms = (reply["terms"] as? [Any] ?? []).compactMap(TermInfo.init)
            lists[key] = terms
            if !terms.contains(where: { $0.id == selected[key] }) { selected[key] = terms.last?.id }
        } catch {
            model?.flash(error.localizedDescription)
        }
    }

    @discardableResult
    func open(_ key: String, cols: Int = 80, rows: Int = 24) async -> TermInfo? {
        guard let api = model?.api, !opening.contains(key) else { return nil }
        opening.insert(key)
        defer { opening.remove(key) }
        do {
            let reply = try await api.post("/api/term", ["key": key], body: ["op": "open", "cols": cols, "rows": rows])
            guard let term = TermInfo(reply["term"]) else { return nil }
            var list = lists[key] ?? []
            if !list.contains(where: { $0.id == term.id }) { list.append(term) }
            lists[key] = list
            selected[key] = term.id
            return term
        } catch {
            model?.flash(error.localizedDescription)
            return nil
        }
    }

    func close(_ key: String, _ id: String) async {
        guard let api = model?.api else { return }
        do {
            try await api.post("/api/term", ["key": key], body: ["op": "close", "term": id])
            remove(key, id)
        } catch {
            model?.flash(error.localizedDescription)
            await refresh(key)
        }
    }

    private func remove(_ key: String, _ id: String) {
        guard var list = lists[key], let index = list.firstIndex(where: { $0.id == id }) else { return }
        list.remove(at: index)
        lists[key] = list
        if selected[key] == id { selected[key] = list.indices.contains(index) ? list[index].id : list.last?.id }
        feeds[id] = nil
        outbox[id] = nil
    }

    // MARK: 输出

    /// 视图出现：先要电脑上留的最近一段输出把画面接上，之后实时的按位置接着喂
    func attach(_ key: String, _ id: String, sink: TermSink) {
        if let feed = feeds[id], feed.sink === sink { return }
        feeds[id] = Feed(key: key, sink: sink)
        Task { await resync(id) }
    }

    func detach(_ id: String, sink: TermSink) {
        if feeds[id]?.sink === sink { feeds[id] = nil }
    }

    /// 实时连接上的 term / term_exit
    func receive(_ event: String, _ data: Data) {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = raw["term"] as? String, let key = raw["key"] as? String else { return }
        if event == "term_exit" {
            remove(key, id)
            return
        }
        guard let feed = feeds[id], let seq = raw["seq"] as? Int,
              let chunk = (raw["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
        let bytes = [UInt8](chunk)
        if feed.next < 0 {
            feed.early.append((seq, bytes))
        } else {
            take(feed, id, seq, bytes)
        }
    }

    private func take(_ feed: Feed, _ id: String, _ seq: Int, _ bytes: [UInt8]) {
        let end = seq + bytes.count
        guard end > feed.next else { return }   // 重放过的
        guard seq <= feed.next else {
            // 中间漏了一段（实时连接断过）：向电脑要
            feed.next = -1
            feed.early = [(seq, bytes)]
            Task { await resync(id) }
            return
        }
        feed.sink?.feed(bytes[(feed.next - seq)...])
        feed.next = end
    }

    /// 拉电脑上留的最近一段输出：接得上就补上缺的，接不上清屏重放
    private func resync(_ id: String) async {
        guard let feed = feeds[id], let api = model?.api else { return }
        do {
            let reply = try await api.post("/api/term", ["key": feed.key], body: ["op": "read", "term": id])
            guard feeds[id] === feed, let start = reply["seq"] as? Int,
                  let data = (reply["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
            let bytes = [UInt8](data)
            let have = feed.next
            if have >= start, have <= start + bytes.count {
                feed.sink?.feed(bytes[(have - start)...])
            } else {
                if have >= 0 { feed.sink?.restart() }
                feed.sink?.feed(bytes[...])
            }
            feed.next = start + bytes.count
            let early = feed.early
            feed.early = []
            for (seq, chunk) in early.sorted(by: { $0.seq < $1.seq }) { take(feed, id, seq, chunk) }
        } catch {
            feed.next = max(feed.next, 0)
            if (error as? APIError)?.message.contains("终端已关闭") == true { remove(feed.key, id) }
        }
    }

    /// 实时连接断过又连上：正在看的终端都补一次
    func reconnected() {
        for (id, feed) in feeds where feed.next >= 0 {
            Task { await resync(id) }
        }
    }

    // MARK: 按键、大小

    /// 按键按顺序发：上一批还没回来时新按的攒着，回来了一起发（不会乱序，打字快也不会一键一个请求）
    func send(_ key: String, _ id: String, _ bytes: [UInt8]) {
        var pending = outbox[id] ?? (key, [])
        pending.bytes += bytes
        outbox[id] = pending
        guard !sending.contains(id) else { return }
        sending.insert(id)
        Task {
            defer { sending.remove(id) }
            while let batch = outbox[id], !batch.bytes.isEmpty, let api = model?.api {
                outbox[id] = (batch.key, [])
                do {
                    try await api.post("/api/term", ["key": batch.key],
                                       body: ["op": "input", "term": id, "data": Data(batch.bytes).base64EncodedString(), "base64": true])
                } catch {
                    outbox[id] = nil
                    model?.flash(error.localizedDescription)
                    if (error as? APIError)?.message.contains("终端已关闭") == true { remove(batch.key, id) }
                    return
                }
            }
        }
    }

    /// 视图大小变了：停手 0.15 秒再告诉电脑（拖面板高度时不连发）
    func resize(_ key: String, _ id: String, cols: Int, rows: Int) {
        resizes[id]?.cancel()
        resizes[id] = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let api = model?.api else { return }
            _ = try? await api.post("/api/term", ["key": key], body: ["op": "resize", "term": id, "cols": cols, "rows": rows])
        }
    }
}
