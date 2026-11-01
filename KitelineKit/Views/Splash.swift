#if !KITELINE_MAC
import SwiftUI
import UIKit
import CryptoKit
import ImageIO

// 启动页。冷启动时系统先显示 Info.plist 里的静态启动屏（LaunchBackground 底色 + LaunchMark 标志），
// App 的第一帧接着画一模一样的 SplashMark，停一下后风筝往右上飞走、露出首页——中间没有黑屏，也没有跳动。
//
// 服务器上可以换：https://tars.betac.cn/splash/config.json（relay/splash.sh 发布，字段说明见 relay/splash/README.md）
// 里有正在生效的一条，就在标志之后换成它（整屏图片、标题、跳过）。配置和图片在后台下载、存在 Caches/splash，
// 下次冷启动才用——启动从不等网络；图还没下好的那条这次跳过，没网、配置坏了就是默认的品牌页。

// MARK: - 配置

struct SplashConfig: Decodable {
    var items: [SplashItem] = []

    init(items: [SplashItem] = []) { self.items = items }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 某一条写错（日期格式不对、少了 id）只跳过那一条
        items = (try? container.decode([Lossy].self, forKey: .items))?.compactMap(\.item) ?? []
    }

    private enum CodingKeys: String, CodingKey { case items }
    private struct Lossy: Decodable {
        let item: SplashItem?
        init(from decoder: Decoder) throws { item = try? SplashItem(from: decoder) }
    }
}

struct SplashItem: Decodable, Equatable {
    let id: String
    /// 生效时间段（ISO 8601 带时区，如 2026-11-01T00:00:00+08:00）；不写就一直有效
    var from: Date?
    var until: Date?
    /// 整屏图（相对 config.json 的路径或完整地址）；深色模式可以另给一张
    var image: String?
    var imageDark: String?
    var title: SplashText?
    var subtitle: SplashText?
    /// 停留几秒（1–6）；默认有图 2.5 秒、只有字 1.8 秒
    var duration: Double?
    /// 点图片打开的地址（可以写相对路径，如 /support）
    var link: String?
    /// 每台手机只显示一次（比如新版本介绍）
    var once: Bool?

    func isLive(_ now: Date) -> Bool { (from ?? .distantPast) <= now && now < (until ?? .distantFuture) }
    var hold: Double { min(max(duration ?? (image == nil ? 1.8 : 2.5), 1), 6) }
}

/// 文案：写一个字符串，或者 {"zh": "…", "en": "…"} 按手机语言挑
struct SplashText: Decodable, Equatable {
    let zh: String?
    let en: String?

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            zh = single
            en = single
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zh = try container.decodeIfPresent(String.self, forKey: .zh)
        en = try container.decodeIfPresent(String.self, forKey: .en)
    }

    private enum CodingKeys: String, CodingKey { case zh, en }

    var text: String? {
        // 跟 App 的界面语言（设置里可以和系统不一样）
        let value = Lang.shared.isEnglish ? (en ?? zh) : (zh ?? en)
        return value?.isEmpty == false ? value : nil
    }
}

/// 这次冷启动要显示的一条，和它在手机上的图
struct SplashChoice {
    let item: SplashItem
    let light: URL?
    let dark: URL?
    let link: URL?

    func image(dark isDark: Bool) -> URL? { isDark ? (dark ?? light) : light }
}

// MARK: - 本机缓存

enum SplashStore {
    static let configURL = URL(string: "https://tars.betac.cn/splash/config.json")!
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("splash", isDirectory: true)
    static var configFile: URL { folder.appendingPathComponent("config.json") }
    private static let shownKey = "splashShown"

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 这次显示哪一条（nil = 默认的品牌页）。只读一个几 KB 的文件、查几个文件在不在，不联网
    static func current(now: Date = .now) -> SplashChoice? {
        choose(configFile: configFile, base: configURL, now: now)
    }

