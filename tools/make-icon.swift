import AppKit
import Foundation

// 生成 Kiteline 的 App 图标（macOS 27 图标规格：1024 画布，圆角方块占 824，留出阴影）。
// 造型：纯色底上一只纯色剪纸纸鸢（北京沙燕，形状在 KitelineKit/Shared/PaperKite.swift），头朝右上斜飞，
// 胸口两根提线汇成一个结，一根线拉出画面——Claude 自己飞，线在你手里。
// 这个文件要和 PaperKite.swift 一起编译（build.sh 里拷成 main.swift 再 swiftc），单独 `swift make-icon.swift` 跑不了。
// 用法：make-icon <输出目录>   → icon_16.png … icon_1024.png、web_*.png、ios_1024.png

/// 底色和纸鸢色：都是纯色，不用渐变、高光
let background: UInt32 = 0x1D1D20
let kiteColor: UInt32 = 0xD97757
/// 风筝线（主线和两根提线）的粗细（格子单位）：要比燕尾细，燕尾尖是收细的
let lineWidth: CGFloat = 1.2

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./icons"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// 图标面（face：正方形，Mac 版再切成圆角方块）上的纸鸢和风筝线。坐标 y 朝下。
/// tinted：iPhone 主屏幕「着色」样式用的灰度版（黑底白纸鸢，系统再按用户选的颜色上色）
func drawFace(_ ctx: CGContext, _ face: CGRect, tinted: Bool = false) {
    let ink = tinted ? CGColor(gray: 1, alpha: 1) : color(kiteColor)
    ctx.setFillColor(tinted ? CGColor(gray: 0, alpha: 1) : color(background))
    ctx.fill(face)
    // 纸鸢在设计稿里是 824 见方的面上 (18, 30) 起、每格 2.05
    let k = face.width / 824
    let unit = 2.05 * k
    ctx.saveGState()
    ctx.translateBy(x: face.minX + 18 * k, y: face.minY + 30 * k)
    ctx.scaleBy(x: unit, y: unit)
    // 主线：从提线结往下，略带弧度拉出画面底边
    let line = CGMutablePath()
    line.move(to: PaperKite.knot)
    line.addCurve(to: CGPoint(x: 276, y: 440), control1: CGPoint(x: 252, y: 260), control2: CGPoint(x: 262, y: 330))
    ctx.addPath(line)
    ctx.setStrokeColor(ink.copy(alpha: 0.8) ?? ink)
    // 小图标上保底 0.7 像素，不至于消失
    ctx.setLineWidth(max(lineWidth, 0.7 / unit))
    ctx.setLineCap(.round)
    ctx.strokePath()
    PaperKite.draw(ctx, color: ink, detail: face.width >= 120 ? .full : .glyph, unit: unit, bridle: lineWidth)
    ctx.restoreGState()
}

/// 连续曲率圆角（squircle 近似）
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// 按精确像素画（lockFocus 在 Retina 屏上会画成两倍大），坐标翻成 y 朝下
func bitmap(_ size: Int, opaque: Bool = false, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    body(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Mac 图标：圆角方块 + 投影
func macIcon(size: Int) -> NSBitmapImageRep {
    bitmap(size) { ctx in
        let s = CGFloat(size) / 1024
        let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = squircle(body, radius: 186 * s)
        ctx.saveGState()
        // 坐标翻过来了，投影的偏移在设备空间里仍是 y 朝上：负数 = 往下
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: color(0x000000, 0.4))
        ctx.addPath(shape)
        ctx.setFillColor(color(background))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        drawFace(ctx, body)
        ctx.restoreGState()
    }
}

/// 手机用的图标：不透明、铺满的方块（圆角由系统切）
func flatIcon(size: Int, tinted: Bool = false) -> NSBitmapImageRep {
    bitmap(size) { ctx in drawFace(ctx, CGRect(x: 0, y: 0, width: size, height: size), tinted: tinted) }
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let png = macIcon(size: size).representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: "\(outputDir)/icon_\(size).png"))
}
for size in [180, 192, 512] {
    guard let png = flatIcon(size: size).representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: "\(outputDir)/web_\(size).png"))
}
/// iOS App 图标：1024、不透明、不带透明通道（App Store 不收带透明通道的图标；圆角由系统切）。
/// 手机和手表都用这张（手表裁成圆形）：拷到 KitelineKit 和 Apple Watch App 的 AppIcon.appiconset/icon-1024.png。
/// 别拷 icon_1024.png——那是 Mac 规格，自带圆角和投影，手机上会露出来
/// ios_1024_tinted.png 是「着色」样式（iOS 18 起）用的灰度版：拷到 KitelineKit 的 AppIcon.appiconset/icon-1024-tinted.png。
/// 不给的话系统自己把彩色图标转灰度、加对比，细线会被描粗
for (name, tinted) in [("ios_1024", false), ("ios_1024_tinted", true)] {
    if let cg = flatIcon(size: 1024, tinted: tinted).cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
       let flat = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        flat.draw(cg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        if let image = flat.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
        }
    }
}

print("图标已生成到 \(outputDir)")
