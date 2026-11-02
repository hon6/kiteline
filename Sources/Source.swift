import Foundation

// MARK: - 数据模型

/// 一条 watcher 输出的会话快照，附带「来自哪个来源」的信息
struct SessionRecord {
    var sourceId: String
    var sourceName: String
    var kind: SourceKind
    var snapshot: SessionSnapshot

    /// 跨来源唯一键：来源 + 远端会话 id
    var key: String { "\(sourceId)#\(snapshot.sessionId)" }
}

/// watcher 输出的事件行
struct WatcherEvent {
    var kind: String
    var sessions: [SessionSnapshot]
    var host: String?
    var watcherVersion: String?
    var protocolVersion: Int?
    var message: String?
    /// 原始 JSON：entries / reset / response 这类事件直接转交下游
    var raw: [String: Any]

    init?(json: [String: Any]) {
        guard let kind = json["event"] as? String else { return nil }
        self.kind = kind
        self.raw = json
        self.host = json["host"] as? String
        self.watcherVersion = json["watcher"] as? String
        self.protocolVersion = json["protocol"] as? Int
        self.message = json["message"] as? String
        self.sessions = []
        if let raw = json["sessions"] as? [[String: Any]] {
            let decoder = JSONDecoder()
            self.sessions = raw.compactMap { dict in
                guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? decoder.decode(SessionSnapshot.self, from: data)
            }
        }
    }

    init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        self.init(json: object)
    }
}

/// 链路状态，用于菜单栏图标与排障
enum LinkState: Equatable {
    case stopped
    case connecting
    case live(host: String?, watcher: String?, sessionCount: Int)
    case failed(reason: String)

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    var shortLabel: String {
        switch self {
        case .stopped: return "未连接"
        case .connecting: return "连接中"
        case .live(let host, _, let count): return "\(host ?? "来源") 在线 · \(count) 会话"
        case .failed(let reason): return "连接失败：\(reason)"
        }
    }
}

/// 会话相对于上次观察的变化，用来决定是否提醒
enum SessionTransition {
    case appeared
    case needsAttention(reason: String)
    case concluded(message: String)
    /// 目标（/goal）达成、做不到、停下、出错中止
    case goalEnded(GoalSnapshot)
    case wentBusy
    case disappeared

    var shouldNotify: Bool {
        switch self {
        case .needsAttention, .concluded, .goalEnded: return true
        default: return false
        }
    }
}

// MARK: - 来源接口

protocol SourceConnectionDelegate: AnyObject {
    func source(_ source: SourceConnection, didChange state: LinkState)
    func source(_ source: SourceConnection, didReceive event: WatcherEvent)
    func source(_ source: SourceConnection, didLog message: String)
}

/// 一个被监听的来源：本机直起 watcher 子进程，或通过 SSH 读远端 watcher。
protocol SourceConnection: AnyObject {
    var id: String { get }
    var config: SourceConfig { get }
    var state: LinkState { get }
    var delegate: SourceConnectionDelegate? { get set }
    /// watcher 所在机器的家目录（hello 事件带来），用于拼路径
    var hostHome: String? { get }

    func start()
    func stop()
    /// 插件、开关变了，要换个 watcher 进程才载入：连着的会话照旧显示、不报离线；手上的请求先答完，
    /// 换进程期间的请求排队、新进程就绪再发（WatcherRPC.hold）。没在跑的（等着重连）下次起进程自然按新开关
    func reload()
    /// 经 watcher 的 stdin 发一个请求，等 stdout 上同 id 的 response。回调在主线程。
    func request(_ payload: [String: Any], timeout: TimeInterval,
                 completion: @escaping (Result<[String: Any], RemoteError>) -> Void)
}

/// watcher 双向通道上的请求/应答：请求写进 watcher 的 stdin，
/// 结果以 `{"event":"response","id":...}` 从 stdout 回来。本机与 SSH 两种来源共用。
final class WatcherRPC {
    typealias Completion = (Result<[String: Any], RemoteError>) -> Void

    private var pending: [String: (completion: Completion, timer: DispatchWorkItem)] = [:]
    /// 换 watcher 进程期间（reload）新来的请求先排着，新进程报 hello 再发
    private var held: [(id: Int, payload: [String: Any], deadline: Date, completion: Completion, timer: DispatchWorkItem)] = []
    private var holdUntil: Date?
    private var heldCounter = 0
    private var writer: FileHandle?
    private var counter = 0
    private let lock = NSLock()
    /// 写管道可能阻塞（几 MB 的图片经 ssh 慢慢送），不能占主线程
    private let writeQueue = DispatchQueue(label: "ccpulse.rpc.write")

    /// 进程（重新）启动时接上新的 stdin；进程退出时传 nil，挂起的请求全部失败
    func attach(_ handle: FileHandle?) {
        lock.lock()
        writer = handle
        lock.unlock()
        if handle == nil { failAll("watcher 通道已断开") }
    }

