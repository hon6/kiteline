import SwiftUI

/// 会话菜单「分享只读链接」：生成一个局域网网址，同一网络里的人用浏览器就能看这个会话（对话和步骤，只读）。
/// 页面和内容都由电脑直接给（见 Sources/GuestLinks.swift），不经过任何服务器；可选有效期，随时停止分享
struct GuestShareSheet: View {
    @Environment(AppModel.self) private var model
    let key: String

    struct Share: Identifiable {
        let id: String
        let url: String
        let expires: Double
    }

    @State private var shares: [Share] = []
    @State private var hours = 24
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        FitSheet(title: L("分享只读链接")) {
            VStack(alignment: .leading, spacing: 14) {
                Text("生成一个局域网网址，和这台电脑在同一网络（Wi-Fi）里的人用浏览器就能查看这个会话，不用装 Kiteline：对话和执行的步骤，不含思考过程、图片和关键信息。会话有进展时，对方的页面自动更新。")
                    .font(.ui(.footnote)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let share = shares.first {
                    active(share)
                } else if loaded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("有效期").font(.ui(.subheadline).weight(.medium))
                        LookSegmented(selection: $hours, options: [(1, L("1 小时")), (24, L("24 小时")), (168, L("7 天"))])
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error {
                    Text(error).font(.ui(.footnote)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("页面和内容直接由你的电脑提供，不经过任何服务器；电脑关机或不在这个网络时打不开。拿到网址的人都能查看，请只发给信任的人；停止分享后立即失效。")
                    .font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } bottom: {
            Button(action: { Task { await (shares.isEmpty ? create() : stop()) } }) {
                Text(shares.isEmpty ? L("生成链接") : L("停止分享"))
                    .font(.ui(.body).weight(.semibold)).foregroundStyle(shares.isEmpty ? .white : .red)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(shares.isEmpty ? Theme.wechatGreen.opacity(busy || !loaded ? 0.4 : 1) : Color.red.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .disabled(busy || !loaded)
        }
        // 打开面板时可能正在重连电脑：连上了再读一次
        .task(id: model.connected) { if model.connected { await load() } }
    }

    /// 正在分享：链接、有效期、复制、转发
    private func active(_ share: Share) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(share.url).font(.system(.footnote, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.wechatGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.wechatGreen.opacity(0.25), lineWidth: 0.5))
            Text(L("有效至 %@", Date(timeIntervalSince1970: share.expires).formatted(date: .abbreviated, time: .shortened)))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { Clipboard.copy(share.url) } label: { Label("复制链接", systemImage: "doc.on.doc") }
                if let url = URL(string: share.url) {
                    ShareLink(item: url) { Label("转发", systemImage: "square.and.arrow.up") }
                }
            }
            .font(.ui(.subheadline))
        }
    }

    private func load(attempt: Int = 0) async {
        error = nil
        do {
            let reply = try await model.api.get("/api/share", ["key": key])
            shares = Self.parse(reply["shares"])
        } catch {
            // 打开面板时正赶上重连：任务被取消就等连上后的那次再读；请求被掐断（已取消）就稍后再读，都不算出错
            if Task.isCancelled { return }
            if (error as? URLError)?.code == .cancelled, attempt < 3 {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { await load(attempt: attempt + 1) }
                return
            }
            self.error = L("无法读取分享状态：%@", error.localizedDescription)
        }
        loaded = true
    }

    private func create() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let reply = try await model.api.post("/api/share", body: ["key": key, "hours": hours])
            shares = Self.parse([reply])
            if let url = shares.first?.url { Clipboard.copy(url) }   // 生成了就顺手复制好
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() async {
        guard let share = shares.first else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            _ = try await model.api.post("/api/share/stop", body: ["id": share.id])
            shares.removeAll { $0.id == share.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func parse(_ value: Any?) -> [Share] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let url = item["url"] as? String else { return nil }
            return Share(id: id, url: url, expires: (item["expires"] as? NSNumber)?.doubleValue ?? 0)
        }
    }
}
