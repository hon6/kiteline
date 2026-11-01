import CryptoKit
import Foundation
#if canImport(TarsP2P)
import TarsP2P
#else
import KitelineKit

// 开源版没有 p2p/（远程访问组件不开源）：换成替身，远程访问显示不可用，手机只能在同一个网络里连
private let p2pMissing = L("这个版本不含远程访问组件，手机需要和电脑在同一个网络里")
private func tars_p2p_start(_ keyPath: String, _ relay: String) -> UnsafeMutablePointer<CChar>? { strdup(p2pMissing) }
private func tars_p2p_serve(_ target: String) -> UnsafeMutablePointer<CChar>? { strdup(p2pMissing) }
private func tars_p2p_status() -> UnsafeMutablePointer<CChar>? { nil }
private func tars_p2p_logs() -> UnsafeMutablePointer<CChar>? { nil }
private func tars_p2p_allow(_ ids: String) {}
private func tars_p2p_pairing(_ seconds: Int32) {}
private func tars_p2p_stop() {}
private func tars_p2p_free(_ p: UnsafeMutablePointer<CChar>) { free(p) }
#endif

/// 远程访问（点对点）：手机不在同一个 Wi-Fi 时也能连这台 Mac，不需要任何账号。
///
/// 每台设备有自己的密钥，公钥就是它的地址。手机用 6 位码（或扫码）绑定时报上自己的公钥、拿到 Mac 的公钥，
/// 之后不管在哪：先打洞直连，打不通走中继（默认 Kiteline 自己的中继，设置里可换成自建的），全程端到端加密。
/// Mac 只接受绑定过的手机（设备记录里的 p2pId），每条连接转给本机的 HTTPS 服务。内核是 p2p/（iroh 编成的静态库）。
final class P2P {
    static let shared = P2P()

    struct Status: Decodable, Equatable {
        var state: String
        var id: String?
        var relay: String?
        var addrs: [String]?
        var error: String?

        var online: Bool { state == "online" }
    }

    private(set) var status = Status(state: "stopped")
    /// 状态变了（设置窗口刷新用）
    var onChange: ((Status) -> Void)?
    private var poller: DispatchSourceTimer?

    private var keyPath: String { AppConfig.directoryURL.appendingPathComponent("p2p.key").path }

    func start(relay: String, httpsPort: Int) {
        stop()
        if let error = Self.take(tars_p2p_start(keyPath, relay.trimmingCharacters(in: .whitespaces))) {
            update(Status(state: "error", error: error))
            return
        }
        refreshAllowlist()
        if let error = Self.take(tars_p2p_serve("127.0.0.1:\(httpsPort)")) {
            update(Status(state: "error", error: error))
            return
        }
        refresh()
        poll(every: 2)
        Log.write("远程访问启动（中继：\(relay.isEmpty ? "iroh 公共中继" : relay)）")
    }

    func stop() {
        poller?.cancel()
        poller = nil
        tars_p2p_stop()
        update(Status(state: "stopped"))
    }

    /// 按设备记录更新「允许连进来的手机」
    func refreshAllowlist() {
        tars_p2p_allow(DeviceStore.shared.p2pIds.joined(separator: ","))
    }

    /// 显示配对码（「手机访问」页）时调：接下来 10 分钟放没绑定的手机经中继连进来配对（配对本身照样要验证码 / 扫码里的令牌），
    /// 并把验证码的哈希和本机公钥报给 Kiteline 服务器——手机不在同一个 Wi-Fi、或者局域网不通时，输验证码就能查到这台 Mac。
    /// 服务器回 409（这个验证码正被别的 Mac 占着）就换一个验证码（「手机访问」页会跟着显示新的）
    func openPairing(code: String?) {
        tars_p2p_pairing(600)
        // 只开窗口（扫码配对用的一次性令牌）：不用报服务器
        guard let code else { return }
        Task {
            // 远程访问刚启动、还没拿到公钥：等一会儿
            var current = await MainActor.run { self.status }
            for _ in 0..<20 where current.id?.isEmpty ?? true {
                try? await Task.sleep(for: .milliseconds(500))
                current = await MainActor.run { self.status }
            }
            guard let id = current.id, !id.isEmpty, let relay = current.relay, !relay.isEmpty,
                  AppState.shared.mobile.pairingCode == code else { return }
            let key = SHA256.hash(data: Data("kiteline-pair/\(code)".utf8)).map { String(format: "%02x", $0) }.joined()
            let gateway = ProcessInfo.processInfo.environment["CCPULSE_PAIR_GATEWAY"] ?? "https://tars.betac.cn/pair"
            var request = URLRequest(url: URL(string: gateway + "/announce")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: String] = ["key": key, "id": id, "relay": relay,
                                          "fp": LocalTLS.caFingerprint ?? ""]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (_, response) = try? await URLSession.shared.data(for: request) else {
                Log.write("配对码没报上 Kiteline 服务器（连不上）：手机只能在同一个 Wi-Fi 里输验证码")
                return
            }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            if httpStatus == 409 {
                await MainActor.run { _ = AppState.shared.mobile.newPairingCode() }
            } else if httpStatus != 200 {
                Log.write("配对码没报上 Kiteline 服务器（\(httpStatus)）：手机只能在同一个 Wi-Fi 里输验证码")
            }
        }
    }

    /// 给绑定过的手机：Mac 的公钥、中继、局域网直连地址
    var joinInfo: [String: Any]? {
        guard let id = status.id, !id.isEmpty else { return nil }
        return ["id": id, "relay": status.relay ?? "", "addrs": status.addrs ?? []]
    }

    var logs: String { Self.take(tars_p2p_logs()) ?? "" }

    /// 上次抄到 ccpulse.log 的最后一行
    private var lastMirrored: String?

    /// 手机经远程访问连进来、被拒、没连成，也写进 ccpulse.log：点对点自己的日志只在内存里，App 一重启就没了，
    /// 查「手机连不上」时看不到当时手机有没有连过来
    private func mirrorLogs() {
        let lines = logs.split(separator: "\n").map(String.init)
        let start = lastMirrored.flatMap { last in lines.lastIndex(of: last).map { $0 + 1 } } ?? 0
        for line in lines[min(start, lines.count)...]
        where ["手机连进来", "拒绝", "没建成", "连不上本机服务"].contains(where: { line.contains($0) }) {
            Log.write("远程访问：\(line)")
        }
        lastMirrored = lines.last ?? lastMirrored
    }

    private func poll(every seconds: Double) {
        poller?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        poller = timer
    }

    private func refresh() {
        mirrorLogs()
        guard let text = Self.take(tars_p2p_status()), let data = text.data(using: .utf8),
              let next = try? JSONDecoder().decode(Status.self, from: data) else { return }
        if next.online && !status.online {
            Log.write("远程访问已连上中继：\(next.relay ?? "-")")
            poll(every: 30)   // 连上以后不用勤着查
        }
        update(next)
    }

    private func update(_ next: Status) {
        guard next != status else { return }
        status = next
        onChange?(next)
    }

    /// 取出库返回的字符串并释放
    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { tars_p2p_free(p) }
        return String(cString: p)
    }
}
