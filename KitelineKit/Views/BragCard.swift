import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
import Photos
#endif

// 分享战绩：把某一天（或某段时间、某个任务）用了多少 token、改了多少行、在线多久、用了哪些 Agent 画成一张图，发微信好友 / 朋友圈。
// 只有数字，不含对话内容、项目名、文件名。数据来自电脑端 GET /api/brag。
//
// 统计、文案、六套主题的画法只有一份：miniprogram/lib/brag.js（小程序直接用）。iPhone 在后台 WebView 里跑同一份脚本画到画布上再取图，
// 由 tools/sync-brag.sh 拷进包里（brag-script.js、brag-*.png）。这里只管界面：选范围、选主题、换一句、显示花费、发出去。

/// 六套主题：和 brag.js 的 THEMES 对上（id、强调色）
enum BragTheme: String, CaseIterable, Identifiable {
    case token, vibe, code, lineup, boss, streak
    var id: String { rawValue }
    var title: String {
        switch self {
        case .token: L("算力")
        case .vibe: L("Vibe 时长")
        case .code: L("代码")
        case .lineup: L("阵容")
        case .boss: L("指挥官")
        case .streak: L("出勤")
        }
    }
    var accent: Color {
        switch self {
        case .token: Color(red: 1, green: 0.541, blue: 0.357)
        case .vibe: Color(red: 0.31, green: 0.82, blue: 0.91)
        case .code: Color(red: 0.247, green: 0.725, blue: 0.314)
        case .lineup: Color(red: 0.91, green: 0.753, blue: 0.478)
        case .boss: Color(red: 0.655, green: 0.545, blue: 0.98)
        case .streak: Color(red: 0.224, green: 0.827, blue: 0.325)
        }
    }
    /// 一个任务没有 24 小时曲线、出勤、并行：只给这四套
    static let forSession: [BragTheme] = [.token, .code, .vibe, .lineup]
}

/// 分享的是哪段时间（id 和 brag.js 的 RANGES 一样）
enum BragRange: String, CaseIterable, Identifiable {
    case today, yesterday, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: L("今天")
        case .yesterday: L("昨天")
        case .week: L("近 7 天")
        case .month: L("近 30 天")
        }
    }
}

// MARK: - 画图（后台 WebView 跑 brag.js）

/// 一张画好的卡片和脚本回的说明
struct BragRender {
    var image: PlatformImage
    var range: String
    var lineCount: Int
    var shareTitle: String
}

struct BragError: LocalizedError {
    var text: String
    var errorDescription: String? { text }
}

@MainActor
final class BragRenderer: NSObject, WKNavigationDelegate {
    static let shared = BragRenderer()
    private var web: WKWebView?
    private var loading: [CheckedContinuation<Void, Error>] = []
    private var loaded = false

    /// 第一次用时建 WebView、载入脚本和图（图转成 data URI：file:// 的图画上去会污染画布，取不出图片）
    private func prepare() async throws {
        if loaded, web != nil { return }
        if web == nil {
            guard let script = Bundle.main.url(forResource: "brag-script", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
                throw BragError(text: L("缺少分享卡片的绘制脚本，请重新安装 App"))
            }
            var assets: [String: String] = ["inline": "1"]
            func dataURI(_ name: String, _ ext: String, mime: String) -> String? {
                Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? Data(contentsOf: $0) }
                    .map { "data:\(mime);base64," + $0.base64EncodedString() }
            }
            assets["kite"] = dataURI("brag-kite", "png", mime: "image/png")
            assets["code"] = dataURI("brag-mpcode", "jpg", mime: "image/jpeg")
            for url in Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? [] {
                let name = url.deletingPathExtension().lastPathComponent
                guard name.hasPrefix("brag-agent-"), let data = try? Data(contentsOf: url) else { continue }
                assets["agent:" + name.dropFirst("brag-agent-".count)] = "data:image/png;base64," + data.base64EncodedString()
            }
            let assetJSON = String(data: (try? JSONSerialization.data(withJSONObject: assets)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            // 脚本里不会出现 </script>，直接内嵌
            let html = """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
            <script>var module = { exports: {} };</script>
            <script>\(script)</script>
            <script>window.KL = module.exports; window.KL_ASSETS = \(assetJSON);</script>
            </body></html>
            """
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 540), configuration: WKWebViewConfiguration())
            view.navigationDelegate = self
            web = view
            view.loadHTMLString(html, baseURL: nil)
        }
        try await withCheckedThrowingContinuation { loading.append($0) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            loaded = true
            loading.forEach { $0.resume() }
            loading = []
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    /// 网页进程被系统收掉了（后台久了）：下次重新建
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in self.web = nil; self.loaded = false }
    }

    private func fail(_ error: Error) {
        web = nil
        loaded = false
        loading.forEach { $0.resume(throwing: error) }
        loading = []
    }

    /// payload：/api/brag 回的原样 JSON；options：theme、range（不给就由脚本挑）、lineIndex、showCost、en
    func render(payload: String, options: [String: Any]) async throws -> BragRender {
        try await prepare()
        guard let web else { throw BragError(text: L("生成图片失败")) }
        let opts = String(data: try JSONSerialization.data(withJSONObject: options), encoding: .utf8) ?? "{}"
        let script = """
        const c = document.createElement('canvas');
        const o = JSON.parse(opts); o.assets = o.code ? Object.assign({}, window.KL_ASSETS, { code: o.code }) : window.KL_ASSETS;
        const meta = await window.KL.renderForHost(c, JSON.parse(payload), o);
        meta.image = c.toDataURL('image/jpeg', 0.92);
        return JSON.stringify(meta);
        """
        let result = try await web.callAsyncJavaScript(script, arguments: ["payload": payload, "opts": opts], contentWorld: .page)
        guard let text = result as? String, let meta = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let uri = meta["image"] as? String, let comma = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])), let image = PlatformImage(data: data) else {
            throw BragError(text: L("生成图片失败"))
        }
        return BragRender(image: image, range: meta["range"] as? String ?? "", lineCount: meta["lineCount"] as? Int ?? 1,
                          shareTitle: meta["shareTitle"] as? String ?? "")
    }
}

