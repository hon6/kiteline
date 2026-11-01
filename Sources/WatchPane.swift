import SwiftUI
import KitelineKit

// MARK: - Apple Watch

/// 设置 → Apple Watch：手表跟着 iPhone 走（不用单独配对），这里看哪台手机配了手表、改手表上的选项。
/// 选项存在 config.mobile.watch，手机 App 的「设置 → Apple Watch」改的是同一份
struct WatchPane: View {
    @State private var watch = AppState.shared.config.mobile.watch
    @State private var devices: [DeviceStore.Device] = []
    @State private var replies: [String] = AppState.shared.config.mobile.watch.replies

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "applewatch.watchface")
                        .font(.app(size: 30, weight: .regular))
                        .foregroundStyle(Color.tarsBrand)
                        .frame(width: 44, height: 44)
                        .background(Color.tarsBrand.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("手表经由 iPhone 连接，无需单独配对").font(.app(size: 13, weight: .semibold))
                        Text("iPhone 上的 Kiteline 连接此 Mac 后，打开手表上的 Kiteline 即可查看会话进度、允许操作、回答提问和语音回复。手表版 Kiteline 随 iPhone App 一同提供：iPhone「Watch」App → 可安装的 App → Kiteline。")
                            .font(.app(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    Button("给新 iPhone 配对…") { SettingsWindowController.shared.show(tab: .phone) }
                    Spacer()
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
                }
            }
            Section("已配对手表的 iPhone") {
                let paired = devices.filter { $0.watch?.paired == true }
                if paired.isEmpty {
                    Text("暂无 iPhone 上报已配对的 Apple Watch。在已配对手表的 iPhone 上打开一次 Kiteline 后将显示在此处。")
                        .font(.app(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(paired, id: \.id) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.watch?.installed == true ? "applewatch" : "applewatch.slash")
                            .font(.app(size: 18)).frame(width: 26)
                            .foregroundStyle(device.watch?.installed == true ? Color.tarsBrand : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.app(size: 13, weight: .semibold))
                            Text(device.watch?.label ?? "").font(.app(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Toggle("双指互点 = 允许", isOn: $watch.doubleTap)
                Toggle("危险命令需在手表上二次确认", isOn: $watch.guardDanger)
                Toggle("确认框中显示「总是允许」", isOn: $watch.alwaysAllow)
            } header: {
                Text("确认")
            } footer: {
                Text("双指互点：适用于 Series 9、Ultra 2 及更新机型。抬腕确认命令内容后，双指互点即等同于轻点「允许 / 批准 / 确认」；拒绝始终需要轻点按钮。危险命令（rm -rf、git push --force、git reset --hard、sudo 等）不响应双指互点，轻点「允许」后还需二次确认。")
                    .foregroundStyle(.secondary)
            }
            Section("显示") {
                Picker("会话列表", selection: $watch.scope) {
                    Text("全部会话").tag("all")
                    Text("仅显示进行中、待确认和出错的会话").tag("active")
                }
                Toggle("隐藏已静音的会话（待确认的会话仍会显示）", isOn: $watch.hideMuted)
                Toggle("显示花费金额", isOn: $watch.showCost)
                Toggle("手表 App 打开时，收到新的确认请求即震动提醒", isOn: $watch.haptics)
            }
            Section {
                Picker("主题色", selection: $watch.theme) {
                    Text("与 iPhone 一致").tag("phone")
                    ForEach(LookTheme.all) { Text($0.name).tag($0.id) }
                }
                Picker("字体", selection: $watch.font) {
                    Text("与 iPhone 一致").tag("phone")
                    ForEach(LookFont.all) { Text($0.name).tag($0.id) }
                }
                Picker("字号", selection: $watch.textSize) {
                    Text("跟随手表文字大小").tag("watch")
                    ForEach(LookSize.all) { Text($0.name).tag($0.id) }
                }
            } header: {
                Text("外观")
            } footer: {
                Text("「与 iPhone 一致」即使用 iPhone 上 Kiteline「设置 → 外观」中的选项。手表始终使用深色外观；手表不提供宋体、楷体等中文字体，选择后中文仍显示为苹方，数字和英文使用同风格字体。")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(replies.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("回复 \(index + 1)", text: Binding(get: { replies.indices.contains(index) ? replies[index] : "" },
                                                                    set: { if replies.indices.contains(index) { replies[index] = $0 } }),
                                  onCommit: saveReplies)
                        Button { replies.remove(at: index); saveReplies() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("添加") { replies.append("") }.disabled(replies.count >= 8)
                    if replies.isEmpty {
                        Button("使用推荐回复") { replies = WatchConfig.suggestedReplies; saveReplies() }
                    }
                    Spacer()
                    if !replies.isEmpty {
                        Button("清空（改用快捷短语）") { replies = []; saveReplies() }
                    }
                }
            } header: {
                Text("手表上的快捷回复")
            } footer: {
                Text(replies.isEmpty ? "当前使用「快捷短语」。手表屏幕较小，可单独设置简短回复（最多 8 条，每条不超过 40 字）。也可在手表上直接语音回复。"
                                     : "在手表上轻点即可发送给 Claude。最多 8 条，每条不超过 40 字。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.width, height: 680)
        .onAppear(perform: reload)
        .onChange(of: watch) { _, value in
            var next = value
            next.replies = AppState.shared.config.mobile.watch.replies
            guard next != AppState.shared.config.mobile.watch else { return }
            AppState.shared.updatePreferences { $0.mobile.watch = next }
            AppState.shared.mobile.publishState()
        }
        .onDisappear(perform: saveReplies)
    }

    private func reload() {
        devices = DeviceStore.shared.all
        watch = AppState.shared.config.mobile.watch
        replies = watch.replies
    }

    private func saveReplies() {
        var next = AppState.shared.config.mobile.watch
        next.merge(["replies": replies])
        guard next != AppState.shared.config.mobile.watch else { return }
        AppState.shared.updatePreferences { $0.mobile.watch = next }
        AppState.shared.mobile.publishState()
    }
}
