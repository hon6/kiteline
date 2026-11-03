import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import QuickLook
#else
import AppKit
#endif

/// 消息里的电脑文件路径：Claude 说「已生成 ~/Desktop/报价单.xlsx」、手机发过去的附件（[附件] 行）。
/// 认出来变成可点的链接，轻点从电脑取回手机预览，预览页右上角能转发到微信等 App（见 FileOpener）。
/// 以前只有项目目录里的文本文件点得开，Claude 放在桌面上的表格在手机上点不开（10-29）
enum FileLink {
    static let scheme = "kiteline-file"
    /// 手机发过去的文件在消息里是这一行（同电脑端 Delivery.compose）
    static let attachPrefix = "[附件] "

    static func url(_ path: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "path", value: path)]
        return parts.url
    }

    static func path(_ url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
    }

    /// 办公文档、图片、音视频、压缩包：取回手机用预览打开（能转发）；代码、文本在项目目录里的还是进项目文件页（能看改动记录）
    static let documentExtensions: Set<String> = [
        "pdf", "xlsx", "xls", "xlsm", "csv", "numbers", "docx", "doc", "pages", "rtf", "pptx", "ppt", "key", "epub",
        "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "zip", "rar", "7z", "gz", "tgz", "dmg", "apk", "ipa",
    ]

    /// 「Sources/App.swift:42」这类带的行号
    private static let lineSuffix = try! NSRegularExpression(pattern: #":\d+(-\d+)?$"#)
    private static let extPattern = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9]{0,7}$"#)
    /// 正文里的绝对路径（/…、~/…、C:\…），到空白、引号、括号、中文标点为止，要带扩展名；前面紧挨着字母、斜杠的不算（网址里那段）
    private static let plainPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/.~:\\-])(?:~/|/|[A-Za-z]:[\\/])[^\s`'"<>()（）【】「」『』，。；：！？、*|]+\.[A-Za-z][A-Za-z0-9]{0,7}(?![A-Za-z0-9_])"#)
    /// 代码里常见、却不会是路径的字
    private static let notPath = CharacterSet(charactersIn: "()[]{}<>=,;\"'`*?|$&!@#^+")

    private static func strip(_ text: String) -> String {
        let ns = text as NSString
        guard let m = lineSuffix.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
        return ns.replacingCharacters(in: m.range, with: "")
    }

    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~/") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    /// 最后一段（/ 和 \ 都算分隔）
    static func lastComponent(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path))
    }

    static func ext(_ path: String) -> String {
        let name = lastComponent(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// `代码` 整段像不像一个文件路径：绝对路径、~/ 开头、带目录的相对路径都要有扩展名；光秃秃的文件名只认办公文档这类
    static func candidate(_ raw: String) -> String? {
        let text = strip(raw.trimmingCharacters(in: .whitespaces))
        guard text.count >= 3, text.count <= 400, !text.contains("\n"), !text.contains("://") else { return nil }
        let ext = ext(text)
        guard !ext.isEmpty, extPattern.firstMatch(in: ext, range: NSRange(location: 0, length: (ext as NSString).length)) != nil else { return nil }
        if isAbsolute(text) { return text.rangeOfCharacter(from: notPath) == nil ? text : nil }
        guard !text.contains(" "), text.rangeOfCharacter(from: notPath) == nil, !text.hasPrefix("-"), !text.hasPrefix(".") || text.hasPrefix("./") || text.hasPrefix("../") else { return nil }
        if text.contains("/") { return text }
        return documentExtensions.contains(ext) ? text : nil
    }

    /// Markdown 行内渲染后：`代码` 里整段是路径的、正文里的绝对路径，加上文件链接（ChatLinkOpener 接住）
    static func linkify(_ result: inout AttributedString) {
        var spans: [(Range<AttributedString.Index>, URL)] = []
        for run in result.runs where run.link == nil && run.inlinePresentationIntent?.contains(.code) == true {
            if let path = candidate(String(result[run.range].characters)), let url = url(path) { spans.append((run.range, url)) }
        }
        for (range, url) in spans { result[range].link = url }
        let plain = String(result.characters)
        guard plain.contains("/") || plain.contains("\\") else { return }
        for match in plainPattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result),
                  result[lower..<upper].runs.allSatisfy({ $0.link == nil }),
                  let url = url(String(plain[range])) else { continue }
            result[lower..<upper].link = url
        }
    }

    /// 一条消息里提到的文件（长按「转发文件」用）：`代码` 里的和正文里的绝对路径，去重、按出现顺序
    static func mentions(in text: String) -> [String] {
        var found: [String] = []
        let ns = text as NSString
        if let code = try? NSRegularExpression(pattern: "`([^`\n]+)`") {
            for m in code.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let path = candidate(ns.substring(with: m.range(at: 1))) { found.append(path) }
            }
        }
        let bare = text.replacingOccurrences(of: "`[^`\n]*`", with: " ", options: .regularExpression)
        let bareNS = bare as NSString
        for m in plainPattern.matches(in: bare, range: NSRange(location: 0, length: bareNS.length)) {
            found.append(bareNS.substring(with: m.range))
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// 我发的消息里「[附件] 路径」那几行拆出来（画成文件卡片），剩下的是正文
    static func splitAttached(_ text: String) -> (text: String, files: [String]) {
        guard text.contains(attachPrefix) else { return (text, []) }
        var keep: [Substring] = []
        var files: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(attachPrefix) {
                let path = String(trimmed.dropFirst(attachPrefix.count)).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { files.append(path); continue }
            }
            keep.append(line)
        }
        return (keep.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), files)
    }

    /// 显示用的文件名：手机发过去的落在电脑的收件箱（…/inbox/日期/）里，名字前面带「时分秒-随机串-」，去掉
    static func displayName(_ path: String) -> String {
        let name = lastComponent(path)
        guard path.contains("/inbox/") || path.contains("\\inbox\\"),
              let prefix = name.range(of: #"^\d{6}-[0-9a-f]{6}-"#, options: .regularExpression) else { return name }
        return String(name[prefix.upperBound...])
    }

    /// 文件类型的图标（SF Symbols）
    static func symbol(_ name: String) -> String {
        guard let type = UTType(filenameExtension: ext(name)) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .spreadsheet) || ["csv", "xls", "xlsx", "numbers"].contains(ext(name)) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        return "doc.text"
    }
}

