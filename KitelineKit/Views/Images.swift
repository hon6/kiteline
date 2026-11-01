import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
import Photos
typealias PlatformImage = UIImage
extension Image {
    init(platform: PlatformImage) { self.init(uiImage: platform) }
}
#else
import AppKit
typealias PlatformImage = NSImage
extension Image {
    init(platform: PlatformImage) { self.init(nsImage: platform) }
}
#endif

/// 取图：内存 → 手机本地（ImageDisk）→ 找电脑要。同一张图同时只取一次。
/// 分三种：对话、待办里是 100 点的方形缩略图（电脑上裁好，一张几 KB 到二十几 KB），今日动态这类是缩小图，点开看大图才取原图
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    enum Variant: String { case full, thumb, square }

    /// 方形缩略图的边长（像素）：100 点 × 屏幕倍数。iPhone 按 3 倍屏（2 倍屏的老机型用 300 也只是略大），Mac 按 2 倍
    #if canImport(UIKit)
    nonisolated static let squarePixels = 300
    #else
    nonisolated static let squarePixels = 200
    #endif

    private let cache = NSCache<NSString, PlatformImage>()
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]
    /// 同时最多找 Mac 要几张：十几张图一起要时排队，免得一起超时
    private let gate = Gate(limit: 4)

    init() { cache.totalCostLimit = 120 * 1024 * 1024 }

    func cached(_ path: String, _ query: [String: String], _ variant: Variant = .full) -> PlatformImage? {
        cache.object(forKey: Self.key(path, query, variant) as NSString)
    }

    /// title：图所在会话的标题，存盘时记下，设置里按会话列出占用时用
    func load(_ api: MacAPI, _ path: String, _ query: [String: String], _ variant: Variant = .full, title: String? = nil) async -> PlatformImage? {
        let key = Self.key(path, query, variant)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = inflight[key] { return await running.value }
        let gate = gate
        let task = Task.detached(priority: .userInitiated) {
            await Self.fetch(api, path, query, variant, title: title, gate: gate)
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4)) }
        return image
    }

    /// 清理缓存后：内存里的也不留
    func clearMemory() { cache.removeAllObjects() }

    /// 缩略图放进内存时的长边像素：对话里单张最大 240×260 点、方格更小，三倍屏 800 足够；
    /// 磁盘上的缩略图仍是 1200（ImageDisk.thumbPixels），读进来时按这个尺寸解码，一张从约 2.7 MB 降到约 1.2 MB
    nonisolated static let displayPixels = 800

    private nonisolated static func fetch(_ api: MacAPI, _ path: String, _ query: [String: String], _ variant: Variant,
                                          title: String?, gate: Gate) async -> PlatformImage? {
        if variant == .square { return await fetchSquare(api, path, query, title: title, gate: gate) }
        if variant == .thumb, let data = ImageDisk.read(path, query, .thumb), let image = decodeThumb(data) { return image }
        var original = ImageDisk.read(path, query, .full)
        if original == nil, let data = await download(api, path, query, gate: gate, progress: variant == .full ? progressKey(path, query) : nil),
           ImageDisk.isImage(data) {
            ImageDisk.write(data, path, query, .full, title: title)
            original = data
        }
        guard let original else { return nil }
        if variant == .thumb {
            if let thumb = ImageDisk.thumbnail(of: original) { ImageDisk.write(thumb.encoded, path, query, .thumb, title: title) }
            return decodeThumb(original)
        }
        return decode(original)
    }

    /// 方形缩略图：先看手机上存的；没有就请电脑裁好再发（?thumb=边长，不传原图）。
    /// 旧版电脑不认这个参数、发来的是原图时，在手机上裁好再存（原图顺手存下，点开看大图时不用再取）
    private nonisolated static func fetchSquare(_ api: MacAPI, _ path: String, _ query: [String: String],
                                                title: String?, gate: Gate) async -> PlatformImage? {
        let side = squarePixels
        if let data = ImageDisk.read(path, query, .square), let image = decode(data) { return image }
        var request = query
        request["thumb"] = String(side)
        guard let data = await download(api, path, request, gate: gate), ImageDisk.isImage(data) else { return nil }
        if let size = ImageDisk.pixelSize(data), size.width <= side + 2, size.height <= side + 2 {
            ImageDisk.write(data, path, query, .square, title: title)
            return decode(data)
        }
        ImageDisk.write(data, path, query, .full, title: title)
        guard let square = ImageDisk.square(of: data, side: side) else { return decodeThumb(data) }
        ImageDisk.write(square.encoded, path, query, .square, title: title)
        return PlatformImage(cg: square.image)
    }

    /// 解码成显示用的小图：解码时直接缩到 displayPixels（不先解出整张大图），已经解好、可以直接画
    private nonisolated static func decodeThumb(_ data: Data) -> PlatformImage? {
        guard !ImageDisk.tooLarge(data), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: displayPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return decode(data) }
        return PlatformImage(cg: image)
    }

    /// 找电脑要：网络不好、电脑去别的机器取图失败时隔一会儿再试，最多三次；会话没了（4xx）不再试。
    /// progress：原图边下边报进度（看大图时显示），按 key 记在 ImageProgress 里
    private nonisolated static func download(_ api: MacAPI, _ path: String, _ query: [String: String], gate: Gate,
                                             progress key: String? = nil) async -> Data? {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(attempt == 1 ? 1.5 : 4)) }
            await gate.enter()
            let started = Date()
            let result: Result<Data, Error>
            do {
                if let key {
                    result = .success(try await api.data(path, query) { received, total in
                        Task { @MainActor in ImageProgress.shared.update(key, received: received, total: total) }
                    })
                } else {
                    result = .success(try await api.data(path, query))
                }
            } catch { result = .failure(error) }
            await gate.leave()
            switch result {
            case .success(let data): return data
            case .failure(let error):
                #if DEBUG
                logFailure(path, query, error, attempt: attempt, seconds: Date().timeIntervalSince(started))
                #endif
                if let error = error as? APIError, (400..<500).contains(error.status) { return nil }
                continue
            }
        }
        return nil
    }

    #if DEBUG
    /// 调试版：取图失败的原因追加到 Documents/media-errors.jsonl（真机上用 devicectl 取回来看）
    private nonisolated static func logFailure(_ path: String, _ query: [String: String], _ error: Error, attempt: Int, seconds: Double) {
        let record: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "path": path, "query": query, "attempt": attempt,
                                     "seconds": (seconds * 10).rounded() / 10, "error": String(describing: error)]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = folder.appendingPathComponent("media-errors.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }
    #endif

    /// 在后台解码好，滑到时不卡主线程。声明像素过多的图不解码（见 ImageDisk.maxPixels）
    private nonisolated static func decode(_ data: Data) -> PlatformImage? {
        guard !ImageDisk.tooLarge(data) else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
        #else
        return NSImage(data: data)
        #endif
    }

    /// 看大图时下载进度的 key（ImageProgress）
    nonisolated static func progressKey(_ path: String, _ query: [String: String]) -> String {
        path + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    private static func key(_ path: String, _ query: [String: String], _ variant: Variant) -> String {
        path + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") + "#" + variant.rawValue
    }
}

/// 看大图时原图的下载进度（按 ImageCache.progressKey 记）
@MainActor @Observable
final class ImageProgress {
    static let shared = ImageProgress()
    struct Item { var received: Int64; var total: Int64 }
    private(set) var items: [String: Item] = [:]

    func update(_ key: String, received: Int64, total: Int64) {
        items[key] = Item(received: received, total: total)
    }
}

/// 看大图时还没下完：原图多大、下了多少（电脑没报总大小时只显示已下载多少）
struct DownloadProgressView: View {
    let key: String

    var body: some View {
        let item = ImageProgress.shared.items[key]
        VStack(spacing: 10) {
            if let item, item.total > 0 {
                ProgressView(value: Double(min(item.received, item.total)), total: Double(item.total))
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                    .tint(.white)
                Text("原图 \(Self.size(item.total)) · \(Int(Double(item.received) * 100 / Double(item.total)))%")
            } else {
                ProgressView().tint(.white)
                Text(item.map { "正在加载原图 · 已下载 \(Self.size($0.received))" } ?? "正在加载原图…")
            }
        }
        .font(.ui(.footnote).monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 限流：同时最多 limit 个，多的排队
private actor Gate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}

extension PlatformImage {
    convenience init(cg image: CGImage) {
        #if canImport(UIKit)
        self.init(cgImage: image)
        #else
        self.init(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #endif
    }
}

/// Mac 上的一张图
struct RemoteImage: View {
    @Environment(AppModel.self) private var model
    let path: String
    let query: [String: String]
    var mode: ContentMode = .fill
    /// 用原图还是缩略图（对话里的小图用缩略图）
    var variant: ImageCache.Variant = .full
    /// 按原比例缩进这么大的框里，自己定宽高（不看外面给多大，宽图不会把格子撑出去）
    var box: CGSize?
    #if os(iOS)
    /// 全屏看图：双指缩放、放大后拖着看、双击放大 / 还原
    var zoom: Zoom?
    #endif
    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let image = shown {
                #if os(iOS)
                if let zoom {
                    ZoomableImage(image: image, active: zoom.active, onTap: zoom.onTap, onPull: zoom.onPull, onLongPress: zoom.onLongPress).ignoresSafeArea()
                } else {
                    still(image)
                }
                #else
                still(image)
                #endif
            } else if failed {
                retry
            } else if compact {
                DownloadProgressView(key: ImageCache.progressKey(path, query))
            } else {
                ProgressView()
            }
        }
        #if os(iOS)
        .background {
            // 看大图时还在加载、没取到的页：点空白处也能关
            if let zoom, shown == nil {
                Color.black.contentShape(Rectangle()).onTapGesture { zoom.onTap() }
            }
        }
        #endif
        .frame(width: shown != nil ? nil : box.map { $0.width }, height: shown != nil ? nil : box.map { $0.width * 0.6 })   // 还没取到：先占个横图的位置
        // 连上 Mac 时（重开 App、断网又连上）没取到的图自动再取
        .task(id: "\(path)|\(query)|\(variant)|\(attempt)|\(model.connected)") {
            guard image == nil else { return }
            let title = ImageDisk.session(path, query).flatMap { model.session($0)?.title }
            // 没取到（图推来时手机正好断网、App 刚回前台还没连上……）：这张图还在页面上就隔一会儿自己再取几次，
            // 不用等用户点「重试」（2026-10-22 手机上一张图一直停在「轻点重试」，电脑那边其实早就能取到）
            for delay in [5.0, 10, 20, 40, 60, 0] {
                image = await ImageCache.shared.load(model.api, path, query, variant, title: title)
                failed = image == nil
                guard failed, delay > 0, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// 能显示的图；看大图时原图还没到，先放缩略图
    private var shown: PlatformImage? {
        if let image = image ?? ImageCache.shared.cached(path, query, variant) { return image }
        #if os(iOS)
        // 看大图时原图还没到：有缩小图（形状和原图一样）先放着；对话里的方形缩略图是裁过的，不拿来占位
        if zoom != nil, variant == .full { return ImageCache.shared.cached(path, query, .thumb) }
        #endif
        return nil
    }

    /// 看大图时重试按钮只占中间一小块，点别处是关闭；小图里整格都是重试
    private var compact: Bool {
        #if os(iOS)
        zoom != nil
        #else
        false
        #endif
    }

    private var retry: some View {
        Button {
            failed = false
            attempt += 1
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                Text("轻点重试").font(.ui(.caption2))
            }
            .foregroundStyle(.secondary)
            .padding(compact ? 24 : 0)
            .frame(maxWidth: compact ? nil : .infinity, maxHeight: compact ? nil : .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.steady(.plain))
    }

    @ViewBuilder
    private func still(_ image: PlatformImage) -> some View {
        if let box, image.size.width > 0, image.size.height > 0 {
            let fit = min(box.width / image.size.width, box.height / image.size.height)
            Image(platform: image).resizable()
                .frame(width: max(1, (image.size.width * fit).rounded()), height: max(1, (image.size.height * fit).rounded()))
        } else {
            Image(platform: image).resizable().aspectRatio(contentMode: mode)
        }
    }
}

#if os(iOS)
extension RemoteImage {
    struct Zoom {
        /// 是不是正在看的这张：翻走了就还原
        var active: Bool
        var onTap: () -> Void
        /// 没放大时往下拖（同「照片」、微信）：拖了多少（0–1），外面跟着淡掉顶栏；拖够了松手就关
        var onPull: (CGFloat) -> Void = { _ in }
        /// 长按（同微信）：弹出系统分享
        var onLongPress: () -> Void = {}
    }
}
#endif

/// 一条消息里的图：一张按原比例缩进框里，多张排成一样大的方格（裁成填满）；点开全屏看
struct MessageImages: View {
    let key: String
    let images: [ChatImage]
    /// 点开后左右滑着看的一组图（比如一张步骤卡片里所有工具结果的图），从点的那张开始；不给就只看这条自己的
    var gallery: [ChatImage]? = nil
    /// 图从哪个接口取：对话里的图 /api/media，群里的图 /api/groups/media（key 是 @group:<群 id>）
    var path = "/api/media"
    @State private var viewing: Int?

    var body: some View {
        // 对话里只放 100 点的方形缩略图（电脑上居中裁好，一张几 KB 到二十几 KB），点开再取原图。
        // 一张、两张、四张是 100 的方块；三张、五张以上一排三个 80 的方块
        let columns = images.count == 1 ? 1 : (images.count == 2 || images.count == 4 ? 2 : 3)
        let side: CGFloat = columns == 3 ? 80 : 100
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 4), count: columns), alignment: .leading, spacing: 4) {
            ForEach(images.indices, id: \.self) { index in
                // 格子大小由底色块定，图盖在上面填满再裁掉
                Color.primary.opacity(0.06)
                    .frame(width: side, height: side)
                    .overlay { RemoteImage(path: path, query: query(index), variant: .square) }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { guard TouchTravel.isTap else { return }; viewing = index }
            }
        }
        .fixedSize()
        #if os(macOS)
        .sheetPanel(item: Binding(get: { viewing.map(ViewerIndex.init) }, set: { viewing = $0?.index })) { start in
            MacImageViewer(key: key, images: gallery ?? images, index: position(start.index), path: path)
        }
        #else
        .fullScreenCover(item: Binding(get: { viewing.map(ViewerIndex.init) }, set: { viewing = $0?.index })) { start in
            ImageViewer(key: key, images: gallery ?? images, index: position(start.index), path: path)
        }
        #endif
    }

    private func query(_ index: Int) -> [String: String] { ["key": key, "ref": images[index].ref] }

    /// 点的这张在整组里排第几
    private func position(_ index: Int) -> Int { gallery?.firstIndex { $0.ref == images[index].ref } ?? index }
}

private struct ViewerIndex: Identifiable {
    let index: Int
    var id: Int { index }
}

#if os(iOS)
/// 全屏看图：左右滑切换；双指缩放、松手保持，放大后上下左右拖着看，拖到边再划翻下一张；双击放大 / 还原；单击关闭；
/// 右上角存相册、分享（长按图也是分享）
struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let key: String
    let images: [ChatImage]
    @State var index: Int
    /// 图从哪个接口取：对话里的图 /api/media，待办的截图 /api/todos/media
    var path = "/api/media"
    /// 往下拖着要关的进度（0–1）：顶栏跟着淡掉
    @State private var pull: CGFloat = 0

    var body: some View {
        // 顶栏单独占一行、不盖在图上：盖在上面时点按钮会落到底下那页（没取到的页点成了「重试」，有图的页点成了关闭）
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.ui(.title3).weight(.semibold))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                Spacer()
                if images.count > 1 { Text("\(index + 1) / \(images.count)").font(.ui(.callout).monospacedDigit()) }
                Spacer()
                // 原来是「⋯」菜单里放 ShareLink：看大图是全屏弹出的页面，ShareLink 从底下那层弹分享面板，被这层挡着弹不出来
                //（10-22 反馈分享打不开）。改成两个按钮直接点，分享用系统面板从最上面这层弹（SystemShare）
                Button { Task { await save() } } label: {
                    Image(systemName: "square.and.arrow.down").font(.ui(.title3))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("存到相册")
                Button { Task { await share() } } label: {
                    Image(systemName: "square.and.arrow.up").font(.ui(.title3))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("分享")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .opacity(1 - min(pull * 3, 1))
            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, image in
                    RemoteImage(path: path, query: ["key": key, "ref": image.ref], mode: .fit,
                                zoom: .init(active: i == index, onTap: { dismiss() }, onPull: { pull = $0 },
                                            onLongPress: { Task { await share() } }))
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
    }

    /// 存相册、分享用原图：还没取到就现取（看大图时一般已经在了），取不到才退回缩略图
    private func original() async -> UIImage? {
        guard images.indices.contains(index) else { return nil }
        let query = ["key": key, "ref": images[index].ref]
        if let image = ImageCache.shared.cached(path, query) { return image }
        if let image = await ImageCache.shared.load(model.api, path, query) { return image }
        return ImageCache.shared.cached(path, query, .thumb)
    }

    /// 系统分享面板：微信、存储图像、隔空投送、拷贝……
    private func share() async {
        guard let image = await original() else { model.flash(L("图片尚未加载完成")); return }
        Haptics.tap()
        SystemShare.present([image])
    }

    private func save() async {
        guard let image = await original() else { model.flash(L("图片尚未加载完成")); return }
        guard await Permissions.shared.ensure(.photos) else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            model.flash(L("已存到相册"))
        } catch {
            model.flash(L("无法存到相册：%@", "\(error.localizedDescription)"))
        }
    }
}

/// 能缩放的图（照「照片」App：UIScrollView 里放 UIImageView）。没放大时拖不动，左右划交给外面翻页；
/// 放大后在里面拖，拖到边再划，系统会把这一划交给外面的翻页
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var active: Bool
    var onTap: () -> Void
    var onPull: (CGFloat) -> Void
    var onLongPress: () -> Void

    func makeUIView(context: Context) -> ZoomScrollView { ZoomScrollView() }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onTap = onTap
        view.onPull = onPull
        view.onLongPress = onLongPress
        if view.imageView.image !== image { view.show(image) }
        if !active, view.zoomScale > view.minimumZoomScale { view.setZoomScale(view.minimumZoomScale, animated: false) }
    }
}

