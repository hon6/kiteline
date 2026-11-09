import CryptoKit
import Foundation
import Security

/// 校验 Mac 的 HTTPS。
///
/// Mac 上的 Kiteline 自己生成一张根证书，再用它签服务器证书（IP 变了只重签服务器证书）。
/// 网页版要用户去「设置」里装描述文件、打开完全信任；App 里不用：配对时记下这张根证书，
/// 之后只认它签出来的证书（先核对主机名；证书上没有这个地址时只要是它签的也认）。系统本来就信任的正式证书（tailscale serve）照常放行。
enum TrustPolicy {
    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func accept(_ trust: SecTrust, host: String, ca: Data?) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        if SecTrustEvaluateWithError(trust, nil) { return true }
        guard let ca, let anchor = SecCertificateCreateWithData(nil, ca as CFData) else { return false }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if SecTrustEvaluateWithError(trust, nil) { return true }
        // 证书上没有这个名字（经公网 IP、域名、端口转发连电脑，或电脑互联里另一台电脑报来的地址）：
        // 只要是配对时记下的这台电脑的根证书签的就认（同电脑之间互连，见 Sources/PeerComputers.swift 的 PeerTrust）。
        // 根证书是这台电脑自己生成、带名称约束的，没有它的私钥签不出来
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// 配对时：从握手里拿 Mac 的根证书（链上最后一张）。
    /// 扫码链接里带了指纹就必须对得上；手输配对码时没有指纹，就先信这一次（之后只认这张）。
    static func capture(_ trust: SecTrust, expected fingerprint: String?) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let root = chain.last else { return nil }
        let der = SecCertificateCopyData(root) as Data
        if let fingerprint, !fingerprint.isEmpty, self.fingerprint(der) != fingerprint.lowercased() { return nil }
        return der
    }
}
