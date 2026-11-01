import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 手机上的图片缓存：会话里的图原图、缩略图各存一份，App 重开、断网都不用再找 Mac 要。
/// 放在 Caches 里（能重新下载的东西不进 iCloud 备份；系统空间特别紧时可能被清，清了下次再取），
/// 按会话分文件夹，设置 →「存储空间」里能看占用、按会话清理。Mac 版连的是自己（Mac 上另有 MediaCache），不存
enum ImageDisk {
    /// full = 原图；thumb = 长边 1200 的缩小图（今日动态的截图这类）；sq = 对话里 100 点的方形缩略图（电脑上裁好的，几 KB）
    enum Kind: String { case full, thumb, square = "sq" }

    /// 缩略图长边最多这么多像素：气泡里单张最宽 240 点、方格最高 110 点，三倍屏也够清楚
    static let thumbPixels = 1200

    static var enabled: Bool {
        #if KITELINE_MAC
        false
        #else
        !Demo.active
        #endif
    }

    static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("images", isDirectory: true)

    /// 内容不会变的图才存，返回它属于哪个会话：会话里的图（/api/media）、今日动态的截图（/api/digest/media）。头像会换，不存
    static func session(_ path: String, _ query: [String: String]) -> String? {
        switch path {
        case "/api/media": return query["key"]
        case "/api/digest/media":
            guard let source = query["source"], let sid = query["sid"] else { return nil }
            return "\(source)#\(sid)"
        default: return nil
        }
    }

    static func read(_ path: String, _ query: [String: String], _ kind: Kind) -> Data? {
        guard enabled, let url = file(path, query, kind) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func write(_ data: Data, _ path: String, _ query: [String: String], _ kind: Kind, title: String?) {
        guard enabled, let session = session(path, query), let url = file(path, query, kind) else { return }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // 记下是哪个会话、叫什么：设置里按会话列出来（会话结束后列表里找不到标题，靠这里记的）
        let metaURL = folder.appendingPathComponent("meta.json")
        let old = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        if old == nil || (title != nil && title != old?.title),
           let encoded = try? JSONEncoder().encode(Meta(key: session, title: title ?? old?.title)) {
            try? encoded.write(to: metaURL, options: .atomic)
        }
    }

    /// 缩成长边 thumbPixels 的小图（已经解码好，可以直接画）和存盘用的数据；原图本来就不大时返回 nil，直接用原图
    static func thumbnail(of data: Data) -> (image: CGImage, encoded: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > thumbPixels, width * height <= maxPixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // 不透明的存 JPEG（小）；带透明的存 PNG，免得透明处变黑
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, (opaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, (opaque ? [kCGImageDestinationLossyCompressionQuality: 0.82] : [:]) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (image, out as Data)
    }

    /// 是不是一张完整的图（Mac 回了错误页、半截数据就不存）
    /// 方形缩略图：按短边缩到 side、居中裁成 side×side，存 JPEG（和电脑上生成的一样；连旧版电脑、它不认 thumb 参数时在手机上裁）
    static func square(of data: Data, side: Int) -> (image: CGImage, encoded: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = props[kCGImagePropertyPixelWidth] as? Int, var height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxPixels else { return nil }
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let longest = Int((Double(side) * Double(max(width, height)) / Double(min(width, height))).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(side, longest),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let scale = max(Double(side) / Double(scaled.width), Double(side) / Double(scaled.height))
        let drawWidth = Double(scaled.width) * scale, drawHeight = Double(scaled.height) * scale
        context.interpolationQuality = .high
        context.draw(scaled, in: CGRect(x: (Double(side) - drawWidth) / 2, y: (Double(side) - drawHeight) / 2, width: drawWidth, height: drawHeight))
        guard let image = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (image, out as Data)
    }

    /// 最多解码多少像素（宽×高）：几百 KB 的 PNG 就能声明上亿像素（12000×12000 全零 PNG 只有 410 KB），
    /// 整张解码要几百 MB，手机会被系统直接关掉。超过的不解码（电脑端生成缩略图时也是这个上限）
    static let maxPixels = 60_000_000

    /// 声明的像素数超过 maxPixels（只读文件头）；读不出尺寸的交给系统去认
    static func tooLarge(_ data: Data) -> Bool {
        guard let size = pixelSize(data) else { return false }
        return size.width * size.height > maxPixels
    }

    /// 图片的像素宽高（只读文件头，不解码）
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetType(source) != nil
    }

    // MARK: 占用和清理

    struct Meta: Codable {
        var key: String
        var title: String?
    }

    struct Usage {
        let folder: URL
        let key: String
        let title: String?
        let images: Int
        let bytes: Int
    }

    /// 每个会话的图占多少
    static func usage() -> [Usage] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.map { folder in
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
            let meta = (try? Data(contentsOf: folder.appendingPathComponent("meta.json"))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            return Usage(folder: folder, key: meta?.key ?? folder.lastPathComponent, title: meta?.title,
                         images: files.filter { $0.pathExtension == Kind.full.rawValue }.count,
                         bytes: files.reduce(0) { $0 + size($1) })
        }
    }

    static func remove(session key: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(hash(key), isDirectory: true))
    }

    static func remove(folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 文件实际占的磁盘空间
    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
    }

    // MARK: 路径

    private static func file(_ path: String, _ query: [String: String], _ kind: Kind) -> URL? {
        guard let session = session(path, query) else { return nil }
        let name = hash(path + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))
        return root.appendingPathComponent(hash(session), isDirectory: true).appendingPathComponent(name + "." + kind.rawValue)
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