private final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: () -> Void = {}
    var onPull: (CGFloat) -> Void = { _ in }
    var onLongPress: () -> Void = {}
    private var laidOutFor: CGSize = .zero
    /// 没放大时往下拖关掉（只认往下、竖着的拖：左右划照样交给外面翻页，放大后照样在里面拖着看）
    private lazy var pullDown = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        // 长按弹分享；长按了松手不算单击（不然分享面板刚出来，看图页就关了）
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        addGestureRecognizer(long)
        single.require(toFail: double)
        single.require(toFail: long)
        addGestureRecognizer(single)
        addGestureRecognizer(pullDown)
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { onLongPress() }
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pullDown else { return super.gestureRecognizerShouldBegin(gesture) }
        guard zoomScale <= minimumZoomScale + 0.01, imageView.image != nil else { return false }
        let velocity = pullDown.velocity(in: self)
        return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.2
    }

    /// 图跟着手指走、越往下越小；拖过 120 点或往下一甩就关，不够就弹回去
    @objc private func pulled(_ gesture: UIPanGestureRecognizer) {
        let move = gesture.translation(in: self)
        let down = max(0, move.y)
        let progress = min(down / 400, 1)
        switch gesture.state {
        case .changed:
            let scale = 1 - progress * 0.35
            imageView.transform = CGAffineTransform(translationX: move.x, y: down).scaledBy(x: scale, y: scale)
            onPull(progress)
        case .ended, .cancelled, .failed:
            let speed = gesture.velocity(in: self).y
            if gesture.state == .ended, down > 120 || (speed > 900 && down > 30) {
                onTap()
            } else {
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0) {
                    self.imageView.transform = .identity
                }
                onPull(0)
            }
        default:
            break
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: UIImage) {
        let old = imageView.image
        imageView.image = image
        // 缩略图换成原图：比例一样就只换图、留着现在的缩放和位置（看着只是变清楚了）
        if let old, laidOutFor != .zero, old.size.height > 0, image.size.height > 0,
           abs(old.size.width / old.size.height - image.size.width / image.size.height) < 0.01 {
            limitZoom()
            return
        }
        laidOutFor = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutFor { fit() }   // 第一次排版、转屏：按新尺寸重新放
        centerImage()
    }

    /// 还原成整张图刚好放进屏幕，算好最多能放大多少
    private func fit() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        laidOutFor = bounds.size
        minimumZoomScale = 1
        zoomScale = 1
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        // 卡住不超过屏幕：多出零点几个点也会让它能左右拖，把翻页的手势吃掉
        let size = CGSize(width: min(bounds.width, image.size.width * fit), height: min(bounds.height, image.size.height * fit))
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        limitZoom()
    }

    /// 至少能放到 4 倍；原图像素多的，放到「一个像素占两个屏幕像素」为止，方便看清大截图里的小字
    private func limitZoom() {
        guard let image = imageView.image, imageView.bounds.width > 0 else { return }
        let pixels = image.size.width * image.scale / (imageView.bounds.width * max(1, traitCollection.displayScale))
        maximumZoomScale = min(12, max(4, pixels * 2))
    }

    /// 图比屏幕小的那一边居中
    private func centerImage() {
        let size = imageView.frame.size
        imageView.center = CGPoint(x: max(size.width, bounds.width) / 2, y: max(size.height, bounds.height) / 2)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func singleTapped() { onTap() }

    /// 双击：放大到点的地方（宽图放到上下撑满屏幕），已放大就还原
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard zoomScale <= minimumZoomScale + 0.01 else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let size = imageView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let fill = max(bounds.width / size.width, bounds.height / size.height)
        let target = min(maximumZoomScale, max(2.5, fill))
        let point = gesture.location(in: imageView)
        let width = bounds.width / target, height = bounds.height / target
        zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
    }
}
#endif

