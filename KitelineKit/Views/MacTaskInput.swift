#if KITELINE_MAC
import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 新任务要带的一张图：压过的 JPEG（同发消息，长边 2048）+ 小预览
public struct TarsTaskImage: Identifiable {
    public let id = UUID()
    public let name: String
    public let data: Data
    let preview: Data

    /// 原图压成要发的样子（自测截图预先放几张图时用）
    public static func make(_ raw: Data, name: String = "image.jpg") -> TarsTaskImage? {
        ImagePrep.prepare(raw).map { TarsTaskImage(name: name, data: $0.jpeg, preview: $0.preview) }
    }
}

/// Mac「新任务」面板的输入区（面板在 Mac App 里：Sources/NewTaskSheet.swift），排法同 Mac 的「加入待办」：
/// 整段文字框（回车换行、⌘回车开始；⌘V 粘贴截图），底下一条「听写」和快捷键；图片一栏（拖进面板、⌘V、粘贴、选择文件、从「照片」），最多 6 张。
/// 10-23 反馈新任务不能粘贴、选择图片：原来是系统的纯文本框，没有附图的地方
public struct TarsTaskInput: View {
    @Binding var text: String
    @Binding var images: [TarsTaskImage]
    let placeholder: String
    let enabled: Bool
    let submitTitle: String
    let onSubmit: () -> Void
    @State private var inputHeight: CGFloat = 110
    @State private var focusToken = 0
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var dropTargeted = false
    /// 剪贴板里有图：图片一栏多一个「粘贴」（截图后不用再点进文字框按 ⌘V）
    @State private var clipboardImage = false

    public static let maxImages = 6

    public init(text: Binding<String>, images: Binding<[TarsTaskImage]>, placeholder: String, enabled: Bool = true,
                submitTitle: String, onSubmit: @escaping () -> Void) {
        _text = text
        _images = images
        self.placeholder = placeholder
        self.enabled = enabled
        self.submitTitle = submitTitle
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                MacInputField(text: $text, height: $inputHeight, placeholder: placeholder, enabled: enabled, focusToken: focusToken,
                              onSubmit: onSubmit, onPasteImages: add, minHeight: 110, maxHeight: 220, returnSubmits: false)
                    .frame(height: inputHeight)
                HStack(spacing: 8) {
                    // 听写要用对话页那份连接（转写走本机服务）；面板在 Mac App 里，环境里没有，这里带上
                    if let model = KitelineKit.model {
                        MacDictateButton { said in
                            text = Dictation.append(said, to: text)
                            focusToken += 1
                        }
                        .environment(model)
                        .disabled(!enabled)
                    }
                    Spacer(minLength: 8)
                    Text(L("⌘V 粘贴截图 · ⌘↩ %@", "\(submitTitle)")).font(.ui(.caption)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).hairlineBorder(MacPalette.separator))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("图片")).font(.ui(.subheadline).weight(.medium))
                Text("\(images.count)/\(Self.maxImages)").font(.ui(.caption)).foregroundStyle(.tertiary).monospacedDigit()
                Spacer(minLength: 8)
                HStack(spacing: 14) {
                    if clipboardImage {
                        Button(L("粘贴")) {
                            ClipboardImage.handled = ClipboardImage.changeCount
                            clipboardImage = false
                            let list = InputTextView.pasteboardImages()
                            if list.isEmpty { KitelineKit.flash(L("无法读取剪贴板里的图片")) } else { add(list) }
                        }
                        .help(L("粘贴剪贴板里的图片"))
                    }
                    Button(L("选择文件…")) { choosingFiles = true }
                    Button(L("从「照片」选择…")) { choosingPhotos = true }
                }
                .font(.ui(.footnote))
                .buttonStyle(.borderless)
                .tint(Theme.claude)
                .disabled(!enabled || images.count >= Self.maxImages)
            }
            .padding(.top, 14).padding(.bottom, 8)

            shots
        }
        // 把图拖进来（从访达、桌面拖截图）：拖到这一片任何地方都行，经过时图片区描边
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Task { add(await DroppedImages.load(providers)) }
            return true
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $picks, maxSelectionCount: max(1, Self.maxImages - images.count), matching: .images)
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            Task {
                for item in items {
                    if let raw = try? await item.loadTransferable(type: Data.self) { add([raw]) }
                }
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            add(urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            })
        }
        .onAppear { clipboardImage = ClipboardImage.offer }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in clipboardImage = ClipboardImage.offer }
        .task { focusToken += 1 }
    }

    /// 没图时是一块虚线框（点一下选文件）；有图时一格格缩略图，最后一格「+」接着加
    private var shots: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if images.isEmpty {
                Button { choosingFiles = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 16, weight: .light)).foregroundStyle(.secondary)
                        Text(L("将截图拖到此处，或在文字框中按 ⌘V 粘贴")).font(.ui(.footnote)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(L("点击选择图片文件"))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68, maximum: 68), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(images) { image in
                        TaskImageTile(image: image) { withAnimation(.snappy) { images.removeAll { $0.id == image.id } } }
                            .zoomableOnClick(images.map { .local($0.data) }, index: images.firstIndex { $0.id == image.id } ?? 0)
                    }
                    if images.count < Self.maxImages {
                        Button { choosingFiles = true } label: {
                            Image(systemName: "plus").font(.system(size: 16, weight: .light)).foregroundStyle(.secondary)
                                .frame(width: 68, height: 68)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(MacPalette.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .help(L("添加图片文件"))
                    }
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropTargeted ? Theme.claude.opacity(0.08) : Color.primary.opacity(0.03), in: shape)
        .overlay(shape.strokeBorder(dropTargeted ? Theme.claude : MacPalette.separator,
                                    style: StrokeStyle(lineWidth: dropTargeted ? 1.5 : 1, dash: images.isEmpty || dropTargeted ? [5, 4] : [])))
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }

    /// 粘贴、拖进来、选的图：同发消息，长边缩到 2048、转 JPEG
    private func add(_ list: [Data]) {
        guard enabled, !list.isEmpty else { return }
        if list.count > Self.maxImages - images.count { KitelineKit.flash(L("最多附 %@ 张图片", "\(Self.maxImages)")) }
        for data in list where images.count < Self.maxImages {
            guard let prepared = ImagePrep.prepare(data) else { continue }
            withAnimation(.snappy) {
                images.append(TarsTaskImage(name: "image-\(images.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
            }
        }
        focusToken += 1
    }
}

/// 一张已附上的图：鼠标指上去右上角出现 ✕，右键也能移除
private struct TaskImageTile: View {
    let image: TarsTaskImage
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if let picture = NSImage(data: image.preview) {
                Image(nsImage: picture).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).hairlineBorder(MacPalette.separator))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                        .foregroundStyle(.white, .black.opacity(0.65))
                        .padding(4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("移除图片"))
                .transition(.opacity)
            }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .contextMenu { Button(L("移除"), role: .destructive, action: remove) }
    }
}
#endif