    /// base：图片、链接的相对路径相对它算。本地预览（截图版）时就是那份 config.json 自己
    static func choose(configFile: URL, base: URL, now: Date = .now) -> SplashChoice? {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? decoder.decode(SplashConfig.self, from: data) else { return nil }
        let shown = Set(UserDefaults.standard.stringArray(forKey: shownKey) ?? [])
        for item in config.items where item.isLive(now) && !(item.once == true && shown.contains(item.id)) {
            let light = item.image.flatMap { local($0, base: base) }
            // 图还没下好：这次先不用它，下次再说
            if item.image != nil, light == nil { continue }
            let dark = item.imageDark.flatMap { local($0, base: base) }
            let link = item.link.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            return SplashChoice(item: item, light: light, dark: dark, link: link)
        }
        return nil
    }

    static func markShown(_ item: SplashItem) {
        guard item.once == true else { return }
        var shown = UserDefaults.standard.stringArray(forKey: shownKey) ?? []
        guard !shown.contains(item.id) else { return }
        shown.append(item.id)
        UserDefaults.standard.set(Array(shown.suffix(50)), forKey: shownKey)
    }

    /// 配置里的图在手机上的位置：远程的看缓存里有没有，本地预览的直接用那个文件
    static func local(_ path: String, base: URL) -> URL? {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { return nil }
        let file = url.isFileURL ? url : cacheFile(for: url)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// 按完整地址（带 ?v= 内容指纹）起文件名：服务器上换了图，地址就变，自然重新下
    static func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        return folder.appendingPathComponent("\(digest).\(ext)")
    }

    /// 解成可以直接画的位图（长边不超过 maxPixels），在后台做，不卡第一帧
    static func decode(_ file: URL, maxPixels: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
    }
}

/// 后台更新启动页配置：冷启动和回到前台时各试一次（15 分钟内不重复），用不用都要等下次冷启动
actor SplashFetcher {
    static let shared = SplashFetcher()
    private var running = false
    private static let fetchedKey = "splashFetched"
    /// 单张图最大 8 MB（推荐 1290×2796 的 JPEG，一般 1 MB 以内）
    private static let maxImageBytes = 8 << 20

    func refresh() async {
        #if SNAPSHOT
        return
        #else
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.fetchedKey) as? Date, Date.now.timeIntervalSince(last) < 15 * 60 { return }
        guard !running else { return }
        running = true
        defer { running = false }

        var request = URLRequest(url: SplashStore.configURL, timeoutInterval: 15)
        // 服务器回 Cache-Control: no-cache：每次都带 ETag 去问，没变就是 304，不重新下
        request.cachePolicy = .useProtocolCachePolicy
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return }
        let config: SplashConfig
        switch status {
        case 200:
            guard let decoded = try? SplashStore.decoder.decode(SplashConfig.self, from: data) else { return }
            config = decoded
        case 404:
            // 服务器上撤掉了配置：回到默认的品牌页
            config = SplashConfig()
        default:
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: SplashStore.folder, withIntermediateDirectories: true)
        if status == 200 {
            try? data.write(to: SplashStore.configFile, options: .atomic)
        } else {
            try? fm.removeItem(at: SplashStore.configFile)
        }

        // 还没过期的条目的图都先下好；不再用到的删掉
        var keep: Set<String> = [SplashStore.configFile.lastPathComponent]
        let now = Date.now
        for item in config.items where (item.until ?? .distantFuture) > now {
            for path in [item.image, item.imageDark].compactMap({ $0 }) {
                guard let url = URL(string: path, relativeTo: SplashStore.configURL)?.absoluteURL, url.scheme == "https" else { continue }
                let file = SplashStore.cacheFile(for: url)
                keep.insert(file.lastPathComponent)
                if !fm.fileExists(atPath: file.path) { await download(url, to: file) }
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: SplashStore.folder.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: SplashStore.folder.appendingPathComponent(name))
        }
        defaults.set(Date.now, forKey: Self.fetchedKey)
        #endif
    }

    private func download(_ url: URL, to file: URL) async {
        guard let (temp, response) = try? await URLSession.shared.download(from: url) else { return }
        defer { try? FileManager.default.removeItem(at: temp) }
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0
        guard (response as? HTTPURLResponse)?.statusCode == 200, size > 0, size <= Self.maxImageBytes,
              let source = CGImageSourceCreateWithURL(temp as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.moveItem(at: temp, to: file)
    }
}

