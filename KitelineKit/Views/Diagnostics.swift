#if os(iOS)
import Foundation
import Network
import SwiftUI

/// 网络诊断：连不上 Mac 时，沿着连接的路一道道查，找出卡在哪一道。
/// 手机网络 → 本地网络权限 → 局域网直连 → 远程访问 → 中继服务器 → 点对点到 Mac → Mac 认不认这台手机 → 实时连接
@MainActor
@Observable
final class NetworkDiagnosis {
    enum State: Equatable { case waiting, running, ok, warn, fail, skipped }

    struct Check: Identifiable {
        let id: String
        let title: String
        var state: State = .waiting
        var detail = ""
        /// 怎么修
        var fix: String?
        /// 修的时候能直接点的（去设置打开……）
        var action: Action?
    }

    enum Action { case openSettings }

    private(set) var checks: [Check] = []
    private(set) var running = false

    /// 结论：有不通的说第一道；实时连接是通的就是「连得上」（要注意的写在各道里）；否则说第一处要注意的
    var conclusion: (state: State, title: String, text: String)? {
        guard !running, !checks.isEmpty else { return nil }
        if let index = checks.firstIndex(where: { $0.state == .fail }) {
            let check = checks[index]
            return (.fail, L("问题位于第 %@ 项：%@", "\(index + 1)", "\(check.title)"), check.fix ?? check.detail)
        }
        let warnings = checks.filter { $0.state == .warn }
        if let stream = checks.first(where: { $0.id == "stream" }), stream.state == .ok {
            return (.ok, L("当前连接正常"), stream.detail + (warnings.isEmpty ? "" : L("。另有 %@ 项需注意，详见下方", "\(warnings.count)")))
        }
        if let check = warnings.first {
            return (.warn, check.title, check.fix ?? check.detail)
        }
        return (.ok, L("全部正常"), L("手机至电脑的各环节均已连通。"))
    }

    /// 给人看 / 拷贝给开发者的文字版
    var report: String {
        let mark: [State: String] = [.ok: "✓", .warn: "!", .fail: "✗", .skipped: "-", .waiting: "…", .running: "…"]
        var lines = [L("Kiteline 网络诊断 %@", "\(Date().formatted(date: .numeric, time: .standard))")]
        for (index, check) in checks.enumerated() {
            lines.append("\(index + 1). \(mark[check.state] ?? "") \(check.title)：\(check.detail)" + (check.fix.map { "（\($0)）" } ?? ""))
        }
        // 远程访问的最近记录：连上、断开、换路（局域网直连 ↔ 中继），排查「换网络后连不上」用
        let logs = PhoneP2P.logs.split(separator: "\n").suffix(30)
        if !logs.isEmpty { lines += ["", L("远程访问记录：")] + logs.map(String.init) }
        return lines.joined(separator: "\n")
    }

    private func set(_ id: String, _ state: State, _ detail: String, fix: String? = nil, action: Action? = nil) {
        guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[index].state = state
        checks[index].detail = detail
        checks[index].fix = fix
        checks[index].action = action
    }

    private func start(_ id: String) {
        guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[index].state = .running
    }