/// 取回电脑上的文件：手机上用系统预览打开（Excel、PDF、Word、图片、视频……），预览页右上角可转发到微信等 App；
/// 也可以直接弹系统分享面板（长按「转发文件」）。Mac 主窗口：本机的文件直接用默认的 App 打开
@MainActor
final class FileOpener {
    static let shared = FileOpener()
    private var task: Task<Void, Never>?
    #if os(iOS)
    /// 预览页的数据源（QLPreviewController 对它是弱引用）
    private var source: PreviewSource?
    #endif

    /// path：消息里写的路径（绝对、~/ 开头，或相对会话目录）；share = 取回后直接弹分享面板，不先预览
    func open(_ model: AppModel, key: String, path: String, share: Bool = false, reveal: Bool = false) {
        let cwd = model.session(key)?.cwd ?? model.pastMeta[key]?.cwd
        #if os(macOS)
        // 会话就在这台 Mac 上：原文件直接用默认的 App 打开（改了存回原处），不用取一份副本
        if model.session(key)?.sourceKind ?? (key.hasPrefix("local") ? "local" : nil) == "local" {
            var local = (path as NSString).expandingTildeInPath
            if !local.hasPrefix("/"), let cwd { local = (cwd as NSString).appendingPathComponent(local) }
            if FileManager.default.fileExists(atPath: local) {
                NSWorkspace.shared.open(URL(fileURLWithPath: local))
                return
            }
        }
        #endif
        task?.cancel()
        let name = FileLink.displayName(path)
        var query = ["key": key, "path": path]
        if let cwd { query["cwd"] = cwd }
        if reveal { query["reveal"] = "1" }
        model.hold(L("正在从电脑取回「%@」…", name))
        task = Task { [weak model] in
            guard let model else { return }
            let progress = Progress()
            do {
                let data = try await model.api.data("/api/download", query) { received, total in
                    guard total > 0 else { return }
                    let percent = Int(received * 100 / total)
                    Task { @MainActor in
                        // 每 5% 刷一次：每 64 KB 都改提示字会让整页跟着重算
                        guard progress.shown != percent / 5, !Task.isCancelled else { return }
                        progress.shown = percent / 5
                        model.hold(L("正在从电脑取回「%@」… %@%%", name, "\(percent)"))
                    }
                }
                guard !Task.isCancelled else { return }
                let file = try Self.save(data, name: name)
                model.hold(nil)
                present(file, share: share)
            } catch is CancellationError {
            } catch let error as APIError where error.data["secret"] as? Bool == true {
                model.hold(nil)
                confirmSecret(name) { self.open(model, key: key, path: path, share: share, reveal: true) }
            } catch {
                guard !Task.isCancelled else { return }
                model.hold(nil)
                model.flash(L("无法取回文件：%@", error.localizedDescription))
            }
        }
    }

