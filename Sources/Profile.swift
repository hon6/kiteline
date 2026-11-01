import AppKit
import Collaboration
import SwiftUI
import UniformTypeIdentifiers
import KitelineKit

/// 对话里「我」的头像和名字，手机和 Mac 共用一份（存在配置的 mobile.myName / mobile.avatar）。
/// 默认用这台 Mac 当前用户的账户头像和全名；也可以换成系统自带的头像（和「系统设置 → 用户与群组」里那套一样）、
/// 自己选的一张图，或者只显示名字首字。
enum Profile {
    /// 自己选的图：存配置目录，512×512 JPEG
    static var customURL: URL { AppConfig.directoryURL.appendingPathComponent("avatar.jpg") }
    /// 系统自带头像：每台 Mac 都有，/Library/User Pictures 只是指向这里的链接
    static let presetRoot = URL(fileURLWithPath: "/System/Library/Templates/Data/Library/User Pictures", isDirectory: true)

    static var groupNames: [String: String] { ["Animals": L("动物"), "Flowers": L("花卉"), "Nature": L("自然"), "Sports": L("运动"), "Instruments": L("乐器"), "Fun": L("趣味")] }
    static let groupOrder = ["Animals", "Flowers", "Nature", "Sports", "Instruments", "Fun"]

    struct Preset { let id: String; let group: String }

    // MARK: 名字

