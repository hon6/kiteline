import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct PairingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 扫到 / 粘贴的配对链接：http://192.168.1.10:8765/?t=<主令牌>&fp=<根证书指纹>[&id=<Mac 点对点公钥>&r=<中继>]，
/// 也接受手输的「192.168.1.10」。带了 id 的（Mac 开着远程访问）局域网不通时可以经中继配
struct PairingLink {
    var base: URL
    var token: String?
    var fingerprint: String?
    var remote: RemoteInfo?

    init?(_ text: String) {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedScheme = raw.contains("://")
        if !typedScheme { raw = "https://" + raw }
        guard var parts = URLComponents(string: raw), let host = parts.host, !host.isEmpty else { return nil }
        let items = parts.queryItems ?? []
        token = items.first { $0.name == "t" }?.value
        fingerprint = items.first { $0.name == "fp" }?.value
        if let id = items.first(where: { $0.name == "id" })?.value, id.count == 64 {
            remote = RemoteInfo(macId: id, relay: items.first { $0.name == "r" }?.value ?? "", addrs: [])
        }
        // 网页用 http 端口（默认 8765）；App 一律走 HTTPS，端口是 http 端口 + 1。只输了地址就用默认的 8766
        if parts.scheme == "http" {
            parts.scheme = "https"
            parts.port = (parts.port ?? 8765) + 1
        } else if !typedScheme, parts.port == nil {
            parts.port = 8766
        }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { return nil }
        base = url
    }
}

enum Pairing {
    /// Mac「设置 → 设备」里显示的名字
    static var deviceName: String {
        #if canImport(UIKit)
        "Kiteline App（\(UIDevice.current.model)）"
        #else
        "Kiteline App"
        #endif
    }

    /// 扫码 / 粘贴链接：链接里是主令牌，用它给这台手机登记一把自己的设备令牌
    static func pair(_ link: PairingLink) async throws -> PairedMac {
        guard let master = link.token, !master.isEmpty else {
            throw PairingError(L("链接中缺少配对令牌。请扫描电脑上 Kiteline「手机访问」中的二维码。"))
        }
        let client = MacClient(expecting: link.fingerprint)
        defer { client.close() }
        let base = try await reach(client, link, token: master)
        let info = try await client.json(base.appending(path: "api/info"), token: master)
        var token = master
        if !master.hasPrefix("d") {
            let reply = try await client.json(base.appending(path: "api/devices/register"), method: "POST",
                                              token: master, body: ["name": deviceName])
            token = reply["token"] as? String ?? master
        }
        return PairedMac(name: info["host"] as? String ?? L("电脑"), addresses: addresses(link.base, info),
                         token: token, caCertificate: client.captured,
                         remote: await remote(client, base, token: token))
    }

    /// 扫码：局域网和远程访问（链接里带了 Mac 的点对点公钥时）一起试，谁先通走谁。Mac 回了错误（令牌不对）直接报
    private static func reach(_ client: MacClient, _ link: PairingLink, token: String) async throws -> URL {
        guard let remote = link.remote, await MainActor.run(body: { PhoneP2P.available }) else { return link.base }
        let results = AsyncStream<Result<URL, Error>> { continuation in
            let lan = Task {
                do {
                    _ = try await client.json(link.base.appending(path: "api/ping"), token: token)
                    continuation.yield(.success(link.base))
                } catch { continuation.yield(.failure(error)) }
            }
            let relay = Task {
                do {
                    guard let local = await PhoneP2P.shared.connect(remote) else { throw PairingError(L("远程访问未能启动")) }
                    _ = try await client.json(local.appending(path: "api/ping"), token: token)
                    continuation.yield(.success(local))
                } catch { continuation.yield(.failure(error)) }
            }
            continuation.onTermination = { _ in lan.cancel(); relay.cancel() }
        }
        var errors: [Error] = []
        for await result in results {
            switch result {
            case .success(let url): return url
            case .failure(let error):
                if error is APIError { throw error }
                errors.append(error)
                if errors.count == 2 { throw errors[0] }
            }
        }
        throw errors.first ?? PairingError(L("无法连接电脑"))
    }

    /// 验证码配对：先按 lan 走局域网（局域网里找到了 Mac、或者填了地址）；连不上（不是 Mac 回了错）、或者没有 lan，
    /// 就凭验证码到 Kiteline 服务器上查到这台 Mac，经点对点（打不通走中继）连过去配
    /// status：进度提示（「请在 Mac 上点允许」），配对页显示
    static func pair(code: String, status: (@Sendable (String) -> Void)? = nil,
                     lan: (() async throws -> PairedMac)?) async throws -> PairedMac {
        var lanError: Error?
        if let lan {
            do { return try await lan() } catch let error as APIError { throw error } catch { lanError = error }
        }
        do {
            return try await pairViaRelay(code: code, status: status)
        } catch let error as APIError {
            throw error
        } catch {
            // 两条路都不通：有局域网的错误就报它（更具体），没有就报中继这边的
            throw lanError ?? error
        }
    }

