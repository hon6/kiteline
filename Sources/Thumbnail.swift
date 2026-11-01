import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 对话里的图片缩略图：手机在对话里只显示 100×100 点的方块（居中裁剪），向电脑要 `?thumb=像素`（3 倍屏 300），
/// 在这里按短边缩小、居中裁成正方形、存成 JPEG，单张几 KB 到二十几 KB；点开看大图时再取原图。
/// 原图动辄几百 KB 到几 MB，以前对话里每张都要整张传到手机再缩，流量和手机内存都浪费
enum Thumbnail {
    /// 手机能要的边长范围（像素）
    static let sizes = 32...640

    /// 请求里要不要缩略图、要多大；没有或不合法时返回 nil（给原图）
    static func size(in request: HTTPRequest) -> Int? {
        guard let text = request.query["thumb"], let size = Int(text), sizes.contains(size) else { return nil }
        return size
    }

    /// 正方形缩略图：按短边缩到 side、居中裁成 side×side，存 JPEG（带透明的先铺白底）。认不出的图返回 nil
    static func square(_ data: Data, side: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = props[kCGImagePropertyPixelWidth] as? Int, var height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // 像素太多的不做（几百 KB 的 PNG 能声明上亿像素，PNG、极端长宽比的图 ImageIO 仍可能整张解码、吃掉几百 MB 内存）
        guard width * height <= 60_000_000 else { return nil }
        // 照片带旋转方向时宽高对调（缩小时按方向转正）
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        // 解码时直接缩：长边缩到「短边刚好 side」对应的长度，不先解出整张大图
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
        return out as Data
    }

    /// 要了缩略图就换成缩略图（算好的按 key 记在内存里，同一张不重复算）；没要、或图认不出就原样返回
    static func reply(_ data: Data, mime: String, request: HTTPRequest, cacheKey: String) -> HTTPResponse {
        guard let side = size(in: request) else { return MobileServer.imageResponse(data, mime: mime) }
        let key = "\(cacheKey)|\(side)" as NSString
        if let hit = cache.object(forKey: key) { return MobileServer.imageResponse(hit as Data, mime: "image/jpeg") }
        guard let thumb = square(data, side: side) else { return MobileServer.imageResponse(data, mime: mime) }
        cache.setObject(thumb as NSData, forKey: key, cost: thumb.count)
        return MobileServer.imageResponse(thumb, mime: "image/jpeg")
    }

    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
}