    static var macName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? NSUserName() : full
    }

    static func displayName(_ config: MobileConfig) -> String {
        let name = config.myName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? macName : name
    }

    /// 名字去掉首尾空白和换行，最多 24 个字
    static func cleanName(_ raw: String) -> String {
        String(raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(24))
    }

    // MARK: 头像

    /// 系统自带头像，id 形如 Animals/Owl
    static let presets: [Preset] = {
        let fm = FileManager.default
        var out: [Preset] = []
        let groups = (try? fm.contentsOfDirectory(atPath: presetRoot.path)) ?? []
        for group in groups.sorted(by: { (groupOrder.firstIndex(of: $0) ?? 99, $0) < (groupOrder.firstIndex(of: $1) ?? 99, $1) }) {
            let files = (try? fm.contentsOfDirectory(atPath: presetRoot.appendingPathComponent(group).path)) ?? []
            for file in files.sorted() where ["heic", "png", "jpg", "jpeg", "tif", "tiff"].contains((file as NSString).pathExtension.lowercased()) {
                out.append(Preset(id: "\(group)/\((file as NSString).deletingPathExtension)", group: group))
            }
        }
        return out
    }()

    /// 只认列表里有的 id，不拼用户给的路径
    static func presetFile(_ id: String) -> URL? {
        guard presets.contains(where: { $0.id == id }) else { return nil }
        let base = presetRoot.appendingPathComponent(id)
        for ext in ["heic", "png", "jpg", "jpeg", "tif", "tiff"] {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func macPicture() -> NSImage? {
        CBIdentity(name: NSUserName(), authority: CBIdentityAuthority.local())?.image
    }

    /// 某个头像设置对应的原图；text 或找不到图时为 nil
    static func image(for avatar: String) -> NSImage? {
        if avatar == "mac" { return macPicture() }
        if avatar == "custom" { return NSImage(contentsOf: customURL) }
        if avatar.hasPrefix("system:"), let url = presetFile(String(avatar.dropFirst(7))) { return NSImage(contentsOf: url) }
        return nil
    }

    static func isValid(_ avatar: String) -> Bool {
        if ["mac", "text"].contains(avatar) { return true }
        if avatar == "custom" { return FileManager.default.fileExists(atPath: customURL.path) }
        return avatar.hasPrefix("system:") && presetFile(String(avatar.dropFirst(7))) != nil
    }

    /// 居中裁成正方形再缩放，白底（透明图也不会变黑）
    static func squareJPEG(_ image: NSImage, side: Int, quality: Double = 0.86) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else { return nil }
        let edge = min(cg.width, cg.height)
        guard let square = cg.cropping(to: CGRect(x: (cg.width - edge) / 2, y: (cg.height - edge) / 2, width: edge, height: edge)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    // MARK: 缓存
    // 状态推送很频繁，头像不能每次都重新读、重新压；设置变了立刻重算，Mac 账户头像每 5 分钟看一眼有没有换。

    private static let lock = NSLock()
    private static var cache: (avatar: String, at: Date, jpeg: Data?, version: String)?
    private static var thumbs: [String: Data] = [:]

    /// 当前头像（256×256 JPEG）和它的版本号；版本号随图片内容变，手机据此决定要不要重新下载
    static func current(_ config: MobileConfig) -> (jpeg: Data?, version: String) {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache, hit.avatar == config.avatar, hit.avatar != "mac" || Date().timeIntervalSince(hit.at) < 300 {
            return (hit.jpeg, hit.version)
        }
        let jpeg = image(for: config.avatar).flatMap { squareJPEG($0, side: 256) }
        let version = jpeg.map { fingerprint($0) } ?? ""
        cache = (config.avatar, Date(), jpeg, version)
        return (jpeg, version)
    }

    static func invalidate() {
        lock.lock(); cache = nil; lock.unlock()
    }

    /// 选头像时的小图（160×160）：系统头像（不会变，记住）、Mac 账户头像和自己选的图（可能会换，每次现做）
    static func thumbnail(_ avatar: String) -> Data? {
        let fixed = avatar.hasPrefix("system:")
        guard fixed || avatar == "mac" || avatar == "custom" else { return nil }
        lock.lock()
        if fixed, let hit = thumbs[avatar] { lock.unlock(); return hit }
        lock.unlock()
        guard let data = image(for: avatar).flatMap({ squareJPEG($0, side: 160, quality: 0.8) }) else { return nil }
        if fixed { lock.lock(); thumbs[avatar] = data; lock.unlock() }
        return data
    }

    static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash & 0xffff_ffff, radix: 36)
    }

    /// 存自己选的图：任意格式进来，统一成 512×512 JPEG
    static func saveCustom(_ data: Data) -> Bool {
        guard data.count <= 20 * 1024 * 1024, let image = NSImage(data: data), let jpeg = squareJPEG(image, side: 512) else { return false }
        do {
            try FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            try jpeg.write(to: customURL, options: .atomic)
        } catch { return false }
        invalidate()
        return true
    }

    // MARK: 给网页的数据

    /// 放进 /api/state 的「我」：名字 + 头像地址（没有图就空着，网页显示名字首字）
    static func mePayload(_ config: MobileConfig) -> [String: Any] {
        let now = current(config)
        return ["name": displayName(config), "avatar": now.jpeg == nil ? "" : "/api/avatar?v=\(now.version)"]
    }

    /// 换头像页要的全部信息
    static func editorPayload(_ config: MobileConfig) -> [String: Any] {
        let mac = macPicture() != nil
        return [
            "ok": true,
            "me": mePayload(config),
            "myName": config.myName,
            "macName": macName,
            "avatar": config.avatar,
            "hasMacPicture": mac,
            "hasCustom": FileManager.default.fileExists(atPath: customURL.path),
            "groups": groupOrder.compactMap { group -> [String: Any]? in
                let items = presets.filter { $0.group == group }.map(\.id)
                return items.isEmpty ? nil : ["name": groupNames[group] ?? group, "items": items]
            } + Set(presets.map(\.group)).subtracting(groupOrder).sorted().map { group in
                ["name": group, "items": presets.filter { $0.group == group }.map(\.id)]
            },
        ]
    }
}

// MARK: - Mac 设置窗口里的「我」

/// 名字首字：和手机网页一致——英文取前两个字母，中文取第一个字
func profileInitials(_ name: String) -> String {
    let text = name.trimmingCharacters(in: .whitespaces)
    guard let first = text.first else { return "?" }
    if first.isASCII, first.isLetter || first.isNumber {
        let letters = text.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return String(letters.prefix(2)).uppercased()
    }
    return String(first)
}

/// 一个头像：有图显示图，没图显示名字首字（和对话里一样的蓝灰底）
struct ProfileFace: View {
    var image: NSImage?
    var name: String
    var side: CGFloat

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.tarsTile
                Text(profileInitials(name)).font(.app(size: side * 0.38, weight: .semibold)).foregroundStyle(Color.tarsBrand)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }
}

struct ProfileSection: View {
    @State private var name = AppState.shared.config.mobile.myName
    @State private var avatar = AppState.shared.config.mobile.avatar
    @State private var face: NSImage? = Profile.current(AppState.shared.config.mobile).jpeg.flatMap(NSImage.init(data:))
    @State private var picking = false