// MARK: - 早上自动弹出

/// 每天早上 8 点以后第一次打开 App 弹一次昨日战绩（11-11 起的 8 点）：昨天确实干过活才弹；分享页里能关掉
enum MorningBrag {
    static let enabledKey = "brag.morning"
    private static let shownKey = "brag.morningShown"

    @MainActor
    static func due(_ model: AppModel, now: Date = Date()) async -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) as? Bool ?? true, model.connected, model.hostFeatures.contains("brag"),
              Calendar.current.component(.hour, from: now) >= 8 else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        guard defaults.string(forKey: shownKey) != today else { return false }
        guard let data = try? await model.api.data("/api/brag", ["days": "2"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        defaults.set(today, forKey: shownKey)   // 今天问过了：昨天没干活也不再问
        let yesterday = formatter.string(from: now.addingTimeInterval(-86400))
        let day = (json["days"] as? [[String: Any]] ?? []).first { $0["day"] as? String == yesterday } ?? [:]
        let tokens = ["input", "output", "cacheRead", "cacheWrite"].reduce(0.0) { $0 + ((day[$1] as? NSNumber)?.doubleValue ?? 0) }
        return ((day["sessions"] as? NSNumber)?.doubleValue ?? 0) > 0 || tokens > 0
    }
}

// MARK: - 分享页