    func run(model: AppModel) async {
        guard !running else { return }
        running = true
        defer { running = false }
        checks = [
            Check(id: "network", title: L("手机网络")),
            Check(id: "permission", title: L("本地网络权限")),
            Check(id: "lan", title: L("局域网直连电脑")),
            Check(id: "remote", title: L("远程访问")),
            Check(id: "relay", title: L("中继服务器")),
            Check(id: "p2p", title: L("点对点连到电脑")),
            Check(id: "auth", title: L("电脑是否信任此手机")),
            Check(id: "stream", title: L("实时连接")),
        ]
        guard let mac = MacStore.shared.current else {
            for check in checks { set(check.id, .skipped, L("尚未配对电脑")) }
            return
        }
        var reached = false        // 有一条路通到了 Mac
        var revoked = false        // Mac 回 401：这台手机被停用了 / 配对被重置

        // 1. 手机网络
        start("network")
        let path = await Self.currentPath()
        let wifi = path.status == .satisfied && path.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
        let cellular = path.availableInterfaces.contains { $0.type == .cellular }
        let vpn = path.availableInterfaces.contains { $0.type == .other }
        guard path.status == .satisfied else {
            set("network", .fail, L("手机当前无网络连接"), fix: L("请开启 Wi-Fi 或蜂窝数据，并关闭飞行模式"))
            for id in ["permission", "lan", "remote", "relay", "p2p", "auth", "stream"] { set(id, .skipped, L("手机无网络，无法检测")) }
            return
        }
        set("network", .ok, (wifi ? "Wi-Fi" : (cellular ? L("蜂窝数据（5G / 4G）") : L("已联网"))) + (vpn ? L("，已开启 VPN") : ""))

        // 2. 本地网络权限（只有在 Wi-Fi 上找 Mac 才用得到）。在 Wi-Fi 上当场查一次：
        // 全新安装后 App 里没记录、显示「没问过」，其实可能已经被拒；真没问过的这时系统会弹框
        start("permission")
        if wifi { await Permissions.shared.request(.localNetwork) }
        switch Permissions.shared.state(.localNetwork) {
        case .denied:
            set("permission", wifi ? .fail : .warn, L("未允许 Kiteline 访问本地网络"),
                fix: L("前往 iPhone「设置 → Kiteline」开启「本地网络」"), action: .openSettings)
        case .granted:
            set("permission", .ok, L("已允许"))
        case .notAsked:
            set("permission", .ok, L("尚未请求（首次在局域网中搜索电脑时系统会弹出对话框，请选择「允许」）"))
        }

        // 3. 局域网直连
        start("lan")
        let lanAddresses = mac.addresses.filter { MacAPI.AddressKind.of($0) == .lan }
        if !wifi {
            set("lan", .skipped, L("当前使用蜂窝数据，不经过局域网"))
        } else if lanAddresses.isEmpty {
            set("lan", .skipped, L("配对信息中无局域网地址"))
        } else {
            let results = await Self.ping(lanAddresses, mac: mac, timeout: 4)
            if let best = results.filter({ $0.status == 200 }).min(by: { $0.ms < $1.ms }) {
                reached = true
                set("lan", .ok, L("已连通：%@（%@ 毫秒）", "\(best.url.host() ?? "")", "\(best.ms)"))
            } else if results.contains(where: { $0.status == 401 }) {
                revoked = true
                set("lan", .fail, L("已连接到电脑，但电脑不信任此手机"), fix: L("此手机可能已在电脑上被停用。请在电脑上打开 Kiteline 的「手机访问」重新扫码"))
            } else if results.contains(where: { $0.certificate }) {
                set("lan", .fail, L("已连接到一台设备，但证书不匹配"),
                    fix: mac.caCertificate == nil
                        ? L("配对时未记录此电脑的证书（当时依赖手机上安装的「Local CA」描述文件），描述文件删除后即失去信任。请在电脑上打开 Kiteline 的「手机访问」重新扫码")
                        : L("可能是电脑已重置证书，或该地址现属于其他设备。请在电脑上打开 Kiteline 的「手机访问」重新扫码"))
            } else {
                let hosts = lanAddresses.compactMap { $0.host() }.joined(separator: "、")
                set("lan", remoteUsable(mac) ? .warn : .fail, L("局域网中未找到电脑（已尝试 %@）", "\(hosts)"),
                    fix: L("请确认电脑已开机且未睡眠、Kiteline 正在运行，且手机与电脑连接同一 Wi-Fi；")
                        + (HostPlatform.isMac ? L("并在电脑的「系统设置 → 隐私与安全性 → 本地网络」中开启 Kiteline") : L("并确认电脑的防火墙允许 Kiteline 接受连接")))
            }
        }

        // 4. 远程访问能不能用
        start("remote")
        if !Store.shared.isPro {
            set("remote", wifi && reached ? .skipped : .warn, L("免费版可在同一 Wi-Fi 下使用全部功能，远程访问需订阅"),
                fix: L("如需外出使用，请订阅 Kiteline Pro"))
        } else if mac.remote == nil {
            set("remote", reached ? .warn : .fail, L("电脑尚未为此手机开通远程访问"),
                fix: (HostPlatform.isMac ? L("请在电脑上打开「Kiteline 设置 → 远程访问」") : L("请在电脑上的 Kiteline 中开启远程访问")) + L("，然后在手机连接同一 Wi-Fi 时打开一次 Kiteline"))
        } else if !PhoneP2P.available {
            set("remote", .skipped, L("此设备不支持远程访问"))
        } else {
            set("remote", .ok, L("已开通"))
        }

        // 5. 中继服务器 6. 点对点到 Mac
        if remoteUsable(mac), let info = mac.remote {
            start("relay")
            let relay = URL(string: info.relay.isEmpty ? "https://tars.betac.cn" : info.relay)
            let relayHost = relay?.host() ?? info.relay
            if let relay, let ms = await Self.relayPing(relay) {
                set("relay", .ok, L("%@ 已连通（%@ 毫秒）", "\(relayHost)", "\(ms)"))
            } else {
                set("relay", .fail, L("无法连接中继 %@", "\(relayHost)"),
                    fix: L("当前网络可能拦截了该连接（公司 Wi-Fi、部分 VPN 或热点）。请更换网络或关闭 VPN 后重试"))
            }

            start("p2p")
            if let local = await PhoneP2P.shared.connect(info) {
                let result = await Self.ping([local], mac: mac, timeout: 8).first
                if result?.status == 200 {
                    reached = true
                    let link = PhoneP2P.shared.refreshLink()
                    let via = link.path == .relay ? L("经中继") : (link.onLAN ? L("局域网直连") : (link.path == .direct ? L("点对点直连") : ""))
                    set("p2p", .ok, L("已连通") + (via.isEmpty ? "" : "，\(via)") + L("（%@ 毫秒）", "\(result?.ms ?? 0)"))
                } else if result?.status == 401 {
                    revoked = true
                    set("p2p", .fail, L("已连接到电脑，但电脑不信任此手机"), fix: L("请在电脑上打开 Kiteline 的「手机访问」重新扫码"))
                } else if result?.certificate == true {
                    set("p2p", .fail, L("已连接到电脑，但证书不匹配"),
                        fix: L("原因与局域网检测项相同。请在电脑上打开 Kiteline 的「手机访问」重新扫码"))
                } else {
                    set("p2p", .fail, L("中继已连通，但电脑未响应"),
                        fix: L("电脑可能处于睡眠或关机状态、Kiteline 未运行、远程访问已关闭，或此手机已在电脑上被停用"))
                }
            } else {
                var why = L("远程访问未能启动")
                if case .failed(let message) = PhoneP2P.shared.state { why = message }
                set("p2p", .fail, why, fix: L("电脑可能处于睡眠或关机状态，或 Kiteline 未运行、未开启远程访问"))
            }
        } else {
            set("relay", .skipped, wifi && reached ? L("已通过 Wi-Fi 直连，无需检测") : L("远程访问不可用，未检测"))
            set("p2p", .skipped, wifi && reached ? L("已通过 Wi-Fi 直连，无需检测") : L("远程访问不可用，未检测"))
        }

        // 7. Mac 认不认这台手机
        start("auth")
        if revoked {
            set("auth", .fail, L("电脑不信任此手机的密钥"), fix: L("请在电脑上打开 Kiteline 的「手机访问」，用手机重新扫码"))
        } else if reached {
            set("auth", .ok, L("已信任（%@）", "\(mac.name)"))
        } else {
            set("auth", .skipped, L("所有线路均无法连接电脑，无法检测"))
        }

        // 8. 实时连接
        start("stream")
        if model.connected {
            set("stream", .ok, L("已连接，线路：%@", "\(model.routeLabel)"))
        } else if reached {
            set("stream", .warn, L("线路已连通，实时连接正在重新连接") + (model.connectionError.map { "（\($0)）" } ?? ""),
                fix: L("请稍候；如仍未恢复，请将 Kiteline 切换到后台后再返回"))
            model.networkChanged(force: true)   // 路已经查通了：让它马上重连，不用等退避
        } else {
            set("stream", .skipped, L("前置检测未通过"))
        }
    }