    /// 经中继配：查 Mac → 开远程访问 → 在 https://127.0.0.1:端口 上用验证码换令牌。
    /// Mac 会弹窗问「是否允许这台手机配对」，点了「允许」才配上：验证码输错一位碰巧撞上别人 Mac 上的码，也配不进去
    private static func pairViaRelay(code: String, status: (@Sendable (String) -> Void)?) async throws -> PairedMac {
        guard await MainActor.run(body: { PhoneP2P.available }) else { throw PairingError("未发现电脑，请手动输入电脑的地址") }
        let (info, fingerprint) = try await findMac(code: code)
        guard let local = await PhoneP2P.shared.connect(info) else {
            throw PairingError(L("已找到电脑，但无法经中继连接。请确认电脑上的 Kiteline 正在运行，且已开启远程访问。"))
        }
        status?(L("已找到电脑，请在电脑上点「允许」完成配对"))
        return try await pair(base: local, code: code, fingerprint: fingerprint, viaRelay: true)
    }

    /// 凭验证码查 Mac：Mac 显示验证码时把它的哈希和自己的点对点公钥报给 Kiteline 服务器（只存 10 分钟）
    private static func findMac(code: String) async throws -> (RemoteInfo, String?) {
        let key = SHA256.hash(data: Data("kiteline-pair/\(code)".utf8)).map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: URL(string: "https://tars.betac.cn/pair/find?key=\(key)")!)
        request.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PairingError(L("局域网中未发现电脑，且无法连接 Kiteline 服务器，请检查手机网络。"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200:
            guard let id = reply["id"] as? String, id.count == 64 else { break }
            let info = RemoteInfo(macId: id, relay: reply["relay"] as? String ?? "", addrs: [])
            return (info, (reply["fp"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        case 429:
            throw PairingError(L("尝试过于频繁，请一分钟后重试。"))
        case 404:
            throw PairingError(L("未找到与该配对码对应的电脑。请核对电脑上显示的配对码（10 分钟内有效），并确认电脑已开启远程访问。"))
        default:
            break
        }
        throw PairingError(L("Kiteline 服务器暂时异常（%@），请稍后重试，或将手机与电脑连接至同一 Wi-Fi。", "\(status)"))
    }

    /// 手输地址 + Mac 上显示的 6 位配对码
    static func pair(address: String, code: String) async throws -> PairedMac {
        guard let link = PairingLink(address) else { throw PairingError(L("地址格式不正确，请输入电脑的 IP 地址，例如 192.168.1.10")) }
        return try await pair(base: link.base, code: code, fingerprint: nil)
    }

    /// 6 位配对码换设备令牌。fingerprint：局域网宣告里带的 Mac 根证书指纹，有就核对。
    /// 经中继配时（viaRelay）Mac 要弹窗让人点「允许」，等得久一些
    static func pair(base: URL, code: String, fingerprint: String?, viaRelay: Bool = false) async throws -> PairedMac {
        let client = MacClient(expecting: fingerprint, timeout: viaRelay ? 75 : 8)
        defer { client.close() }
        let reply = try await client.json(base.appending(path: "pair"), method: "POST", body: ["code": code, "name": deviceName])
        guard let token = reply["token"] as? String else { throw PairingError(L("电脑未返回令牌，请重试")) }
        _ = try? await client.json(base.appending(path: "api/devices/rename"), method: "POST", token: token,
                                   body: ["name": deviceName])
        let info = try await client.json(base.appending(path: "api/info"), token: token)
        return PairedMac(name: info["host"] as? String ?? L("电脑"), addresses: addresses(base, info),
                         token: token, caCertificate: client.captured,
                         remote: await remote(client, base, token: token))
    }

    /// 开通远程访问：报上这台手机的点对点公钥，拿回 Mac 的公钥和中继。Mac 没开远程访问返回 nil，不影响配对
    static func remote(_ client: MacClient, _ base: URL, token: String) async -> RemoteInfo? {
        guard let phoneId = await MainActor.run(body: { PhoneP2P.publicId() }),
              let reply = try? await client.json(base.appending(path: "api/p2p/join"), method: "POST", token: token, body: ["id": phoneId])
        else { return nil }
        return RemoteInfo(reply)
    }

    /// 连上的地址排第一，再加上 Mac 报的其他 HTTPS 地址（局域网、Tailscale、.local 名字）
    static func addresses(_ first: URL, _ info: [String: Any]) -> [URL] {
        var list = [first]
        for text in info["https"] as? [String] ?? [] {
            if let url = URL(string: text), !list.contains(url) { list.append(url) }
        }
        return list
    }
}
