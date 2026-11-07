import Foundation

/// 开源版不含这个入口：替身（start 直接报错，入口不启动；其余代码照常编译）
final class MPGate {
    static var remoteAllowed: Bool { false }
    struct Keys { var publicB64URL: String { "" } }
    let keys = Keys()
    private(set) var port: UInt16 = 0
    var relay: MPRelayLink?

    init(route: @escaping (HTTPRequest, @escaping (HTTPServer.Reply) -> Void) -> Void, hostName: @escaping () -> String) {}

    func start(host: String, port: UInt16) throws {
        throw NSError(domain: "MPGate", code: 1, userInfo: [NSLocalizedDescriptionKey: "not included in this build"])
    }

    func stop() {}
}

final class MPRelayLink {
    init?(gate: MPGate, relay: String) { return nil }
    func start() {}
    func stop() {}
}