    private func remoteUsable(_ mac: PairedMac) -> Bool {
        Store.shared.isPro && mac.remote != nil && PhoneP2P.available
    }

    // MARK: 探测

    /// 现在的网络状况（一次性）
    private static func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard once.first() else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "kiteline.diagnosis.path"))
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    struct Ping { var url: URL; var status: Int?; var ms: Int; var certificate: Bool }

    /// 一起试几个地址的 /api/ping（带这台手机的钥匙）
    private static func ping(_ urls: [URL], mac: PairedMac, timeout: TimeInterval) async -> [Ping] {
        let client = MacClient(mac: mac, timeout: timeout)
        defer { client.close() }
        return await withTaskGroup(of: Ping.self) { group in
            for base in urls {
                group.addTask {
                    let start = Date()
                    let url = base.appending(path: "api/ping")
                    do {
                        let request = try MacClient.request(url, token: mac.token)
                        let (_, http) = try await client.send(request)
                        return Ping(url: base, status: http.statusCode, ms: Int(Date().timeIntervalSince(start) * 1000), certificate: false)
                    } catch let error as URLError {
                        let certificate = [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                                           .secureConnectionFailed, .cancelled].contains(error.code)
                        return Ping(url: base, status: nil, ms: 0, certificate: certificate)
                    } catch {
                        return Ping(url: base, status: nil, ms: 0, certificate: false)
                    }
                }
            }
            var all: [Ping] = []
            for await result in group { all.append(result) }
            return all
        }
    }

    /// 中继自己的 /ping（公开证书，用系统的网络栈）
    private static func relayPing(_ relay: URL) async -> Int? {
        var request = URLRequest(url: relay.appending(path: "ping"))
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let start = Date()
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Int(Date().timeIntervalSince(start) * 1000)
    }
}

