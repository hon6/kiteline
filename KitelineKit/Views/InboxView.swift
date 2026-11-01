import SwiftUI

/// 通知收件箱（同网页版）：Kiteline 发过的每条提醒都在这里，含免打扰时没推到锁屏的；早上起来翻一遍就知道夜里发生了什么
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @State private var entries: [InboxEntry]?
    @State private var error: String?
    @State private var seenBefore: Double = UserDefaults.standard.double(forKey: "inboxSeen")
    @AppStorage("inboxFilter") private var filter = "all"

    var body: some View {
        let all = entries ?? []
        let held = all.filter { $0.delivery != "sent" }
        let shown = filter == "held" ? held : all
        List {
            // 读到了才显示筛选：还在读、读失败时显示「全部 0」像是真的一条都没有
            if entries != nil {
                Section {
                    Picker("筛选", selection: $filter) {
                        Text("全部 \(all.count)").tag("all")
                        Text("未推送到锁屏 \(held.count)").tag("held")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            ForEach(days(shown), id: \.0) { day, list in
                Section {
                    ForEach(list) { entry in
                        Button { target(entry) } label: { row(entry) }.buttonStyle(RowButtonStyle())
                    }
                } header: {
                    Text(day).font(.sectionHeader)
                }
            }
            if entries != nil, shown.isEmpty {
                // 空状态照系统样式（图标 + 标题 + 说明）
                Group {
                    if all.isEmpty {
                        ContentUnavailableView {
                            Label("暂无通知", systemImage: "bell")
                        } description: {
                            Text("Claude 需要确认、完成任务或发来图片时，将在此处记录。")
                        }
                    } else {
                        ContentUnavailableView {
                            Label("均已推送到锁屏", systemImage: "bell.badge")
                        } description: {
                            Text("免打扰时段内未推送的提醒会显示在这里。")
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        // 筛选条是第一行：去掉分组列表给第一组留的那一大截上边距
        .contentMargins(.top, 4, for: .scrollContent)
        .overlay { if entries == nil { if let error { LoadFailed(error: error) { await load() } } else { ProgressView() } } }
        .navigationTitle("通知")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ e: InboxEntry) -> some View {
        let (icon, what) = e.icon
        let unread = e.ts > seenBefore
        return HStack(alignment: .top, spacing: 10) {
            TarsIcon(symbol: icon, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(e.title).font(.ui(.subheadline).weight(unread ? .semibold : .regular)).foregroundStyle(.primary).lineLimit(1)
                    Text(what).font(.ui(.caption2).weight(.medium)).foregroundStyle(kindColor(e.kind))
                    Spacer(minLength: 4)
                    Text(Format.listTime(e.ts)).font(.ui(.caption)).foregroundStyle(.tertiary)
                }
                if !e.body.isEmpty { Text(e.body).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(3) }
                if let reason = e.heldReason { Label(reason, systemImage: "bell.slash").font(.ui(.caption2)).foregroundStyle(.tertiary) }
            }
            if unread { Circle().fill(Theme.removed).frame(width: 7, height: 7).padding(.top, 6) }
        }
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "attention", "stuck", "editor", "link": return .orange
        case "error", "budget": return Theme.removed
        case "conclusion": return Theme.added
        default: return .secondary
        }
    }

    private func days(_ list: [InboxEntry]) -> [(String, [InboxEntry])] {
        var order: [String] = []
        var map: [String: [InboxEntry]] = [:]
        for e in list {
            let day = DayLabel.of(e.ts)
            if map[day] == nil { order.append(day) }
            map[day, default: []].append(e)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    /// 点一条：日报 → 今日动态，花费 → 用量，定时任务 → 定时任务，其余打开那个会话
    private func target(_ e: InboxEntry) {
        if let route = Route(notifyRoute: e.route) { open(route) } else if let key = e.key { open(.chat(key)) }
    }

    private func load() async {
        do {
            let list = try await model.api.get(InboxReply.self, "/api/inbox", ["limit": "200"]).entries
            entries = list
            error = nil
            if let latest = list.first?.ts { model.markInboxSeen(latest) } else { model.markInboxSeen(0) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension Route {
    /// 提醒里带的 route（today / usage / schedules / group:<群 id>）
    init?(notifyRoute: String?) {
        switch notifyRoute {
        case "today": self = .today
        case "usage": self = .usage
        case "schedules": self = .schedules
        case "todos": self = .todos
        case "groups": self = .groups
        case let route? where route.hasPrefix("group:"): self = .group(String(route.dropFirst(6)))
        default: return nil
        }
    }
}

/// 列表右上角的铃铛：通知收件箱，有没看过的就带数字
struct InboxBell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open

    var body: some View {
        Button { open(.inbox) } label: {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if model.inboxUnread > 0 {
                        Text(model.inboxUnread > 99 ? "99+" : "\(model.inboxUnread)")
                            .font(.appFixed(size: 10, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(Theme.removed, in: Capsule())
                            .offset(x: 9, y: -8)
                    }
                }
                .barIcon()
        }
        .accessibilityLabel(model.inboxUnread > 0 ? "通知，\(model.inboxUnread) 条未读" : "通知")
    }
}

/// 网差 / 连不上时顶上的一条：「网络较差 · ↓ 80 KB/s · 延迟 950 ms」
struct NetStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 在别处的 Wi-Fi 上开着 Tailscale 这类组网：免费版不经隧道连，说清楚这算远程访问（否则一直「连接中」不知道为什么）
        let viaTunnel = !model.connected && !Store.shared.isPro && model.api.lanViaTunnel
        if !model.connected, !Store.shared.isPro, !NetPath.shared.onLAN || model.everConnected || viaTunnel {
            Button { _ = model.requirePro(.remote) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                    if viaTunnel {
                        Text("经 VPN 连接属于远程访问").lineLimit(1)
                    } else {
                        Text("不在电脑所在的 Wi-Fi 中").lineLimit(1)
                    }
                    Text("订阅远程访问").fontWeight(.semibold)
                }
                .font(.ui(.caption))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.claude.opacity(0.95), in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            strip
        }
    }

    @ViewBuilder
    private var strip: some View {
        let net = model.net
        let text: String? = {
            if !model.connected, model.everConnected {
                return net.quality == .offline ? L("无法连接电脑，正在重新连接…（当前显示上次缓存的内容）") : L("连接已断开，正在重新连接…")
            }
            if model.connected, net.quality == .poor { return L("网络较差") + (net.description.isEmpty ? "" : " · " + net.description) }
            return nil
        }()
        if let text {
            HStack(spacing: 6) {
                Image(systemName: model.connected ? "wifi.exclamationmark" : "arrow.triangle.2.circlepath")
                Text(text).lineLimit(1)
            }
            .font(.ui(.caption))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background((model.connected ? Color.orange : Color.gray).opacity(0.92), in: Capsule())
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
