import SwiftUI

// 在后台运行 Claude Code（电脑上 Kiteline 的设置；电脑端见 Hosted.swift / desktop app.py）。本机（电脑自己的项目）默认开，远端电脑按设备开、默认不开：
// 先「检测出口 IP」——这台电脑照后台运行时的那套网络设置查出口，看过结果点「确认开启」才开这一台。
// 会话页上的提示（在 VS Code 里跑、能转到后台的远端会话）点开也是这个面板，开了以后还能把当前会话转到后台。
// iPhone 设置、Mac 设置的「来源」页、各端对话页都用这一份。

/// 会话页顶上的提示：「当前会话支持后台托管 Claude」。所在设备没开后台运行时一直显示，勾了「不再提示」才不再出现（存在电脑上，各端一起）
struct HostedTip: View {
    @Environment(AppModel.self) private var model
    let session: SessionInfo
    let open: () -> Void

    var body: some View {
        if session.hostable, model.hostFeatures.contains("hostedSetup"), !model.hosted.tipOff,
           model.sources.first(where: { $0.id == session.sourceId })?.hosted == "off" {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.stars").foregroundStyle(Theme.added)
                        Text("当前会话支持后台托管 Claude，可减少 VS Code 的内存占用")
                            .font(.ui(.footnote)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.right").font(.ui(.caption2).weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 18)
                Button {
                    Task { await model.setHosted(tipOff: true) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square").font(.ui(.footnote))
                        Text("不再提示").font(.ui(.caption))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .padding(.horizontal, 14)
            .transition(.opacity)
        }
    }
}

/// 会话页顶上的提示：所在电脑开着后台运行，这次却没起来、改在 VS Code 中打开了——说清楚原因和怎么办
/// （11-16 反馈：「要在会话详情里显示什么原因无法使用，否则用户都不知道该怎么办」）。
/// 点「重试」打开后台运行面板（能把当前会话转到后台，就是再试一次）；「知道了」只在这台设备上收起这一次的（下次起不来又会出现）
struct HostedIssueTip: View {
    let session: SessionInfo
    let retry: () -> Void
    @AppStorage("kiteline.hostedIssueDismissed") private var dismissed = ""

    var body: some View {
        if let issue = session.hostedIssue, dismissed != Self.mark(session.sourceId, issue) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("后台运行 Claude Code 未成功，此会话已改在 VS Code 中运行")
                        .font(.ui(.footnote).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                line(L("原因"), L(issue.reason) + (issue.detail.map { "（\($0)）" } ?? ""))
                line(L("解决"), L(issue.fix))
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { dismissed = Self.mark(session.sourceId, issue) }
                    } label: { Text("知道了").font(.ui(.caption)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    Button(action: retry) {
                        Text("重试").font(.ui(.caption).weight(.semibold)).foregroundStyle(Theme.added)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .padding(.horizontal, 14)
            .transition(.opacity)
        }
    }

    private func line(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.ui(.caption)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func mark(_ sourceId: String, _ issue: HostedIssue) -> String { "\(sourceId)@\(Int(issue.at))" }
}

/// 一台远端电脑的出口检测结果（/api/hosted/probe）
struct HostedProbe {
    var ip: String?
    var place: String?
    var org: String?
    /// vscode：照 VS Code 里正在运行的 Claude Code；shell：照终端环境（VS Code 里没有在运行的）
    var source: String?
    var settings: [(String, String)]
    var error: String?

    init(_ raw: [String: Any]) {
        let egress = raw["egress"] as? [String: Any]
        ip = egress?["ip"] as? String
        let country = (egress?["country"] as? String).map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
        var parts: [String] = []
        for part in [country, egress?["region"] as? String, egress?["city"] as? String] {
            if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
        }
        place = parts.isEmpty ? nil : parts.joined(separator: " · ")
        org = egress?["org"] as? String
        source = raw["source"] as? String
        settings = ((raw["settings"] as? [String: Any]) ?? [:]).compactMap { key, value in (value as? String).map { (key, $0) } }
            .sorted { $0.0 < $1.0 }
        error = raw["error"] as? String
    }
}

/// 后台运行 Claude Code 的设置面板：说明；每台能后台运行的电脑（本机、远端）各自「检测出口 IP」「确认开启 / 关闭」；从会话进来的还能把它转到后台
struct HostedSetupSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    /// 只看这一台（来源页某一行、会话页提示进来的）；nil = 所有能后台运行的
    var sourceId: String?
    /// 从哪个会话的提示点进来的（开了以后能把它转到后台）
    var key: String?
    @State private var probes: [String: HostedProbe] = [:]
    @State private var probing: Set<String> = []
    @State private var saving: Set<String> = []
    @State private var failure: String?
    @State private var moving = false
    /// 「关闭这些窗口」：正在关、关完的说明
    @State private var closingWindows = false
    @State private var windowsNote: String?
    @State private var windowsLoaded = false

    private var machines: [SourceInfo] {
        model.sources.filter { $0.hosted != nil && (sourceId == nil || $0.id == sourceId) }
    }
    private var session: SessionInfo? { key.flatMap { model.session($0) } }

    var body: some View {
        FitSheet(title: L("后台运行 Claude Code")) {
            VStack(alignment: .leading, spacing: 14) {
                Text("开启后，这台电脑上的新建任务和恢复的会话不再打开 VS Code，由 Kiteline 在那台电脑上后台运行 Claude Code，可减少 VS Code 的内存占用；发送消息、确认均不切换前台，电脑锁屏时也能操作。")
                    .font(.ui(.subheadline))
                Text("后台运行的 Claude Code 就在项目所在的电脑上运行，使用与 VS Code 中的 Claude Code 相同的网络设置（代理、证书、接口地址），每次启动前核对一致才运行。开启前请先检测出口。")
                    .font(.ui(.footnote)).foregroundStyle(.secondary)
                if machines.isEmpty {
                    Text("没有可在后台运行 Claude Code 的电脑（Windows 电脑暂不支持）。").font(.ui(.footnote)).foregroundStyle(.secondary)
                }
                ForEach(machines, id: \.id) { card($0) }
                if model.hostFeatures.contains("editorWindows") { windowsCard }
                if let failure {
                    Text(failure).font(.ui(.footnote)).foregroundStyle(.red)
                }
                if let session, session.hostable, model.sources.first(where: { $0.id == session.sourceId })?.hosted == "on" {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            Task { await move(session) }
                        } label: {
                            Text(moving ? L("正在转到后台…") : L("把当前会话转到后台运行")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.added)
                        .disabled(moving || session.isBusy || session.isWaiting)
                        Text(session.isBusy || session.isWaiting ? L("Claude 正在处理这个会话，请在这一轮完成后再转到后台。")
                                                                 : L("将关闭这个会话在 VS Code 中的标签页，并在后台接着这段对话。"))
                            .font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                #if SNAPSHOT
                Color.clear.frame(height: 0).task {   // 截图版点不了按钮：打开就把每台检测一遍
                    if Snapshot.sheet == "hosted" { for machine in machines { await runProbe(machine.id) } }
                }
                #endif
                if !probes.isEmpty {
                    Text("检测通过查询 IP 的公共网址（如 ipinfo.io）进行，不连接 Claude。若代理按域名分流（例如仅让 Claude 的域名走专线），Claude 实际使用的出口可能与此处显示的不同，但与 VS Code 中的 Claude Code 使用同一套网络设置。")
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 会话都在后台运行后自动关闭项目的 VS Code 窗口（开关），以及电脑上没有会话在运行的窗口、一次关掉
    /// （电脑的 features 里有 editorWindows 才显示；规则见电脑端 EditorWindows.swift / editor_windows.py）
    private var windowsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { model.hosted.closeEditor }, set: { on in Task { await model.setHosted(closeEditor: on) } })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("会话都在后台运行后，自动关闭项目的 VS Code 窗口").font(.ui(.subheadline)).fontWeight(.semibold)
                    Text("窗口中没有其他会话在运行、没有未保存的改动时才会关闭，可减少 VS Code 的内存占用。需要查看代码时，可随时在会话中选择「在 VS Code 中打开」。")
                        .font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.editorIdle.isEmpty {
                Divider()
                Text(L("%lld 个 VS Code 窗口中没有会话在运行", count: model.editorIdle.count)).font(.ui(.subheadline)).fontWeight(.semibold)
                Text(model.editorIdle.joined(separator: "、")).font(.ui(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await closeWindows() }
                } label: {
                    Text(closingWindows ? L("正在关闭…") : L("关闭这些窗口")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(closingWindows)
            } else if windowsLoaded {
                Divider()
                Text("目前没有可以关闭的 VS Code 窗口。").font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if let windowsNote {
                Text(windowsNote).font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .task {
            #if SNAPSHOT
            // 截图版一启动就是这个面板，连接可能还没建好：没问到就隔一秒再问，最多 8 次
            var asked = await model.loadEditorWindows()
            for _ in 0..<8 where !asked {
                try? await Task.sleep(for: .seconds(1))
                asked = await model.loadEditorWindows()
            }
            #else
            let asked = await model.loadEditorWindows()
            #endif
            windowsLoaded = asked   // 没问到就不说「目前没有可以关闭的窗口」
            #if SNAPSHOT
            if Snapshot.closeWindows, !model.editorIdle.isEmpty {   // 截图版点不了按钮：替它点一下，看关完以后的样子
                try? await Task.sleep(for: .seconds(2))
                await closeWindows()
            }
            #endif
        }
    }

    private func closeWindows() async {
        closingWindows = true
        windowsNote = nil
        defer { closingWindows = false }
        do {
            let result = try await model.closeEditorWindows()
            if result.closed > 0 { model.flash(L("已关闭 %lld 个窗口", count: result.closed)) }
            if result.left > 0 { windowsNote = L("%lld 个窗口未能关闭，VS Code 可能正在等待确认，请到电脑上查看", count: result.left) }
        } catch {
            windowsNote = error.localizedDescription
        }
    }

    @ViewBuilder private func card(_ machine: SourceInfo) -> some View {
        let on = machine.hosted == "on"
        let probe = probes[machine.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(machine.name).font(.ui(.subheadline).weight(.semibold))
                Text(on ? L("已开启") : machine.online ? L("未开启") : L("离线"))
                    .font(.ui(.caption2).weight(.semibold))
                    .foregroundStyle(on ? Theme.added : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((on ? Theme.added : Color.secondary).opacity(0.12), in: Capsule())
                Spacer(minLength: 0)
            }
            if on, let issue = machine.hostedIssue {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近一次后台启动未成功").font(.ui(.caption).weight(.semibold)).foregroundStyle(.orange)
                    Text(L(issue.reason) + (issue.detail.map { "（\($0)）" } ?? "")).font(.ui(.caption)).textSelection(.enabled)
                    Text(L(issue.fix)).font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }
            if let probe {
                if let error = probe.error {
                    Text(error).font(.ui(.footnote)).foregroundStyle(.secondary)
                } else {
                    row(L("出口 IP"), probe.ip ?? L("未能查到（网络不通或代理不可用）"), mono: probe.ip != nil)
                    if let place = probe.place { row(L("地区"), place) }
                    if let org = probe.org, !org.isEmpty { row(L("网络"), org) }
                    row(L("网络设置"), probe.source == "vscode" ? L("与 VS Code 中运行的 Claude Code 一致")
                                       : probe.source == "shell" ? L("按终端环境（VS Code 中目前没有运行的 Claude Code）") : L("测试环境"))
                    if probe.settings.isEmpty {
                        row(L("代理"), L("未设置（使用电脑本身的网络）"))
                    } else {
                        ForEach(probe.settings, id: \.0) { name, value in row(name, value, mono: true) }
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task { await runProbe(machine.id) }
                } label: {
                    Label(probe == nil ? L("检测出口 IP") : L("重新检测"), systemImage: "network")
                }
                .buttonStyle(.bordered)
                .disabled(probing.contains(machine.id) || !machine.online)
                if probing.contains(machine.id) {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                if on {
                    Button(role: .destructive) {
                        Task { await set(machine.id, false) }
                    } label: { Text("关闭") }
                    .buttonStyle(.bordered)
                    .disabled(saving.contains(machine.id))
                } else {
                    Button {
                        Task { await set(machine.id, true) }
                    } label: { Text("确认开启") }
                    .buttonStyle(.borderedProminent).tint(Theme.added)
                    .disabled(probe?.ip == nil || saving.contains(machine.id))
                }
            }
            if !on, probe?.ip == nil, !probing.contains(machine.id) {
                Text("检测到出口后才能开启。").font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.ui(.footnote)).foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
            Text(value).font(mono ? .system(.footnote, design: .monospaced) : .ui(.footnote)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runProbe(_ id: String) async {
        probing.insert(id)
        failure = nil
        defer { probing.remove(id) }
        do {
            let reply = try await model.api.post("/api/hosted/probe", body: ["sourceId": id])
            if let raw = (reply["machines"] as? [[String: Any]] ?? []).first(where: { $0["id"] as? String == id }) {
                probes[id] = HostedProbe(raw)
            }
        } catch {
            failure = L("检测未完成：%@", error.localizedDescription)
        }
    }

    private func set(_ id: String, _ value: Bool) async {
        saving.insert(id)
        defer { saving.remove(id) }
        await model.setHosted(sourceId: id, on: value)
    }

    private func move(_ session: SessionInfo) async {
        moving = true
        failure = nil
        defer { moving = false }
        do {
            let reply = try await model.api.post("/api/hosted/move", ["key": session.key])
            model.flash(reply["message"] as? String ?? L("已转到后台运行"))
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
