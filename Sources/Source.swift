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
    case wentBusy
    case disappeared

    var shouldNotify: Bool {
        switch self {
        case .needsAttention, .concluded: return true
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
    /// 经 watcher 的 stdin 发一个请求，等 stdout 上同 id 的 response。回调在主线程。
    func request(_ payload: [String: Any], timeout: TimeInterval,
                 completion: @escaping (Result<[String: Any], RemoteError>) -> Void)
}

/// watcher 双向通道上的请求/应答：请求写进 watcher 的 stdin，
/// 结果以 `{"event":"response","id":...}` 从 stdout 回来。本机与 SSH 两种来源共用。
final class WatcherRPC {
    typealias Completion = (Result<[String: Any], RemoteError>) -> Void

    private var pending: [String: (completion: Completion, timer: DispatchWorkItem)] = [:]
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

    func send(_ payload: [String: Any], timeout: TimeInterval, completion: @escaping Completion) {
        lock.lock()
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