    /// 换进程（reload）期间：新请求排队，最多 seconds 秒；到期新进程还没就绪，排着的都算失败、调 expired
    func hold(for seconds: TimeInterval, expired: @escaping () -> Void) {
        lock.lock()
        holdUntil = Date().addingTimeInterval(seconds)
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let lapsed = self.holdUntil.map { $0 <= Date() } ?? false
            self.lock.unlock()
            guard lapsed else { return }   // 已经就绪（release 过）或又延长了
            self.release(failing: "来源未连接")
            expired()
        }
    }

    var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return holdUntil.map { $0 > Date() } ?? false
    }

    /// 新进程就绪：排着的请求照发；给了 failing 就都按失败回（新进程起不来、来源停了）
    func release(failing reason: String? = nil) {
        lock.lock()
        let items = held
        held.removeAll()
        holdUntil = nil
        lock.unlock()
        for item in items {
            item.timer.cancel()
            if let reason = reason {
                DispatchQueue.main.async { item.completion(.failure(RemoteError(reason))) }
            } else {
                send(item.payload, timeout: max(1, item.deadline.timeIntervalSinceNow), completion: item.completion)
            }
        }
    }

    /// 手上的请求都答完（最晚到 deadline）再做 then：换进程前用，别把正在答的请求掐断
    func drain(until deadline: Date, then: @escaping () -> Void) {
        lock.lock()
        let busy = !pending.isEmpty
        lock.unlock()
        guard busy, Date() < deadline else { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.drain(until: deadline, then: then)
        }
    }

    func send(_ payload: [String: Any], timeout: TimeInterval, completion: @escaping Completion) {
        lock.lock()
        if let until = holdUntil, until > Date() {
            heldCounter += 1
            let heldId = heldCounter
            let timer = DispatchWorkItem { [weak self] in
                self?.dropHeld(heldId, RemoteError("请求超时（\(Int(timeout)) 秒）"))
            }
            held.append((heldId, payload, Date().addingTimeInterval(timeout), completion, timer))
            lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
            return
        }
        counter += 1
        let requestId = "r\(counter)"
        let handle = writer
        lock.unlock()
        guard let writer = handle else {
            DispatchQueue.main.async { completion(.failure(RemoteError("来源未连接"))) }
            return
        }
        var body = payload
        body["id"] = requestId
        guard var data = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { completion(.failure(RemoteError("请求无法编码"))) }
            return
        }
        data.append(0x0A)

        let timer = DispatchWorkItem { [weak self] in
            self?.finish(requestId, .failure(RemoteError("请求超时（\(Int(timeout)) 秒）")))
        }
        lock.lock()
        pending[requestId] = (completion, timer)
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)

        writeQueue.async { [weak self] in
            do {
                try writer.write(contentsOf: data)
            } catch {
                self?.finish(requestId, .failure(RemoteError("写入 watcher 失败：\(error.localizedDescription)")))
            }
        }
    }

    /// 是 response 事件就消费掉并返回 true
    func consume(_ event: WatcherEvent) -> Bool {
        guard event.kind == "response", let requestId = event.raw["id"] as? String else { return false }
        if event.raw["ok"] as? Bool == true {
            finish(requestId, .success(event.raw))
        } else {
            finish(requestId, .failure(RemoteError(event.raw["error"] as? String ?? "watcher 返回失败")))
        }
        return true
    }

    func failAll(_ reason: String) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, entry) in all {
            entry.timer.cancel()
            DispatchQueue.main.async { entry.completion(.failure(RemoteError(reason))) }
        }
    }

    private func dropHeld(_ heldId: Int, _ error: RemoteError) {
        lock.lock()
        let item = held.firstIndex { $0.id == heldId }.map { held.remove(at: $0) }
        lock.unlock()
        guard let item = item else { return }
        DispatchQueue.main.async { item.completion(.failure(error)) }
    }

    private func finish(_ requestId: String, _ result: Result<[String: Any], RemoteError>) {
        lock.lock()
        let entry = pending.removeValue(forKey: requestId)
        lock.unlock()
        guard let entry = entry else { return }
        entry.timer.cancel()
        DispatchQueue.main.async { entry.completion(result) }
    }
}

/// 把 watcher 的 JSON Lines 解析成事件（本机与 SSH 两种来源共用同一套解析与拆行逻辑）
final class WatcherLineReader {
    private var buffer = Data()
    private let onEvent: (WatcherEvent) -> Void
    private let onGarbage: (String) -> Void

    init(onEvent: @escaping (WatcherEvent) -> Void, onGarbage: @escaping (String) -> Void) {
        self.onEvent = onEvent
        self.onGarbage = onGarbage
    }

    func feed(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            if let event = WatcherEvent(line: line) {
                onEvent(event)
            } else {
                let raw = String(data: line, encoding: .utf8) ?? "<binary>"
                onGarbage(String(raw.prefix(160)))
            }
        }
    }

    func reset() {
        buffer.removeAll()
    }
}
