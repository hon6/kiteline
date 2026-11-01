import AppKit
import SwiftUI
import KitelineKit

/// 设置 → 远程访问：点对点直连 + 中继兜底，不需要账号。这里开关、填自建中继、看哪些手机能远程连
struct RemotePane: View {
    @StateObject private var model = RemoteModel()
    @State private var relay = AppState.shared.config.mobile.relayURL
    @State private var showLogs = false

    var body: some View {
        Form {
            Section {
                Toggle("开启远程访问", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
            } footer: {
                Text("手机不在同一 Wi-Fi 时（如办公室、外出、4G/5G 网络）也能连接这台 Mac。优先直连，无法直连时经中继转发；全程端到端加密，中继无法查看内容。无需注册账号。")
                    .foregroundStyle(.secondary)
            }
            if model.enabled {
                Section("状态") {
                    LabeledContent("连接") {
                        HStack(spacing: 6) {
                            Circle().fill(model.status.online ? Color.green : (model.status.state == "starting" ? .orange : .red))
                                .frame(width: 8, height: 8)
                            Text(label)
                        }
                    }
                    if let relay = model.status.relay, !relay.isEmpty {
                        LabeledContent("中继", value: relay.replacingOccurrences(of: ".link./", with: ".link").replacingOccurrences(of: "https://", with: ""))
                    }
                    if let error = model.status.error, !error.isEmpty {
                        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("可远程连接的手机") {
                        Text(model.phones.isEmpty ? L("暂无（在同一 Wi-Fi 下完成配对后显示）") : model.phones.joined(separator: "、"))
                            .foregroundStyle(model.phones.isEmpty ? .secondary : .primary)
                    }
                    HStack {
                        Spacer()
                        Button("查看日志") { showLogs = true }
                    }
                }
                Section {
                    TextField("中继地址", text: $relay, prompt: Text("留空则使用 Kiteline 中继（tars.betac.cn）"))
                    HStack {
                        Spacer()
                        Button("应用") { model.setRelay(relay) }
                            .disabled(relay.trimmingCharacters(in: .whitespaces) == AppState.shared.config.mobile.relayURL)
                    }
                } header: {
                    Text("中继服务器")
                } footer: {
                    Text("无法直连时经中继转发，中继仅转发加密数据，无法查看内容。默认使用 Kiteline 官方中继（上海）；如需使用自建中继，请填写其地址，例如 https://relay.example.com。修改后，手机将在下次连接时自动切换。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.width)
        .onAppear { model.reload() }
        .sheetPanel(isPresented: $showLogs) {
            VStack(alignment: .leading, spacing: 10) {
                Text("远程访问日志").font(.app(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .panelDragArea()
                ScrollView {
                    Text(P2P.shared.logs.isEmpty ? L("（暂无日志）") : P2P.shared.logs)
                        .font(.app(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("关闭") { showLogs = false }.keyboardShortcut(.defaultAction).tarsButton() }
            }
            .padding(16)
            .panelFrame(width: 640, height: 420)
        }
    }

    private var label: String {
        switch model.status.state {
        case "online": return L("已连接，手机可通过外部网络连接")
        case "starting": return L("正在连接中继…")
        case "error": return L("出错")
        default: return L("未运行")
        }
    }
}

/// 把远程访问的状态接给 SwiftUI
final class RemoteModel: ObservableObject {
    @Published var status = P2P.shared.status
    @Published var enabled = AppState.shared.config.mobile.remoteEnabled
    @Published var phones: [String] = []

    init() {
        P2P.shared.onChange = { [weak self] status in self?.status = status }
        reload()
    }

    func reload() {
        status = P2P.shared.status
        phones = DeviceStore.shared.all.filter { $0.p2pId != nil }.map(\.name)
    }

    func setEnabled(_ on: Bool) {
        AppState.shared.updatePreferences { $0.mobile.remoteEnabled = on }
        enabled = on
        let mobile = AppState.shared.config.mobile
        if on { P2P.shared.start(relay: mobile.effectiveRelay, httpsPort: mobile.effectiveHTTPSPort) } else { P2P.shared.stop() }
    }

    func setRelay(_ relay: String) {
        let clean = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        AppState.shared.updatePreferences { $0.mobile.relayURL = clean }
        let mobile = AppState.shared.config.mobile
        if mobile.remoteEnabled { P2P.shared.start(relay: mobile.effectiveRelay, httpsPort: mobile.effectiveHTTPSPort) }
    }
}