// MARK: - 界面

/// 启动页的底色：和静态启动屏同一个值（Assets 的 LaunchBackground）
enum SplashStyle {
    static let background = Color(uiColor: UIColor(named: "LaunchBackground") ?? UIColor(hex: 0x0B0B0C, alpha: 1))
}

/// 启动页上的纸鸢：就是 KiteMark（和 App 图标同一只、同一个品牌橙），连着提线和一段主线
struct SplashKite: View {
    var body: some View {
        KiteMark(line: KiteColor.brand.opacity(0.75))
    }
}

/// 风筝 + Kiteline 字样。静态启动屏的图（Assets 的 LaunchMark）就是把它原样渲染出来的：
/// TARS_RENDER_LAUNCH=<目录> bash ios/snapshot.sh shot x.png（见 Snapshot.swift），改了这里要重新出图
struct SplashMark: View {
    static let size = CGSize(width: 200, height: 162)
    static let kite: CGFloat = 120
    /// 风筝飞走：往右上飘、轻轻一偏，字样淡掉
    var lifted = false
    var reduceMotion = false

    var body: some View {
        VStack(spacing: 0) {
            SplashKite()
                .frame(width: Self.kite, height: Self.kite)
                // 纸鸢身子在格子右上、燕尾往左下拖：整体往左挪一点，看起来才居中
                .offset(x: -6)
                .rotationEffect(.degrees(lifted && !reduceMotion ? -7 : 0))
                .offset(x: lifted && !reduceMotion ? 30 : 0, y: lifted && !reduceMotion ? -54 : 0)
                .scaleEffect(lifted && !reduceMotion ? 0.9 : 1)
                .opacity(lifted ? 0 : 1)
            Text(verbatim: "Kiteline")
                .font(.system(size: 23, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(.white.opacity(0.92))
                .frame(height: 30)
                .padding(.top, 12)
                .opacity(lifted ? 0 : 1)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Kiteline"))
    }
}

/// 盖在整个 App 上的启动页：品牌页停一下就走；服务器配了图就换上图，到点或点「跳过」再走
struct SplashOverlay: View {
    @AppStorage("onboarded") private var onboarded = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var choice: SplashChoice?
    @State private var art: UIImage?
    /// 服务器配的那一条已经换上（图淡入、字出来）
    @State private var showingItem = false
    @State private var deadline: Date?
    @State private var leaving = false
    @State private var gone = false

    /// 品牌页在第一帧之后再停多久（静态启动屏已经显示了一会儿，这里不用长）
    private static let brandHold = 0.4

    var body: some View {
        if !gone {
            content
                .allowsHitTesting(!leaving)
                .task { await run() }
        }
    }

    private var content: some View {
        let artShown = showingItem && art != nil
        return ZStack {
            SplashStyle.background
                .ignoresSafeArea()
                .opacity(leaving ? 0 : 1)
                .animation(.easeInOut(duration: 0.42).delay(0.1), value: leaving)
            // 和静态启动屏一样按整块屏幕居中（不是按安全区），第一帧和系统画的严丝合缝
            SplashMark(lifted: leaving || artShown, reduceMotion: reduceMotion)
                .animation(leaving ? .easeIn(duration: 0.5) : .easeInOut(duration: 0.4), value: leaving || artShown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            if let art {
                artwork(art)
                    .ignoresSafeArea()
                    .opacity(showingItem && !leaving ? 1 : 0)
                    .scaleEffect(leaving && !reduceMotion ? 1.04 : 1)
                    .animation(.easeInOut(duration: leaving ? 0.45 : 0.4), value: showingItem && !leaving)
            }
            if let item = choice?.item, showingItem {
                caption(item, onImage: art != nil)
                    .opacity(leaving ? 0 : 1)
                    .animation(.easeOut(duration: 0.3), value: leaving)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 10)))
            }
            if showingItem, let deadline, choice.map({ $0.item.hold >= 2 }) == true {
                skip(deadline)
                    .opacity(leaving ? 0 : 1)
                    .transition(.opacity)
            }
        }
        // 启动页总是深色（玻璃、材质按深色画），不跟 App 的浅色 / 深色设置
        .environment(\.colorScheme, .dark)
    }

    // MARK: 服务器配的图和字

    private func artwork(_ image: UIImage) -> some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    // 停留期间慢慢推近一点点（减弱动态效果时不动）
                    .scaleEffect(showingItem && !reduceMotion ? 1 : 1.05)
                    .animation(reduceMotion ? nil : .linear(duration: (choice?.item.hold ?? 2.5) + 0.6), value: showingItem)
            }
            .clipped()
            .overlay {
                // 上下各压一层黑，白字和「跳过」在亮图上也看得清
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.32), .clear], startPoint: .top, endPoint: .bottom).frame(height: 160)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom).frame(height: 360)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard let link = choice?.link else { return }
                openURL(link)
                leave()
            }
            .accessibilityHidden(true)
    }

    /// 标题、副标题。有图时左对齐压在图的下方，底下一行小标志；只有字时在品牌页下方居中
    @ViewBuilder
    private func caption(_ item: SplashItem, onImage: Bool) -> some View {
        let title = item.title?.text, subtitle = item.subtitle?.text
        if onImage {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                if let title {
                    Text(title)
                        .font(.system(size: 30, weight: .semibold))
                        .kerning(-0.3)
                        .foregroundStyle(.white)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 16))
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.74))
                        .padding(.top, 10)
                }
                Rectangle().fill(.white.opacity(0.2)).frame(height: 0.5).padding(.top, title == nil && subtitle == nil ? 0 : 26)
                HStack(spacing: 8) {
                    SplashKite().frame(width: 28, height: 28)
                    Text(verbatim: "Kiteline").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.86))
                }
                .padding(.top, 16)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        } else {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                if let title {
                    Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white.opacity(0.94))
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 15)).lineSpacing(2).foregroundStyle(.white.opacity(0.62))
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)
            .padding(.bottom, 40)
        }
    }

    private func skip(_ deadline: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let left = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
            Button(action: leave) {
                HStack(spacing: 6) {
                    Text("跳过")
                    if left > 0 { Text("\(left)").monospacedDigit().foregroundStyle(.white.opacity(0.7)) }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // 烟灰色玻璃：压在亮图上白字也看得清
                .liquidGlass(in: Capsule(), tint: .black.opacity(0.3), interactive: true)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: 时间线

    private func run() async {
        #if SNAPSHOT
        // 截图版：默认不要启动页；TARS_DEMO_SPLASH 看启动页（停住不走）
        guard let preview = Snapshot.splash else { gone = true; return }
        if preview != "brand" {
            let file = URL(fileURLWithPath: preview)
            choice = SplashStore.choose(configFile: file, base: file)
        }
        try? await Task.sleep(for: .milliseconds(300))
        await present(holding: false)
        #else
        // 第一次打开（还在引导）只用品牌页
        choice = onboarded ? SplashStore.current() : nil
        await present(holding: true)
        #endif
    }

    /// holding：到点自己走（截图版停住）
    private func present(holding: Bool) async {
        guard let choice else {
            if holding {
                try? await Task.sleep(for: .seconds(Self.brandHold))
                leave()
            }
            return
        }
        if let file = choice.image(dark: scheme == .dark) {
            // 长边 3000 像素：最大的 iPhone（2868）、iPad（2732）都够清楚
            art = await SplashStore.decode(file, maxPixels: 3000)
            // 图坏了：当作没配
            if art == nil {
                self.choice = nil
                if holding { leave() }
                return
            }
        }
        SplashStore.markShown(choice.item)
        let until = Date.now.addingTimeInterval(choice.item.hold)
        withAnimation(.easeOut(duration: 0.35)) {
            deadline = until
            showingItem = true
        }
        guard holding else { return }
        try? await Task.sleep(for: .seconds(choice.item.hold))
        leave()
    }

    private func leave() {
        guard !leaving else { return }
        leaving = true
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            gone = true
        }
    }
}
#endif