#if os(macOS)
/// Mac 看大图里的一张：电脑上的（对话里的图、待办截图，经接口取）或本机现成的（文件面板里的图片、输入框里刚附的图）
enum ViewerImage {
    case remote(path: String, query: [String: String])
    case local(Data)
}

/// Mac 上看大图：能放大缩小、拖着看（见 ZoomImageView），← → 切换，拷贝、存储、共享、用「预览」打开。
/// 是能拖动、改大小的面板（见 SheetPanel），拉大窗口图跟着变大
struct MacImageViewer: View {
    @PanelDismiss private var dismiss
    @Environment(AppModel.self) private var model: AppModel?
    let images: [ViewerImage]
    @State var index: Int
    /// 只有一张时标题显示的名字（文件名）
    var name: String? = nil
    @FocusState private var focused: Bool
    /// 这一张的原图（取到了才能缩放、拷贝、共享）
    @State private var current: NSImage?
    @State private var failed = false
    @StateObject private var zoom = ZoomControl()

    init(images: [ViewerImage], index: Int = 0, name: String? = nil) {
        self.images = images
        _index = State(initialValue: index)
        self.name = name
    }

    /// 对话里的图（/api/media）、待办的截图（/api/todos/media）
    init(key: String, images: [ChatImage], index: Int, path: String = "/api/media") {
        self.init(images: images.map { .remote(path: path, query: ["key": key, "ref": $0.ref]) }, index: index)
    }

