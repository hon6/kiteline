import AppKit
import UniformTypeIdentifiers

/// 系统共享菜单里的「Kiteline」（微信「转发到其他应用 → 选择电脑中的应用」、访达右键「共享」、Safari 的分享按钮……）。
/// 扩展只负责收东西：文件原样拷进 ~/Library/Application Support/TARS/ShareInbox/<编号>/，文字和链接、文件清单写进旁边的 <编号>.json，
/// 然后用 kiteline://share?id=<编号> 唤起 Kiteline，由它弹「发送到会话」面板（选已有会话，或选项目、Agent 新建会话）。
/// 扩展必须开沙盒：能写的只有 ShareInbox 这一个目录（KitelineShare.entitlements 的临时例外）
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        // 不画界面：收完马上交给 Kiteline，面板在 Kiteline 里
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collect()
    }

    /// 真正的用户目录（沙盒里 NSHomeDirectory() 是扩展自己的容器）
    private static var home: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    private func collect() {
        let id = UUID().uuidString
        let dir = URL(fileURLWithPath: Self.home + "/Library/Application Support/TARS/ShareInbox/" + id, isDirectory: true)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var texts: [String] = []
        var files: [String] = []
        let lock = NSLock()
        let group = DispatchGroup()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            finish(nil); return
        }

        /// 起个不重名的文件名放进收件目录
        func place(_ name: String) -> URL {
            let clean = name.replacingOccurrences(of: "/", with: "_")
            var target = dir.appendingPathComponent(clean.isEmpty ? "file" : clean)
            let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            return target
        }
        func addFile(_ name: String) { lock.lock(); files.append(name); lock.unlock() }
        func addText(_ text: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            lock.lock(); if !texts.contains(t) { texts.append(t) }; lock.unlock()
        }

        for item in items {
            if let text = item.attributedContentText?.string { addText(text) }
            for provider in item.attachments ?? [] {
                group.enter()
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { value, _ in
                        defer { group.leave() }
                        let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        guard let url, url.isFileURL else { return }
                        let target = place(url.lastPathComponent)
                        if (try? FileManager.default.copyItem(at: url, to: target)) != nil { addFile(target.lastPathComponent) }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier) { value, _ in
                        defer { group.leave() }
                        var data: Data?
                        var name = "image.png"
                        if let url = value as? URL {
                            data = try? Data(contentsOf: url)
                            name = url.lastPathComponent
                        } else if let raw = value as? Data {
                            data = raw
                        } else if let image = value as? NSImage, let tiff = image.tiffRepresentation {
                            data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                        }
                        guard let data else { return }
                        let target = place(name)
                        if (try? data.write(to: target)) != nil { addFile(target.lastPathComponent) }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { value, _ in
                        defer { group.leave() }
                        if let url = value as? URL { addText(url.absoluteString) }
                        else if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { addText(url.absoluteString) }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { value, _ in
                        defer { group.leave() }
                        if let text = value as? String { addText(text) }
                        else if let data = value as? Data, let text = String(data: data, encoding: .utf8) { addText(text) }
                    }
                } else {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard !texts.isEmpty || !files.isEmpty else {
                try? FileManager.default.removeItem(at: dir)
                self?.finish(nil); return
            }
            let manifest: [String: Any] = ["text": texts.joined(separator: "\n\n"), "files": files, "at": Date().timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
                try? data.write(to: dir.appendingPathExtension("json"))   // 清单放在目录旁边（<编号>.json），不和收到的文件重名
            }
            self?.finish(URL(string: "kiteline://share?id=" + id))
        }
    }

    private func finish(_ link: URL?) {
        if let link {
            // 唤起 Kiteline（没在运行会先启动），它收到链接后弹「发送到会话」面板
            NSWorkspace.shared.open(link)
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
