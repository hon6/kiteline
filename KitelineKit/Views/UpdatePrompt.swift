#if !KITELINE_MAC
import SwiftUI

// 新版本提醒（AppUpdates）在界面上的几处：打开 App 时弹出的面板、设置里点「可更新至」进去的页面；
// 首页顶上的「有新版本」提示条在 RemoteNotices.swift。

/// 打开 App 时弹出：这台手机和连着的电脑各有什么新版本、更新了什么；底下「此版本不再提示」，右上角「以后再说」（24 小时后再提醒）
struct UpdatePromptSheet: View {
    private let updates = AppUpdates.shared

    var body: some View {
        let offers = updates.prompt ?? []
        FitSheet(title: L("发现新版本"), doneTitle: L("以后再说")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(offers) { offer in
                    UpdateOfferCard(offer: offer)
                }
                SkipToggle(offers: offers)
            }
        }
    }
}

/// 设置里点「可更新至 x.y」进来：同一张卡片，和「此版本不再提示」
struct UpdateOfferPage: View {
    let app: Bool
    private let updates = AppUpdates.shared

    var body: some View {
        ScrollView {
            if let offer = app ? updates.appOffer : updates.hostOffer {
                VStack(alignment: .leading, spacing: 14) {
                    UpdateOfferCard(offer: offer)
                    SkipToggle(offers: [offer])
                }
                .padding(16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(L("已是最新版本"), systemImage: "checkmark.circle")
                    .padding(.top, 60)
            }
        }
        .background(Theme.pageBackground)
        .navigationTitle(L("新版本"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SkipToggle: View {
    let offers: [UpdateOffer]
    private let updates = AppUpdates.shared

    var body: some View {
        Toggle(isOn: Binding(get: { !offers.isEmpty && offers.allSatisfy(updates.isSkipped) }, set: { updates.setSkipped(offers, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(offers.count > 1 ? L("这些版本不再提示") : L("此版本不再提示")).font(.ui(.body))
                Text("有更新的版本时会再次提示").font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 一项新版本：哪一端、当前版本 → 新版本、落后的各版本更新内容、怎么更新
struct UpdateOfferCard: View {
    let offer: UpdateOffer
    private let updates = AppUpdates.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TarsIcon(symbol: offer.isApp ? (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") : "desktopcomputer", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(.headline))
                    Text(L("当前版本 %@ · 新版本 %@", offer.current, offer.version))
                        .font(.ui(.subheadline)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ForEach(offer.releases) { release in
                VStack(alignment: .leading, spacing: 6) {
                    // 只有一版时标题里已经写了版本号，不再重复
                    if offer.releases.count > 1 || !release.date.isEmpty {
                        Text(release.date.isEmpty ? release.version : "\(release.version) · \(release.date)")
                            .font(.ui(.footnote).weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ReleaseNotesText(text: release.notes)
                }
            }
            if offer.isApp {
                PrimaryGlassButton(title: L("前往 App Store 更新")) { Task { await updates.openStore(openURL) } }
            } else {
                HostUpdateAction(offer: offer)
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var title: String {
        switch offer.kind {
        case .app: return UIDevice.current.userInterfaceIdiom == .pad ? L("iPad 上的 Kiteline") : L("iPhone 上的 Kiteline")
        case .host(_, let name): return name.isEmpty ? L("电脑上的 Kiteline") : L("「%@」上的 Kiteline", name)
        }
    }
}

/// 电脑那一项怎么更新：新版电脑端能从手机上让它下载安装、重启；旧版电脑端（没有接口）、开发版只能在电脑上操作
private struct HostUpdateAction: View {
    let offer: UpdateOffer
    private let updates = AppUpdates.shared

    var body: some View {
        if updates.hostOffer?.version != offer.version, let done = updates.hostDone, done == offer.version {
            Label(L("电脑端已更新到 %@", done), systemImage: "checkmark.circle.fill")
                .font(.ui(.subheadline).weight(.medium)).foregroundStyle(.green)
        } else if let state = updates.hostState, updates.hostOffer?.version == offer.version {
            if !state.supported {
                PageNote(text: L("%@，请在电脑上到官网下载新版本。", state.reason.isEmpty ? L("此电脑无法自动更新") : state.reason))
            } else {
                switch state.phase {
                case "downloading":
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: state.progress).tint(Theme.claude)
                        HStack {
                            Text(state.size > 0 ? L("正在电脑上下载 · %@ / %@", bytes(state.received), bytes(state.size)) : L("正在电脑上下载…"))
                                .font(.ui(.footnote)).foregroundStyle(.secondary)
                            Spacer()
                            Button("取消") { Task { await updates.hostAction("cancel") } }.font(.ui(.footnote))
                        }
                    }
                case "installing":
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView().progressViewStyle(.linear).tint(Theme.claude)
                        Text("正在电脑上安装，不影响电脑上的会话。").font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                case "ready":
                    PrimaryGlassButton(title: L("重启电脑端 Kiteline")) { Task { await updates.hostAction("restart") } }
                    PageNote(text: L("新版本已在电脑上装好。重启需要十几秒，期间手机会暂时断开，之后自动重新连接；电脑上正在进行的会话不受影响。"))
                case "restarting":
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView().progressViewStyle(.linear).tint(Theme.claude)
                        Text("电脑端 Kiteline 正在重启，稍后自动重新连接…").font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                default:
                    if state.phase == "error", !state.error.isEmpty {
                        PageNote(text: state.error, color: Theme.removed)
                    }
                    PrimaryGlassButton(title: state.phase == "error" ? L("重试") : L("在电脑上下载并安装")) { Task { await updates.hostAction("start") } }
                    PageNote(text: L("电脑在后台下载安装，装好后重启电脑端 Kiteline 即可完成更新。"))
                }
            }
        } else {
            // 旧版电脑端没有让手机来更新的接口
            PageNote(text: L("请在电脑上点击 Kiteline 侧栏底部的绿色箭头完成更新。"))
        }
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

/// 更新内容：「新功能」「改进」这种分节标题加粗，「· 」开头的一条条缩进排
private struct ReleaseNotesText: View {
    let text: String

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if let item = Self.bullet(line) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "·").foregroundStyle(.secondary)
                        Text(verbatim: item).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.ui(.subheadline))
                } else {
                    Text(verbatim: line).font(.ui(.subheadline).weight(.semibold))
                        .padding(.top, index == 0 ? 0 : 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// 「· 内容」「- 内容」「• 内容」→ 内容；不是一条就 nil
    private static func bullet(_ line: String) -> String? {
        for mark in ["· ", "• ", "- ", "·", "•"] where line.hasPrefix(mark) {
            return String(line.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
#endif
