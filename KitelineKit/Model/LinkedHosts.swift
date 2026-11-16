import Foundation
import Observation

/// 设备维度里「独立的 Kiteline 设备」：手机直连的其他 Kiteline 电脑（MacStore.linked）。
///
/// 每台各一个 MacAPI、各一条事件流（局域网下各走各的；远程访问时都在同一个点对点端点里）。
/// 它推来的整份状态存在这里（原样，没换写法），和主电脑的状态在 AppModel.applyCombined 里合成一份：
/// 设备 id、会话 key 换成 `kl:<编号前 8 位>:…`，并进同一个设备、会话列表。其他事件（对话增量、提醒、终端、负载）换好写法交给同一个处理。
@MainActor
final class LinkedHost {
    let computerId: String
    let api: MacAPI
    /// 最近一份整份状态（那台的写法）；nil = 还没连上过
    var raw: [String: Any]?
    var online = false
    var error: String?
    var stream: Task<Void, Never>?
    /// 这一次连上之后对过远程访问信息没有（每次重新连上对一次：那台后来才开远程访问、换了中继）
    var remoteChecked = false

    var prefix: String { DeviceHub.prefix(computerId) }
    /// 它自己的设备 id（不含它经互联转来的 kl: 设备）
    var own: Set<String> {
        Set(((raw?["sources"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.filter { !$0.hasPrefix(DeviceHub.sourcePrefix) })
    }

    init(mac: PairedMac, computerId: String) {
        self.computerId = computerId
        api = MacAPI(mac: mac)
        api.wantsPatch = false
        // 远程访问走自己那条通道（kiteline_p2p_channel），选路看通道的状态
        if let macId = mac.remote?.macId {
            api.linkReader = { PhoneP2P.readChannelLink(macId) }
        }
    }
}

/// 设置里「Kiteline 设备」一行显示的
struct LinkedStatus: Equatable, Identifiable {
    var id: String
    var name: String
    var online: Bool
    var error: String?
    var version: String?
    var platform: String?
    var features: Set<String>
    /// 这台电脑带进来的设备（本机写法的 id）
    var sources: [String]
}

extension AppModel {
    // MARK: 起停

    /// 按 MacStore.linked 起停（加了、删了一台都调）
    func syncLinked() {
        guard !embedded else { return }
        let primaryId = MacStore.shared.current?.computerId
        let wanted = MacStore.shared.linked.filter { $0.computerId != nil && $0.computerId != primaryId }
        let ids = Set(wanted.compactMap(\.computerId))
        for (id, host) in linkedHosts where !ids.contains(id) {
            host.stream?.cancel()
            linkedHosts.removeValue(forKey: id)
        }
        for mac in wanted {
            guard let id = mac.computerId, linkedHosts[id] == nil else { continue }
            let host = LinkedHost(mac: mac, computerId: id)
            linkedHosts[id] = host
            startLinkedRemote(host)
            if streamTask != nil { connectLinked(host) }
        }
        // 移除了的电脑的通道关掉（主电脑的转发不在这里面）
        PhoneP2P.shared.keepChannels(Set(wanted.compactMap { $0.remote?.macId }))
        applyCombined()
    }

    func startLinked() {
        syncLinked()
        for host in linkedHosts.values where host.stream == nil {
            host.api.networkChanged()
            connectLinked(host)
        }
    }

    func stopLinked() {
        for host in linkedHosts.values {
            host.stream?.cancel()
            host.stream = nil
            host.online = false
        }
    }

    /// 换了网络：各台重新探路、重连事件流
    func linkedNetworkChanged() {
        for host in linkedHosts.values {
            host.api.networkChanged()
            guard host.stream != nil else { continue }
            host.stream?.cancel()
            connectLinked(host)
        }
    }

    // MARK: 远程访问（每台一条通道）

    /// 订阅了、那台开着远程访问：在同一个点对点端点里给它开一条通道，本机转发地址加进它的候选（同主电脑的 startRemote）
    func startLinkedRemote(_ host: LinkedHost) {
        guard Store.shared.isPro, PhoneP2P.available,
              let info = MacStore.shared.linked.first(where: { $0.computerId == host.computerId })?.remote else { return }
        host.api.useRemote(Task { await PhoneP2P.shared.channel(info) })
        if host.api.remoteRefused == nil {
            host.api.remoteRefused = { [weak self] in
                await MainActor.run { self?.refreshLinkedForwards() }
            }
        }
    }

    /// 各台都开一遍（订阅了、端点重开过）
    func startLinkedRemotes() {
        for host in linkedHosts.values { startLinkedRemote(host) }
    }

    /// 通道的本机端口被 iOS 回收过（挂起后回来）：重开，端口变了的告诉那台的请求层
    func refreshLinkedForwards() {
        let changed = PhoneP2P.shared.resumeChannels()
        guard !changed.isEmpty else { return }
        for mac in MacStore.shared.linked {
            guard let macId = mac.remote?.macId, let url = changed[macId], let host = mac.computerId.flatMap({ linkedHosts[$0] }) else { continue }
            host.api.useRemote(Task { () -> URL? in url })
        }
    }

    /// 连上一台后对一下它的远程访问信息：报上手机的点对点公钥（那台从此放这台手机经中继连进来），
    /// 拿回它的公钥和中继；那台后来才开远程访问、换了中继都在这时跟上
    private func refreshLinkedRemote(_ host: LinkedHost) {
        guard !host.remoteChecked, PhoneP2P.available, let phoneId = PhoneP2P.publicId() else { return }
        host.remoteChecked = true
        Task { [weak self, weak host] in
            guard let host, let reply = try? await host.api.post("/api/p2p/join", body: ["id": phoneId]) else { return }
            let info = RemoteInfo(reply)
            guard let self, MacStore.shared.linked.first(where: { $0.computerId == host.computerId })?.remote != info else { return }
            MacStore.shared.updateLinked(host.computerId) { $0.remote = info }
            if let macId = info?.macId { host.api.linkReader = { PhoneP2P.readChannelLink(macId) } }
            self.startLinkedRemote(host)
        }
    }

    /// 一台连上了：订阅推送、报「App 在前台」（开着时它不推锁屏）
    private func linkedOpened(_ host: LinkedHost) {
        #if !KITELINE_MAC
        PushSetup.shared.connectedLinked(host.api)
        #endif
        let api = host.api
        Task { _ = try? await api.post("/api/presence", body: ["visible": true]) }
    }

    private func connectLinked(_ host: LinkedHost) {
        host.stream = Task { [weak self, weak host] in
            var delay = 1.0
            while !Task.isCancelled {
                guard let host else { return }
                do {
                    for try await (event, data) in host.api.events() {
                        guard let self, !Task.isCancelled else { return }
                        if !host.online || host.error != nil {
                            host.online = true
                            host.error = nil
                            delay = 0.3
                            NetLog.note("linked_open", ["id": String(host.computerId.prefix(8)), "via": "\(host.api.routeKind)"])
                            self.refreshLinkedRemote(host)
                            self.linkedOpened(host)
                        }
                        self.handleLinked(host, event, data)
                    }
                } catch let error as APIError where error.unauthorized {
                    guard let self, !Task.isCancelled else { return }
                    host.online = false
                    host.error = L("这台电脑已停用本手机，请重新添加")
                    self.applyCombined()
                    return
                } catch {
                    if !Task.isCancelled { host.error = error.localizedDescription }
                }
                guard let self, !Task.isCancelled else { return }
                if host.online {
                    host.online = false
                    host.remoteChecked = false
                    self.applyCombined()
                }
                _ = await host.api.probe()
                try? await Task.sleep(for: .seconds(delay))
                delay = min(max(delay * 2, 1), 30)
            }
        }
    }

    // MARK: 事件

    private func handleLinked(_ host: LinkedHost, _ event: String, _ data: Data) {
        switch event {
        case "state":
            host.raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let raw = host.raw {
                MacStore.shared.updateLinked(host.computerId) { mac in
                    if let name = raw["host"] as? String, !name.isEmpty { mac.name = name }
                }
            }
            applyCombined()
        case "entries", "reset", "notify", "peers", "term", "term_exit":
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            if event == "notify" { object.removeValue(forKey: "inbox") }   // 通知收件箱只在主电脑上（铃铛数不跟着加）
            let mapped = DeviceHub.outward(object, prefix: host.prefix, own: host.own)
            guard let out = try? JSONSerialization.data(withJSONObject: mapped) else { return }
            handleEventFromLinked(event, out)
        case "sys":
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = object["id"] as? String else { return }
            object["id"] = DeviceHub.local(id, prefix: host.prefix)
            guard let out = try? JSONSerialization.data(withJSONObject: object) else { return }
            handleEventFromLinked(event, out)
        default:
            // 待办、收藏、会话组、会话群是主电脑上的；增量状态不会来（要的是整份）
            break
        }
    }

    // MARK: 合成

    /// 主电脑的状态 + 各台直连电脑的状态 → 一份（同 /api/state 的格式）。
    /// 直连的电脑在线时，主电脑经互联转来的同一台的设备、会话丢掉，只留直连的（同一 key，不重复）；
    /// 离线时它的设备留着显示「离线」，会话不显示（主电脑经互联转来的照常显示、照常经主电脑操作）
    func combinedState(primary: [String: Any]) -> (state: [String: Any], table: [String: (computerId: String, remote: String)], hosts: [DeviceHub.Host]) {
        guard !linkedHosts.isEmpty else { return (primary, [:], []) }
        var state = primary
        let ordered = MacStore.shared.linked.compactMap { $0.computerId.flatMap { linkedHosts[$0] } }
        let live = ordered.filter { $0.online && $0.raw != nil }
        let livePrefixes = live.map(\.prefix)
        func fromLive(_ id: String) -> Bool { livePrefixes.contains { id.hasPrefix($0) } }
        // 直连的电脑经互联转来的主电脑自己的设备：主电脑本来就有，不要第二份
        let primaryPrefix = MacStore.shared.current?.computerId.map(DeviceHub.prefix)

        var sources = (primary["sources"] as? [[String: Any]] ?? []).filter { !fromLive($0["id"] as? String ?? "") }
        var sessions = (primary["sessions"] as? [[String: Any]] ?? []).filter { !fromLive($0["sourceId"] as? String ?? "") }
        var present = Set(sources.compactMap { $0["id"] as? String })
        var pinned = primary["pinned"] as? [String] ?? []
        var marked = primary["marked"] as? [String] ?? []
        var muted = primary["muted"] as? [String] ?? []
        var sys = primary["sys"] as? [String: Any] ?? [:]
        var alerts = primary["alerts"] as? [[String: Any]] ?? []
        var agents = primary["agents"] as? [[String: Any]] ?? []
        var table: [String: (computerId: String, remote: String)] = [:]
        var hosts: [DeviceHub.Host] = []

        for host in ordered {
            guard let raw = host.raw else { continue }
            let own = host.own, prefix = host.prefix
            hosts.append(DeviceHub.Host(computerId: host.computerId, api: host.api, own: own))
            var taken = Set<String>()
            for var source in raw["sources"] as? [[String: Any]] ?? [] {
                guard let remote = source["id"] as? String else { continue }
                let local = DeviceHub.local(remote, prefix: prefix)
                // 它转来的别的电脑的设备：那台是主电脑、或那台也直连着且在线，都以那边为准
                if remote.hasPrefix(DeviceHub.sourcePrefix), primaryPrefix.map(remote.hasPrefix) == true || fromLive(remote) { continue }
                guard !present.contains(local) else { continue }
                source["id"] = local
                if !host.online { source["online"] = false }
                sources.append(source)
                present.insert(local)
                if host.online { table[local] = (host.computerId, remote); taken.insert(local) }
            }
            guard host.online else { continue }
            let mapped = DeviceHub.outward(raw, prefix: prefix, own: own) as? [String: Any] ?? [:]
            for session in mapped["sessions"] as? [[String: Any]] ?? [] where taken.contains(session["sourceId"] as? String ?? "") {
                sessions.append(session)
            }
            for key in mapped["pinned"] as? [String] ?? [] where !pinned.contains(key) { pinned.append(key) }
            for key in mapped["marked"] as? [String] ?? [] where !marked.contains(key) { marked.append(key) }
            for key in mapped["muted"] as? [String] ?? [] where !muted.contains(key) { muted.append(key) }
            for (id, stats) in mapped["sys"] as? [String: Any] ?? [:] where taken.contains(id) { sys[id] = stats }
            for var alert in mapped["alerts"] as? [[String: Any]] ?? [] {
                if let id = alert["id"] as? String { alert["id"] = prefix + id }   // 「尝试重连」按前缀找回这台（见 reconnect）
                alerts.append(alert)
            }
            let known = Set(agents.compactMap { $0["id"] as? String })
            agents += (mapped["agents"] as? [[String: Any]] ?? []).filter { !known.contains($0["id"] as? String ?? "") }
        }
        state["sources"] = sources
        state["sessions"] = sessions
        state["pinned"] = pinned
        state["marked"] = marked
        state["muted"] = muted
        state["sys"] = sys
        state["alerts"] = alerts
        state["agents"] = agents
        return (state, table, hosts)
    }

    /// 合成一份交给 apply；顺手更新路由表和设置里的状态
    func applyCombined() {
        guard let primary = primaryRaw else { return }
        let (state, table, hosts) = combinedState(primary: primary)
        hub.set(hosts: hosts, table: table)
        refreshLinkedStatus()
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let payload = try? JSONDecoder().decode(StatePayload.self, from: data) else { return }
        applyState(payload)
        Offline.saveState(data)
    }

    private func refreshLinkedStatus() {
        var list: [LinkedStatus] = []
        for mac in MacStore.shared.linked {
            guard let id = mac.computerId, let host = linkedHosts[id] else { continue }
            let raw = host.raw
            let sources = host.own.sorted().map { host.prefix + $0 }   // 它自己的设备（不含它经互联转来的）
            // 名字用它本机那台设备的名字（有别名就是别名），没有再用主机名
            let localName = (raw?["sources"] as? [[String: Any]] ?? []).first { $0["kind"] as? String == "local" }?["name"] as? String
            list.append(LinkedStatus(id: id, name: localName.flatMap { $0.isEmpty ? nil : $0 } ?? (raw?["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? mac.name,
                                     online: host.online, error: host.online ? nil : host.error,
                                     version: raw?["version"] as? String, platform: raw?["platform"] as? String,
                                     features: Set(raw?["features"] as? [String] ?? []), sources: sources))
        }
        if list != linkedStatus { linkedStatus = list }
    }

    // MARK: 添加、移除

    /// 设置里「添加 Kiteline 设备」配好之后：问清是哪台电脑（老版本没有编号的不收），记下、连上
    func addLinked(_ paired: PairedMac) async throws {
        let probe = MacAPI(mac: paired)
        // 经中继添加的（配对时已经给它开了通道）：照样经通道问
        if let macId = paired.remote?.macId, let url = PhoneP2P.shared.channelURL(macId) {
            probe.linkReader = { PhoneP2P.readChannelLink(macId) }
            probe.useRemote(Task { () -> URL? in url })
        }
        // 没加成：配对时开的通道关掉
        func reject(_ message: String) -> PairingError {
            PhoneP2P.shared.keepChannels(Set(MacStore.shared.linked.compactMap { $0.remote?.macId }))
            return PairingError(message)
        }
        let info: [String: Any]
        do {
            info = try await probe.get("/api/computers")
        } catch let error as APIError where error.status == 404 {
            throw reject(L("这台电脑上的 Kiteline 版本较旧，请先更新到最新版本再添加"))
        } catch {
            _ = reject("")
            throw error
        }
        guard let id = info["self"] as? String, !id.isEmpty else {
            throw reject(L("这台电脑上的 Kiteline 版本较旧，请先更新到最新版本再添加"))
        }
        if id == MacStore.shared.current?.computerId {
            throw reject(L("这台电脑就是当前连接的电脑，无需再添加"))
        }
        var mac = paired
        mac.computerId = id
        MacStore.shared.addLinked(mac)
        syncLinked()
        flash(L("已添加「%@」", mac.name))
    }

    func removeLinked(_ computerId: String) {
        #if !KITELINE_MAC
        if let api = linkedHosts[computerId]?.api { PushSetup.shared.leaveLinked(api) }   // 让它别再往这台手机推
        #endif
        MacStore.shared.removeLinked(computerId)
        syncLinked()
    }

    // MARK: 推送

    /// 推送里的会话 key → 手机上的。另加的电脑推来的是它自己的写法（`local#<会话 id>`），手机上是 `kl:<编号>:local#<会话 id>`，
    /// 按结尾认（同 WidgetSnapshot.sameSession）。刚被推送叫起来、那台还没连上时等一会儿（最多 6 秒）
    func sessionKey(forPushed key: String) async -> String {
        for _ in 0..<20 {
            if sessions.contains(where: { $0.key == key }) { return key }
            if key.contains("#"), let hit = sessions.first(where: { $0.key.hasPrefix(DeviceHub.sourcePrefix) && $0.key.hasSuffix(":" + key) }) {
                return hit.key
            }
            if MacStore.shared.linked.isEmpty { return key }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return key
    }

    // MARK: 设备别名

    /// 给设备起别名（清空 = 恢复电脑上的默认名）：记在设备所在的那台电脑上，各端看到的都一样。
    /// 指向直连电脑的设备经 DeviceHub 发给那台；主电脑经互联转来的由主电脑转给那台
    func renameSource(_ id: String, to name: String) async -> Bool {
        let host = hub.computer(of: id).flatMap { computer in linkedStatus.first { $0.id == computer } }
        let features = host?.features ?? hostFeatures
        guard features.contains("renameSource") else {
            flash(L("这台电脑上的 Kiteline 版本较旧，请先更新后再设置别名"))
            return false
        }
        do {
            _ = try await api.post("/api/sources/rename", body: ["sourceId": id, "name": name])
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// 这个设备能不能起别名（设备所在的电脑够新）
    func canRename(_ sourceId: String) -> Bool {
        if let computer = hub.computer(of: sourceId) {
            return linkedStatus.first { $0.id == computer }?.features.contains("renameSource") ?? false
        }
        return hostFeatures.contains("renameSource")
    }

    /// 「尝试重连」的提醒来自直连的电脑：去掉前缀交给那台
    func linkedAlertTarget(_ id: String) -> (MacAPI, String)? {
        for host in linkedHosts.values where id.hasPrefix(host.prefix) {
            return (host.api, String(id.dropFirst(host.prefix.count)))
        }
        return nil
    }
}
