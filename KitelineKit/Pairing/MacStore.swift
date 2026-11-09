import Foundation
import Observation
import Security

/// 配对好的 Mac：能连的地址、这台手机的设备令牌、Mac 自己的根证书（用来校验它的 HTTPS）
struct PairedMac: Codable, Equatable {
    var name: String
    /// 能连的地址，最近一次连上的排最前（局域网、Tailscale……）
    var addresses: [URL]
    /// 设备令牌（d 开头）：Mac 的「设置 → 设备」里能看到、能停用
    var token: String
    /// Mac 本机根证书（DER）。走 tailscale serve 这类正式证书时为空
    var caCertificate: Data?
    /// 远程访问：Mac 的点对点公钥和中继（Mac 没开远程访问时为空）
    var remote: RemoteInfo?
    /// 这台电脑的编号（电脑互联用，旧版电脑端没有）
    var computerId: String? = nil
    /// 和这台互联的其他 Kiteline 电脑（那台电脑替这台手机登记好的令牌、地址、证书）：这台连不上时换到能连上的那台
    var others: [PairedMac]? = nil
}

/// 存配对信息：令牌是钥匙，放钥匙串，只留在这台手机上（不进 iCloud 备份恢复到别的设备）
@Observable
final class MacStore {
    static let shared = MacStore()

    private(set) var current: PairedMac?

    private init() {
        current = Keychain.load()
    }

    func save(_ mac: PairedMac) {
        current = mac
        Keychain.save(mac)
    }

    #if SNAPSHOT
    /// 截图构建：连测试实例，不进钥匙串
    func useTemporarily(_ mac: PairedMac) { current = mac }
    #endif

    #if !KITELINE_MAC
    /// 进演示模式：连「演示 Mac」（DemoServer 在本机应答），不进钥匙串，退出或重开 App 就回到配对页
    @MainActor
    func enterDemo() {
        Offline.clear()
        ImageCache.shared.clearMemory()
        DemoServer.shared.reset()
        Demo.set(true)
        Store.shared.demoChanged()
        current = Demo.mac
    }

    var isDemo: Bool { current.map(Demo.isDemo) ?? false }
    #endif

    func forget() {
        #if !KITELINE_MAC
        // 退出演示模式：钥匙串里没有它，只清掉演示留下的缓存
        if isDemo {
            current = nil
            Demo.set(false)
            Task { @MainActor in
                Offline.clear()
                Store.shared.demoChanged()
            }
            return
        }
        current = nil
        Keychain.delete()
        Task { @MainActor in PushSetup.shared.leave() }
        #else
        current = nil
        Keychain.delete()
        #endif
        Task { @MainActor in
            PhoneP2P.shared.reset()
            Offline.clear()
            ImageDisk.removeAll()
            ImageCache.shared.clearMemory()
        }
    }

    /// 现在这台被停用了（令牌失效）：同组还有别的电脑就换过去，没有才回到配对页
    func dropCurrent() {
        guard var list = current?.others, !list.isEmpty else { forget(); return }
        var next = list.removeFirst()
        next.others = list
        save(next)
    }

    /// 换到同组的另一台电脑（这台连不上、那台连得上）：原来这台留在「其他电脑」里，之后照样能换回来
    func switchTo(_ computerId: String) {
        guard var mac = current, var list = mac.others, let index = list.firstIndex(where: { $0.computerId == computerId }) else { return }
        var next = list.remove(at: index)
        mac.others = nil
        next.others = [mac] + list
        save(next)
    }

    /// 电脑报来的「互联的其他电脑」：记下它们（已有的更新名字和地址，新加的放后面，不在名单里的去掉）
    func setOthers(selfId: String?, _ list: [PairedMac]) {
        guard var mac = current else { return }
        if let selfId, mac.computerId != selfId { mac.computerId = selfId }
        mac.others = list.isEmpty ? nil : list
        guard mac != current else { return }
        save(mac)
    }

    /// 老配对没记 Mac 的根证书（配对时系统已经信任它）：连上时补记（见 MacClient.onRootCaptured）
    func fillCertificate(_ der: Data, token: String) {
        guard var mac = current, mac.token == token, mac.caCertificate == nil else { return }
        mac.caCertificate = der
        save(mac)
    }

    /// Mac 给了（或更新了）远程访问信息：配对后、Mac 后来才开远程访问、Mac 换了中继
    func setRemote(_ info: RemoteInfo?) {
        guard var mac = current, mac.remote != info else { return }
        mac.remote = info
        save(mac)
    }

    /// 这个地址刚连上：排到最前，下次先试它；Mac 报来的新地址补在后面
    func connected(via address: URL, known: [URL] = []) {
        guard var mac = current else { return }
        var list = [address] + mac.addresses.filter { $0 != address }
        for url in known where !list.contains(url) { list.append(url) }
        mac.addresses = Array(list.prefix(8))
        guard mac != current else { return }
        save(mac)
    }
}

private enum Keychain {
    private static let service = "com.mrhong.tars.pairing"
    private static let account = "mac"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> PairedMac? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    static func save(_ mac: PairedMac) {
        guard let data = try? JSONEncoder().encode(mac) else { return }
        delete()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
