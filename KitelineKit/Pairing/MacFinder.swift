import Foundation
import Network
import Observation

/// 在局域网上找开着 Kiteline 的 Mac（Mac 用 Bonjour 宣告 _tars._tcp），找到了只输 6 位配对码就能配上
@MainActor
@Observable
final class MacFinder {
    struct Found: Identifiable, Hashable {
        var name: String
        /// Mac 本机根证书指纹，配对时核对
        var fingerprint: String?
        fileprivate var endpoint: NWEndpoint
        var id: String { name }
    }

    private(set) var macs: [Found] = []
    /// 找了一会儿了（没找到就该让用户手输地址了）
    private(set) var settled = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_tars._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Found? in
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let txt) = result.metadata, txt["role"] == "mac" else { return nil }
                return Found(name: name, fingerprint: txt["fp"], endpoint: result.endpoint)
            }
            Task { @MainActor in self?.macs = found.sorted { $0.name < $1.name } }
        }
        browser.start(queue: .main)
        self.browser = browser
        Task {
            try? await Task.sleep(for: .seconds(3))
            settled = true
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Bonjour 名字 → https://IP:端口（连一下，看实际连到的地址；只要 IPv4，免得拿到带网卡后缀的 IPv6 链路地址）
    func address(of mac: Found) async -> URL? {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: mac.endpoint, using: parameters)
        return await withCheckedContinuation { continuation in
            let once = Once(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(Self.url(connection.currentPath?.remoteEndpoint))
                case .failed, .cancelled: once.finish(nil)
                default: break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { once.finish(nil) }
        }
    }

    private nonisolated static func url(_ endpoint: NWEndpoint?) -> URL? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let ip): text = "\(ip)".components(separatedBy: "%").first ?? "\(ip)"
        case .name(let name, _): text = name
        default: text = "\(host)"
        }
        return URL(string: "https://\(text):\(port.rawValue)")
    }

    /// 连接的回调和超时都在主队列上，谁先到算谁的，只回一次
    private final class Once: @unchecked Sendable {
        private let connection: NWConnection
        private var continuation: CheckedContinuation<URL?, Never>?
        init(connection: NWConnection, continuation: CheckedContinuation<URL?, Never>) {
            self.connection = connection
            self.continuation = continuation
        }
        func finish(_ url: URL?) {
            guard let continuation else { return }
            self.continuation = nil
            connection.cancel()
            continuation.resume(returning: url)
        }
    }
}

extension Pairing {
    /// 局域网里找到的 Mac + 6 位配对码
    static func pair(found mac: MacFinder.Found, base: URL, code: String) async throws -> PairedMac {
        try await pair(base: base, code: code, fingerprint: mac.fingerprint)
    }
}
