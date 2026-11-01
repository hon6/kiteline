import CommonCrypto
import Foundation

/// Bark 备用推送（iOS 上免费的推送 App，国内常用）。网页推送被专注模式吞掉、或证书没装好收不到时兜底。
///
/// - 地址：Bark App 里复制的「https://api.day.app/<key>」，也支持自建 bark-server，或只填 key
/// - 需要你确认的用「时效性」级别（专注模式下也会响），其他用普通级别
/// - 可选加密：填了 Bark App 里设置的 AES 密钥 / IV，内容用 AES-CBC 加密后再发，Bark 服务器只看到密文
/// - 推送里不带 Kiteline 的令牌
enum Bark {
    struct Target {
        var server: String
        var key: String
    }

    /// 「https://api.day.app/KEY」「https://my.server/KEY/」或只填「KEY」
    static func parse(_ text: String) -> Target? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("/") {
            return trimmed.range(of: "^[A-Za-z0-9]{6,64}$", options: .regularExpression) == nil ? nil
                : Target(server: "https://api.day.app", key: trimmed)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let key = parts.first, key.range(of: "^[A-Za-z0-9]{6,64}$", options: .regularExpression) != nil else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return Target(server: "\(scheme)://\(host)\(port)", key: key)
    }

    /// 按设置决定这类提醒要不要走 Bark
    static func wants(_ kind: String, config: MobileConfig) -> Bool {
        guard parse(config.barkURL) != nil else { return false }
        switch config.barkMode {
        case "all": return true
        case "attention": return kind == "attention" || kind == "budget"
        default: return false
        }
    }

    static func send(title: String, body: String, kind: String, config: MobileConfig,
                     completion: ((Bool, String) -> Void)? = nil) {
        guard let target = parse(config.barkURL) else { completion?(false, "Bark 地址无效"); return }
        var payload: [String: Any] = [
            "title": title,
            "body": String(body.prefix(500)),
            "group": "Kiteline",
            "level": kind == "attention" ? "timeSensitive" : "active",
            "isArchive": 1,
        ]
        if kind == "attention" { payload["sound"] = "multiwayinvitation" }
        var request = URLRequest(url: URL(string: "\(target.server)/push")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let key = config.barkKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            // 加密推送（Bark 文档的写法）：明文 JSON 用 AES-CBC/PKCS7 加密，ciphertext + iv 以表单 POST 到 /<key>
            let iv = config.barkIV.trimmingCharacters(in: .whitespaces)
            guard let plain = try? JSONSerialization.data(withJSONObject: payload),
                  let cipher = aesCBC(plain, key: key, iv: iv) else {
                completion?(false, "加密失败：密钥须为 16 / 24 / 32 个字符，IV 须为 16 个字符"); return
            }
            request.url = URL(string: "\(target.server)/\(target.key)")
            let form = ["ciphertext": cipher.base64EncodedString(), "iv": iv]
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formEncode(form).data(using: .utf8)
        } else {
            payload["device_key"] = target.key
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let ok = error == nil && status == 200 && (reply["code"] as? Int ?? 200) == 200
            let message = ok ? "已发到 Bark" : (error?.localizedDescription ?? (reply["message"] as? String) ?? "Bark 返回 \(status)")
            if !ok { Log.write("Bark 推送失败：\(message)") }
            DispatchQueue.main.async { completion?(ok, message) }
        }.resume()
    }

    static func aesCBC(_ data: Data, key: String, iv: String) -> Data? {
        let keyData = Data(key.utf8), ivData = Data(iv.utf8)
        guard [16, 24, 32].contains(keyData.count), ivData.count == 16 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                keyData.withUnsafeBytes { keyBytes in
                    ivData.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, keyData.count, ivBytes.baseAddress,
                                inBytes.baseAddress, data.count, outBytes.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .sorted().joined(separator: "&")
    }
}