/// 「分享战绩」：选时间段、选主题、换一句、要不要露花费，然后发微信 / 存相册。sessionKey 给了就是这个会话（任务）的
struct BragShareSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    var sessionKey: String?
    /// 一打开就看这一段（早上自动弹出、今日动态里点的都是昨天）
    var initialRange: BragRange?

    @State private var payload: String?
    /// 推荐码专属的小程序码（data URI）：扫了能认出是谁带来的；取不到就用包里通用的码
    @State private var code: String?
    @State private var range: BragRange?
    @State private var lineIndex = 0
    @State private var rendered: BragRender?
    @State private var busy = false
    @State private var error: String?
    @AppStorage("brag.showCost") private var showCost = false
    @AppStorage("brag.theme") private var themeID = BragTheme.token.rawValue
    @AppStorage(MorningBrag.enabledKey) private var morning = true

    private var themes: [BragTheme] { sessionKey == nil ? BragTheme.allCases : BragTheme.forSession }
    private var theme: BragTheme {
        let picked = BragTheme(rawValue: themeID) ?? .token
        return themes.contains(picked) ? picked : .token
    }
    /// 选项一变就重画
    private var renderKey: String { "\(payload?.count ?? 0)|\(range?.rawValue ?? "")|\(theme.rawValue)|\(lineIndex)|\(showCost)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if sessionKey == nil {
                        Picker(L("范围"), selection: Binding(get: { range ?? .today }, set: { range = $0; lineIndex = 0 })) {
                            ForEach(BragRange.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    themePicker
                    if let error {
                        LoadFailed(error: error) { await load() }.padding(.top, 40)
                    } else if let rendered {
                        Image(platform: rendered.image)
                            .resizable()
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .frame(maxWidth: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .opacity(busy ? 0.7 : 1)
                            .frame(maxWidth: .infinity)
                        controls(rendered)
                    } else {
                        ProgressView(L("正在统计各台电脑的数据…")).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(16)
            }
            .background(Theme.pageBackground)
            .navigationTitle(sessionKey == nil ? L("分享战绩") : L("分享本次任务"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("关闭")) { dismiss() } }
            }
        }
        .task {
            if range == nil, let initialRange { range = initialRange }
            await load()
        }
        .task(id: renderKey) { await draw() }
    }

    /// 主题：一排胶囊，选中的描主题色边
    private var themePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(themes) { item in
                    let on = item == theme
                    Button {
                        Haptics.tap()
                        themeID = item.rawValue
                        lineIndex = 0
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(item.accent).frame(width: 7, height: 7)
                            Text(item.title).font(.ui(.subheadline).weight(.semibold))
                        }
                        .foregroundStyle(on ? item.accent : Color.primary)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? item.accent : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func controls(_ rendered: BragRender) -> some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tap()
                lineIndex += 1
            } label: {
                Label(L("换一句"), systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(rendered.lineCount < 2)
            Toggle(isOn: $showCost) { Text(L("显示花费")).font(.ui(.subheadline)) }
                .toggleStyle(.button).buttonStyle(.bordered)
        }
        VStack(spacing: 10) {
            Button {
                Haptics.tap()
                noteShare("friend")
                SystemShare.present([rendered.image])
            } label: {
                Label(L("发给微信好友"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(Theme.wechatGreen)
            Button {
                noteShare("moments")
                Task { await saveForMoments(rendered.image) }
            } label: {
                Label(L("保存图片，发朋友圈"), systemImage: "photo.on.rectangle").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
        if sessionKey == nil {
            Toggle(isOn: $morning) {
                Text(L("每天第一次打开时弹出昨日战绩")).font(.ui(.subheadline))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        Text(L("图片只有数字，不包含对话内容、项目名和文件名。图片下方带 Kiteline 小程序码，好友长按即可识别。"))
            .font(.ui(.caption)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 告诉电脑点了一次分享（按设备记次数，运营后台看谁分享了多少次）；失败不管，不打扰分享
    private func noteShare(_ via: String) {
        let body: [String: Any] = ["via": via, "theme": theme.rawValue, "range": sessionKey == nil ? (range?.rawValue ?? "") : "session"]
        Task { _ = try? await model.api.post("/api/brag/shared", body: body) }
    }

    private func load() async {
        error = nil
        do {
            let query = sessionKey.map { ["key": $0] } ?? ["days": "30"]
            let data = try await model.api.data("/api/brag", query)
            var ref = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ref"] as? String
            if ref == nil, sessionKey != nil {   // 一个任务的接口不带推荐码：问一次按天的（有缓存，很快）
                ref = (try? await model.api.get("/api/brag", ["days": "1"]))?["ref"] as? String
            }
            if let ref { code = await Self.personalCode(ref) }
            payload = String(data: data, encoding: .utf8)
        } catch {
            let text = "\(error)"
            self.error = text.contains("404") ? L("电脑上的 Kiteline 版本较旧，更新到最新版本后即可分享战绩") : (error as? LocalizedError)?.errorDescription ?? text
        }
    }

    /// 中继按推荐码生成的小程序码（只有 8 位十六进制的推荐码，不带别的）；8 秒取不到就算了
    private static func personalCode(_ ref: String) async -> String? {
        guard ref.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil,
              let url = URL(string: "https://tars.betac.cn/mp/pay/code?ref=\(ref)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), mime.hasPrefix("image/") else { return nil }
        return "data:\(mime);base64," + data.base64EncodedString()
    }

    private func draw() async {
        guard let payload else { return }
        busy = true
        defer { busy = false }
        var options: [String: Any] = ["theme": theme.rawValue, "lineIndex": lineIndex, "showCost": showCost, "en": Lang.shared.isEnglish]
        if let code { options["code"] = code }
        if let range { options["range"] = range.rawValue }
        do {
            let result = try await BragRenderer.shared.render(payload: payload, options: options)
            guard !Task.isCancelled else { return }
            rendered = result
            // 第一次由脚本挑范围（今天还没怎么用就是昨天）
            if sessionKey == nil, range == nil { range = BragRange(rawValue: result.range) ?? .today }
        } catch {
            if !Task.isCancelled { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    /// 微信朋友圈不接收别的 App 直接发图：先存相册，再打开微信，在朋友圈里选这张
    @MainActor
    private func saveForMoments(_ image: PlatformImage) async {
        #if canImport(UIKit)
        guard await Permissions.shared.ensure(.photos) else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            model.flash(L("已存到相册，在微信朋友圈选择这张图即可"))
            if let url = URL(string: "weixin://") {
                try? await Task.sleep(for: .milliseconds(900))
                await UIApplication.shared.open(url)
            }
        } catch {
            model.flash(L("无法存到相册：%@", "\(error.localizedDescription)"))
        }
        #endif
    }
}

// MARK: - 首页、今日动态上的战绩条

/// 一眼看到的战绩：Token、新增代码、在线时长、最多同时几个 Agent；点了打开分享页（同一段时间）。
/// 11-11：首页和今日动态都要有个平时能点进去看、能分享的地方
struct BragStrip: View {
    @Environment(AppModel.self) private var model
    var range: BragRange = .today
    /// 首页上用浅灰底（同上面的今日用量卡片），别的页面用白卡片
    var onTile = false
    @State private var days: [[String: Any]] = []
    @State private var loaded = false
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill").foregroundStyle(KiteColor.brand)
                    Text(title).font(.ui(.subheadline).weight(.semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Label(L("分享"), systemImage: "square.and.arrow.up")
                        .font(.ui(.caption).weight(.semibold)).foregroundStyle(KiteColor.brand)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(KiteColor.brand.opacity(0.12), in: Capsule())
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    metric(BragNumber.short(sum("input") + sum("output") + sum("cacheRead") + sum("cacheWrite")), L("Token"))
                    metric("+" + BragNumber.short(sum("linesAdded")), L("行代码"))
                    metric(BragNumber.hours(sum("activeMinutes")), L("在线"))
                    metric("\(Int(peak))", L("最多同时"))
                }
                .redacted(reason: loaded ? [] : .placeholder)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(onTile ? Theme.tile : Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
        .task(id: "\(model.connected)|\(range.rawValue)") {
            // 进来先拉一次，之后每 5 分钟（同首页用量）；电脑端有 60 秒缓存
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .sheetPanel(isPresented: $show) { BragShareSheet(initialRange: range).environment(model) }
    }

    private var title: String {
        switch range {
        case .today: L("今日战绩")
        case .yesterday: L("昨日战绩")
        case .week: L("近 7 天战绩")
        case .month: L("近 30 天战绩")
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ui(.headline).monospacedDigit()).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 这段时间包含的天（同 brag.js makeStats）
    private var picked: [[String: Any]] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let sorted = days.filter { ($0["day"] as? String ?? "") <= today }.sorted { ($0["day"] as? String ?? "") < ($1["day"] as? String ?? "") }
        switch range {
        case .today: return sorted.filter { $0["day"] as? String == today }
        case .yesterday:
            let yesterday = formatter.string(from: Date().addingTimeInterval(-86400))
            return sorted.filter { $0["day"] as? String == yesterday }
        case .week: return Array(sorted.suffix(7))
        case .month: return Array(sorted.suffix(30))
        }
    }

    private func sum(_ field: String) -> Double { picked.reduce(0) { $0 + (($1[field] as? NSNumber)?.doubleValue ?? 0) } }
    private var peak: Double { picked.map { ($0["peak"] as? NSNumber)?.doubleValue ?? 0 }.max() ?? 0 }

    private func load() async {
        guard model.connected, model.hostFeatures.contains("brag") else { return }
        let want = range == .month ? "30" : range == .week ? "7" : "2"
        guard let data = try? await model.api.data("/api/brag", ["days": want]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        days = json["days"] as? [[String: Any]] ?? []
        loaded = true
    }
}

/// 战绩条上的数字：中文「2.63 亿」「38.2 万」，英文「263M」「38.2K」（同 brag.js number）
enum BragNumber {
    static func short(_ n: Double) -> String {
        func trim(_ v: Double) -> String {
            v >= 100 ? String(Int(v.rounded())) : v >= 10 ? String(format: "%.1f", v).replacingOccurrences(of: ".0", with: "")
                : String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        }
        if Lang.shared.isEnglish {
            if n >= 1e9 { return trim(n / 1e9) + "B" }
            if n >= 1e6 { return trim(n / 1e6) + "M" }
            if n >= 1e4 { return trim(n / 1e3) + "K" }
        } else {
            if n >= 1e8 { return trim(n / 1e8) + " 亿" }
            if n >= 1e4 { return trim(n / 1e4) + " 万" }
        }
        return Int(n.rounded()).formatted()
    }

    static func hours(_ minutes: Double) -> String {
        if minutes < 60 { return Lang.shared.isEnglish ? "\(Int(minutes)) min" : "\(Int(minutes)) 分钟" }
        let h = minutes / 60
        let text = h >= 10 ? String(Int(h.rounded())) : String(format: "%.1f", h).replacingOccurrences(of: ".0", with: "")
        return Lang.shared.isEnglish ? "\(text) h" : "\(text) 小时"
    }
}
