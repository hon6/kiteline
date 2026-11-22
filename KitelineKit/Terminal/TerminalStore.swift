import Foundation
import Observation

/// 会话里开着的一个终端：一般开在会话所在的电脑上（Remote-SSH 的会话就是那台服务器），目录是会话的工作目录（见 watcher 的 term）；
/// agent 用 term run 跑的命令也是一个终端（run 有值），可能开在别的电脑上（device 写着是哪台）
struct TermInfo: Identifiable, Hashable {
    let id: String
    var shell: String
    var cwd: String
    var createdAt: Double
    /// 终端实际所在的设备（电脑端补的：本机写电脑名、远端写来源名）
    var device: String
    /// agent 跑的命令（term run）；普通终端为空
    var run: String
    var title: String
    /// 命令跑完了（标签留着回看）
    var ended: Bool
    var exitCode: Int?
    /// 后台运行会话的「claude」主终端：接的就是 Claude 本身，不给关（关了也只是断开，但 × 容易让人以为会结束 Claude）
    var hosted: Bool
    /// 用户起的名字（重命名）、颜色、在列表里的位置、拆分组（同 VS Code 的终端列表；电脑上的 watcher 记着，各端一致）
    var customName: String
    var color: String
    var order: Double
    var group: String?

    init?(_ raw: Any?) {
        guard let raw = raw as? [String: Any], let id = raw["term"] as? String else { return nil }
        self.id = id
        shell = raw["shell"] as? String ?? ""
        cwd = raw["cwd"] as? String ?? ""
        createdAt = raw["createdAt"] as? Double ?? 0
        device = raw["device"] as? String ?? raw["host"] as? String ?? ""
        run = raw["run"] as? String ?? ""
        title = raw["title"] as? String ?? ""
        ended = raw["ended"] != nil && !(raw["ended"] is NSNull)
        exitCode = raw["exitCode"] as? Int
        hosted = raw["hosted"] as? Bool ?? false
        customName = raw["name"] as? String ?? ""
        color = raw["color"] as? String ?? ""
        order = (raw["order"] as? Double) ?? (raw["order"] as? Int).map(Double.init) ?? createdAt
        group = (raw["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var isRun: Bool { !run.isEmpty }

    /// 标签上的名字：agent 跑的用命令名，普通终端用 shell 名（zsh、bash、pwsh）
    var name: String {
        if !customName.isEmpty { return customName }
        if isRun { return title.isEmpty ? "run" : title }
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
    /// 这块屏现在的行列数（还没排好版时为空）
    var grid: (cols: Int, rows: Int)? { get }
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
    /// 会话 key → 会话所在的设备名（新开的终端开在这台上；电脑端列表里给的）
    private(set) var devices: [String: String] = [:]

    @ObservationIgnored weak var model: AppModel?
    /// 还没开出来的会话（Mac 新会话标签：会话编号预先定好）→ 终端开在哪个目录：电脑端查不到这个会话时按它开
    @ObservationIgnored var pendingCwd: [String: String] = [:]

    private func withCwd(_ key: String, _ body: [String: Any]) -> [String: Any] {
        guard let cwd = pendingCwd[key] else { return body }
        var body = body
        body["cwd"] = cwd
        return body
    }
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
            let reply = try await api.post("/api/term", ["key": key], body: withCwd(key, ["op": "list"]))
            let terms = (reply["terms"] as? [Any] ?? []).compactMap(TermInfo.init)
            lists[key] = terms
            if let device = reply["device"] as? String ?? reply["host"] as? String, !device.isEmpty { devices[key] = device }
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
            let reply = try await api.post("/api/term", ["key": key], body: withCwd(key, ["op": "open", "cols": cols, "rows": rows]))
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

    // MARK: 改名、颜色、排序、拆分（同 VS Code 的终端列表）

    func rename(_ key: String, _ id: String, _ name: String) async {
        await meta(key, ["op": "rename", "term": id, "name": name])
    }

    func setColor(_ key: String, _ id: String, _ color: String) async {
        await meta(key, ["op": "color", "term": id, "color": color])
    }

    /// 拖到 target 前面（target 为空 = 放到最后）：位置取两个邻居中间的值，先在本地挪好再告诉电脑
    func move(_ key: String, _ id: String, before target: String?) async {
        guard var list = lists[key], let from = list.firstIndex(where: { $0.id == id }), id != target else { return }
        let moving = list.remove(at: from)
        let at = target.flatMap { t in list.firstIndex { $0.id == t } } ?? list.count
        let previous = at > 0 ? list[at - 1].order : nil
        let next = at < list.count ? list[at].order : nil
        let order: Double = switch (previous, next) {
        case let (p?, n?): (p + n) / 2
        case let (p?, nil): p + 1000
        case let (nil, n?): n - 1000
        default: moving.order
        }
        var moved = moving
        moved.order = order
        list.insert(moved, at: at)
        lists[key] = list
        await meta(key, ["op": "order", "term": id, "order": order])
    }

    /// 拆分：在它旁边再开一个，并排显示（同一组）
    func split(_ key: String, _ id: String, cols: Int, rows: Int) async {
        guard let api = model?.api else { return }
        do {
            let reply = try await api.post("/api/term", ["key": key], body: withCwd(key, ["op": "split", "term": id, "cols": cols, "rows": rows]))
            guard let term = TermInfo(reply["term"]) else { return }
            upsert(key, term)
            selected[key] = term.id
            await refresh(key)   // 原来那个也进了组
        } catch {
            model?.flash(error.localizedDescription)
        }
    }

    private func meta(_ key: String, _ body: [String: Any]) async {
        guard let api = model?.api else { return }
        do {
            let reply = try await api.post("/api/term", ["key": key], body: body)
            if let term = TermInfo(reply["term"]) { upsert(key, term) }
        } catch {
            model?.flash(error.localizedDescription)
            await refresh(key)
        }
    }

    /// 换上新信息、按位置重新排（拆分组里的挨在一起）
    private func upsert(_ key: String, _ term: TermInfo) {
        guard var list = lists[key] else { return }
        if let index = list.firstIndex(where: { $0.id == term.id }) { list[index] = term } else { list.append(term) }
        lists[key] = list.sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    // MARK: 输出

    /// 视图出现：先要电脑上留的最近一段输出把画面接上，之后实时的按位置接着喂
    func attach(_ key: String, _ id: String, sink: TermSink) {
        if let feed = feeds[id], feed.sink === sink { return }
        feeds[id] = Feed(key: key, sink: sink)
        Task {
            await resync(id)
            await takeOver(key, id)
        }
    }

    /// 接上画面后把终端尺寸设成这块屏的大小，再把行数改一下又改回来，逼程序整屏重画。
    /// 同一个终端可能几端在看（后台运行的「claude」终端电脑上也开着）：它按最后设的那个宽度排版，
    /// 手机接上时回放的旧输出和 Claude 只重画变化那几行的做法叠在一起，窄屏上就是一团错位的字（11-16 截图）
    func takeOver(_ key: String, _ id: String) async {
        for _ in 0..<20 where feeds[id]?.sink?.grid == nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard let grid = feeds[id]?.sink?.grid, grid.rows > 2, let api = model?.api else { return }
        resizes[id]?.cancel()
        _ = try? await api.post("/api/term", ["key": key], body: ["op": "resize", "term": id, "cols": grid.cols, "rows": grid.rows - 1])
        try? await Task.sleep(for: .milliseconds(250))
        _ = try? await api.post("/api/term", ["key": key], body: ["op": "resize", "term": id, "cols": grid.cols, "rows": grid.rows])
    }

    func detach(_ id: String, sink: TermSink) {
        if feeds[id]?.sink === sink { feeds[id] = nil }
    }

    /// 实时连接上的 term / term_exit
    func receive(_ event: String, _ data: Data) {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = raw["term"] as? String, let key = raw["key"] as? String else { return }
        if event == "term_meta" {
            // 别的端改了名字、颜色、位置、拆分组
            if lists[key] != nil, let term = TermInfo(raw["info"]) { upsert(key, term) }
            return
        }
        if event == "term_open" {
            // agent 用 term run 新开的：面板拉过列表的直接多一个标签（没在看别的终端就切过去）
            guard lists[key] != nil, let term = TermInfo(raw["info"]) else { return }
            upsert(key, term)
            if selected[key] == nil { selected[key] = id }
            return
        }
        if event == "term_exit" {
            if raw["keep"] as? Bool == true, let term = TermInfo(raw["info"]),
               let index = lists[key]?.firstIndex(where: { $0.id == id }) {
                lists[key]?[index] = term   // 跑完的命令：标签留着，标上退出码
            } else if raw["keep"] as? Bool != true {
                remove(key, id)
            }
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
            Task {
                await resync(id)
                await takeOver(feed.key, id)
            }
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