/// 网络诊断的弹窗：最上面是结论，下面一道道列出来
struct NetworkDiagnosisSheet: View {
    @Environment(AppModel.self) private var model
    @State private var diagnosis = NetworkDiagnosis()
    @State private var copied = false

    var body: some View {
        FitSheet(title: L("网络诊断")) {
            VStack(alignment: .leading, spacing: 14) {
                summary
                VStack(spacing: 0) {
                    ForEach(Array(diagnosis.checks.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { Divider().padding(.leading, 44) }
                        row(index + 1, check)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 10) {
                    Button { Task { await diagnosis.run(model: model) } } label: {
                        Label("重新检测", systemImage: "arrow.clockwise").frame(maxWidth: .infinity).frame(height: 44)
                    }
                    .buttonStyle(.steady(.bordered))
                    .disabled(diagnosis.running)
                    Button {
                        Clipboard.copy(diagnosis.report, feedback: false)
                        copied = true
                    } label: {
                        Label(copied ? "已\(Clipboard.verb)" : "\(Clipboard.verb)结果", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity).frame(height: 44)
                    }
                    .buttonStyle(.steady(.bordered))
                    .disabled(diagnosis.running || diagnosis.checks.isEmpty)
                }
                .tint(Theme.claude)
            }
        }
        .task { await diagnosis.run(model: model) }
    }

    @ViewBuilder private var summary: some View {
        if let conclusion = diagnosis.conclusion {
            HStack(alignment: .top, spacing: 10) {
                icon(conclusion.state).font(.system(size: 22))
                VStack(alignment: .leading, spacing: 3) {
                    Text(conclusion.title).font(.ui(.headline))
                    Text(conclusion.text).font(.ui(.subheadline)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(color(conclusion.state).opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.claude)
                Text("正在逐项检测…").font(.ui(.subheadline)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func row(_ number: Int, _ check: NetworkDiagnosis.Check) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if check.state == .running { ProgressView().controlSize(.small).tint(Theme.claude) } else { icon(check.state) }
            }
            .font(.system(size: 18))
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(number). \(check.title)").font(.ui(.subheadline).weight(.semibold))
                if !check.detail.isEmpty {
                    Text(check.detail).font(.ui(.footnote)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let fix = check.fix, check.state == .fail || check.state == .warn {
                    Text(fix).font(.ui(.footnote)).foregroundStyle(color(check.state)).fixedSize(horizontal: false, vertical: true)
                }
                if check.action == .openSettings, check.state == .fail || check.state == .warn {
                    Button("前往设置") { Permissions.shared.openSettings() }
                        .font(.ui(.footnote).weight(.semibold))
                        .buttonStyle(.steady(.plain))
                        .foregroundStyle(Theme.claude)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func icon(_ state: NetworkDiagnosis.State) -> some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.added)
        case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.removed)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .waiting, .running: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }

    private func color(_ state: NetworkDiagnosis.State) -> Color {
        switch state {
        case .ok: Theme.added
        case .warn: .orange
        case .fail: Theme.removed
        default: .secondary
        }
    }
}

/// 首页标题下面「正在连接…」的按钮：转圈 + 文字，居中；点开网络诊断
struct ConnectingButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.claude)
                Text(text).lineLimit(1)
                Text("诊断").fontWeight(.semibold)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .font(.ui(.footnote))
            .foregroundStyle(Theme.claude)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Theme.tile, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .frame(maxWidth: .infinity)
        .accessibilityHint("打开网络诊断，定位连接失败的环节")
    }
}
#endif