    var body: some View {
        Group {
            if let current {
                ZoomImageView(image: current, control: zoom, onSwipe: images.count > 1 ? { step($0) } : nil)
            } else if failed {
                ContentUnavailableView(L("无法获取图片"), systemImage: "photo")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chatBackground)
        // ⌘+（要按 Shift 的那个）也放大：工具栏按钮只能带一个快捷键
        .background { Button("") { zoom.zoomIn() }.keyboardShortcut("+", modifiers: .command).opacity(0).accessibilityHidden(true) }
        // 按钮放小窗的工具栏（同「预览」）：左边标题，右边按钮；macOS 26 起是液态玻璃，窄了收进「»」
        .navigationTitle(images.count > 1 ? "\(index + 1) / \(images.count)" : (name ?? L("图片")))
        .toolbar { toolbar }
        .panelFrame(width: 900, height: 700, minWidth: 480, minHeight: 320)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }   // 一打开就能按 ←/→ 翻
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .task(id: index) {
            failed = false
            current = cached(images[index])
            if current == nil {
                current = await load(images[index])
                failed = current == nil
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if images.count > 1 {
            ToolbarItemGroup(placement: .navigation) {
                Button { step(-1) } label: { Label(L("上一张"), systemImage: "chevron.left") }
                    .disabled(index == 0).help(L("上一张（←）")).panelToolbarItem()
                Button { step(1) } label: { Label(L("下一张"), systemImage: "chevron.right") }
                    .disabled(index == images.count - 1).help(L("下一张（→）")).panelToolbarItem()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { zoom.zoomOut() } label: { Label(L("缩小"), systemImage: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command).help(L("缩小（⌘-）")).panelToolbarItem()
            Button { zoom.actualSize() } label: { Text(zoom.percent).monospacedDigit().frame(minWidth: 40) }
                .keyboardShortcut("0", modifiers: .command).help(L("实际大小（⌘0）")).panelToolbarItem()
            Button { zoom.zoomIn() } label: { Label(L("放大"), systemImage: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command).help(L("放大（⌘+）")).panelToolbarItem()
            Button { zoom.fit() } label: { Label(L("适合窗口"), systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .keyboardShortcut("9", modifiers: .command).disabled(zoom.fitting).help(L("适合窗口（⌘9）")).panelToolbarItem()
        }
        GroupGap()   // 缩放一组、拷贝 / 存储 / 共享 / 预览一组，分成两块玻璃
        ToolbarItemGroup(placement: .primaryAction) {
            Button { copy() } label: { Label(L("拷贝"), systemImage: "doc.on.doc") }.help(L("拷贝图片")).panelToolbarItem()
            // 同 iPhone 看大图的「存到相册」「分享」：存成文件、共享给微信 / 隔空投送 / 信息……
            Button { Task { await saveAs() } } label: { Label(L("存储…"), systemImage: "square.and.arrow.down") }.help(L("存储为文件")).panelToolbarItem()
            if let current {
                ShareLink(item: Image(nsImage: current), preview: SharePreview(L("图片"), image: Image(nsImage: current))) {
                    Label(L("共享"), systemImage: "square.and.arrow.up")
                }
                .help(L("共享")).panelToolbarItem()
            }
            Button { Task { await openInPreview() } } label: { Label(L("用「预览」打开"), systemImage: "arrow.up.forward.app") }
                .help(L("用「预览」打开（可标注、另存）")).panelToolbarItem()
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(L("完成")) { dismiss() }.keyboardShortcut(.cancelAction).panelToolbarButton()
        }
    }

    private func cached(_ image: ViewerImage) -> NSImage? {
        switch image {
        case .local(let data): NSImage(data: data)
        case .remote(let path, let query): ImageCache.shared.cached(path, query)
        }
    }

    private func load(_ image: ViewerImage) async -> NSImage? {
        switch image {
        case .local(let data): NSImage(data: data)
        case .remote(let path, let query): if let model { await ImageCache.shared.load(model.api, path, query) } else { nil }
        }
    }

    /// 原图的数据（存储、用「预览」打开）：PNG / JPEG 原样
    private func data() async -> Data? {
        switch images[index] {
        case .local(let data): data
        case .remote(let path, let query): try? await model?.api.data(path, query)
        }
    }

    /// 存成文件：原图（PNG / JPEG 原样），默认放「下载」
    private func saveAs() async {
        guard let data = await data() else { model?.flash(L("无法获取图片")); return }
        let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"   // 同系统截图的文件名
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name ?? L("Kiteline 图片 %@.%@", "\(stamp.string(from: Date()))", "\(ext)")
        panel.allowedContentTypes = [ext == "png" ? .png : .jpeg]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            model?.flash(L("已存储"))
        } catch {
            model?.flash(L("存储失败：%@", "\(error.localizedDescription)"))
        }
    }

    private func step(_ delta: Int) {
        index = min(max(0, index + delta), images.count - 1)
    }

    private func copy() {
        guard let current else { model?.flash(L("图片尚未加载")); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([current])
        model?.flash(L("已拷贝图片"))
    }

    private func openInPreview() async {
        guard let data = await data() else { model?.flash(L("无法获取图片")); return }
        let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TARS-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            model?.flash(L("保存失败：%@", "\(error.localizedDescription)"))
        }
    }
}

/// 工具栏里两组按钮之间留一点空，各成一块玻璃（macOS 26 起；更早的系统工具栏本来就分得开）
private struct GroupGap: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }
}

extension View {
    /// Mac：点这张图放大看（能缩放的看大图面板）；鼠标指上去显示放大镜手势
    @ViewBuilder
    func zoomableOnClick(_ images: [ViewerImage], index: Int = 0, name: String? = nil) -> some View {
        modifier(ZoomOnClick(images: images, index: index, name: name))
    }
}

private struct ZoomOnClick: ViewModifier {
    let images: [ViewerImage]
    let index: Int
    let name: String?
    @State private var viewing = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { viewing = true }
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .help(L("点击放大查看"))
            .sheetPanel(isPresented: $viewing) { MacImageViewer(images: images, index: index, name: name) }
    }
}
#endif