    /// 群里发的文件（存在电脑上）：取回后预览，同上
    func openGroupFile(_ model: AppModel, group: String, file: GroupMedia) {
        task?.cancel()
        model.hold(L("正在从电脑取回「%@」…", file.name))
        task = Task { [weak model] in
            guard let model else { return }
            do {
                let data = try await model.api.data("/api/groups/media", ["id": group, "ref": file.ref])
                guard !Task.isCancelled else { return }
                let url = try Self.save(data, name: file.name)
                model.hold(nil)
                present(url, share: false)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                model.hold(nil)
                model.flash(L("无法取回文件：%@", error.localizedDescription))
            }
        }
    }

    private final class Progress: @unchecked Sendable { var shown = -1 }

    /// 取回的文件放临时目录（每个一个子目录，名字保持原样：预览页标题、转发到微信时对方看到的都是它）；一小时前的清掉
    static func save(_ data: Data, name: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let fm = FileManager.default
        if let old = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for dir in old where ((try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < Date().addingTimeInterval(-3600) {
                try? fm.removeItem(at: dir)
            }
        }
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let file = dir.appendingPathComponent(safe.isEmpty ? "file" : safe)
        try data.write(to: file)
        return file
    }

    private func present(_ file: URL, share: Bool) {
        #if os(iOS)
        Haptics.tap()
        #if targetEnvironment(macCatalyst)
        let previewable = true   // Catalyst（截图版）没有 canPreview：一律先预览，预览页里照样能分享
        #else
        let previewable = QLPreviewController.canPreview(file as NSURL)
        #endif
        if share || !previewable {
            // 预览不了的（压缩包、安装包……）直接给分享面板：存到「文件」、发给微信、用别的 App 打开
            SystemShare.present([file])
            return
        }
        let controller = QLPreviewController()
        let source = PreviewSource(file)
        self.source = source
        controller.dataSource = source
        SystemShare.top?.present(controller, animated: true)
        #else
        NSWorkspace.shared.open(file)
        #endif
    }

    /// 名字像密钥、密码的文件（.env、私钥……）：先问一句（同项目文件页的「仍然查看」）
    private func confirmSecret(_ name: String, proceed: @escaping () -> Void) {
        let message = L("「%@」可能包含密钥或密码，默认不传到手机。仍要取回吗？", name)
        #if os(iOS)
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("仍然取回"), style: .default) { _ in proceed() })
        SystemShare.top?.present(alert, animated: true)
        #else
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L("仍然取回"))
        alert.addButton(withTitle: L("取消"))
        if alert.runModal() == .alertFirstButtonReturn { proceed() }
        #endif
    }
}

#if os(iOS)
private final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    let file: URL
    init(_ file: URL) { self.file = file }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { file as NSURL }
}
#endif