    private var shownName: String {
        let trimmed = Profile.cleanName(name)
        return trimmed.isEmpty ? Profile.macName : trimmed
    }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                ProfileFace(image: avatar == "text" ? nil : face, name: shownName, side: 52)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("名字", text: $name, prompt: Text(Profile.macName))
                    HStack {
                        Spacer()
                        Button("更换头像…") { picking = true }
                            .popover(isPresented: $picking, arrowEdge: .bottom) {
                                AvatarPicker(selected: avatar, name: shownName) { choose($0) }
                            }
                    }
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("我")
        } footer: {
            Text("对话中你一侧显示的头像和名字，手机与 Mac 共用。默认使用此 Mac 账户的头像和用户名；名字留空时使用 Mac 用户名。")
                .foregroundStyle(.secondary)
        }
        .onChange(of: name) { _, value in
            let cleaned = Profile.cleanName(value)
            AppState.shared.updatePreferences { $0.mobile.myName = cleaned == Profile.macName ? "" : cleaned }
        }
    }

    /// 选中一个：mac / text / system:<id>，或者一张图片文件
    private func choose(_ choice: AvatarPicker.Choice) {
        picking = false
        switch choice {
        case .avatar(let value):
            guard Profile.isValid(value) else { return }
            avatar = value
        case .file(let url):
            guard let data = try? Data(contentsOf: url), Profile.saveCustom(data) else {
                KitelineModel.alert(L("无法更换"), L("无法打开此图片，请选择其他图片。"))
                return
            }
            avatar = "custom"
        }
        AppState.shared.updatePreferences { $0.mobile.avatar = avatar }
        face = Profile.current(AppState.shared.config.mobile).jpeg.flatMap(NSImage.init(data:))
    }
}

/// 换头像的弹出框：Mac 账户头像、名字首字、选一张图片，再加系统自带的那几十张
struct AvatarPicker: View {
    enum Choice { case avatar(String), file(URL) }

    var selected: String
    var name: String
    var choose: (Choice) -> Void
    @State private var images: [String: NSImage] = [:]

    private let columns = Array(repeating: GridItem(.fixed(52), spacing: 10), count: 7)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    if Profile.macPicture() != nil { tile("mac", label: L("Mac 头像")) }
                    tile("text", label: L("名字首字"))
                    if FileManager.default.fileExists(atPath: Profile.customURL.path) { tile("custom", label: L("自选图片")) }
                    Button(action: pickFile) {
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.secondary.opacity(0.15))
                                .frame(width: 46, height: 46)
                                .overlay(Image(systemName: "photo.badge.plus").font(.app(size: 18)).foregroundStyle(.secondary))
                            Text("选择图片…").font(.app(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Profile.groupOrder + Set(Profile.presets.map(\.group)).subtracting(Profile.groupOrder).sorted(), id: \.self) { group in
                    let items = Profile.presets.filter { $0.group == group }
                    if !items.isEmpty {
                        Text(Profile.groupNames[group] ?? group).font(.app(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(items, id: \.id) { tile("system:\($0.id)", label: nil) }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 7 * 52 + 6 * 10 + 28, height: 420)
        .task { await load() }
    }

    private func tile(_ value: String, label: String?) -> some View {
        Button { choose(.avatar(value)) } label: {
            VStack(spacing: 3) {
                ProfileFace(image: value == "text" ? nil : images[value], name: name, side: 46)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(value == selected ? Color.tarsBrand : .clear, lineWidth: 2.5).padding(-3))
                if let label = label {
                    Text(label).font(.app(size: 10)).foregroundStyle(value == selected ? Color.tarsBrand : .secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(label ?? String(value.split(separator: "/").last ?? ""))
    }

    /// 小图在后台做，弹框先出来
    private func load() async {
        let wanted = ["mac", "custom"] + Profile.presets.map { "system:\($0.id)" }
        let loaded: [String: NSImage] = await Task.detached(priority: .userInitiated) {
            var out: [String: NSImage] = [:]
            for value in wanted { if let data = Profile.thumbnail(value), let image = NSImage(data: data) { out[value] = image } }
            return out
        }.value
        images = loaded
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("选择一张图片作为头像（将居中裁剪为正方形）")
        if panel.runModal() == .OK, let url = panel.url { choose(.file(url)) }
    }
}
