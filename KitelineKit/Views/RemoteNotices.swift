#if !KITELINE_MAC
import SwiftUI

// 远程配置（RemoteConfig）在界面上的几处：首页顶上的公告和「有新版本」、低于最低版本时整屏挡住的「需要更新」；
// 另有电脑上的插件要求更新版本的 Kiteline 时（插件清单的 minApp.ios）首页和那个会话里的提示。

/// 电脑上的插件要求更新版本的 iPhone 版 Kiteline：哪几家 agent、至少要哪个版本；不用更新为 nil
enum PluginAppRequirement {
    @MainActor static func check(_ agents: some Sequence<String>) -> (names: [String], version: VersionNumber)? {
        let current = RemoteConfig.shared.version
        var names: [String] = [], highest: VersionNumber?
        for agent in Set(agents).sorted() {
            guard let text = Agents.requiredAppVersion(agent), let need = VersionNumber(text), current < need else { continue }
            names.append(Agents.info(agent).name)
            if highest.map({ $0 < need }) ?? true { highest = need }
        }
        return highest.map { (names, $0) }
    }

    static func dismissID(_ version: VersionNumber) -> String { "plugin-app:\(version)" }
}

/// 首页顶上：服务器配的公告、「Kiteline x.y 已发布」、电脑上的插件要求更新。都没有就什么都不画
struct RemoteNoticeStrip: View {
    private let remote = RemoteConfig.shared
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let notices = remote.notices()
        let update = remote.updatePrompt
        // 服务器已经在提示新版本时不重复说
        let plugin = update == nil ? PluginAppRequirement.check(model.sessions.map(\.agent))
            .flatMap { remote.dismissed.contains(PluginAppRequirement.dismissID($0.version)) ? nil : $0 } : nil
        if update != nil || plugin != nil || !notices.isEmpty {
            VStack(spacing: 8) {
                if let update {
                    NoticeCard(symbol: "arrow.down.circle", title: L("Kiteline %@ 已发布", update.description),
                               detail: remote.updateNotes ?? L("轻点前往 App Store 更新"),
                               open: { Task { await remote.openStore(openURL) } },
                               close: { withAnimation(.snappy) { remote.dismiss(RemoteConfig.updateID(update)) } })
                }
                if let plugin {
                    NoticeCard(symbol: "arrow.down.circle", title: L("需要更新 Kiteline"),
                               detail: L("电脑上的 %@ 需要 Kiteline %@ 或更高版本才能完整显示，轻点前往 App Store 更新",
                                         plugin.names.joined(separator: Lang.shared.isEnglish ? ", " : "、"), plugin.version.description),
                               open: { Task { await remote.openStore(openURL) } },
                               close: { withAnimation(.snappy) { remote.dismiss(PluginAppRequirement.dismissID(plugin.version)) } })
                }
                ForEach(notices) { notice in
                    NoticeCard(symbol: notice.level == .warning ? "exclamationmark.triangle" : "megaphone",
                               tint: notice.level == .warning ? .orange : Theme.claude,
                               title: notice.title?.text, detail: notice.body?.text,
                               open: notice.url.map { url -> () -> Void in { openURL(url) } },
                               close: notice.dismissible ? { withAnimation(.snappy) { remote.dismiss(notice.id) } } : nil)
                }
            }
        }
    }
}

/// 对话页输入框上方：这个会话的 agent 要求更新版本的 Kiteline 才能完整显示（关不掉，更新了自然就没了）
struct PluginUpdateHint: View {
    let session: SessionInfo
    private let remote = RemoteConfig.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let need = PluginAppRequirement.check([session.agent]) {
            NoticeCard(symbol: "arrow.down.circle", title: L("需要更新 Kiteline"),
                       detail: L("这个会话需要 Kiteline %@ 或更高版本才能完整显示，轻点前往 App Store 更新", need.version.description),
                       open: { Task { await remote.openStore(openURL) } }, close: nil)
                .padding(.horizontal, 10)
        }
    }
}

/// 一条公告：图标、标题、说明；有链接的整条可点，能关的右边一个 ✕（样子同首页的待办提示条）
private struct NoticeCard: View {
    let symbol: String
    var tint: Color = Theme.claude
    let title: String?
    let detail: String?
    let open: (() -> Void)?
    let close: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let open {
                Button(action: open) { content(chevron: close == nil) }
                    .buttonStyle(PressableStyle())
            } else {
                content(chevron: false)
            }
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.ui(.caption).weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("关闭")
            }
        }
        .padding(.leading, 12).padding(.trailing, close == nil ? 12 : 4).padding(.vertical, 10)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func content(chevron: Bool) -> some View {
        HStack(spacing: 10) {
            TarsIcon(symbol: symbol, size: 30, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.primary) }
                // 放在首页 List 的行里时不固定高度会被压成一行
                if let detail { Text(detail).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true) }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 这个版本已经低于服务器要求的最低版本：整屏挡住，只能去 App Store 更新（盖在整个 App 上、启动页下面）。
/// 样子同第一次打开的引导页：纯石墨底、纸鸢、白字、品牌橙的主按钮
struct UpdateGate: View {
    private let remote = RemoteConfig.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        if remote.updateRequired {
            ZStack {
                GlassBackdrop()
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                    KiteMark(line: KiteColor.brand.opacity(0.75)).frame(width: 96, height: 96)
                    Text("需要更新 Kiteline")
                        .font(.ui(.title2).weight(.semibold))
                        .padding(.top, 28)
                    Text("此版本已停止支持，请前往 App Store 更新到最新版本后继续使用。")
                        .font(.ui(.callout))
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                    // 新版本说明（配置里写了才有）
                    if let notes = remote.updateNotes {
                        Text(notes)
                            .font(.ui(.footnote))
                            .foregroundStyle(Palette.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 14)
                    }
                    Spacer(minLength: 28)
                    Text("当前版本 \(remote.version.description)")
                        .font(.ui(.footnote))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.bottom, 16)
                    PrimaryGlassButton(title: L("前往 App Store")) { Task { await remote.openStore(openURL) } }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 26)
                .padding(.bottom, 18)
            }
            .foregroundStyle(Palette.text)
            .environment(\.colorScheme, .dark)
            .transition(.opacity)
        }
    }
}
#endif