/// 消息里的一个文件：图标 + 文件名 + 类型 / 大小（我发过去的附件、还没发出去的、待发的）
struct FileChip: View {
    let name: String
    var size: Int? = nil
    /// 画在我的气泡里（主题色底、浅色字）
    var mine = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: FileLink.symbol(name))
                .font(.system(size: 20, weight: .regular))
                .frame(width: 36, height: 40)
                .background(mine ? Color.white.opacity(0.16) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.ui(.subheadline)).lineLimit(2).truncationMode(.middle)
                Text(detail).font(.ui(.caption2)).opacity(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 260, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var detail: String {
        let kind = FileLink.ext(name).uppercased()
        let parts = [kind.isEmpty ? L("文件") : kind, size.map { Bytes.size($0) }].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

/// 我发过去的文件（消息里的 [附件] 行）：轻点取回预览，长按菜单里能转发
struct AttachedFiles: View {
    @Environment(AppModel.self) private var model
    let key: String
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(paths, id: \.self) { path in
                FileChip(name: FileLink.displayName(path), mine: true)
                    .onTapGesture { guard TouchTravel.isTap else { return }; FileOpener.shared.open(model, key: key, path: path) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("轻点打开文件"))
            }
        }
    }
}

extension AppModel {
    /// 长按菜单的「转发文件」：消息里提到的文件取回后弹系统分享面板；有好几个就先选一个
    func forwardFilesAction(key: String, paths: [String], choose: @escaping () -> Void) -> MenuAction? {
        guard !paths.isEmpty else { return nil }
        return MenuAction(title: L("转发文件"), symbol: "arrowshape.turn.up.right") {
            if paths.count == 1 { FileOpener.shared.open(self, key: key, path: paths[0], share: true) } else { choose() }
        }
    }

    /// 长按菜单的「转发」（图片）：取原图（取不到用缩略图）弹系统分享面板，微信、存储图像、隔空投送……
    /// Mac 上右键菜单不放：点开看大图的工具栏里有「共享」
    func forwardImagesAction(key: String, images: [ChatImage]) -> MenuAction? {
        #if os(macOS)
        return nil
        #else
        guard !images.isEmpty else { return nil }
        return MenuAction(title: L("转发"), symbol: "arrowshape.turn.up.right") {
            Task { @MainActor in
                var loaded: [PlatformImage] = []
                for image in images {
                    let query = ["key": key, "ref": image.ref]
                    if let full = await ImageCache.shared.load(self.api, "/api/media", query) ?? ImageCache.shared.cached("/api/media", query, .thumb) {
                        loaded.append(full)
                    }
                }
                guard !loaded.isEmpty else { self.flash(L("图片尚未加载完成")); return }
                Haptics.tap()
                SystemShare.present(loaded)
            }
        }
        #endif
    }
}

/// 一条消息里提到好几个文件：选一个转发 / 打开
struct FilePickSheet: View {
    @Environment(AppModel.self) private var model
    @PanelDismiss private var dismiss
    let key: String
    let paths: [String]

    var body: some View {
        FitSheet(title: L("消息中的文件")) {
            SheetSection(footer: L("轻点打开预览；右侧按钮直接转发到其他 App。")) {
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    if index > 0 { SheetDivider() }
                    HStack(spacing: 8) {
                        Button {
                            dismiss()
                            FileOpener.shared.open(model, key: key, path: path)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                FileChip(name: FileLink.displayName(path))
                                Text(Bytes.shortPath(path)).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(RowButtonStyle())
                        Button {
                            dismiss()
                            FileOpener.shared.open(model, key: key, path: path, share: true)
                        } label: {
                            Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.steady(.plain))
                        .accessibilityLabel("转发")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
        }
    }
}

/// 「转发文件」选文件的面板用（sheetPanel(item:) 要 Identifiable）
struct MentionedFiles: Identifiable {
    let paths: [String]
    var id: String { paths.joined(separator: "\n") }
}
